import SwiftUI
import Security
import LocalAuthentication
import CryptoKit
import AppKit

struct SecureRecord: Identifiable, Codable {
    var id = UUID()
    var title: String
    var username: String
    var secret: String
    var note: String
}

/// Look in the data-protection Keychain first, preserving keys created by older builds.
struct VaultKeychain {
    static func loadOrCreate(context: LAContext, ciphertextExists: Bool) throws -> SymmetricKey {
        for dataProtection in [true, false] {
            var result: CFTypeRef?
            var query = identity(dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecUseAuthenticationContext as String] = context
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess {
                guard let bytes = result as? Data, bytes.count == 32 else { throw SecureStore.UnlockError.invalidKey }
                return SymmetricKey(data: bytes)
            }
            guard status == errSecItemNotFound else { throw SecureStore.UnlockError.keychain(status) }
        }
        guard !ciphertextExists else { throw SecureStore.UnlockError.missingKey }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw SecureStore.UnlockError.keychain(status) }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &accessError) else {
            throw SecureStore.UnlockError.accessControl
        }
        var item = identity(dataProtection: true)
        item[kSecValueData as String] = bytes
        item[kSecAttrAccessControl as String] = access
        item[kSecUseAuthenticationContext as String] = context
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecureStore.UnlockError.keychain(added) }
        return SymmetricKey(data: bytes)
    }
    private static func identity(dataProtection: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.vault.workspace.encryption.v1",
         kSecAttrAccount as String: "vault-key",
         kSecUseDataProtectionKeychain as String: dataProtection]
    }
}

