import XCTest
@testable import MemtermCore

/// Founder bug 2026-10-24: "if you try to make the window slimmer but have
/// lots of workspaces it won't allow it". The chip row held its full natural
/// width, so it set the window's minimum width. The bar now compacts in a
/// fixed order instead, and every step is checked here: drop the
/// "Workspaces:" title, shorten the other chips to initials, then to bare
/// color dots, then shorten the active chip's name, then move chips from the
/// end into an overflow menu. The active chip is never moved into overflow.
final class WorkspaceBarCompactionTests: XCTestCase {

    // Widths chosen so each ladder step has a clear threshold:
    // title 70, add 20, overflow 20, spacing 6.
    // Chips: full 100, initials 40, dot 22; active "a" full 120.
    private func chip(_ id: String, active: Bool = false, full: Double = 100) -> WorkspaceBarCompaction.Chip {
        WorkspaceBarCompaction.Chip(id: id, fullWidth: active ? 120 : full,
                                    initialsWidth: 40, dotWidth: 22, isActive: active)
    }

    private var three: [WorkspaceBarCompaction.Chip] {
        [chip("a", active: true), chip("b"), chip("c")]
    }

    private func plan(_ available: Double,
                      _ chips: [WorkspaceBarCompaction.Chip]? = nil) -> WorkspaceBarCompaction.Plan {
        WorkspaceBarCompaction.plan(available: available, titleWidth: 70, addWidth: 20,
                                    overflowWidth: 20, spacing: 6, minActiveWidth: 50,
                                    chips: chips ?? three)
    }

    /// The width the plan's visible items need, recomputed independently so
    /// the "it fits" claim is checked, not trusted.
    private func usedWidth(_ p: WorkspaceBarCompaction.Plan,
                           _ chips: [WorkspaceBarCompaction.Chip]? = nil) -> Double {
        var widths: [Double] = []
        if p.showTitle { widths.append(70) }
        for c in chips ?? three where !p.overflow.contains(c.id) {
            switch p.modes[c.id]! {
            case .full: widths.append(c.isActive ? min(c.fullWidth, p.activeMaxWidth ?? .infinity) : c.fullWidth)
            case .initials: widths.append(c.initialsWidth)
            case .dot: widths.append(c.dotWidth)
            }
        }
        if !p.overflow.isEmpty { widths.append(20) }
        widths.append(20)
        return widths.reduce(0, +) + 6 * Double(widths.count - 1)
    }

    // natural: 70 + 120 + 100 + 100 + 20 + 4*6 = 434
    func testEverythingFullWhenItFits() {
        let p = plan(434)
        XCTAssertTrue(p.showTitle)
        XCTAssertEqual(p.modes, ["a": .full, "b": .full, "c": .full])
        XCTAssertNil(p.activeMaxWidth)
        XCTAssertEqual(p.overflow, [])
    }

    // without title: 120 + 100 + 100 + 20 + 3*6 = 358
    func testTheTitleGoesFirst() {
        let p = plan(433)
        XCTAssertFalse(p.showTitle)
        XCTAssertEqual(p.modes, ["a": .full, "b": .full, "c": .full])
        XCTAssertLessThanOrEqual(usedWidth(p), 433)
    }

    // initials: 120 + 40 + 40 + 20 + 18 = 238
    func testOtherChipsShortenToInitialsNext() {
        let p = plan(357)
        XCTAssertFalse(p.showTitle)
        XCTAssertEqual(p.modes, ["a": .full, "b": .initials, "c": .initials])
        XCTAssertLessThanOrEqual(usedWidth(p), 357)
    }

    // dots: 120 + 22 + 22 + 20 + 18 = 202
    func testOtherChipsBecomeDotsAfterThat() {
        let p = plan(237)
        XCTAssertEqual(p.modes, ["a": .full, "b": .dot, "c": .dot])
        XCTAssertNil(p.activeMaxWidth)
        XCTAssertLessThanOrEqual(usedWidth(p), 237)
    }

