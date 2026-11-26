import Foundation
import Synchronization

/// One running terminal: a child process on a PTY, plus the engine parsing its output.
///
/// Data flow:
///   PTY read thread → `engine.feed` → (coalesced) `onNeedsDisplay` on the main queue
///   → the view's next frame calls `snapshot(into:)` → renderer.
///
/// `onNeedsDisplay` is coalesced: while one notification is queued on the main
/// thread, further output doesn't queue more. A `cat` of a huge file produces
/// thousands of reads per second but at most one main-thread hop per frame or so.
public final class TerminalSession: @unchecked Sendable {
    public struct Handlers: Sendable {
        public var needsDisplay: @MainActor @Sendable () -> Void = {}
        public var title: @MainActor @Sendable (String) -> Void = { _ in }
        public var bell: @MainActor @Sendable () -> Void = {}
        public var exit: @MainActor @Sendable (Int32) -> Void = { _ in }
        public init() {}
    }

    public struct Options: Sendable {
        public var scrollback = 10_000
        public var cursorStyle: CursorState.Style = .block
        public var cursorBlink = false
        public init() {}
    }

    public let engine: any TerminalEngine
    private let pty: PTYProcess
    private let bytesCounter = ByteCounter()

    /// Total bytes received from the program (for the perf log).
    public var bytesReceived: Int { bytesCounter.total }
    /// Working directory of the foreground process (or shell).
    public var currentDirectory: String? { pty.currentDirectory }
    /// Name of the foreground program, if it isn't the shell (e.g. "vim").
    public var runningProgram: String? { pty.runningProgram }

    public var pid: pid_t { pty.pid }

    /// Set `LITE_LOG_PTY=1` to also log escaped PTY output to stdout.
    private static let logOutput = ProcessInfo.processInfo.environment["LITE_LOG_PTY"] == "1"

    public init(command: ShellCommand, size: PTYProcess.Size, options: Options = Options(), handlers: Handlers) throws {
        // Replies (e.g. to "\e[c") can be produced during the very first feed, before
        // `pty` exists; the sink forwards once it's set.
        let sink = ReplySink()
        var events = TerminalEngineEvents()
        events.reply = { bytes in sink.write(bytes) }
        events.title = { title in Task { @MainActor in handlers.title(title) } }
        events.bell = { Task { @MainActor in handlers.bell() } }
        let engine = SwiftTermEngine(cols: Int(size.cols), rows: Int(size.rows), scrollback: options.scrollback,
                                     cursorStyle: options.cursorStyle, cursorBlink: options.cursorBlink,
                                     events: events)
        self.engine = engine

        let flag = DisplayFlag()
        let counter = bytesCounter
        pty = try PTYProcess(
            command: command,
            size: size,
            onData: { bytes in
                if Self.logOutput { print("[pty] \(PTYDebug.escaped(bytes))") }
                engine.feed(bytes)
                counter.add(bytes.count)
                if flag.claim() {
                    DispatchQueue.main.async {
                        flag.release()
                        MainActor.assumeIsolated { handlers.needsDisplay() }
                    }
                }
            },
            onExit: { code in
                Task { @MainActor in handlers.exit(code) }
            }
        )
        sink.attach(pty)
    }

    public func write(_ bytes: some Sequence<UInt8>) { pty.write(bytes) }
    public func write(_ string: String) { pty.write(string) }

    /// Resizes the engine first, then the PTY, so output produced for the new
    /// size is parsed at the new size.
    public func resize(_ size: PTYProcess.Size) {
        engine.resize(cols: Int(size.cols), rows: Int(size.rows))
        pty.resize(size)
    }

    public func terminate() { pty.terminate() }

    @discardableResult
    public func snapshot(into grid: inout GridSnapshot) -> Bool { engine.snapshot(into: &grid) }

    public var modes: TerminalModes { engine.modes }
}

private final class ByteCounter: Sendable {
    private let value = Atomic(0)
    func add(_ n: Int) { value.add(n, ordering: .relaxed) }
    var total: Int { value.load(ordering: .relaxed) }
}

/// "A redraw is already queued" flag (claim = set if clear).
private final class DisplayFlag: Sendable {
    private let queued = Atomic(false)
    func claim() -> Bool { !queued.exchange(true, ordering: .acquiringAndReleasing) }
    func release() { queued.store(false, ordering: .releasing) }
}

/// Buffers engine replies until the PTY exists.
private final class ReplySink: Sendable {
    private let state = Mutex<(pty: PTYProcess?, pending: [UInt8])>((nil, []))

    func write(_ bytes: [UInt8]) {
        let pty: PTYProcess? = state.withLock { s in
            if s.pty == nil { s.pending += bytes }
            return s.pty
        }
        pty?.write(bytes)
    }

    func attach(_ pty: PTYProcess) {
        let pending = state.withLock { s in
            s.pty = pty
            defer { s.pending = [] }
            return s.pending
        }
        if !pending.isEmpty { pty.write(pending) }
    }
}
