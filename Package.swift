// swift-tools-version:6.0
import PackageDescription

// Lite — [Li]am's [T]erminal [E]mulator.
// Apple Silicon / macOS 27+ only. No package dependencies: SwiftTerm is a git
// submodule (Vendor/SwiftTerm) compiled as a target below.
let package = Package(
    name: "Lite",
    platforms: [.macOS("27.0")],
    targets: [
        // SwiftTerm (MIT, Miguel de Icaza): the VT parser + screen state only; its views are
        // never used, and only Sources/TermCore/SwiftTermEngine.swift imports it.
        // Built from the submodule with this manifest rather than upstream's, which would
        // pull in swift-png, swift-argument-parser and swift-docc-plugin (none used on macOS).
        // Sources/SwiftTermBridge is Lite's own, compiled into the module (by the plugin,
        // since a target's sources must live under its path) so it can use internal API
        // (scrolling). Upstream's files are never edited.
        .target(
            name: "SwiftTerm",
            path: "Vendor/SwiftTerm/Sources/SwiftTerm",
            exclude: ["Documentation.docc", "Mac/README.md", "Apple/Metal/Shaders.metal", "iOS"],
            // Upstream warnings (mostly in its unused AppKit view) aren't ours to fix.
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])],
            // Generates upstream's build info + terminfo table, and adds Sources/SwiftTermBridge.
            plugins: ["SwiftTermBuildInfo"]
        ),
        .executableTarget(
            name: "SwiftTermBuildInfoGenerator",
            path: "Vendor/SwiftTerm/Sources/SwiftTermBuildInfoGenerator"
        ),
        .plugin(
            name: "SwiftTermBuildInfo",
            capability: .buildTool(),
            dependencies: ["SwiftTermBuildInfoGenerator"]
        ),

        // forkpty + execve in C: Swift can't fork safely.
        .target(name: "CPty", path: "Sources/CPty"),

        // Terminal model + PTY. No AppKit/Metal.
        .target(
            name: "TermCore",
            dependencies: ["CPty", "SwiftTerm"],
            path: "Sources/TermCore"
        ),

        // Metal + CoreText renderer. Shaders live in Resources/Shaders.metal (compiled at launch).
        .target(
            name: "TermRender",
            dependencies: ["TermCore"],
            path: "Sources/TermRender",
            linkerSettings: [
                .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"), .linkedFramework("AppKit"),
            ]
        ),

        .executableTarget(
            name: "Lite",
            dependencies: ["TermCore", "TermRender"],
            path: "Sources/Lite",
            linkerSettings: [.linkedFramework("AppKit")]
        ),

        .testTarget(name: "TermCoreTests", dependencies: ["TermCore"], path: "Tests/TermCoreTests"),
    ]
)
