import Foundation

/// Renders raw PTY bytes as a readable, escaped single line for stdout logging,
/// e.g. `ESC[1mhi\r\n` → `\e[1mhi\r\n`. Used until there's a renderer, and
/// later behind `LITE_LOG_PTY=1`.
public enum PTYDebug {
    public static func escaped(_ bytes: UnsafeRawBufferPointer) -> String {
        var out = ""
        out.reserveCapacity(bytes.count)
        // Decode UTF-8 leniently so non-ASCII text stays readable.
        let text = String(decoding: bytes, as: UTF8.self)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x1B: out += "\\e"
            case 0x0D: out += "\\r"
            case 0x0A: out += "\\n"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x07: out += "\\a"
            case 0x5C: out += "\\\\"
            case 0x00..<0x20, 0x7F: out += String(format: "\\x%02x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
