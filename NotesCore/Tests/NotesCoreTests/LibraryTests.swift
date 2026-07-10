import Foundation
import Testing
@testable import NotesCore

@Suite struct LibraryTests {
    @Test func sanitizedFileNames() {
        #expect(Library.sanitizedFileName(fromTitle: "Analysis III") == "Analysis III")
        #expect(Library.sanitizedFileName(fromTitle: "a/b:c") == "a-b-c")
        #expect(Library.sanitizedFileName(fromTitle: "  spaced  ") == "spaced")
        #expect(Library.sanitizedFileName(fromTitle: "...hidden") == "hidden")
        #expect(Library.sanitizedFileName(fromTitle: "   ") == "Untitled")
        #expect(Library.sanitizedFileName(fromTitle: "") == "Untitled")
        #expect(Library.sanitizedFileName(fromTitle: String(repeating: "x", count: 200)).count <= 80)
    }

    @Test func uniqueNames() {
        #expect(Library.uniqueName(base: "Note", existing: []) == "Note")
        #expect(Library.uniqueName(base: "Note", existing: ["Note"]) == "Note 2")
        #expect(Library.uniqueName(base: "Note", existing: ["note"]) == "Note 2")
        #expect(Library.uniqueName(base: "Note", existing: ["Note", "Note 2", "NOTE 3"]) == "Note 4")
    }

    @Test func scratchpadNameIsStable() {
        // The formatter uses the local timezone (names are user-facing), so
        // only check shape and determinism, not the exact date.
        let date = Date(timeIntervalSince1970: 1_752_000_000)
        let name = Library.scratchpadName(for: date)
        #expect(name.wholeMatch(of: /Scratch \d{4}-\d{2}-\d{2} \d{2}\.\d{2}/) != nil)
        #expect(Library.scratchpadName(for: date) == name)
    }

    @Test func appendPagesJoinsContentAndDropsTrailingBlanks() {
        let a1 = Page(text: "a1", textModified: Date(timeIntervalSince1970: 1))
        let b1 = Page(drawingData: Data([1]), drawingModified: Date(timeIntervalSince1970: 2))
        var target = Note(pages: [a1])
        var source = Note(pages: [b1, Page()]) // trailing blank never travels
        target.appendPages(of: source)
        #expect(target.pages.map(\.id) == [a1.id, b1.id])

        // Appending an empty note is a no-op.
        source = Note(pages: [Page()])
        target.appendPages(of: source)
        #expect(target.pages.count == 2)
    }
}
