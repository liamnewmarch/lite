import Foundation
import SwiftTerm

/// `TerminalEngine` backed by SwiftTerm's `Terminal` (parser + buffers only; none of
/// SwiftTerm's views or its PTY code). This is the only file that imports SwiftTerm.
///
/// Locking: SwiftTerm's own `terminalLock` (FIFO-fair, so a busy PTY thread can't
/// starve the main thread) guards all access. Delegate callbacks run with that
/// lock held, so they only touch our own fields or hop elsewhere asynchronously.
public final class SwiftTermEngine: TerminalEngine, @unchecked Sendable {
    private let terminal: Terminal
    private let delegate: Delegate // Terminal holds its delegate weakly

    // Guarded by terminal.terminalLock:
    private var needsFullSnapshot = true

    public init(cols: Int, rows: Int, scrollback: Int = 10_000,
                cursorStyle: CursorState.Style = .block, cursorBlink: Bool = false,
                events: TerminalEngineEvents) {
        delegate = Delegate(events: events)
        delegate.cursorStyle = cursorStyle == .hollowBlock ? .block : cursorStyle
        delegate.cursorBlinking = cursorBlink
        var options = TerminalOptions.default
        options.cols = max(cols, 1)
        options.rows = max(rows, 1)
        options.scrollback = scrollback
        options.termName = "xterm-256color"
        // The style programs get back on DECSCUSR 0 ("reset to default").
        options.cursorStyle = switch (cursorStyle, cursorBlink) {
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        case (_, true): .blinkBlock
        case (_, false): .steadyBlock
        }
        terminal = Terminal(delegate: delegate, options: options)
    }

    public var cols: Int { terminal.terminalLock.withLock { terminal.cols } }
    public var rows: Int { terminal.terminalLock.withLock { terminal.rows } }

    public func feed(_ bytes: UnsafeRawBufferPointer) {
        let slice = ArraySlice(bytes.bindMemory(to: UInt8.self))
        terminal.terminalLock.withLock { terminal.feed(buffer: slice) }
    }

    public func resize(cols: Int, rows: Int) {
        terminal.terminalLock.withLock {
            terminal.resize(cols: max(cols, 1), rows: max(rows, 1))
            needsFullSnapshot = true
        }
    }

    public var modes: TerminalModes {
        terminal.terminalLock.withLock {
            var m = TerminalModes()
            m.applicationCursor = terminal.applicationCursor
            m.bracketedPaste = terminal.bracketedPasteMode
            m.alternateScreen = terminal.isCurrentBufferAlternate
            let mouse = terminal.mouseMode
            m.mouseReporting = mouse != .off
            m.mouseDrag = mouse.sendButtonTracking()
            m.mouseMotion = mouse.sendMotionEvent()
            return m
        }
    }

    @discardableResult
    public func snapshot(into grid: inout GridSnapshot) -> Bool {
        terminal.terminalLock.withLock {
            let cols = terminal.cols, rows = terminal.rows
            var changedRows: ClosedRange<Int>?
            if needsFullSnapshot || grid.cols != cols || grid.rows != rows {
                grid = GridSnapshot(cols: cols, rows: rows)
                changedRows = rows > 0 ? 0...(rows - 1) : nil
                needsFullSnapshot = false
            } else if let r = terminal.getUpdateRange() {
                let lo = max(0, r.startY), hi = min(rows - 1, r.endY)
                changedRows = lo <= hi ? lo...hi : nil
            }
            terminal.clearUpdateRange()

            if let changedRows {
                for row in changedRows { convertRow(row, cols: cols, into: &grid) }
            }

            let old = grid.cursor
            let pos = terminal.getCursorLocation()
            // The cursor is relative to the live screen; when scrolled back by `offset`
            // rows it moves down the view, and off it entirely past the bottom.
            let viewRow = pos.y + terminal.liteViewport.offset
            grid.cursor = CursorState(
                col: min(max(pos.x, 0), cols - 1),
                row: min(max(viewRow, 0), rows - 1),
                visible: delegate.cursorVisible && viewRow < rows, // DECTCEM, or scrolled off
                style: delegate.cursorStyle,
                blinking: delegate.cursorBlinking
            )
            return changedRows != nil || grid.cursor != old
        }
    }

    // MARK: - Scrollback

    public var viewport: Viewport {
        terminal.terminalLock.withLock {
            let v = terminal.liteViewport
            return Viewport(offset: v.offset, maxOffset: v.maxOffset, topRow: v.topRow,
                            firstRow: v.firstRow, endRow: v.endRow)
        }
    }

    public func scrollViewport(toOffset offset: Int) {
        terminal.terminalLock.withLock { terminal.liteScrollViewport(toOffset: offset) }
    }

    // MARK: - Text

    public func line(absoluteRow: Int) -> (cells: [String], wrapsIntoNext: Bool)? {
        terminal.terminalLock.withLock { lineLocked(absoluteRow) }
    }

    public func text(from start: GridPoint, to end: GridPoint) -> String {
        terminal.terminalLock.withLock {
            let (a, b) = start <= end ? (start, end) : (end, start)
            var out = ""
            var row = a.row
            while row <= b.row {
                guard let (cells, wraps) = lineLocked(row) else { row += 1; continue }
                let lo = row == a.row ? max(0, a.col) : 0
                let hi = row == b.row ? min(cells.count - 1, b.col) : cells.count - 1
                var piece = lo <= hi ? cells[lo...hi].joined() : ""
                let continues = wraps && row != b.row
                if !continues {
                    while piece.last == " " { piece.removeLast() }
                }
                out += piece
                if row != b.row && !continues { out += "\n" }
                row += 1
            }
            return out
        }
    }

