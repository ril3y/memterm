import Foundation

/// Where the workspace bar sits (spec 2026-10-02 §3/§7). `top` is the row
/// above the tab strip; `left`/`right` are a sidebar under the tab strip.
public enum WorkspaceBarPosition: String, CaseIterable, Sendable {
    case top, left, right

    /// Which coordinate runs along the bar.
    public var axis: WorkspaceBarDrop.Axis { self == .top ? .horizontal : .vertical }
}

/// How a workspace chip is drawn when the bar is short of room.
public enum WorkspaceChipMode: Equatable, Sendable {
    /// Color dot + full name (+ the hover ✕).
    case full
    /// Color dot + initials, e.g. "MT" for "memterm tools".
    case initials
    /// The color dot alone; the name lives in the tooltip.
    case dot
}

/// Fits the workspace bar's chip row into the width it has.
///
/// Founder bug 2026-10-24: with many workspaces the window refused to get
/// narrower, because the chip row held its full natural width and so set the
/// window's minimum. The row now gives up room in a fixed order, cheapest
/// loss first:
///
/// 1. drop the "Workspaces:" title,
/// 2. shorten every other chip to initials,
/// 3. then to bare color dots,
/// 4. shorten the active chip's name (never below `minActiveWidth`),
/// 5. move chips from the end into an overflow menu.
///
/// The active chip is never moved into overflow: it is what the window is
/// showing. Below even that, the bar clips; it never holds the window open.
public enum WorkspaceBarCompaction {

    public struct Chip: Equatable, Sendable {
        public let id: String
        public let fullWidth: Double
        public let initialsWidth: Double
        public let dotWidth: Double
        public let isActive: Bool

        public init(id: String, fullWidth: Double, initialsWidth: Double,
                    dotWidth: Double, isActive: Bool) {
            self.id = id
            self.fullWidth = fullWidth
            self.initialsWidth = initialsWidth
            self.dotWidth = dotWidth
            self.isActive = isActive
        }
    }

    public struct Plan: Equatable, Sendable {
        public var showTitle: Bool
        /// Every chip's mode, overflowed ones included (they keep the mode
        /// they had, which the bar ignores).
        public var modes: [String: WorkspaceChipMode]
        /// The active chip's width cap, or nil when it shows in full.
        public var activeMaxWidth: Double?
        /// Ids moved into the overflow menu, in bar order.
        public var overflow: [String]
    }

    public static func plan(available: Double, titleWidth: Double, addWidth: Double,
                            overflowWidth: Double, spacing: Double, minActiveWidth: Double,
                            chips: [Chip]) -> Plan {
        func rowWidth(_ widths: [Double]) -> Double {
            widths.reduce(0, +) + spacing * Double(max(widths.count - 1, 0))
        }
        func modes(_ inactive: WorkspaceChipMode) -> [String: WorkspaceChipMode] {
            Dictionary(uniqueKeysWithValues: chips.map { ($0.id, $0.isActive ? .full : inactive) })
        }
        func width(_ chip: Chip, _ mode: WorkspaceChipMode) -> Double {
            switch mode {
            case .full: return chip.fullWidth
            case .initials: return chip.initialsWidth
            case .dot: return chip.dotWidth
            }
        }

        // Steps 1-3: whole-row modes, checked in order.
        let attempts: [(Bool, WorkspaceChipMode)] = [(true, .full), (false, .full),
                                                    (false, .initials), (false, .dot)]
        for (showTitle, inactive) in attempts {
            let m = modes(inactive)
            var widths = showTitle ? [titleWidth] : []
            widths += chips.map { width($0, m[$0.id]!) }
            widths.append(addWidth)
            if rowWidth(widths) <= available {
                return Plan(showTitle: showTitle, modes: m, activeMaxWidth: nil, overflow: [])
            }
        }

        // Steps 4-5: the others are dots. Give the active chip whatever room
        // is left; while that is under its minimum, overflow from the end.
        let dotModes = modes(.dot)
        let active = chips.first(where: \.isActive)
        var overflow: [String] = []
        var candidates = chips.filter { !$0.isActive }
        while true {
            let shown = chips.filter { !$0.isActive && !overflow.contains($0.id) }
            var others = shown.map(\.dotWidth)
            if !overflow.isEmpty { others.append(overflowWidth) }
            others.append(addWidth)
            guard let active else {
                if rowWidth(others) <= available || candidates.isEmpty {
                    return Plan(showTitle: false, modes: dotModes, activeMaxWidth: nil,
                                overflow: overflow)
                }
                overflow.insert(candidates.removeLast().id, at: 0)
                continue
            }
            // The active chip's slot costs one more spacing.
            let room = available - rowWidth(others) - spacing
            if room >= minActiveWidth || candidates.isEmpty {
                let cap = max(room, minActiveWidth)
                return Plan(showTitle: false, modes: dotModes,
                            activeMaxWidth: cap < active.fullWidth ? cap : nil,
                            overflow: chips.map(\.id).filter { overflow.contains($0) })
            }
            overflow.append(candidates.removeLast().id)
        }
    }

