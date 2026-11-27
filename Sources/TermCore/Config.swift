import Foundation

/// Which Option key(s) act as Meta (send ESC-prefixed keys) instead of composing
/// characters like é or ∑.
public enum OptionAsMeta: String, Sendable, CaseIterable { case none, left, right, both }

/// User settings, read from `~/.config/lite/config` (or `$XDG_CONFIG_HOME/lite/config`).
///
/// Format: one `key = value` per line, `#` starts a comment line, blank lines are
/// ignored, values may be "quoted". Repeatable keys (`palette`) accumulate. The
/// parser lives behind `Config.parse` so a spec'd format (e.g. TOML + JSON Schema)
/// can replace it later without touching the rest of the app.
/// Space between the window edges and the text: a fixed size, or relative to the font size.
public enum WindowPadding: Sendable, Equatable {
    case points(Double)
    /// Multiples of `font-size`, like CSS `em`.
    case em(Double)

    public func points(fontSize: Double) -> Double {
        switch self {
        case .points(let p): p
        case .em(let e): e * fontSize
        }
    }
}

public struct Config: Sendable, Equatable {
    /// nil = the system monospaced font (SF Mono).
    public var fontFamily: String?
    public var fontSize: Double = 13
    public var palette: Palette = .default
    public var optionAsMeta: OptionAsMeta = .none
    public var scrollbackLimit = 10_000
    public var cursorStyle: CursorState.Style = .block
    public var cursorBlink = false
    public var quitAfterLastWindowClosed = false
    /// nil = a narrow default (a few points; see TerminalView).
    public var windowPadding: WindowPadding?
    /// `keybind` lines, in file order (a later binding for the same shortcut wins).
    public var keyBindings: [KeyBinding] = []

    /// `windowPadding` in points, or nil for the default.
    public var windowPaddingPoints: Double? { windowPadding?.points(fontSize: fontSize) }

    public init() {}

    public struct Diagnostic: Sendable, Equatable, CustomStringConvertible {
        public var line: Int
        public var message: String
        public init(line: Int, message: String) { self.line = line; self.message = message }
        /// `line` 0 means the problem isn't tied to a line (e.g. a font that isn't installed).
        public var description: String { line > 0 ? "line \(line): \(message)" : message }
    }

    // MARK: - Location

    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("lite", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lite", isDirectory: true)
    }

    public static var fileURL: URL { directory().appendingPathComponent("config") }

