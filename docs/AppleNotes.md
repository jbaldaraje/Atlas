# iCloud / Apple Notes in Vault

## How to use it

1. Enable iCloud Notes through macOS and open Apple's Notes app. Wait until the notes you want are available on this Mac.
2. In Vault choose **Notes → Add iCloud / Apple Notes**, or **Add Notes** on Overview.
3. Read the explanation, click **Connect to Apple Notes**, and allow the macOS Automation prompt. Select the account named iCloud (or another explicitly chosen local Notes account), then a folder.
4. Select individual unlocked notes or Select All Unlocked. Decide whether to index their plaintext for search. Click Import Selected.
5. Read snapshots in the Notes workspace. They also appear in All Files and an Apple Notes account collection, so tags, favorites, subjects, collections, inspector, and the graph remain available.
6. Select a note and click Refresh from Notes to update the local snapshot. This is a manual refresh, not live or bidirectional synchronization.

If permission is denied, allow Vault under **System Settings → Privacy & Security → Automation → Notes**, then reconnect. Keep the same app identity/signing configuration. If a source note moved, reconnect and import it from its current folder: its account/note identity keeps the existing catalog ID and user metadata. If it was deleted or is unavailable, the local snapshot stays intact.

## Permission and privacy boundary

Vault reads the installed Notes app through its AppleScript interface. It does not authenticate directly to iCloud, request your Apple ID password, scrape iCloud.com, access private Notes database files, or pretend that its own CloudKit container can access Apple's Notes records. iCloud availability and syncing remain the responsibility of Apple's Notes app and your macOS account.

The app requests Automation capability and a sandbox Apple-events exception for **com.apple.Notes only**, plus an explanatory NSAppleEventsUsageDescription in both build configurations. The system prompt says “control”; the bundled script only reads accounts, folders, titles, protected status, plaintext, and available source dates. No create/update/delete command modifies Notes. Account/folder/note IDs are typed Apple-event parameters; no Notes content is interpolated into script source. No new network or full-disk-access entitlement is added.

Locked/password-protected notes are excluded even if they were previously unlocked in Apple Notes. If protected status cannot be determined, the note is excluded conservatively. Vault never supplies a password or invokes an unlock operation. Importing a local snapshot does not inherit Apple's original note encryption: a previously imported snapshot remains readable if the original is locked later. Sensitive notes should not be imported into the ordinary library. Secure Vault remains a separate system.

## Snapshot behavior and safety

Only plain text is imported by Automation. Tables/checklists may flatten into text; formatting, images, drawings, scans, and other attachments are not imported. Text extraction/search is explicitly optional and stored in the existing regular-library plaintext index. These snapshots are not encrypted Secure Vault records.

The existing FileItem gets optional source provenance, preserving older metadata. Account ID plus note ID identifies an imported note even after its title/folder changes; repeated imports/refreshes reuse its catalog ID, tags, descriptions, favorites, and memberships. Snapshots live in unique directories under Vault's existing managed Files/AppleNotes library. Writes are atomic and verified. Unchanged text/title reuses the existing file. Refresh writes a new local version before updating catalog metadata; only after successful persistence is the superseded app-owned file removed. Other files in its directory are never removed.

Refresh refuses to overwrite a snapshot edited outside Vault. Save/export those local edits before choosing how to replace them; no automatic destructive repair is offered. An unavailable source, denied permission, timeout, failed save, or cancellation preserves the Apple Notes original and existing catalog state. A failed metadata save can leave a generated local file for recovery; it does not delete original Notes data. Cancellation applies between Notes requests and keeps completed imports.

## Exported-note fallback

Use **Import Exported PDF / Text…** when Automation is unavailable or a note needs a faithful visual export. Export it yourself from Notes, then choose it through the native file picker. The existing file import review lets you index the exported file or copy it into the managed library. Imported files are labeled as exports, appear in Notes/All Files, and use native Quick Look for PDF/RTF/HTML preview. Text/Markdown exports can be read directly.

Exports have no verified account/note identity and no Refresh from Notes control; replacing an exported file is a normal local file operation. They are not represented as live iCloud links. Existing duplicate-path import behavior is retained.

## Implementation

New files: ImportedNote.swift (optional provenance, stable keys, registration rules); ImportedNoteTests.swift; AppleNotesBridge.swift (constant read-only script and typed events); AppleNotesStore.swift (user-initiated UI coordination); NotesSnapshotService.swift (managed snapshot IO); NotesWorkspace.swift (reader and consent/import sheet); this guide.

Existing FileItem, LibraryStore, collections, file import, Quick Look preview, global search, graph file nodes, inspector, Overview, sidebar, and activity mascot are extended. No competing notes database or new credential store is introduced. Workspace text-cache invalidation delegates note snapshots to the explicit Notes refresh path so a newly imported searchable note is not immediately removed from the index.

## Validation and limitations

Swift syntax/project/entitlement structure checks pass. New tests cover identity across title/folder changes, account collection registration, safe filenames, legacy metadata decoding, import/refresh/restart preserving metadata, unchanged-copy reuse, sibling-file preservation, edited-copy refusal, and specific permission/lock/timeout messages. The native AppleScript interpreter, Notes scripting dictionary, macOS Automation consent, sandbox behavior, iCloud synchronization, signed builds, and GUI reader/preview have **not been exercised** on this Linux machine. The Apple-event dateValue API was checked against a public macOS SDK header; that is not runtime validation.

NSAppleScript executes on the main thread as required. Operations yield between bounded note requests; a folder-title query can temporarily occupy the main thread until Notes responds or the 15-second script timeout expires. Cancellation cannot interrupt a system permission prompt or synchronous Apple-event call. Test responsiveness with large Notes folders before relying on it.

The sandbox Apple-events exception needs review for any Mac App Store distribution. This source integration is not a claim of App Store approval, a production-ready cloud synchronization service, or universal Notes-format compatibility.

On a Mac, run the README build/tests. With disposable notes, verify allow/deny/retry, nested folders, empty folders, locked notes, moved/renamed/deleted notes, Unicode/quotes/newlines in titles, refreshed text and optional search, preserving tags/favorites, local edits, cancelled imports, exported PDF previews, and offline/partially synced iCloud accounts. Confirm the app never changes an original note or shows its contents in the mascot/error logs.
