# Incremental smart folder scanning

This update extends the existing app and its existing folder-scan workflow. The Overview composition, sidebar navigation, graph renderer, node effects, camera, selection, file-opening behavior, storage cleanup, and Secure Vault are retained.

## Entry points and workflow

Use **Scan Folders** on Overview or in the sidebar. Existing **Approve Folder…** opens the same workflow. The native picker accepts multiple folders; no enumeration starts until **Start Scan**. The review lists exact source paths, categories, and optional processing permissions. Counts/sizes are explicitly measured during discovery rather than invented in advance. There is no artificial file-count limit. Manual scans first count matching files in bounded chunks, then process a second bounded pass; monitoring continues to use a single pass. Processing finishes indexing/organizing each chunk before requesting more files. The measured count powers estimated completed/remaining percentages. Minimize the cinematic progress sheet to continue navigating while the same task runs in the compact status bar. Keep Vault open. See [progress semantics and acceptance](ScanProgress.md). Chunk size controls temporary buffering, never the total scan size. Hidden files, packages, symbolic links, and configured excluded paths are skipped.

Quick selections are All Supported Files, Documents (documents/PDF/presentations/data), Photos & Media, and custom checkboxes. Presentations, spreadsheets/data, archives, images, media, ordinary documents, PDFs, and other catalogable types are distinct groups. Other files get metadata/default-app behavior; text/preview support is never implied for every type.

Previously saved category sets are versioned at read time: old Documents still includes the presentations/data it previously covered, and old Other still includes archives. New selections use the expanded taxonomy. Missing optional fields decode without discarding old libraries. Reapproving an existing folder recognizes legacy bookmarks and retains its ID/settings; background-monitor preferences are changed only when the monitoring option is explicitly enabled. Existing catalog entries are not removed when narrowing filters.

## Integration with existing architecture

`WorkspaceStore` still owns folder approval, saved location configuration, background polling, and workspace metadata. Its `FolderScanCoordinator` extension sequences discovery → indexing → organization → possible-duplicate review and persists job checkpoints/results in the existing workspace document. Polling reuses the same organization rules for new/changed files.

`FileAccessService` still handles approved scopes, regular-file metadata, bookmarks, and indexing. Discovery now reports individual unavailable entries while continuing safe independent work. `LibraryStore.synchronize` still calls its existing index/import routine, then merges by filesystem identity or path. Stable IDs, user descriptions/tags/favorites, and existing references are preserved. Hard links, nested source folders, and known rescanned paths do not create new catalog entries. No copying is performed by scanning; managed-copy import remains a separate existing choice.

`SmartOrganizationService` is new because there was no equivalent metadata-organization service. It uses the existing ContentService for opt-in supported PDF/UTF-8 text, plus ImageIO for photo metadata; no network request, reverse geocoder, OCR, or visual similarity runs automatically. `OrganizationRules` creates existing Subject/FileCollection memberships with provenance, not new graph node types or a separate knowledge database.

`KnowledgeMap.swift` is unchanged. It already renders actual subject/file and collection/file memberships. Capture years/months, GPS areas, folder contexts, file types, tags, and Needs Review are ordinary virtual collections; detected topics are ordinary subjects. Every added line comes from a stored membership. Existing manual document links remain intact. File selections expose evidence in the existing inspector; subject/collection nodes use their existing inspectors. Existing halos, hover/selection emphasis, pulses, focus, search, layers, and opening interactions apply to new nodes automatically.

## Organization evidence and limitations

- Photo dates use valid EXIF DateTimeOriginal only, preserving the recorded local timestamp and grouping by year/month. Filesystem creation/modification dates are not presented as capture dates.
- GPS processing is opt-in. Both valid coordinate values and hemisphere references are required. Coordinates are grouped to approximate two-decimal areas and labeled as such. No city, landmark, address, or location confidence is invented. Photos without GPS have no location group.
- Topic rules use explicit filename/folder/tag evidence, or at least two matching keywords from extracted text. Existing subject names can also match metadata. These are editable rule-based classifications, not AI or guaranteed semantic analysis.
- Supported text extraction is opt-in and stores plaintext in the regular existing text index. Unsupported Office/Keynote/archive content is not claimed to have been analyzed; metadata/folder/type grouping remains available. Image OCR stays an explicit inspector action.
- New uncertain document/topic cases and missing photo capture dates go to Needs Review. Inspect evidence and use Mark Reviewed after checking it. Unchanged files are not reclassified, so manual membership edits and review decisions survive ordinary rescans. Changes to metadata/tags or processing permissions cause reprocessing; only memberships previously owned by automatic organization are replaced. Manual groups, tags, descriptions, original files, and manual relationships are not overwritten.
- Visual photo similarity, reverse geocoding, OCR during automatic scans, full Office text extraction, semantic project inference, and cloud AI are not included. Projects can be represented by existing user collections/subjects and explainable folder context.

