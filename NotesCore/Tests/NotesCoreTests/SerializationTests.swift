import Foundation
import Testing
@testable import NotesCore

@Suite struct ManifestTests {
    @Test func roundTripPreservesDatesAtMillisecondPrecision() throws {
        let date = Date(timeIntervalSince1970: 1_752_000_000.123)
        let manifest = Manifest(pages: [
            .init(id: UUID(), drawingModified: date, textModified: nil)
        ])
        let decoded = try Manifest.decode(from: manifest.jsonData())
        #expect(decoded.pages.count == 1)
        let decodedDate = try #require(decoded.pages[0].drawingModified)
        #expect(abs(decodedDate.timeIntervalSince1970 - date.timeIntervalSince1970) < 0.001)
        #expect(decoded.pages[0].textModified == nil)
        #expect(decoded.formatVersion == Note.currentFormatVersion)
        #expect(decoded.paper == "a4")
    }

    @Test func encodingIsDeterministic() throws {
        let manifest = Manifest(pages: [
            .init(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                  drawingModified: Date(timeIntervalSince1970: 1_000),
                  textModified: Date(timeIntervalSince1970: 2_000))
        ])
        #expect(try manifest.jsonData() == manifest.jsonData())
    }
}

@Suite struct NotePackageSerializerTests {
    private func makeNote() -> Note {
        Note(pages: [
            Page(drawingData: Data([1, 2, 3]),
                 text: "# Heading\nBody",
                 drawingModified: Date(timeIntervalSince1970: 1_000),
                 textModified: Date(timeIntervalSince1970: 2_000)),
            Page(drawingData: Data([4, 5]),
                 text: "",
                 drawingModified: Date(timeIntervalSince1970: 3_000)),
            Page(drawingData: Data(),
                 text: "text only",
                 textModified: Date(timeIntervalSince1970: 4_000)),
        ])
    }

    @Test func roundTrip() throws {
        let note = makeNote()
        let tree = try NotePackageSerializer.fileTree(for: note)
        let loaded = try NotePackageSerializer.note(from: tree)
        #expect(loaded == note)
    }

    @Test func emptyLayersProduceNoFiles() throws {
        let note = makeNote()
        let tree = try NotePackageSerializer.fileTree(for: note)

        let pagesDir = try #require(tree[NotePackageSerializer.pagesDirectoryName])
        guard case .directory(let pageFiles) = pagesDir else {
            Issue.record("pages is not a directory"); return
        }
        // Page 3 has no ink → no .drawing file.
        #expect(pageFiles.count == 2)

        let textDir = try #require(tree[NotePackageSerializer.textDirectoryName])
        guard case .directory(let textFiles) = textDir else {
            Issue.record("text is not a directory"); return
        }
        // Page 2 has no text → no .md file.
        #expect(textFiles.count == 2)
    }

    @Test func trailingEmptyPagesAreNotPersisted() throws {
        var note = makeNote()
        note.pages.append(Page())
        let tree = try NotePackageSerializer.fileTree(for: note)
        let loaded = try NotePackageSerializer.note(from: tree)
        #expect(loaded.pages.count == 3)
    }

    @Test func emptyNoteRoundTrips() throws {
        let tree = try NotePackageSerializer.fileTree(for: Note())
        let loaded = try NotePackageSerializer.note(from: tree)
        #expect(loaded.pages.isEmpty)
        // No pages/text directories for an empty note.
        #expect(tree[NotePackageSerializer.pagesDirectoryName] == nil)
        #expect(tree[NotePackageSerializer.textDirectoryName] == nil)
    }

    @Test func missingManifestThrows() {
        let tree = FileNode.directory([:])
        #expect(throws: NotePackageError.missingManifest) {
            try NotePackageSerializer.note(from: tree)
        }
    }

    @Test func nonDirectoryThrows() {
        #expect(throws: NotePackageError.notADirectory) {
            try NotePackageSerializer.note(from: .file(Data()))
        }
    }

    @Test func corruptManifestThrows() {
        let tree = FileNode.directory([
            NotePackageSerializer.manifestName: .file(Data("not json".utf8))
        ])
        do {
            _ = try NotePackageSerializer.note(from: tree)
            Issue.record("expected corruptManifest to be thrown")
        } catch NotePackageError.corruptManifest {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func newerFormatVersionIsRejected() throws {
        var manifest = Manifest()
        manifest.formatVersion = Note.currentFormatVersion + 1
        let tree = FileNode.directory([
            NotePackageSerializer.manifestName: .file(try manifest.jsonData())
        ])
        #expect(throws: NotePackageError.unsupportedFormatVersion(Note.currentFormatVersion + 1)) {
            try NotePackageSerializer.note(from: tree)
        }
    }

    @Test func missingPageFilesLoadAsEmptyLayers() throws {
        // Manifest lists a page but the drawing/text files are gone
        // (e.g. a partially synced or hand-edited package).
        let id = UUID()
        let manifest = Manifest(pages: [.init(id: id)])
        let tree = FileNode.directory([
            NotePackageSerializer.manifestName: .file(try manifest.jsonData())
        ])
        let loaded = try NotePackageSerializer.note(from: tree)
        #expect(loaded.pages.count == 1)
        #expect(loaded.pages[0].id == id)
        #expect(loaded.pages[0].isEmpty)
    }

    @Test func unknownFilesAreIgnored() throws {
        var note = makeNote()
        note = Note(pages: [note.pages[0]])
        guard case .directory(var root) = try NotePackageSerializer.fileTree(for: note) else {
            Issue.record("root is not a directory"); return
        }
        root["stray.txt"] = .file(Data("future feature".utf8))
        let loaded = try NotePackageSerializer.note(from: .directory(root))
        #expect(loaded == note)
    }
}
