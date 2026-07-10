import UIKit
import Observation
import NotesCore

/// One entry in the library tree: a folder or a `.note` package.
struct LibraryItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case folder
        case note
    }

    let url: URL
    let name: String
    let kind: Kind
    var children: [LibraryItem] = []

    var id: URL { url }
}

/// Owns the library: discovers the iCloud container (or the local fallback),
/// migrates a pre-iCloud local library into the cloud, scans the folder/note
/// tree, watches for remote changes, and performs file operations
/// (create/rename/move/delete/append). Opening a single note is
/// `NoteSession`'s job.
@Observable
final class LibraryStore {
    enum Phase: Equatable {
        case starting
        case ready
        case failed(String)
    }

    enum Storage: Equatable {
        case iCloud
        case localOnly
    }

    private(set) var phase: Phase = .starting
    private(set) var storage: Storage = .localOnly
    private(set) var rootURL: URL?
    private(set) var items: [LibraryItem] = []
    var lastError: String?

    let backups = BackupManager()
    /// `Documents/Backups` in the iCloud container (or local fallback).
    private(set) var backupsDirectory: URL?

    private var identityObserver: (any NSObjectProtocol)?
    private var metadataQuery: NSMetadataQuery?
    private var queryObservers: [any NSObjectProtocol] = []
    private var locateTask: Task<Void, Never>?
    private var rescanScheduled = false

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
            nonisolated(unsafe) let store = self
            MainActor.assumeIsolated { store?.restart() }
        }
        locateTask = Task { await locate() }
    }

    private func restart() {
        locateTask?.cancel()
        stopMetadataQuery()
        phase = .starting
        rootURL = nil
        items = []
        locateTask = Task { await locate() }
    }

    private func locate() async {
        let cloudDocuments = await Task.detached(priority: .userInitiated) {
            Self.ubiquityDocumentsURL()
        }.value
        guard !Task.isCancelled else { return }

        if let cloudDocuments {
            storage = .iCloud
            backupsDirectory = cloudDocuments.appendingPathComponent("Backups", isDirectory: true)
            await Task.detached(priority: .userInitiated) {
                try? FileManager.default.createDirectory(at: cloudDocuments, withIntermediateDirectories: true)
                Self.migrateLocalLibrary(to: cloudDocuments)
            }.value
            guard !Task.isCancelled else { return }
            rootURL = cloudDocuments
            startMetadataQuery()
        } else {
            storage = .localOnly
            backupsDirectory = Self.localDocumentsURL.appendingPathComponent("Backups", isDirectory: true)
            rootURL = Self.localDocumentsURL
        }

        await rescan()
        guard !Task.isCancelled else { return }
        phase = .ready
    }

    /// Moves a pre-iCloud local library (folders and `.note` packages at the
    /// local Documents root) into the cloud container. Name collisions get a
    /// unique suffix instead of merging — nothing is ever overwritten.
    private nonisolated static func migrateLocalLibrary(to cloudRoot: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: localDocumentsURL, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory, !name.hasPrefix("."),
                  !Library.reservedFolderNames.contains(name) else { continue }

            let cloudNames = Set(
                ((try? fm.contentsOfDirectory(atPath: cloudRoot.path)) ?? []).map { $0.lowercased() }
            )
            var candidate = name
            var counter = 2
            while cloudNames.contains(candidate.lowercased()) {
                if name.hasSuffix(".\(Library.noteExtension)") {
                    let base = String(name.dropLast(Library.noteExtension.count + 1))
                    candidate = "\(base) \(counter).\(Library.noteExtension)"
                } else {
                    candidate = "\(name) \(counter)"
                }
                counter += 1
            }
            do {
                try fm.setUbiquitous(
                    true,
                    itemAt: entry,
                    destinationURL: cloudRoot.appendingPathComponent(candidate, isDirectory: true)
                )
            } catch {
                NSLog("LibraryStore: migration of \(name) failed: \(error)")
            }
        }
    }

    // MARK: Scanning

    func rescanNow() async {
        await rescan()
    }

    private func rescan() async {
        guard let rootURL else { return }
        let scanned = await Task.detached(priority: .userInitiated) {
            Self.scan(directory: rootURL)
        }.value
        items = scanned
    }

    private nonisolated static func scan(directory: URL) -> [LibraryItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [LibraryItem] = []
        for url in entries {
            let name = url.lastPathComponent
            guard !Library.reservedFolderNames.contains(name) else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            if url.pathExtension == Library.noteExtension {
                result.append(LibraryItem(
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    kind: .note
                ))
            } else {
                result.append(LibraryItem(
                    url: url,
                    name: name,
                    kind: .folder,
                    children: scan(directory: url)
                ))
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .folder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// The subtree rooted at `folderURL` (nil = library root).
    func items(in folderURL: URL?) -> [LibraryItem] {
        guard let folderURL else { return items }
        func find(in items: [LibraryItem]) -> LibraryItem? {
            for item in items {
                if item.url == folderURL { return item }
                if let found = find(in: item.children) { return found }
            }
            return nil
        }
        return find(in: items)?.children ?? []
    }

    /// All folders in the library, flattened with a display path.
    func allFolders() -> [(name: String, url: URL)] {
        var result: [(String, URL)] = []
        func walk(_ items: [LibraryItem], prefix: String) {
            for item in items where item.kind == .folder {
                let name = prefix.isEmpty ? item.name : "\(prefix)/\(item.name)"
                result.append((name, item.url))
                walk(item.children, prefix: name)
            }
        }
        walk(items, prefix: "")
        return result
    }

    /// All notes in the library, flattened with a display path.
    func allNotes() -> [(name: String, url: URL)] {
        var result: [(String, URL)] = []
        func walk(_ items: [LibraryItem], prefix: String) {
            for item in items {
                let name = prefix.isEmpty ? item.name : "\(prefix)/\(item.name)"
                switch item.kind {
                case .note: result.append((name, item.url))
                case .folder: walk(item.children, prefix: name)
                }
            }
        }
        walk(items, prefix: "")
        return result
    }

    // MARK: Live updates (iCloud)

    private func startMetadataQuery() {
        stopMetadataQuery()
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(value: true)
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            queryObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: query, queue: .main
            ) { [weak self] _ in
                nonisolated(unsafe) let store = self
                MainActor.assumeIsolated { store?.scheduleRescan() }
            })
        }
        query.start()
        query.enableUpdates()
        metadataQuery = query
    }

    private func stopMetadataQuery() {
        for observer in queryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        queryObservers = []
        metadataQuery?.stop()
        metadataQuery = nil
    }

    /// Coalesces bursts of metadata updates into one rescan per second.
    private func scheduleRescan() {
        guard !rescanScheduled else { return }
        rescanScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            rescanScheduled = false
            await rescan()
        }
    }

    // MARK: Operations

    func createFolder(named title: String) async {
        guard let rootURL else { return }
        let base = Library.sanitizedFileName(fromTitle: title)
        await performOperation { [rootURL] in
            let name = Self.uniqueChildName(base: base, in: rootURL, extension: nil)
            try FileManager.default.createDirectory(
                at: rootURL.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: false
            )
        }
    }

    @discardableResult
    func createNote(named title: String, in folderURL: URL?) async -> URL? {
        guard let parent = folderURL ?? rootURL else { return nil }
        let base = Library.sanitizedFileName(fromTitle: title)
        return await performOperation { [parent] in
            let name = Self.uniqueChildName(base: base, in: parent, extension: Library.noteExtension)
            let url = parent.appendingPathComponent(name, isDirectory: true)
            try Self.writeEmptyNote(at: url)
            return url
        }
    }

    /// Creates a scratchpad capture in the Unsorted folder and returns it,
    /// ready to be opened directly.
    func createScratchpad() async -> URL? {
        guard let rootURL else { return nil }
        let unsorted = rootURL.appendingPathComponent(Library.unsortedFolderName, isDirectory: true)
        _ = await Task.detached(priority: .userInitiated) {
            try? FileManager.default.createDirectory(at: unsorted, withIntermediateDirectories: true)
        }.value
        return await createNote(named: Library.scratchpadName(for: Date()), in: unsorted)
    }

    func rename(_ item: LibraryItem, to title: String) async {
        let base = Library.sanitizedFileName(fromTitle: title)
        guard base != item.name else { return }
        let parent = item.url.deletingLastPathComponent()
        let ext = item.kind == .note ? Library.noteExtension : nil
        await performOperation { [url = item.url] in
            let name = Self.uniqueChildName(base: base, in: parent, extension: ext)
            try Self.coordinatedMove(from: url, to: parent.appendingPathComponent(name, isDirectory: true))
        }
    }

    func move(_ item: LibraryItem, into folderURL: URL?) async {
        guard let destination = folderURL ?? rootURL,
              destination.standardizedFileURL.path != item.url.deletingLastPathComponent().standardizedFileURL.path
        else { return }
        // Refuse moving a folder into itself or a descendant (path-boundary
        // aware: "Uni" must not match "Uni 2").
        if item.kind == .folder,
           (destination.standardizedFileURL.path + "/").hasPrefix(item.url.standardizedFileURL.path + "/") {
            lastError = "Cannot move a folder into itself."
            return
        }
        let ext = item.kind == .note ? Library.noteExtension : nil
        await performOperation { [item] in
            let name = Self.uniqueChildName(base: item.name, in: destination, extension: ext)
            try Self.coordinatedMove(from: item.url, to: destination.appendingPathComponent(name, isDirectory: true))
        }
    }

    func delete(_ item: LibraryItem) async {
        await performOperation { [url = item.url] in
            var coordinatorError: NSError?
            var operationError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: url, options: .forDeleting, error: &coordinatorError
            ) { coordinatedURL in
                do {
                    try FileManager.default.removeItem(at: coordinatedURL)
                } catch {
                    operationError = error
                }
            }
            if let coordinatorError { throw coordinatorError }
            if let operationError { throw operationError }
        }
    }

    /// Appends the content pages of the note at `sourceURL` to the note at
    /// `targetURL`, then deletes the source ("connect a scratchpad capture
    /// to a note"). Only offered from the library screen, where no note
    /// session is open.
    func appendNote(at sourceURL: URL, to targetURL: URL) async {
        await performOperation {
            try Self.appendNoteFiles(source: sourceURL, target: targetURL)
        }
    }

    /// Runs `work` off the main actor, reports errors, and rescans.
    @discardableResult
    private func performOperation<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> T? {
        lastError = nil
        let result: Result<T, Error> = await Task.detached(priority: .userInitiated) {
            do {
                return .success(try work())
            } catch {
                return .failure(error)
            }
        }.value
        var value: T?
        switch result {
        case .success(let succeeded):
            value = succeeded
        case .failure(let error):
            lastError = error.localizedDescription
            NSLog("LibraryStore: operation failed: \(error)")
        }
        await rescan()
        return value
    }

    // MARK: File-level helpers (nonisolated: run in detached tasks)

    private nonisolated static func uniqueChildName(base: String, in directory: URL, extension ext: String?) -> String {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let existingBases = Set(entries.map { name -> String in
            if let ext, name.lowercased().hasSuffix(".\(ext)") {
                return String(name.dropLast(ext.count + 1))
            }
            return name
        })
        let unique = Library.uniqueName(base: base, existing: existingBases)
        return ext.map { "\(unique).\($0)" } ?? unique
    }

    private nonisolated static func writeEmptyNote(at url: URL) throws {
        let tree = try NotePackageSerializer.fileTree(for: Note())
        let wrapper = FileWrapperAdapter.apply(tree, reusing: nil)
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinatorError
        ) { coordinatedURL in
            do {
                try wrapper.write(to: coordinatedURL, options: .atomic, originalContentsURL: nil)
            } catch {
                writeError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    private nonisolated static func coordinatedMove(from source: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinatorError
        ) { coordinatedSource, coordinatedDestination in
            do {
                try FileManager.default.moveItem(at: coordinatedSource, to: coordinatedDestination)
                coordinator.item(at: coordinatedSource, willMoveTo: coordinatedDestination)
            } catch {
                moveError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let moveError { throw moveError }
    }

    nonisolated static func loadNote(at url: URL) throws -> Note {
        let wrapper = try FileWrapper(url: url, options: .immediate)
        return try NotePackageSerializer.note(from: FileWrapperAdapter.fileNode(from: wrapper))
    }

    private nonisolated static func appendNoteFiles(source: URL, target: URL) throws {
        var coordinatorError: NSError?
        var operationError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            readingItemAt: source, options: [],
            writingItemAt: target, options: .forMerging,
            error: &coordinatorError
        ) { coordinatedSource, coordinatedTarget in
            do {
                let sourceNote = try loadNote(at: coordinatedSource)
                var targetNote = try loadNote(at: coordinatedTarget)
                targetNote.appendPages(of: sourceNote)
                let tree = try NotePackageSerializer.fileTree(for: targetNote)
                let existing = try? FileWrapper(url: coordinatedTarget, options: .immediate)
                let wrapper = FileWrapperAdapter.apply(tree, reusing: existing)
                try wrapper.write(to: coordinatedTarget, options: .atomic, originalContentsURL: coordinatedTarget)
            } catch {
                operationError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let operationError { throw operationError }

        // Source is deleted only after the target was written successfully.
        var deleteCoordinatorError: NSError?
        coordinator.coordinate(
            writingItemAt: source, options: .forDeleting, error: &deleteCoordinatorError
        ) { coordinatedURL in
            try? FileManager.default.removeItem(at: coordinatedURL)
        }
    }
}
