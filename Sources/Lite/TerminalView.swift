import AppKit
import QuartzCore
import TermCore
import TermRender

/// The terminal's content view: a layer-backed NSView whose layer is a
/// `CAMetalLayer` (a Core Animation layer that hands out GPU textures,
/// "drawables", to render into; think `<canvas>` + WebGPU context).
///
/// Frame pacing: a display link (vsync-aligned callback, like
/// `requestAnimationFrame`) runs only while something is dirty, then pauses
/// itself, so an idle terminal uses no CPU or GPU.
///
/// Input lives in TerminalView+Keyboard.swift (keys, IME) and
/// TerminalView+Mouse.swift (selection, scrolling, mouse reporting, clipboard).
@MainActor
final class TerminalView: NSView {
    struct GridGeometry: Equatable {
        var cols: Int, rows: Int
        var origin: (x: Int, y: Int)
        var pixelWidth: Int, pixelHeight: Int
        static func == (a: Self, b: Self) -> Bool {
            a.cols == b.cols && a.rows == b.rows && a.origin == b.origin
                && a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight
        }
    }

    /// Padding around the grid when `window-padding` isn't set, in points. The title/tab
    /// bar (safe area) is always added to the top on top of this.
    static let defaultPadding = NSEdgeInsets(top: 2, left: 6, bottom: 4, right: 6)

    /// Padding on all four sides, in points (`window-padding`); nil = `defaultPadding`.
    var padding: CGFloat? {
        didSet { if padding != oldValue { updateGeometry() } }
    }

    let renderer: TerminalRenderer
    /// The terminal this view shows. Each frame pulls changed rows into `grid`.
    var session: TerminalSession? { didSet { setNeedsRender() } }
    /// Last rendered screen. Kept between frames so only changed rows are rewritten.
    private(set) var grid = GridSnapshot(cols: 0, rows: 0)
    private(set) var geometry: GridGeometry?

    /// Called when the grid's column/row count changes.
    var onGridResize: ((GridGeometry) -> Void)?

    /// Which Option key(s) act as Meta (send ESC-prefixed keys) instead of composing
    /// characters like é or ∑. Default: neither (the macOS convention). From the config.
    var optionAsMeta: OptionAsMeta = .none

    /// User key bindings (`keybind` in the config); checked before anything else.
    var keyBindings: [KeyBinding] = []

    /// The terminal font at its point size; re-rasterised per display scale.
    private(set) var font: CTFont

    // Input state (used by the extensions).
    var markedText = ""                    // IME composition in progress (e.g. pinyin, dead key)
    var selection: TextSelection?
    var mouseButtonReported: Int?          // button currently reported to the program
    var scrollAccumulator: CGFloat = 0     // fractional rows from trackpad deltas
    var autoscrollTimer: Timer?

    private var displayLink: CADisplayLink?
    private var needsRender = true
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var blinkTimer: Timer?
    private var blinkOn = true
    private var windowObservers: [NSObjectProtocol] = []
    private let perf = PerfLog()

