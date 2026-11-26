import AppKit
import TermCore

/// Mouse: selection, scrolling, reporting to programs, and the clipboard.
///
/// When the program has asked for mouse events (vim `mouse=a`, htop, tmux), clicks
/// and the wheel go to it. Holding Shift overrides that and selects text instead,
/// the xterm convention.
extension TerminalView: NSMenuItemValidation {
    private func reportsMouse(_ event: NSEvent) -> Bool {
        guard let session else { return false }
        return session.modes.mouseReporting && !event.modifierFlags.contains(.shift)
    }

    private func report(_ kind: MouseReport.Kind, button: Int, event: NSEvent) {
        let c = cell(at: convert(event.locationInWindow, from: nil))
        let f = event.modifierFlags
        session?.engine.sendMouse(MouseReport(kind: kind, button: button, col: c.col, row: c.row,
                                              shift: f.contains(.shift), option: f.contains(.option),
                                              control: f.contains(.control)))
    }

    /// Absolute grid point under the mouse.
    private func gridPoint(_ event: NSEvent) -> GridPoint {
        let p = convert(event.locationInWindow, from: nil)
        let c = cell(at: p)
        return GridPoint(row: (session?.engine.viewport.topRow ?? 0) + c.row, col: c.col)
    }

    // MARK: - Buttons

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if reportsMouse(event) {
            mouseButtonReported = 0
            report(.press, button: 0, event: event)
            return
        }
        let point = gridPoint(event)
        switch event.clickCount {
        case 2: selection = TextSelection(anchor: point, granularity: .word)
        case 3...: selection = TextSelection(anchor: point, granularity: .line)
        default:
            if event.modifierFlags.contains(.shift), var s = selection {
                s.head = point // Shift-click extends
                selection = s
            } else {
                selection = TextSelection(anchor: point)
            }
        }
        setNeedsRender()
    }

    override func mouseDragged(with event: NSEvent) {
        if let button = mouseButtonReported {
            report(.drag, button: button, event: event)
            return
        }
        guard selection != nil else { return }
        updateSelectionHead(event)
        // Dragging above/below the grid scrolls, so you can select beyond the screen.
        let row = rawRow(at: convert(event.locationInWindow, from: nil))
        let rows = geometry?.rows ?? 0
        if row < 0 || row >= rows {
            startAutoscroll(direction: row < 0 ? 1 : -1, event: event)
        } else {
            stopAutoscroll()
        }
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoscroll()
        if let button = mouseButtonReported {
            mouseButtonReported = nil
            report(.release, button: button, event: event)
            return
        }
        if selection?.isEmpty == true {
            selection = nil // a plain click clears the selection
            setNeedsRender()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let session, session.modes.mouseMotion, !event.modifierFlags.contains(.shift) else { return }
        report(.move, button: 0, event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if reportsMouse(event) { mouseButtonReported = 2; report(.press, button: 2, event: event) }
        else { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if mouseButtonReported == 2 { mouseButtonReported = nil; report(.release, button: 2, event: event) }
        else { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if reportsMouse(event) { mouseButtonReported = 1; report(.press, button: 1, event: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if mouseButtonReported == 1 { mouseButtonReported = nil; report(.release, button: 1, event: event) }
    }

    private func updateSelectionHead(_ event: NSEvent) {
        guard var s = selection else { return }
        let head = gridPoint(event)
        guard head != s.head else { return }
        s.head = head
        selection = s
        setNeedsRender()
    }

    private func startAutoscroll(direction: Int, event: NSEvent) {
        guard autoscrollTimer == nil else { return }
        autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let engine = self.session?.engine else { return }
                engine.scrollViewport(toOffset: engine.viewport.offset + direction)
                if var s = self.selection, let rows = self.geometry?.rows {
                    let v = engine.viewport
                    s.head.row = direction > 0 ? v.topRow : v.topRow + rows - 1
                    self.selection = s
                }
                self.setNeedsRender()
            }
        }
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    // MARK: - Scrolling

    /// Trackpads send many small precise deltas (points); mouse wheels send coarse
    /// "lines". Both are accumulated into whole rows.
    override func scrollWheel(with event: NSEvent) {
        guard let session else { return }
        if event.phase == .began { scrollAccumulator = 0 }
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / cellHeightPoints
            : event.scrollingDeltaY * 3
        scrollAccumulator += delta
        let rows = Int(scrollAccumulator) // truncates toward zero
        guard rows != 0 else { return }
        scrollAccumulator -= CGFloat(rows)
        // Positive = towards older content.

        let modes = session.modes
        if reportsMouse(event) {
            for _ in 0..<min(abs(rows), 10) {
                report(rows > 0 ? .scrollUp : .scrollDown, button: 0, event: event)
            }
        } else if modes.alternateScreen {
            // Full-screen programs (less, man, vim without mouse) have no scrollback:
            // send arrow keys instead ("alternate scroll"), as most terminals do.
            let key: KeyEncoder.Key = rows > 0 ? .up : .down
            let bytes = KeyEncoder.encode(key, modes: modes)
            session.write(Array(repeating: bytes, count: min(abs(rows), 10)).flatMap { $0 })
        } else {
            let engine = session.engine
            engine.scrollViewport(toOffset: engine.viewport.offset + rows)
            setNeedsRender()
        }
    }

    // MARK: - Clipboard (Edit menu: Cmd-C / Cmd-V / Cmd-A)

    func selectedText() -> String? {
        guard let selection, !selection.isEmpty, let engine = session?.engine else { return nil }
        let (a, b) = selection.resolved(cols: grid.cols) { engine.line(absoluteRow: $0)?.cells }
        let text = engine.text(from: a, to: b)
        return text.isEmpty ? nil : text
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText() else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let session, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        send(KeyEncoder.paste(text, bracketed: session.modes.bracketedPaste))
    }

    override func selectAll(_ sender: Any?) {
        guard let engine = session?.engine else { return }
        let v = engine.viewport
        selection = TextSelection(anchor: GridPoint(row: v.firstRow, col: 0),
                                  head: GridPoint(row: v.endRow - 1, col: max(grid.cols - 1, 0)))
        setNeedsRender()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return selectedText() != nil
        case #selector(paste(_:)): return NSPasteboard.general.string(forType: .string) != nil
        default: return true
        }
    }
}
