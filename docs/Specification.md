> Historical Phase 1 baseline. See [current implementation status](Status.md) and [security design](Security.md) for the expanded phase 1–6 source and current capabilities. The read-only entitlement described below has been replaced by user-selected read/write capability for explicit Trash/restore; original indexing bookmarks remain read-only.

# Vault: product and technical specification

Vault is a local-first macOS workspace that adds editable organization to user-selected files without silently moving, renaming, uploading, or deleting them. The initial workflow is: choose files → review scope and ownership → index originals or verify managed copies → browse, search, organize, and open them.

## Platform and design

Minimum macOS 14, Xcode 16 or newer, Swift 5.9-compatible language mode. macOS 14 supplies NavigationSplitView, modern observation-compatible SwiftUI APIs, ContentUnavailableView, SettingsLink, and the two-argument onChange API. There are no third-party runtime dependencies. Native window chrome, resizable sidebar and detail columns, restrained lavender/mint accents, rounded thumbnail cards, empty states, native menus, accessible system colors, and adjustable dark/light/system appearance define the shell. Dark is the initial default.

## Delivered Phase 1 scope

- Sandboxed macOS application, shared Xcode scheme, standalone domain package.
- Native multi-file selection and import review listing names, folders, counts, logical bytes, and ownership effects.
- Index in place with read-only security-scoped bookmarks; unique-directory managed copies with byte comparison and source modification checks before registration.
- Atomic JSON metadata persistence with schema checking. Corrupt metadata blocks writes rather than replacing the library with an empty database.
- Real filesystem name, type, logical size, available dates, location, and Vault-added date.
- Lazy thumbnail grid/list, Quick Look thumbnails, open in default app, reveal in Finder.
- Search over filenames, descriptions, and tags; favorites, media filter, collection filter; name/added/size/modified sorting.
- Create collections and add/remove memberships through the inspector. Edit descriptions and tags without changing source files.
- Explicitly confirmed index removal; underlying originals and managed copies are retained.
- Clear planned states for all later-phase navigation destinations. No fake graph, storage totals, activity, or credentials.

## Persistence choice and boundaries

`VaultCore` contains Codable value types and an atomic file-backed repository. JSON is appropriate for a small initial library, permits portable tests, has no migration dependency, and makes transactional save failure easy to surface. This is a deliberate MVP tradeoff, not the final large-library persistence engine: reads and writes currently happen on the main actor and rewrite the complete document. SwiftData/SQLite, asynchronous repository operations, pagination, and a migration from schema 1 are prerequisites for a large-library release.

`FileItem` stores UUID, filename/type, bookmark, last indexed location, ownership, logical size, filesystem timestamps, indexed timestamp, editable description/tags, collection IDs, and favorite state. The saved location for a managed copy is its managed destination. `FileCollection` stores its ID and name. Bookmarks resolve the current URL for open/reveal/preview; the inspector explicitly labels the saved location and metadata as an indexing-time snapshot. Stale bookmarks fail with reauthorization guidance rather than silently trusting an absolute path.

`FileAccessService` owns scoped access, metadata inspection, verified copy import, bookmark resolution, and file availability checks. Work-intensive inspection and copying run off the main actor. `LibraryStore` coordinates user intent and persistence; UI views consume its state. `LibraryRepository` owns encoding and atomic writes. There is no destructive filesystem service in this build. Removing a collection membership or an index entry does not call filesystem deletion.

Thumbnails are requested only for rendered lazy grid/inspector views; macOS may generate previews for supported formats. Unsupported types retain a generic icon and the default-app action. No text extraction or full-format support is claimed.

## Permission and privacy contract

App Sandbox is enabled with user-selected **read-only** file access and app-scoped bookmarks. Managed copies and metadata live in the sandbox's Application Support/Vault directory. There is no network entitlement, arbitrary-folder access, monitoring, telemetry, credential store, AI request, or automatic classification. Never put passwords into ordinary file metadata. A managed library is not encrypted and is not a substitute for a backup.

Users select regular files; directories and symlinks are rejected. Folder scans, overlap/hard-link accounting, import customization, sensitive-category detection, processing estimates, per-file progress, cancellation, retry jobs, and configurable managed-library locations are future work. The current import sheet states these limits. Copy verification is not a snapshot guarantee against hostile concurrent writers. Failed metadata saves leave verified managed copies available for manual inspection and explain that outcome.

## Next model migrations

Add Subject, Tag, and explicit Relationship entities independent of paths; ImportJob and ScanLocation for durable work/access state; StorageAnalysis, DuplicateGroup, and DeletionRecord for provenance-aware cleanup; StudySession for explicit study events; and SecureItem only in a separate encrypted store. Add source-origin provenance distinct from managed destination, stable file identities, availability/index status, thumbnail cache keys, and schema migration tooling before these features ship.