    init(renderer: TerminalRenderer) {
        self.renderer = renderer
        font = renderer.atlas.fonts.font(.regular)
        font = CTFontCreateCopyWithAttributes(font, renderer.atlas.fonts.pointSize, nil, nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        wantsLayer = true
        // We draw on our own schedule; AppKit should never redraw/stretch the layer itself.
        layerContentsRedrawPolicy = .never
        if ProcessInfo.processInfo.environment["LITE_DEBUG_OVERLAY"] == "1" { renderer.showsOverlay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderer.context.device
        // 8-bit BGRA, *not* the _srgb variant: we write sRGB-encoded colours directly
        // and blending happens in sRGB space, which is how macOS composites its own
        // text. (Linear-space blending makes light-on-dark text look thinner.)
        layer.pixelFormat = RenderContext.pixelFormat
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.maximumDrawableCount = 3
        layer.contentsGravity = .topLeft // never stretch stale content during resize
        layer.needsDisplayOnBoundsChange = false
        return layer
    }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else {
            stopBlinking()
            return
        }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        window.makeFirstResponder(self)
        // Focus changes switch the cursor between solid and hollow.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.blinkOn = true
                    self?.setNeedsRender()
                }
            })
        }
        updateScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        if renderer.scale != scale {
            // Moving between Retina and non-Retina displays: re-rasterise at the new size.
            renderer.setFont(font, scale: scale)
        }
        updateGeometry()
    }

    /// Changes the font (config reload): new atlas, new cell size, so the grid
    /// (and the PTY size) usually changes too.
    func setFont(_ newFont: CTFont) {
        let same = CTFontCopyPostScriptName(newFont) == CTFontCopyPostScriptName(font)
            && CTFontGetSize(newFont) == CTFontGetSize(font)
        font = newFont
        if !same { renderer.setFont(newFont, scale: metalLayer.contentsScale) }
        updateGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
        // Draw synchronously during live resize so the content tracks the window edge.
        if inLiveResize { render() }
    }

    override func layout() {
        super.layout()
        updateGeometry() // safe area changes (e.g. the tab bar appearing) arrive via layout
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Mouse-moved events (for programs that track motion, e.g. tmux, vim with mouse=a).
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: - Geometry

    /// Grid size for the current bounds. Pixel-snapped so cells align with the screen.
    func computeGeometry() -> GridGeometry {
        let scale = metalLayer.contentsScale
        let m = renderer.metrics
        let pad = padding.map { NSEdgeInsets(top: $0, left: $0, bottom: $0, right: $0) } ?? Self.defaultPadding
        let top = Int(((safeAreaInsets.top + pad.top) * scale).rounded())
        let left = Int((pad.left * scale).rounded())
        let w = Int((bounds.width * scale).rounded())
        let h = Int((bounds.height * scale).rounded())
        let usableW = w - left - Int((pad.right * scale).rounded())
        let usableH = h - top - Int((pad.bottom * scale).rounded())
        let cols = max(1, usableW / m.cellWidth)
        let rows = max(1, usableH / m.cellHeight)
        // The space left over (less than a cell) is split between both sides, so the
        // grid sits centred inside the padding instead of leaving a wider gap at the
        // right and bottom.
        let x = left + max(0, usableW - cols * m.cellWidth) / 2
        let y = top + max(0, usableH - rows * m.cellHeight) / 2
        return GridGeometry(cols: cols, rows: rows, origin: (x, y),
                            pixelWidth: cols * m.cellWidth, pixelHeight: rows * m.cellHeight)
    }

    private func updateGeometry() {
        let scale = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(width: (bounds.width * scale).rounded(),
                                         height: (bounds.height * scale).rounded())
        let g = computeGeometry()
        let old = geometry
        geometry = g
        setNeedsRender()
        if old?.cols != g.cols || old?.rows != g.rows {
            onGridResize?(g)
        }
    }

    /// Cell under a point in view coordinates, clamped to the grid (visible coordinates).
    func cell(at point: NSPoint) -> (col: Int, row: Int) {
        guard let g = geometry else { return (0, 0) }
        let scale = metalLayer.contentsScale
        let m = renderer.metrics
        let px = point.x * scale - CGFloat(g.origin.x)
        let py = (bounds.height - point.y) * scale - CGFloat(g.origin.y) // NSView y is up
        let col = Int((px / CGFloat(m.cellWidth)).rounded(.down))
        let row = Int((py / CGFloat(m.cellHeight)).rounded(.down))
        return (max(0, min(col, g.cols - 1)), max(0, min(row, g.rows - 1)))
    }

    /// Unclamped row (negative above the grid, ≥ rows below), for drag autoscroll.
    func rawRow(at point: NSPoint) -> Int {
        guard let g = geometry else { return 0 }
        let py = (bounds.height - point.y) * metalLayer.contentsScale - CGFloat(g.origin.y)
        return Int((py / CGFloat(renderer.metrics.cellHeight)).rounded(.down))
    }

    /// A cell's rect in screen coordinates (for placing the IME candidate window).
    func screenRect(col: Int, row: Int) -> NSRect {
        guard let g = geometry, let window else { return .zero }
        let scale = metalLayer.contentsScale
        let m = renderer.metrics
        let x = CGFloat(g.origin.x + col * m.cellWidth) / scale
        let yTop = CGFloat(g.origin.y + row * m.cellHeight) / scale
        let h = CGFloat(m.cellHeight) / scale
        let viewRect = NSRect(x: x, y: bounds.height - yTop - h, width: CGFloat(m.cellWidth) / scale, height: h)
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    var cellHeightPoints: CGFloat { CGFloat(renderer.metrics.cellHeight) / metalLayer.contentsScale }

    // MARK: - Rendering

    func setNeedsRender() {
        needsRender = true
        displayLink?.isPaused = false
    }

    @objc private func step(_ link: CADisplayLink) {
        guard needsRender else {
            link.isPaused = true
            return
        }
        render()
    }

    private func render() {
        guard let window, let geometry, bounds.width > 0, bounds.height > 0 else { return }
        needsRender = false

        // Copy changed rows out under the engine's lock, then render without it.
        let viewport = session?.engine.viewport ?? Viewport()
        session?.snapshot(into: &grid)

        // Per-frame decorations go on a copy. Changing `selection`/`cursor` doesn't copy
        // the cell array (copy-on-write only triggers when cells are mutated).
        var frame = grid
        frame.selection = selectionHighlight(viewport: viewport)
        let focused = window.isKeyWindow
        if !focused && frame.cursor.style == .block { frame.cursor.style = .hollowBlock }
        if frame.cursor.blinking && focused && !blinkOn { frame.cursor.visible = false }
        if !markedText.isEmpty { drawMarkedText(into: &frame) }
        updateBlinkTimer(needed: frame.cursor.blinking && focused && grid.cursor.visible)

        renderer.draw(frame, in: metalLayer, origin: geometry.origin, presentsWithTransaction: inLiveResize)
        perf.frame(renderer: renderer, bytes: session?.bytesReceived ?? 0)
    }

    private func selectionHighlight(viewport: Viewport) -> SelectionHighlight? {
        guard let selection, !selection.isEmpty, let engine = session?.engine else { return nil }
        let (a, b) = selection.resolved(cols: grid.cols) { engine.line(absoluteRow: $0)?.cells }
        return SelectionHighlight(startCol: a.col, startRow: a.row - viewport.topRow,
                                  endCol: b.col, endRow: b.row - viewport.topRow)
    }

    /// Shows the in-progress IME composition inline at the cursor, underlined.
    private func drawMarkedText(into frame: inout GridSnapshot) {
        var col = frame.cursor.col
        let row = frame.cursor.row
        for ch in markedText {
            let used = frame.put(ch, col: col, row: row, attrs: .underline)
            if used == 0 { break }
            col += used
        }
        frame.cursor.col = min(col, frame.cols - 1)
    }

    // MARK: - Cursor blink

    /// Restart the blink cycle with the cursor shown (e.g. after a key press).
    func resetBlink() {
        blinkOn = true
        if blinkTimer != nil {
            stopBlinking()
            setNeedsRender()
        }
    }

    private func updateBlinkTimer(needed: Bool) {
        if needed, blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.blinkOn.toggle()
                    self.setNeedsRender()
                }
            }
        } else if !needed, blinkTimer != nil {
            stopBlinking()
        }
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = true
    }

    @objc func toggleDebugOverlay(_ sender: Any?) {
        renderer.showsOverlay.toggle()
        setNeedsRender()
    }
}

