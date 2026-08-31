import AppKit
import MemtermCore
import SwiftTerm

// FR-4: per-pane ⌘F search. Live output and restored ghost scrollback are one
// continuous result set because restore feed()s ghost lines into the same
// buffer the search walks. Everything here is read-only with respect to the
// terminal: SwiftTerm's search reads buffer lines and moves the selection —
// nothing is ever written to the pty and the buffer is never mutated.
//
// SwiftTerm ships its own find bar, but it is `internal` (no match-count
// label, no extension points), so this is a minimal overlay on the public
// search API: findNext / findPrevious / searchMatchSummary / clearSearch.

/// Small find bar pinned to the top-right of one pane: search field,
/// prev/next, match counter, close. Esc closes; Enter/⇧Enter step matches.
final class PaneFindBar: NSVisualEffectView, NSSearchFieldDelegate {
    var onSearchChanged: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    var searchText: String {
        get { searchField.stringValue }
        set { searchField.stringValue = newValue }
    }

    func setMatchLabel(_ text: String) {
        countLabel.stringValue = text
    }

    func focus() {
        window?.makeFirstResponder(searchField)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        material = .popover
        blendingMode = .withinWindow
        state = .active
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        searchField.placeholderString = "Find"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        configureButton(previousButton, symbol: "chevron.up", tooltip: "Previous Match (⌘⇧G)",
                        action: #selector(previousTapped))
        configureButton(nextButton, symbol: "chevron.down", tooltip: "Next Match (⌘G)",
                        action: #selector(nextTapped))
        configureButton(closeButton, symbol: "xmark", tooltip: "Close (Esc)",
                        action: #selector(closeTapped))

        let stack = NSStackView(views: [searchField, countLabel, previousButton,
                                        nextButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    private func configureButton(_ button: NSButton, symbol: String, tooltip: String,
                                 action: Selector) {
        button.bezelStyle = .texturedRounded
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.toolTip = tooltip
        button.target = self
        button.action = action
    }

    @objc private func previousTapped() { onPrevious?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func closeTapped() { onClose?() }

    func controlTextDidChange(_ obj: Notification) {
        onSearchChanged?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        }
        return false
    }
}

// MARK: - PaneView search plumbing

extension PaneView {

    /// ⌘F: show (or refocus) this pane's find bar, seeded from a compact
    /// single-line selection when there is one.
    func openFindBar() {
        let bar = findBar ?? installFindBar()
        bar.isHidden = false
        if let term = FindSupport.prefillTerm(fromSelection: getSelection()) {
            bar.searchText = term
        }
        bar.focus()
        if !bar.searchText.isEmpty {
            findBarSearchChanged(bar.searchText)
        }
    }

    /// Esc (from the field) or the close button. The current match stays
    /// selected so the user keeps their place; focus returns to the terminal.
    func closeFindBar() {
        guard let bar = findBar, !bar.isHidden else { return }
        bar.isHidden = true
        window?.makeFirstResponder(self)
    }

    /// ⌘G / ⌘⇧G — also live while the search field has focus (menu key
    /// equivalents fire before the field editor sees the keystroke).
    func findNextMatch() { stepMatch(forward: true) }
    func findPreviousMatch() { stepMatch(forward: false) }

    private func stepMatch(forward: Bool) {
        guard let bar = findBar, !bar.searchText.isEmpty else { return }
        runSearch(term: bar.searchText, forward: forward)
    }

    /// Incremental search: every edit re-runs from the current position, so
    /// extending a term refines the same match instead of jumping away.
    func findBarSearchChanged(_ term: String) {
        guard let bar = findBar else { return }
        if term.isEmpty {
            withSearchDrivenSelection { clearSearch() }
            bar.setMatchLabel("")
            return
        }
        runSearch(term: term, forward: true)
    }

    private func runSearch(term: String, forward: Bool) {
        // Case-insensitive by default (SearchOptions() default); the search
        // selects the match and scrolls to it — read-only on buffer and pty.
        let options = SearchOptions()
        withSearchDrivenSelection {
            if forward {
                findNext(term, options: options)
            } else {
                findPrevious(term, options: options)
            }
        }
        let summary = searchMatchSummary(term, options: options)
        findBar?.setMatchLabel(FindSupport.matchCountLabel(index: summary.index,
                                                           total: summary.total))
    }

    /// Search moves the selection to highlight matches; without this guard,
    /// copy-on-select would clobber the user's clipboard on every jump.
    private func withSearchDrivenSelection<T>(_ body: () -> T) {
        searchIsDrivingSelection = true
        defer { searchIsDrivingSelection = false }
        _ = body()
    }

    private func installFindBar() -> PaneFindBar {
        let bar = PaneFindBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.onSearchChanged = { [weak self] term in self?.findBarSearchChanged(term) }
        bar.onNext = { [weak self] in self?.findNextMatch() }
        bar.onPrevious = { [weak self] in self?.findPreviousMatch() }
        bar.onClose = { [weak self] in self?.closeFindBar() }
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            bar.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
        ])
        findBar = bar
        return bar
    }
}
