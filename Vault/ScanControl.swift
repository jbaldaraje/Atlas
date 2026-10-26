import Foundation
import VaultCore

/// One cooperative pause gate shared by the scan stages. No timer runs while paused.
actor ScanControl {
    private var paused = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var waitingCount: Int { waiters.count }
    func pause() { paused = true }
    func resume() {
        paused = false; let pending = waiters; waiters.removeAll()
        for continuation in pending.values { continuation.resume() }
    }
    func wait() async throws {
        try Task.checkCancellation()
        guard paused else { return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if !paused { continuation.resume() }
                else { waiters[id] = continuation }
            }
        }, onCancel: { Task { await self.cancel(id) } })
        try Task.checkCancellation()
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}

/// A separate job journal keeps progress checkpoints out of the full workspace JSON.
actor ScanJournal {
    static func url(base: URL) -> URL { base.appendingPathComponent("scan-job.json") }
    private let url: URL
    init(base: URL) { url = Self.url(base: base) }
    func save(_ job: ScanJob) throws {
        // Final cancelled/interrupted state must also save from a cancelled caller.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(job).write(to: url, options: .atomic)
    }
}
