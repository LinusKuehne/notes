import Foundation

/// A single A4 page of the note.
///
/// `drawingData` is an opaque blob (`PKDrawing.dataRepresentation()` on Apple
/// platforms). NotesCore never interprets it, which keeps this package
/// buildable and testable on Linux.
public struct Page: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var drawingData: Data
    public var text: String
    /// Last time the drawing changed. `nil` when the page never had ink.
    public var drawingModified: Date?
    /// Last time the typed text changed. `nil` when the page never had text.
    public var textModified: Date?

    public init(
        id: UUID = UUID(),
        drawingData: Data = Data(),
        text: String = "",
        drawingModified: Date? = nil,
        textModified: Date? = nil
    ) {
        self.id = id
        self.drawingData = drawingData
        self.text = text
        self.drawingModified = drawingModified
        self.textModified = textModified
    }

    /// A page with no ink and no text. Empty pages at the end of the note are
    /// not persisted; the UI always shows one as the "next" page.
    public var isEmpty: Bool {
        drawingData.isEmpty && text.isEmpty
    }

    /// The most recent of the page's modification dates.
    public var lastModified: Date? {
        switch (drawingModified, textModified) {
        case let (d?, t?): return max(d, t)
        case let (d?, nil): return d
        case let (nil, t?): return t
        case (nil, nil): return nil
        }
    }
}

/// The single note of Stage 1: an ordered list of A4 pages.
public struct Note: Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var pages: [Page]

    public init(pages: [Page] = []) {
        self.pages = pages
    }

    public var isEmpty: Bool {
        pages.allSatisfy(\.isEmpty)
    }

    /// The most recent modification date across all pages.
    public var lastModified: Date? {
        pages.compactMap(\.lastModified).max()
    }

    /// The note as it should be persisted: trailing empty pages removed.
    /// (The always-present blank page after the last content is a pure view
    /// concept and must never reach disk or the PDF export.)
    public func normalizedForSave() -> Note {
        var trimmed = pages
        while let last = trimmed.last, last.isEmpty {
            trimmed.removeLast()
        }
        return Note(pages: trimmed)
    }

    public func page(withID id: UUID) -> Page? {
        pages.first { $0.id == id }
    }

    public mutating func updatePage(_ page: Page) {
        guard let index = pages.firstIndex(where: { $0.id == page.id }) else {
            pages.append(page)
            return
        }
        pages[index] = page
    }
}
