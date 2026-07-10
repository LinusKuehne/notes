import UIKit
import NotesCore

/// Automatic iCloud conflict resolution: when the document enters
/// `.inConflict`, every conflicting version is loaded, merged into the
/// current note per page / per layer (last writer wins via `NoteMerger`),
/// and the conflict versions are marked resolved and pruned.
enum ConflictResolver {
    /// Resolves outstanding conflicts for `document`. Returns `true` when a
    /// merge was applied.
    @discardableResult
    static func resolveConflicts(for document: NoteDocument) -> Bool {
        let url = document.fileURL
        guard let conflictVersions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !conflictVersions.isEmpty else {
            return false
        }

        var merged = document.note
        for version in conflictVersions {
            do {
                let versionNote = try loadNote(at: version.url)
                merged = NoteMerger.merge(merged, versionNote)
            } catch {
                // An unreadable version must not block resolution — the
                // current version wins for that copy.
                NSLog("ConflictResolver: skipping unreadable version \(version.url): \(error)")
            }
        }

        document.replaceNote(merged)

        // Persist the merge FIRST — only then mark the versions resolved and
        // prune them. Marking before the merged content is on disk would let
        // a crash/kill permanently delete the other device's data. On save
        // failure the versions stay unresolved, so resolution retries on the
        // next document state change.
        document.save(to: url, for: .forOverwriting) { success in
            nonisolated(unsafe) let versions = conflictVersions
            MainActor.assumeIsolated {
                guard success else {
                    NSLog("ConflictResolver: merge save failed; leaving versions unresolved")
                    return
                }
                for version in versions {
                    version.isResolved = true
                }
                let coordinator = NSFileCoordinator(filePresenter: nil)
                coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: nil) { coordinatedURL in
                    do {
                        try NSFileVersion.removeOtherVersionsOfItem(at: coordinatedURL)
                    } catch {
                        NSLog("ConflictResolver: failed to prune versions: \(error)")
                    }
                }
            }
        }
        return true
    }

    private static func loadNote(at url: URL) throws -> Note {
        var readError: NSError?
        var result: Result<Note, Error> = .failure(CocoaError(.fileReadUnknown))
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &readError) { coordinatedURL in
            do {
                let wrapper = try FileWrapper(url: coordinatedURL, options: .immediate)
                let note = try NotePackageSerializer.note(from: FileWrapperAdapter.fileNode(from: wrapper))
                result = .success(note)
            } catch {
                result = .failure(error)
            }
        }
        if let readError { throw readError }
        return try result.get()
    }
}
