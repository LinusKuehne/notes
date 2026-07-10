# Notes

A personal note-taking app for **iPad and Mac** (Mac Catalyst), built with
Swift 6, SwiftUI, PencilKit, and iCloud Drive documents.
Minimum OS: iPadOS 26 / macOS 26.

**Stage 1 (current):** a single note made of consecutive A4 pages —
Apple Pencil handwriting (system palm rejection, lasso, ink tools via
PKToolPicker), full-page typed text (markdown source, rendering comes
later), iCloud sync between iPad and Mac, A4 PDF export, and rotating PDF
backups that can mirror into Google Drive from the Mac.

Planned next stages: folders & multiple notes, a quick-capture scratchpad
with an "unsorted" inbox, markdown + LaTeX rendering, text boxes, photo /
document embedding, more pen tools (vertical space, etc.).

## Project layout

| Path | What it is |
| --- | --- |
| `NotesCore/` | Pure-Foundation Swift package: document model, `.note` package format, conflict merging, A4 geometry. Builds and tests on any platform (`swift test --package-path NotesCore`). |
| `NotesApp/` | The app target (SwiftUI + UIKit interop). Folder-synchronized in Xcode — files added here appear in the project automatically. |
| `Notes.xcodeproj` | Hand-written project; all build settings live in `Config/*.xcconfig`. |
| `scripts/verify-linux.sh` | Non-Mac validation (used by the coding agent). |
| `.github/workflows/ci.yml` | CI: NotesCore tests on every push; full iOS + Catalyst build on manual dispatch. |

## One-time setup on your Mac

The repo builds unsigned in CI, but running on your devices (and iCloud
sync) needs your Apple Developer identity once:

1. **Xcode ▸ Settings ▸ Accounts** — sign in with your Apple ID. A paid
   Apple Developer Program membership is strongly recommended: the iCloud
   Documents entitlement is restricted on free personal teams.
2. Put your **Team ID** (10-character code, shown next to your team in
   Xcode's account settings) into `Config/Signing.xcconfig`:
   `DEVELOPMENT_TEAM = AB12CD34EF`
3. Open `Notes.xcodeproj`, select the **Notes** target ▸
   **Signing & Capabilities**, and enable *Automatically manage signing*
   for **both** rows — iOS *and* Mac Catalyst. The committed entitlements
   should make Xcode register the App ID `com.linuskuehne.notes` and the
   iCloud container `iCloud.com.linuskuehne.notes` on first build. If it
   complains, add the **iCloud ▸ iCloud Documents** capability and create
   the container by hand, then verify it exists under
   developer.apple.com ▸ Certificates, Identifiers & Profiles ▸ Identifiers.
4. **Build & run once for an iPad destination and once for
   "My Mac (Mac Catalyst)"** so automatic signing mints both provisioning
   profiles. (The classic failure — "provisioning profile doesn't match the
   entitlements file's value for icloud-container-identifiers" on the Mac
   build — is fixed by toggling automatic signing off/on and rebuilding
   once the container exists in the portal.)
5. Sign both devices into the same Apple ID with iCloud Drive enabled.
6. If Xcode rewrites `project.pbxproj` on first open (formatting, signing
   bits), commit that rewrite once.

### Good to know (first-run behavior)

- The app's folder in Files/Finder (**Notes**) appears only after the app
  has saved its first file into iCloud, and `NSUbiquitousContainers`
  settings are re-read only when the app's build number changes
  (`CURRENT_PROJECT_VERSION` in `Config/Shared.xcconfig`).
- Without iCloud (signed out / entitlement missing) the app stores the note
  locally and shows an internal-drive badge; it migrates the note into
  iCloud automatically the next launch after iCloud becomes available.
- On a second device the first launch downloads the note from iCloud before
  opening it.
- Simultaneous offline edits on both devices are merged automatically,
  page by page, newest edit wins per layer (ink / text separately).

## PDF backups

- Every platform: rotating `Notes <timestamp>.pdf` files (last 10) are
  written to the iCloud container's `Documents/Backups/` after saves —
  visible in Files ▸ Notes ▸ Backups.
- **Mac:** use the toolbar menu ▸ *Choose Google Drive Folder…* and pick a
  folder inside Google Drive (`~/Library/CloudStorage/GoogleDrive-…` with
  Google Drive for desktop installed). Backups are mirrored there and
  Google's file provider uploads them — no Google API involved.
- **iPad:** iPadOS does not allow apps to write into third-party cloud
  folders, so automatic Drive mirroring is Mac-only; from the iPad use
  *Share PDF* ▸ *Save to Drive* for a manual copy.

## Development notes

This repo is developed with Claude Code from a Linux environment where
Xcode is unavailable; the macOS CI job (`app-build`) is the compile check,
and `CLAUDE.md` documents the working rules (max 4 parallel subagents,
commit/push after every step).
