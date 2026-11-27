/// User key bindings (`keybind = <trigger> = <action>` in the config): a shortcut that
/// sends something to the program instead of its usual meaning, e.g. Cmd-K → Ctrl-K.
///
/// Actions are prefixed: `key:ctrl+k` sends a key combination, `text:…` literal text.
/// Bare words are reserved for named actions (none yet).
///
/// Triggers and key actions are written like `cmd+shift+k`: modifiers (`cmd`, `ctrl`,
/// `opt`, `shift`, with long forms) then one key, either a character or a name
/// (`up`, `enter`, `f5`, `space`, `plus`, `equal`…).
public struct KeyBinding: Sendable, Equatable {
    public var trigger: KeyChord
    public var action: Action

    public enum Action: Sendable, Equatable {
        /// `key:` — send what pressing this key combination would send (it can't include Cmd).
        case keys(KeyChord)
        /// `text:` — send these characters as they are (`text:` with \e, \xNN, \n, \r, \t, \\ escapes).
        case text(String)
    }

    public init(trigger: KeyChord, action: Action) {
        self.trigger = trigger
        self.action = action
    }

    /// The bytes to send, given the program's current modes (arrows depend on them).
    public func bytes(modes: TerminalModes) -> [UInt8] {
        switch action {
        case .text(let s): return Array(s.utf8)
        case .keys(let chord): return chord.encoded(modes: modes)
        }
    }

    /// Parses the value of a `keybind` line: `<trigger> = <action>`.
    public static func parse(_ value: String) -> Result<KeyBinding, ParseError> {
        guard let eq = value.firstIndex(of: "=") else {
            return .failure(.init("expected <trigger> = <action>, e.g. cmd+k = key:ctrl+k"))
        }
        let triggerText = value[..<eq].trimmingCharacters(in: .whitespaces)
        let actionText = value[value.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard let trigger = KeyChord(triggerText) else {
            return .failure(.init("unrecognised shortcut \"\(triggerText)\""))
        }
        if actionText.lowercased().hasPrefix("text:") {
            guard let text = unescape(String(actionText.dropFirst(5))) else {
                return .failure(.init("bad escape in \"\(actionText)\" (use \\e, \\xNN, \\n, \\r, \\t or \\\\)"))
            }
            return .success(KeyBinding(trigger: trigger, action: .text(text)))
        }
        // Every action has a prefix, so bare words stay free for named actions later
        // (e.g. `new_tab`).
        guard actionText.lowercased().hasPrefix("key:") else {
            let hint = KeyChord(actionText) != nil ? "; did you mean key:\(actionText)?" : ""
            return .failure(.init("unrecognised action \"\(actionText)\" (use key:… or text:…\(hint))"))
        }
        let chordText = actionText.dropFirst(4).trimmingCharacters(in: .whitespaces)
        guard let chord = KeyChord(chordText) else {
            return .failure(.init("unrecognised key \"\(chordText)\" in \"\(actionText)\""))
        }
        guard !chord.modifiers.contains(.command) else {
            return .failure(.init("an action can't use cmd: programs never receive it"))
        }
        return .success(KeyBinding(trigger: trigger, action: .keys(chord)))
    }

    public struct ParseError: Error, Sendable, Equatable {
        public var message: String
        init(_ message: String) { self.message = message }
    }

    static func unescape(_ s: String) -> String? {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            switch it.next() {
            case "e"?: out.append("\u{1B}")
            case "n"?: out.append("\n")
            case "r"?: out.append("\r")
            case "t"?: out.append("\t")
            case "\\"?: out.append("\\")
            case "x"?:
                guard let a = it.next(), let b = it.next(), let v = UInt8(String([a, b]), radix: 16) else { return nil }
                out.unicodeScalars.append(Unicode.Scalar(v))
            default: return nil
            }
        }
        return out
    }
}

/// A key plus modifiers, e.g. `cmd+k` or `ctrl+shift+up`.
public struct KeyChord: Sendable, Equatable {
    public enum Key: Sendable, Equatable {
        /// A character key, unshifted and lowercased ("k", "1", "/").
        case character(String)
        /// A key with its own terminal encoding (arrows, Return, F-keys…).
        case special(KeyEncoder.Key)
    }

    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let shift = Modifiers(rawValue: 8)
    }

    public var key: Key
    public var modifiers: Modifiers

    public init(key: Key, modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Parses `cmd+k`, `ctrl+shift+up`, `opt+plus`… (case-insensitive).
    public init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        var mods: Modifiers = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "super": mods.insert(.command)
            case "ctrl", "control": mods.insert(.control)
            case "opt", "option", "alt": mods.insert(.option)
            case "shift": mods.insert(.shift)
            default: return nil
            }
        }
        guard let key = Self.key(named: last) else { return nil }
        self.init(key: key, modifiers: mods)
    }

    private static func key(named name: String) -> Key? {
        switch name {
        case "up": return .special(.up)
        case "down": return .special(.down)
        case "left": return .special(.left)
        case "right": return .special(.right)
        case "home": return .special(.home)
        case "end": return .special(.end)
        case "pageup", "page_up": return .special(.pageUp)
        case "pagedown", "page_down": return .special(.pageDown)
        case "insert": return .special(.insert)
        case "delete", "forward_delete": return .special(.forwardDelete)
        case "backspace": return .special(.backspace)
        case "enter", "return": return .special(.enter)
        case "tab": return .special(.tab)
        case "escape", "esc": return .special(.escape)
        case "space": return .character(" ")
        case "plus": return .character("+")
        case "equal", "equals": return .character("=")
        default:
            if name.count >= 2, name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...12).contains(n) {
                return .special(.function(n))
            }
            return name.count == 1 ? .character(name) : nil
        }
    }

    /// What pressing this combination sends (Cmd is ignored: it never reaches programs).
    func encoded(modes: TerminalModes) -> [UInt8] {
        var mods: KeyEncoder.Modifiers = []
        if modifiers.contains(.shift) { mods.insert(.shift) }
        if modifiers.contains(.control) { mods.insert(.control) }
        if modifiers.contains(.option) { mods.insert(.option) }
        switch key {
        case .special(let k):
            if k == .tab && modifiers.contains(.shift) { return KeyEncoder.encode(.backtab, modes: modes) }
            return KeyEncoder.encode(k, modifiers: mods, modes: modes)
        case .character(let c):
            let meta: [UInt8] = modifiers.contains(.option) ? [0x1B] : []
            if modifiers.contains(.control), let byte = KeyEncoder.controlByte(for: c) { return meta + [byte] }
            let text = modifiers.contains(.shift) ? c.uppercased() : c
            return meta + Array(text.utf8)
        }
    }
}
