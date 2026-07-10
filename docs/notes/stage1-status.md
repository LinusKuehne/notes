# Stage 1 status (2026-07-10)

Branch: `claude/custom-notetaking-app-eu3bc2`. All Stage-1 layers are
implemented and pushed; see CLAUDE.md for the architecture map and working
rules.

## Verification state

- `notescore-tests` (Linux CI): **green** since the first push.
- `app-build` (macOS CI, workflow_dispatch): iterating on Swift 6
  default-MainActor isolation errors. Fixed so far: nonisolated
  FileWrapperAdapter/PDFExporter/static constants; MainActor.assumeIsolated
  in UIDocument main-queue callbacks (state observer, save completion).
  Latest dispatch pending at time of writing — check Actions for the result
  of commit `a649edc`.
- A 3-agent review workflow (PencilKit/UIKit, document/sync, model/flow)
  was dispatched; apply confirmed findings as individual commits.

## Environment facts (do not rediscover)

- No Swift toolchain installable on this Linux sandbox: download.swift.org,
  Docker Hub blob CDN (cloudfront), and GitHub release-asset downloads are
  all blocked by the egress proxy; api.github.com is gated to this repo.
  GitHub Actions is the compile/test environment; use the GitHub MCP tools
  (`actions_run_trigger` with ci.yml, `get_job_logs` with failed_only).
- Repo is public → macOS runner minutes are free.

## Known Stage-1 limitations (deliberate)

- Text that overflows an A4 page is clipped (no pagination/reflow yet).
- Ink in exported PDFs is raster (vector ink impossible with public
  PencilKit API); typed text is vector/selectable.
- Automatic Google Drive mirroring is Mac-only (iPadOS cannot grant folder
  access to third-party file providers); iPad uses the share sheet.
- Undo/redo relies on PencilKit's built-in canvas undo; no document-level
  undo manager wiring yet.
- User's one-time signing/iCloud steps (README) still pending — user is on
  holiday without a Mac; unsigned CI builds are the only verification until
  then.

## Next stages (user will prompt)

Folders/multi-note, scratchpad inbox, markdown/LaTeX rendering, text boxes
(consider PaperKit), photos/documents, more pen tools.
