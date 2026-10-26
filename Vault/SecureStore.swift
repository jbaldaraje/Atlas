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
    private let service = "com.vault.workspace.encryption.v1"
    private let account = "vault-key"
    private let url = URL.applicationSupportDirectory.appendingPathComponent("Vault/Secure/records.aesgcm")
    var idleSeconds: TimeInterval = 120
    private var observers: [NSObjectProtocol] = []
    init() {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lock() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lock() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lock() } })
    }
    func unlock() {
        guard !authenticating else { return }
        authenticating = true
        let attempt = generation
        Task {
            defer { authenticating = false }
            let context = LAContext()
            authentication = context
            context.localizedReason = "Unlock your encrypted Vault records"
            do {
                guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: context.localizedReason) else { return }
                var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecUseAuthenticationContext as String: context]
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                let data: Data
                if status == errSecItemNotFound {
                    // Never create a replacement key for existing ciphertext.
                    guard !FileManager.default.fileExists(atPath: url.path) else { throw SecureError.missingKey }
                    var bytes = Data(count: 32)
                    let generated = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
                    guard generated == errSecSuccess else { throw SecureError.keychain }
                    var accessError: Unmanaged<CFError>?
                    guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &accessError) else { throw SecureError.keychain }
                    query = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecValueData as String: bytes, kSecAttrAccessControl as String: access]
                    guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw SecureError.keychain }
                    data = bytes
                } else {
                    guard status == errSecSuccess, let bytes = result as? Data else { throw SecureError.keychain }
                    data = bytes
                }
                let candidateKey = SymmetricKey(data: data)
                let loaded = try EncryptedRecordRepository(url: url).load(key: candidateKey)
                guard attempt == generation else { return }
                key = candidateKey; records = loaded; unlocked = true; touch()
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in guard let self else { return }; if Date().timeIntervalSince(self.lastActivity) >= self.idleSeconds { self.lock() } }
                }
            } catch { self.error = "Unlock failed. Authentication, Keychain access, or record integrity could not be verified. Existing encrypted data has been preserved."; lock() }
        }
    }
    func touch() { lastActivity = .now }
    func lock() {
        generation = UUID(); authentication?.invalidate(); authentication = nil
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
    enum SecureError: Error { case missingKey, keychain }
}
