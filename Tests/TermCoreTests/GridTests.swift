import Testing
@testable import TermCore

@Suite struct GridTests {
    @Test func wideCharacterUsesTwoCells() {
        var g = GridSnapshot(cols: 10, rows: 1)
        let next = g.put("a日b", col: 0, row: 0)
        #expect(next == 4)
        #expect(g[1, 0].attrs.contains(.wide))
        #expect(g[2, 0].attrs.contains(.wideTrailer))
        #expect(g[3, 0].scalar == UInt32(("b" as Unicode.Scalar).value))
    }

    @Test func clustersGoToSideTable() {
        var g = GridSnapshot(cols: 10, rows: 1)
        g.put("👍🏽", col: 0, row: 0)
        #expect(g[0, 0].cluster == 1)
        #expect(g.text(col: 0, row: 0) == "👍🏽")
        #expect(g.text(col: 2, row: 0) == nil)
    }

    @Test func wideCharacterDoesNotSplitAtEdge() {
        var g = GridSnapshot(cols: 3, rows: 1)
        let next = g.put("ab日", col: 0, row: 0)
        #expect(next == 2)
        #expect(g[2, 0] == .blank)
    }

    @Test func paletteMatchesXtermTables() {
        let p = Palette.default
        #expect(p.indexed.count == 256)
        #expect(p.resolve(.indexed(196), foreground: true) == RGB(255, 0, 0))
        #expect(p.resolve(.indexed(232), foreground: true) == RGB(8, 8, 8))
        #expect(p.resolve(.indexed(255), foreground: true) == RGB(238, 238, 238))
        #expect(p.resolve(.default, foreground: false) == p.background)
        #expect(p.resolve(.rgb(1, 2, 3), foreground: true) == RGB(1, 2, 3))
    }
}
