# Connected document exploration and dashboard widgets

An incremental extension of the existing Vault application in the Atlas repository. The Overview, scoped file catalog, Knowledge Map renderer, subjects, collections, Apple Notes snapshots, scanning jobs, and Secure Vault remain the existing systems. No additional original files are copied, moved, renamed, or deleted for these features.

## Explore a document

Select an indexed file to open its existing inspector, then choose **Preview** for the expanded reader. **At a Glance** shows your saved description and available local indexed text: short source excerpts, heading-like lines, frequent terms, and date strings. These are source-derived aids, not generated summaries or validated event dates. A missing index produces an explanatory empty state and the existing explicit **Extract Text / OCR Locally** action. Extraction writes plaintext to the regular local index; it is separate from Secure Vault.

Key-term buttons search the document. PDFs up to 50 MB use PDFKit's asynchronous native search and navigate to the first match. Other formats retain native Quick Look and offer a bounded indexed-text excerpt around the first match. Unsupported or locked documents can be opened in their default app. Search covers only the existing text index for formats without PDF search; that index can be partial or older than the original. This change does not add universal Office extraction, citation parsing, named-entity recognition, media durations, or an AI summarizer.

**Connected Documents** uses the shared graph index and shows at most 12 documents per page. Every displayed reason has evidence:

- Explicit user connections include their stored labels and a confirmed **Remove User Connection** action. Removing a link only edits the relationship.
- Shared subjects show stored membership. Two memberships still owned by the organization engine are identified as editable suggestions with the recorded evidence when available. Manual membership editing clears that ownership marker.
- Shared tags and meaningful virtual collections use existing metadata. Merely sharing a physical folder or automatic file-type collection does not produce a suggested connection.
- Photo date/GPS labels require matching recorded facts and the corresponding group key. A collection membership without those facts is presented as a shared collection.
- **Compare existing indexed text** is off initially. Enabling it compares up to 12,000 already-indexed characters and 60 frequent terms per indexed document. A candidate needs at least three shared distinct terms; it is a lexical suggestion, not a semantic similarity score. No new file extraction or external request occurs. **Save Connection** creates a reviewed user relationship through the existing workspace model; **Dismiss Text Match** hides that pair's text evidence without removing other reasons or user links.

Related items include real saved descriptions when present. Subject, collection, and tag actions use existing browsing/search routes. Metadata-only files remain useful without extracting their content. All Types / Docs / Media / Photos continues to filter connected candidate documents before paging.

## History and map context

Compact back/forward controls and the trail menu preserve up to 80 document, subject, collection, and relationship visits. A new branch discards forward history. The reader's back/forward controls skip non-document entries; the inspector's trail can revisit topics. History persists as IDs, reasons, and timestamps, without filenames, bookmarks, paths, or document contents. Missing files are pruned when the catalog changes; unavailable historical items have a fallback label. Restoring saved history does not automatically reopen a document at startup.

Following a connected document updates the existing reader, inspector, and optional embedded map. The full map and embedded map share one cached `KnowledgeGraphIndex`; they have independent viewport/projection state. Existing positions are reused when changing selection. The map focuses the selected node with a short transition while retaining nearby context. Active paths use actual existing direct edges or shared meaningful parent edges; a text suggestion does not create a graph edge until saved. Selected/origin context may remain visible outside the active type filter, which the map footer explains.

The existing 150-node / 900-edge drawing budgets, full-catalog search/paging, background preparation, and separate graph-layout persistence remain. Hover and camera changes do not rebuild the catalog. Selection pulses stop after 1.8 seconds; Reduce Motion and the Cinematic animations preference disable them. Parent-folder paths and page positions are retained per window when leaving ordinary browsers, separately from persisted exploration history.

## Customize Overview

The new **Your quick access** area sits inside the existing Overview. Choose **Customize Dashboard** to show/hide, reorder, select compact/expanded sizes, and prioritize recent or favorite items. Drag cards to reorder, use the list's move controls, or reset the default layout. Three widgets are initially visible: My Notes, My Documents, and Favorites & Pinned. Expanded widgets span two columns when space permits; the grid reflows down to one column.

