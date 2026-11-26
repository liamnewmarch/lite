// Lite's bridge into SwiftTerm. NOT an upstream file: it lives outside the submodule
// (Vendor/SwiftTerm), but it's compiled into the SwiftTerm module (the SwiftTermBuildInfo
// plugin copies it in) so it can use internal API. Keep it tiny and public-only-what-we-need.
//
// SwiftTerm's own view scrolls via internal API (`lines.count`, `userScrolling`,
// `setViewYDisp`); these wrappers expose the same operations.

extension Terminal {
    /// Viewport position, in rows.
    /// - offset: how far the view is scrolled back from the live screen (0 = live).
    /// - maxOffset: rows of scrollback available (0 on the alternate screen).
    /// - topRow: "absolute" (scroll-invariant) row of the top visible line; stays
    ///   valid for the same line even as old scrollback is trimmed.
    /// - firstRow/endRow: absolute range of all lines (scrollback + screen).
    public var liteViewport: (offset: Int, maxOffset: Int, topRow: Int, firstRow: Int, endRow: Int) {
        let b = buffer
        let maxOffset = max(0, b.lines.count - rows)
        return (maxOffset - b.yDisp, maxOffset, b.yDisp + b.linesTop, b.linesTop, b.linesTop + b.lines.count)
    }

    /// Scrolls the viewport to `offset` rows back from the live screen (clamped).
    /// While scrolled back, new output doesn't move the view (`userScrolling`).
    public func liteScrollViewport(toOffset offset: Int) {
        let b = buffer
        let maxOffset = max(0, b.lines.count - rows)
        let clamped = max(0, min(offset, maxOffset))
        userScrolling = clamped > 0
        let target = maxOffset - clamped
        if target != b.yDisp {
            setViewYDisp(target)
            refresh(startRow: 0, endRow: rows)
        }
    }
}
