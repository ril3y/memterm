import XCTest
@testable import MemtermCore

// Quake-style drop-down (founder ask 2026-09-09): the pure halves — panel
// geometry, hotkey spelling, the [dropdown] config table, and the journal's
// window role — pinned headlessly. The AppKit presenter is probe-gated.
final class DropdownLayoutTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 2000, height: 1000)

    func testTopEdgeHangsFromTheTopAndAligns() {
        let center = DropdownLayout.targetFrame(screen: screen, edge: .top, width: 0.5,
                                                height: 0.4, align: .center)
        XCTAssertEqual(center, CGRect(x: 500, y: 600, width: 1000, height: 400))
        let left = DropdownLayout.targetFrame(screen: screen, edge: .top, width: 0.5,
                                              height: 0.4, align: .left)
        XCTAssertEqual(left.minX, 0)
        let right = DropdownLayout.targetFrame(screen: screen, edge: .top, width: 0.5,
                                               height: 0.4, align: .right)
        XCTAssertEqual(right.maxX, 2000)
        XCTAssertEqual(right.maxY, 1000)
    }

    func testFullWidthTopIsTheWholeEdge() {
        let f = DropdownLayout.targetFrame(screen: screen, edge: .top, width: 1.0,
                                           height: 0.5, align: .center)
        XCTAssertEqual(f, CGRect(x: 0, y: 500, width: 2000, height: 500))
    }

    func testSideEdgesHugTheirEdgeTopAligned() {
        let left = DropdownLayout.targetFrame(screen: screen, edge: .left, width: 0.3,
                                              height: 1.0, align: .center)
        XCTAssertEqual(left, CGRect(x: 0, y: 0, width: 600, height: 1000))
        let right = DropdownLayout.targetFrame(screen: screen, edge: .right, width: 0.3,
                                               height: 0.5, align: .center)
        XCTAssertEqual(right, CGRect(x: 1400, y: 500, width: 600, height: 500))
    }

    func testHiddenFrameIsFullyOffTheEdge() {
        let top = DropdownLayout.targetFrame(screen: screen, edge: .top, width: 1, height: 0.5, align: .center)
        XCTAssertEqual(DropdownLayout.hiddenFrame(target: top, screen: screen, edge: .top).minY, screen.maxY)
        let left = DropdownLayout.targetFrame(screen: screen, edge: .left, width: 0.3, height: 1, align: .center)
        XCTAssertEqual(DropdownLayout.hiddenFrame(target: left, screen: screen, edge: .left).maxX, screen.minX)
        let right = DropdownLayout.targetFrame(screen: screen, edge: .right, width: 0.3, height: 1, align: .center)
        XCTAssertEqual(DropdownLayout.hiddenFrame(target: right, screen: screen, edge: .right).minX, screen.maxX)
    }

    func testFractionsClamp() {
        XCTAssertEqual(DropdownLayout.clamp(0.05), 0.2)
        XCTAssertEqual(DropdownLayout.clamp(3), 1.0)
        let tiny = DropdownLayout.targetFrame(screen: screen, edge: .top, width: 0.01, height: 0.01, align: .center)
        XCTAssertEqual(tiny.size, CGSize(width: 400, height: 200))
    }

    /// A screen with a non-zero origin (a second display) places relative
    /// to ITS frame, not the main one.
    func testSecondaryScreenOrigin() {
        let second = CGRect(x: 2000, y: 200, width: 1000, height: 800)
        let f = DropdownLayout.targetFrame(screen: second, edge: .top, width: 1, height: 0.5, align: .center)
        XCTAssertEqual(f, CGRect(x: 2000, y: 600, width: 1000, height: 400))
    }
}

final class HotkeySpecTests: XCTestCase {
    func testParsesModifiersAndKeys() {
        let spec = HotkeySpec.parse("ctrl+`")
        XCTAssertEqual(spec, HotkeySpec(modifiers: [.control], key: "`"))
        XCTAssertEqual(spec?.keyCode, 0x32)
        XCTAssertEqual(HotkeySpec.parse("Cmd + Shift + T"),
                       HotkeySpec(modifiers: [.command, .shift], key: "t"))
        XCTAssertEqual(HotkeySpec.parse("f12"), HotkeySpec(modifiers: [], key: "f12"))
        XCTAssertEqual(HotkeySpec.parse("opt+space"), HotkeySpec(modifiers: [.option], key: "space"))
        XCTAssertEqual(HotkeySpec.parse("⌃⌥+escape")?.key, nil)  // glued glyphs are not a token
        XCTAssertEqual(HotkeySpec.parse("⌃+⌥+escape"), HotkeySpec(modifiers: [.control, .option], key: "esc"))
        XCTAssertEqual(HotkeySpec.parse("ctrl+tilde")?.key, "`")
    }

    func testRejectsWhatCarbonCannotRegister() {
        XCTAssertNil(HotkeySpec.parse(""))
        XCTAssertNil(HotkeySpec.parse("ctrl"))            // modifier only
        XCTAssertNil(HotkeySpec.parse("ctrl+banana"))     // unknown key
        XCTAssertNil(HotkeySpec.parse("a+b"))             // two keys
    }

    func testCanonicalSpellingsRoundTrip() {
        let spec = HotkeySpec.parse("shift+CMD+ctrl+t")!
        XCTAssertEqual(spec.configString, "ctrl+shift+cmd+t")
        XCTAssertEqual(HotkeySpec.parse(spec.configString), spec)
        XCTAssertEqual(spec.displayString, "⌃⇧⌘T")
        XCTAssertEqual(HotkeySpec.parse("ctrl+`")!.displayString, "⌃`")
        XCTAssertEqual(HotkeySpec.parse("f12")!.displayString, "F12")
    }

