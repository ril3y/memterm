import XCTest
@testable import MemtermCore

/// FR-61 detection: herdr's screen rules (ported) classify an agent pane as
/// working / blocked / idle from its terminal title and visible screen.
final class AgentStatusTests: XCTestCase {

    private func detect(_ kind: AgentKind, title: String = "", _ lines: [String]) -> AgentDetection {
        AgentStatusDetector.detect(kind: kind, title: title, screen: lines.joined(separator: "\n"))
    }

    // MARK: Agent kinds

    func testAgentKindFromAdapterName() {
        XCTAssertEqual(AgentKind(adapterName: "claude"), .claude)
        XCTAssertEqual(AgentKind(adapterName: "codex"), .codex)
        XCTAssertEqual(AgentKind(adapterName: "gemini"), .gemini)
        XCTAssertNil(AgentKind(adapterName: "ssh"))
        XCTAssertNil(AgentKind(adapterName: ""))
    }

    func testEveryPortedRuleCompiles() {
        for kind in AgentKind.allCases {
            XCTAssertEqual(AgentRules.compileFailures(for: kind), [],
                           "\(kind) rules must all compile under ICU")
            XCTAssertFalse(AgentRules.rules(for: kind).isEmpty)
        }
    }

    // MARK: Regions

    func testBottomNonEmptyLinesSkipsBlankLines() {
        let text = "a\nb\n\nc\n\n"
        XCTAssertEqual(AgentRegions.bottomNonEmptyLines(text, 2), "b\n\nc\n\n")
    }

    func testAfterLastHorizontalRule() {
        XCTAssertEqual(AgentRegions.afterLastHorizontalRule("x\n────\ny\n───\nz"), "z")
        XCTAssertEqual(AgentRegions.afterLastHorizontalRule("no rules"), "no rules")
    }

    func testPromptBoxBodyIsBetweenTheLastTwoRules() {
        let text = "out\n─────\n❯ hi\n─────\n  ? for shortcuts"
        XCTAssertEqual(AgentRegions.promptBoxBody(text), "❯ hi\n")
        XCTAssertNil(AgentRegions.promptBoxBody("one\n─────\nrule"))
    }

    // MARK: Claude Code

    func testClaudeBashPermissionPromptIsBlocked() {
        let d = detect(.claude, [
            "⏺ I'll clean the build directory.",
            "",
            "────────────────────────────────────────",
            " Bash command",
            "",
            "   rm -rf build",
            "   Remove build output",
            "",
            " Do you want to proceed?",
            " ❯ 1. Yes",
            "   2. Yes, and don't ask again for rm commands in /tmp/x",
            "   3. No, and tell Claude what to do differently (esc)",
        ])
        XCTAssertEqual(d.state, .blocked)
        XCTAssertTrue(d.visibleBlocker)
    }

    func testClaudeLiveTurnIsWorking() {
        let d = detect(.claude, [
            "⏺ Reading files.",
            "",
            "✻ Pondering… (12s · ↑ 1.2k tokens · esc to interrupt)",
            "",
            "────────────────────────────────────────",
            "❯ ",
            "────────────────────────────────────────",
            "  ⏵⏵ accept edits on (shift+tab to cycle)",
        ])
        XCTAssertEqual(d.state, .working)
    }

    func testClaudeSpinnerTitleIsWorking() {
        XCTAssertEqual(detect(.claude, title: "⠂ Claude Code", ["anything"]).state, .working)
        XCTAssertEqual(detect(.claude, title: "◐ Claude Code", ["anything"]).state, .working)
    }

    func testClaudePromptBoxIsVisiblyIdle() {
        let d = detect(.claude, title: "✳ Claude Code", [
            "⏺ Done.",
            "",
            "────────────────────────────────────────",
            "❯ ",
            "────────────────────────────────────────",
            "  ? for shortcuts",
        ])
        XCTAssertEqual(d.state, .idle)
        XCTAssertTrue(d.visibleIdle)
    }

    func testClaudeTranscriptViewerSkipsTheUpdate() {
        let d = detect(.claude, [
            "⏺ earlier output",
            "Showing detailed transcript · ctrl+o to toggle",
        ])
        XCTAssertTrue(d.skipUpdate)
    }