| Widget | Source and actions |
|---|---|
| My Notes | Imported Apple Notes/exported-note records; source modification dates when available, favorite priority, real excerpts, existing note reader. Add Notes opens the existing import flow. Generic note creation is not supported. |
| My Documents | Recently added or successfully opened document records; preview, default app, favorite, Finder, graph, and View All into Docs browsing. |
| My Photos | Recent/favorite images using the existing thumbnail cache; stored capture date/approximate GPS when available, otherwise indexed date. Preview and View All use the current library. |
| My Media | Existing audio/video records with thumbnails/icons and real file type; native preview/default-app playback and Media browsing. |
| Recently Accessed | Existing opened-file activity, recorded only after a successful default-app open or successfully loading an explicitly opened plain-text note reader. Scanning, selecting metadata, and studying are not inferred access events. View All opens existing activity groups. |
| Favorites & Pinned | Existing file favorites plus locally pinned collection IDs. Context menus favorite files; collection browser context menus pin collections. View All offers favorite files or pinned collections. |
| Continue Exploring | Actual visits through the current history cursor, with original visit reasons/timestamps. Opens the existing map with that item selected. |
| Storage Snapshot | Distinct indexed logical bytes, managed logical bytes, and the last available measured allocated analysis/verified duplicate groups. Opens Storage & Cleanup. These are indexed scopes, not Mac capacity or guaranteed recoverable space. |

Widgets have their own named categories rather than inheriting the browser's global type selection. This is stated above the grid. Their View All actions set the corresponding existing browser filter. Existing parent-folder and group browsing remains parent-first with 60 children per page; widgets show only 3 items (compact) or 6 (expanded), plus at most that many pinned collections in Favorites. Hidden widgets do not publish rows or request previews. Background top-k preparation avoids sorting the full file catalog into each widget. Only visible photo/media rows request thumbnails through the existing bounded queue.

Note snippets reuse saved descriptions or indexed text. When neither exists, visible managed plain-text note snapshots can provide an ephemeral excerpt from at most 2,048 bytes. At most 64 snippet cache entries are retained in memory. This does not make an unindexed note searchable or write another note/index. Regular imported notes remain unencrypted local copies under the existing Notes consent model.

## Persistence and boundaries

`workspace-preferences.json` lives in the existing Application Support/Vault directory (inside the sandbox for the signed app). It contains dashboard settings, exploration IDs/reasons/timestamps, pinned collection IDs, and dismissed text-match pairs. Writes are atomic and debounced on a background actor; Customize Done and scene inactivity request a flush. The file is small and separate from the full existing catalog/workspace JSON. A corrupt preferences file is preserved and reported, with preference writes disabled until repaired; keep a copy before recovering it. File viewing/catalog operations remain available. Abrupt process termination can still lose the last pending preference change.

No new entitlement, third-party dependency, network call, telemetry, or Secure Vault access is introduced. Existing regular-library metadata and text are not encrypted. Existing full-catalog JSON persistence and the first background metadata/content-index build remain costs; this implementation is not a replacement database or a claim of measured 30k-file latency. Stored identities deduplicate logical totals where available; logical bytes are not allocated or reclaimable bytes, and separately managed hard-link references are not additive physical usage.

## Source inventory

New files:

- `Packages/VaultCore/Sources/VaultCore/Exploration.swift`: bounded history, connection evidence, source-grounded glance, optional lexical index, paging DTOs.
- `Packages/VaultCore/Sources/VaultCore/Dashboard.swift`: widget configuration, backward-compatible preferences, bounded dashboard snapshots and storage scopes.
- `Vault/WorkspacePreferencesStore.swift`: atomic local preference persistence and corruption handling.
- `Vault/ExplorationNavigator.swift`, `Vault/ExplorationTrailView.swift`: per-window history, routes, browser sessions, compact trail.
- `Vault/DocumentExplorerModel.swift`, `Vault/SelectionContext.swift`: shared-actor context lookup and cancellable preparation.
- `Vault/DocumentContextPanel.swift`: glance, evidence, connected navigation and review actions in the existing inspector/reader.
- `Vault/SearchablePDFPreview.swift`: bounded native PDF preview and asynchronous find.
- `Vault/DashboardModel.swift`, `Vault/DashboardWidgets.swift`: cached dashboard preparation, responsive widgets and customization.
- `Packages/VaultCore/Tests/VaultCoreTests/ExplorationTests.swift`, `DashboardTests.swift`, and `VaultTests/ExplorationIntegrationTests.swift`: regression fixtures.

