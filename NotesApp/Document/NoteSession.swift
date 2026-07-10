import UIKit
import Observation
import NotesCore

/// An open note: downloads it if it only exists in the cloud, opens the
/// `NoteDocument`, watches for iCloud conflicts, and drives save/close on
/// scene lifecycle events. Created when the user navigates into a note,
/// closed when they leave.
@Observable
final class NoteSession {
    enum Phase: Equatable {
        case starting
        case downloading
        case ready
        case failed(String)
    }

    let noteURL: URL
    /// The note's title is its file name.
    let title: String

    private(set) var phase: Phase = .starting
    private(set) var document: NoteDocument?
    /// Bumped whenever the note was replaced wholesale (open, conflict
    /// merge) so views can rebuild.
    private(set) var noteGeneration = 0

    private let backups: BackupManager
    private let backupsDirectory: URL?
    private var stateObserver: (any NSObjectProtocol)?
    private var isClosed = false

    init(noteURL: URL, backups: BackupManager, backupsDirectory: URL?) {
        self.noteURL = noteURL
        self.title = noteURL.deletingPathExtension().lastPathComponent
        self.backups = backups
        self.backupsDirectory = backupsDirectory
    }

    // MARK: Open / close

    func open() async {
        // Materialize a cloud-only note before opening (UIDocument would
        // also download, but this way we can show progress).
        if FileManager.default.isUbiquitousItem(at: noteURL) {
            phase = .downloading
            await Task.detached(priority: .userInitiated) { [noteURL] in
                try? FileManager.default.startDownloadingUbiquitousItem(at: noteURL)
                await UbiquitousItemFinder.waitUntilDownloaded(at: noteURL, timeout: 60)
            }.value
        }
        guard !isClosed else { return }

        let document = NoteDocument(fileURL: noteURL)
        document.onNoteReplaced = { [weak self] _ in
            self?.noteGeneration += 1
        }

        let exists = FileManager.default.fileExists(atPath: noteURL.path)
        let opened: Bool = await withCheckedContinuation { continuation in
            if exists {
                document.open { continuation.resume(returning: $0) }
            } else {
                // The library normally creates the package first; this is a
                // recovery path (e.g. the note vanished remotely).
                document.save(to: noteURL, for: .forCreating) { continuation.resume(returning: $0) }
            }
        }
        if isClosed {
            if opened { document.close(completionHandler: nil) }
            return
        }
        guard opened else {
            phase = .failed("Could not \(exists ? "open" : "create") “\(title)”.")
            return
        }

        self.document = document
        observeState(of: document)
        // A conflict may already exist at open time (both devices synced
        // while the app was closed) — no further state change will fire.
        if document.documentState.contains(.inConflict) {
            ConflictResolver.resolveConflicts(for: document)
        }
        phase = .ready
        noteGeneration += 1
    }

    /// Saves and closes; the session cannot be reused afterwards.
    func closeAndSave() {
        isClosed = true
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
            self.stateObserver = nil
        }
        guard let document else { return }
        self.document = nil
        let backups = backups
        let backupsDirectory = backupsDirectory
        let title = title
        document.close { success in
            nonisolated(unsafe) let document = document
            MainActor.assumeIsolated {
                // UIDocument.close autosaves; trigger the backup pipeline.
                if success {
                    backups.noteSaved(document.note, title: title, backupsDirectory: backupsDirectory)
                }
            }
        }
    }

    // MARK: Conflicts

    private func observeState(of document: NoteDocument) {
        stateObserver = NotificationCenter.default.addObserver(
            forName: UIDocument.stateChangedNotification, object: document, queue: .main
        ) { [weak document] _ in
            // Safe: queue .main pins this block to the main thread, so the
            // reference never actually crosses isolation.
            nonisolated(unsafe) let document = document
            MainActor.assumeIsolated {
                guard let document else { return }
                if document.documentState.contains(.inConflict) {
                    ConflictResolver.resolveConflicts(for: document)
                }
            }
        }
    }

    // MARK: Saving

    /// Saves if there are unsaved changes (used on scene background / exit).
    /// The completion is a `@MainActor` closure — that makes it Sendable, so
    /// it can travel through UIDocument's completion handler.
    func saveNow(completion: (@MainActor () -> Void)? = nil) {
        guard let document, document.hasUnsavedChanges else {
            completion?()
            return
        }
        document.save(to: document.fileURL, for: .forOverwriting) { [weak self] success in
            // UIDocument calls the completion on the queue that initiated the
            // save — the main queue here.
            MainActor.assumeIsolated {
                if success, let self, let document = self.document {
                    self.backups.noteSaved(
                        document.note,
                        title: self.title,
                        backupsDirectory: self.backupsDirectory
                    )
                }
                completion?()
            }
        }
    }

    func handleScenePhaseChange(toBackground: Bool) {
        guard toBackground else { return }
        // Finish the write even if the app is suspended right after.
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "SaveNote")
        saveNow {
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }
}

/// Ubiquitous-item helpers.
enum UbiquitousItemFinder {
    /// Polls until the ubiquitous item at `url` is fully downloaded (or the
    /// timeout elapses — `UIDocument.open` will then finish the download).
    static func waitUntilDownloaded(at url: URL, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
               values.ubiquitousItemDownloadingStatus == .current {
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }
}
