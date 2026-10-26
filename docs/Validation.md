# Validation record

## Current instance

Linux, with no Swift compiler, Xcode, or macOS SDK. **No Swift compilation, XCTest execution, UI launch, authentication, signed sandbox permission test, destructive-operation runtime test, or CI execution has occurred.**

Static checks passed after the expanded implementation:

- Swift grammar parsing of all **34 Swift files**, using tree-sitter-swift. This does not perform type checking or validate native framework APIs.
- OpenStep parsing of `project.pbxproj` and resolution of declared object, product, package, configuration, and build-phase references.
- Exact membership of all **25 application/integration Swift sources** in project references, including new services and tests.
- Shared Xcode scheme XML and entitlement plist parsing.
- App Sandbox, user-selected read/write capability, and app-scoped bookmark configuration; no network client entitlement. Original index bookmarks explicitly request read-only access.
- `git diff --check` returned success. All source deliverables are untracked new files in the initially empty, unborn repository, so this is not a tracked-diff review.

Validation parsers were installed from PyPI into `/tmp` and are not app dependencies. The repository's own automated tests are **24 domain/package test methods and 23 macOS integration test methods**; all are currently **unrun**. Syntax parser checks are not substitutes for them.

## Required next validation

Execute the README's build, package-test, and Xcode-test commands on macOS. The pinned-action GitHub Actions workflow is written but has not run or been published/pushed. Test successful extraction, hashing, recovery, and encryption along with missing/corrupt data, overwrite refusal, original-file preservation, cancelled work, and failed authentication. Hostless tests do not validate signing, Finder Trash permissions, native prompts, or Touch ID.

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
