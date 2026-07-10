import Foundation
import Testing
@testable import NotesCore

@Suite struct NoteMergerTests {
    private let t1 = Date(timeIntervalSince1970: 1_000)
    private let t2 = Date(timeIntervalSince1970: 2_000)
    private let t3 = Date(timeIntervalSince1970: 3_000)

    @Test func drawingAndTextMergeIndependently() {
        let id = UUID()
        // Side A: newer drawing. Side B: newer text.
        let a = Note(pages: [Page(id: id, drawingData: Data([0xA]), text: "old",
                                  drawingModified: t3, textModified: t1)])
        let b = Note(pages: [Page(id: id, drawingData: Data([0xB]), text: "new",
                                  drawingModified: t2, textModified: t2)])
        let merged = NoteMerger.merge(a, b)
        #expect(merged.pages.count == 1)
        #expect(merged.pages[0].drawingData == Data([0xA]))
        #expect(merged.pages[0].text == "new")
        #expect(merged.pages[0].drawingModified == t3)
        #expect(merged.pages[0].textModified == t2)
    }

    @Test func mergeIsSymmetric() {
        let id = UUID()
        let a = Note(pages: [Page(id: id, drawingData: Data([0xA]), drawingModified: t3)])
        let b = Note(pages: [Page(id: id, drawingData: Data([0xB]), drawingModified: t2)])
        #expect(NoteMerger.merge(a, b) == NoteMerger.merge(b, a))
    }

    @Test func pagesUniqueToEitherSideAreKept() {
        let shared = Page(text: "shared", textModified: t1)
        let onlyA = Page(text: "a only", textModified: t3)
        let onlyB = Page(text: "b only", textModified: t2)
        let a = Note(pages: [shared, onlyA])
        let b = Note(pages: [shared, onlyB])
        let merged = NoteMerger.merge(a, b)
        #expect(Set(merged.pages.map(\.id)) == Set([shared.id, onlyA.id, onlyB.id]))
    }

    @Test func orderFollowsNewerSideAndInsertsAfterPredecessor() {
        let p1 = Page(text: "1", textModified: t1)
        let p2 = Page(text: "2", textModified: t1)
        let inserted = Page(text: "1.5", textModified: t3)
        // Newer side (contains t3): [p1, inserted, p2]; older side: [p1, p2].
        let newer = Note(pages: [p1, inserted, p2])
        let older = Note(pages: [p1, p2])
        let merged = NoteMerger.merge(older, newer)
        #expect(merged.pages.map(\.id) == [p1.id, inserted.id, p2.id])
    }

    @Test func secondaryOnlyPageInsertsAfterItsPredecessor() {
        let p1 = Page(text: "1", textModified: t3)
        let p2 = Page(text: "2", textModified: t3)
        let extra = Page(text: "extra", textModified: t1)
        // Primary (newer): [p1, p2]. Secondary: [p1, extra, p2].
        let primary = Note(pages: [p1, p2])
        let secondary = Note(pages: [p1, extra, p2])
        let merged = NoteMerger.merge(primary, secondary)
        #expect(merged.pages.map(\.id) == [p1.id, extra.id, p2.id])
    }

    @Test func mergingIdenticalNotesIsIdentity() {
        let note = Note(pages: [Page(text: "x", textModified: t1),
                                Page(drawingData: Data([1]), drawingModified: t2)])
        #expect(NoteMerger.merge(note, note) == note)
    }

    @Test func pagesWithoutDatesLoseAgainstDatedPages() {
        let id = UUID()
        let dated = Note(pages: [Page(id: id, text: "dated", textModified: t1)])
        let undated = Note(pages: [Page(id: id, text: "undated")])
        let merged = NoteMerger.merge(undated, dated)
        #expect(merged.pages[0].text == "dated")
    }
}
