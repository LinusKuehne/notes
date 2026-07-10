import Foundation

/// Library-level conventions and pure helpers. The library itself is plain
/// directory structure inside the app's container:
///
///     Documents/
///       Main.note                  ← a note (package)
///       Uni/
///         Analysis III.note
///       Unsorted/                  ← scratchpad captures land here
///         Scratch 2026-07-10 09.41.note
///
/// A note's title IS its file name (minus the extension) — file-native, so
/// Files/Finder show the same names and renames are just file renames.
public enum Library {
    public static let noteExtension = "note"
    /// Folder that receives scratchpad quick-capture notes.
    public static let unsortedFolderName = "Unsorted"
    /// Reserved directory names that are not user content.
    public static let reservedFolderNames: Set<String> = ["Backups"]

    // MARK: Titles ↔ file names

    /// Turns a user-entered title into a safe file name (no path separators
    /// or leading dots; trimmed; never empty).
    public static func sanitizedFileName(fromTitle title: String) -> String {
        var name = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        if name.isEmpty {
            name = "Untitled"
        }
        // Keep names comfortably under filesystem limits.
        if name.count > 80 {
            name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// Returns `base`, or `base 2`, `base 3`, … — the first name not in
    /// `existing` (case-insensitive, as iCloud Drive's filesystem is).
    public static func uniqueName(base: String, existing: Set<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        if !taken.contains(base.lowercased()) {
            return base
        }
        var counter = 2
        while taken.contains("\(base) \(counter)".lowercased()) {
            counter += 1
        }
        return "\(base) \(counter)"
    }

    /// Default name for a scratchpad capture created at `date`.
    public static func scratchpadName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Scratch \(formatter.string(from: date))"
    }
}

extension Note {
    /// Appends `other`'s content pages at the end of this note — the
    /// "connect a scratchpad capture to a real note" operation. Page IDs are
    /// UUIDs, so pages keep their identity (and their drawing/text files
    /// carry over unchanged in the package).
    public mutating func appendPages(of other: Note) {
        pages.append(contentsOf: other.normalizedForSave().pages)
    }
}
