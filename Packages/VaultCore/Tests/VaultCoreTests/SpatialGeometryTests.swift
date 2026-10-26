import XCTest
@testable import VaultCore

final class SpatialGeometryTests: XCTestCase {
    func testCameraCoordinateRoundTripAfterPanAndZoom() {
        var camera = GraphCamera(); camera.setZoom(1.7); camera.pan = SpatialPoint(x: -120, y: 80)
        let original = SpatialPoint(x: 456, y: -234)
        let screen = camera.screen(original, width: 900, height: 600)
        let world = camera.world(screen, width: 900, height: 600)
        XCTAssertEqual(world.x, original.x, accuracy: 0.000001)
        XCTAssertEqual(world.y, original.y, accuracy: 0.000001)
    }
    func testFocusCentersSelectedNode() {
        var camera = GraphCamera(); camera.setZoom(0.8)
        let point = SpatialPoint(x: 200, y: -500); camera.focus(point)
        XCTAssertEqual(camera.screen(point, width: 1000, height: 600), SpatialPoint(x: 500, y: 300))
    }
    func testFitContainsOrdinaryNetworkAndEmptyFitPreservesCamera() {
        let points = [SpatialPoint(x: -500, y: -300), SpatialPoint(x: 650, y: 450)]
        var camera = GraphCamera(); camera.fit(points, width: 1000, height: 700)
        for p in points {
            let screen = camera.screen(p, width: 1000, height: 700)
            XCTAssertGreaterThan(screen.x, 0); XCTAssertLessThan(screen.x, 1000)
            XCTAssertGreaterThan(screen.y, 0); XCTAssertLessThan(screen.y, 700)
        }
        let before = camera; camera.fit([], width: 0, height: 0)
        XCTAssertEqual(camera, before)
    }
    func testZoomClampsToNavigationBounds() {
        var camera = GraphCamera(); camera.setZoom(0)
        XCTAssertEqual(camera.zoom, 0.15)
        camera.setZoom(100)
        XCTAssertEqual(camera.zoom, 2.5)
    }
    func testLayoutPreservesExistingNodesAndSpacesNewNodes() {
        let ids = (0..<40).map { _ in UUID() }
        let initial = SpatialLayout.extending([:], ids: Array(ids.prefix(20)))
        let extended = SpatialLayout.extending(initial, ids: Array(ids.reversed()))
        for (id, point) in initial { XCTAssertEqual(extended[id], point) }
        XCTAssertEqual(extended.count, 40)
        for (index, a) in ids.enumerated() {
            for b in ids.dropFirst(index + 1) {
                let p = extended[a]!, q = extended[b]!
                XCTAssertGreaterThanOrEqual(hypot(p.x - q.x, p.y - q.y), 175)
            }
        }
    }
    func testLegacyWorkspaceWithoutPresentationOrOpenHistoryLoads() throws {
        let encoded = try JSONEncoder().encode(Workspace())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "graphPositions"); object.removeValue(forKey: "openedFiles")
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.openedFiles); XCTAssertNil(decoded.graphPositions)
        XCTAssertTrue(decoded.relationships.isEmpty)
    }
}