    func testTheActiveNameShortensOnlyOnceTheOthersAreDots() {
        let p = plan(190)
        XCTAssertEqual(p.modes, ["a": .full, "b": .dot, "c": .dot])
        XCTAssertEqual(p.activeMaxWidth, 108)  // 190 - (22 + 22 + 20 + 18)
        XCTAssertEqual(p.overflow, [])
        XCTAssertLessThanOrEqual(usedWidth(p), 190)
    }

    // min active, two dots: 50 + 22 + 22 + 20 + 18 = 132.
    // Overflow one: 50 + 22 + 20(overflow) + 20 + 18 = 130.
    func testChipsMoveFromTheEndIntoOverflowLast() {
        let p = plan(131)
        XCTAssertEqual(p.overflow, ["c"])
        XCTAssertEqual(p.modes["b"], .dot)
        XCTAssertEqual(p.activeMaxWidth, 51)  // all the room that is left
        XCTAssertLessThanOrEqual(usedWidth(p), 131)
    }

    func testTheActiveChipIsNeverMovedIntoOverflowEvenWhenItIsLast() {
        let chips = [chip("b"), chip("c"), chip("a", active: true)]
        let p = plan(100, chips)
        XCTAssertFalse(p.overflow.contains("a"))
        XCTAssertEqual(p.overflow, ["b", "c"])  // listed in bar order
    }

    /// Too narrow for even the active chip at its minimum: everything else
    /// overflows and the plan stops there (the bar clips; the window is
    /// never held open by it).
    func testNarrowerThanTheMinimumOverflowsEverythingElse() {
        let p = plan(10)
        XCTAssertEqual(p.overflow, ["b", "c"])
        XCTAssertEqual(p.activeMaxWidth, 50)
    }

    /// An active name already shorter than the room left is not "shortened".
    func testAShortActiveNameIsNotCapped() {
        let chips = [WorkspaceBarCompaction.Chip(id: "a", fullWidth: 45, initialsWidth: 30,
                                                 dotWidth: 22, isActive: true),
                     chip("b")]
        let p = plan(100, chips)  // full 177, initials 117: too wide; dots 99 fits
        XCTAssertEqual(p.modes["b"], .dot)
        XCTAssertNil(p.activeMaxWidth)
    }

    func testNoChipsAtAll() {
        let p = plan(50, [])
        XCTAssertEqual(p.modes, [:])
        XCTAssertEqual(p.overflow, [])
    }

    // MARK: - Initials

    func testInitialsFromSeparatedWords() {
        XCTAssertEqual(WorkspaceBarCompaction.initials(for: "memterm tools"), "MT")
        XCTAssertEqual(WorkspaceBarCompaction.initials(for: "remote-attach"), "RA")
        XCTAssertEqual(WorkspaceBarCompaction.initials(for: "fix_the_bar_now"), "FTB")
        XCTAssertEqual(WorkspaceBarCompaction.initials(for: "  spaced   out  "), "SO")
    }

    func testInitialsFromCamelCase() {
        XCTAssertEqual(WorkspaceBarCompaction.initials(for: "SmartFoodie"), "SF")
    }

    func testASingleWordKeepsTwoLetters() {
        XCTAssertEqual(WorkspaceBarCompaction.initials(for: "default"), "De")
        XCTAssertEqual(WorkspaceBarCompaction.initials(for: "x"), "X")
    }

    func testDigitsAndNonLatinNamesSurvive() {
        XCTAssertEqual(WorkspaceBarCompaction.initials(for: "Project 2"), "P2")
        XCTAssertEqual(WorkspaceBarCompaction.initials(for: "日本語"), "日本")
        XCTAssertEqual(WorkspaceBarCompaction.initials(for: "🚀 launch"), "🚀L")
    }

    func testAnEmptyNameGivesAPlaceholder() {
        XCTAssertEqual(WorkspaceBarCompaction.initials(for: "   "), "•")
    }
}
