import Foundation
import Synchronization
import Testing
@testable import TermCore

/// Collects PTY output and exit status from background threads.
final class Capture: Sendable {
    let output = Mutex(Data())
    let exitCode = Mutex<Int32?>(nil)

    var text: String { output.withLock { String(decoding: $0, as: UTF8.self) } }

    /// Polls until `condition` holds or the timeout passes.
    func wait(timeout: Duration = .seconds(5), until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

func spawn(_ args: [String], size: PTYProcess.Size = .init(cols: 80, rows: 24),
                   capture: Capture) throws -> PTYProcess {
    try PTYProcess(
        command: ShellCommand(path: args[0], arguments: args,
                              environment: ShellCommand.terminalEnvironment(base: [:]),
                              workingDirectory: "/tmp"),
        size: size,
        onData: { bytes in capture.output.withLock { $0.append(contentsOf: bytes) } },
        onExit: { code in capture.exitCode.withLock { $0 = code } }
    )
}

@Suite struct PTYProcessTests {
    @Test func runsCommandAndReportsExit() async throws {
        let c = Capture()
        let pty = try spawn(["/bin/sh", "-c", "echo hello; exit 3"], capture: c)
        #expect(pty.pid > 0)
        #expect(await c.wait { c.exitCode.withLock { $0 } != nil })
        #expect(c.exitCode.withLock { $0 } == 3)
        #expect(await c.wait { c.text.contains("hello") })
        // The tty's ONLCR turns \n into \r\n: proof we're on a real PTY.
        #expect(c.text.contains("hello\r\n"))
    }

    @Test func hasControllingTerminalWithInitialSize() async throws {
        let c = Capture()
        _ = try spawn(["/bin/sh", "-c", "stty size; tty"], size: .init(cols: 132, rows: 43), capture: c)
        #expect(await c.wait { c.exitCode.withLock { $0 } != nil })
        #expect(await c.wait { c.text.contains("/dev/ttys") })
        #expect(c.text.contains("43 132"))
    }

    @Test func setsTerminalEnvironment() async throws {
        let c = Capture()
        _ = try spawn(["/bin/sh", "-c", "echo \"$TERM|$COLORTERM|$TERM_PROGRAM\"; pwd"], capture: c)
        #expect(await c.wait { c.exitCode.withLock { $0 } != nil })
        #expect(await c.wait { c.text.contains("xterm-256color|truecolor|Lite") })
        #expect(c.text.contains("/tmp") || c.text.contains("/private/tmp"))
    }

    @Test func writesInputAndResizes() async throws {
        let c = Capture()
        // Wait for a line of input, then report the (new) size.
        let pty = try spawn(["/bin/sh", "-c", "read line; echo \"got:$line\"; stty size"], capture: c)
        pty.resize(.init(cols: 100, rows: 30))
        pty.write("abc\r")
        #expect(await c.wait { c.exitCode.withLock { $0 } != nil })
        #expect(await c.wait { c.text.contains("30 100") })
        #expect(c.text.contains("got:abc"))
    }

    @Test func utf8InputIsEnabled() async throws {
        let c = Capture()
        _ = try spawn(["/bin/sh", "-c", "stty -a"], capture: c)
        let done = await c.wait { c.exitCode.withLock { $0 } != nil }
        #expect(done, "output: \(c.text)")
        #expect(await c.wait { c.text.contains("iutf8") })
        #expect(!c.text.contains("-iutf8"))
    }

    @Test func terminateHangsUpTheChild() async throws {
        let c = Capture()
        let pty = try spawn(["/bin/sh", "-c", "sleep 30"], capture: c)
        try await Task.sleep(for: .milliseconds(100))
        pty.terminate()
        #expect(await c.wait { c.exitCode.withLock { $0 } != nil })
        #expect(c.exitCode.withLock { $0 } == 128 + SIGHUP)
    }

    @Test func loginShellUsesDashPrefixedArgv0() {
        let cmd = ShellCommand.loginShell(base: [:])
        #expect(cmd.arguments.count == 1)
        #expect(cmd.arguments[0] == "-" + (cmd.path as NSString).lastPathComponent)
        #expect(cmd.environment["LANG"] == "en_US.UTF-8")
        #expect(cmd.environment["TERM"] == "xterm-256color")
    }

    @Test func stripsOtherTerminalsVariables() {
        let env = ShellCommand.terminalEnvironment(base: ["GHOSTTY_RESOURCES_DIR": "x", "TERM_SESSION_ID": "y",
                                                          "LANG": "de_DE.UTF-8", "PATH": "/usr/bin"])
        #expect(env["GHOSTTY_RESOURCES_DIR"] == nil)
        #expect(env["TERM_SESSION_ID"] == nil)
        #expect(env["LANG"] == "de_DE.UTF-8")
        #expect(env["PATH"] == "/usr/bin")
    }

    @Test func escapesDebugOutput() {
        let bytes: [UInt8] = Array("\u{1B}[1mhé\r\n\u{07}".utf8)
        let s = bytes.withUnsafeBytes { PTYDebug.escaped($0) }
        #expect(s == "\\e[1mhé\\r\\n\\a")
    }
}

@Suite struct ProcessInfoTests {
    @Test func tracksDirectoryAndForegroundProgram() async throws {
        let c = Capture()
        // Interactive sh: job control puts each command in its own foreground process group.
        let pty = try spawn(["/bin/sh", "-i"], capture: c)
        defer { pty.terminate() }
        pty.write("cd /usr/bin\r")
        #expect(await c.wait { pty.currentDirectory == "/usr/bin" })
        #expect(pty.runningProgram == nil) // just the shell
        pty.write("sleep 5\r")
        #expect(await c.wait { pty.runningProgram == "sleep" })
        pty.write([0x03]) // Ctrl-C
        #expect(await c.wait { pty.runningProgram == nil })
    }
}