    func testKnownAgentWithNoMatchingRuleIsPlainIdle() {
        let d = detect(.claude, ["just some text"])
        XCTAssertEqual(d.state, .idle)
        XCTAssertFalse(d.visibleIdle)
        XCTAssertNil(d.ruleId)
    }

    // MARK: Codex

    func testCodexActionRequiredTitleIsBlocked() {
        XCTAssertEqual(detect(.codex, title: "Action Required", ["x"]).state, .blocked)
    }

    func testCodexSpinnerTitleIsWorking() {
        XCTAssertEqual(detect(.codex, title: "⠋ codex", ["x"]).state, .working)
    }

    func testCodexPlainTitleIsIdle() {
        let d = detect(.codex, title: "codex", ["x"])
        XCTAssertEqual(d.state, .idle)
        XCTAssertTrue(d.visibleIdle)
    }

    func testCodexTrustDialogIsBlocked() {
        let d = detect(.codex, [
            "> You are in /Users/me/proj",
            "",
            "  Do you trust the contents of this directory? Working with untrusted contents comes with higher risk.",
            "",
            "› 1. Yes, continue",
            "  2. No, quit",
            "",
            "  Press enter to continue",
        ])
        XCTAssertEqual(d.state, .blocked)
    }

    func testCodexLiveTimerAbovePromptIsWorking() {
        let d = detect(.codex, [
            "• Ran ls",
            "",
            "• Working (12s • esc to interrupt)",
            "",
            "› Ask Codex to do anything",
        ])
        XCTAssertEqual(d.state, .working)
    }

    // MARK: Gemini

    func testGeminiApplyChangeIsBlocked() {
        let d = detect(.gemini, [
            "╭──────────────────────────╮",
            "│ Apply this change?        │",
            "│ ● 1. Yes, allow once      │",
            "╰──────────────────────────╯",
        ])
        XCTAssertEqual(d.state, .blocked)
    }

    func testGeminiEscToCancelIsWorking() {
        XCTAssertEqual(detect(.gemini, ["⠏ Thinking… (esc to cancel, 3s)"]).state, .working)
    }

    func testGeminiQuietScreenIsIdle() {
        XCTAssertEqual(detect(.gemini, ["> Type your message"]).state, .idle)
    }
}

/// OSC 7501 (herdr's Program Status Protocol) payload parsing.
final class ProgramStatusTests: XCTestCase {

    func testParsesStateKindProgressAndBase64Fields() {
        let title = Data("Build".utf8).base64EncodedString()
        let s = ProgramStatus.parse("state=blocked:kind=permission:progress=40:app=mytool:title=\(title)")
        XCTAssertEqual(s?.state, "blocked")
        XCTAssertEqual(s?.kind, "permission")
        XCTAssertEqual(s?.progress, 40)
        XCTAssertEqual(s?.app, "mytool")
        XCTAssertEqual(s?.title, "Build")
        XCTAssertEqual(s?.agentState, .blocked)
    }

    func testStateWordsMapToAgentStates() {
        XCTAssertEqual(ProgramStatus.parse("state=working")?.agentState, .working)
        XCTAssertEqual(ProgramStatus.parse("state=error")?.agentState, .blocked)
        XCTAssertEqual(ProgramStatus.parse("state=done")?.agentState, .idle)
        XCTAssertEqual(ProgramStatus.parse("state=idle")?.agentState, .idle)
        XCTAssertTrue(ProgramStatus.parse("state=clear")?.isClear ?? false)
        XCTAssertNil(ProgramStatus.parse("state=dancing")?.agentState)
    }

    func testRejectsGarbage() {
        XCTAssertNil(ProgramStatus.parse(""))
        XCTAssertNil(ProgramStatus.parse("kind=permission"), "state is required")
        XCTAssertNil(ProgramStatus.parse(String(repeating: "x", count: 10_000)))
        XCTAssertEqual(ProgramStatus.parse("state=working:progress=900")?.progress, nil,
                       "progress outside 0...100 is dropped")
    }

