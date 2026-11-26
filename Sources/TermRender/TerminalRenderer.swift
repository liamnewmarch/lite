import CoreText
import Foundation
import Metal
import QuartzCore
import Synchronization
import TermCore

/// Turns a `GridSnapshot` into pixels.
///
/// Each frame:
/// 1. Walk the grid on the CPU and build three instance lists: background rects,
///    glyph quads, and decoration rects (underline/strikethrough/cursor shapes).
/// 2. Copy them into one GPU buffer (one of three, rotated; see `inflight`).
/// 3. Encode a render pass: clear to the background colour, then one instanced draw
///    per list (plus two for the debug overlay). Each draw is "draw this 4-vertex
///    quad N times", where the shader reads instance i's data from the buffer.
///
/// We rebuild every instance every frame: a 200×60 grid is ~12k cells, which takes
/// well under a millisecond. Dirty-row tracking will make this incremental later if
/// the overlay says it matters.
@MainActor
public final class TerminalRenderer {
    public let context: RenderContext
    public private(set) var atlas: GlyphAtlas
    public var palette: Palette
    public var showsOverlay = false

    public var metrics: FontMetrics { atlas.fonts.metrics }

    /// CPU time to build + encode the last frame, and GPU time of the last completed frame.
    public var lastFrameTimes: (cpuMs: Double, gpuMs: Double) {
        let t = timings.snapshot()
        return (t.cpuMs, t.gpuMs)
    }

    // Triple buffering: the CPU fills buffer N+1 while the GPU may still be reading
    // buffers N and N−1. The semaphore stops the CPU getting more than 3 frames ahead
    // (which would mean overwriting data the GPU hasn't read yet).
    private static let maxInflight = 3
    private var buffers: [(any MTLBuffer)?] = Array(repeating: nil, count: maxInflight)
    private var bufferIndex = 0
    private let inflight = DispatchSemaphore(value: maxInflight)

    private let timings = Timings()
    private var rects: [RectInstance] = []
    private var glyphs: [GlyphInstance] = []
    private var decorations: [RectInstance] = []
    private var overlayRects: [RectInstance] = []
    private var overlayGlyphs: [GlyphInstance] = []

    public init(context: RenderContext, font: CTFont, scale: CGFloat, palette: Palette) {
        self.context = context
        self.palette = palette
        atlas = GlyphAtlas(fonts: FontSet(font: font, scale: scale), device: context.device, queue: context.queue)
    }

    /// Rebuilds fonts and the atlas, e.g. when the window moves to a display with a
    /// different scale factor, or the font changes.
    public func setFont(_ font: CTFont, scale: CGFloat) {
        atlas = GlyphAtlas(fonts: FontSet(font: font, scale: scale), device: context.device, queue: context.queue)
    }

    public var scale: CGFloat { metrics.scale }

    /// Renders `grid` with its top-left cell at `origin` (px) into the layer's next drawable.
    public func draw(_ grid: GridSnapshot, in layer: CAMetalLayer, origin: (x: Int, y: Int),
                     presentsWithTransaction: Bool = false) {
        inflight.wait()
        guard let drawable = layer.nextDrawable() else {
            inflight.signal()
            return
        }
        let cb = encode(grid, into: drawable.texture, origin: origin)
        layer.presentsWithTransaction = presentsWithTransaction
        if presentsWithTransaction {
            // During live resize: present in sync with the window's Core Animation
            // transaction so the content never lags (or stretches) behind the frame.
            cb.commit()
            cb.waitUntilScheduled()
            drawable.present()
        } else {
            cb.present(drawable)
            cb.commit()
        }
    }

