import Foundation

/// Founder polish (2026-09-01): a NEW workspace gets a RANDOM preset color —
/// picked from the presets no existing workspace is using, so early
/// workspaces are visually distinct; only when every preset is taken does the
/// pick fall back to any preset. The candidate math is a pure seam
/// (TESTING.md §1 placement rule); the app layer draws the actual random
/// element (app code may use randomness freely — randomness itself is not
/// under test, the candidate set is).
public enum WorkspaceColorPick {
    /// The colors a new workspace may be given: `presets` minus `used`, or
    /// all of `presets` when that difference is empty. Preserves preset
    /// order; never returns an empty array unless `presets` is empty.
    public static func candidates(presets: [String], used: [String]) -> [String] {
        let taken = Set(used)
        let unused = presets.filter { !taken.contains($0) }
        return unused.isEmpty ? presets : unused
    }
}