/// Separate encrypted storage: never forward these records to LibraryStore or content indexing.
@MainActor
final class SecureStore: ObservableObject {
    @Published private(set) var unlocked = false
    @Published private(set) var records: [SecureRecord] = []
    @Published var error: String?
    @Published var authenticating = false
    private var key: SymmetricKey?
    private var authentication: LAContext?
    private var generation = UUID()
    private var timer: Timer?
    private var lastActivity = Date()
    private var copiedChangeCount: Int?
    typealias Authenticate = (LAContext) async throws -> Void
    typealias KeyAccess = (LAContext, Bool) throws -> SymmetricKey
    private let authenticate: Authenticate
    private let keyAccess: KeyAccess
    private let applicationIsActive: () -> Bool
    private let url: URL
    private var unlockTask: Task<Void, Never>?
    var idleSeconds: TimeInterval = 120
    private var observers: [NSObjectProtocol] = []
    init(
        url: URL = URL.applicationSupportDirectory.appendingPathComponent("Vault/Secure/records.aesgcm"),
        authenticate: @escaping Authenticate = { context in
            var failure: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &failure) else {
                throw failure ?? NSError(domain: LAError.errorDomain, code: LAError.Code.passcodeNotSet.rawValue)
            }
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your encrypted Vault records") else {
                throw UnlockError.authenticationFailed
            }
        },
        keyAccess: @escaping KeyAccess = VaultKeychain.loadOrCreate,
        applicationIsActive: @escaping () -> Bool = { NSApp.isActive },
        observeSystemEvents: Bool = true
    ) {
        self.url = url; self.authenticate = authenticate; self.keyAccess = keyAccess
        self.applicationIsActive = applicationIsActive
        guard observeSystemEvents else { return }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lock() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lock() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.applicationDeactivated() } })
    }
    func unlock() {
        guard !authenticating, !unlocked else { return }
        error = nil
        authenticating = true
        let attempt = generation
        unlockTask = Task {
            defer { authenticating = false; authentication = nil }
            let context = LAContext()
            authentication = context
            context.localizedReason = "Unlock your encrypted Vault records"
            do {
                try await authenticate(context)
                guard attempt == generation else { return }
                try await waitForApplication(attempt: attempt)
                let candidateKey = try keyAccess(context, FileManager.default.fileExists(atPath: url.path))
                let loaded: [SecureRecord]
                do { loaded = try EncryptedRecordRepository(url: url).load(key: candidateKey) }
                catch { throw UnlockError.recordsUnreadable }
                try await waitForApplication(attempt: attempt)
                guard attempt == generation else { return }
                key = candidateKey; records = loaded; unlocked = true; touch()
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        if Date().timeIntervalSince(self.lastActivity) >= self.idleSeconds { self.lock() }
                    }
                }
            } catch {
                // Explicit lock/sleep/navigation cancellation must never revive or publish a pending unlock.
                guard attempt == generation else { return }
                let message = Self.unlockMessage(for: error)
                lock()
                self.error = message
            }
        }
    }
    /// Exposed internally so tests can wait for the actual unlock attempt, without prompting the Keychain.
    func waitForUnlock() async { await unlockTask?.value }
    private func waitForApplication(attempt: UUID) async throws {
        // The system authentication panel can close just before Vault regains focus.
        for _ in 0..<40 {
            try Task.checkCancellation()
            guard attempt == generation else { throw CancellationError() }
            if applicationIsActive() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw UnlockError.applicationInactive
    }
    func applicationDeactivated() {
        // No plaintext is exposed during authentication. The system's own panel may take focus.
        if authenticating && !unlocked { return }
        lock()
    }
    func touch() { lastActivity = .now }
    func lock() {
        generation = UUID(); unlockTask?.cancel(); authentication?.invalidate(); authentication = nil
        timer?.invalidate(); timer = nil; key = nil; records = []; unlocked = false
        clearClipboard()
    }
    func save(_ record: SecureRecord) {
        var next = records
        if let i = next.firstIndex(where: { $0.id == record.id }) { next[i] = record } else { next.append(record) }
        persist(next)
    }
    func delete(_ id: UUID) { persist(records.filter { $0.id != id }) }
    private func persist(_ next: [SecureRecord]) {
        guard unlocked, let key else { return }
        do {
            try EncryptedRecordRepository(url: url).save(next, key: key)
            records = next; touch()
        } catch { self.error = "Encrypted records could not be saved." }
    }
    func copy(_ text: String) {
        guard unlocked else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        copiedChangeCount = pasteboard.changeCount; touch()
        let count = pasteboard.changeCount
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.copiedChangeCount == count else { return }
            self.clearClipboard()
        }
    }
    private func clearClipboard() {
        if let copiedChangeCount, NSPasteboard.general.changeCount == copiedChangeCount { NSPasteboard.general.clearContents() }
        copiedChangeCount = nil
    }
    enum UnlockError: LocalizedError {
        case missingKey, invalidKey, accessControl, authenticationFailed, applicationInactive, recordsUnreadable
        case keychain(OSStatus)
        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "The encryption key was not found in this Mac’s Keychain. Your encrypted records were preserved. Run the app with the original signing team and bundle identifier; an encrypted-file backup alone cannot replace the missing key."
            case .invalidKey:
                return "The stored Keychain key has an unexpected format. Existing encrypted records and the key were preserved."
            case .accessControl:
                return "macOS could not create a user-presence-protected Keychain key. Run a signed build of Vault and check that your Mac has a login password."
            case .authenticationFailed:
                return "macOS could not authenticate you. Try Unlock again using Touch ID or your Mac’s login password."
            case .applicationInactive:
                return "Vault stayed locked because it did not regain focus after authentication. Return to Vault and try Unlock again."
            case .recordsUnreadable:
                return "The encrypted records could not be read or authenticated with the Keychain key. The existing file and key were preserved; do not delete or reset them."
            case .keychain(let status):
                if status == errSecMissingEntitlement {
                    return "Keychain access requires a correctly signed build (\(status)). In Xcode, enable automatic signing and use your original team and bundle identifier, then Run again."
                }
                let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain access failed"
                return "Keychain error \(status): \(reason). Run Vault as a signed app and ensure your login Keychain is unlocked. Existing encrypted records were preserved."
            }
        }
    }
    static func unlockMessage(for error: Error) -> String? {
        if error is CancellationError { return nil }
        if let secureError = error as? UnlockError {
            if case .keychain(errSecUserCanceled) = secureError { return nil }
            return secureError.errorDescription
        }
        let nsError = error as NSError
        if nsError.domain == LAError.errorDomain {
            switch nsError.code {
            case LAError.Code.userCancel.rawValue, LAError.Code.appCancel.rawValue: return nil
            case LAError.Code.systemCancel.rawValue:
                return "macOS interrupted authentication. Keep Vault open and try Unlock again."
            case LAError.Code.passcodeNotSet.rawValue, LAError.Code.biometryNotAvailable.rawValue, LAError.Code.notInteractive.rawValue:
                return "macOS authentication is unavailable. Set a Mac login password and run Vault in your normal interactive login session. Touch ID is optional."
            default: return "macOS authentication failed (\(nsError.code)). Try again using Touch ID or your Mac’s login password."
            }
        }
        return "Unlock failed before records could be exposed. Existing encrypted data was preserved."
    }
}
