import CoreText
import Metal
import TermCore

/// A glyph atlas: one big texture that individual glyph bitmaps are packed into,
/// like a CSS sprite sheet. Each glyph is rasterised once by CoreText on the CPU,
/// uploaded into a free spot, and from then on drawing it is just a textured quad
/// pointing at that spot.
///
/// Two pages:
/// - `gray` (R8, 1 byte/pixel): coverage masks for normal text. The colour is applied
///   in the shader, so one bitmap serves every foreground colour.
/// - `color` (RGBA8): colour glyphs (emoji), stored with their own colours.
///
/// Pages start at 1024² and double (contents copied on the GPU) when full.
@MainActor
public final class GlyphAtlas {
    public struct Entry: Sendable {
        public var atlasX: UInt16 = 0, atlasY: UInt16 = 0
        public var width: UInt16 = 0, height: UInt16 = 0
        /// Bitmap offset from the cell's left edge / the baseline (y down), in px.
        public var offsetX: Int16 = 0, offsetY: Int16 = 0
        public var isColor = false
        public var isEmpty: Bool { width == 0 }
        static let empty = Entry()
    }

    @MainActor public final class Page {
        public let name: String
        public let pixelFormat: MTLPixelFormat
        public let bytesPerPixel: Int
        public private(set) var texture: any MTLTexture
        public private(set) var size: Int
        fileprivate var packer: ShelfPacker
        public var usage: Double { packer.usage }

        fileprivate init(name: String, device: any MTLDevice, format: MTLPixelFormat, bpp: Int, size: Int) {
            self.name = name
            pixelFormat = format
            bytesPerPixel = bpp
            self.size = size
            texture = Self.makeTexture(device: device, format: format, size: size)
            packer = ShelfPacker(size: size)
        }

        fileprivate static func makeTexture(device: any MTLDevice, format: MTLPixelFormat, size: Int) -> any MTLTexture {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
            desc.usage = .shaderRead
            // Apple Silicon has unified memory: .shared lets the CPU write texels directly.
            desc.storageMode = .shared
            return device.makeTexture(descriptor: desc)!
        }