    func testSubRecordsAreMarked() {
        XCTAssertTrue(ProgramStatus.parse("state=working:id=build")?.isSubRecord ?? false)
        XCTAssertFalse(ProgramStatus.parse("state=working")?.isSubRecord ?? true)
    }
}

/// FR-61 done/hysteresis + FR-62 alert rule.
final class AgentAttentionTests: XCTestCase {

    private func det(_ s: AgentState, visibleIdle: Bool = false, visibleBlocker: Bool = false,
                     skip: Bool = false) -> AgentDetection {
        AgentDetection(state: s, skipUpdate: skip, visibleIdle: visibleIdle,
                       visibleBlocker: visibleBlocker, ruleId: nil)
    }

    func testEnteringBlockedAlwaysAlerts() {
        var t = AgentAttentionTracker()
        XCTAssertNil(t.observe(pane: "p", kind: .claude, detection: det(.working), looking: true, now: 0))
        XCTAssertEqual(t.observe(pane: "p", kind: .claude, detection: det(.blocked, visibleBlocker: true),
                                 looking: true, now: 1), .blocked)
        XCTAssertEqual(t.badge(of: "p"), .blocked)
        XCTAssertNil(t.observe(pane: "p", kind: .claude, detection: det(.blocked), looking: true, now: 2),
                       "staying blocked does not alert again")
    }

    func testFinishingAlertsOnlyWhenNotLooking() {
        var t = AgentAttentionTracker()
        _ = t.observe(pane: "a", kind: .claude, detection: det(.working), looking: false, now: 0)
        XCTAssertEqual(t.observe(pane: "a", kind: .claude, detection: det(.idle, visibleIdle: true),
                                 looking: false, now: 1), .done)
        XCTAssertEqual(t.badge(of: "a"), .done)
        XCTAssertEqual(t.needsYouCount, 1)

        _ = t.observe(pane: "b", kind: .codex, detection: det(.working), looking: true, now: 0)
        XCTAssertNil(t.observe(pane: "b", kind: .codex, detection: det(.idle, visibleIdle: true),
                               looking: true, now: 1))
        XCTAssertEqual(t.badge(of: "b"), .none)
    }

    func testMarkSeenClearsDone() {
        var t = AgentAttentionTracker()
        _ = t.observe(pane: "a", kind: .claude, detection: det(.working), looking: false, now: 0)
        _ = t.observe(pane: "a", kind: .claude, detection: det(.idle, visibleIdle: true), looking: false, now: 1)
        XCTAssertTrue(t.markSeen(pane: "a"))
        XCTAssertEqual(t.badge(of: "a"), .none)
        XCTAssertEqual(t.needsYouCount, 0)
        XCTAssertFalse(t.markSeen(pane: "a"), "nothing left to clear")
    }

    func testWorkingToPlainIdleWaitsForConfirmation() {
        var t = AgentAttentionTracker()
        _ = t.observe(pane: "a", kind: .claude, detection: det(.working), looking: false, now: 0)
        XCTAssertNil(t.observe(pane: "a", kind: .claude, detection: det(.idle), looking: false, now: 0.1))
        XCTAssertEqual(t.badge(of: "a"), .working, "a gap between tool calls is not 'done'")
        XCTAssertNil(t.observe(pane: "a", kind: .claude, detection: det(.working), looking: false, now: 0.2))
        XCTAssertEqual(t.badge(of: "a"), .working)
        // A real finish: plain idle held past the 700 ms cap.
        XCTAssertNil(t.observe(pane: "a", kind: .claude, detection: det(.idle), looking: false, now: 1.0))
        XCTAssertEqual(t.observe(pane: "a", kind: .claude, detection: det(.idle), looking: false, now: 1.8), .done)
    }

    func testPlainIdleAppliesAfterThreeConfirmations() {
        var t = AgentAttentionTracker()
        _ = t.observe(pane: "a", kind: .claude, detection: det(.working), looking: true, now: 0)
        for i in 1...3 {
            _ = t.observe(pane: "a", kind: .claude, detection: det(.idle), looking: true, now: Double(i) * 0.1)
            XCTAssertEqual(t.badge(of: "a"), .working)
        }
        _ = t.observe(pane: "a", kind: .claude, detection: det(.idle), looking: true, now: 0.4)
        XCTAssertEqual(t.badge(of: "a"), .none)
    }

