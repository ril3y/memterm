import Foundation

// M0 deliverable: the engine seam drawn as a protocol (REQUIREMENTS.md §7.1).
// v0.1 backs this with SwiftTerm; the surface is deliberately small (~15 methods)
// so libghostty-vt can be evaluated as a drop-in post-1.0.
//
// The persistence engine (M2) talks ONLY to this protocol — never to SwiftTerm
// types directly — because serializing grid + scrollback is the killer feature
// and must not be entangled with one emulator's internals.

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
