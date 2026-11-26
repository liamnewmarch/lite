import AppKit
import TermCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Window controllers are owned here; AppKit only holds windows weakly via the controller.
    private var controllers: [TerminalWindowController] = []
    private(set) var config = Config()
    private var configWatcher: ConfigWatcher?

    /// `Lite -e "command"`: run a command in the first window instead of a shell
    /// (like `xterm -e`); the app quits when that window closes.
    private let startupCommand: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-e"), i + 1 < args.count else { return nil }
        return args[(i + 1)...].joined(separator: " ")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        loadConfig(showErrors: true)
        configWatcher = ConfigWatcher(url: Config.fileURL) { [weak self] in self?.loadConfig(showErrors: true) }
        newWindow(command: startupCommand)
        NSApp.activate()
    }

    /// Standard Mac behaviour: closing the last window keeps the app running (unless
    /// `quit-after-last-window-closed = true`); clicking the Dock icon opens a fresh window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        config.quitAfterLastWindowClosed || startupCommand != nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { newWindow(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Confirm before quitting if any tab is running something other than its shell.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = controllers.compactMap(\.runningProgram)
        guard !busy.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Lite?"
        let names = Set(busy).sorted().joined(separator: ", ")
        alert.informativeText = busy.count == 1
            ? "\(names) is still running in a tab. Quitting will end it."
            : "\(busy.count) tabs are running programs (\(names)). Quitting will end them."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: - Windows

    func makeController(frame: NSRect? = nil) -> TerminalWindowController {
        let controller = TerminalWindowController(config: config, frame: frame)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        return controller
    }

    /// The key window's controller, e.g. to inherit its working directory.
    var keyController: TerminalWindowController? {
        controllers.first { $0.window?.isKeyWindow == true }
    }

    /// Cmd-N. Respects the system "Prefer tabs" setting via `tabbingMode = .automatic`.
    @objc func newWindow(_ sender: Any?) { newWindow(command: nil) }

    private func newWindow(command: String?) {
        let directory = keyController?.currentDirectory
        let controller = makeController()
        if let key = NSApp.keyWindow {
            controller.window?.cascadeTopLeft(from: key.frame.origin)
        }
        controller.showWindow(nil)
        controller.start(directory: directory, command: command)
    }

    /// Cmd-T when no window is key (e.g. all windows closed). When a window is key,
    /// `TerminalWindowController.newWindowForTab` handles it first via the responder chain.
    @objc func newWindowForTab(_ sender: Any?) {
        newWindow(sender)
    }

    // MARK: - Config

    private func loadConfig(showErrors: Bool) {
        var (loaded, diagnostics) = Config.load()
        let (_, fontWarning) = loaded.makeFont()
        if let fontWarning { diagnostics.append(.init(line: 0, message: fontWarning)) }
        let changed = loaded != config
        config = loaded
        if changed { controllers.forEach { $0.apply(config) } }
        for d in diagnostics { print("[config] \(Config.fileURL.path): \(d)") }
        if showErrors && !diagnostics.isEmpty { presentConfigErrors(diagnostics) }
    }

    private func presentConfigErrors(_ diagnostics: [Config.Diagnostic]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Problems in your Lite config"
        let lines = diagnostics.prefix(12).map { $0.line > 0 ? "Line \($0.line): \($0.message)" : $0.message }
        alert.informativeText = lines.joined(separator: "\n")
            + (diagnostics.count > 12 ? "\n…and \(diagnostics.count - 12) more" : "")
            + "\n\nEverything else was applied."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Config")
        if alert.runModal() == .alertSecondButtonReturn { openSettings(nil) }
    }

    /// Lite > Settings… (Cmd-,): creates the config file with commented defaults if
    /// needed and opens it in the default plain-text editor.
    @objc func openSettings(_ sender: Any?) {
        let url = Config.fileURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Config.template.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("[config] couldn't create \(url.path): \(error)")
                NSSound.beep()
                return
            }
            configWatcher?.restart() // the directory may not have existed before
        }
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func reloadConfig(_ sender: Any?) {
        loadConfig(showErrors: true)
    }
}

extension Config {
    /// The configured font, or the system monospaced font (with a warning if the
    /// family wasn't found or isn't monospaced).
    @MainActor
    func makeFont() -> (CTFont, warning: String?) {
        let size = CGFloat(fontSize)
        let fallback = NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        guard let family = fontFamily else { return (fallback, nil) }
        guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
                ?? NSFont(name: family, size: size) else {
            return (fallback, "font-family \"\(family)\" isn't installed; using the system font")
        }
        let warning = font.isFixedPitch ? nil : "font-family \"\(family)\" isn't monospaced; text may overlap"
        return (font as CTFont, warning)
    }
}

/// Watches the config file (and its directory, since editors often save by
/// writing a new file and renaming it over the old one) and calls `onChange`,
/// debounced, after it's modified.
@MainActor
final class ConfigWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var sources: [any DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        restart()
    }

    func restart() {
        sources.forEach { $0.cancel() }
        sources = []
        for path in [url.deletingLastPathComponent().path, url.path] {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.changed() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    private func changed() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.restart() // the file may have been replaced: watch the new one
                self.onChange()
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
}