    /// Loads the config file. A missing file is not an error (defaults apply).
    public static func load(from url: URL = fileURL) -> (Config, [Diagnostic]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (Config(), []) }
        return parse(text)
    }

    // MARK: - Parsing

    public static func parse(_ text: String) -> (Config, [Diagnostic]) {
        var config = Config()
        var diagnostics: [Diagnostic] = []
        var ansi = Array(Palette.default.indexed.prefix(16))
        var p = Palette.default

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNo = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else {
                diagnostics.append(.init(line: lineNo, message: "expected `key = value`"))
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            func fail(_ message: String) { diagnostics.append(.init(line: lineNo, message: message)) }
            func color(_ v: String) -> RGB? {
                guard let c = parseColor(v) else { fail("`\(key)`: invalid colour \"\(v)\" (use #rrggbb)"); return nil }
                return c
            }
            func bool(_ v: String) -> Bool? {
                switch v.lowercased() {
                case "true", "yes", "on", "1": return true
                case "false", "no", "off", "0": return false
                default: fail("`\(key)`: expected true or false"); return nil
                }
            }

            switch key {
            case "font-family":
                config.fontFamily = value.isEmpty ? nil : value
            case "font-size":
                if let size = Double(value), (4...200).contains(size) { config.fontSize = size }
                else { fail("`font-size`: expected a number between 4 and 200") }
            case "background": if let c = color(value) { p.background = c }
            case "foreground": if let c = color(value) { p.foreground = c }
            case "cursor-color": if let c = color(value) { p.cursor = c }
            case "cursor-text": if let c = color(value) { p.cursorText = c }
            case "selection-background": if let c = color(value) { p.selectionBackground = c }
            case "selection-foreground":
                if value.isEmpty { p.selectionForeground = nil } else if let c = color(value) { p.selectionForeground = c }
            case "palette":
                // palette = N=#rrggbb  (N = 0…15)
                let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let n = Int(parts[0]), (0..<16).contains(n) else {
                    fail("`palette`: expected N=#rrggbb with N from 0 to 15"); continue
                }
                if let c = color(parts[1]) { ansi[n] = c }
            case "option-as-meta":
                if let v = OptionAsMeta(rawValue: value.lowercased()) { config.optionAsMeta = v }
                else if let b = bool(value) { config.optionAsMeta = b ? .both : .none }
            case "scrollback-limit":
                if let n = Int(value), n >= 0 { config.scrollbackLimit = n }
                else { fail("`scrollback-limit`: expected a whole number of lines") }
            case "cursor-style":
                switch value.lowercased() {
                case "block": config.cursorStyle = .block
                case "bar": config.cursorStyle = .bar
                case "underline": config.cursorStyle = .underline
                default: fail("`cursor-style`: expected block, bar or underline")
                }
            case "cursor-blink":
                if let b = bool(value) { config.cursorBlink = b }
            case "quit-after-last-window-closed":
                if let b = bool(value) { config.quitAfterLastWindowClosed = b }
            case "keybind":
                switch KeyBinding.parse(value) {
                case .success(let b): config.keyBindings.append(b)
                case .failure(let e): fail("`keybind`: \(e.message)")
                }
            case "window-padding":
                let v = value.lowercased()
                if v.hasSuffix("em"), let e = Double(v.dropLast(2).trimmingCharacters(in: .whitespaces)), (0...10).contains(e) {
                    config.windowPadding = .em(e)
                } else if let pts = Double(v), (0...200).contains(pts) {
                    config.windowPadding = .points(pts)
                } else {
                    fail("`window-padding`: expected points (0–200, e.g. 12) or a multiple of font-size (e.g. 1em)")
                }
            default:
                fail("unknown key `\(key)`")
            }
        }
        config.palette = Palette(foreground: p.foreground, background: p.background, cursor: p.cursor,
                                 cursorText: p.cursorText, selectionBackground: p.selectionBackground,
                                 selectionForeground: p.selectionForeground, ansi: ansi)
        return (config, diagnostics)
    }

    static func parseColor(_ s: String) -> RGB? {
        var hex = s.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return RGB(hex: v)
    }

    // MARK: - Template

    /// Written by Settings… when no config file exists. Everything commented out = defaults.
    public static let template = """
    # Lite configuration. One `key = value` per line; lines starting with # are comments.
    # Changes apply as soon as you save.

    # Font. Leave font-family unset for the system monospaced font (SF Mono).
    # font-family = Menlo
    # font-size = 13

    # Colours (#rrggbb).
    # background = #000000
    # foreground = #d8d8dc
    # cursor-color = #e8e8ec
    # cursor-text = #000000
    # selection-background = #3e4a63
    # selection-foreground =

    # The 16 ANSI colours (0–7 normal, 8–15 bright). Repeat the key for each.
    # palette = 0=#2a2a2e
    # palette = 1=#e0616b
    # palette = 2=#8fc97a
    # palette = 3=#e6c36b
    # palette = 4=#6aa6e8
    # palette = 5=#c58ae0
    # palette = 6=#5fc6c9
    # palette = 7=#c8c8cc
    # palette = 8=#5c5c63
    # palette = 9=#ff7a84
    # palette = 10=#a8dc93
    # palette = 11=#f2d688
    # palette = 12=#8cbcf2
    # palette = 13=#d6a6ee
    # palette = 14=#7fdadd
    # palette = 15=#f4f4f6

    # Space around the text, on all four sides: points (e.g. 12), or a multiple of
    # font-size (e.g. 1em, which follows font-size). Unset = a narrow default.
    # window-padding = 1em

    # Cursor: block, bar or underline. Programs can still change it.
    # cursor-style = block
    # cursor-blink = false

    # Option key as Meta (sends ESC+key, for shell/emacs shortcuts) instead of
    # typing special characters: none, left, right or both.
    # option-as-meta = none

    # Lines of scrollback per tab (applies to new tabs).
    # scrollback-limit = 10000

    # Key bindings: <shortcut> = <action>. Repeat the key for each. The action is
    # key:… to send a key combination (cmd can't be sent), or text:… with \\e, \\xNN, \\n, \\r,
    # \\t escapes. Bindings take priority over menu shortcuts (cmd+a below replaces
    # Select All). Key names: a–z, 0–9, symbols, up, down, left, right, home, end,
    # pageup, pagedown, enter, tab, escape, backspace, delete, space, plus, equal, f1–f12.
    # keybind = cmd+a = key:ctrl+a
    # keybind = cmd+k = key:ctrl+k
    # keybind = cmd+left = text:\\x01

    # Quit Lite when its last window closes (default: keep running, like most Mac apps).
    # quit-after-last-window-closed = false

    """
}
