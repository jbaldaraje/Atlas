import Foundation
import CryptoKit

/// Entire payload, including titles and usernames, is authenticated ciphertext.
struct EncryptedRecordRepository {
    let url: URL
    func load(key: SymmetricKey) throws -> [SecureRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        return try JSONDecoder().decode([SecureRecord].self, from: AES.GCM.open(box, using: key))
    }
    func save(_ records: [SecureRecord], key: SymmetricKey) throws {
        let data = try JSONEncoder().encode(records)
        guard let ciphertext = try AES.GCM.seal(data, using: key).combined else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ciphertext.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
