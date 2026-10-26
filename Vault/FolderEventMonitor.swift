import AppKit
import CoreServices
import VaultCore

/// One FSEvents stream per explicitly approved root; no recursive idle polling.
@MainActor
final class FolderEventMonitor {
    private final class CallbackBox: @unchecked Sendable {
        let changed: @Sendable ([String]) -> Void
        init(_ changed: @escaping @Sendable ([String]) -> Void) { self.changed = changed }
    }
    private final class Watch {
        let location: ScanLocation
        let resource: PreviewResource
        let stream: FSEventStreamRef
        let callback: CallbackBox
        let queue: DispatchQueue
        init(location: ScanLocation, resource: PreviewResource, stream: FSEventStreamRef, callback: CallbackBox, queue: DispatchQueue) {
            self.location = location; self.resource = resource; self.stream = stream; self.callback = callback; self.queue = queue
        }
        deinit {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            queue.sync {} // Finish callbacks before their immutable context and scope are released.
            withExtendedLifetime(callback) {}; withExtendedLifetime(resource) {}
        }
    }
    private let queue = DispatchQueue(label: "Vault.approved-folder-events", qos: .utility)
    private var watches: [UUID: Watch] = [:]
    private var generation = UUID()
    func configure(_ locations: [ScanLocation], changed: @escaping @MainActor @Sendable (UUID) -> Void) async -> [String] {
        let current = UUID(); generation = current
        let enabled = locations.filter { !$0.paused }
        let wanted = Set(enabled.map(\.id))
        for id in Array(watches.keys) where !wanted.contains(id) || !enabled.contains(where: { $0.id == id && $0 == watches[id]?.location }) { remove(id) }
        var errors: [String] = []
        for location in enabled where watches[location.id] == nil {
            do {
                let resource = try await PreviewResource.resolve(bookmark: location.bookmark, directory: true)
                guard generation == current, !Task.isCancelled else { return errors }
                let url = resource.url
                let id = location.id
                let excluded = [URL.applicationSupportDirectory.appendingPathComponent("Vault", isDirectory: true).standardizedFileURL.path] + location.excludes.map { url.appendingPathComponent($0).standardizedFileURL.path }
                let box = CallbackBox { paths in
                    guard paths.isEmpty || paths.contains(where: { path in !excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) }) else { return }
                    Task { @MainActor in changed(id) }
                }
                var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil)
                let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
                guard let stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, eventPaths, _, _ in
                    guard count > 0, let info else { return }
                    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                    Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().changed(paths)
                }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1, flags) else {
                    throw CocoaError(.fileReadUnknown)
                }
                FSEventStreamSetDispatchQueue(stream, queue)
                guard FSEventStreamStart(stream) else {
                    FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
                    queue.sync {}
                    throw CocoaError(.fileReadNoPermission)
                }
                watches[id] = Watch(location: location, resource: resource, stream: stream, callback: box, queue: queue)
                changed(id) // One reconciliation on connection/reconfiguration, then events only.
            } catch { errors.append("A monitored folder could not be watched. Reconnect its volume or approve it again.") }
        }
        return errors
    }
    func stop() { generation = UUID(); for id in Array(watches.keys) { remove(id) } }
    private func remove(_ id: UUID) { watches.removeValue(forKey: id) }
}
