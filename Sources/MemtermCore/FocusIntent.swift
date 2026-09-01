import Foundation

// L2 headless seam (TESTING.md §2): the focus contract as a state machine.
// "Where must the keyboard land after <gesture>?" used to live only in probe
// assertions (and shipped wrong twice: the rename-commit handoff race, the
// close-pane focus loss). The machine is the intent; the probe's focus steps
// verify AppKit's firstResponder actually obeys it after every gesture.
public enum FocusTarget: Equatable, CustomStringConvertible {
    /// The selected tab's focused pane — the resting state: keystrokes reach
    /// the terminal.
    case pane
    /// An inline rename's field editor (workspace chip or tab rename sheet).
    case renameEditor

    public var description: String {
        switch self {
        case .pane: return "pane"
        case .renameEditor: return "renameEditor"
        }
    }
}

public struct FocusIntent: Equatable {
    public enum Event {
        case selectTab
        case switchWorkspace
        case beginRename
        case commitRename
        case cancelRename
        case closePane
        case closeTab
    }

    public private(set) var target: FocusTarget = .pane

    public init() {}

    /// Applies a gesture; returns the expected first-responder target after
    /// AppKit settles. Every path except beginRename returns the keyboard to
    /// the pane — that IS the contract the shipped bugs violated.
    @discardableResult
    public mutating func apply(_ event: Event) -> FocusTarget {
        switch event {
        case .beginRename:
            target = .renameEditor
        case .selectTab, .switchWorkspace, .commitRename, .cancelRename,
             .closePane, .closeTab:
            target = .pane
        }
        return target
    }
}
