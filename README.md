# Lite

Liam’s terminal emulator

A small, fast, native macOS terminal: AppKit windows and tabs, Metal rendering, and
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the terminal emulation.
It’s very much a work in progress, built mainly for my own use, so expect rough edges
and things to change.

## Build

You need macOS 27 or later on Apple Silicon, and the Xcode Command Line Tools
(`xcode-select --install`). Xcode itself isn’t needed.

```sh
git clone --recurse-submodules https://github.com/liamnewmarch/lite.git
cd lite
make            # builds build/Lite.app
make run        # builds and runs it
make install    # installs to /Applications
```

Settings live in `~/.config/lite/config`. Open them from Lite › Settings… (⌘,).
