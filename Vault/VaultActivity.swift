import Foundation
import VaultCore

/// Public-facing activity only: no file paths, passwords, secure titles, or error contents.
struct VaultActivityInput {
    var hasError = false
    var authenticating = false
    var secureSelected = false
    var secureUnlocked = false
    var scanStage: ScanStage?
    var discovered = 0
    var processed = 0
    var importing = false
    var importProgress = 0
    var importTotal = 0
    var monitoring = false
    var working = false
    var processingLabel: String?
    var activeFolders = 0
    var pausedFolders = 0
    var catalogFiles = 0
}

struct VaultActivity: Equatable {
    enum Kind: String { case idle, scanning, organizing, importing, monitoring, processing, authenticating, locked, unlocked, paused, attention }
    let kind: Kind
    let title: String
    let detail: String
    let progress: Double?
    var isBusy: Bool { [.scanning, .organizing, .importing, .monitoring, .processing, .authenticating].contains(kind) }

    static func resolve(_ input: VaultActivityInput) -> VaultActivity {
        if input.hasError { return VaultActivity(kind: .attention, title: "Needs your attention", detail: "An operation reported an issue", progress: nil) }
        if input.authenticating { return VaultActivity(kind: .authenticating, title: "Verifying access", detail: "Waiting for macOS authentication", progress: nil) }
        if let stage = input.scanStage, stage.isRunning {
            let title: String
            switch stage {
            case .enumerating: title = "Discovering files"
            case .indexing: title = "Indexing your library"
            case .organizing: title = "Connecting your ideas"
            case .duplicates: title = "Reviewing duplicates"
            default: title = "Scanning folders"
            }
            return VaultActivity(kind: stage == .organizing ? .organizing : .scanning, title: title, detail: "\(input.discovered) found · \(input.processed) processed", progress: nil)
        }
        if input.importing {
            let total = max(0, input.importTotal), completed = max(0, input.importProgress)
            let progress: Double? = total > 0 ? min(1, Double(completed) / Double(total)) : nil
            return VaultActivity(kind: .importing, title: "Adding your files", detail: total > 0 ? "\(min(completed, total)) of \(total) processed" : "Reading selected file metadata", progress: progress)
        }
        if input.monitoring { return VaultActivity(kind: .monitoring, title: "Checking your folders", detail: "Reviewing approved locations", progress: nil) }
        if input.working { return VaultActivity(kind: .processing, title: input.processingLabel ?? "Processing local files", detail: "Working on your Mac", progress: nil) }
        if input.secureSelected {
            return VaultActivity(kind: input.secureUnlocked ? .unlocked : .locked, title: input.secureUnlocked ? "Secure Vault unlocked" : "Secure Vault locked", detail: "Separate encrypted records", progress: nil)
        }
        if input.activeFolders > 0 { return VaultActivity(kind: .idle, title: "Ready when you are", detail: "\(input.activeFolders) folders monitored while open", progress: nil) }
        if input.pausedFolders > 0 { return VaultActivity(kind: .paused, title: "Monitoring paused", detail: "\(input.pausedFolders) approved folders paused", progress: nil) }
        return VaultActivity(kind: .idle, title: "Ready when you are", detail: "\(input.catalogFiles) files in your local library", progress: nil)
    }
}