    /// Renders offscreen and returns the image: the `--snapshot` debug mode, and a
    /// stand-in for Metal frame capture (unavailable without Xcode).
    public func renderImage(_ grid: GridSnapshot, width: Int, height: Int, origin: (x: Int, y: Int)) -> CGImage? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderContext.pixelFormat,
                                                            width: width, height: height, mipmapped: false)
        desc.usage = .renderTarget
        desc.storageMode = .shared
        guard let texture = context.device.makeTexture(descriptor: desc) else { return nil }
        inflight.wait()
        let cb = encode(grid, into: texture, origin: origin)
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        // BGRA8 in memory = 32-bit little-endian with alpha first.
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Builds instances and encodes the frame into `target`. The caller commits.
    /// Must be balanced by a prior `inflight.wait()`; the completion handler signals.
    private func encode(_ grid: GridSnapshot, into target: any MTLTexture, origin: (x: Int, y: Int)) -> any MTLCommandBuffer {
        let cpuStart = ContinuousClock.now

        buildInstances(grid, origin: origin)
        let viewport = (w: target.width, h: target.height)
        if showsOverlay { buildOverlay(grid: grid, viewport: viewport) } else {
            overlayRects.removeAll(keepingCapacity: true)
            overlayGlyphs.removeAll(keepingCapacity: true)
        }

        // Pack all lists into one buffer, back to back.
        let sizes = [
            rects.count * MemoryLayout<RectInstance>.stride,
            glyphs.count * MemoryLayout<GlyphInstance>.stride,
            decorations.count * MemoryLayout<RectInstance>.stride,
            overlayRects.count * MemoryLayout<RectInstance>.stride,
            overlayGlyphs.count * MemoryLayout<GlyphInstance>.stride,
        ]
        let buffer = instanceBuffer(minLength: max(sizes.reduce(0, +), 64))
        var offsets: [Int] = []
        var cursor = 0
        func copy<T>(_ array: [T]) {
            offsets.append(cursor)
            array.withUnsafeBytes { src in
                if src.count > 0 { (buffer.contents() + cursor).copyMemory(from: src.baseAddress!, byteCount: src.count) }
                cursor += src.count
            }
        }
        copy(rects); copy(glyphs); copy(decorations); copy(overlayRects); copy(overlayGlyphs)

        // A render pass: which texture to draw into, and to clear it first.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let bg = palette.background
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.r) / 255, green: Double(bg.g) / 255,
                                                            blue: Double(bg.b) / 255, alpha: 1)

        let cb = context.queue.makeCommandBuffer()!
        let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
        var uniforms = Uniforms(viewportSize: SIMD2(Float(viewport.w), Float(viewport.h)))
        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentTexture(atlas.gray.texture, index: 0)
        enc.setFragmentTexture(atlas.color.texture, index: 1)

        func drawQuads(_ pipeline: any MTLRenderPipelineState, _ count: Int, _ offset: Int) {
            guard count > 0 else { return }
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(buffer, offset: offset, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        drawQuads(context.rectPipeline, rects.count, offsets[0])
        drawQuads(context.glyphPipeline, glyphs.count, offsets[1])
        drawQuads(context.rectPipeline, decorations.count, offsets[2])
        drawQuads(context.rectPipeline, overlayRects.count, offsets[3])
        drawQuads(context.glyphPipeline, overlayGlyphs.count, offsets[4])
        enc.endEncoding()

        let timings = self.timings
        let semaphore = inflight
        cb.addCompletedHandler { cb in
            timings.recordGPU(ms: (cb.gpuEndTime - cb.gpuStartTime) * 1000)
            semaphore.signal()
        }
        timings.recordCPU(ms: (ContinuousClock.now - cpuStart).milliseconds,
                          instances: rects.count + glyphs.count + decorations.count)
        return cb
    }

    private func instanceBuffer(minLength: Int) -> any MTLBuffer {
        bufferIndex = (bufferIndex + 1) % Self.maxInflight
        if let b = buffers[bufferIndex], b.length >= minLength { return b }
        // Grow with headroom so resizing the window doesn't reallocate every frame.
        let b = context.device.makeBuffer(length: minLength * 3 / 2, options: .storageModeShared)!
        buffers[bufferIndex] = b
        return b
    }

    // MARK: - Building instances

    private func buildInstances(_ grid: GridSnapshot, origin: (x: Int, y: Int)) {
        rects.removeAll(keepingCapacity: true)
        glyphs.removeAll(keepingCapacity: true)
        decorations.removeAll(keepingCapacity: true)

        let m = metrics
        let cw = m.cellWidth, ch = m.cellHeight
        let defaultBG = palette.background
        let cursor = grid.cursor
        let selection = grid.selection

        for row in 0..<grid.rows {
            let y = origin.y + row * ch
            // Merge runs of same-coloured backgrounds into one rect.
            var runStart = 0
            var runColor: RGB?

            for col in 0..<grid.cols {
                let cell = grid[col, row]
                var fg = palette.resolve(cell.fg, foreground: true)
                var bg = palette.resolve(cell.bg, foreground: false)
                if cell.attrs.contains(.inverse) { swap(&fg, &bg) }
                if let selection, selection.contains(col: col, row: row) {
                    bg = palette.selectionBackground
                    if let sfg = palette.selectionForeground { fg = sfg }
                }
                let isCursor = cursor.visible && cursor.style == .block && cursor.col == col && cursor.row == row
                if isCursor { bg = palette.cursor; fg = palette.cursorText }
                if cell.attrs.contains(.dim) { fg = fg.mixed(with: bg, 0.5) }

                // Background runs (the clear colour already covers default-bg cells).
                let wanted: RGB? = bg == defaultBG ? nil : bg
                if wanted != runColor {
                    if let c = runColor { appendRect(&rects, origin.x + runStart * cw, y, (col - runStart) * cw, ch, c.packed()) }
                    runStart = col
                    runColor = wanted
                }

                if cell.attrs.contains(.wideTrailer) { continue }
                let span = cell.attrs.contains(.wide) ? 2 : 1
                let x = origin.x + col * cw

                if !cell.attrs.contains(.invisible), cell.scalar != 0, cell.scalar != 0x20 {
                    let variant: FontSet.Variant = switch (cell.attrs.contains(.bold), cell.attrs.contains(.italic)) {
                    case (true, true): .boldItalic
                    case (true, false): .bold
                    case (false, true): .italic
                    case (false, false): .regular
                    }
                    let e = atlas.entry(scalar: cell.scalar, text: grid.text(col: col, row: row) ?? " ", variant: variant, span: span)
                    if !e.isEmpty {
                        glyphs.append(GlyphInstance(
                            x: Int16(clamping: x + Int(e.offsetX)), y: Int16(clamping: y + m.baseline + Int(e.offsetY)),
                            w: e.width, h: e.height, atlasX: e.atlasX, atlasY: e.atlasY,
                            color: fg.packed(), flags: e.isColor ? 1 : 0))
                    }
                }
                if cell.attrs.contains(.underline) {
                    appendRect(&decorations, x, y + m.underlineY, span * cw, m.underlineThickness, fg.packed())
                }
                if cell.attrs.contains(.strikethrough) {
                    appendRect(&decorations, x, y + m.strikethroughY, span * cw, m.underlineThickness, fg.packed())
                }
            }
            if let c = runColor { appendRect(&rects, origin.x + runStart * cw, y, (grid.cols - runStart) * cw, ch, c.packed()) }
        }

        // Non-block cursor shapes draw over the text.
        if cursor.visible, cursor.style != .block, cursor.row < grid.rows, cursor.col < grid.cols {
            let x = origin.x + cursor.col * cw, y = origin.y + cursor.row * ch
            let thick = max(2, Int((m.scale).rounded()))
            let color = palette.cursor.packed()
            switch cursor.style {
            case .bar: appendRect(&decorations, x, y, thick, ch, color)
            case .underline: appendRect(&decorations, x, y + ch - thick, cw, thick, color)
            case .hollowBlock:
                // Unfocused window: outline only, so it's clear where keys won't go.
                let t = max(1, Int(m.scale.rounded()))
                let w = grid.cursor.col < grid.cols && grid[cursor.col, cursor.row].attrs.contains(.wide) ? 2 * cw : cw
                appendRect(&decorations, x, y, w, t, color)
                appendRect(&decorations, x, y + ch - t, w, t, color)
                appendRect(&decorations, x, y, t, ch, color)
                appendRect(&decorations, x + w - t, y, t, ch, color)
            case .block: break
            }
        }
    }

    private func appendRect(_ list: inout [RectInstance], _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: UInt32) {
        list.append(RectInstance(x: Int16(clamping: x), y: Int16(clamping: y),
                                 w: Int16(clamping: w), h: Int16(clamping: h), color: color))
    }

    // MARK: - Debug overlay

    /// A small panel in the top-right corner, drawn with the same atlas as the grid.
    private func buildOverlay(grid: GridSnapshot, viewport: (w: Int, h: Int)) {
        overlayRects.removeAll(keepingCapacity: true)
        overlayGlyphs.removeAll(keepingCapacity: true)
        let t = timings.snapshot()
        let lines = [
            String(format: "cpu %.2f ms  gpu %.2f ms", t.cpuMs, t.gpuMs),
            "grid \(grid.cols)×\(grid.rows)  instances \(t.instances)",
            String(format: "atlas gray %d² %.1f%%  color %d² %.1f%%",
                   atlas.gray.size, atlas.gray.usage * 100, atlas.color.size, atlas.color.usage * 100),
            "glyphs \(atlas.glyphCount)  cell \(metrics.cellWidth)×\(metrics.cellHeight)px @\(Int(metrics.scale))x",
            String(format: "shader compile %.1f ms", context.shaderCompileMs),
        ]
        let m = metrics
        let maxLen = lines.map(\.count).max() ?? 0
        let pad = m.cellWidth
        let w = maxLen * m.cellWidth + 2 * pad
        let h = lines.count * m.cellHeight + pad
        let x0 = viewport.w - w - pad
        let y0 = Int(40 * m.scale)
        appendRect(&overlayRects, x0, y0, w, h, RGB(0, 0, 0).packed(alpha: 200))
        let color = RGB(hex: 0x9EE493).packed()
        for (i, line) in lines.enumerated() {
            var x = x0 + pad
            let y = y0 + pad / 2 + i * m.cellHeight + m.baseline
            for ch in line {
                let scalar = ch.unicodeScalars.first!.value
                let e = atlas.entry(scalar: scalar, text: String(ch), variant: .regular, span: 1)
                if !e.isEmpty {
                    overlayGlyphs.append(GlyphInstance(
                        x: Int16(clamping: x + Int(e.offsetX)), y: Int16(clamping: y + Int(e.offsetY)),
                        w: e.width, h: e.height, atlasX: e.atlasX, atlasY: e.atlasY, color: color, flags: 0))
                }
                x += m.cellWidth
            }
        }
    }
}

/// Frame timings, written from the GPU completion handler (a background thread)
/// and read on the main thread.
final class Timings: Sendable {
    struct Values { var cpuMs = 0.0, gpuMs = 0.0, instances = 0 }
    private let values = Mutex(Values())

    func recordGPU(ms: Double) { values.withLock { $0.gpuMs = ms } }
    func recordCPU(ms: Double, instances: Int) {
        values.withLock { $0.cpuMs = ms; $0.instances = instances }
    }
    func snapshot() -> Values { values.withLock { $0 } }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
