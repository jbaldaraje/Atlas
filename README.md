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

The package contains **14 tests**; the Xcode integration target contains **9 tests**. They have been written but **not executed** here. This Linux machine has neither Swift nor the macOS SDK. [macOS CI](.github/workflows/macos.yml) is provided but has not run. Unsigned CLI builds cannot validate signed sandbox behavior.

## Use the workspaces

- **Overview / All Files:** Add Files (⌘I), review scope, index originals or create verified copies. Browse grid/list, search filename/description/tags and opt-in extracted text, sort/filter, favorite, create collections, and edit metadata in the inspector. Drop files onto regular library workspaces to review import. ⌘-click files and use Organize for batch tags, collection membership, favorites, or confirmed index removal.
- **Overview / Approved Locations:** Approve a folder and inspect its complete regular-file listing before indexing/monitoring. Polling runs every 30 seconds while Vault is open. Pause, exclude relative subfolders, or disconnect. Hidden files/packages/symlinks are skipped; over 10,000 files rejects the scan. Missing references are preserved and produce access errors on open.
- **Subjects:** Create subjects, edit descriptions/deadlines, link documents, and explicitly record study sessions. Opening a file never counts as study.
- **Knowledge Map:** Explore file-type nodes and curved connections; pan/pinch/zoom/fit, focus direct neighbors, switch to a list, filter layers, and create links through file context menus. Double-click opens real files. Node positions persist. A short selection pulse respects Reduce Motion; rendering is capped at 150 matching nodes. Inspect relationships from the file inspector to remove links.
- **Timeline:** See Vault-added events, explicit study records, and separately labeled filesystem modification dates.
- **Storage & Cleanup:** Analyze distinct file identities and streaming SHA-256 duplicate candidates. Filter largest/old files. Originals require confirmation plus a fresh native grant for the exact file before macOS Trash; protected locations are excluded. Managed copies use Vault's recoverable area. Nothing is removed automatically.
- **Recently Deleted:** Restore retained managed copies without overwrite or confirm permanent removal. Native Trash restores use a fresh destination grant; Finder may remove those files independently. Retained files still consume storage. Allocated size is not a guaranteed reclaim estimate on APFS.
- **Secure Vault:** Unlock with OS authentication, store/edit/delete encrypted credentials, licenses, recovery codes, or private notes. Lock is automatic on inactivity/focus loss/sleep/session changes. Clipboard clears after 20 seconds if unchanged. The Keychain key is device-bound; ciphertext backups alone do not provide portable recovery. See [security design and limitations](docs/Security.md).
- **Inspector / Local content index:** Explicitly extract supported PDF/UTF-8 text or image OCR, search locally, review a description excerpt and tag suggestions, and save only if desired. Extracted text is plaintext outside Secure Vault; do not process sensitive documents casually. Remote AI is not included.

Metadata and managed files live inside the sandbox's Application Support/Vault directory, normally `~/Library/Containers/com.vault.workspace/Data/Library/Application Support/Vault`. Preserve this directory and original files when troubleshooting. Do not delete corrupt databases to make startup succeed. Regular library files/metadata are not encrypted. Secure records are encrypted separately.

## Required macOS acceptance before release

Use disposable fixtures only. Validate import/copy cancellation, conflict preservation, restart bookmarks, folder grants/revocation, exclusions/disconnect, graph interaction, extracted-text invalidation after modifications, OCR format/error limits, unavailable volumes, storage identity accounting, duplicates, and crash/save failures. Exercise native Trash and managed recovery in signed sandbox builds, including externally emptied Trash and restore conflicts. Validate real Touch ID/OS fallback, cancellation/lockout, Keychain loss, tampered records, idle/sleep/focus races, and clipboard ownership. Run VoiceOver, keyboard, resizing, light/dark, performance, and independent security review. These remain pending.

See [spatial design and interaction checklist](docs/Design.md), [specification](docs/Specification.md), [phase roadmap](docs/Roadmap.md), [implementation status](docs/Status.md), and [validation record](docs/Validation.md).

The Overview now shows real recently added/opened files and a compact network entry rather than statistic cards. The native context inspector starts collapsed; select an item to reveal it or use Option–Command–I. The Inspector Preview action opens native Quick Look where supported.
