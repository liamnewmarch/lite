import CPty
import Foundation
import Synchronization

/// A child process attached to a pseudo-terminal.
///
/// Threading:
/// - A dedicated thread does blocking `read()` on the master and calls `onData`
///   *on that thread*. The buffer is only valid for the duration of the call.
/// - Writes are queued on a serial queue so a full PTY buffer never blocks the caller.
/// - Exit is detected by a second thread blocked in `waitpid` (not by read EOF, since
///   background jobs can keep the slave open after the shell exits). `onExit` runs once on
///   that thread. A kqueue/Dispatch process source looks neater but registers asynchronously,
///   so a child that exits immediately can be missed.
/// - The read thread owns the fd and closes it after EOF/EIO, so `terminate()` never
///   closes an fd out from under a blocked `read()`.
public final class PTYProcess: @unchecked Sendable {
    public struct Size: Sendable, Equatable {
        public var cols: UInt16
        public var rows: UInt16
        /// Pixel size of the text area (some programs use it for images); 0 if unknown.
        public var pixelWidth: UInt16
        public var pixelHeight: UInt16

        public init(cols: UInt16, rows: UInt16, pixelWidth: UInt16 = 0, pixelHeight: UInt16 = 0) {
            self.cols = max(cols, 1)
            self.rows = max(rows, 1)
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
        }
    }

    public struct SpawnError: Error, CustomStringConvertible {
        public let errno: Int32
        public var description: String { "PTY spawn failed: \(String(cString: strerror(errno)))" }
    }

    public let pid: pid_t
    private let fd: Int32
    private let onExit: @Sendable (Int32) -> Void
    private let writeQueue = DispatchQueue(label: "lite.pty.write")
    private let exited = Mutex(false)

    public init(
        command: ShellCommand,
        size: Size,
        onData: @escaping @Sendable (UnsafeRawBufferPointer) -> Void,
        onExit: @escaping @Sendable (_ exitCode: Int32) -> Void
    ) throws {
        // Build every C string before forking (the child can't allocate safely).
        let argv = CStringArray(command.arguments)
        let envp = CStringArray(command.environment.map { "\($0.key)=\($0.value)" })
        var pid: pid_t = 0
        let fd = command.path.withCString { path in
            withOptionalCString(command.workingDirectory) { cwd in
                lite_pty_spawn(path, argv.pointer, envp.pointer, cwd,
                               size.rows, size.cols, size.pixelWidth, size.pixelHeight, &pid)
            }
        }
        guard fd >= 0 else { throw SpawnError(errno: errno) }

        self.fd = fd
        self.pid = pid
        self.onExit = onExit

        let reader = Thread { [self] in self.readLoop(onData) }
        reader.name = "lite.pty.read.\(pid)"
        reader.qualityOfService = .userInteractive
        reader.start()

        let waiter = Thread { [self] in self.waitForExit() }
        waiter.name = "lite.pty.wait.\(pid)"
        waiter.qualityOfService = .utility
        waiter.start()
    }

    public func write(_ bytes: some Sequence<UInt8>) {
        let data = Array(bytes)
        guard !data.isEmpty else { return }
        writeQueue.async { [fd] in
            data.withUnsafeBytes { buf in
                var offset = 0
                while offset < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                    if n > 0 { offset += n; continue }
                    if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    return // EIO/EBADF: child gone or fd closed
                }
            }
        }
    }

    public func write(_ string: String) { write(string.utf8) }

    public func resize(_ size: Size) {
        _ = lite_pty_set_size(fd, size.rows, size.cols, size.pixelWidth, size.pixelHeight)
    }

    /// The process group currently in the terminal's foreground (the shell when idle).
    public var foregroundProcessGroup: pid_t? {
        let pgid = lite_pty_foreground_pgid(fd)
        return pgid > 0 ? pgid : nil
    }

    /// Working directory of the foreground process (or the shell), e.g. to open new tabs there.
    public var currentDirectory: String? {
        for candidate in [foregroundProcessGroup, pid].compactMap({ $0 }) {
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if lite_proc_cwd(candidate, &buf, Int32(buf.count)) == 0 {
                let path = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !path.isEmpty { return path }
            }
        }
        return nil
    }

    /// Name of the foreground program if it isn't the shell itself (e.g. "vim"), else nil.
    /// Used to confirm before closing a tab with something running.
    public var runningProgram: String? {
        guard let pg = foregroundProcessGroup, pg != pid else { return nil }
        var buf = [CChar](repeating: 0, count: 256)
        guard lite_proc_name(pg, &buf, Int32(buf.count)) == 0 else { return "a program" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Hang up: SIGHUP the child's process group, like closing a real terminal.
    public func terminate() {
        // Held across kill() so the pid can't be reaped (and reused) in between.
        exited.withLock { done in
            if !done { kill(-pid, SIGHUP) }
        }
    }

    // MARK: - Private

    private func readLoop(_ onData: @Sendable (UnsafeRawBufferPointer) -> Void) {
        let capacity = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer {
            buffer.deallocate()
            close(fd)
        }
        while true {
            let n = read(fd, buffer, capacity)
            if n > 0 {
                onData(UnsafeRawBufferPointer(start: buffer, count: n))
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break // 0 = EOF; EIO = slave side fully closed (normal on macOS)
            }
        }
    }

    private func waitForExit() {
        _ = lite_pty_wait_exit(pid)
        // Mark exited and reap under the same lock `terminate()` holds while signalling.
        let code = exited.withLock { done in
            done = true
            var code: Int32 = -1
            _ = lite_pty_reap(pid, &code)
            return code
        }
        onExit(code)
    }
}

/// A NULL-terminated `char *[]` that frees itself.
private final class CStringArray {
    let storage: [UnsafeMutablePointer<CChar>?]
    init(_ strings: [String]) { storage = strings.map { strdup($0) } + [nil] }
    var pointer: UnsafePointer<UnsafeMutablePointer<CChar>?> {
        storage.withUnsafeBufferPointer { $0.baseAddress! }
    }
    deinit { storage.forEach { free($0) } }
}

private func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let s else { return body(nil) }
    return s.withCString(body)
}
