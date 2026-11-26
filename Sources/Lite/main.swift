import AppKit

// Writing to a PTY whose child has gone must return an error, not kill the app.
// (The child resets this to the default before exec.)
signal(SIGPIPE, SIG_IGN)

// Debug logs should appear immediately even when stdout is a file or pipe.
setvbuf(stdout, nil, _IOLBF, 0)

// `--snapshot out.png`: render the test card offscreen and exit (no window).
Snapshot.runIfRequested()

// Top-level code in main.swift runs on the main actor in Swift 6.
// NSApplication.delegate is weak, so we keep a strong reference here.
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
