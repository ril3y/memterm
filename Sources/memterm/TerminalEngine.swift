import Foundation

// M0 deliverable: the engine seam drawn as a protocol (REQUIREMENTS.md §7.1).
// v0.1 backs this with SwiftTerm; the surface is deliberately small (~15 methods)
// so libghostty-vt can be evaluated as a drop-in post-1.0.
//
// SEAM STATUS (re-scoped at the Stage-2 audit): nothing conforms to this
// protocol yet. In the shipping v0 code the engine-swap seam is held by TWO
// concrete choke points instead, both deliberately narrow:
//   - capture: PaneView.scrollbackText(maxLines:) is the ONLY place the
//     persistence path touches SwiftTerm buffer internals (the pure assembly
//     lives in MemtermCore.ScrollbackText, engine-free);
//   - restore: ghost content goes through TerminalView.feed(text:) only
//     (TerminalWindowController.makeRestoredPane), never the pty.
// Swapping engines means reimplementing those two surfaces. Making PaneView
// conform to this protocol (serializeState/restoreGhostState) is the intended
// M3+ refactor; until then this file is the contract those choke points must
// converge to, not a description of current wiring.

/// A single cell run captured from the grid; attribute payload stays opaque to
/// the persistence layer (round-trips through the same engine that produced it).
struct GridSnapshot {
    var cols: Int
    var rows: Int
    var cursor: (col: Int, row: Int)
    /// Rendered lines of the visible grid, styled runs flattened to text for
    /// M0; M2 replaces this with attributed runs + a stable serialization.
    var visibleLines: [String]
}

/// OSC 133 semantic mark (FR-6, FR-19): prompt/command boundaries.
enum PromptMark {
    case promptStart          // OSC 133;A
    case commandStart         // OSC 133;B
    case outputStart          // OSC 133;C
    case commandEnd(exitCode: Int?)  // OSC 133;D
}

/// The seam between the app/persistence layers and the VT emulator.
protocol TerminalEngine: AnyObject {
    // -- Geometry --
    var cols: Int { get }
    var rows: Int { get }
    func resize(cols: Int, rows: Int)

    // -- Data path --
    /// Bytes read from the pty master; the engine parses and updates the grid.
    func feed(_ bytes: ArraySlice<UInt8>)
    /// Bytes the user produced (keystrokes, paste) headed to the pty master.
    var onDataToProcess: (([UInt8]) -> Void)? { get set }

    // -- Persistence hooks (M2 consumers) --
    func snapshotGrid() -> GridSnapshot
    /// Serialize scrollback + grid to a stable, versioned byte format.
    func serializeState() -> Data
    /// Restore a prior `serializeState()` payload as dimmed ghost content
    /// above the live grid (FR-24). Engine-version mismatches must degrade
    /// to plain-text ghost lines, never fail the pane.
    func restoreGhostState(_ data: Data) throws
    var scrollbackLineCount: Int { get }

    // -- Semantic events (capture engine inputs, FR-5/6/13) --
    var onTitleChange: ((String) -> Void)? { get set }
    var onCwdChange: ((String) -> Void)? { get set }        // OSC 7 / OSC 1337
    var onPromptMark: ((PromptMark) -> Void)? { get set }   // OSC 133
    var onBell: (() -> Void)? { get set }

    // -- Search (FR-4: one result set across ghost + live) --
    func search(_ needle: String, caseSensitive: Bool) -> Int  // match count for M0
}
