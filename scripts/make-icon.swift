// Renders a placeholder 1024×1024 app icon PNG with CoreGraphics + CoreText.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"
let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: ~100px margin, continuous-corner squircle (approximated with a rounded rect).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(path)
ctx.clip()
let gradient = CGGradient(colorsSpace: cs, colors: [
    CGColor(srgbRed: 0.18, green: 0.18, blue: 0.20, alpha: 1),
    CGColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// ">_" prompt glyphs.
let font = CTFontCreateWithName("Menlo-Bold" as CFString, 300, nil)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: CGColor(srgbRed: 0.55, green: 0.85, blue: 0.55, alpha: 1),
]
let line = CTLineCreateWithAttributedString(NSAttributedString(string: ">_", attributes: attrs))
ctx.textPosition = CGPoint(x: 230, y: 400)
CTLineDraw(line, ctx)

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("failed to write \(out)") }
