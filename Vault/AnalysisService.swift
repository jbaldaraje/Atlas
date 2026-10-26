import Foundation
import CryptoKit
import VaultCore

struct AnalyzedFile: Identifiable {
    var id: UUID { file.id }
    let file: FileItem
    let identity: String
    let allocated: Int64
    let digest: String?
}
struct StorageReport {
    var files: [AnalyzedFile] = []
    var failedIDs: [UUID] = []
    var duplicates: [[AnalyzedFile]] = []
    var logicalBytes: Int64 { files.reduce(0) { $0 + $1.file.size } }
    var allocatedBytes: Int64 { files.reduce(0) { $0 + $1.allocated } }
}
actor AnalysisService {
    func analyze(_ files: [FileItem], hash: Bool) throws -> StorageReport {
        var report = StorageReport()
        var identities = Set<String>()
        var candidates: [(FileItem, String, Int64, Date?)] = []
        for file in files {
            try Task.checkCancellation()
            do {
                let entry = try FileAccessService.withAccess(file) { url -> (FileItem, String, Int64, Date?) in
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
                    let attr = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard let device = attr[.systemNumber] as? NSNumber, let inode = attr[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
                    var refreshed = file; refreshed.size = Int64(values.fileSize ?? 0); refreshed.modifiedAt = values.contentModificationDate
                    return (refreshed, "\(device):\(inode)", Int64(values.totalFileAllocatedSize ?? 0), values.contentModificationDate)
                }
                if identities.insert(entry.1).inserted { candidates.append(entry) }
            } catch { report.failedIDs.append(file.id) }
        }
        let sizes = Dictionary(grouping: candidates, by: { $0.0.size })
        for (file, identity, allocated, modified) in candidates {
            try Task.checkCancellation()
            do {
                var digest: String?
                if hash, (sizes[file.size]?.count ?? 0) > 1 {
                    digest = try FileAccessService.withAccess(file) { url in
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        var hasher = SHA256()
                        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                            try Task.checkCancellation(); hasher.update(data: chunk)
                        }
                        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        guard Int64(after.fileSize ?? -1) == file.size, after.contentModificationDate == modified else { throw CocoaError(.fileReadUnknown) }
                        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    }
                }
                report.files.append(AnalyzedFile(file: file, identity: identity, allocated: allocated, digest: digest))
            } catch is CancellationError { throw CancellationError() }
            catch { report.failedIDs.append(file.id) }
        }
        report.duplicates = Dictionary(grouping: report.files.filter { $0.digest != nil }, by: { $0.digest! }).values.filter { $0.count > 1 }.map { $0 }
        return report
    }
}
