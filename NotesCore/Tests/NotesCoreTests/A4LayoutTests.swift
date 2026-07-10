import Foundation
import Testing
@testable import NotesCore

@Suite struct A4LayoutTests {
    let layout = NotebookLayout(pageSpacing: 20, verticalInset: 10)

    @Test func pageOrigins() {
        #expect(layout.pageOriginY(at: 0) == 10)
        #expect(layout.pageOriginY(at: 1) == 10 + A4.height + 20)
    }

    @Test func contentHeight() {
        #expect(layout.contentHeight(pageCount: 0) == 20)
        #expect(layout.contentHeight(pageCount: 1) == 10 + A4.height + 10)
        #expect(layout.contentHeight(pageCount: 3) == 10 + 3 * A4.height + 2 * 20 + 10)
    }

    @Test func pageIndexClampsAndAssignsGaps() {
        let count = 5
        #expect(layout.pageIndex(atY: -100, pageCount: count) == 0)
        #expect(layout.pageIndex(atY: 0, pageCount: count) == 0)
        // Just inside page 1.
        #expect(layout.pageIndex(atY: layout.pageOriginY(at: 1) + 1, pageCount: count) == 1)
        // In the gap below page 1 → still page 1.
        #expect(layout.pageIndex(atY: layout.pageOriginY(at: 1) + A4.height + 5, pageCount: count) == 1)
        // Far below everything → last page.
        #expect(layout.pageIndex(atY: 1e9, pageCount: count) == count - 1)
        #expect(layout.pageIndex(atY: 100, pageCount: 0) == 0)
    }

    @Test func visiblePageIndices() {
        let count = 10
        // Window covering the top of the stack.
        #expect(layout.visiblePageIndices(minY: 0, maxY: A4.height / 2, pageCount: count) == 0..<1)
        // Window spanning the boundary of pages 0 and 1.
        let boundary = layout.pageOriginY(at: 1)
        #expect(layout.visiblePageIndices(minY: boundary - 50, maxY: boundary + 50, pageCount: count) == 0..<2)
        // Window entirely inside the gap between pages 0 and 1 → page 0 only.
        let gapStart = layout.pageOriginY(at: 0) + A4.height
        #expect(layout.visiblePageIndices(minY: gapStart + 2, maxY: gapStart + 10, pageCount: count) == 0..<1)
        // Degenerate and empty inputs.
        #expect(layout.visiblePageIndices(minY: 100, maxY: 50, pageCount: count).isEmpty)
        #expect(layout.visiblePageIndices(minY: 0, maxY: 100, pageCount: 0).isEmpty)
    }

    @Test func fitScale() {
        #expect(NotebookLayout.fitScale(containerWidth: A4.width) == 1)
        #expect(NotebookLayout.fitScale(containerWidth: 2 * A4.width) == 2)
        #expect(abs(NotebookLayout.fitScale(containerWidth: A4.width + 40, margin: 20) - 1) < 1e-9)
        #expect(NotebookLayout.fitScale(containerWidth: 10, margin: 20) == 1)
    }
}