/// `LITE_PERF_LOG=1`: once a second (while frames are being drawn), logs frame
/// rate, CPU/GPU frame times and how fast output is arriving. Stand-in for Instruments.
@MainActor
final class PerfLog {
    private static let enabled = ProcessInfo.processInfo.environment["LITE_PERF_LOG"] == "1"
    private var windowStart = ContinuousClock.now
    private var frames = 0
    private var cpuTotal = 0.0, cpuMax = 0.0, gpuTotal = 0.0
    private var bytesAtStart = 0

    func frame(renderer: TerminalRenderer, bytes: Int) {
        guard Self.enabled else { return }
        let t = renderer.lastFrameTimes
        frames += 1
        cpuTotal += t.cpuMs
        cpuMax = max(cpuMax, t.cpuMs)
        gpuTotal += t.gpuMs
        let elapsed = (ContinuousClock.now - windowStart)
        guard elapsed >= .seconds(1) else { return }
        let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let mbps = Double(bytes - bytesAtStart) / 1e6 / secs
        print(String(format: "[perf] %3.0f fps  cpu avg %.2f ms max %.2f ms  gpu avg %.2f ms  input %.1f MB/s",
                     Double(frames) / secs, cpuTotal / Double(frames), cpuMax, gpuTotal / Double(frames), mbps))
        windowStart = .now
        frames = 0
        cpuTotal = 0; cpuMax = 0; gpuTotal = 0
        bytesAtStart = bytes
    }
}
