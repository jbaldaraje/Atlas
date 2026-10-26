import Foundation

public struct SpatialPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Camera math is independent of SwiftUI and of stored file paths.
public struct GraphCamera: Equatable, Sendable {
    public var zoom: Double = 1
    public var pan = SpatialPoint(x: 0, y: 0)
    public init() {}
    public func screen(_ point: SpatialPoint, width: Double, height: Double) -> SpatialPoint {
        SpatialPoint(x: width / 2 + pan.x + point.x * zoom, y: height / 2 + pan.y + point.y * zoom)
    }
    public func world(_ point: SpatialPoint, width: Double, height: Double) -> SpatialPoint {
        SpatialPoint(x: (point.x - width / 2 - pan.x) / zoom, y: (point.y - height / 2 - pan.y) / zoom)
    }
    public mutating func setZoom(_ value: Double) { zoom = min(2.5, max(0.15, value)) }
    public mutating func focus(_ point: SpatialPoint) { pan = SpatialPoint(x: -point.x * zoom, y: -point.y * zoom) }
    public mutating func fit(_ points: [SpatialPoint], width: Double, height: Double) {
        guard let first = points.first, width > 0, height > 0 else { return }
        let minX = points.map(\.x).min() ?? first.x, maxX = points.map(\.x).max() ?? first.x
        let minY = points.map(\.y).min() ?? first.y, maxY = points.map(\.y).max() ?? first.y
        setZoom(min((width - 70) / (maxX - minX + 190), (height - 70) / (maxY - minY + 130), 1))
        focus(SpatialPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2))
    }
}

public enum SpatialLayout {
    /// Add nodes without changing any existing position. Generous spacing avoids card collisions.
    public static func extending(_ positions: [UUID: SpatialPoint], ids: [UUID]) -> [UUID: SpatialPoint] {
        var result = positions
        var slot = 0
        for id in ids where result[id] == nil {
            while true {
                let angle = Double(slot) * 2.399963229728653
                let radius = 145 * sqrt(Double(slot))
                let point = SpatialPoint(x: radius * cos(angle), y: radius * sin(angle))
                slot += 1
                if result.values.allSatisfy({ hypot($0.x - point.x, $0.y - point.y) >= 175 }) {
                    result[id] = point; break
                }
            }
        }
        return result
    }
}
