import SwiftUI
import NotesCore

/// SwiftUI bridge for the UIKit notebook. `noteGeneration` bumps whenever
/// the model was replaced wholesale (open, iCloud conflict merge) and forces
/// a rebuild of the page stack.
struct NotebookView: UIViewControllerRepresentable {
    let document: NoteDocument
    let tools: ToolCoordinator
    let noteGeneration: Int

    func makeUIViewController(context: Context) -> NotebookViewController {
        context.coordinator.lastGeneration = noteGeneration
        return NotebookViewController(document: document, tools: tools)
    }

    func updateUIViewController(_ controller: NotebookViewController, context: Context) {
        if context.coordinator.lastGeneration != noteGeneration {
            context.coordinator.lastGeneration = noteGeneration
            controller.reloadFromDocument()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastGeneration = -1
    }
}
