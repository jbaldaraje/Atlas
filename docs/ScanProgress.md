# Scan progress and background navigation

Start a scan from Overview or the sidebar as before. **Minimize** closes the scan sheet and leaves a compact glass status bar at the bottom of the window. Navigation, search, previews, and file inspection remain available. **Expand** or the header's scan button reopens the same job; it never starts a second scan. **Cancel** works from either presentation and reports cancellation while the current operation unwinds. Completed catalog entries and originals are preserved.

When minimized work finishes, the status bar offers **View Results** and a dismiss control. It does not force the modal back open or change the selected workspace. Keep Vault open: this is an application-owned task, not a system background daemon. Quitting does not continue scanning; persisted running jobs become interrupted on the next launch and can be retried using the existing identity-aware merge.

## Percentage semantics

A cancellable initial pass counts regular files matching the approved sources, exclusions, and selected file categories. It uses the same bounded cursor as processing; candidate URLs are discarded after each chunk. Counting has an indeterminate bar and real counts, because the total is not yet known. There is still no file-count quota.

After counting, the UI shows **Estimated overall progress**, a loading bar, and both completed and remaining percentages. Index attempts and organization account for 95% of the work estimate, with equal weights per file for these two steps. Catalog metadata checks for possible duplicate groups account for the final 5%. The value stays below 100% until the job completes. A completed scan with errors is labeled for review; reaching 100% means the workflow finished, not that every entry succeeded. Unavailable entries, unchanged entries, and repeated references count as resolved work, separately from successful additions.

Counts reflect references traversed, so overlapping approved folders may contribute work twice while still producing only one catalog item. If files appear or disappear between passes, the denominator adjusts. Progress may change accordingly. This is a measured workload estimate, not a time estimate: PDF extraction, network volumes, and file types have different costs. Counting adds an extra directory traversal, while memory buffering remains bounded. The existing catalog/JSON persistence costs remain.

The modal, compact bar, header, and sidebar mascot share one scan job. Optional progress fields preserve decoding of older jobs. Progress/counters are saved at existing checkpoints; the animation never drives them.

## Appearance and accessibility

The scan sheet uses the existing cinematic lighting and glass materials, a locally drawn orbit/radar, and a native progress bar. The compact bar reuses a smaller radar. Decorative motion pauses for Reduce Motion, disabled Cinematic animations, increased contrast, inactive windows, and inactive scenes. The illustration is hidden from accessibility; the native bar exposes completed and remaining percentages. Reduce Transparency uses the existing opaque surface fallback. No remote assets, uploads, extra permissions, or secrets are involved.

## Changed boundaries

- `VaultCore/Organization.swift`: counting stage, serializable work counters, tested fraction/percentage calculations, shared stage titles.
- `FolderScanCoordinator.swift`: counting pass, actual index/organization/review updates, minimize/expand/cancel lifecycle. The task remains owned by WorkspaceStore.
- `AnalysisService.swift`: optional throttled metadata-check progress callback; existing storage callers keep the default behavior.
- `ScanProgressView.swift`: shared meter, decorative radar, and persistent status bar.
- `FolderScanReview.swift`, `WorkspaceView.swift`, `WorkspaceStore.swift`: presentation and activity wiring, preserving navigation and preventing a concurrent drag import during a scan.
- `VaultActivity.swift`, `VaultMascot.swift`: measured percentage in existing sidebar activity.

## Validation and macOS acceptance

Four domain tests cover unknown totals, phase weights, finalization, stopped states, empty/changed totals, serialization, and legacy decoding. Four native test methods cover minimize/expand without restarting, completion without reopening, cancellation/retry, empty sources, and mascot progress; the existing multi-chunk regression now asserts measured totals and saved completion. Tests use disposable fixtures. They are written, not executed in this Linux environment.

On macOS, build and run the README test commands, then:

1. Scan a disposable mixed-format tree with PDFs/Documents selected. Counting should show no invented percentage; after counting, only matching files should form the denominator. Check 0–99% during processing/final review and 100% at completion.
2. Minimize during counting, indexing, and organization. Browse all workspaces, search, open a preview, and expand again. The same job/counters must continue; import actions remain unavailable during scanning.
3. Leave the job minimized until it completes. Confirm navigation stays where you left it, the modal stays closed, and View Results shows the correct additions/errors. Dismiss the status bar.
4. Cancel in either presentation, including during the initial count and duplicate review. Confirm status settles, originals remain intact, committed entries remain, and retry creates a new job without duplicate catalog items.
5. Scan an empty folder, overlapping folders, and a source with permission failures. Modify/add/remove fixtures between passes. Check the adjusted estimate and actionable results.
6. Exercise a large multi-chunk tree, light/dark appearance, window/inspector resizing, VoiceOver, Reduce Motion, Reduce Transparency, increased contrast, inactive windows, and disabled Cinematic animations. Confirm animation pauses without pausing the job. Quit/relaunch mid-job and verify interrupted/retry behavior.

No macOS compilation, native execution, or rendered UI validation occurred in this cloud task.
