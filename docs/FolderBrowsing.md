# Parent folders and on-demand children

File-heavy workspaces now open at a parent/group level. They do not build a view or request a thumbnail for every catalog file. Select a parent to load its immediate children, use Back/Parents to return, and use Previous/Next to reach all items at that level. A page contains at most **60 groups/files/events combined**. This is a presentation budget, never a scan or indexing quota.

## Workspace behavior

- **All Files / Images & Media:** start with indexed parent folders. Approved source paths are preferred as roots, nested roots are collapsed, and existing individual imports fall back to their indexed parents. A folder shows only its immediate subfolders and files. Media includes image, video, and audio categories. Favorites, text/type/size/date filters, sorting, grid/list, inspection, Cmd-click selection, bulk metadata actions, and confirmed index removal remain available. Search finds matches across the scoped index while retaining the folder hierarchy; a parent’s count reflects matching descendants. Go to Parents to search the whole current scope.
- **Collections:** show virtual parent collection cards first. Open one to browse its indexed folder hierarchy. Empty collections remain visible and editable. The toolbar no longer constructs a picker for every collection.
- **Subjects:** show subject cards first. Opening a subject reveals its linked parent folders, not a toggle for every library file. Link Files opens a searchable folder browser with checkboxes only for the current file page. Description/deadline edits are saved explicitly, avoiding a whole-workspace save per keystroke. Study recording remains an explicit user action.
- **Timeline:** start with three event parents: Added to Vault, last-indexed filesystem modification dates, and explicitly recorded study sessions. Open a parent, then a month. File event months show parent folders before files; study months show paged session records. Filesystem dates and Vault dates remain distinct. Merely opening a file never creates study history.
- **Notes:** start with imported accounts, then source note folders, then paged snapshots. They use the account/folder names captured from Notes rather than per-snapshot managed-library UUID directories. The note reader opens only for the selected snapshot and retains manual refresh, native preview, inspection, and Open Local Copy.
- **Overview:** replaces eager recently-opened/added file shelves with a parent-folder browser. Recent activity remains available behind its own parent group, with Recently opened/Recently added choices and paged records prepared only after selection. The compact network illustration uses real subject/collection parents. It no longer scans every relationship in a drawing callback.
- **Storage & Cleanup:** after explicit analysis, start with indexed-folder and verified-duplicate parent groups. Chart category aggregation is prepared once in the background; detailed file rows are not expanded by default. Open a group/folder and use a file context menu to review cleanup. Original Trash and managed-copy recovery still require the existing exact-file review/confirmation/grants. Duplicate groups themselves are paged, and their files remain behind another folder level. Native APFS allocation limitations remain.
- **Recently Deleted:** start with macOS Trash and Vault-managed recovery parents. Only the selected location’s current 60 records are rendered. Restore and permanent deletion semantics and confirmations are preserved. These are Vault-tracked records, not arbitrary Finder Trash contents.
- **Inspector:** subject/collection inspectors provide Browse folders actions instead of expanding every linked file. File memberships are populated only after expanding the membership group and are searchable/paged; related links load a bounded page with background name lookup only after expanding Related documents.

Knowledge Map retains its separate cached/paged graph implementation. Secure Vault records remain in their existing separate authenticated subsystem and are never passed into the ordinary catalog browser or thumbnail pipeline.

## Architecture and performance

`CatalogIndex` in VaultCore normalizes existing path metadata, determines source/parent roots, records month keys, and produces scoped pages. It uses only persisted metadata; it does not inspect new folders, request broader access, move files, change relationships, or index new content. Counts describe cataloged descendants (or explicit event/session records), not every file on disk. Parent groups with identical names use full IDs as sorting tie-breakers so paging remains deterministic.

`CatalogBrowserEngine` is an actor shared by LibraryStore. It caches a normal catalog index across file/media/subject/collection/timeline/notes navigation and keeps a small number of independent analysis datasets. Construction, filtering, grouping, sorting, and paging run away from the main UI executor. Lightweight published pages feed SwiftUI. Hover, selection, animations, and scan counters do not recompute all rows. New requests coalesce for 120 ms; leaving or superseding a view cancels preparation, and cancelled results cannot be published. A different folder shows a loading state rather than displaying the previous folder’s children; refreshing metadata for the same location keeps its current page usable.

Library graph/metadata revisions and relevant workspace changes invalidate the index. Scan counters, opened-file history, and graph positions do not. Subjects, sessions, source configuration, and extracted searchable text do. Existing unchanged folder synchronization does not change the library revision. The new catalog is an in-memory view index and does not create another database file.

`ThumbnailPipeline` runs at most four active Quick Look requests through a shared queue, requests cancellation when a card leaves, and resumes each waiting task once. The NSCache is configured for 128 images / an approximate 32 MiB cost limit; native cache limits are advisory. Cache keys use file identity in Vault, size, and modification timestamp. Only visible file cards or explicit inspector previews use this pipeline; parent cards have SF Symbols and counts. Native permission scopes remain tied to the request lifetime.

Existing JSON library/workspace persistence and original-file operations remain separate. Loading a catalog still requires O(indexed files) background metadata work and retains that metadata in memory. Sorting a very large opened leaf is background work, not an unbounded UI list. This change does not guarantee a frame rate, replace persistence with SQLite, or continue jobs after Vault quits.

## Validation

Eight domain regression methods cover 30,123-file parent/leaf behavior and last-file reachability, deep folder boundaries, mixed group/file page coverage, duplicate folder names, nested approved roots, media/text/favorite/size filtering, subject/collection membership and empty parents, timeline date/study separation, Notes source folders, and missing scopes. Four native integration methods cover shared-cache reuse/invalidation, cancellation without publishing children, independent storage datasets, and workspace revision behavior.

The cloud environment lacks Swift, Xcode, and a macOS SDK. Tests are written but unrun; grammar/project checks cannot validate framework APIs, Swift type checking, native Quick Look behavior, or performance on the affected Mac.

On macOS, build/test using README commands and use disposable indexed fixtures to check:

1. Enter every ordinary workspace with 30,000+ indexed files: parent/group cards should appear first, with no initial file thumbnail flood. Open a folder and confirm only its immediate children appear.
2. Open a large single folder, page through every item, switch folders rapidly, and use Back/Parents. Verify stable paging, no stale children, and cancellation. Search a file near the end of the catalog and follow its matching parent path.
3. Check media formats (including HEIC, MKV, and FLAC), filters/sorts/favorites, grid/list, Cmd-click selection across pages, and exact bulk metadata/index review. No original file should move or disappear.
4. Create/select a subject, link/unlink files across folders/pages, edit/save metadata, and record a study session. Check timeline parent/month/file timestamps and explicit session labels.
5. Browse a collection and Notes account/folder, open one note, and verify reader refresh/preview. Expand inspector memberships/related links only on demand.
6. Analyze storage, inspect parent folders and verified duplicate groups, and use context-menu cleanup actions with temporary files only. Validate exact original/managed-copy confirmations, native grants, restore conflicts, and paged recovery records.
7. In Instruments, compare CPU/memory/energy on page entry and verify there are no catalog-size SwiftUI child lists or thumbnail bursts. Switch away while thumbnails are queued and confirm native cancellation and scope cleanup. Exercise light/dark, Reduce Motion, keyboard, VoiceOver, and window resizing.

No native build, UI launch, destructive-operation execution, timing measurement, or performance improvement claim has been verified here.
