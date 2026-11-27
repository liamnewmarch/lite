import Testing
@testable import TermCore

@Suite struct KeyBindingTests {
    private let modes = TerminalModes()

    private func binding(_ s: String) -> KeyBinding? {
        if case .success(let b) = KeyBinding.parse(s) { return b }
        return nil
    }

    @Test func cmdLetterToControlByte() throws {
        let b = try #require(binding("cmd+k = key:ctrl+k"))
        #expect(b.trigger == KeyChord(key: .character("k"), modifiers: .command))
        #expect(b.bytes(modes: modes) == [0x0B])
        #expect(binding("cmd+a=key:ctrl+a")?.bytes(modes: modes) == [0x01])
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
        #expect(binding("cmd+left = key:opt+b")?.bytes(modes: modes) == [0x1B, 0x62])
        #expect(binding("cmd+up = Key: ctrl+up")?.bytes(modes: modes) == Array("\u{1B}[1;5A".utf8))
        #expect(binding("cmd+j = key:shift+x")?.bytes(modes: modes) == Array("X".utf8))
        #expect(binding("cmd+e = key:enter")?.bytes(modes: modes) == [0x0D])
    }

    @Test func textActions() {
        #expect(binding("cmd+d = text:\\e[A")?.bytes(modes: modes) == Array("\u{1B}[A".utf8))
        #expect(binding("cmd+d = text:a=b\\x01\\n")?.bytes(modes: modes) == Array("a=b\u{01}\n".utf8))
    }

    @Test func errors() {
        #expect(binding("cmd+k") == nil)          // no action
        #expect(binding("cmd+k = key:cmd+j") == nil)  // programs never see cmd
        #expect(binding("cmd+k = text:\\q") == nil)
        #expect(binding("cmd+k = key:nonsense") == nil)
        // Bare words are reserved for named actions; a bare chord points at key:.
        if case .failure(let e) = KeyBinding.parse("cmd+k = ctrl+k") {
            #expect(e.message.contains("did you mean key:ctrl+k"))
        } else {
            Issue.record("a bare chord should be rejected")
        }
        let (c, d) = Config.parse("keybind = cmd+k = key:ctrl+k\nkeybind = nope\nkeybind = cmd+l = key:ctrl+l")
        #expect(c.keyBindings.count == 2)
        #expect(d.map(\.line) == [2])
    }
}
