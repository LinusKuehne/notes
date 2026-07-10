import UIKit
import NotesCore

/// The single note, stored as a `.note` document package and managed by
/// `UIDocument` (coordinated I/O, autosave, iCloud conflict surface).
///
/// The in-memory model is `NotesCore.Note`; serialization goes through
/// `NotePackageSerializer` (layout) and `FileWrapperAdapter` (incremental
/// `FileWrapper` reuse so unchanged pages are not rewritten/re-uploaded).
final class NoteDocument: UIDocument {
    static let typeIdentifier = "com.linuskuehne.notes.note"

    private(set) var note = Note()

    /// The file wrapper tree from the last load/save, kept alive between
    /// saves so unchanged page files keep their identity (incremental
    /// writes + incremental iCloud uploads).
    private var rootWrapper: FileWrapper?

    /// Called whenever the model is replaced from disk (open, revert,
    /// conflict merge) — the UI re-renders from scratch on this.
    var onNoteReplaced: ((Note) -> Void)?

    // MARK: Editing

    /// Applies a model change from the UI and schedules an autosave.
    func updateNote(_ newNote: Note) {
        guard newNote != note else { return }
        note = newNote
        updateChangeCount(.done)
    }

    /// Replaces the model programmatically (conflict merge) and re-renders.
    func replaceNote(_ newNote: Note) {
        guard newNote != note else { return }
        note = newNote
        updateChangeCount(.done)
        onNoteReplaced?(note)
    }

    // MARK: UIDocument overrides

    override func contents(forType typeName: String) throws -> Any {
        let tree = try NotePackageSerializer.fileTree(for: note)
        let wrapper = FileWrapperAdapter.apply(tree, reusing: rootWrapper)
        rootWrapper = wrapper
        return wrapper
    }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let wrapper = contents as? FileWrapper else {
            throw CocoaError(.fileReadCorruptFile)
        }
        rootWrapper = wrapper
        note = try NotePackageSerializer.note(from: FileWrapperAdapter.fileNode(from: wrapper))
        onNoteReplaced?(note)
    }

    override var savingFileType: String? {
        Self.typeIdentifier
    }

    // Keep autosave failures observable during development.
    override func handleError(_ error: Error, userInteractionPermitted: Bool) {
        NSLog("NoteDocument error (interaction permitted: \(userInteractionPermitted)): \(error)")
        super.handleError(error, userInteractionPermitted: userInteractionPermitted)
    }
}
