# Validation record

## Current instance

Linux, with no Swift compiler, Xcode, or macOS SDK. **No Swift compilation, XCTest execution, UI launch, authentication, signed sandbox permission test, destructive-operation runtime test, or CI execution has occurred.**

Static checks passed after the expanded implementation:

- Swift grammar parsing of all **70 Swift files**, using tree-sitter-swift. This does not perform type checking or validate native framework APIs.
- OpenStep parsing of `project.pbxproj` and resolution of declared object, product, package, configuration, and build-phase references.
- Exact membership of all **46 application Swift sources**, **10 core sources**, and **22 native integration source memberships** in project references, including new services and tests.
- Shared Xcode scheme XML and entitlement plist parsing.
- App Sandbox, user-selected read/write capability, and app-scoped bookmark configuration; no network client entitlement. Original index bookmarks explicitly request read-only access.
- `git diff --check` returned success.

Validation parsers were installed from PyPI into `/tmp` and are not app dependencies. The repository's own automated tests are **69 domain/package test methods and 52 macOS integration test methods**; all are currently **unrun**. Syntax parser checks are not substitutes for them.

## Required next validation

Execute the README's build, package-test, and Xcode-test commands on macOS. The pinned-action GitHub Actions workflow is written but is present in the repository; no CI result is asserted from this environment. Test successful extraction, hashing, recovery, and encryption along with missing/corrupt data, overwrite refusal, original-file preservation, cancelled work, and failed authentication. Hostless tests do not validate signing, Finder Trash permissions, native prompts, or Touch ID.

Before real personal-data use, complete signed sandbox tests, VoiceOver/keyboard/appearance/resizing tests, source and Trash recovery failure tests, performance measurements, and independent security review. See Security.md for threat-model assumptions and known transaction/recovery limits. The source implementation spans phases 1–6 but Status.md lists remaining scope. No claim of complete feature coverage or production readiness is made.

This cloud instance supports source editing and static inspection. A macOS/Xcode host remains an external blocker for required native validation. Saving startup guidance does not publish configuration, execute CI, or prove restoration in a new task.

Spatial redesign: six additional domain tests cover camera inverse transforms, centering, fitting, zoom bounds, stable collision-free layout extension, and backward decoding of workspace metadata without optional presentation/history fields. They remain unrun. The updated project references/build phase include all new native views. See Design.md for the still-pending visual and interaction acceptance checks.

## VaultCore module build configuration correction

A local macOS build reported `Unable to find module dependency: VaultCore`. The app/test dependency has been changed from local Swift-package product resolution to an explicit native static-framework target named VaultCore. It compiles the same three core source files, defines the module, and is linked by both consumers through explicit target dependencies. The standalone package remains unchanged for `swift test`.

Project inspection passed: all references resolve, all three core sources belong to the target, both Debug/Release configurations define a static module, and both consumers depend on and link the resulting framework. This verifies project structure, not a native build; macOS/Xcode are still unavailable here. Access to GitHub Actions logs through the GitHub API was denied, so no CI outcome is asserted.

## WorkspaceView type-checking decomposition

A macOS compiler reported a type-checking timeout at WorkspaceView.body. The single expression previously combined navigation, conditional workspaces, inspector, toolbar, observers, drop handling, multiple alerts, sheets, and confirmation dialogs. These now have separate opaque-view boundaries, a typed workspace switch, explicit Boolean bindings, and ordinary action handlers. The nested library grid, row menus, and empty state are also checked independently. Selection and file-operation semantics remain the same. Syntax parsing passes for all 29 Swift files; the macOS compiler timeout fix has not been verified with Xcode in this Linux instance.

## Scan file-category filtering

Folder review now offers multi-select Documents, PDFs, Images, Media, and Other, plus All Types/None controls. Counts, matching logical bytes, and candidate rows update with the selection. Saved locations persist optional category sets, with missing fields defaulting to all types for older metadata. Category filtering applies to future polling as well as initial indexing; stale scan results are rejected when the saved category set changes before synchronization. Previously indexed files are preserved.

