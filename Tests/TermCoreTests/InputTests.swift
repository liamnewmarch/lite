import Foundation
import Synchronization
import Testing
@testable import TermCore

private func s(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

@Suite struct KeyModifierTests {
    let modes = TerminalModes()

    @Test func modifiedCursorKeys() {
        #expect(s(KeyEncoder.encode(.up, modifiers: .shift, modes: modes)) == "\u{1B}[1;2A")
        #expect(s(KeyEncoder.encode(.right, modifiers: .control, modes: modes)) == "\u{1B}[1;5C")
        #expect(s(KeyEncoder.encode(.home, modifiers: [.shift, .control], modes: modes)) == "\u{1B}[1;6H")
        #expect(s(KeyEncoder.encode(.pageUp, modifiers: .shift, modes: modes)) == "\u{1B}[5;2~")
    }

    @Test func optionArrowsMoveByWord() {
        #expect(s(KeyEncoder.encode(.left, modifiers: .option, modes: modes)) == "\u{1B}b")
        #expect(s(KeyEncoder.encode(.right, modifiers: .option, modes: modes)) == "\u{1B}f")
        // With other modifiers too, it's the regular xterm encoding.
        #expect(s(KeyEncoder.encode(.left, modifiers: [.option, .shift], modes: modes)) == "\u{1B}[1;4D")
    }

    @Test func functionKeys() {
        #expect(s(KeyEncoder.encode(.function(1), modes: modes)) == "\u{1B}OP")
        #expect(s(KeyEncoder.encode(.function(4), modifiers: .shift, modes: modes)) == "\u{1B}[1;2S")
        #expect(s(KeyEncoder.encode(.function(5), modes: modes)) == "\u{1B}[15~")
        #expect(s(KeyEncoder.encode(.function(12), modifiers: .control, modes: modes)) == "\u{1B}[24;5~")
    }

    @Test func metaAndSpecialBackspace() {
        #expect(s(KeyEncoder.encode(.text("x"), modifiers: .option, modes: modes)) == "\u{1B}x")
        #expect(KeyEncoder.encode(.backspace, modifiers: .option, modes: modes) == [0x1B, 0x7F])
        #expect(KeyEncoder.encode(.backspace, modifiers: .control, modes: modes) == [0x08])
        #expect(s(KeyEncoder.encode(.tab, modifiers: .shift, modes: modes)) == "\u{1B}[Z")
    }

    @Test func controlBytes() {
        #expect(KeyEncoder.controlByte(for: "c") == 0x03)
        #expect(KeyEncoder.controlByte(for: "A") == 0x01)
        #expect(KeyEncoder.controlByte(for: " ") == 0x00)
        #expect(KeyEncoder.controlByte(for: "[") == 0x1B)
        #expect(KeyEncoder.controlByte(for: "/") == 0x1F)
        #expect(KeyEncoder.controlByte(for: "é") == nil)
    }

    @Test func paste() {
        #expect(s(KeyEncoder.paste("a\nb\r\nc", bracketed: false)) == "a\rb\rc")
        #expect(s(KeyEncoder.paste("ls\n", bracketed: true)) == "\u{1B}[200~ls\r\u{1B}[201~")
        // An embedded end marker can't terminate the bracket early.
        #expect(s(KeyEncoder.paste("x\u{1B}[201~rm -rf /\n", bracketed: true)) == "\u{1B}[200~xrm -rf /\r\u{1B}[201~")
    }
}

@Suite struct SelectionTests {
    let cells = "cd ~/code/lite && ls (a,b)".map(String.init)

    @Test func wordIncludesPathCharacters() {
        #expect(WordBoundary.range(in: cells, at: 6) == 3...13)   // "~/code/lite"
        #expect(WordBoundary.range(in: cells, at: 0) == 0...1)    // "cd"
        #expect(WordBoundary.range(in: cells, at: 20) == 20...20) // "(" alone
    }

    @Test func wideTrailerBelongsToItsCharacter() {
        let wide = ["日", "", "本", "", " ", "x"]
        #expect(WordBoundary.range(in: wide, at: 1) == 0...3)
    }

    @Test func resolvesOrderAndGranularity() {
        let line: (Int) -> [String]? = { _ in self.cells }
        var sel = TextSelection(anchor: GridPoint(row: 5, col: 8), head: GridPoint(row: 5, col: 4))
        var r = sel.resolved(cols: 30, line: line)
        #expect(r.start == GridPoint(row: 5, col: 4) && r.end == GridPoint(row: 5, col: 8))
        sel.granularity = .word
        r = sel.resolved(cols: 30, line: line)
        #expect(r.start.col == 3 && r.end.col == 13)
        sel.granularity = .line
        r = sel.resolved(cols: 30, line: line)
        #expect(r.start.col == 0 && r.end.col == 29)
        #expect(TextSelection(anchor: GridPoint(row: 1, col: 1)).isEmpty)
    }

    @Test func highlightContainment() {
        let h = SelectionHighlight(startCol: 5, startRow: 1, endCol: 2, endRow: 3)
        #expect(!h.contains(col: 4, row: 1) && h.contains(col: 5, row: 1))
        #expect(h.contains(col: 0, row: 2) && h.contains(col: 79, row: 2))
        #expect(h.contains(col: 2, row: 3) && !h.contains(col: 3, row: 3))
    }
}

@Suite struct ScrollbackTests {
    private func engine(rows: Int = 5, lines: Int) -> SwiftTermEngine {
        let e = SwiftTermEngine(cols: 20, rows: rows, events: .init())
        let text = (0..<lines).map { "line \($0)" }.joined(separator: "\r\n")
        Array(text.utf8).withUnsafeBytes { e.feed($0) }
        return e
    }

    @Test func scrollsBackAndForth() {
        let e = engine(lines: 20)
        var v = e.viewport
        #expect(v.offset == 0 && v.maxOffset == 15)
        e.scrollViewport(toOffset: 3)
        var g = GridSnapshot(cols: 0, rows: 0)
        e.snapshot(into: &g)
        #expect(e.viewport.offset == 3)
        #expect((0..<g.cols).compactMap { g.text(col: $0, row: 0) }.joined().hasPrefix("line 12"))
        #expect(!g.cursor.visible || g.cursor.row < 5)
        e.scrollViewport(toOffset: 999) // clamped
        #expect(e.viewport.offset == 15)
        e.scrollViewport(toOffset: 0)
        v = e.viewport
        #expect(v.offset == 0)
    }

    @Test func viewStaysPutWhileScrolledBack() {
        let e = engine(lines: 20)
        e.scrollViewport(toOffset: 5)
        let top = e.viewport.topRow
        Array("\r\nmore\r\noutput".utf8).withUnsafeBytes { e.feed($0) }
        #expect(e.viewport.topRow == top)
    }

    @Test func extractsTextAcrossLines() {
        let e = engine(lines: 20)
        let first = e.viewport.firstRow
        #expect(e.text(from: GridPoint(row: first, col: 0), to: GridPoint(row: first + 1, col: 19)) == "line 0\nline 1")
        #expect(e.text(from: GridPoint(row: first + 2, col: 5), to: GridPoint(row: first + 2, col: 5)) == "2")
    }

    @Test func softWrappedLinesJoinWithoutNewline() {
        let e = SwiftTermEngine(cols: 10, rows: 5, events: .init())
        Array("abcdefghijKLM".utf8).withUnsafeBytes { e.feed($0) }
        let first = e.viewport.firstRow
        #expect(e.line(absoluteRow: first)?.wrapsIntoNext == true)
        #expect(e.text(from: GridPoint(row: first, col: 0), to: GridPoint(row: first + 1, col: 9)) == "abcdefghijKLM")
    }

    @Test func mouseReportsUseSGRWhenRequested() {
        let replies = Mutex<[UInt8]>([])
        var events = TerminalEngineEvents()
        events.reply = { b in replies.withLock { $0 += b } }
        let e = SwiftTermEngine(cols: 20, rows: 5, events: events)
        e.sendMouse(MouseReport(kind: .press, col: 1, row: 1))
        #expect(replies.withLock { $0.isEmpty }) // not requested yet
        Array("\u{1B}[?1000h\u{1B}[?1006h".utf8).withUnsafeBytes { e.feed($0) } // normal tracking + SGR
        #expect(e.modes.mouseReporting && !e.modes.mouseDrag)
        e.sendMouse(MouseReport(kind: .press, col: 2, row: 3))
        e.sendMouse(MouseReport(kind: .release, col: 2, row: 3))
        e.sendMouse(MouseReport(kind: .scrollUp, col: 0, row: 0))
        #expect(s(replies.withLock { $0 }) == "\u{1B}[<0;3;4M\u{1B}[<0;3;4m\u{1B}[<64;1;1M")
    }
}
