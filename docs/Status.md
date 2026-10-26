# Implementation status

This is an expanded development implementation spanning phases 1–6. It is **not a completed production release**. Native source has not yet been compiled or run; static parsers cannot check framework API compatibility or runtime correctness.

| Phase | Source functionality now present | Remaining scope / release work |
|---|---|---|
| 1 | SwiftUI shell, verified copies, scoped references, atomic metadata, native thumbnails, search, editable tags/descriptions, collections, favorites, drop import, multi-selection and bulk metadata/index removal, type/size/recent filters | Native build/UI validation; advanced date/tag filters, import configuration and first-run flow; asynchronous database persistence |
| 2 | Subjects and deadlines; persisted spatial graph positions; typed icon nodes, curved edges, short selection pulses, hover, pan/pinch/fit/focus/list modes; contextual file/subject/collection/link inspectors; real opened/added overview activity | Native interaction/accessibility and large-layout validation, projects/notes/tag nodes, recursive cluster expansion, advanced relationship filters, full activity events |
| 3 | Identity-aware logical/allocated analysis; cancellable streaming SHA-256 candidate groups; size/old filters; managed recovery; native original Trash and restore; permanent retained-copy deletion | Signed sandbox testing; bulk cleanup planning; APFS allocation/reclaim analysis, empty-folder analysis, resilient journal replay, concurrent replacement review |
| 4 | Explicit folder preview and approval; 30-second foreground polling, pause/resume, relative exclusions, disconnect; new/modified/moved reference refresh | Persistent job/retry state; filesystem events/reconciliation; explicit missing-file availability state; background operation when app closed; monitor limits and cancellation UX |
| 5 | Separate authenticated encrypted records, random device-bound Keychain key, OS authentication, lock triggers, clipboard ownership-aware timeout, record CRUD | Native Keychain/LA integration tests, independent review, configurable timeouts, portable recovery/export/key rotation, optional encrypted attachments |
| 6 | Opt-in local PDF/UTF-8 text extraction and image OCR; extracted-text search; reviewable frequency-based tag suggestions and description excerpts; explicit study sessions | Document-summary quality, OCR bounds for hostile images, richer search and review workflows, performance benchmarks. Remote AI intentionally absent and optional. |

No external cloud service or API key is required. No mock files/statistics are injected. Local excerpts and word-frequency tags are labeled as such rather than represented as AI-generated summaries. An image OCR request is explicit. Automatic monitoring never extracts contents.

The next decisive step is execution on macOS. The new GitHub Actions workflow can run unsigned builds, package tests, and filesystem/encryption tests after the changes are committed and pushed by the user. It does not replace signed sandbox, permission, visual/accessibility, or authentication testing, and it has not run from this chat. No publish, remote push, or release has been performed.