Added three domain tests for classification (including uppercase extensions, PDF/document separation, audio/video, and unknown/extensionless types), legacy metadata decoding, and category-set persistence including explicit none. Added a native scanner integration test for category selection, all/none behavior, hidden files, and symlink exclusion using disposable fixtures. These tests are written but remain unrun because Swift/Xcode are unavailable here. The folder enumerator is now in FileAccessService so its actual filesystem behavior can be tested by the existing native target.

Manual acceptance on macOS: approve a disposable folder containing mixed formats; select PDFs plus Documents and confirm only those rows/counts/bytes remain; approve and verify the library. Add matching and nonmatching files and observe polling. Restart and verify saved category choices. Change File Types to Images and confirm new images are added, new nonimages are skipped, and existing documents remain. Verify All Types, no selected types (confirmation disabled), no matches (future monitoring allowed), and cancelled review.

## Secure Vault authentication focus repair

The reported system authentication prompt closing matches a source-level race: the application-deactivation observer called lock() even while the vault was locked and awaiting authentication, invalidating the LAContext used by the prompt. Deactivation now cancels/clears an unlocked vault as before, but does not cancel a locked authentication attempt. Unlock waits briefly for foreground activation, checking cancellation and its generation token, before acquiring a key and again before publishing records. Explicit lock, sleep, session resignation, and navigation remain unconditional cancellation paths. The UI provides Cancel Unlock. Error messages now distinguish LocalAuthentication cancellation/interruption, signing/Keychain status, missing key, and unreadable/authentication-failed record data. No record or key is deleted/reset as a repair.

Key access now requests the macOS data-protection Keychain for new user-presence-protected keys, with a legacy lookup fallback for existing keys. The app never creates a replacement when ciphertext exists without an accessible key. These native API changes require signed macOS runtime validation.

Six injected-dependency tests were added against SecureStore's actual async unlock flow, without a real Keychain/biometric prompt: authentication focus loss, explicit lock before authentication completes, missing-key ciphertext preservation, wrong-key ciphertext preservation, user cancellation, and inactive-app refusal. Static syntax/project checks pass; the tests and real Touch ID/password fallback remain unrun on this Linux host. On macOS, test first enrollment, existing legacy records, repeated unlocks, the system dialog taking focus, cancellation, switching apps while unlocked, sleep during authentication, and navigation during authentication. Verify no records appear while Vault is inactive.

## Incremental smart scanning and graph organization

See SmartScanning.md for integration, file inventory, limits, and macOS acceptance. Static syntax parsing passes for 34 Swift files; all Xcode references resolve and every app/core source belongs to its native target without duplicate compilation. The existing graph renderer is unchanged. Actual build/test attempts returned exit 127 (`swift: command not found`, `xcodebuild: command not found`). No native tests or application runtime ran. Test sources now total 44 methods: 24 package and 20 native, including real EXIF fixtures and complete catalog/organization/rescan/cancellation tests. These counts describe source methods only, not passing outcomes.

## Removal of the local scan cap

Removed the 10,000-file guard and its error, as requested after a real local scan hit it. Replaced production whole-source discovery with a bounded actor cursor used by both manual scanning and polling. Each chunk is indexed and organized before requesting the next; progress/checkpoints accumulate and scopes close on success, cancellation, or errors. UI and current scanning documentation no longer advertise a source-file quota.

Added native regression sources for 10,003-file discovery with bounded chunks; idempotent cursor closing that preserves originals; and a full multi-chunk scan with a persisted catalog containing every file. The repository now contains 47 test methods (24 package, 23 native), all unrun here. Static syntax, project-reference, and whitespace checks pass. Swift/Xcode remain unavailable on Linux, so the removal and batching behavior still need native compilation/execution. Existing JSON persistence remains an independent large-library performance limitation rather than an imposed scan-count limit.

## 3D mascot, glass surfaces, and live activity

