import Foundation
import Testing
@testable import TermCore

@Suite struct ConfigTests {
    @Test func emptyIsDefaults() {
        let (c, d) = Config.parse("")
        #expect(c == Config())
        #expect(d.isEmpty)
    }

    @Test func templateParsesToDefaults() {
        let (c, d) = Config.parse(Config.template)
        #expect(d.isEmpty)
        #expect(c == Config())
    }

    @Test func parsesValues() {
        let (c, d) = Config.parse("""
        # comment
        font-family = "JetBrains Mono"
        font-size = 14.5
        background = #101010
        foreground = c0c0c0
        palette = 1=#ff0000
        palette = 15 = #ffffff
        option-as-meta = left
        scrollback-limit = 5000
        cursor-style = bar
        cursor-blink = true
        quit-after-last-window-closed = yes
        """)
        #expect(d.isEmpty)
        #expect(c.fontFamily == "JetBrains Mono")
        #expect(c.fontSize == 14.5)
        #expect(c.palette.background == RGB(hex: 0x101010))
        #expect(c.palette.foreground == RGB(hex: 0xC0C0C0))
        #expect(c.palette.indexed[1] == RGB(hex: 0xFF0000))
        #expect(c.palette.indexed[15] == RGB(hex: 0xFFFFFF))
        #expect(c.palette.indexed[196] == RGB(255, 0, 0)) // cube untouched
        #expect(c.optionAsMeta == .left)
        #expect(c.scrollbackLimit == 5000)
        #expect(c.cursorStyle == .bar && c.cursorBlink)
        #expect(c.quitAfterLastWindowClosed)
    }

    @Test func reportsErrorsWithLineNumbersAndKeepsGoing() {
        let (c, d) = Config.parse("""
        font-size = huge
        nonsense
        background = #12345
        colour = red
        palette = 16=#000000
        font-size = 15
        """)
        #expect(d.map(\.line) == [1, 2, 3, 4, 5])
        #expect(c.fontSize == 15)
        #expect(c.palette.background == Palette.default.background)
    }

    @Test func xdgConfigHome() {
        #expect(Config.directory(environment: ["XDG_CONFIG_HOME": "/tmp/x"]).path == "/tmp/x/lite")
        #expect(Config.directory(environment: [:]).path.hasSuffix("/.config/lite"))
    }
}
