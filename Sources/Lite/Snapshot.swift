import AppKit
import ImageIO
import TermCore
import TermRender

/// `Lite --snapshot out.png [--run "command" [--wait secs] [--scroll rows]] [--select r1,c1,r2,c2] [--overlay] [--size 800x500] [--scale 2] [--bench N]`
///
/// Renders offscreen through the real renderer and writes a PNG, without opening
/// a window. Without `--run` it renders the static test card; with `--run` it
/// runs the command on a real PTY through the terminal engine (the full live
/// pipeline), waits for it to exit (or `--wait` seconds, default 10, so full-screen
/// programs like vim can be captured while running), and renders the screen.
/// For checking rendering without screen access or Xcode frame capture.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = args[i + 1]
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        let sizeParts = (value("--size") ?? "800x500").split(separator: "x").compactMap { Double($0) }
        let points = CGSize(width: sizeParts.first ?? 800, height: sizeParts.last ?? 500)
        let scale = CGFloat(Double(value("--scale") ?? "2") ?? 2)

        do {
            let context = try RenderContext.shared()
            // Uses your config's font and colours, like the app (pass --no-config for defaults).
            let config = args.contains("--no-config") ? Config() : Config.load().0
            let renderer = TerminalRenderer(context: context, font: config.makeFont().0, scale: scale,
                                            palette: config.palette)
            renderer.showsOverlay = args.contains("--overlay")
            let m = renderer.metrics
            let w = Int(points.width * scale), h = Int(points.height * scale)
            let origin = (x: Int(6 * scale), y: Int(30 * scale)) // ≈ title bar inset
            let cols = (w - origin.x * 2) / m.cellWidth
            let rows = (h - origin.y - Int(4 * scale)) / m.cellHeight
            var grid: GridSnapshot
            if let command = value("--run") {
                let wait = value("--wait").flatMap(Double.init) ?? 10
                let scroll = value("--scroll").flatMap(Int.init) ?? 0
                grid = try runCommand(command, cols: cols, rows: rows, wait: wait, scroll: scroll)
            } else {
                grid = DemoGrid.make(cols: cols, rows: rows)
            }

            // --select r1,c1,r2,c2 (visible coordinates): draw a selection highlight.
            if let sel = value("--select")?.split(separator: ",").compactMap({ Int($0) }), sel.count == 4 {
                grid.selection = SelectionHighlight(startCol: sel[1], startRow: sel[0], endCol: sel[3], endRow: sel[2])
            }

            // Render twice: the first frame rasterises glyphs; the second has real timings.
            _ = renderer.renderImage(grid, width: w, height: h, origin: origin)
            guard let image = renderer.renderImage(grid, width: w, height: h, origin: origin) else {
                fatalError("render failed")
            }
            if let n = value("--bench").flatMap(Int.init) {
                var cpu: [Double] = [], gpu: [Double] = []
                for _ in 0..<n {
                    _ = renderer.renderImage(grid, width: w, height: h, origin: origin)
                    let t = renderer.lastFrameTimes
                    cpu.append(t.cpuMs); gpu.append(t.gpuMs)
                }
                cpu.sort(); gpu.sort()
                print(String(format: "[bench] %d frames  cpu median %.3f ms (min %.3f, max %.3f)  gpu median %.3f ms",
                             n, cpu[n / 2], cpu.first!, cpu.last!, gpu[n / 2]))
            }
            let url = URL(fileURLWithPath: out) as CFURL
            guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
                fatalError("can't write \(out)")
            }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            print("[snapshot] \(cols)x\(rows) cells, \(w)x\(h)px, cell \(m.cellWidth)x\(m.cellHeight)px → \(out)")
            exit(0)
        } catch {
            print("[snapshot] \(error)")
            exit(1)
        }
    }

    private static func runCommand(_ command: String, cols: Int, rows: Int, wait: Double, scroll: Int) throws -> GridSnapshot {
        let env = ShellCommand.terminalEnvironment(base: ProcessInfo.processInfo.environment)
        let shell = ShellCommand(path: "/bin/sh", arguments: ["/bin/sh", "-c", command], environment: env,
                                 workingDirectory: FileManager.default.currentDirectoryPath)
        nonisolated(unsafe) var exited: Int32?
        var handlers = TerminalSession.Handlers()
        handlers.exit = { code in exited = code }
        let session = try TerminalSession(command: shell,
                                          size: PTYProcess.Size(cols: UInt16(cols), rows: UInt16(rows)),
                                          handlers: handlers)
        // Spin the main run loop (which also runs main-actor tasks) until the command exits.
        let deadline = Date().addingTimeInterval(wait)
        while exited == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1)) // let trailing output be parsed
        print("[snapshot] command \(exited.map { "exited with \($0)" } ?? "still running after \(wait)s")")
        if scroll > 0 { session.engine.scrollViewport(toOffset: scroll) }
        var grid = GridSnapshot(cols: 0, rows: 0)
        session.snapshot(into: &grid)
        session.terminate()
        return grid
    }
}
