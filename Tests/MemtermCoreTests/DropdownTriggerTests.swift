import XCTest
@testable import MemtermCore

final class DropdownTriggerTests: XCTestCase {
    func testParsesCombosAndDoubleTaps() {
        XCTAssertEqual(DropdownTrigger.parse("ctrl+`"), .combo(HotkeySpec(modifiers: [.control], key: "`")))
        XCTAssertEqual(DropdownTrigger.parse("double-tap ctrl"), .doubleTap(.control))
        XCTAssertEqual(DropdownTrigger.parse("Double-Tap Esc"), .doubleTap(.escape))
        XCTAssertEqual(DropdownTrigger.parse("double-tap  option"), .doubleTap(.option))
        XCTAssertEqual(DropdownTrigger.parse("double-tap ⌘"), .doubleTap(.command))
        XCTAssertNil(DropdownTrigger.parse("double-tap banana"))
        XCTAssertNil(DropdownTrigger.parse("double-tap"))
        XCTAssertNil(DropdownTrigger.parse(""))
    }

    func testSpellingsRoundTrip() {
        for text in ["double-tap ctrl", "double-tap opt", "double-tap shift", "double-tap cmd", "double-tap esc", "ctrl+shift+t"] {
            let trigger = DropdownTrigger.parse(text)!
            XCTAssertEqual(trigger.configString, text)
            XCTAssertEqual(DropdownTrigger.parse(trigger.configString), trigger)
        }
        XCTAssertEqual(DropdownTrigger.parse("double-tap ctrl")!.displayString, "Double-tap ⌃")
        XCTAssertEqual(DropdownTrigger.parse("double-tap esc")!.displayString, "Double-tap Esc")
        XCTAssertTrue(DropdownTrigger.parse("double-tap esc")!.isDoubleTap)
        XCTAssertFalse(DropdownTrigger.parse("f12")!.isDoubleTap)
    }

    func testConfigAcceptsDoubleTapSpelling() {
        let c = Config.parse("[dropdown]\nhotkey = \"Double-Tap Ctrl\"\n")
        XCTAssertEqual(c.dropdownHotkey, "double-tap ctrl")
        XCTAssertEqual(Config.parse("[dropdown]\nhotkey = \"double-tap nope\"\n").dropdownHotkey, "ctrl+`")
    }
}

final class DoubleTapDetectorTests: XCTestCase {
    func testTwoQuickCleanTapsFire() {
        var d = DoubleTapDetector(window: 0.35)
        XCTAssertFalse(d.press(at: 1.00)); d.release(at: 1.05)
        XCTAssertTrue(d.press(at: 1.20))
        d.release(at: 1.25)
        // Starts over: the next single press does not fire.
        XCTAssertFalse(d.press(at: 1.30))
    }

    func testSlowTapsDoNotFire() {
        var d = DoubleTapDetector(window: 0.35)
        XCTAssertFalse(d.press(at: 1.0)); d.release(at: 1.1)
        XCTAssertFalse(d.press(at: 1.6)); d.release(at: 1.7)
        XCTAssertTrue(d.press(at: 1.9))  // second press relative to the 1.6 one
    }

    func testAnotherKeyInBetweenCancels() {
        var d = DoubleTapDetector(window: 0.35)
        XCTAssertFalse(d.press(at: 1.0))
        d.interrupt()          // ⌃C: a shortcut, not a tap
        d.release(at: 1.1)
        XCTAssertFalse(d.press(at: 1.2))
    }

    func testHeldKeyAndRepeatsAreOnePress() {
        var d = DoubleTapDetector(window: 0.35)
        XCTAssertFalse(d.press(at: 1.0))
        XCTAssertFalse(d.press(at: 1.1))   // key repeat while held
        XCTAssertFalse(d.press(at: 1.2))
        d.release(at: 1.25)
        XCTAssertTrue(d.press(at: 1.3))
    }

    func testReleaseAfterWindowForgetsTheFirstTap() {
        var d = DoubleTapDetector(window: 0.35)
        XCTAssertFalse(d.press(at: 1.0))
        d.release(at: 1.5)                 // held too long
        XCTAssertFalse(d.press(at: 1.6))
    }
}
