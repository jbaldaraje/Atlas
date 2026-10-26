# Vault

A local-first native **macOS 14+** file and knowledge workspace, written in Swift/SwiftUI with no third-party runtime dependencies. Requires **Xcode 16+**.

**Development implementation spanning phases 1–6. Not production-ready: macOS compilation, runtime testing, and security review remain pending.** See [current status and gaps](docs/Status.md).

## Build and run on a Mac

Open `Vault.xcodeproj`, choose the shared **Vault** scheme and **My Mac**, set a signing team if required, then run with ⌘R. Preserve App Sandbox, user-selected read/write capability, and app-scoped bookmarks. The read/write capability enables explicitly requested native Trash/restore; indexed originals use read-only bookmarks.

```sh
xcodebuild -project Vault.xcodeproj -scheme Vault -destination 'platform=macOS' -derivedDataPath /tmp/VaultDerivedData build CODE_SIGNING_ALLOWED=NO
xcodebuild -project Vault.xcodeproj -scheme Vault -destination 'platform=macOS' -derivedDataPath /tmp/VaultDerivedData test CODE_SIGNING_ALLOWED=NO
cd Packages/VaultCore
swift test
```

The package contains **69 tests**; the Xcode integration target contains **52 tests**. They have been written but **not executed** here. This Linux machine has neither Swift nor the macOS SDK. [macOS CI](.github/workflows/macos.yml) is provided but has not run. Unsigned CLI builds cannot validate signed sandbox behavior.

## If Xcode reports “Unable to find module dependency: VaultCore”

The Xcode project now builds `VaultCore` as an explicit native static framework target and links it into both Vault and VaultTests. Its source files are shared with the standalone package under `Packages/VaultCore`; no package needs to be added manually or downloaded for the app build.

Close Xcode, update the checkout with `git pull --ff-only`, then reopen `Vault.xcodeproj`. Select **Vault / My Mac**, choose **Product → Clean Build Folder** (⇧⌘K), and build again (⌘B). Keep any local signing changes; do not reset or discard them to update. If Git reports conflicting local changes, resolve those before continuing.

For a build independent of Xcode’s existing derived data, run from the repository root:

```sh
xcodebuild -project Vault.xcodeproj -scheme Vault \
  -destination 'platform=macOS' -derivedDataPath /tmp/VaultModuleCheck \
  build CODE_SIGNING_ALLOWED=NO
```

That unsigned command checks compilation; use the signed Xcode Run workflow for normal app execution. If it fails, inspect the first error in the VaultCore build rather than only later import errors.

## If the Touch ID prompt closes before Secure Vault unlocks

Update to the latest source, rebuild, and run the signed app from Xcode. The unlock flow now tolerates temporary focus changes caused by the system authentication panel while keeping the vault locked. It waits for Vault to regain focus before showing any records. Locking manually, navigating away, sleeping, or changing the login session still cancels the attempt. Cancel Unlock is available while authentication is pending.

If it still fails, report the exact message shown. Keychain failures now include their status code and distinguish signing/access problems, missing keys, and unreadable ciphertext. Keep the same signing team and bundle identifier used to create the vault. Do not delete `records.aesgcm` or Keychain items to troubleshoot: losing the key can make existing records unrecoverable.

## Use the workspaces

- **Overview / All Files:** Add Files (⌘I), review scope, index originals or create verified copies. Browse parent folders first, then open immediate children in paged grid/list views. Search filename/description/tags and opt-in extracted text, sort/filter, favorite, create collections, and edit metadata in the inspector. See [folder-first browsing and performance](docs/FolderBrowsing.md). Drop files onto regular library workspaces to review import. ⌘-click files and use Organize for batch tags, collection membership, favorites, or confirmed index removal.
- **Scan Folders / Approved Locations:** Use Scan Folders on Overview or the sidebar, select multiple folders, choose presets/categories and optional local text/GPS processing, then Start Scan. There is no file-count cap: a counting pass measures matching files, then indexing and organization run in batches. The cinematic progress sheet shows estimated completed/remaining percentages and a loading bar. Minimize it to keep navigating while scanning continues in a compact status bar; Expand and Cancel control the same job. Keep Vault open. See [scan progress and background navigation](docs/ScanProgress.md). Progress/results show added files, topics, photo groups, review items, possible duplicates, and errors. Retry is safe for known files. Existing monitoring runs every 30 seconds while Vault is open; pause, exclude relative paths, change File Types, or disconnect. Metadata-only scanning never moves originals. See [smart scanning integration and limitations](docs/SmartScanning.md).
- **Subjects:** Open a subject parent, browse linked folders, use Link Files to choose documents on demand, save descriptions/deadlines, and explicitly record study sessions. Opening a file never counts as study.
- **Knowledge Map:** Explore file-type nodes and curved connections; pan/pinch/zoom/fit, focus direct neighbors, switch to a list, filter layers, and create links through file context menus. Double-click opens real files. Node positions persist. A short selection pulse respects Reduce Motion; a cached background index supplies pages of up to 150 nodes and 900 visible connections. Search covers the full catalog, and page controls reach all matches. Opening the map no longer saves the full workspace; explicit node drags save a separate background layout. See [large-library behavior and validation](docs/KnowledgeMapPerformance.md). Inspect relationships from the file inspector to remove links.
- **Timeline:** Open an event parent, then a month and folder, to see paged Vault-added events, explicit study records, and separately labeled filesystem modification dates.
- **Storage & Cleanup:** Analyze distinct file identities and streaming SHA-256 duplicate candidates. Filter largest/old files. Originals require confirmation plus a fresh native grant for the exact file before macOS Trash; protected locations are excluded. Managed copies use Vault's recoverable area. Nothing is removed automatically.
- **Recently Deleted:** Restore retained managed copies without overwrite or confirm permanent removal. Native Trash restores use a fresh destination grant; Finder may remove those files independently. Retained files still consume storage. Allocated size is not a guaranteed reclaim estimate on APFS.
- **Secure Vault:** Unlock with OS authentication, store/edit/delete encrypted credentials, licenses, recovery codes, or private notes. Lock is automatic on inactivity/focus loss/sleep/session changes. Clipboard clears after 20 seconds if unchanged. The Keychain key is device-bound; ciphertext backups alone do not provide portable recovery. See [security design and limitations](docs/Security.md).
- **Inspector / Local content index:** Explicitly extract supported PDF/UTF-8 text or image OCR, search locally, review a description excerpt and tag suggestions, and save only if desired. Extracted text is plaintext outside Secure Vault; do not process sensitive documents casually. Remote AI is not included.

