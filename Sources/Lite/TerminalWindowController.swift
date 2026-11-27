import AppKit
import TermCore
import TermRender

/// One window == one tab == one shell session.
///
/// Creation is two-step: `init` builds the window, then the caller places it
/// (cascade, or join a tab group) and calls `start()`. The shell is spawned only
/// once the window has its final frame and layout (including the tab bar), so it
/// starts at the right size instead of getting an immediate SIGWINCH.
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let terminalView: TerminalView
    private var session: TerminalSession?
    private var config: Config
    private var closeConfirmed = false

    init(config: Config, frame: NSRect? = nil) {
        self.config = config
        let context: RenderContext
        do {
            context = try RenderContext.shared()
        } catch {
            fatalError("[metal] \(error)")
        }
        let renderer = TerminalRenderer(context: context, font: config.makeFont().0,
                                        scale: NSScreen.main?.backingScaleFactor ?? 2, palette: config.palette)
        terminalView = TerminalView(renderer: renderer)
        terminalView.optionAsMeta = config.optionAsMeta
        terminalView.padding = config.windowPaddingPoints.map { CGFloat($0) }
        terminalView.keyBindings = config.keyBindings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Mostly hidden chrome: the content extends under a transparent title bar,
        // traffic lights stay. The title still shows in the tab bar and Window menu.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Lite"
        window.backgroundColor = config.palette.background.nsColor
        window.minSize = NSSize(width: 240, height: 120)
        window.isReleasedWhenClosed = false

        // Native tabbing. All Lite windows share an identifier so they can merge.
        window.tabbingIdentifier = "com.liamnewmarch.lite.terminal"
        window.tabbingMode = .automatic
        window.contentView = terminalView

        super.init(window: window)
        window.delegate = self
        if let frame { window.setFrame(frame, display: false) } else { window.center() }

        terminalView.onGridResize = { [weak self] g in self?.gridDidResize(g) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Spawns the shell (or `command`) at the window's current grid size, in
    /// `directory` if given. Call after placing the window.
    func start(directory: String? = nil, command: String? = nil) {
        guard session == nil, let window else { return }
        window.layoutIfNeeded()
        let g = terminalView.computeGeometry()
        let shell = ShellCommand.loginShell(directory: directory, command: command)
        let shellName = command ?? (shell.path as NSString).lastPathComponent

        var handlers = TerminalSession.Handlers()
        handlers.needsDisplay = { [weak self] in self?.terminalView.setNeedsRender() }
        handlers.title = { [weak self] title in self?.window?.title = title.isEmpty ? shellName : title }
        handlers.bell = { NSSound.beep() }
        handlers.exit = { [weak self] code in
            print("[pty] shell exited with code \(code)")
            self?.closeConfirmed = true // nothing left to confirm
            self?.window?.close()
        }
        var options = TerminalSession.Options()
        options.scrollback = config.scrollbackLimit
        options.cursorStyle = config.cursorStyle
        options.cursorBlink = config.cursorBlink
        do {
            let session = try TerminalSession(command: shell, size: Self.ptySize(g), options: options, handlers: handlers)
            self.session = session
            terminalView.session = session
            window.title = shellName
            print("[pty] spawned \(shell.path) as \(shell.arguments.joined(separator: " ")) pid=\(session.pid) size=\(g.cols)x\(g.rows) cwd=\(shell.workingDirectory ?? "-")")
        } catch {
            print("[pty] \(error)")
        }
    }

    var currentDirectory: String? { session?.currentDirectory }
    var runningProgram: String? { session?.runningProgram }

    /// Applies a (re)loaded config. Font, colours, padding, key bindings and Option-as-Meta update live;
    /// scrollback size and the default cursor apply to new tabs.
    func apply(_ newConfig: Config) {
        config = newConfig
        terminalView.renderer.palette = newConfig.palette
        window?.backgroundColor = newConfig.palette.background.nsColor
        terminalView.optionAsMeta = newConfig.optionAsMeta
        terminalView.setFont(newConfig.makeFont().0)
        terminalView.padding = newConfig.windowPaddingPoints.map { CGFloat($0) }
        terminalView.keyBindings = newConfig.keyBindings
    }

    private func gridDidResize(_ g: TerminalView.GridGeometry) {
        guard let session else { return } // not started yet: start() uses the latest size
        session.resize(Self.ptySize(g))
    }

    private static func ptySize(_ g: TerminalView.GridGeometry) -> PTYProcess.Size {
        PTYProcess.Size(cols: UInt16(clamping: g.cols), rows: UInt16(clamping: g.rows),
                        pixelWidth: UInt16(clamping: g.pixelWidth), pixelHeight: UInt16(clamping: g.pixelHeight))
    }

    // MARK: - Tabs

    /// Cmd-T, and the "+" button in the tab bar (AppKit shows it when this is implemented).
    /// The new tab starts in this tab's current directory.
    override func newWindowForTab(_ sender: Any?) {
        guard let window, let delegate = NSApp.delegate as? AppDelegate else { return }
        let directory = currentDirectory
        let controller = delegate.makeController(frame: window.frame)
        guard let newWindow = controller.window else { return }
        window.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
        controller.start(directory: directory)
    }

    /// Cmd-1…8 select that tab; Cmd-9 the last one (menu item tags 1…9).
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard let tabs = window?.tabbedWindows ?? window.map({ [$0] }), !tabs.isEmpty else { return }
        let index = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
        guard tabs.indices.contains(index) else { return }
        tabs[index].makeKeyAndOrderFront(nil)
    }

    /// Cmd-Shift-W: close every tab in this window.
    @objc func closeWindowGroup(_ sender: Any?) {
        let windows = window?.tabbedWindows ?? window.map { [$0] } ?? []
        windows.forEach { $0.performClose(sender) }
    }

    // MARK: - Closing

    /// Confirm before closing a tab that's running something other than its shell.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closeConfirmed, let program = runningProgram else { return true }
        let alert = NSAlert()
        alert.messageText = "Close this tab?"
        alert.informativeText = "\(program) is still running. Closing the tab will end it."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self?.closeConfirmed = true
                sender.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        session?.terminate()
        onClose?()
    }
}

extension RGB {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}
