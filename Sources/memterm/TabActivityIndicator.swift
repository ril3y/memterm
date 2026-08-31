import AppKit
import MemtermCore

// Founder UX stage (2026-08-31): live activity in the native tab bar. The
// view goes into NSWindowTab.accessoryView (public AppKit API — verified in
// the macOS SDK's NSWindowTab.h): a small spinner while a non-selected tab's
// pty is producing output, decaying ~1.5 s after output stops to a solid
// "unseen output" dot that clears when the tab is selected. The pure state
// machine (decay + coalescing) is MemtermCore.TabActivityTracker; this is
// only its AppKit face.

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

    private func applyDotColor() {
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyDotColor()
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
