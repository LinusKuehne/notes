# Notes — project guide for Claude

A personal note-taking app for iPad + Mac (Mac Catalyst). Swift 6 / SwiftUI /
PencilKit / UIDocument+iCloud Drive. Min iPadOS 26 / macOS 26. Stage 1 =
one synced note of consecutive A4 pages; see `docs/` and the README for the
roadmap (folders, markdown/LaTeX, text boxes, scratchpad come later).

## Working rules (agreed with the user)

- **Workflows/subagents allowed: at most 4 in parallel.**
- **Never lose progress:** commit and push to the working branch after every
  completed step (small, frequent commits). Save non-code findings (research,
  design notes) into `docs/notes/` before moving on, so a fresh session can
  resume from the repo alone.
- Do not create a pull request unless the user asks.

## Build & verify

- **This repo is developed from a Linux environment.** Xcode/UIKit code
  cannot be compiled or run here. Use:
  - `scripts/verify-linux.sh` — plist/JSON/pbxproj validation, plus
    NotesCore tests and Swift syntax checks when a toolchain is present
    (no Swift toolchain is installable in the sandboxed environment —
    swift.org, Docker Hub blobs, and GitHub release assets are all blocked).
  - **GitHub Actions is the real verification** (`.github/workflows/ci.yml`):
    - `notescore-tests` (ubuntu, swift container) runs on every push.
    - `app-build` (macos-26, xcodebuild for generic/iOS **and** Mac
      Catalyst, `CODE_SIGNING_ALLOWED=NO`) runs on `workflow_dispatch` —
      trigger it via the GitHub MCP tools after app-layer changes and read
      failures with `get_job_logs`.
- The app target compiles with Xcode 26 defaults: Swift 6 language mode,
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency.
  Types used from UIDocument's background I/O paths (serialization,
  exporters) must be marked `nonisolated`.

## Architecture map

- `NotesCore/` — pure-Foundation SwiftPM package, builds/tests on Linux:
  document model (`Note`/`Page`), `manifest.json` codec, `.note` package
  serializer (`FileNode` tree), per-page last-writer-wins `NoteMerger`,
  A4 geometry (`NotebookLayout`). Keep it free of UIKit/PencilKit imports;
  PKDrawing data stays opaque `Data`.
- `NotesApp/Document/` — `NoteDocument` (UIDocument over a directory
  FileWrapper; incremental child-wrapper reuse), `DocumentStore` (container
  discovery, download-before-open, local fallback + migration, conflict
  watch, save-on-background), `ConflictResolver` (NSFileVersion → merge).
- `NotesApp/Notebook/` — `NotebookViewController` (zoomable UIScrollView of
  A4 pages in paper points; page virtualization: live PKCanvasView only near
  the viewport — many live canvases cause Metal OOM), `PageView` (text layer
  under ink), `ToolCoordinator` (PKToolPicker on iPad; Mac uses
  `MacToolStrip` because PKToolPicker never shows on Catalyst).
- `NotesApp/Export/` — `PDFExporter` (A4 PDF: vector text, rasterized ink),
  `BackupManager` (rotating PDFs into iCloud `Documents/Backups`; Mac-only
  mirror into a security-scoped user-picked folder, e.g. Google Drive's
  `~/Library/CloudStorage` folder — iPadOS cannot pick third-party
  file-provider folders).
- `Notes.xcodeproj/project.pbxproj` — hand-written, objectVersion 77,
  folder-synchronized `NotesApp/` group: **adding/removing files under
  `NotesApp/` requires no project edits.** Build settings live in
  `Config/*.xcconfig`; the user's team ID goes in `Config/Signing.xcconfig`.

## Conventions

- The `.note` package: `manifest.json` + `pages/<uuid>.drawing` +
  `text/<uuid>.md`. One file per page (iCloud uploads only what changed).
  Bump `Manifest.formatVersion` on layout changes and keep older versions
  loadable.
- Info.plist `NSUbiquitousContainers` changes only take effect when
  `CURRENT_PROJECT_VERSION` (CFBundleVersion) is bumped.
- Trailing empty pages are a view-only concept (Notability-style always-one
  blank page); they must never be persisted or exported.
