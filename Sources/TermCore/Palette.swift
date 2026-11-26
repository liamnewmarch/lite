/// 8-bit sRGB colour.
public struct RGB: Sendable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    public init(hex: UInt32) {
        self.init(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
    }

    /// Linear interpolation in sRGB space (good enough for "dim").
    public func mixed(with other: RGB, _ t: Double) -> RGB {
        func m(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) * (1 - t) + Double(b) * t).rounded()) }
        return RGB(m(r, other.r), m(g, other.g), m(b, other.b))
    }
}

/// Resolves `TermColor`s to concrete colours. The first 16 entries come from the
/// theme; 16–255 are the standard xterm cube and gray ramp.
public struct Palette: Sendable, Equatable {
    public var foreground: RGB
    public var background: RGB
    public var cursor: RGB
    public var cursorText: RGB
    public var selectionBackground: RGB
    /// nil = keep each cell's own foreground colour.
    public var selectionForeground: RGB?
    /// 256 entries.
    public var indexed: [RGB]

    public init(foreground: RGB, background: RGB, cursor: RGB, cursorText: RGB,
                selectionBackground: RGB, selectionForeground: RGB? = nil, ansi: [RGB]) {
        precondition(ansi.count == 16)
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        var table = ansi
        let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
        for r in levels { for g in levels { for b in levels { table.append(RGB(r, g, b)) } } }
        for i in 0..<24 { let v = UInt8(8 + i * 10); table.append(RGB(v, v, v)) }
        indexed = table
    }

    public func resolve(_ color: TermColor, foreground isForeground: Bool) -> RGB {
        switch color {
        case .default: return isForeground ? foreground : background
        case .defaultInverted: return isForeground ? background : foreground
        case .indexed(let i): return indexed[Int(i)]
        case .rgb(let r, let g, let b): return RGB(r, g, b)
        }
    }

    public static let `default` = Palette(
        foreground: RGB(hex: 0xD8D8DC),
        background: RGB(hex: 0x000000),
        cursor: RGB(hex: 0xE8E8EC),
        cursorText: RGB(hex: 0x000000),
        selectionBackground: RGB(hex: 0x3E4A63),
        ansi: [
            0x2A2A2E, 0xE0616B, 0x8FC97A, 0xE6C36B, 0x6AA6E8, 0xC58AE0, 0x5FC6C9, 0xC8C8CC,
            0x5C5C63, 0xFF7A84, 0xA8DC93, 0xF2D688, 0x8CBCF2, 0xD6A6EE, 0x7FDADD, 0xF4F4F6,
        ].map { RGB(hex: $0) }
    )
}
