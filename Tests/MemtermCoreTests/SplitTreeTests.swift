import XCTest
@testable import MemtermCore

final class SplitTreeTests: XCTestCase {

    /// Round trip through real JSON bytes (JSONSerialization), the same way
    /// the state store persists the tree — not just object-graph identity.
    private func roundTrip(_ node: SplitNode) throws -> SplitNode? {
        let data = try JSONSerialization.data(withJSONObject: node.toJSONObject())
        let obj = try JSONSerialization.jsonObject(with: data)
        return SplitNode.from(jsonObject: obj)
    }

    func testSinglePaneRoundTrips() throws {
        let node = SplitNode.pane("p-123")
        XCTAssertEqual(try roundTrip(node), node)
    }

    func testNestedMixedTreeRoundTripsWithRatiosAndIds() throws {
        let node = SplitNode.split(
            vertical: true, ratio: 0.25,
            first: .split(vertical: false, ratio: 0.5,
                          first: .pane("A"), second: .pane("B")),
            second: .split(vertical: true, ratio: 0.75,
                           first: .pane("C"),
                           second: .split(vertical: false, ratio: 0.125,
                                          first: .pane("D"), second: .pane("E"))))
        let back = try roundTrip(node)
        XCTAssertEqual(back, node)
        XCTAssertEqual(back?.paneIds, ["A", "B", "C", "D", "E"])
    }

    func testFractionalRatioSurvivesJSONWithinAccuracy() throws {
        let node = SplitNode.split(vertical: false, ratio: 0.61803398875,
                                   first: .pane("a"), second: .pane("b"))
        guard case .split(let vertical, let ratio, _, _)? = try roundTrip(node) else {
            return XCTFail("tree shape lost")
        }
        XCTAssertFalse(vertical)
        XCTAssertEqual(ratio, 0.61803398875, accuracy: 1e-9)
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(SplitNode.from(jsonObject: ["nope": true]))
        XCTAssertNil(SplitNode.from(jsonObject: "just a string"))
        XCTAssertNil(SplitNode.from(jsonObject: [
            "vertical": true, "ratio": 0.5,
            "children": [["pane": "only-one-child"]],
        ]))
        XCTAssertNil(SplitNode.from(jsonObject: [
            "vertical": true, "ratio": 0.5,
            "children": [["pane": "ok"], ["garbage": 1]],
        ]))
    }

    func testPaneIdsAreInOrder() {
        let node = SplitNode.split(vertical: true, ratio: 0.5,
                                   first: .pane("first"),
                                   second: .split(vertical: false, ratio: 0.5,
                                                  first: .pane("second"),
                                                  second: .pane("third")))
        XCTAssertEqual(node.paneIds, ["first", "second", "third"])
    }
}