    func testSkipUpdateKeepsThePreviousState() {
        var t = AgentAttentionTracker()
        _ = t.observe(pane: "a", kind: .claude, detection: det(.blocked), looking: true, now: 0)
        XCTAssertNil(t.observe(pane: "a", kind: .claude, detection: det(.unknown, skip: true), looking: true, now: 1))
        XCTAssertEqual(t.badge(of: "a"), .blocked)
    }

    func testAgentExitClearsWithoutAlert() {
        var t = AgentAttentionTracker()
        _ = t.observe(pane: "a", kind: .claude, detection: det(.blocked), looking: false, now: 0)
        XCTAssertNil(t.observe(pane: "a", kind: nil, detection: nil, looking: false, now: 1))
        XCTAssertEqual(t.badge(of: "a"), .none)
        XCTAssertEqual(t.needsYouCount, 0)
    }

    func testAgentChangeResetsState() {
        var t = AgentAttentionTracker()
        _ = t.observe(pane: "a", kind: .claude, detection: det(.working), looking: false, now: 0)
        XCTAssertNil(t.observe(pane: "a", kind: .codex, detection: det(.idle, visibleIdle: true),
                               looking: false, now: 1), "a different agent starting is not a finish")
        XCTAssertEqual(t.badge(of: "a"), .none)
    }

    func testWorkingAgainClearsAStaleDone() {
        var t = AgentAttentionTracker()
        _ = t.observe(pane: "a", kind: .claude, detection: det(.working), looking: false, now: 0)
        _ = t.observe(pane: "a", kind: .claude, detection: det(.idle, visibleIdle: true), looking: false, now: 1)
        _ = t.observe(pane: "a", kind: .claude, detection: det(.working), looking: false, now: 2)
        XCTAssertEqual(t.badge(of: "a"), .working)
        XCTAssertEqual(t.needsYouCount, 0)
    }

    func testNeedsYouCountsBlockedAndUnseenDone() {
        var t = AgentAttentionTracker()
        _ = t.observe(pane: "a", kind: .claude, detection: det(.blocked), looking: false, now: 0)
        _ = t.observe(pane: "b", kind: .gemini, detection: det(.working), looking: false, now: 0)
        _ = t.observe(pane: "b", kind: .gemini, detection: det(.idle, visibleIdle: true), looking: false, now: 1)
        _ = t.observe(pane: "c", kind: .codex, detection: det(.working), looking: false, now: 0)
        XCTAssertEqual(t.needsYouCount, 2)
    }

    func testIdleFromStartDoesNotAlert() {
        var t = AgentAttentionTracker()
        XCTAssertNil(t.observe(pane: "a", kind: .claude, detection: det(.idle, visibleIdle: true),
                               looking: false, now: 0))
        XCTAssertEqual(t.badge(of: "a"), .none)
    }

    func testSelectedTabShowsOnlyBlocked() {
        XCTAssertEqual(AgentBadge.blocked.shownOnTab(selected: true), .blocked,
                       "a waiting agent stays visible on the tab you're on")
        XCTAssertEqual(AgentBadge.working.shownOnTab(selected: true), .none)
        XCTAssertEqual(AgentBadge.done.shownOnTab(selected: true), .none)
        XCTAssertEqual(AgentBadge.working.shownOnTab(selected: false), .working)
        XCTAssertEqual(AgentBadge.done.shownOnTab(selected: false), .done)
    }

    func testBadgeRollupPrefersBlockedThenDoneThenWorking() {
        XCTAssertEqual(AgentBadge.strongest([.working, .done, .none]), .done)
        XCTAssertEqual(AgentBadge.strongest([.working, .blocked, .done]), .blocked)
        XCTAssertEqual(AgentBadge.strongest([.none, .working]), .working)
        XCTAssertEqual(AgentBadge.strongest([]), .none)
    }
}
