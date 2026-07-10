import Foundation
import Testing
@testable import NotesCore

@Suite struct NoteModelTests {
    @Test func pageEmptiness() {
        #expect(Page().isEmpty)
        #expect(!Page(drawingData: Data([1, 2])).isEmpty)
        #expect(!Page(text: "hi").isEmpty)
    }

    @Test func pageLastModified() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)
        #expect(Page().lastModified == nil)
        #expect(Page(drawingModified: late, textModified: early).lastModified == late)
        #expect(Page(drawingModified: nil, textModified: early).lastModified == early)
    }

    @Test func normalizedForSaveTrimsTrailingEmptyPages() {
        let content = Page(text: "content")
        let note = Note(pages: [content, Page(), Page()])
        let saved = note.normalizedForSave()
        #expect(saved.pages.count == 1)
        #expect(saved.pages.first?.id == content.id)
    }

    @Test func normalizedForSaveKeepsInteriorEmptyPages() {
        let first = Page(text: "a")
        let middle = Page() // intentionally blank page between content
        let last = Page(drawingData: Data([9]))
        let saved = Note(pages: [first, middle, last, Page()]).normalizedForSave()
        #expect(saved.pages.map(\.id) == [first.id, middle.id, last.id])
    }

    @Test func normalizedForSaveOfEmptyNoteIsEmpty() {
        #expect(Note(pages: [Page(), Page()]).normalizedForSave().pages.isEmpty)
    }

    @Test func updatePageReplacesOrAppends() {
        var note = Note(pages: [Page(text: "one")])
        var page = note.pages[0]
        page.text = "changed"
        note.updatePage(page)
        #expect(note.pages.count == 1)
        #expect(note.pages[0].text == "changed")

        let newPage = Page(text: "two")
        note.updatePage(newPage)
        #expect(note.pages.count == 2)
        #expect(note.pages[1].id == newPage.id)
    }
}