Added a native SceneKit character and data-only public activity resolver, with shared glass controls/panels and accessibility-aware motion preferences. See MascotGlass.md for changed files and runtime acceptance. Five meaningful status tests are added; the current total is 52 source test methods (24 package, 28 native), all unrun here. Static syntax checks pass for 36 Swift files, and the Xcode target/source references include both new files. This Linux environment cannot compile or render SwiftUI/SceneKit, so appearance, interaction, signing, authentication, and GPU/energy behavior remain unverified. No screenshot or render is presented as a running application.

## Apple Notes / iCloud snapshot integration

Added a read-only user-initiated Apple Notes Automation bridge, account/folder/note selection, local plain-text snapshots with stable source identity/manual refresh, a Notes reader, and exported-file fallback. See AppleNotes.md for permissions, limits, changed/new files, and the signed macOS acceptance checklist. The sandbox exception is scoped to com.apple.Notes; both app build configurations include NSAppleEventsUsageDescription. No network entitlement or private database access is added.

Static Swift syntax parsing and native project/reference membership checks pass for 42 files. Test sources total 59 methods (28 package and 31 native). Seven additional tests cover source identity, source collections, filenames, legacy decoding, snapshot refresh/restart, user edits/sibling preservation, and safe error messages. Tests remain unrun. Real Notes scripting/permission behavior and the native reader require macOS; no actual note was accessed from this cloud task.

## Scan progress, cinematic effects, and minimization

Added an initial bounded counting pass, optional persisted work counters, estimated overall completed/remaining percentages, and progress updates for indexing, organization, and final catalog review. Added a shared progress meter/radar, minimize/expand controls, and a persistent status bar that retains results without reopening the sheet. The mascot shares measured progress. Counting remains indeterminate until the total is known; estimates reserve finalization and do not claim 100% for stopped jobs. See ScanProgress.md for weighting, lifecycle, limitations, and manual acceptance.

Four domain and four native regression methods were added, with measured totals also asserted in the existing multi-chunk test. The source now contains 67 test methods (32 package, 35 native). Swift grammar checks pass for all 43 Swift files; project references and exact source memberships, scheme XML, entitlement plist, and whitespace checks pass. Swift/Xcode remain unavailable, so native build, tests, appearance, accessibility, and actual navigation-while-scanning behavior remain unverified.

## Large Knowledge Map first-open optimization

The supplied debugger screenshot stopped in per-node context-menu construction at a linear catalog lookup, with SIGTERM and a repeated-update warning. Source inspection also found catalog-wide node/edge generation and sorting in computed render properties, plus synchronous full-workspace persistence during initial layout. Replaced these with an actor-backed revision cache, background bounded projections, full-catalog search/paging, action-time file lookup, and a separately persisted background layout. Camera/hover/animation operate on a small snapshot; opening the map does not save workspace metadata. See KnowledgeMapPerformance.md for scope, remaining costs, and native acceptance.

Five domain and four native test methods were added, including 30,123-file graph and 30,100-coordinate layout fixtures, bounded/dense projections, search, full paging, Focus/layers, an XCTest performance measurement, index reuse, no workspace write on first load, cancellation, and node-position persistence. Current total: 76 source test methods (37 package, 39 native), all unrun here. Static syntax passes for 46 Swift files; project references, source membership, entitlement plist, scheme XML, and whitespace checks pass. Native compilation, runtime profiling, timings, memory/energy changes, the repeated-update warning, and actual large-library first-open behavior remain unverified because Swift/Xcode/macOS are unavailable.

## Knowledge Map native compiler diagnostic correction

A user macOS build reported two ambiguous Subject annotations in KnowledgeMapModel.swift, assignment to the immutable catch error, and related ObservedObject/Binding diagnostics in KnowledgeMap. The new model imports Combine, whose Subject protocol conflicts with VaultCore.Subject. Both signatures now explicitly name VaultCore.Subject. The node-position catch handler now assigns self.error instead of the caught Error value. The view diagnostics are consistent with cascading type-check failures from the invalid model signatures; no binding workaround was added.

