import Foundation

/// Turns key presses into the bytes a terminal program expects (xterm conventions).
/// AppKit-free so it's unit-testable; `TerminalView` maps `NSEvent`s to `Key`.
///
/// Modifier encoding (xterm "modifyCursorKeys"): special keys with modifiers send
/// `CSI 1 ; m X` or `CSI n ; m ~`, where m = 1 + Shift(1) + Alt/Option(2) + Ctrl(4).
public enum KeyEncoder {
    public enum Key: Sendable, Equatable {
        /// Composed text (from typing or the input method).
        case text(String)
        case enter, backspace, tab, backtab, escape
        case up, down, left, right
        case home, end, pageUp, pageDown, insert, forwardDelete
        /// F1…F12.
        case function(Int)
    }

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        /// Option acting as Alt/Meta (for text, only when Option-as-Meta is on).
        public static let option = Modifiers(rawValue: 2)
        public static let control = Modifiers(rawValue: 4)

        /// xterm's modifier parameter.
        var parameter: Int { 1 + Int(rawValue & 7) }
    }

    private static let esc: UInt8 = 0x1B

    public static func encode(_ key: Key, modifiers: Modifiers = [], modes: TerminalModes) -> [UInt8] {
        func csi(_ s: String) -> [UInt8] { [esc, 0x5B] + Array(s.utf8) }  // ESC [
        func ss3(_ s: String) -> [UInt8] { [esc, 0x4F] + Array(s.utf8) }  // ESC O
        let m = modifiers.parameter
        let meta: [UInt8] = modifiers.contains(.option) ? [esc] : []

        // Arrows/Home/End: SS3 in application cursor mode (vim, less…), else CSI;
        // with modifiers always CSI 1;m X.
        func cursorKey(_ final: String) -> [UInt8] {
            if m > 1 { return csi("1;\(m)\(final)") }
            return modes.applicationCursor ? ss3(final) : csi(final)
        }
        func tildeKey(_ n: Int) -> [UInt8] { m > 1 ? csi("\(n);\(m)~") : csi("\(n)~") }

        switch key {
        case .text(let s):
            return meta + Array(s.utf8)
        case .enter:
            return meta + [0x0D]                 // CR; the tty turns it into NL for the program
        case .backspace:
            if modifiers.contains(.control) { return meta + [0x08] }
            return meta + [0x7F]                 // Option-Backspace = ESC DEL: delete word in shells
        case .tab:
            return modifiers.contains(.shift) ? csi("Z") : meta + [0x09]
        case .backtab:
            return csi("Z")
        case .escape:
            return meta + [esc]
        case .up: return cursorKey("A")
        case .down: return cursorKey("B")
        case .right:
            // Option-Right/Left = word movement, the macOS convention (Terminal.app, iTerm).
            if modifiers == .option { return [esc, UInt8(ascii: "f")] }
            return cursorKey("C")
        case .left:
            if modifiers == .option { return [esc, UInt8(ascii: "b")] }
            return cursorKey("D")
        case .home: return cursorKey("H")
        case .end: return cursorKey("F")
        case .pageUp: return tildeKey(5)
        case .pageDown: return tildeKey(6)
        case .insert: return tildeKey(2)
        case .forwardDelete: return tildeKey(3)
        case .function(let n):
            switch n {
            case 1...4:
                let final = ["P", "Q", "R", "S"][n - 1]
                return m > 1 ? csi("1;\(m)\(final)") : ss3(final)
            case 5...12:
                return tildeKey([15, 17, 18, 19, 20, 21, 23, 24][n - 5])
            default:
                return []
            }
        }
    }

    /// Ctrl + key → control byte (Ctrl-A = 0x01 … Ctrl-Z = 0x1A, Ctrl-[ = ESC, Ctrl-Space = NUL…).
    /// `base` is the key without modifiers (e.g. NSEvent.charactersIgnoringModifiers).
    public static func controlByte(for base: String) -> UInt8? {
        guard base.unicodeScalars.count == 1, let v = base.unicodeScalars.first?.value, v < 128 else { return nil }
        switch UInt8(v) {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return UInt8(v) - 0x60
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return UInt8(v) - 0x40
        case UInt8(ascii: " "), UInt8(ascii: "@"), UInt8(ascii: "2"): return 0x00
        case UInt8(ascii: "["), UInt8(ascii: "3"): return 0x1B
        case UInt8(ascii: "\\"), UInt8(ascii: "4"): return 0x1C
        case UInt8(ascii: "]"), UInt8(ascii: "5"): return 0x1D
        case UInt8(ascii: "^"), UInt8(ascii: "6"): return 0x1E
        case UInt8(ascii: "_"), UInt8(ascii: "/"), UInt8(ascii: "-"), UInt8(ascii: "7"): return 0x1F
        case UInt8(ascii: "?"), UInt8(ascii: "8"): return 0x7F
        default: return nil
        }
    }

    /// Bytes for pasting `text`. Newlines become CR (what pressing Return sends).
    /// In bracketed-paste mode the text is wrapped in `ESC[200~ … ESC[201~` so the
    /// shell inserts it instead of running each line; any end marker inside the
    /// text is removed so a paste can't break out of the bracket.
    public static func paste(_ text: String, bracketed: Bool) -> [UInt8] {
        var t = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        guard bracketed else { return Array(t.utf8) }
        t = t.replacingOccurrences(of: "\u{1B}[201~", with: "")
        return Array("\u{1B}[200~".utf8) + Array(t.utf8) + Array("\u{1B}[201~".utf8)
    }
}
