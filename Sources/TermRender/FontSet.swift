import AppKit
import CoreText

/// Cell geometry in device pixels. Everything in the renderer is integer pixels so
/// glyphs and cell edges land exactly on the pixel grid (crisp, no seams).
public struct FontMetrics: Sendable, Equatable {
    public let cellWidth: Int
    public let cellHeight: Int
    /// Distance from the top of a cell to the text baseline.
    public let baseline: Int
    /// From the top of the cell.
    public let underlineY: Int
    public let underlineThickness: Int
    public let strikethroughY: Int
    /// Backing scale (2 on Retina): points → pixels.
    public let scale: CGFloat
}

/// The four style variants of one font, at *pixel* size (point size × scale).
/// Rasterising at pixel size, rather than scaling a 1× bitmap, is what makes
/// Retina text sharp.
@MainActor
public final class FontSet {
    public enum Variant: Int, CaseIterable { case regular, bold, italic, boldItalic }

    public let pointSize: CGFloat
    public let metrics: FontMetrics
    private let fonts: [CTFont]

    public init(font: CTFont, scale: CGFloat) {
        pointSize = CTFontGetSize(font)
        let base = CTFontCreateCopyWithAttributes(font, pointSize * scale, nil, nil)
        func variant(_ traits: CTFontSymbolicTraits) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
        }
        fonts = [base, variant(.traitBold), variant(.traitItalic), variant([.traitBold, .traitItalic])]

        // Cell width = advance of "M" (all glyphs share it in a monospace font).
        var unichar: UniChar = 0x4D
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(base, &unichar, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(base, .horizontal, &glyph, &advance, 1)

        let ascent = CTFontGetAscent(base)
        let descent = CTFontGetDescent(base)
        let leading = CTFontGetLeading(base)
        let cellHeight = Int((ascent + descent + leading).rounded(.up))
        let baseline = Int((leading / 2 + ascent).rounded())
        let underlinePos = CTFontGetUnderlinePosition(base) // negative = below baseline
        let thickness = max(1, Int(CTFontGetUnderlineThickness(base).rounded()))

        metrics = FontMetrics(
            // Round to nearest, not up: SF Mono's 16.07px advance at 26px would become
            // 17px and leave a visible gap between every pair of glyphs.
            cellWidth: max(1, Int(advance.width.rounded())),
            cellHeight: max(1, cellHeight),
            baseline: baseline,
            underlineY: min(cellHeight - thickness, baseline - Int(underlinePos.rounded()) ),
            underlineThickness: thickness,
            strikethroughY: baseline - Int((CTFontGetXHeight(base) / 2).rounded()),
            scale: scale
        )
    }

    public func font(_ variant: Variant) -> CTFont { fonts[variant.rawValue] }

    /// The default terminal font: the system monospaced font (SF Mono).
    public static func defaultFont(size: CGFloat = 13) -> CTFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
    }
}
