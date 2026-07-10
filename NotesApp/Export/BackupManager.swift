import UIKit
import SwiftUI
import UniformTypeIdentifiers
import Observation
import NotesCore

/// Rotating PDF backups.
///
/// Every platform writes `Notes <timestamp>.pdf` into the iCloud container's
/// `Documents/Backups/` folder (visible in Files/Finder), keeping the last
/// `keepCount`. On Mac Catalyst the newest backups are additionally mirrored
/// into a user-picked folder — pointing that at the Google Drive folder in
/// `~/Library/CloudStorage/` gets them uploaded by Google's own file
/// provider, no Drive API needed. (This is Mac-only by necessity: iPadOS
/// grays out third-party file-provider folders in the folder picker.)
@Observable
final class BackupManager {
    nonisolated static let keepCount = 10
    /// Minimum time between automatic backups (manual ones are unthrottled).
    nonisolated static let minimumInterval: TimeInterval = 5 * 60

    private(set) var lastBackupDate: Date?
    private(set) var lastError: String?
    private(set) var isBackingUp = false

    /// Content timestamp covered by the last backup — skips no-op backups.
    private var lastBackedUpContentDate: Date?

    private nonisolated static let lastBackupDateKey = "backup.lastDate"
    private nonisolated static let driveBookmarkKey = "backup.driveFolderBookmark"

    init() {
        lastBackupDate = UserDefaults.standard.object(forKey: Self.lastBackupDateKey) as? Date
    }

    // MARK: Triggers

    /// Called after every successful document save; throttled.
    func noteSaved(_ note: Note, backupsDirectory: URL?) {
        guard let backupsDirectory else { return }
        let contentDate = note.lastModified
        if let lastBackedUpContentDate, let contentDate, contentDate <= lastBackedUpContentDate {
            return
        }
        if let lastBackupDate, Date().timeIntervalSince(lastBackupDate) < Self.minimumInterval {
            return
        }
        performBackup(note, backupsDirectory: backupsDirectory)
    }

    func backupNow(_ note: Note, backupsDirectory: URL?) {
        guard let backupsDirectory else {
            lastError = "No backup folder is available yet."
            return
        }
        performBackup(note, backupsDirectory: backupsDirectory)
    }

    private func performBackup(_ note: Note, backupsDirectory: URL) {
        guard !isBackingUp else { return }
        isBackingUp = true
        lastError = nil
        let mirrorFolder = Self.resolveDriveFolder()

        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<Void, Error> in
                do {
                    try Self.writeBackup(of: note, into: backupsDirectory)
                    if let mirrorFolder {
                        try Self.mirror(into: mirrorFolder, note: note)
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            isBackingUp = false
            switch result {
            case .success:
                lastBackupDate = Date()
                lastBackedUpContentDate = note.lastModified
                UserDefaults.standard.set(lastBackupDate, forKey: Self.lastBackupDateKey)
            case .failure(let error):
                lastError = error.localizedDescription
                NSLog("BackupManager: backup failed: \(error)")
            }
        }
    }

    // MARK: Writing

    private nonisolated static func writeBackup(of note: Note, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(PDFExporter.defaultFileName(for: Date()))
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinatorError
        ) { coordinatedURL in
            do {
                try PDFExporter.writePDF(for: note, to: coordinatedURL)
            } catch {
                writeError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
        try rotate(in: directory)
    }

    /// Deletes the oldest backups beyond `keepCount`. The timestamped names
    /// sort chronologically, so name order is age order.
    private nonisolated static func rotate(in directory: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("Notes ") && $0.hasSuffix(".pdf") }
            .sorted(by: >)
        for name in names.dropFirst(keepCount) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: Google Drive mirror (Mac Catalyst only)

    var hasDriveFolder: Bool {
        UserDefaults.standard.data(forKey: Self.driveBookmarkKey) != nil
    }

    var driveFolderName: String? {
        Self.resolveDriveFolder()?.lastPathComponent
    }

    func setDriveFolder(_ url: URL) {
        #if targetEnvironment(macCatalyst)
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.driveBookmarkKey)
            lastError = nil
        } catch {
            lastError = "Could not save access to \(url.lastPathComponent): \(error.localizedDescription)"
        }
        #endif
    }

    func clearDriveFolder() {
        UserDefaults.standard.removeObject(forKey: Self.driveBookmarkKey)
    }

    private nonisolated static func resolveDriveFolder() -> URL? {
        #if targetEnvironment(macCatalyst)
        guard let bookmark = UserDefaults.standard.data(forKey: driveBookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale, let refreshed = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            UserDefaults.standard.set(refreshed, forKey: driveBookmarkKey)
        }
        return url
        #else
        return nil
        #endif
    }

    private nonisolated static func mirror(into folder: URL, note: Note) throws {
        guard folder.startAccessingSecurityScopedResource() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { folder.stopAccessingSecurityScopedResource() }

        let url = folder.appendingPathComponent(PDFExporter.defaultFileName(for: Date()))
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinatorError
        ) { coordinatedURL in
            do {
                try PDFExporter.writePDF(for: note, to: coordinatedURL)
            } catch {
                writeError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
        try rotate(in: folder)
    }
}

#if targetEnvironment(macCatalyst)
/// Folder picker for the Google Drive mirror target (NSOpenPanel under
/// Catalyst).
struct BackupFolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPick(url)
            }
        }
    }
}
#endif