## Progress, interruption, and results

The sheet reports the current stage, discovered entries, processed indexing attempts, skipped/unchanged entries, and known errors. Overlapping sources can rediscover an entry; catalog-added counts remain unique by ID. Cancellation preserves catalog work already committed; organization not committed yet can be retried. A previously running job is marked Interrupted after reopening. Checkpoints retain approved bookmarks/settings for Retry Scan; a new retry merges safely rather than appending duplicates.

Results show added files, topics detected during this run, newly created date/GPS groups, new membership connections, review items, errors, and possible duplicate groups. Duplicate candidates use actual sizes with hard-link/reference identity deduplication through the existing AnalysisService; equal-sized files are not called verified duplicates. Use existing Storage & Cleanup for SHA-256 verification. Results link directly to relevant file, subject, and collection inspectors or the existing Knowledge Map.

Catalog and workspace JSON writes remain separate atomic files, not one database transaction. A failed organization metadata save is reported and can be retried using stable organization keys; originals remain intact. This does not add an ACID database or a general cross-filesystem transaction system.

## File inventory

New:
- `Packages/VaultCore/Sources/VaultCore/Organization.swift` — scan job/evidence values and pure organization rules.
- `Packages/VaultCore/Tests/VaultCoreTests/OrganizationTests.swift` — identity, organization, GPS, evidence, and compatibility invariants.
- `Vault/SmartOrganizationService.swift` — real ImageIO metadata and existing local text extraction.
- `Vault/FolderScanCoordinator.swift` — extension of the existing workspace coordinator.
- `Vault/FolderScanReview.swift` — extracted/extended existing review sheet, progress, and results.
- `docs/SmartScanning.md` — this integration/validation guide.

Modified:
- `Library.swift`, `Workspace.swift`, `WorkspaceTests.swift` in VaultCore — optional identity/provenance/job fields, expanded categories, compatibility, merge rules/tests.
- `FileAccessService.swift`, `LibraryStore.swift`, `WorkspaceStore.swift` — existing discovery/index/persistence/polling integration.
- `OverviewWorkspace.swift`, `WorkspaceView.swift`, `VaultApp.swift` — two entry points, shared presentation, scan/import scheduling guards.
- `SecureWorkspace.swift` — only the existing folder/category UI declared in that file; encrypted-record behavior is unchanged.
- `DetailViews.swift` — organization evidence and review action in the existing inspector.
- `VaultTests/FeatureTests.swift` — actual pipeline, interruption, cancellation/retry, EXIF/GPS opt-in fixtures.
- `Vault.xcodeproj/project.pbxproj` — native source/test target membership.
- `README.md`, `docs/Status.md`, `docs/Validation.md` — current usage and validation outcomes.

## Validation

Static Swift grammar parsing and Xcode object/source-reference checks pass. Attempted `swift test` and `xcodebuild … build` both exited 127 because the Linux host has neither tool. **No native compilation, XCTest, or runtime validation occurred.** The repository now has 24 package and 23 native test methods, all unrun here.

New tests cover filesystem-identity merges preserving manual metadata; idempotent memberships; real versus missing photo facts; invalid GPS; topic evidence thresholds; legacy category and metadata decoding; the complete scan/catalog/subject/review pipeline and repeated scan; manual subject removal surviving an unchanged rescan; interrupted-job recovery; generated JPEG EXIF/GPS metadata and opt-in handling; and cancellation/retry preserving originals.

On macOS, build and run the README commands, then test two overlapping disposable folders containing mixed formats. Review presets before Start, cancel/retry, compare original bytes/paths, inspect subject/date/GPS/review groups in the existing map, modify a file and let monitoring refresh it, restart mid-job, revoke folder permission, and verify unavailable-file reporting. Run light/dark/accessibility checks to confirm the existing design and interactions remain intact.

### Local scanning without a file-count cap

The previous 10,000-entry failure has been removed. FolderScanCursor streams discovery in chunks of up to 512 visited entries. The scan coordinator commits catalog and organization work between chunks, while monitoring uses the same cursor. Filtered/empty chunks do not rewrite the catalog. Scope access is closed on completion, cancellation, or failure, with idempotent explicit close and deinitialization cleanup. The collection-returning discovery methods remain available for callers needing an array, but production scan/monitor paths do not collect all source candidates before indexing.

Progress is cumulative across chunks; cancellation retains completed catalog batches, and Retry Scan can resume by safely rescanning known identities. There is no guaranteed maximum capacity or performance claim: the existing catalog/workspace stores still grow with the indexed library and use atomic JSON snapshots. This update removes the arbitrary scan quota and bounds transient discovery/organization buffers; it does not replace persistence with a disk-paged database.

Three additional native regression tests cover 10,003 files (past the former cap) while asserting per-chunk buffering, repeated cursor closure without file deletion, and a complete catalog/organization scan spanning multiple chunks. These tests remain unrun in the Linux environment.
