import AppKit
import TermCore

/// Keyboard input.
///
/// Two paths:
/// 1. Keys with a fixed terminal encoding (arrows, F-keys, Return, Ctrl-combos,
///    Option-as-Meta…) are encoded directly by `KeyEncoder`.
/// 2. Everything else goes through `interpretKeyEvents`, i.e. the macOS text
///    input system, which calls back into the `NSTextInputClient` methods below.
///    That's what makes input methods (Chinese/Japanese/Korean), dead keys
///    (Option-E then E = é) and the emoji picker work.
///
/// While a composition is in progress (`markedText` non-empty) *every* key goes to
/// the input system, so e.g. Return confirms a candidate instead of reaching the shell.
extension TerminalView: @MainActor NSTextInputClient {
    override func keyDown(with event: NSEvent) {
        guard session != nil else { return }
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }
        if let bytes = directEncoding(for: event) {
            send(bytes)
            return
        }
        interpretKeyEvents([event])
    }

    /// Sends input to the program: snaps the view back to the live screen and
    /// restarts the cursor blink, like every terminal.
    func send(_ bytes: [UInt8]) {
        guard let session, !bytes.isEmpty else { return }
        if session.engine.viewport.offset > 0 {
            session.engine.scrollViewport(toOffset: 0)
            setNeedsRender()
        }
        resetBlink()
        session.write(bytes)
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    // MARK: - Direct encoding

    private func directEncoding(for event: NSEvent) -> [UInt8]? {
        guard let session else { return nil }
        let flags = event.modifierFlags
        let modes = session.modes
        let metaOption = flags.contains(.option) && optionIsMeta(event)

        var mods: KeyEncoder.Modifiers = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }

        // Special keys: Option always counts as Alt here (there's nothing to compose).
        if let key = specialKey(event) {
            if flags.contains(.option) { mods.insert(.option) }
            return KeyEncoder.encode(key, modifiers: mods, modes: modes)
        }

        // Ctrl-letter etc. → control byte (plus ESC if Option is Meta).
        if flags.contains(.control), let base = event.charactersIgnoringModifiers,
           let byte = KeyEncoder.controlByte(for: base) {
            return (metaOption ? [0x1B] : []) + [byte]
        }

        // Option-as-Meta: ESC + the unmodified character (Shift still applies).
        if metaOption, let base = event.charactersIgnoringModifiers, !base.isEmpty {
            return KeyEncoder.encode(.text(base), modifiers: .option, modes: modes)
        }
        return nil // plain text → input system
    }

    private func specialKey(_ event: NSEvent) -> KeyEncoder.Key? {
        if event.keyCode == 53 { return .escape } // no NSEvent.SpecialKey for Escape
        switch event.specialKey {
        case .upArrow?: return .up
        case .downArrow?: return .down
        case .leftArrow?: return .left
        case .rightArrow?: return .right
        case .home?: return .home
        case .end?: return .end
        case .pageUp?: return .pageUp
        case .pageDown?: return .pageDown
        case .insert?, .help?: return .insert
        case .deleteForward?: return .forwardDelete
        case .delete?, .backspace?: return .backspace
        case .carriageReturn?, .enter?, .newline?: return .enter
        case .tab?: return .tab
        case .backTab?: return .backtab
        case .f1?: return .function(1)
        case .f2?: return .function(2)
        case .f3?: return .function(3)
        case .f4?: return .function(4)
        case .f5?: return .function(5)
        case .f6?: return .function(6)
        case .f7?: return .function(7)
        case .f8?: return .function(8)
        case .f9?: return .function(9)
        case .f10?: return .function(10)
        case .f11?: return .function(11)
        case .f12?: return .function(12)
        default: return nil
        }
    }

    /// Whether the Option key held for this event acts as Meta. The device-specific
    /// bits in `modifierFlags` (from IOKit's NX_DEVICE*ALTKEYMASK) tell left from right.
    private func optionIsMeta(_ event: NSEvent) -> Bool {
        let raw = event.modifierFlags.rawValue
        let left = raw & 0x20 != 0, right = raw & 0x40 != 0
        switch optionAsMeta {
        case .none: return false
        case .both: return true
        case .left: return left
        case .right: return right
        }
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let hadMarked = hasMarkedText()
        markedText = ""
        if hadMarked { setNeedsRender() }
        guard !text.isEmpty else { return }
        send(KeyEncoder.encode(.text(text), modes: session?.modes ?? TerminalModes()))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        setNeedsRender()
    }

    func unmarkText() {
        markedText = ""
        setNeedsRender()
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: (markedText as NSString).length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Where the IME candidate window should appear: at the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        screenRect(col: grid.cursor.col, row: grid.cursor.row)
    }

    /// Commands the input system produces for keys it doesn't turn into text. Most
    /// are already handled by `directEncoding`; this covers the rest without beeping.
    override func doCommand(by selector: Selector) {
        let modes = session?.modes ?? TerminalModes()
        switch selector {
        case #selector(insertNewline(_:)), #selector(insertLineBreak(_:)):
            send(KeyEncoder.encode(.enter, modes: modes))
        case #selector(insertTab(_:)):
            send(KeyEncoder.encode(.tab, modes: modes))
        case #selector(insertBacktab(_:)):
            send(KeyEncoder.encode(.backtab, modes: modes))
        case #selector(deleteBackward(_:)):
            send(KeyEncoder.encode(.backspace, modes: modes))
        case #selector(cancelOperation(_:)):
            send(KeyEncoder.encode(.escape, modes: modes))
        default:
            break
        }
    }
}
