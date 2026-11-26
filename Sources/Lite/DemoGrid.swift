import Foundation
import TermCore

/// M3 test card: a static grid exercising colours, styles, Unicode and wide
/// characters. Replaced by live terminal output in M4.
enum DemoGrid {
    static func make(cols: Int, rows: Int) -> GridSnapshot {
        var g = GridSnapshot(cols: cols, rows: rows)
        var row = 0
        func line(_ build: (inout GridSnapshot, Int) -> Void) {
            guard row < rows else { return }
            build(&g, row)
            row += 1
        }

        line { g, r in g.put("Lite — Metal + CoreText glyph atlas (M3 test card)", col: 0, row: r, attrs: .bold) }
        line { _, _ in }

        // 16 ANSI colours as foreground and background.
        line { g, r in
            var c = g.put("ansi fg  ", col: 0, row: r, fg: .indexed(8))
            for i in 0..<16 { c = g.put(String(format: "%02d ", i), col: c, row: r, fg: .indexed(UInt8(i))) }
        }
        line { g, r in
            var c = g.put("ansi bg  ", col: 0, row: r, fg: .indexed(8))
            for i in 0..<16 { c = g.put("   ", col: c, row: r, bg: .indexed(UInt8(i))) }
        }

        // 256-colour cube + gray ramp, one cell each.
        line { g, r in
            var c = g.put("256      ", col: 0, row: r, fg: .indexed(8))
            for i in 16..<256 where c < cols { c = g.put(" ", col: c, row: r, bg: .indexed(UInt8(i))) }
        }

        // Truecolor gradient.
        line { g, r in
            var c = g.put("24-bit   ", col: 0, row: r, fg: .indexed(8))
            let width = max(cols - c, 1)
            for i in 0..<width {
                let t = Double(i) / Double(width)
                let rgb = hue(t)
                c = g.put("▀", col: c, row: r, fg: .rgb(rgb.0, rgb.1, rgb.2), bg: .rgb(rgb.2, rgb.0, rgb.1))
            }
        }
        line { _, _ in }

        // Styles.
        line { g, r in
            var c = g.put("styles   ", col: 0, row: r, fg: .indexed(8))
            let styles: [(String, CellAttributes)] = [
                ("regular", []), ("bold", .bold), ("italic", .italic), ("bold-italic", [.bold, .italic]),
                ("underline", .underline), ("strike", .strikethrough), ("dim", .dim), ("inverse", .inverse),
            ]
            for (name, attrs) in styles {
                c = g.put(name, col: c, row: r, attrs: attrs)
                c = g.put(" ", col: c, row: r)
            }
        }
        line { g, r in
            var c = g.put("mixed    ", col: 0, row: r, fg: .indexed(8))
            c = g.put("error:", col: c, row: r, fg: .indexed(9), attrs: .bold)
            c = g.put(" file ", col: c, row: r)
            c = g.put("main.swift", col: c, row: r, fg: .indexed(12), attrs: .underline)
            c = g.put(" line ", col: c, row: r)
            c = g.put(" 42 ", col: c, row: r, fg: .indexed(0), bg: .indexed(11))
        }
        line { _, _ in }

        // Unicode: Latin, symbols, box drawing, CJK (double width), emoji (colour, double width).
        line { g, r in
            var c = g.put("unicode  ", col: 0, row: r, fg: .indexed(8))
            c = g.put("café naïve ß λ → ✓ ★ ≠ ≤ ∞  ", col: c, row: r)
            c = g.put("┌─┬─┐ ╭─╮ ░▒▓█", col: c, row: r, fg: .indexed(6))
        }
        line { g, r in
            var c = g.put("wide     ", col: 0, row: r, fg: .indexed(8))
            c = g.put("日本語 한국어 中文", col: c, row: r)
            c = g.put(" | ", col: c, row: r, fg: .indexed(8))
            c = g.put("😀 👍🏽 🇬🇧 👨‍👩‍👧 🦀", col: c, row: r)
        }
        line { g, r in
            var c = g.put("ascii    ", col: 0, row: r, fg: .indexed(8))
            let ascii = String((33...126).map { Character(Unicode.Scalar(UInt8($0))) })
            c = g.put(ascii, col: c, row: r)
        }
        line { _, _ in }

        // A fake prompt with the block cursor after it.
        line { g, r in
            var c = g.put("~/code/lite", col: 0, row: r, fg: .indexed(4))
            c = g.put(" $ ", col: c, row: r, fg: .indexed(4))
            c = g.put("echo hello", col: c, row: r)
            g.cursor = CursorState(col: min(c, cols - 1), row: r, visible: true, style: .block)
        }
        line { _, _ in }

        // Fill the rest so the whole window shows text (helps spot seams/misalignment).
        let filler = "The quick brown fox jumps over the lazy dog. 0123456789 "
        while row < rows {
            line { g, r in
                let num = String(format: "%3d ", r + 1)
                var c = g.put(num, col: 0, row: r, fg: .indexed(8))
                while c < cols {
                    let before = c
                    c = g.put(filler, col: c, row: r, fg: .indexed(UInt8(7 + (r % 2) * 8)))
                    if c == before { break }
                }
            }
        }
        return g
    }

    private static func hue(_ t: Double) -> (UInt8, UInt8, UInt8) {
        func ch(_ offset: Double) -> UInt8 {
            let v = 0.5 + 0.5 * cos(2 * .pi * (t + offset))
            return UInt8((v * 255).rounded())
        }
        return (ch(0), ch(2.0 / 3), ch(1.0 / 3))
    }
}