    // MARK: - Initials

    /// Short form of a workspace name: the first letters of up to three
    /// words (words split on spaces, punctuation and camelCase humps), or
    /// the first two characters of a one-word name.
    public static func initials(for name: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var words: [String] = []
        for part in name.unicodeScalars.split(whereSeparator: { separators.contains($0) }) {
            words += splitCamelCase(String(String.UnicodeScalarView(part)))
        }
        guard let first = words.first else { return "•" }
        if words.count == 1 {
            let chars = Array(first)
            let head = String(chars[0]).uppercased()
            return chars.count > 1 ? head + String(chars[1]) : head
        }
        return words.prefix(3).map { String($0.first!).uppercased() }.joined()
    }

    /// "SmartFoodie" → ["Smart", "Foodie"]: a word starts at an uppercase
    /// letter that follows a lowercase one.
    private static func splitCamelCase(_ word: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var previousWasLower = false
        for c in word {
            if c.isUppercase, previousWasLower, !current.isEmpty {
                parts.append(current)
                current = ""
            }
            current.append(c)
            previousWasLower = c.isLowercase
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    // MARK: - Sidebar (vertical axis)

    public struct VerticalPlan: Equatable, Sendable {
        public var showTitle: Bool
        /// Ids moved into the overflow menu, in bar order.
        public var overflow: [String]
    }

    /// Fits a top-down chip column into `available` height. Every chip has
    /// the column's full width, so only the count matters: drop the title
    /// first, then move chips from the end into overflow (the overflow
    /// button then takes a row of its own). The active chip never overflows.
    public static func verticalPlan(available: Double, titleHeight: Double, addHeight: Double,
                                    overflowHeight: Double, chipHeight: Double, spacing: Double,
                                    chips: [(id: String, isActive: Bool)]) -> VerticalPlan {
        func height(title: Bool, visibleChips: Int, overflow: Bool) -> Double {
            var heights: [Double] = title ? [titleHeight] : []
            heights += Array(repeating: chipHeight, count: visibleChips)
            if overflow { heights.append(overflowHeight) }
            heights.append(addHeight)
            return heights.reduce(0, +) + spacing * Double(max(heights.count - 1, 0))
        }
        if height(title: true, visibleChips: chips.count, overflow: false) <= available {
            return VerticalPlan(showTitle: true, overflow: [])
        }
        if height(title: false, visibleChips: chips.count, overflow: false) <= available {
            return VerticalPlan(showTitle: false, overflow: [])
        }
        // Overflow candidates, last first; the active chip is never one.
        let candidates = chips.reversed().filter { !$0.isActive }.map(\.id)
        var overflowed: Set<String> = []
        for id in candidates {
            overflowed.insert(id)
            if height(title: false, visibleChips: chips.count - overflowed.count,
                      overflow: true) <= available { break }
        }
        return VerticalPlan(showTitle: false,
                            overflow: chips.map(\.id).filter { overflowed.contains($0) })
    }
}