Metadata and managed files live inside the sandbox's Application Support/Vault directory, normally `~/Library/Containers/com.vault.workspace/Data/Library/Application Support/Vault`. Preserve this directory and original files when troubleshooting. Do not delete corrupt databases to make startup succeed. Regular library files/metadata are not encrypted. Secure records are encrypted separately.

## Required macOS acceptance before release

Use disposable fixtures only. Validate import/copy cancellation, conflict preservation, restart bookmarks, folder grants/revocation, exclusions/disconnect, graph interaction, extracted-text invalidation after modifications, OCR format/error limits, unavailable volumes, storage identity accounting, duplicates, and crash/save failures. Exercise native Trash and managed recovery in signed sandbox builds, including externally emptied Trash and restore conflicts. Validate real Touch ID/OS fallback, cancellation/lockout, Keychain loss, tampered records, idle/sleep/focus races, and clipboard ownership. Run VoiceOver, keyboard, resizing, light/dark, performance, and independent security review. These remain pending.

See [spatial design and interaction checklist](docs/Design.md), [specification](docs/Specification.md), [phase roadmap](docs/Roadmap.md), [implementation status](docs/Status.md), and [validation record](docs/Validation.md).

The Overview shows parent folders and a compact subject/collection network entry. File shelves and child thumbnails load only after navigating into a parent. The native context inspector starts collapsed; select an item to reveal it or use Option–Command–I. The Inspector Preview action opens native Quick Look where supported.

## Sidebar mascot and glass appearance

The left panel includes a native 3D mascot and live local activity status for scans, import, folder checks, authentication, secure locking, and errors. Panels and buttons use glass materials with restrained cinematic lighting. In Settings, use **Cinematic animations** and **Show 3D sidebar mascot** to control motion and space. macOS Reduce Motion/Reduce Transparency are respected, and continuous mascot rendering pauses in inactive windows. See [mascot, glass, privacy, and validation details](docs/MascotGlass.md).

## Import iCloud / Apple Notes

Open **Notes → Add iCloud / Apple Notes** (also **Add Notes** on Overview), connect to Apple Notes on this Mac, allow the Automation prompt, and select your iCloud account, folder, and unlocked notes. Vault imports readable local plain-text snapshots and can refresh them manually. It does not edit originals or sign in directly to iCloud. Locked notes and attachments are excluded; imported copies are ordinary unencrypted library files. Exported PDF/text notes are supported as a fallback through the existing file importer. See [permissions, use, safety, and pending native validation](docs/AppleNotes.md).

## Parent-first navigation for large libraries

All Files, Images & Media, Collections, Subjects, Timeline, Notes, Overview, Storage, and Recently Deleted now present parent folders or groups before individual children. Views render at most 60 children per page and prepare their metadata in the background; Previous/Next reaches the complete current level. No scan/index limit is added. Thumbnail work is queued, cached, and cancelled when leaving file cards. See [behavior, architecture, and required macOS acceptance](docs/FolderBrowsing.md).

## File type filters on file workspaces

Use **All Types / Docs / Media / Photos** in the page header. Docs includes PDFs, text documents, presentations, and spreadsheets; Media is audio/video; Photos is images. The choice persists across tabs and parent-folder navigation, updates matching counts, and keeps paged background browsing. All Types restores archives and other files too. Scan/monitor settings remain independent. See [scope, behavior, and pending native validation](docs/FileTypeFilters.md).

## Connected documents and personal dashboard

Select a file for **At a Glance**, source excerpts, key-term search, and **Connected Documents** with real relationship explanations. Preview supports connected reading, back/forward trails, and an optional view of the existing Knowledge Map. Indexed-text comparisons are optional, labeled suggestions, and can be reviewed or dismissed.

In Overview, choose **Customize Dashboard** to show/hide, reorder, resize, and prioritize Notes, Documents, Photos, Media, Recently Accessed, Favorites & Pinned, Continue Exploring, and Storage Snapshot widgets. Settings and trails save locally. Widgets use bounded real catalog results and existing viewers; Notes creation remains the existing import flow. See [behavior, modified files, test results, and macOS acceptance](docs/ConnectedExplorerDashboard.md).