        /// Doubles the page, copying existing glyphs so their coordinates stay valid.
        fileprivate func grow(device: any MTLDevice, queue: any MTLCommandQueue) -> Bool {
            let newSize = size * 2
            guard newSize <= GlyphAtlas.maxPageSize else { return false }
            let newTexture = Self.makeTexture(device: device, format: pixelFormat, size: newSize)
            let cb = queue.makeCommandBuffer()!
            let blit = cb.makeBlitCommandEncoder()!
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: size, height: size, depth: 1),
                      to: newTexture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted() // rare; keeps the logic simple
            // In-flight frames keep the old texture alive until they finish.
            texture = newTexture
            size = newSize
            packer.size = newSize
            print("[atlas] \(name) page grew to \(newSize)²")
            return true
        }
    }

    nonisolated static let maxPageSize = 8192

    public let fonts: FontSet
    public let gray: Page
    public let color: Page
    public private(set) var glyphCount = 0

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    /// Fast path for ASCII: [variant * 128 + scalar].
    private var ascii = [Entry?](repeating: nil, count: FontSet.Variant.allCases.count * 128)
    private var cache: [Key: Entry] = [:]
    private var warnedFull = false

    private struct Key: Hashable {
        var text: String
        var variant: FontSet.Variant
        var span: Int
    }

    public init(fonts: FontSet, device: any MTLDevice, queue: any MTLCommandQueue) {
        self.fonts = fonts
        self.device = device
        self.queue = queue
        gray = Page(name: "gray", device: device, format: .r8Unorm, bpp: 1, size: 1024)
        color = Page(name: "color", device: device, format: .rgba8Unorm, bpp: 4, size: 512)
    }

    /// Looks up (rasterising on first use) the glyph for `text` in a cell span of 1 or 2.
    public func entry(scalar: UInt32, text: @autoclosure () -> String, variant: FontSet.Variant, span: Int) -> Entry {
        if scalar < 128 && span == 1 {
            let i = variant.rawValue * 128 + Int(scalar)
            if let e = ascii[i] { return e }
            let e = rasterize(text(), variant: variant, span: span)
            ascii[i] = e
            return e
        }
        let key = Key(text: text(), variant: variant, span: span)
        if let e = cache[key] { return e }
        let e = rasterize(key.text, variant: variant, span: span)
        cache[key] = e
        return e
    }

    // MARK: - Rasterisation

    private func rasterize(_ text: String, variant: FontSet.Variant, span: Int) -> Entry {
        let m = fonts.metrics
        var line = makeLine(text, font: fonts.font(variant))

        // CoreText picks a fallback font automatically (e.g. Apple Color Emoji, PingFang
        // for CJK). Colour fonts go to the RGBA page.
        let runFont = firstRunFont(line) ?? fonts.font(variant)
        let isColor = CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)

        // Emoji are often wider/taller than the cell box: scale them to fit their span.
        var ascent: CGFloat = 0, descent: CGFloat = 0
        var advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        if isColor {
            let fitW = CGFloat(span * m.cellWidth) / max(advance, 1)
            let fitH = CGFloat(m.cellHeight) / max(ascent + descent, 1)
            let s = min(1, fitW, fitH)
            if s < 1 {
                let scaled = CTFontCreateCopyWithAttributes(runFont, CTFontGetSize(runFont) * s, nil, nil)
                line = makeLine(text, font: scaled)
                advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            }
        }

        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return .empty } // e.g. space

        // 1px transparent border so neighbours in the atlas never bleed into each other.
        let pad = 1
        let minX = Int(bounds.minX.rounded(.down)), maxX = Int(bounds.maxX.rounded(.up))
        let minY = Int(bounds.minY.rounded(.down)), maxY = Int(bounds.maxY.rounded(.up))
        let w = maxX - minX + 2 * pad
        let h = maxY - minY + 2 * pad

        let page = isColor ? color : gray
        guard let spot = place(w, h, in: page) else { return .empty }

        var pixels = [UInt8](repeating: 0, count: w * h * page.bytesPerPixel)
        pixels.withUnsafeMutableBytes { buf in
            let ctx: CGContext
            if isColor {
                ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            } else {
                // Draw white-on-black into a gray bitmap: the result is pure coverage.
                ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                ctx.setFillColor(gray: 1, alpha: 1)
            }
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            // No "font smoothing" (stem darkening) and no subpixel positioning: glyphs
            // are reused at every cell position, so they must be position-independent.
            ctx.setAllowsFontSmoothing(false)
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSubpixelPositioning(false)
            ctx.setShouldSubpixelPositionFonts(false)
            ctx.textPosition = CGPoint(x: CGFloat(pad - minX), y: CGFloat(pad - minY))
            CTLineDraw(line, ctx)

            // CGBitmapContext rows are stored top-to-bottom, same as Metal textures.
            page.texture.replace(region: MTLRegionMake2D(spot.x, spot.y, w, h), mipmapLevel: 0,
                                 withBytes: buf.baseAddress!, bytesPerRow: w * page.bytesPerPixel)
        }
        glyphCount += 1

        // Centre colour glyphs horizontally within their span.
        let centring = isColor ? Int(((CGFloat(span * m.cellWidth) - advance) / 2).rounded()) : 0
        return Entry(atlasX: UInt16(spot.x), atlasY: UInt16(spot.y),
                     width: UInt16(w), height: UInt16(h),
                     offsetX: Int16(minX - pad + centring),
                     offsetY: Int16(-(maxY + pad)),
                     isColor: isColor)
    }

    private func place(_ w: Int, _ h: Int, in page: Page) -> (x: Int, y: Int)? {
        while true {
            if let spot = page.packer.place(width: w, height: h) { return spot }
            if !page.grow(device: device, queue: queue) {
                if !warnedFull {
                    print("[atlas] \(page.name) page full at \(page.size)²; new glyphs will be blank")
                    warnedFull = true
                }
                return nil
            }
        }
    }

    private func makeLine(_ text: String, font: CTFont) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    private func firstRunFont(_ line: CTLine) -> CTFont? {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], let run = runs.first else { return nil }
        let attrs = CTRunGetAttributes(run) as NSDictionary
        guard let value = attrs[kCTFontAttributeName as String] else { return nil }
        return (value as! CTFont)
    }
}

/// Shelf packing: glyphs are placed left-to-right in horizontal "shelves" (rows);
/// a new shelf opens below when nothing fits. Simple and fast, and glyphs in a
/// monospace font are similar sizes, so waste is low.
struct ShelfPacker {
    struct Shelf { var y: Int; var height: Int; var x: Int }

    var size: Int
    private var shelves: [Shelf] = []
    private var nextY = 0
    private var usedArea = 0

    init(size: Int) { self.size = size }

    var usage: Double { Double(usedArea) / Double(size * size) }

    mutating func place(width: Int, height: Int) -> (x: Int, y: Int)? {
        guard width <= size else { return nil }
        // Best fit: the shortest shelf that's tall enough (and not wastefully tall).
        var best: Int?
        for (i, s) in shelves.enumerated()
        where s.height >= height && s.height <= height + height / 2 + 2 && s.x + width <= size {
            if best == nil || s.height < shelves[best!].height { best = i }
        }
        if let i = best {
            let spot = (shelves[i].x, shelves[i].y)
            shelves[i].x += width
            usedArea += width * shelves[i].height
            return spot
        }
        guard nextY + height <= size else { return nil }
        shelves.append(Shelf(y: nextY, height: height, x: width))
        defer { nextY += height }
        usedArea += width * height
        return (0, nextY)
    }
}
