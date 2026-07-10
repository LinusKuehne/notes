import Foundation

/// `manifest.json` at the root of the `.note` package. Describes the format
/// version, paper size, and the ordered pages with their per-page
/// modification dates (used for last-writer-wins conflict merging).
public struct Manifest: Codable, Equatable, Sendable {
    public struct PageEntry: Codable, Equatable, Sendable {
        public var id: UUID
        public var drawingModified: Date?
        public var textModified: Date?

        public init(id: UUID, drawingModified: Date? = nil, textModified: Date? = nil) {
            self.id = id
            self.drawingModified = drawingModified
            self.textModified = textModified
        }
    }

    public var formatVersion: Int
    public var paper: String
    public var pages: [PageEntry]

    public init(formatVersion: Int = Note.currentFormatVersion, paper: String = "a4", pages: [PageEntry] = []) {
        self.formatVersion = formatVersion
        self.paper = paper
        self.pages = pages
    }

    public init(describing note: Note) {
        self.init(
            pages: note.pages.map {
                PageEntry(id: $0.id, drawingModified: $0.drawingModified, textModified: $0.textModified)
            }
        )
    }

    // MARK: JSON

    /// Deterministic encoding (sorted keys, stable date format) so that saving
    /// an unchanged note produces byte-identical output — this keeps iCloud
    /// from re-uploading an unchanged manifest. Dates are stored as
    /// milliseconds since 1970: exact roundtrip, no timezone/formatting
    /// ambiguity, and precise enough for last-writer-wins merging.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Manifest.self, from: data)
    }
}
