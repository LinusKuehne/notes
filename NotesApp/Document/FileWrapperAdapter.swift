import Foundation
import NotesCore

/// Bridges NotesCore's platform-neutral `FileNode` tree to real `FileWrapper`s.
///
/// The interesting part is `apply(_:reusing:)`: it reuses existing child
/// wrappers whose contents are unchanged, so `FileWrapper`'s incremental
/// writing skips them on disk and iCloud only uploads the page files that
/// actually changed.
enum FileWrapperAdapter {
    static func fileNode(from wrapper: FileWrapper) -> FileNode {
        if wrapper.isDirectory {
            var children: [String: FileNode] = [:]
            for (name, child) in wrapper.fileWrappers ?? [:] {
                children[name] = fileNode(from: child)
            }
            return .directory(children)
        }
        return .file(wrapper.regularFileContents ?? Data())
    }

    /// Builds a `FileWrapper` for `tree`, reusing children of `existing` that
    /// are byte-identical. Returns `existing` itself when nothing changed at
    /// this level or below.
    static func apply(_ tree: FileNode, reusing existing: FileWrapper?) -> FileWrapper {
        switch tree {
        case .file(let data):
            if let existing, !existing.isDirectory, existing.regularFileContents == data {
                return existing
            }
            return FileWrapper(regularFileWithContents: data)

        case .directory(let children):
            let existingChildren = (existing?.isDirectory == true) ? (existing?.fileWrappers ?? [:]) : [:]

            var result: [String: FileWrapper] = [:]
            var anyChanged = false
            for (name, childNode) in children {
                let existingChild = existingChildren[name]
                let childWrapper = apply(childNode, reusing: existingChild)
                result[name] = childWrapper
                if childWrapper !== existingChild { anyChanged = true }
            }
            let removed = Set(existingChildren.keys).subtracting(children.keys)
            if !removed.isEmpty { anyChanged = true }

            if let existing, existing.isDirectory, !anyChanged {
                return existing
            }

            let directory = FileWrapper(directoryWithFileWrappers: [:])
            for (name, child) in result {
                if child.preferredFilename != name {
                    child.preferredFilename = name
                }
                directory.addFileWrapper(child)
            }
            return directory
        }
    }
}
