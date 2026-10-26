# Validation record

## Current instance

Linux, with no Swift compiler, Xcode, or macOS SDK. **No Swift compilation, XCTest execution, UI launch, authentication, signed sandbox permission test, destructive-operation runtime test, or CI execution has occurred.**

Static checks passed after the expanded implementation:

- Swift grammar parsing of all **29 Swift files**, using tree-sitter-swift. This does not perform type checking or validate native framework APIs.
- OpenStep parsing of `project.pbxproj` and resolution of declared object, product, package, configuration, and build-phase references.
- Exact membership of all **22 application/integration Swift sources** in project references, including new services and tests.
- Shared Xcode scheme XML and entitlement plist parsing.
- App Sandbox, user-selected read/write capability, and app-scoped bookmark configuration; no network client entitlement. Original index bookmarks explicitly request read-only access.
- `git diff --check` returned success. All source deliverables are untracked new files in the initially empty, unborn repository, so this is not a tracked-diff review.

Validation parsers were installed from PyPI into `/tmp` and are not app dependencies. The repository's own automated tests are **14 domain/package test methods and 9 macOS integration test methods**; all are currently **unrun**. Syntax parser checks are not substitutes for them.

## Required next validation

Execute the README's build, package-test, and Xcode-test commands on macOS. The pinned-action GitHub Actions workflow is written but has not run or been published/pushed. Test successful extraction, hashing, recovery, and encryption along with missing/corrupt data, overwrite refusal, original-file preservation, cancelled work, and failed authentication. Hostless tests do not validate signing, Finder Trash permissions, native prompts, or Touch ID.

Before real personal-data use, complete signed sandbox tests, VoiceOver/keyboard/appearance/resizing tests, source and Trash recovery failure tests, performance measurements, and independent security review. See Security.md for threat-model assumptions and known transaction/recovery limits. The source implementation spans phases 1–6 but Status.md lists remaining scope. No claim of complete feature coverage or production readiness is made.

This cloud instance supports source editing and static inspection. A macOS/Xcode host remains an external blocker for required native validation. Saving startup guidance does not publish configuration, execute CI, or prove restoration in a new task.

Spatial redesign: six additional domain tests cover camera inverse transforms, centering, fitting, zoom bounds, stable collision-free layout extension, and backward decoding of workspace metadata without optional presentation/history fields. They remain unrun. The updated project references/build phase include all new native views. See Design.md for the still-pending visual and interaction acceptance checks.
