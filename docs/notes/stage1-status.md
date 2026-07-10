# Stage 1 + Stage 2 foundation status (2026-07-10)

Branch: `claude/custom-notetaking-app-eu3bc2`. **Stage 1 is complete and
the Stage 2 foundation (library organization) is built — both fully green
in CI** as of commit `99a92b1`; see CLAUDE.md for the architecture map and
working rules.

## Stage 2 foundation (built while the user is away from a Mac)

- Library = plain directories + `.note` packages in the container; a
  note's title IS its file name (Files/Finder mirror the app).
- `LibraryStore`: tree scan + live metadata-query rescans, local→cloud
  migration with rename-on-collision, coordinated create/rename/move/
  delete, scratchpad captures into `Unsorted/`, append-note-to-note
  (connect a capture to a real note; source deleted only after the target
  wrote). `NoteSession`: the Stage-1 per-note open/sync logic by URL.
- UI: `LibraryView` browser (context menus, pull-to-refresh, one-tap
  scratchpad that opens directly), `NotebookScreen` per note.
- Deliberately deferred until device testing: markdown/LaTeX rendering,
  text boxes, photos (user decision — Stage 2 UI-heavy features wait).

## Verification state

- `notescore-tests` (Linux CI): **green** (including NoteMerger ordering
  regression tests added by the review).
- `app-build` (macOS CI, workflow_dispatch): **green** — both generic/iOS
  and Mac Catalyst destinations compile unsigned on the macos-26 runner.
- A 3-agent review (PencilKit/UIKit, document/sync, model/flow) produced
  16 findings — all fixed (see the "Apply review findings" commit): zoom
  transform vs frame corruption, initial fit-width zoom, visible-window
  refresh on layout, hitTest side effects, tool propagation to new
  canvases, empty-drawing serialization, conflict merge persisted before
  version pruning, merger run-reversal, restart stall, and more.
- NOT yet verified: actual runtime behavior on device — requires the
  user's Mac/iPad (signing steps in README).

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
