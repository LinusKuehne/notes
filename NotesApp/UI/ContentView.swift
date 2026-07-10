import SwiftUI
import NotesCore

/// Navigation targets inside the library.
enum LibraryRoute: Hashable {
    case folder(URL)
    case note(URL)
}

/// App root: resolves the library (iCloud container or local fallback) and
/// hosts the navigation stack — library browser → folders → notebook.
struct ContentView: View {
    @State private var library = LibraryStore()
    @State private var path = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch library.phase {
                case .starting:
                    ProgressView("Loading library…")
                case .failed(let message):
                    ContentUnavailableView(
                        "Could not open the library",
                        systemImage: "exclamationmark.icloud",
                        description: Text(message)
                    )
                case .ready:
                    LibraryView(library: library, folderURL: nil, path: $path)
                }
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .folder(let url):
                    LibraryView(library: library, folderURL: url, path: $path)
                case .note(let url):
                    NotebookScreen(library: library, noteURL: url)
                }
            }
        }
        .task { library.start() }
        .onChange(of: library.phase) { _, newPhase in
            // Library re-resolved (iCloud sign-in/out): URLs changed, pop
            // everything.
            if newPhase != .ready {
                path = NavigationPath()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await library.rescanNow() }
            }
        }
    }
}

#Preview {
    ContentView()
}
