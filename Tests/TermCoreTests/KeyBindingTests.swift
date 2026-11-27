import Testing
@testable import TermCore

@Suite struct KeyBindingTests {
    private let modes = TerminalModes()

    private func binding(_ s: String) -> KeyBinding? {
        if case .success(let b) = KeyBinding.parse(s) { return b }
        return nil
    }

    @Test func cmdLetterToControlByte() throws {
        let b = try #require(binding("cmd+k = ctrl+k"))
        #expect(b.trigger == KeyChord(key: .character("k"), modifiers: .command))
        #expect(b.bytes(modes: modes) == [0x0B])
        #expect(binding("cmd+a=ctrl+a")?.bytes(modes: modes) == [0x01])
    }

    @Test func chordSyntax() {
        #expect(KeyChord("Command+Shift+K") == KeyChord(key: .character("k"), modifiers: [.command, .shift]))
        #expect(KeyChord("opt+plus") == KeyChord(key: .character("+"), modifiers: .option))
        #expect(KeyChord("cmd+f5") == KeyChord(key: .special(.function(5)), modifiers: .command))
        #expect(KeyChord("ctrl+space") == KeyChord(key: .character(" "), modifiers: .control))
        #expect(KeyChord("hyper+k") == nil)
        #expect(KeyChord("cmd+") == nil)
        #expect(KeyChord("cmd+nonsense") == nil)
    }

    @Test func keyActions() {
        #expect(binding("cmd+left = opt+b")?.bytes(modes: modes) == [0x1B, 0x62])
        #expect(binding("cmd+up = ctrl+up")?.bytes(modes: modes) == Array("\u{1B}[1;5A".utf8))
        #expect(binding("cmd+j = shift+x")?.bytes(modes: modes) == Array("X".utf8))
        #expect(binding("cmd+e = enter")?.bytes(modes: modes) == [0x0D])
    }

    @Test func textActions() {
        #expect(binding("cmd+d = text:\\e[A")?.bytes(modes: modes) == Array("\u{1B}[A".utf8))
        #expect(binding("cmd+d = text:a=b\\x01\\n")?.bytes(modes: modes) == Array("a=b\u{01}\n".utf8))
    }

    @Test func errors() {
        #expect(binding("cmd+k") == nil)          // no action
        #expect(binding("cmd+k = cmd+j") == nil)  // programs never see cmd
        #expect(binding("cmd+k = text:\\q") == nil)
        let (c, d) = Config.parse("keybind = cmd+k = ctrl+k\nkeybind = nope\nkeybind = cmd+l = ctrl+l")
        #expect(c.keyBindings.count == 2)
        #expect(d.map(\.line) == [2])
    }
}
