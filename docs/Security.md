# Vault security design and release gate

## Trust boundary

The regular library, workspace metadata, extracted text, previews, and ordinary managed files are **not encrypted**. They are protected by macOS user permissions, App Sandbox, and the user's disk protections. Content extraction is opt-in because it places supported text and OCR in plaintext workspace metadata. No file contents or metadata are uploaded; there is no network entitlement or remote AI client.

Secure Vault has a separate AES-GCM file under Application Support/Vault/Secure. The entire array, including titles, usernames, notes, and secrets, is encrypted and authenticated. CryptoKit generates each sealing nonce. The 256-bit key comes from SecRandomCopyBytes, is stored as a generic-password Keychain item with WhenUnlockedThisDeviceOnly accessibility and userPresence access control, and is retrieved through an authenticated LAContext. OS device-owner authentication provides Touch ID or the system fallback. There is no custom cryptography or master-password derivation.

A missing key never causes an existing encrypted store to be replaced with a new key. Authentication/decryption failures retain existing ciphertext. A generation token prevents a pending unlock from publishing plaintext after a lock/sleep/focus event invalidates authentication. Writes require an unlocked key and use atomic encrypted-file replacement. File and parent directory permissions are restricted. Locked writes are rejected.

The in-memory key and records are released on lock, idle timeout, loss of application focus while unlocked, sleep, session resignation, and leaving the secure workspace. A temporary focus loss while still locked and authenticating does not invalidate the system authentication prompt; no key or records are published until the app is active again. Explicit lock, sleep, session resignation, and navigation always invalidate pending authentication. New protected keys use the macOS data-protection Keychain; existing legacy Keychain entries are read as a fallback without replacing them. Swift-managed memory is not guaranteed to be zeroized. A malicious process running as the user, compromised macOS, debugging/injection, screenshots, and compromised system clipboard are outside this defense boundary. These risks prevent any absolute security claim.

Clipboard clearing checks ownership via change count so later clipboard data from another app is preserved. Secrets are not added to library metadata, content search, thumbnails, notifications, or logs. General library indexing must never receive secure records.

## Recovery and backup

The key is device-bound. An encrypted-record-file backup alone cannot restore the vault on another Mac or after loss of the Keychain key. No recovery/export or key-rotation UI is implemented. No recovery guarantees should be made. Ordinary library backups and secure-record backups are different problems. Backups may retain deleted ciphertext indefinitely. The UI explains these limits before unlocking.

## Destructive file actions

Index removal never deletes files. Managed copies may be moved into a durable app-owned recovery area: intent is written before movement and recovery payloads are discoverable on restart. Restore refuses overwrite, copies/verifies before registration, and only removes recovery payloads after metadata registration. Permanent removal is a separate confirmation for a specific retained copy.

Original-file deletion uses macOS Trash with a second native picker grant for the exact file. The app checks path, resource identity, indexed size, indexed modification date, regular-file type, and excludes system/application-managed locations. Imported originals retain read-only bookmarks even though the app needs a user-selected read/write capability for explicitly requested Trash and restore operations. No original permanent-deletion UI is offered. Restore requires a new save location grant and refuses overwrite. Finder may permanently remove a Trash item; Vault then reports restore failure.

Filesystem operations and JSON metadata cannot form a single ACID transaction. Pending `.intent` files preserve original metadata when recording a native Trash result fails, and the error directs the user to Finder Trash. Crash reconciliation UI, stronger journal replay, and adversarial file-replacement race resistance remain release blockers. Do not exercise destructive actions on real personal data before macOS validation.

## Required independent review

Before production release, inspect Keychain access-control behavior on all supported Macs; test Touch ID unavailable/cancelled/locked-out and OS password fallback; test sleep/lock/unlock races and first-run enrollment; confirm ciphertext tampering behavior, missing-key behavior, idle handling, clipboard ownership, and absence of secret logging. Review sandbox grants for nested folders, external volumes, Trash, and restores. Threat-model local database tampering and filesystem races. Test interrupted saves, permissions, disk-full, power loss, and recovery records. Perform independent security review before presenting this subsystem as production-ready.
