# Shared Docs / Media / Photos filter

The header of each file workspace now contains **All Types / Docs / Media / Photos**. It becomes a native menu when there is insufficient width for the segmented control. The selection uses AppStorage and persists across tabs, folder navigation, windows, and launches. Recent activity also exposes the same control in its sheet.

- **Docs:** PDF, text/Markdown/RTF, Word/Pages, presentations, spreadsheets, CSV/JSON and other classified data documents.
- **Media:** audio and video, including MP3, FLAC, MOV, MP4, and MKV.
- **Photos:** photos, images, diagrams, and graphics, including HEIC, PNG, JPEG, GIF, SVG, and supported raw-image extensions.
- **All Types:** restores the complete indexed scope, including archives and unclassified files. Classification does not imply that every format can be previewed or have its text extracted.

## Scope

The filter applies to Overview folder browsing and recent activity, All Files, Images & Media, Subjects, Collections, Timeline file events, Notes snapshots, Knowledge Map, Storage & Cleanup, Recently Deleted, and related-file lists. The Images & Media tab retains its image/audio/video scope: Docs will have no matches there. Notes remain scoped to imported snapshots; selecting Photos does not expose attachments that were never imported.

Parent folders and virtual group counts are computed from matching descendants. Typed Subject/Collection roots omit groups without matching files; All Types retains empty groups. File membership editors still offer all metadata destinations so users can assign a file to an empty subject/collection. The Overview has navigation parents for Subjects/Collections instead of unfiltered file counts in preview cards. The graph retains matching files and their connected subject/collection parents, with visible-endpoint edges only. An explicitly selected/origin document can remain as navigation context outside the filter, with an explanatory footer.

Timeline study records are explicitly authored events without a file type. They appear under All Types and are not represented as matching Photos/Media/Docs. Already-open single-file readers/previews are explicit contexts, not reclassified file lists. Secure Vault credentials and Settings are separate from file workspaces and do not display a file-type selector.

Changing the choice resets page numbers and clears the main workspace’s file selection/inspector, avoiding bulk actions on a previous category’s hidden selection. Parent navigation remains intact. Empty folder results show the selected type and provide Show All Types. Scope filters such as collection, subject, keyword, size, favorites, and dates still combine with the type choice.

The new named Overview widgets have independent categories (My Documents, My Photos, and My Media) and bounded 3/6-item previews. Their View All actions enter the existing browser with the corresponding filter. This is stated above the widget grid; ordinary Overview parent-folder browsing still follows the global selection. At a Glance is a single-document context; Connected Documents candidates follow the global filter. See ConnectedExplorerDashboard.md.

## Performance and storage semantics

The common catalog filters cached category values before counting groups and slicing pages; it does not rebuild its index just because the type changes. Graph filtering runs on the existing graph actor. Recent activity, recovery filtering, and storage aggregation execute in background tasks with cancellation, while existing 60-row / graph drawing budgets remain in force. Filtering does not materialize the entire library as SwiftUI views or request offscreen thumbnails.

Storage totals/charts/folder counts reflect matching analyzed files. The unavailable count is explicitly labeled as belonging to the full analysis because the report may not retain the types of inaccessible entries. Analysis still covers the indexed library; the selector changes displayed results. A verified duplicate group can display one matching member when other copies have different file types. The UI explains that All Types reveals all copies; it does not delete hidden members or change verified hashes. Filtered storage snapshots receive new cache revisions so switching categories cannot reuse an index made from another category’s subset.

Recovery counts and pages apply the same classification to tracked Trash/recovery records. The original grant, confirmation, restore, and deletion workflows remain unchanged. No original files are opened or modified by choosing a filter. Approved scan categories, monitoring configuration, and scan quotas are unaffected; scanning remains unlimited.

## Validation

Seven domain regression methods cover document formats, uppercase/dotted extensions, media/photo separation, archives/unknown types under All Types, filtering before folder counts and page slicing, restoring all types, scoped subject/collection counts, typed timeline events and study exclusion, Notes scope, and graph parent/edge consistency. The existing native shared-cache test now switches categories and asserts the same index is reused.

All tests remain unrun in this Linux environment, which lacks Swift and Xcode. Static syntax/project checks cannot establish native compilation or runtime correctness.

On macOS, build/test using README commands, then check a mixed-format disposable library:

1. Switch the four choices in each file workspace and drill through parents. Verify accurate matching counts, retained paths, reset paging/selection, and complete access via All Types.
2. Check Docs includes PDFs/presentations/spreadsheets, Media excludes still images, and Photos includes HEIC/PNG/SVG. Combine with search/favorites/size/date filters and test an empty result’s reset action.
3. Verify the choice persists when navigating, reopening the app, and opening recent activity. Resize to test segmented/menu fallback and keyboard/VoiceOver operation.
4. Check subject/collection parents, Notes account/folder scope, typed timeline months, study visibility under All Types, and graph parent/edge behavior.
5. Run storage analysis and switch types repeatedly while browsing. Confirm charts/totals and duplicate member counts match, clearing the filter restores all results, and no stale subset is used. Test filtered recovery counts/pages with temporary records and preserve all destructive confirmations.
6. Rapidly switch categories during scanning and background preparation; check responsiveness, cancellation, and the existing child/thumbnail limits with a large library. Native performance and signed permission validation remain pending.
