import UIKit
import Observation
import NotesCore

/// Owns the app's single document: finds it (iCloud container or local
/// fallback), downloads it when it only exists in the cloud, migrates a
/// local copy into iCloud, opens it, watches for conflicts, and drives
/// save/close on scene lifecycle events.
@Observable
final class DocumentStore {
    enum Phase: Equatable {
        case starting
        case downloading
        case ready
        case failed(String)
    }

    enum Storage: Equatable {
        case iCloud
        case localOnly
    }

    private(set) var phase: Phase = .starting
    private(set) var storage: Storage = .localOnly
    private(set) var document: NoteDocument?
    /// Bumped whenever the note was replaced wholesale (open, conflict
    /// merge) so views can rebuild.
    private(set) var noteGeneration = 0

    let backups = BackupManager()
    /// `Documents/Backups` in the iCloud container (or local fallback).
    private(set) var backupsDirectory: URL?

    private var stateObserver: (any NSObjectProtocol)?
    private var identityObserver: (any NSObjectProtocol)?

    private nonisolated static let containerIdentifier = "iCloud.com.linuskuehne.notes"

    // MARK: Locations

    private nonisolated static func ubiquityDocumentsURL() -> URL? {
        // First access can block for seconds — only call off the main thread.
        FileManager.default
            .url(forUbiquityContainerIdentifier: containerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    private nonisolated static var localDocumentsURL: URL {
        URL.documentsDirectory
    }

    // MARK: Lifecycle

    func start() {
        phase = .starting
        identityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        }
        Task { await locateAndOpen() }
    }

    private func restart() {
        let document = document
        self.document = nil
        phase = .starting
        document?.close { _ in
            Task { @MainActor in await self.locateAndOpen() }
        }
    }

    private func locateAndOpen() async {
        // 1. Resolve the container off the main thread.
        let cloudDocuments = await Task.detached(priority: .userInitiated) {
            Self.ubiquityDocumentsURL()
        }.value

        let localURL = Self.localDocumentsURL.appendingPathComponent(NoteDocument.fileName, isDirectory: true)

        guard let cloudDocuments else {
            storage = .localOnly
            backupsDirectory = Self.localDocumentsURL.appendingPathComponent("Backups", isDirectory: true)
            await openOrCreate(at: localURL, mergingLocalCopy: nil)
            return
        }
        storage = .iCloud
        backupsDirectory = cloudDocuments.appendingPathComponent("Backups", isDirectory: true)
        let cloudURL = cloudDocuments.appendingPathComponent(NoteDocument.fileName, isDirectory: true)
        let localExists = FileManager.default.fileExists(atPath: localURL.path)

        // 2. Does the note exist in iCloud (possibly not downloaded yet)?
        let existsInCloud = await UbiquitousItemFinder.itemExists(named: NoteDocument.fileName)

        if existsInCloud {
            phase = .downloading
            await Task.detached(priority: .userInitiated) {
                try? FileManager.default.createDirectory(at: cloudDocuments, withIntermediateDirectories: true)
                try? FileManager.default.startDownloadingUbiquitousItem(at: cloudURL)
                await UbiquitousItemFinder.waitUntilDownloaded(at: cloudURL, timeout: 60)
            }.value
            await openOrCreate(at: cloudURL, mergingLocalCopy: localExists ? localURL : nil)
        } else if localExists {
            // 3. Move the local note into iCloud (off-main, document closed).
            let moved = await Task.detached(priority: .userInitiated) {
                do {
                    try FileManager.default.createDirectory(at: cloudDocuments, withIntermediateDirectories: true)
                    try FileManager.default.setUbiquitous(true, itemAt: localURL, destinationURL: cloudURL)
                    return true
                } catch {
                    NSLog("DocumentStore: local→iCloud migration failed: \(error)")
                    return false
                }
            }.value
            if moved {
                await openOrCreate(at: cloudURL, mergingLocalCopy: nil)
            } else {
                storage = .localOnly
                await openOrCreate(at: localURL, mergingLocalCopy: nil)
            }
        } else {
            _ = await Task.detached(priority: .userInitiated) {
                try? FileManager.default.createDirectory(at: cloudDocuments, withIntermediateDirectories: true)
            }.value
            await openOrCreate(at: cloudURL, mergingLocalCopy: nil)
        }
    }

    private func openOrCreate(at url: URL, mergingLocalCopy localURL: URL?) async {
        let document = NoteDocument(fileURL: url)
        document.onNoteReplaced = { [weak self] _ in
            self?.noteGeneration += 1
        }

        let exists = FileManager.default.fileExists(atPath: url.path)
        let opened: Bool = await withCheckedContinuation { continuation in
            if exists {
                document.open { continuation.resume(returning: $0) }
            } else {
                document.save(to: url, for: .forCreating) { continuation.resume(returning: $0) }
            }
        }

        guard opened else {
            phase = .failed("Could not \(exists ? "open" : "create") the note at \(url.lastPathComponent).")
            return
        }

        // A local copy from before iCloud was enabled: merge it in, delete it.
        if let localURL {
            do {
                let localNote = try Self.loadNote(at: localURL)
                document.replaceNote(NoteMerger.merge(document.note, localNote))
                Task.detached {
                    let coordinator = NSFileCoordinator(filePresenter: nil)
                    coordinator.coordinate(writingItemAt: localURL, options: .forDeleting, error: nil) {
                        try? FileManager.default.removeItem(at: $0)
                    }
                }
            } catch {
                NSLog("DocumentStore: could not merge pre-iCloud local copy: \(error)")
            }
        }

        self.document = document
        observeState(of: document)
        phase = .ready
        noteGeneration += 1
    }

    private nonisolated static func loadNote(at url: URL) throws -> Note {
        let wrapper = try FileWrapper(url: url, options: .immediate)
        return try NotePackageSerializer.note(from: FileWrapperAdapter.fileNode(from: wrapper))
    }

    // MARK: Document state / conflicts

    private func observeState(of document: NoteDocument) {
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
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
                    self.backups.noteSaved(document.note, backupsDirectory: self.backupsDirectory)
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

/// One-shot `NSMetadataQuery` helpers for the ubiquitous Documents scope.
enum UbiquitousItemFinder {
    /// Whether an item with `name` exists in the app's iCloud Documents
    /// scope (downloaded or not). Times out conservatively: on timeout we
    /// report "does not exist", which at worst creates a fresh note that a
    /// later conflict merge reconciles.
    static func itemExists(named name: String, timeout: TimeInterval = 10) async -> Bool {
        await withCheckedContinuation { continuation in
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, name)

            var observer: (any NSObjectProtocol)?
            var timeoutTask: Task<Void, Never>?
            let finish: (Bool) -> Void = { result in
                if let observer { NotificationCenter.default.removeObserver(observer) }
                timeoutTask?.cancel()
                query.stop()
                continuation.resume(returning: result)
            }
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
            ) { _ in
                finish(query.resultCount > 0)
            }
            timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                finish(false)
            }
            query.start()
        }
    }

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
