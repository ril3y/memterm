import XCTest
@testable import MemtermCore

// TESTING.md L2 seam (c): the focus contract, headless. Every gesture path
// must return the keyboard to the pane except an in-progress rename.
final class FocusIntentTests: XCTestCase {
    func testRestingStateIsPane() {
        XCTAssertEqual(FocusIntent().target, .pane)
    }

    func testRenameLifecycle() {
        var intent = FocusIntent()
        XCTAssertEqual(intent.apply(.beginRename), .renameEditor)
        XCTAssertEqual(intent.apply(.commitRename), .pane)
        XCTAssertEqual(intent.apply(.beginRename), .renameEditor)
        XCTAssertEqual(intent.apply(.cancelRename), .pane)
    }

    func testEveryNonRenameGestureLandsInPane() {
        let events: [FocusIntent.Event] = [.selectTab, .switchWorkspace,
                                           .closePane, .closeTab]
        for event in events {
            var intent = FocusIntent()
            intent.apply(.beginRename)  // worst case: gesture arrives mid-rename
            XCTAssertEqual(intent.apply(event), .pane,
                           "gesture \(event) must hand the keyboard to the pane")
        }
    }
}
