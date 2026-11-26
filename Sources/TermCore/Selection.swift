/// A mouse selection in absolute (scroll-invariant) coordinates, so it stays on
/// the same text while scrolling. `anchor` is where the drag started, `head`
/// where it is now; word/line granularity snaps both ends outwards.
public struct TextSelection: Sendable, Equatable {
    public enum Granularity: Sendable, Equatable { case character, word, line }

    public var anchor: GridPoint
    public var head: GridPoint
    public var granularity: Granularity

    public init(anchor: GridPoint, head: GridPoint? = nil, granularity: Granularity = .character) {
        self.anchor = anchor
        self.head = head ?? anchor
        self.granularity = granularity
    }

    /// A plain click (no drag) selects nothing.
    public var isEmpty: Bool { granularity == .character && anchor == head }

    /// Ordered, snapped (start, end), inclusive. `line` returns a row's cells.
    public func resolved(cols: Int, line: (Int) -> [String]?) -> (start: GridPoint, end: GridPoint) {
        var (a, b) = anchor <= head ? (anchor, head) : (head, anchor)
        switch granularity {
        case .character:
            break
        case .word:
            if let cells = line(a.row) { a.col = WordBoundary.range(in: cells, at: a.col).lowerBound }
            if let cells = line(b.row) { b.col = WordBoundary.range(in: cells, at: b.col).upperBound }
        case .line:
            a.col = 0
            b.col = max(cols - 1, 0)
        }
        return (a, b)
    }
}

public enum WordBoundary {
    /// Characters that end a word. Everything else (including `/ . - _ ~ : @ ? = & % + #`)
    /// is part of one, so double-clicking a path or URL selects all of it.
    static let delimiters: Set<String> = [" ", "\t", "'", "\"", "`", "(", ")", "[", "]", "{", "}", "<", ">", "|", ";", ",", "│"]

    /// The run of same-class cells around `col`. "" (the second half of a wide
    /// character) belongs with the cell before it.
    public static func range(in cells: [String], at col: Int) -> ClosedRange<Int> {
        guard !cells.isEmpty else { return 0...0 }
        let col = max(0, min(col, cells.count - 1))
        func isWord(_ i: Int) -> Bool {
            var i = i
            while i > 0 && cells[i].isEmpty { i -= 1 }
            return !delimiters.contains(cells[i])
        }
        let target = isWord(col)
        var lo = col, hi = col
        // Delimiters select just themselves (except runs of spaces, which group).
        if !target && cells[col] != " " { return col...col }
        while lo > 0 && isWord(lo - 1) == target && (target || cells[lo - 1] == " ") { lo -= 1 }
        while hi < cells.count - 1 && isWord(hi + 1) == target && (target || cells[hi + 1] == " ") { hi += 1 }
        return lo...hi
    }
}
