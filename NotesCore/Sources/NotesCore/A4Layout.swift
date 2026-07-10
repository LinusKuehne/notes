import Foundation

/// A4 paper geometry in PDF points (1 pt = 1/72 inch). 210 × 297 mm.
public enum A4 {
    public static let width: Double = 595.28
    public static let height: Double = 841.89
}

/// Pure geometry for the vertically scrolling stack of A4 pages, shared by
/// the notebook view (page frames, visibility) and the PDF exporter.
/// All values are in unscaled "paper" coordinates; the view multiplies by its
/// display scale / zoom.
public struct NotebookLayout: Equatable, Sendable {
    /// Vertical gap between consecutive pages.
    public var pageSpacing: Double
    /// Padding above the first and below the last page.
    public var verticalInset: Double

    public init(pageSpacing: Double = 24, verticalInset: Double = 24) {
        self.pageSpacing = pageSpacing
        self.verticalInset = verticalInset
    }

    /// Y origin of page `index` (0-based) in content coordinates.
    public func pageOriginY(at index: Int) -> Double {
        verticalInset + Double(index) * (A4.height + pageSpacing)
    }

    /// Total content height for `pageCount` pages.
    public func contentHeight(pageCount: Int) -> Double {
        guard pageCount > 0 else { return 2 * verticalInset }
        return pageOriginY(at: pageCount - 1) + A4.height + verticalInset
    }

    /// The page whose vertical span contains `y` (clamped to valid indices).
    /// The spacing below a page counts as belonging to that page.
    public func pageIndex(atY y: Double, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        let stride = A4.height + pageSpacing
        let index = Int(((y - verticalInset) / stride).rounded(.down))
        return min(max(index, 0), pageCount - 1)
    }

    /// Indices of pages intersecting the vertical window [minY, maxY],
    /// clamped to `0..<pageCount`. Empty when there are no pages.
    public func visiblePageIndices(minY: Double, maxY: Double, pageCount: Int) -> Range<Int> {
        guard pageCount > 0, maxY > minY else { return 0..<0 }
        let first = pageIndex(atY: minY, pageCount: pageCount)
        var last = pageIndex(atY: maxY, pageCount: pageCount)
        // pageIndex clamps into the page span; make sure `last` really
        // intersects the window (maxY may sit in the gap above it).
        if pageOriginY(at: last) > maxY { last = max(first, last - 1) }
        return first..<(last + 1)
    }

    /// Scale that fits the page width into `containerWidth` with `margin` on
    /// both sides.
    public static func fitScale(containerWidth: Double, margin: Double = 0) -> Double {
        guard containerWidth > 2 * margin else { return 1 }
        return (containerWidth - 2 * margin) / A4.width
    }
}
