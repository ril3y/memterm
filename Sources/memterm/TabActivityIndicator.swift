import AppKit
import MemtermCore

// Founder UX stage (2026-08-31): live per-tab activity. Under the custom
// chrome the view renders FIRST-CLASS inside each TabItemView in our tab
// strip (it used to be squeezed into NSWindowTab.accessoryView): a small
// spinner while a non-selected tab's pty is producing output, decaying
// ~1.5 s after output stops to a solid "unseen output" dot that clears when
// the tab is selected. The pure state machine (decay + coalescing) is
// MemtermCore.TabActivityTracker; this is only its AppKit face.

final class TabActivityIndicatorView: NSView {
    private let spinner = NSProgressIndicator()
    private let dot = NSView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.frame = bounds
        spinner.autoresizingMask = [.width, .height]
        addSubview(spinner)

        dot.frame = NSRect(x: 5, y: 5, width: 6, height: 6)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.isHidden = true
        addSubview(dot)
        applyDotColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// FR-61: an agent badge recolors the dot (orange = needs you, green =
    /// finished unseen) or shows the spinner (working). `.none` = plain
    /// output activity, accent-colored as before.
    private(set) var agentBadge: AgentBadge = .none

    private func applyDotColor() {
        let color: NSColor
        switch agentBadge {
        case .blocked: color = .systemOrange
        case .done: color = .systemGreen
        default: color = .controlAccentColor
        }
        dot.layer?.backgroundColor = color.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyDotColor()
    }

    /// Agent badges outrank plain output activity (FR-61 precedence:
    /// blocked > done > working > output).
    func apply(state: TabActivityState, agent: AgentBadge) {
        agentBadge = agent
        applyDotColor()
        switch agent {
        case .blocked, .done:
            spinner.stopAnimation(nil)
            dot.isHidden = false
        case .working:
            dot.isHidden = true
            spinner.startAnimation(nil)
        case .none:
            apply(state: state)
        }
    }

    func apply(state: TabActivityState) {
        switch state {
        case .idle:
            spinner.stopAnimation(nil)
            dot.isHidden = true
        case .active:
            dot.isHidden = true
            spinner.startAnimation(nil)
        case .unseen:
            spinner.stopAnimation(nil)
            dot.isHidden = false
        }
    }
}