    private func lineLocked(_ absoluteRow: Int) -> (cells: [String], wrapsIntoNext: Bool)? {
        guard let line = terminal.getScrollInvariantLine(row: absoluteRow) else { return nil }
        var cells: [String] = []
        cells.reserveCapacity(line.count)
        var previousWide = false
        for col in 0..<line.count {
            let cd = line[col]
            if cd.width == 0 && previousWide {
                cells.append("")
            } else {
                let t = cd.getText()
                cells.append(t == "\0" || t.isEmpty ? " " : t)
            }
            previousWide = cd.width == 2
        }
        let wraps = terminal.getScrollInvariantLine(row: absoluteRow + 1)?.isWrapped ?? false
        return (cells, wraps)
    }

    // MARK: - Mouse reporting

    public func sendMouse(_ e: MouseReport) {
        terminal.terminalLock.withLock {
            let mode = terminal.mouseMode
            var flags: Int
            switch e.kind {
            case .press:
                guard mode.sendButtonPress() else { return }
                flags = terminal.encodeButton(button: e.button, release: false, shift: e.shift, meta: e.option, control: e.control)
            case .release:
                guard mode.sendButtonRelease() else { return }
                flags = terminal.encodeButton(button: e.button, release: true, shift: e.shift, meta: e.option, control: e.control)
            case .drag:
                guard mode.sendButtonTracking() else { return }
                flags = terminal.encodeButton(button: e.button, release: false, shift: e.shift, meta: e.option, control: e.control) | 32
            case .move:
                guard mode.sendMotionEvent() else { return }
                // "No button" (3) + motion (32), plus modifier bits.
                flags = (terminal.encodeButton(button: 0, release: false, shift: e.shift, meta: e.option, control: e.control) & ~3) | 3 | 32
            case .scrollUp, .scrollDown:
                guard mode.sendButtonPress() else { return }
                flags = terminal.encodeButton(button: e.kind == .scrollUp ? 4 : 5, release: false,
                                              shift: e.shift, meta: e.option, control: e.control)
            }
            let col = max(0, min(e.col, terminal.cols - 1)), row = max(0, min(e.row, terminal.rows - 1))
            terminal.sendEvent(buttonFlags: flags, x: col, y: row) // reply → Delegate.send → PTY
        }
    }

    // MARK: - Conversion (lock held)

    private func convertRow(_ row: Int, cols: Int, into grid: inout GridSnapshot) {
        grid.clearClusters(row: row)
        guard let line = terminal.getLine(row: row) else {
            for col in 0..<cols { grid[col, row] = .blank }
            return
        }
        let count = min(cols, line.count)
        var previousWide = false
        for col in 0..<count {
            let cd = line[col]
            let attr = cd.attribute
            var attrs = Self.attributes(attr)
            let width = cd.width
            if width == 2 {
                attrs.insert(.wide)
            } else if width == 0 && previousWide {
                attrs.insert(.wideTrailer)
            }
            previousWide = width == 2

            var cell = Cell(fg: Self.color(attr.fg), bg: Self.color(attr.bg), attrs: attrs)
            if !attrs.contains(.wideTrailer) {
                // getText() is the only public accessor; for single scalars it's an
                // inline small String (no allocation).
                let text = cd.getText()
                let scalars = text.unicodeScalars
                cell.scalar = scalars.first?.value ?? 0
                if !cd.isSimpleRune && scalars.count > 1 {
                    cell.cluster = 1
                    grid.clusters[row * cols + col] = text
                }
            }
            grid[col, row] = cell
        }
        for col in count..<cols { grid[col, row] = .blank }
    }

    private static func color(_ c: Attribute.Color) -> TermColor {
        switch c {
        case .defaultColor: .default
        case .defaultInvertedColor: .defaultInverted
        case .ansi256(let code): .indexed(code)
        case .trueColor(let r, let g, let b): .rgb(r, g, b)
        }
    }

    private static func attributes(_ attr: Attribute) -> CellAttributes {
        let s = attr.style
        var a: CellAttributes = []
        if s.contains(.bold) { a.insert(.bold) }
        if s.contains(.italic) { a.insert(.italic) }
        if s.contains(.underline) || attr.underlineStyle != .none { a.insert(.underline) }
        if s.contains(.crossedOut) { a.insert(.strikethrough) }
        if s.contains(.inverse) { a.insert(.inverse) }
        if s.contains(.dim) { a.insert(.dim) }
        if s.contains(.invisible) { a.insert(.invisible) }
        return a
    }

    // MARK: - Delegate

    /// Receives SwiftTerm callbacks (with the terminal lock held).
    private final class Delegate: TerminalDelegate {
        let events: TerminalEngineEvents
        var cursorVisible = true
        var cursorStyle: CursorState.Style = .block
        var cursorBlinking = false

        init(events: TerminalEngineEvents) { self.events = events }

        func send(source: Terminal, data: ArraySlice<UInt8>) { events.reply(Array(data)) }
        func setTerminalTitle(source: Terminal, title: String) { events.title(title) }
        func bell(source: Terminal) { events.bell() }
        func showCursor(source: Terminal) { cursorVisible = true }
        func hideCursor(source: Terminal) { cursorVisible = false }
        func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
            switch newStyle {
            case .blinkBlock, .steadyBlock: cursorStyle = .block
            case .blinkUnderline, .steadyUnderline: cursorStyle = .underline
            case .blinkBar, .steadyBar: cursorStyle = .bar
            }
            switch newStyle {
            case .blinkBlock, .blinkUnderline, .blinkBar: cursorBlinking = true
            case .steadyBlock, .steadyUnderline, .steadyBar: cursorBlinking = false
            }
        }
    }
}
