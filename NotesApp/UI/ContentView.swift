import SwiftUI
import NotesCore

/// Placeholder shell — replaced by the real notebook UI as the document,
/// notebook, and export layers land.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "pencil.and.outline")
                .font(.system(size: 48))
            Text("Notes")
                .font(.largeTitle.bold())
            Text("A4 \(Int(A4.width.rounded())) × \(Int(A4.height.rounded())) pt")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
