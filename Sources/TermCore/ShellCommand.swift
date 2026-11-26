import Foundation

/// What to run on a new PTY, plus the environment it runs with.
public struct ShellCommand: Sendable {
    public var path: String
    /// Full argv including argv[0].
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(path: String, arguments: [String], environment: [String: String], workingDirectory: String?) {
        self.path = path
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// The user's login shell, the way Terminal.app-style emulators launch it.
    ///
    /// - The shell comes from the passwd database, not `$SHELL`: apps launched from
    ///   Finder/Dock get a minimal launchd environment where `$SHELL` may be stale or missing.
    /// - argv[0] is `-zsh` (leading dash): the traditional login-shell signal, so it
    ///   reads `/etc/zprofile` (which runs `path_helper` to build a proper `$PATH`).
    ///
    /// - `directory`: where to start (e.g. the current tab's directory); defaults to home.
    /// - `command`: run this via the login shell's `-c` instead of an interactive shell
    ///   (`Lite -e "…"`).
    public static func loginShell(base: [String: String] = ProcessInfo.processInfo.environment,
                                  directory: String? = nil, command: String? = nil) -> ShellCommand {
        let user = UserInfo.current()
        let shell = user.shell
        let name = (shell as NSString).lastPathComponent
        var isDir: ObjCBool = false
        let cwd = directory.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue ? $0 : nil }
        return ShellCommand(
            path: shell,
            arguments: ["-\(name)"] + (command.map { ["-c", $0] } ?? []),
            environment: terminalEnvironment(base: base, user: user),
            workingDirectory: cwd ?? user.home
        )
    }

    /// Environment for a child of the terminal: the inherited environment with
    /// terminal-identity variables replaced.
    public static func terminalEnvironment(base: [String: String], user: UserInfo = .current()) -> [String: String] {
        var env = base
        // Variables describing *another* terminal (e.g. when launched via `make run`
        // from Ghostty/iTerm) would mislead programs about capabilities.
        for key in env.keys where key.hasPrefix("ITERM_") || key.hasPrefix("GHOSTTY_")
            || key.hasPrefix("KITTY_") || key.hasPrefix("WEZTERM_") || key.hasPrefix("VTE_") {
            env[key] = nil
        }
        for key in ["TERM_SESSION_ID", "TERMINFO", "LINES", "COLUMNS", "LC_TERMINAL", "LC_TERMINAL_VERSION"] {
            env[key] = nil
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Lite"
        env["TERM_PROGRAM_VERSION"] = LiteInfo.version
        env["SHELL"] = user.shell
        env["HOME"] = env["HOME"] ?? user.home
        env["USER"] = env["USER"] ?? user.name
        env["LOGNAME"] = env["LOGNAME"] ?? user.name
        // Finder-launched apps often have no locale set; without one, many programs
        // fall back to ASCII and mangle UTF-8.
        if env["LANG"] == nil && env["LC_ALL"] == nil && env["LC_CTYPE"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }
        return env
    }
}

public enum LiteInfo {
    public static let version = "0.1.0"
}

public struct UserInfo: Sendable {
    public var name: String
    public var home: String
    public var shell: String

    public static func current() -> UserInfo {
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        let rc = getpwuid_r(getuid(), &pwd, &buffer, buffer.count, &result)
        guard rc == 0, result != nil else {
            return UserInfo(name: NSUserName(), home: NSHomeDirectory(), shell: "/bin/zsh")
        }
        let shell = pwd.pw_shell.map { String(cString: $0) } ?? ""
        return UserInfo(
            name: pwd.pw_name.map { String(cString: $0) } ?? NSUserName(),
            home: pwd.pw_dir.map { String(cString: $0) } ?? NSHomeDirectory(),
            shell: shell.isEmpty || !FileManager.default.isExecutableFile(atPath: shell) ? "/bin/zsh" : shell
        )
    }
}
