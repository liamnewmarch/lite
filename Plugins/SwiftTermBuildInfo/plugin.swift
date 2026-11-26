import Foundation
import PackagePlugin

/// Adds two things to the SwiftTerm target, which is built straight from the submodule:
///
/// 1. Lite's bridge (Sources/SwiftTermBridge/*.swift), copied in so it compiles inside the
///    SwiftTerm module and can use internal API. A target's sources must live under its
///    path, and the submodule is upstream's, so this is how it gets in.
/// 2. The output of SwiftTerm's own build-info generator (Vendor/SwiftTerm/Sources/SwiftTermBuildInfoGenerator,
/// unmodified) for the SwiftTerm target. Upstream's plugin can't be reused as is: it points the
/// generator at the *package* directory, which here is Lite's, not the submodule's.
@main
struct SwiftTermBuildInfo: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let generator = try context.tool(named: "SwiftTermBuildInfoGenerator")
        let repo = context.package.directoryURL.appending(path: "Vendor/SwiftTerm")
        let out = context.pluginWorkDirectoryURL.appending(path: "Generated")
        let buildInfo = out.appending(path: "SwiftTermBuildInfo.swift")
        let terminfo = out.appending(path: "SwiftTermTerminfo.swift")

        // Re-run when the terminfo source or the checked-out commit changes.
        var inputs = [repo.appending(path: "swifterm-terminfo")]
        if let head = Self.gitHead(of: repo) { inputs.append(head) }

        var commands: [Command] = [.buildCommand(
            displayName: "Generate SwiftTerm build information",
            executable: generator.url,
            arguments: [repo.path, buildInfo.path, terminfo.path],
            inputFiles: inputs,
            outputFiles: [buildInfo, terminfo]
        )]

        let bridgeDir = context.package.directoryURL.appending(path: "Sources/SwiftTermBridge")
        let bridgeFiles = (try? FileManager.default.contentsOfDirectory(at: bridgeDir, includingPropertiesForKeys: nil)) ?? []
        for file in bridgeFiles where file.pathExtension == "swift" {
            let copy = out.appending(path: "Bridge").appending(path: file.lastPathComponent)
            commands.append(.buildCommand(
                displayName: "Add \(file.lastPathComponent) to SwiftTerm",
                executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: [file.path, copy.path],
                inputFiles: [file],
                outputFiles: [copy]
            ))
        }
        return commands
    }

    /// The submodule's HEAD file (its `.git` is a file: "gitdir: <path>").
    private static func gitHead(of repo: URL) -> URL? {
        let dotGit = repo.appending(path: ".git")
        guard let s = try? String(contentsOf: dotGit, encoding: .utf8), s.hasPrefix("gitdir: ") else {
            return FileManager.default.fileExists(atPath: dotGit.appending(path: "HEAD").path)
                ? dotGit.appending(path: "HEAD") : nil
        }
        let path = s.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return repo.appending(path: path).appending(path: "HEAD").standardizedFileURL
    }
}