Swift grammar and project/source-reference checks pass after the correction. Native compilation remains unverified here: this Linux environment has no Swift compiler or Xcode. Rebuild with the Vault scheme on macOS to verify that all reported diagnostics clear.

## Parent-first pages and deferred child rendering

Replaced full-catalog render-time file sorting, subject-wide file toggles, and eager timeline rows with a shared actor-backed metadata browser. Ordinary workspaces show parent folders/groups first and at most 60 immediate children per page; search/filter counts are computed in the background and all matches remain reachable. Added source-aware roots, collection/subject navigation, event/month timeline grouping, Notes account/folder grouping, overview parent folders, storage/recovery parents, conditional/paged inspector editors, and queued/cancellable thumbnails. See FolderBrowsing.md for scope and native acceptance. No scan or indexing quota, additional folder permission, or automatic file operation was added.

Eight package and four native regression methods were added. Current source total: 88 methods (45 package, 43 native), all unrun. Fixtures include 30,123 catalog entries, deep and overlapping path boundaries, mixed pagination, duplicate folder names, media and text filters, virtual memberships, timeline date/study separation, Notes grouping, shared cache reuse, dataset isolation, revision invalidation, and cancellation. Static grammar checks pass for 54 Swift files, with project reference/membership, scheme/entitlement syntax, and whitespace checks. No Swift compiler/Xcode/macOS SDK is available; actual native compilation, Quick Look queue/cancellation, security-scope cleanup, UI performance, accessibility, and deletion/recovery runtime acceptance remain unverified.

## Shared file-type filtering

Added a persistent native All Types / Docs / Media / Photos selector to file workspace headers and recent activity. A common VaultCore classification filters before folder/group counts and paging, with graph parent relevance, typed timeline events, Notes scope, and background storage/recovery filtering. Scanning/monitoring categories are unchanged. Typed storage projections receive distinct cache revisions, and changes clear previous category selections. See FileTypeFilters.md for scope, limitations, and acceptance.

Seven domain tests were added and the native catalog-cache test now verifies category changes reuse the index. Current source total is 95 methods (52 package, 43 native), all unrun. Static Swift grammar checks pass for 57 files, with native project references/source membership, scheme XML, entitlement plist, and whitespace checks. Swift/Xcode/macOS remain unavailable here; AppStorage persistence, native compilation, picker resizing/accessibility, storage/recovery totals, cancellation, and UI performance require validation on macOS.

## Connected explorer and customizable dashboard

Added 17 package and 9 native regression methods for source-grounded context, explainable/dismissible connection evidence, shared graph caching and actual path edges, bounded large-library projections, history, real activity, widget configuration/storage scopes, atomic preferences/corruption preservation, current-record editing, and UTF-8 note excerpts. Current total: 121 source methods (69 package, 52 native), all unrun. See ConnectedExplorerDashboard.md for changed files and detailed manual acceptance.

Both attempted native commands returned exit 127: `swift test --package-path Packages/VaultCore` reported `swift: command not found`; `xcodebuild -project Vault.xcodeproj -scheme Vault -destination 'platform=macOS' test` reported `xcodebuild: command not found`. Swift grammar checks pass for 70 files; project/source membership checks cover 46 app, 10 core and 22 native test-target sources. Scheme/entitlement parsing and `git diff --check` pass. These checks do not establish Swift type correctness, successful compilation, PDFKit/Quick Look runtime correctness, signed sandbox behavior, or measured performance. Native acceptance remains pending.

## Preferences initializer compiler correction

A reported macOS build found an unqualified `error =` assignment inside the preferences initializer's `catch` block. Swift resolves that name to the immutable caught `Error`, causing both diagnostics in the screenshot. The assignment now explicitly targets `self.error`, the store's optional message property. Nearby model catch handlers already qualify their assignments. The corrupt-preferences preservation behavior is unchanged and is covered by an existing native regression test, which remains unrun here. Swift grammar parsing of all 70 files, project source-membership checks, and `git diff --check` pass. Swift and Xcode remain unavailable; native compilation must be verified on macOS.
