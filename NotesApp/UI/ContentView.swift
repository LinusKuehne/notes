import SwiftUI
import NotesCore

/// App shell: resolves the document via `DocumentStore`, then shows the
/// notebook with the Draw/Text mode toggle (and the Mac tool strip on
/// Catalyst, since PKToolPicker doesn't exist there).
struct ContentView: View {
    @State private var store = DocumentStore()
    @State private var tools = ToolCoordinator()
    @State private var exportDocument: PDFFileDocument?
    @State private var showExporter = false
    @State private var showFolderPicker = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            switch store.phase {
            case .starting:
                ProgressView("Opening note…")
            case .downloading:
                ProgressView("Downloading from iCloud…")
            case .failed(let message):
                ContentUnavailableView(
                    "Could not open the note",
                    systemImage: "exclamationmark.icloud",
                    description: Text(message)
                )
            case .ready:
                if let document = store.document {
                    notebook(for: document)
                }
            }
        }
        .task { store.start() }
        .onChange(of: scenePhase) { _, newPhase in
            store.handleScenePhaseChange(toBackground: newPhase == .background)
        }
    }

    private func notebook(for document: NoteDocument) -> some View {
        NotebookView(document: document, tools: tools, noteGeneration: store.noteGeneration)
            .ignoresSafeArea(.container, edges: .bottom)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: $tools.mode) {
                        Label("Draw", systemImage: "pencil.tip.crop.circle")
                            .tag(ToolCoordinator.InteractionMode.draw)
                        Label("Text", systemImage: "keyboard")
                            .tag(ToolCoordinator.InteractionMode.text)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                #if targetEnvironment(macCatalyst)
                ToolbarItem(placement: .secondaryAction) {
                    MacToolStrip(tools: tools)
                }
                #endif
                ToolbarItem(placement: .topBarTrailing) {
                    storageBadge
                }
                ToolbarItem(placement: .topBarTrailing) {
                    exportMenu(for: document)
                }
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .fileExporter(
                isPresented: $showExporter,
                document: exportDocument,
                contentType: .pdf,
                defaultFilename: PDFExporter.defaultFileName(for: Date())
            ) { _ in
                exportDocument = nil
            }
            #if targetEnvironment(macCatalyst)
            .sheet(isPresented: $showFolderPicker) {
                BackupFolderPicker { url in
                    store.backups.setDriveFolder(url)
                }
            }
            #endif
    }

    private func exportMenu(for document: NoteDocument) -> some View {
        Menu {
            Section("Export") {
                Button {
                    let note = document.note
                    Task {
                        let data = await Task.detached { PDFExporter.pdfData(for: note) }.value
                        exportDocument = PDFFileDocument(data: data)
                        showExporter = true
                    }
                } label: {
                    Label("Export PDF…", systemImage: "arrow.down.document")
                }
                ShareLink(item: NotePDF(note: document.note), preview: SharePreview("Notes PDF")) {
                    Label("Share PDF", systemImage: "square.and.arrow.up")
                }
            }
            Section("Backup") {
                Button {
                    store.saveNow {
                        store.backups.backupNow(document.note, backupsDirectory: store.backupsDirectory)
                    }
                } label: {
                    Label("Back Up Now", systemImage: "clock.arrow.circlepath")
                }
                #if targetEnvironment(macCatalyst)
                Button {
                    showFolderPicker = true
                } label: {
                    if let folder = store.backups.driveFolderName {
                        Label("Mirror Folder: \(folder)…", systemImage: "folder.badge.gearshape")
                    } else {
                        Label("Choose Google Drive Folder…", systemImage: "folder.badge.plus")
                    }
                }
                #endif
                if let date = store.backups.lastBackupDate {
                    Text("Last backup \(date.formatted(date: .abbreviated, time: .shortened))")
                }
                if let error = store.backups.lastError {
                    Text(error)
                }
            }
        } label: {
            Label("Export & Backup", systemImage: "square.and.arrow.up.circle")
        }
    }

    private var storageBadge: some View {
        Image(systemName: store.storage == .iCloud ? "icloud" : "internaldrive")
            .foregroundStyle(.secondary)
            .help(store.storage == .iCloud ? "Synced via iCloud" : "Stored locally (iCloud unavailable)")
    }
}

#Preview {
    ContentView()
}
