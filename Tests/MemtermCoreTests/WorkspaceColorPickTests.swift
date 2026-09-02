import XCTest
@testable import MemtermCore

/// Founder polish (2026-09-01): a new workspace's color is drawn at random
/// from the presets NOT already in use, falling back to the full preset list
/// only when all are taken. The random draw lives in the app layer; these
/// tests pin the pure candidate math it draws from.
final class WorkspaceColorPickTests: XCTestCase {
    private let presets = ["#8e8e93", "#0a84ff", "#28c840",
                           "#febc2e", "#ff5f57", "#bf5af2"]

    func testAllPresetsFreeWhenNothingUsed() {
        XCTAssertEqual(WorkspaceColorPick.candidates(presets: presets, used: []),
                       presets)
    }

    func testUsedPresetsAreExcluded() {
        let candidates = WorkspaceColorPick.candidates(
            presets: presets, used: ["#0a84ff", "#ff5f57"])
        XCTAssertEqual(candidates, ["#8e8e93", "#28c840", "#febc2e", "#bf5af2"])
    }

    func testDuplicateUsageStillExcludesJustThatPreset() {
        let candidates = WorkspaceColorPick.candidates(
            presets: presets, used: ["#28c840", "#28c840", "#28c840"])
        XCTAssertEqual(candidates, ["#8e8e93", "#0a84ff", "#febc2e",
                                    "#ff5f57", "#bf5af2"])
    }

    func testAllTakenFallsBackToEveryPreset() {
        XCTAssertEqual(WorkspaceColorPick.candidates(presets: presets, used: presets),
                       presets)
    }

    func testNonPresetUsageDoesNotShrinkCandidates() {
        // A workspace recolored to a hex outside the preset list must not
        // remove any preset from the pool.
        XCTAssertEqual(WorkspaceColorPick.candidates(presets: presets,
                                                     used: ["#123456"]),
                       presets)
    }

    func testEmptyPresetsStaysEmpty() {
        XCTAssertEqual(WorkspaceColorPick.candidates(presets: [], used: ["#0a84ff"]),
                       [])
    }
}
