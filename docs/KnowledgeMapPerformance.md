# Knowledge Map: large-library loading

The reported first-open stall occurred with 30,000+ files. The debugger screenshot shows `KnowledgeMap.nodeActions` executing `files.first(where:)` while SwiftUI constructs node context menus. `SIGTERM` indicates termination; the screenshot alone does not establish a memory crash or a specific termination cause.

The previous 150-node drawing budget was applied too late: view properties repeatedly constructed every node and every membership edge, scanned adjacency, sorted the entire catalog, and performed per-node linear FileItem lookups. Hover, selection, camera, footer, and Canvas rendering could trigger these properties again. Initial position seeding also synchronously wrote the full workspace JSON, including unrelated metadata. These are source-level performance problems independent of the termination signal.

## Current implementation

- **Background graph index.** KnowledgeGraphIndex builds node lookup and adjacency once per graph revision in KnowledgeGraphEngine, an actor isolated from the UI executor. It uses linear source-order interleaving of files/subjects/collections instead of sorting all files on first opening. Only graph metadata is used; no files, thumbnails, text extraction, or previews are accessed.
- **Small published snapshot.** Background queries produce up to 150 nodes and 900 visible-endpoint edges. SwiftUI/Canvas read this cached snapshot; animation, pan, zoom, and hover do not rebuild the graph or traverse the full catalog. Neighborhood highlighting examines only snapshot edges.
- **Full-catalog navigation.** Search filters every indexed node in the background. Previous/Next controls page through every match, including Focus results; the selected node and direct connections receive priority. These are display budgets, not file scan/index quotas. The footer reports visible/matching/total counts and flags truncated edge detail. The relationship picker also uses a searchable 50-row shortlist instead of creating thousands of menu entries.
- **Cached across navigation.** WorkspaceView retains KnowledgeMapModel. Returning to Knowledge Map reuses its index. Library changes and subject/relationship edits invalidate it; scan counter checkpoints, open-history events, camera, hover, and legacy position updates do not. An unchanged synchronization refresh does not invalidate the index. Query changes are coalesced for 120 ms. Leaving the view or superseding its request cancels its preparation; cancelled work cannot publish a stale result.
- **Action-time file lookup.** Node context menus depend on GraphNode metadata and closures. They look up the current FileItem only when a user actually invokes Open, Reveal, or Favorite. They do not capture copies of FileItem for every rendered menu.
- **Bounded layout and separate persistence.** Layout collision checks receive only the current visible positions, never the whole saved layout. Existing visible positions are reused during selection updates. Camera fitting runs on initial display/visible-set changes or explicit Fit, rather than writing state back to the workspace during seeding. First opening, filtering, selecting, and paging do not save the workspace. Explicit node drags persist coordinates atomically in `graph-layout.json` on the background actor. Old workspace graphPositions remain readable as the migration fallback; no existing metadata is deleted.
- **Loading/error states.** A first-load indicator appears while preparing; navigation remains available. Later refreshes keep the previous scene visible with a small activity indicator. An unreadable saved layout reports an error rather than silently overwriting it. No custom layout is deleted to repair the map.

## Boundaries and remaining costs

Index construction is O(nodes + relationships + memberships) and keeps that metadata in memory. Queries still perform a background node filter and adjacency traversal; they do not load an unbounded UI or run a force simulation. Very dense graphs can still have large index memory requirements. The 900-edge detail budget applies to the current display, and saved relationships are preserved.

The existing JSON library/workspace stores still have synchronous persistence and separate large-library costs during scanning and metadata changes. This patch removes full-workspace saves triggered by graph opening/layout; it does not replace those stores with SQLite or guarantee a frame rate/latency on a particular Mac. Existing imported text, images, and bookmarks are untouched. The new layout document is ordinary local metadata outside Secure Vault.

## Validation

Five domain test methods include a 30,123-file fixture with subject/collection memberships, bounded node/edge projections, last-file search, complete paging coverage, Focus/layer behavior, dense-edge truncation, missing/self-edge exclusion, and a cached-projection XCTest performance measurement. Four native test methods cover index reuse/invalidation, zero workspace writes on opening, a 30,100-coordinate legacy layout, node-drag restart persistence, cancellation/retry, and graph revision behavior during scan checkpoints/open history.

These tests are written but unrun in the Linux cloud workspace, which lacks Swift, Xcode, and the macOS SDK. No timings, memory savings, frame rates, or native test successes are claimed.

On macOS:

1. Run the README build, package-test, and native-test commands. Preserve the existing library and signing settings.
2. Open a disposable library with 30,000+ files. Confirm the preparation indicator appears and navigation remains usable. Return to the map and check index reuse. In Instruments Time Profiler, context-menu construction must no longer call a catalog-wide `first(where:)`; Canvas rendering must not build allNodes or membership arrays.
3. Pan/zoom/hover/select without sustained catalog-size CPU work. Verify selecting an already-visible node preserves the camera, and Focus/query/page changes fit the new visible set.
4. Search a file near the end of the catalog, page through matches, change layers, and focus a high-degree subject. Confirm visible and total counts are distinct, pages reach the complete matching set, and edges never point to absent nodes.
5. Open context menus and invoke real Open/Reveal/Favorite actions. Search the relationship picker, create a link, and confirm the map refreshes. Remove a selected fixture from the index and check graceful refresh.
6. Open the map while a large scan is minimized, type rapidly, switch away mid-prepare, and return. Verify cancellation prevents stale publication. Scan checkpoints alone must not rebuild the index.
7. Check that opening the map does not change workspace.json. Drag a node, quit/reopen, and verify graph-layout.json restores the position without modifying original files. Preserve both metadata documents if investigating an error.
8. Profile first open/reopen, CPU, allocation growth, and scrolling/panning on the affected Mac. Check the console for repeated-update warnings and test VoiceOver, Reduce Motion, and light/dark appearance. Actual macOS acceptance remains pending.