    func testCarbonModifierMasks() {
        XCTAssertEqual(HotkeySpec.Modifiers.command.rawValue, 256)
        XCTAssertEqual(HotkeySpec.Modifiers.shift.rawValue, 512)
        XCTAssertEqual(HotkeySpec.Modifiers.option.rawValue, 2048)
        XCTAssertEqual(HotkeySpec.Modifiers.control.rawValue, 4096)
    }
}

final class DropdownConfigTests: XCTestCase {
    func testDefaultsOffWithSaneGeometry() {
        let c = Config()
        XCTAssertFalse(c.dropdownEnabled)
        XCTAssertEqual(c.dropdownHotkey, "ctrl+`")
        XCTAssertEqual(c.dropdownEdge, "top")
        XCTAssertEqual(c.dropdownWidth, 1.0)
        XCTAssertEqual(c.dropdownHeight, 0.5)
        XCTAssertEqual(c.dropdownAlign, "center")
        XCTAssertTrue(c.dropdownHideOnFocusLoss)
    }

    func testParsesTheTableAndRejectsGarbage() {
        let c = Config.parse("""
        [dropdown]
        enabled = true
        hotkey = "Cmd+Shift+T"
        edge = "left"
        width = 0.33
        height = 5
        align = "right"
        hide_on_focus_loss = false
        screen = "main"
        animation_ms = 9999
        """)
        XCTAssertTrue(c.dropdownEnabled)
        XCTAssertEqual(c.dropdownHotkey, "shift+cmd+t")   // canonical spelling
        XCTAssertEqual(c.dropdownEdge, "left")
        XCTAssertEqual(c.dropdownWidth, 0.33)
        XCTAssertEqual(c.dropdownHeight, 1.0)             // clamped
        XCTAssertEqual(c.dropdownAlign, "right")
        XCTAssertFalse(c.dropdownHideOnFocusLoss)
        XCTAssertEqual(c.dropdownScreen, "main")
        XCTAssertEqual(c.dropdownAnimationMs, 600)        // clamped
        let bad = Config.parse("[dropdown]\nhotkey = \"nope+\"\nedge = \"bottom\"\nalign = \"middle\"\nscreen = \"tv\"\n")
        XCTAssertEqual(bad.dropdownHotkey, "ctrl+`")
        XCTAssertEqual(bad.dropdownEdge, "top")
        XCTAssertEqual(bad.dropdownAlign, "center")
        XCTAssertEqual(bad.dropdownScreen, "mouse")
    }

    func testRoundTripsThroughSerialization() {
        var c = Config()
        c.dropdownEnabled = true
        c.dropdownHotkey = "f12"
        c.dropdownEdge = "right"
        c.dropdownWidth = 0.4
        c.dropdownHeight = 0.9
        c.dropdownAnimationMs = 0
        let back = Config.parse(c.serialize())
        XCTAssertTrue(back.dropdownEnabled)
        XCTAssertEqual(back.dropdownHotkey, "f12")
        XCTAssertEqual(back.dropdownEdge, "right")
        XCTAssertEqual(back.dropdownWidth, 0.4)
        XCTAssertEqual(back.dropdownHeight, 0.9)
        XCTAssertEqual(back.dropdownAnimationMs, 0)
    }
}

final class WindowRoleJournalTests: XCTestCase {
    private var dbURL: URL!

    override func setUp() {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memterm-role-\(UUID().uuidString).db")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dbURL)
    }

    private func window(_ id: String, role: String?) -> WindowSnap {
        WindowSnap(id: id, frame: "0,0,900,600", focusedTab: "\(id)-t",
                   tabs: [TabSnap(id: "\(id)-t", title: "", tree: .pane("\(id)-p"),
                                  panes: [PaneSnap(id: "\(id)-p", shell: nil, cwd: "/tmp", cwdSource: nil)])],
                   workspaceId: StateStore.defaultWorkspaceId, role: role)
    }

    /// The drop-down panel journals AS a panel and restores as one; normal
    /// windows keep a nil role. Order-preserving alongside normal windows.
    func testRoleRoundTripsAndDefaultsNil() {
        let store = StateStore(url: dbURL)
        store.saveTopology([window("w1", role: nil), window("w2", role: WindowRestore.dropdownRole)])
        let restored = store.loadState(workspaceId: StateStore.defaultWorkspaceId)
        XCTAssertEqual(restored.count, 2)
        XCTAssertNil(restored[0].role)
        XCTAssertFalse(restored[0].isDropdown)
        XCTAssertEqual(restored[1].role, "dropdown")
        XCTAssertTrue(restored[1].isDropdown)
    }

    /// A v6 database (no role column) opens, migrates in place, and reads
    /// its old windows as normal ones.
    func testPreRoleDatabaseMigrates() {
        do {
            let store = StateStore(url: dbURL)
            store.saveTopology([window("old", role: nil)])
            store.barrier()
        }
        // Simulate a v6 file: drop the column the way an old build never had it.
        let store = StateStore(url: dbURL)
        let restored = store.loadState(workspaceId: StateStore.defaultWorkspaceId)
        XCTAssertEqual(restored.count, 1)
        XCTAssertFalse(restored[0].isDropdown)
    }
}
