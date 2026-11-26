/// The terminal model the renderer consumes. Every terminal engine (SwiftTerm now,
/// a home-grown one later) exports its visible screen as a `GridSnapshot`.
///
/// `Cell` is plain data (no references), so a snapshot copy is a straight memory
/// copy. Multi-scalar grapheme clusters (e.g. "👍🏽", "é" as e + combining accent)
/// live in a side table keyed by cell index, so `Cell` stays small.

public enum TermColor: Sendable, Hashable {
    case `default`
    /// The *other* default: background colour when used as a foreground and vice versa
    /// (reverse video of the default pair).
    case defaultInverted
    /// 0–15 ANSI, 16–231 6×6×6 cube, 232–255 grayscale ramp.
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct CellAttributes: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold          = CellAttributes(rawValue: 1 << 0)
    public static let italic        = CellAttributes(rawValue: 1 << 1)
    public static let underline     = CellAttributes(rawValue: 1 << 2)
    public static let strikethrough = CellAttributes(rawValue: 1 << 3)
    public static let inverse       = CellAttributes(rawValue: 1 << 4)
    public static let dim           = CellAttributes(rawValue: 1 << 5)
    public static let invisible     = CellAttributes(rawValue: 1 << 6)
    /// First cell of a double-width character (CJK, most emoji).
    public static let wide          = CellAttributes(rawValue: 1 << 7)
    /// Second (empty) cell of a double-width character.
    public static let wideTrailer   = CellAttributes(rawValue: 1 << 8)
}

public struct Cell: Sendable, Hashable {
    /// First (often only) Unicode scalar; 0 means empty.
    public var scalar: UInt32
    /// 0 = the cell is just `scalar`; 1 = the full cluster is in `GridSnapshot.clusters[index]`.
    public var cluster: UInt32
    public var fg: TermColor
    public var bg: TermColor
    public var attrs: CellAttributes

    public init(scalar: UInt32 = 0, cluster: UInt32 = 0, fg: TermColor = .default,
                bg: TermColor = .default, attrs: CellAttributes = []) {
        self.scalar = scalar
        self.cluster = cluster
        self.fg = fg
        self.bg = bg
        self.attrs = attrs
    }

    public static let blank = Cell()
}

public struct CursorState: Sendable, Hashable {
    /// `hollowBlock` is what the view shows when the window isn't focused.
    public enum Style: Sendable, Hashable { case block, hollowBlock, bar, underline }
    public var col: Int
    public var row: Int
    public var visible: Bool
    public var style: Style
    /// The program asked for a blinking cursor (DECSCUSR 1/3/5). The view does the blinking.
    public var blinking: Bool

    public init(col: Int = 0, row: Int = 0, visible: Bool = true, style: Style = .block, blinking: Bool = false) {
        self.col = col
        self.row = row
        self.visible = visible
        self.style = style
        self.blinking = blinking
    }
}

/// A linear (stream) selection in *visible* grid coordinates, for drawing. Rows may
/// lie outside 0..<rows when the selection extends into scrolled-off lines.
public struct SelectionHighlight: Sendable, Hashable {
    public var startCol: Int, startRow: Int
    public var endCol: Int, endRow: Int  // inclusive

    public init(startCol: Int, startRow: Int, endCol: Int, endRow: Int) {
        self.startCol = startCol; self.startRow = startRow
        self.endCol = endCol; self.endRow = endRow
    }

    @inline(__always)
    public func contains(col: Int, row: Int) -> Bool {
        guard row >= startRow, row <= endRow else { return false }
        if row == startRow && col < startCol { return false }
        if row == endRow && col > endCol { return false }
        return true
    }
}

public struct GridSnapshot: Sendable {
    public private(set) var cols: Int
    public private(set) var rows: Int
    /// Row-major, `cols * rows`.
    public var cells: [Cell]
    /// Multi-scalar clusters by cell index (`row * cols + col`).
    public var clusters: [Int: String] = [:]
    public var cursor = CursorState()
    /// Set by the view each frame (not by the engine).
    public var selection: SelectionHighlight?

    public init(cols: Int, rows: Int) {
        self.cols = max(cols, 0)
        self.rows = max(rows, 0)
        cells = Array(repeating: .blank, count: self.cols * self.rows)
    }

    public subscript(col: Int, row: Int) -> Cell {
        get { cells[row * cols + col] }
        set { cells[row * cols + col] = newValue }
    }

    /// Text to draw for the cell at (col, row), or nil if it's empty.
    public func text(col: Int, row: Int) -> String? {
        let cell = self[col, row]
        if cell.cluster != 0, let s = clusters[row * cols + col] { return s }
        guard cell.scalar != 0, let s = Unicode.Scalar(cell.scalar) else { return nil }
        return String(Character(s))
    }

    /// Removes cluster entries for one row (before rewriting it).
    public mutating func clearClusters(row: Int) {
        guard !clusters.isEmpty else { return }
        let range = (row * cols)..<((row + 1) * cols)
        clusters = clusters.filter { !range.contains($0.key) }
    }

    /// Writes `character` at (col, row), handling clusters and double width.
    /// Returns the number of columns used (0 if it didn't fit).
    @discardableResult
    public mutating func put(_ character: Character, col: Int, row: Int,
                             fg: TermColor = .default, bg: TermColor = .default,
                             attrs: CellAttributes = []) -> Int {
        let width = CellWidth.columns(of: character)
        guard row >= 0, row < rows, col >= 0, col + width <= cols else { return 0 }
        let scalars = character.unicodeScalars
        var cell = Cell(scalar: scalars.first!.value, fg: fg, bg: bg, attrs: attrs)
        if scalars.count > 1 {
            clusters[row * cols + col] = String(character)
            cell.cluster = 1
        }
        if width == 2 {
            cell.attrs.insert(.wide)
            self[col + 1, row] = Cell(fg: fg, bg: bg, attrs: attrs.union(.wideTrailer))
        }
        self[col, row] = cell
        return width
    }

    /// Writes a string left to right, clipping at the right edge. Returns the next column.
    @discardableResult
    public mutating func put(_ string: String, col: Int, row: Int,
                             fg: TermColor = .default, bg: TermColor = .default,
                             attrs: CellAttributes = []) -> Int {
        var c = col
        for ch in string {
            let used = put(ch, col: c, row: row, fg: fg, bg: bg, attrs: attrs)
            if used == 0 { break }
            c += used
        }
        return c
    }
}

/// Demo-grade character width. From M4 the terminal engine decides widths
/// (they must match what the program running in the terminal assumes).
public enum CellWidth {
    public static func columns(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 1 }
        if scalars.contains(where: { $0.value == 0xFE0F }) { return 2 }               // emoji presentation selector
        if first.properties.isEmojiPresentation { return 2 }
        if (0x1F1E6...0x1F1FF).contains(first.value) { return 2 }                     // regional indicators (flags)
        switch first.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
