import Foundation

/// Platform-neutral stand-in for a directory `FileWrapper` tree, so the
/// package layout logic is fully testable on Linux. The app target converts
/// `FileNode` to/from real `FileWrapper`s in a few lines.
public enum FileNode: Equatable, Sendable {
    case file(Data)
    indirect case directory([String: FileNode])

    public var isDirectory: Bool {
        if case .directory = self { return true }
        return false
    }

    public subscript(name: String) -> FileNode? {
        guard case .directory(let children) = self else { return nil }
        return children[name]
    }

    public var fileData: Data? {
        guard case .file(let data) = self else { return nil }
        return data
    }
}

public enum NotePackageError: Error, Equatable {
    case notADirectory
    case missingManifest
    case corruptManifest(String)
    /// The package was written by a newer app version. We refuse to load it
    /// rather than silently drop data we don't understand.
    case unsupportedFormatVersion(Int)
}

/// Maps `Note` ⇄ the on-disk `.note` package layout:
///
///     Main.note/
///       manifest.json          format version, page order, per-page dates
///       pages/<uuid>.drawing   raw PKDrawing data, only when the page has ink
///       text/<uuid>.md         markdown source, only when the page has text
///
/// One file per page keeps iCloud uploads incremental and conflicts local to
/// a page. Trailing empty pages are trimmed before writing.
public struct NotePackageSerializer {
    public static let manifestName = "manifest.json"
    public static let pagesDirectoryName = "pages"
    public static let textDirectoryName = "text"
    public static let drawingExtension = "drawing"
    public static let textExtension = "md"

    // MARK: Note → file tree

    public static func fileTree(for note: Note) throws -> FileNode {
        let normalized = note.normalizedForSave()
        let manifest = Manifest(describing: normalized)

        var pageFiles: [String: FileNode] = [:]
        var textFiles: [String: FileNode] = [:]
        for page in normalized.pages {
            if !page.drawingData.isEmpty {
                pageFiles["\(page.id.uuidString).\(drawingExtension)"] = .file(page.drawingData)
            }
            if !page.text.isEmpty {
                textFiles["\(page.id.uuidString).\(textExtension)"] = .file(Data(page.text.utf8))
            }
        }

        var root: [String: FileNode] = [
            manifestName: .file(try manifest.jsonData())
        ]
        if !pageFiles.isEmpty { root[pagesDirectoryName] = .directory(pageFiles) }
        if !textFiles.isEmpty { root[textDirectoryName] = .directory(textFiles) }
        return .directory(root)
    }

    // MARK: File tree → Note

    public static func note(from tree: FileNode) throws -> Note {
        guard tree.isDirectory else {
            throw NotePackageError.notADirectory
        }
        guard let manifestData = tree[manifestName]?.fileData else {
            throw NotePackageError.missingManifest
        }
        let manifest: Manifest
        do {
            manifest = try Manifest.decode(from: manifestData)
        } catch {
            throw NotePackageError.corruptManifest(String(describing: error))
        }
        guard manifest.formatVersion <= Note.currentFormatVersion else {
            throw NotePackageError.unsupportedFormatVersion(manifest.formatVersion)
        }

        let pagesDir = tree[pagesDirectoryName]
        let textDir = tree[textDirectoryName]

        let pages = manifest.pages.map { entry -> Page in
            let drawingData = pagesDir?["\(entry.id.uuidString).\(drawingExtension)"]?.fileData ?? Data()
            let textData = textDir?["\(entry.id.uuidString).\(textExtension)"]?.fileData
            let text = textData.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return Page(
                id: entry.id,
                drawingData: drawingData,
                text: text,
                drawingModified: entry.drawingModified,
                textModified: entry.textModified
            )
        }
        return Note(pages: pages)
    }
}
