import Foundation
import Synchronization
import Testing
@testable import TermCore

private func feed(_ engine: SwiftTermEngine, _ s: String) {
    Array(s.utf8).withUnsafeBytes { engine.feed($0) }
}

private func rowText(_ g: GridSnapshot, _ row: Int) -> String {
    (0..<g.cols).map { g.text(col: $0, row: row) ?? " " }.joined()
        .replacingOccurrences(of: "\0", with: " ")
        .trimmingCharacters(in: .whitespaces)
}

@Suite struct SwiftTermEngineTests {
    @Test func plainTextAndCursor() {
        let e = SwiftTermEngine(cols: 20, rows: 5, events: .init())
        feed(e, "hello\r\nworld")
        var g = GridSnapshot(cols: 0, rows: 0)
        #expect(e.snapshot(into: &g))
        #expect(g.cols == 20 && g.rows == 5)
        #expect(rowText(g, 0) == "hello")
        #expect(rowText(g, 1) == "world")
        #expect(g.cursor.col == 5 && g.cursor.row == 1 && g.cursor.visible)
    }

    @Test func colorsAndStyles() {
        let e = SwiftTermEngine(cols: 20, rows: 2, events: .init())
        feed(e, "\u{1B}[1;31mA\u{1B}[0m\u{1B}[38;5;200mB\u{1B}[48;2;1;2;3mC\u{1B}[0m\u{1B}[3;4;9mD\u{1B}[7mE")
        var g = GridSnapshot(cols: 0, rows: 0)
        e.snapshot(into: &g)
        #expect(g[0, 0].fg == .indexed(1) && g[0, 0].attrs.contains(.bold))
        #expect(g[1, 0].fg == .indexed(200) && g[1, 0].attrs.isEmpty)
        #expect(g[2, 0].bg == .rgb(1, 2, 3))
        #expect(g[3, 0].attrs.isSuperset(of: [.italic, .underline, .strikethrough]))
        #expect(g[4, 0].attrs.contains(.inverse))
    }

    @Test func wideCharactersAndClusters() {
        let e = SwiftTermEngine(cols: 10, rows: 1, events: .init())
        feed(e, "日a👍🏽")
        var g = GridSnapshot(cols: 0, rows: 0)
        e.snapshot(into: &g)
        #expect(g[0, 0].attrs.contains(.wide))
        #expect(g[1, 0].attrs.contains(.wideTrailer))
        #expect(g.text(col: 2, row: 0) == "a")
        #expect(g.text(col: 3, row: 0) == "👍🏽")
        #expect(g[3, 0].attrs.contains(.wide))
    }

    @Test func incrementalSnapshotReportsNoChangeWhenIdle() {
        let e = SwiftTermEngine(cols: 10, rows: 3, events: .init())
        feed(e, "x")
        var g = GridSnapshot(cols: 0, rows: 0)
        #expect(e.snapshot(into: &g))
        #expect(!e.snapshot(into: &g))
        feed(e, "\r\n\r\nz")
        #expect(e.snapshot(into: &g))
        #expect(rowText(g, 0) == "x")
        #expect(rowText(g, 2) == "z")
    }

    @Test func resizeRebuildsGrid() {
        let e = SwiftTermEngine(cols: 10, rows: 3, events: .init())
        feed(e, "abc")
        var g = GridSnapshot(cols: 0, rows: 0)
        e.snapshot(into: &g)
        e.resize(cols: 30, rows: 8)
        #expect(e.snapshot(into: &g))
        #expect(g.cols == 30 && g.rows == 8)
        #expect(rowText(g, 0) == "abc")
    }

    @Test func modesAndCursorVisibility() {
        let e = SwiftTermEngine(cols: 10, rows: 3, events: .init())
        #expect(!e.modes.applicationCursor && !e.modes.bracketedPaste && !e.modes.alternateScreen)
        feed(e, "\u{1B}[?1h\u{1B}[?2004h\u{1B}[?1049h\u{1B}[?25l")
        let m = e.modes
        #expect(m.applicationCursor && m.bracketedPaste && m.alternateScreen)
        var g = GridSnapshot(cols: 0, rows: 0)
        e.snapshot(into: &g)
        #expect(!g.cursor.visible)
    }

    @Test func repliesAndTitleAreReported() {
        let replies = Mutex<[UInt8]>([])
        let title = Mutex("")
        var events = TerminalEngineEvents()
        events.reply = { bytes in replies.withLock { $0 += bytes } }
        events.title = { t in title.withLock { $0 = t } }
        let e = SwiftTermEngine(cols: 10, rows: 3, events: events)
        feed(e, "\u{1B}[c\u{1B}]0;hello\u{07}") // Primary Device Attributes + set title
        let reply = replies.withLock { String(decoding: $0, as: UTF8.self) }
        #expect(reply.hasPrefix("\u{1B}[?"))
        #expect(title.withLock { $0 } == "hello")
    }
}

@Suite struct KeyEncoderTests {
    private func enc(_ k: KeyEncoder.Key, app: Bool = false) -> String {
        var m = TerminalModes()
        m.applicationCursor = app
        return String(decoding: KeyEncoder.encode(k, modes: m), as: UTF8.self)
    }

    @Test func basics() {
        #expect(enc(.text("hé")) == "hé")
        #expect(enc(.enter) == "\r")
        #expect(enc(.backspace) == "\u{7F}")
        #expect(enc(.tab) == "\t")
        #expect(enc(.backtab) == "\u{1B}[Z")
        #expect(enc(.forwardDelete) == "\u{1B}[3~")
        #expect(enc(.pageUp) == "\u{1B}[5~")
    }

    @Test func arrowsFollowApplicationCursorMode() {
        #expect(enc(.up) == "\u{1B}[A")
        #expect(enc(.left) == "\u{1B}[D")
        #expect(enc(.up, app: true) == "\u{1B}OA")
        #expect(enc(.home, app: true) == "\u{1B}OH")
    }
}

