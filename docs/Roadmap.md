> Original implementation roadmap. Work from later phases is now present; [Status.md](Status.md) is the current source of truth for implemented and outstanding scope. No phase is declared production complete.

# Incremental implementation and release gates

Phase 1 is a source implementation pending macOS compilation and runtime acceptance. It is not a production release. Keep each following phase independently testable and reviewable.

## Phase 1 hardening

Run the build, package tests, integration tests, and manual permission flow on macOS. Add UI automation for import confirmation, selection, inspector saves, filters, and keyboard navigation. Add import progress/cancellation with structured tasks, per-file errors and retry, bookmark renewal, managed source provenance, thumbnail cancellation/cache, multi-selection, drag/drop, type/date/size filters, collection rename/removal, and backup/export. Move repository IO off the main actor and migrate transactionally to SwiftData/SQLite before large-scale use. Test disk-full/save failure and orphan-copy reconciliation. Validate accessibility, VoiceOver, narrow windows, both appearances, and opening files from external volumes. Do not claim completion of these additions before they are implemented.

## Phase 2: visual intelligence

Persist subjects, tags, typed relationships, and user-authored notes with referential-integrity rules. Add local PDFKit/text extraction with format-specific support labels, bounded content indexing, and sensitive-content opt-in. Add a filtered, spatially indexed graph with pan/zoom, selection, explicit relationships, nonoverlapping labels, keyboard alternatives, and focus/expand. Timeline separates filesystem dates, Vault-added/opened events, and explicitly recorded study sessions. Tests cover migration, relationship deletion, query behavior, extraction failures, and graph selection on large fixtures.

## Phase 3: storage and safe deletion

Introduce a dedicated analysis actor and deletion service. Count stable file identities across overlapping roots; report logical indexed bytes, allocated bytes, managed bytes, and estimated recoverable bytes separately. Narrow duplicate candidates by size, then stream SHA-256 hashing with cancellation; verify current identity and metadata before acting. Exact duplicates remain distinct from similarity suggestions. Old-file filters only suggest review.

Deletion plans enumerate exact URLs, ownership, references, counts, and effects. Distinguish collection removal, index removal, managed-copy trashing, original trashing, and permanent deletion. Revalidate permissions, identities, symlinks, and concurrent changes after confirmation. Use macOS Trash by default. Only record successful operations; partial failures keep consistent metadata. Recently Deleted offers restore only while the actual recovery resource exists. Temporary-directory tests cover locked/missing files, races, protected paths, multiple references, failed trash, restore conflicts, and external permanent removal. No personal files in destructive tests.

## Phase 4: authorized monitoring

Add folder-selection onboarding and preflight counts, supported types, exclusions, duplicate candidates, and explicit sensitive-file controls. Persist security-scoped ScanLocation bookmarks and durable cancellable ImportJobs. Use supported filesystem event monitoring plus periodic reconciliation of authorized scopes; recognize identity changes and avoid unchanged reprocessing. Provide pause/resume/exclude/disconnect, stale-bookmark renewal, and clear permission revocation. Test nested folders, overlapping grants, event loss/coalescing, moves, removable volumes, cancellation, and restarts. A folder grant never expands to its parent.

## Phase 5: secure vault

Begin with a written threat model and independent security review. Store records separately from ordinary metadata, thumbnail caches, search, and diagnostics. Use CryptoKit authenticated encryption with random per-vault keys held behind appropriate Keychain access controls. LocalAuthentication unlocks access to key material; it is not an encryption substitute. Define enrollment, password fallback, KDF choice/parameters, recovery, key rotation, and backup behavior before implementation; do not invent a custom KDF or promise recovery without a recoverable key. Require authentication to expose sensitive content, lock on idle/sleep/session changes, clear in-memory plaintext as feasible, and clear copied secrets only if the clipboard still contains Vault's copied value. Test tampering, locked access, auth cancellation, no-Touch-ID fallback, clipboard ownership, idle locking, rotation, and recovery. Do not ship until dedicated review passes.

## Phase 6: advanced organization

Add local OCR, explicit study sessions, exam dates/reminders, editable classification suggestions, and a Needs Review collection. Optional remote AI must disclose destination, transmitted data, retention implications, and cost before opt-in. Keep it disabled by default and exclude secure records categorically. Benchmark search, scrolling, extraction, graph layout, and cancellation on representative libraries; record actual hardware, dataset, and latency instead of invented performance statistics.
