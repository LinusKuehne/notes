import SwiftUI
import NotesCore

/// The notebook for a single note: opens a `NoteSession` on appear, closes
/// (and saves) it on leave. Hosts the Draw/Text mode toggle, the Mac tool
/// strip, and the export/backup menu.
struct NotebookScreen: View {
    let library: LibraryStore
    let noteURL: URL

    @State private var session: NoteSession?
    @State private var tools = ToolCoordinator()
    @State private var exportDocument: PDFFileDocument?
    @State private var showExporter = false
    @State private var showFolderPicker = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch session?.phase {
            case nil, .starting:
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
                if let session, let document = session.document {
                    notebook(for: document, session: session)
                }
            }
        }
        .navigationTitle(session?.title ?? noteURL.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard session == nil else { return }
            let newSession = NoteSession(
                noteURL: noteURL,
                backups: library.backups,
                backupsDirectory: library.backupsDirectory
            )
            session = newSession
            await newSession.open()
        }
        .onDisappear {
            session?.closeAndSave()
        }
        .onChange(of: scenePhase) { _, newPhase in
            session?.handleScenePhaseChange(toBackground: newPhase == .background)
        }
    }

    private func notebook(for document: NoteDocument, session: NoteSession) -> some View {
        NotebookView(document: document, tools: tools, noteGeneration: session.noteGeneration)
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
                    exportMenu(for: document, session: session)
                }
            }
            .fileExporter(
                isPresented: $showExporter,
                document: exportDocument,
                contentType: .pdf,
                defaultFilename: PDFExporter.fileName(title: session.title, date: Date())
            ) { _ in
                exportDocument = nil
            }
            #if targetEnvironment(macCatalyst)
            .sheet(isPresented: $showFolderPicker) {
                BackupFolderPicker { url in
                    library.backups.setDriveFolder(url)
                }
            }
            #endif
    }

    private func exportMenu(for document: NoteDocument, session: NoteSession) -> some View {
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
                ShareLink(
                    item: NotePDF(note: document.note, title: session.title),
                    preview: SharePreview("\(session.title) PDF")
                ) {
                    Label("Share PDF", systemImage: "square.and.arrow.up")
                }
            }
            Section("Backup") {
                Button {
                    session.saveNow {
                        library.backups.backupNow(
                            document.note,
                            title: session.title,
                            backupsDirectory: library.backupsDirectory
                        )
                    }
                } label: {
                    Label("Back Up Now", systemImage: "clock.arrow.circlepath")
                }
                #if targetEnvironment(macCatalyst)
                Button {
                    showFolderPicker = true
                } label: {
                    if let folder = library.backups.driveFolderName {
                        Label("Mirror Folder: \(folder)…", systemImage: "folder.badge.gearshape")
                    } else {
                        Label("Choose Google Drive Folder…", systemImage: "folder.badge.plus")
                    }
                }
                #endif
                if let date = library.backups.lastBackupDate {
                    Text("Last backup \(date.formatted(date: .abbreviated, time: .shortened))")
                }
                if let error = library.backups.lastError {
                    Text(error)
                }
            }
        } label: {
            Label("Export & Backup", systemImage: "square.and.arrow.up.circle")
        }
    }
}