Modified existing files:

- Core `KnowledgeGraph.swift`, `CatalogBrowser.swift`: shared connection indexes, actual path edges/context filtering, pinned collection query.
- `Vault/KnowledgeMapModel.swift`, `KnowledgeMap.swift`: shared actor/index, per-presentation position reuse, selection focus and paths.
- `Vault/WorkspaceView.swift`, `ContextInspector.swift`, `DetailViews.swift`, `FilePreview.swift`: stable reader presentation, centralized routes, deferred selection lookup and integrated discovery. The former `RelatedFileLinks.swift` list is retired; its explicit-link details/removal are integrated into Connected Documents.
- `Vault/LibraryStore.swift`, `WorkspaceStore.swift`: shared graph engine, current-record metadata edits, note snippet access, real activity revision/recording.
- `Vault/FolderBrowser.swift`, `FolderBrowserModel.swift`: per-window parent context, collection pins, shared widget preparation cache, manual subject provenance.
- `Vault/OverviewWorkspace.swift`, `NotesWorkspace.swift`, `NotesSnapshotService.swift`, `VaultApp.swift`: additive widgets, existing note-reader routing/activity, bounded snippets, shared preferences.
- `Vault.xcodeproj/project.pbxproj`: explicit new app/core/test source membership. README, Status, Validation, FileTypeFilters, and this document describe behavior and limits.

## Actual validation and remaining acceptance

Added 26 regression methods: 17 domain/package and 9 native integration tests. Coverage includes history branching/pruning/corrupt cursor bounds, evidence ranking/provenance/dismissal, real graph paths, source-only excerpts, 30,123-file connection paging/top-k widgets, widget preferences/defaults/order/priority, identity-aware logical storage, pinned collections, shared graph build reuse, cancellation, independent presentation positions, corruption preservation, current-record metadata safety, bounded UTF-8 note snippets, and explicit activity without study inference.

This Linux environment has neither Swift nor Xcode. `swift test --package-path Packages/VaultCore` and `xcodebuild -project Vault.xcodeproj -scheme Vault -destination 'platform=macOS' test` both returned exit 127 (command not found). No new or existing XCTest was run. Static Swift grammar, project references/exact source membership, scheme XML, entitlements plist, and whitespace checks pass; these are not compilation. Current totals: 70 Swift files, 69 package methods and 52 native integration methods, all unrun here.

On macOS, use README build/test commands, then validate with disposable fixtures:

1. Select related documents with explicit links, manual/automatic subjects, tags, manual collections, and EXIF/GPS groups. Check each explanation, remove only a user link, review subject membership, and verify same-folder-only files are not invented connections.
2. Test metadata-only, indexed PDF/text, locked/unsupported files, stale bookmarks, removed files, and unavailable volumes. Confirm defaults do not extract text, optional comparisons remain suggestions, dismissal preserves user links, and saved links survive restart.
3. Follow A → B → C in inspector/preview/embedded map, back/forward/branch and topic routes; check camera orientation, real path direction, synchronized selection, preserved browser paths, reopened history, and no writes to originals.
4. Search real PDF terms, repeat/cancel rapidly, switch documents during loading/search, test files over 50 MB and encrypted PDFs, verify source excerpts and Quick Look fallback. Native PDFKit callback/lifetime behavior remains unverified here.
5. Show/hide/reorder/resize/prioritize/reset every widget, drag cards, pin/unpin files/collections, use every View All/preview/open/Finder/graph action, restart, and check preferences. Exercise missing/corrupt preference files without discarding originals.
6. Verify note widget snippet/reader/refresh/import behavior, actual access vs scanning, no implicit study events, and storage scopes against analysis. No note text should enter the index without the existing explicit extraction/searchable-import choice.
7. Profile a 30k+ library while scanning and navigating. Check frame time, memory, first metadata/text-index costs, canceled jobs, thumbnail queue, and the existing 60-child / 150-node limits. No runtime performance figures are claimed.
8. Exercise keyboard/context-menu actions, VoiceOver, narrow windows, light/dark, Reduce Motion/Transparency, multiple windows, signed sandbox grants and recovery workflows. Independent security/release acceptance from Status.md remains pending.
