import AppKit
import QuickLookThumbnailing
import VaultCore

/// Demand-driven thumbnails for visible file cards only. Never used for Secure Vault records.
@MainActor
final class ThumbnailPipeline {
    static let shared = ThumbnailPipeline()
    private struct Entry {
        let key: String
        let request: QLThumbnailGenerator.Request
        let continuation: CheckedContinuation<NSImage?, Never>
    }
    private let cache = NSCache<NSString, NSImage>()
    private var pending: [UUID: Entry] = [:]
    private var queue: [UUID] = []
    private var active: [UUID: Entry] = [:]
    private var suspended = false
    private var pressure: DispatchSourceMemoryPressure?
    private init() {
        cache.countLimit = 128
        configure(megabytes: UserDefaults.standard.integer(forKey: "thumbnailCacheMB"))
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in Task { @MainActor in self?.cache.removeAllObjects() } }
        source.resume(); pressure = source
    }
    func configure(megabytes: Int) {
        cache.totalCostLimit = (ThumbnailBudget(rawValue: megabytes) ?? .standard).bytes
        cache.removeAllObjects()
    }
    func setSuspended(_ value: Bool) {
        suspended = value
        if value {
            for id in Array(pending.keys) + Array(active.keys) { cancel(id) }
            cache.removeAllObjects()
        }
    }
    func image(key: String, request: QLThumbnailGenerator.Request) async -> NSImage? {
        if Task.isCancelled || suspended { return nil }
        if let image = cache.object(forKey: key as NSString) { return image }
        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !suspended, pending.count < 128 else { continuation.resume(returning: nil); return }
                pending[id] = Entry(key: key, request: request, continuation: continuation)
                queue.append(id); startNext()
            }
        }, onCancel: { Task { @MainActor in self.cancel(id) } })
    }
    private func startNext() {
        while !suspended, active.count < 4, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let entry = pending.removeValue(forKey: id) else { continue }
            active[id] = entry
            QLThumbnailGenerator.shared.generateBestRepresentation(for: entry.request) { representation, _ in
                let image = representation?.nsImage
                let cost = representation.map { $0.cgImage.width * $0.cgImage.height * 4 } ?? 0
                Task { @MainActor in self.finish(id, image: image, cost: cost) }
            }
        }
    }
    private func finish(_ id: UUID, image: NSImage?, cost: Int) {
        guard let entry = active.removeValue(forKey: id) else { return }
        if let image { cache.setObject(image, forKey: entry.key as NSString, cost: cost) }
        entry.continuation.resume(returning: image); startNext()
    }
    private func cancel(_ id: UUID) {
        if let entry = pending.removeValue(forKey: id) {
            entry.continuation.resume(returning: nil)
            queue.removeAll { $0 == id }
        } else if let entry = active.removeValue(forKey: id) {
            QLThumbnailGenerator.shared.cancel(entry.request)
            entry.continuation.resume(returning: nil)
        }
        startNext()
    }
}
