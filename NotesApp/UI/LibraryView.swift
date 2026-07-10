import SwiftUI
import NotesCore

/// One level of the library: the notes and folders inside `folderURL`
/// (nil = root). Folders push another `LibraryView`; notes push the
/// notebook.
struct LibraryView: View {
    let library: LibraryStore
    let folderURL: URL?
    @Binding var path: NavigationPath

    @State private var newNotePrompt = false
    @State private var newFolderPrompt = false
    @State private var newItemName = ""
    @State private var renameTarget: LibraryItem?
    @State private var renameText = ""
    @State private var deleteTarget: LibraryItem?

    private var items: [LibraryItem] {
        library.items(in: folderURL)
    }

    private var isRoot: Bool { folderURL == nil }

    var body: some View {
        List {
            ForEach(items) { item in
                row(for: item)
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    isRoot ? "No notes yet" : "Empty folder",
                    systemImage: "square.and.pencil",
                    description: Text(isRoot
                        ? "Create a note with the + button, or capture an idea with the scratchpad."
                        : "Notes you create or move here will appear.")
                )
            }
        }
        .navigationTitle(folderURL?.lastPathComponent ?? "Notes")
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Quick capture: one tap, straight onto a fresh page.
                Button {
                    Task {
                        if let url = await library.createScratchpad() {
                            path.append(LibraryRoute.note(url))
                        }
                    }
                } label: {
                    Label("Scratchpad", systemImage: "bolt.circle")
                }
                .help("Quick note — lands in \(Library.unsortedFolderName)")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        newItemName = ""
                        newNotePrompt = true
                    } label: {
                        Label("New Note…", systemImage: "square.and.pencil")
                    }
                    if isRoot {
                        Button {
                            newItemName = ""
                            newFolderPrompt = true
                        } label: {
                            Label("New Folder…", systemImage: "folder.badge.plus")
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            if isRoot {
                ToolbarItem(placement: .topBarLeading) {
                    storageBadge
                }
            }
        }
        .alert("New Note", isPresented: $newNotePrompt) {
            TextField("Title", text: $newItemName)
            Button("Create") {
                let title = newItemName
                Task {
                    if let url = await library.createNote(named: title, in: folderURL) {
                        path.append(LibraryRoute.note(url))
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Folder", isPresented: $newFolderPrompt) {
            TextField("Name", text: $newItemName)
            Button("Create") {
                let title = newItemName
                Task { await library.createFolder(named: title) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Rename",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget {
                    let title = renameText
                    Task { await library.rename(target, to: title) }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "Delete “\(deleteTarget?.name ?? "")”?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    Task { await library.delete(target) }
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget?.kind == .folder
                ? "The folder and all notes inside it will be deleted."
                : "This note will be deleted.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { library.lastError != nil },
                set: { if !$0 { library.lastError = nil } }
            )
        ) {
            Button("OK") { library.lastError = nil }
        } message: {
            Text(library.lastError ?? "")
        }
        .refreshable {
            await library.rescanNow()
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(for item: LibraryItem) -> some View {
        NavigationLink(value: item.kind == .folder ? LibraryRoute.folder(item.url) : LibraryRoute.note(item.url)) {
            HStack {
                Label {
                    Text(item.name)
                } icon: {
                    Image(systemName: item.kind == .folder ? "folder" : "doc.text.image")
                        .foregroundStyle(item.kind == .folder ? Color.accentColor : .secondary)
                }
                if item.kind == .folder, !item.children.isEmpty {
                    Spacer()
                    Text("\(item.children.count)")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                }
            }
        }
        .contextMenu {
            Button {
                renameText = item.name
                renameTarget = item
            } label: {
                Label("Rename…", systemImage: "pencil")
            }

            moveMenu(for: item)

            if item.kind == .note {
                appendMenu(for: item)
            }

            Divider()

            Button(role: .destructive) {
                deleteTarget = item
            } label: {
                Label("Delete…", systemImage: "trash")
            }
        }
    }

    /// "Move to …" — the root plus every folder (except the item itself and,
    /// for folders, their own subtree).
    @ViewBuilder
    private func moveMenu(for item: LibraryItem) -> some View {
        let currentParent = item.url.deletingLastPathComponent().standardizedFileURL.path
        Menu {
            if library.rootURL?.standardizedFileURL.path != currentParent {
                Button("Notes (top level)") {
                    Task { await library.move(item, into: nil) }
                }
            }
            ForEach(library.allFolders(), id: \.url) { folder in
                let folderPath = folder.url.standardizedFileURL.path
                if folderPath != item.url.standardizedFileURL.path,
                   folderPath != currentParent,
                   !(item.kind == .folder
                     && (folderPath + "/").hasPrefix(item.url.standardizedFileURL.path + "/")) {
                    Button(folder.name) {
                        Task { await library.move(item, into: folder.url) }
                    }
                }
            }
        } label: {
            Label("Move To", systemImage: "folder")
        }
    }

    /// "Add to note …" — appends this note's pages to another note and
    /// removes this one (the scratchpad → real note flow).
    @ViewBuilder
    private func appendMenu(for item: LibraryItem) -> some View {
        Menu {
            ForEach(library.allNotes(), id: \.url) { note in
                if note.url != item.url {
                    Button(note.name) {
                        Task { await library.appendNote(at: item.url, to: note.url) }
                    }
                }
            }
        } label: {
            Label("Add Pages to Note", systemImage: "text.append")
        }
    }

    private var storageBadge: some View {
        Image(systemName: library.storage == .iCloud ? "icloud" : "internaldrive")
            .foregroundStyle(.secondary)
            .help(library.storage == .iCloud
                ? "Synced via iCloud"
                : "Stored locally (iCloud unavailable)")
    }
}
