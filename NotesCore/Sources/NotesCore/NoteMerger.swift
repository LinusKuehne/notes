import Foundation

/// Automatic conflict resolution between two versions of the same note
/// (e.g. edited offline on iPad and Mac). Merging is per page and per layer,
/// last writer wins:
///
/// - A page present in both versions takes its drawing from whichever side
///   modified the drawing more recently, and its text from whichever side
///   modified the text more recently (the two can come from different sides).
/// - Pages present on only one side are kept.
/// - Page order follows the side with the most recent modification overall;
///   pages unique to the other side are inserted after the page that precedes
///   them there (or appended at the end).
public struct NoteMerger {
    public static func merge(_ a: Note, _ b: Note) -> Note {
        // `primary` drives the page order.
        let aDate = a.lastModified ?? .distantPast
        let bDate = b.lastModified ?? .distantPast
        let (primary, secondary) = aDate >= bDate ? (a, b) : (b, a)

        let secondaryByID = Dictionary(uniqueKeysWithValues: secondary.pages.map { ($0.id, $0) })
        let primaryIDs = Set(primary.pages.map(\.id))

        var merged = primary.pages.map { page -> Page in
            guard let other = secondaryByID[page.id] else { return page }
            return mergePage(page, other)
        }

        // Insert pages that exist only in `secondary`, preserving their local
        // neighborhood: each goes right after its predecessor in `secondary`.
        for (index, page) in secondary.pages.enumerated() where !primaryIDs.contains(page.id) {
            let predecessor = secondary.pages[..<index].last { primaryIDs.contains($0.id) }
            if let predecessor,
               let anchor = merged.firstIndex(where: { $0.id == predecessor.id }) {
                merged.insert(page, at: anchor + 1)
            } else if predecessor == nil, index < secondary.pages.count {
                merged.insert(page, at: min(index, merged.count))
            } else {
                merged.append(page)
            }
        }

        return Note(pages: merged)
    }

    private static func mergePage(_ a: Page, _ b: Page) -> Page {
        precondition(a.id == b.id)
        var result = a

        let aDrawing = a.drawingModified ?? .distantPast
        let bDrawing = b.drawingModified ?? .distantPast
        if bDrawing > aDrawing {
            result.drawingData = b.drawingData
            result.drawingModified = b.drawingModified
        }

        let aText = a.textModified ?? .distantPast
        let bText = b.textModified ?? .distantPast
        if bText > aText {
            result.text = b.text
            result.textModified = b.textModified
        }

        return result
    }
}
