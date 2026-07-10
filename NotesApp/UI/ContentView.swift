import SwiftUI
import NotesCore

/// App shell: resolves the document via `DocumentStore`, then shows the
/// notebook with the Draw/Text mode toggle (and the Mac tool strip on
/// Catalyst, since PKToolPicker doesn't exist there).
struct ContentView: View {
    @State private var store = DocumentStore()
    @State private var tools = ToolCoordinator()
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
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
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
