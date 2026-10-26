import Foundation

public enum NotificationPreference: String, Codable, CaseIterable, Sendable {
    case off, important, scanCompletion
    public var title: String {
        switch self { case .off: "Off"; case .important: "Important events only"; case .scanCompletion: "Scan completion and errors" }
    }
    public func shouldNotify(stage: ScanStage, hasErrors: Bool) -> Bool {
        guard self != .off else { return false }
        if stage == .failed || stage == .interrupted { return true }
        return stage == .completed && (hasErrors || self == .scanCompletion)
    }
}
public enum ThumbnailBudget: Int, CaseIterable, Sendable {
    case small = 16, standard = 32, large = 64
    public var bytes: Int { rawValue * 1024 * 1024 }
}
/// Monotonic timestamps, not wall-clock dates. Always deliver the final count.
public struct ProgressThrottle: Sendable {
    private var last: TimeInterval?
    public let interval: TimeInterval
    public init(interval: TimeInterval = 0.1) { self.interval = interval }
    public mutating func shouldPublish(now: TimeInterval, final: Bool = false) -> Bool {
        if final || last == nil || now - (last ?? now) >= interval {
            last = now; return true
        }
        return false
    }
}
/// Coalesces event bursts; taking a batch removes only those roots, not later changes.
public struct MonitoringChanges: Sendable {
    public private(set) var dirty: Set<UUID> = []
    public init() {}
    public mutating func mark(_ id: UUID) { dirty.insert(id) }
    public mutating func reconcile(enabled: Set<UUID>) { dirty.formIntersection(enabled) }
    public mutating func take() -> Set<UUID> { let next = dirty; dirty.removeAll(keepingCapacity: true); return next }
}
