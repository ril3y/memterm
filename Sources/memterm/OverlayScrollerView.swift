import AppKit
import MemtermCore

// SCROLL UX stage — the auto-hiding overlay scrollbar band (founder ask 2:
// "mousewheel forever vs a quick bar to grab"). One instance per terminal
// pane (shell AND serial — SerialPaneView inherits the installation), pinned
// to the pane's trailing ~12pt. All logic lives in
// MemtermCore.OverlayScroller{Layout,Visibility} (unit-tested, injected
// clock); this view is the thin AppKit face.
//
// Contract with the terminal underneath:
//  - hitTest returns nil whenever the bar is not shown (or the pane cannot
//    scroll), so terminal mouse events — including mouse-reporting apps —
//    are untouched outside the bar's visible moments, and ALWAYS untouched
//    outside the 12pt band (the view is only that wide).
//  - Scrolling goes exclusively through SwiftTerm's public surface:
//    scroll(toPosition:) for knob drags, pageUp()/pageDown() for track
//    clicks (both verified in AppleTerminalView.swift; the built-in
//    NSScroller's .knobSlot case is unimplemented upstream, which is why
//    this view exists). Wheel events over the band are handed back to the
//    pane.
//  - Never steals first responder (acceptsFirstResponder = false;
//    acceptsFirstMouse lets a drag start without click-through focus games).

final class OverlayScrollerView: NSView {
    weak var pane: PaneView?

    private var visibility = OverlayScrollerVisibility()
    private var fadeTimer: Timer?
    /// Distance from the knob's top edge to the mouse-down point, while a
    /// knob drag is in flight.
    private var dragGrabDelta: CGFloat?
    private var lastScrollPosition = -1.0

    override var isFlipped: Bool { true }  // model offsets are top-origin
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Space kept clear at the pane's bottom (the serial footer strip).
    var bottomInset: CGFloat = 0 {
        didSet { updateFrameToBand() }
    }

    init() {
        super.init(frame: .zero)
        // Frame-based on purpose: quiet probe windows sit offscreen and may
        // never run an autolayout display pass, so the band positions itself
        // deterministically (autoresizing triggers resize(withOldSuperviewSize:),
        // which exact-sets the frame from the pane's bounds).
        autoresizingMask = [.minXMargin, .height]
        // No explicit layer backing: a quiet probe window never runs a
        // display pass, and a layer-backed subview's cacheDisplay capture
        // comes back unpainted there (alphaValue animation works either way).
        alphaValue = 0
        isHidden = true
    }

    /// Pins the band to the pane's trailing edge, footer strip excluded.
    /// Idempotent and called again at use time (noteScrollActivity, mouse
    /// entry, probe reads): a quiet probe window sits offscreen and may
    /// never run a layout/display pass, so the band cannot rely on one.
    func updateFrameToBand() {
        guard let sv = superview else { return }
        let target = NSRect(x: sv.bounds.width - OverlayScrollerLayout.bandWidth,
                            y: bottomInset,
                            width: OverlayScrollerLayout.bandWidth,
                            height: max(0, sv.bounds.height - bottomInset))
        if frame != target { frame = target }
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        updateFrameToBand()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        fadeTimer?.invalidate()
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func currentMetrics() -> OverlayScrollerMetrics? {
        guard let pane, pane.canScroll else { return nil }
        return OverlayScrollerMetrics(trackLength: bounds.height,
                                      proportion: pane.scrollThumbsize,
                                      position: CGFloat(pane.scrollPosition))
    }

    // MARK: - Activity / fade

    /// Called by the pane on every scroll delegate tick (per scrolled LINE
    /// during floods — this path must stay O(1)-cheap: a clock read, a
    /// comparison, and a coalesced setNeedsDisplay; the fade timer is armed
    /// once, not per call).
    func noteScrollActivity() {
        guard let pane, pane.canScroll else { return }
        updateFrameToBand()
        visibility.noteActivity(now: now)
        let position = pane.scrollPosition
        if position != lastScrollPosition {
            lastScrollPosition = position
            needsDisplay = true
        }
        presentIfNeeded()
    }

    private func presentIfNeeded() {
        if isHidden || alphaValue < 1 {
            isHidden = false
            needsDisplay = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                animator().alphaValue = 1
            }
        }
        armFadeTimer()
    }

    private func armFadeTimer() {
        guard fadeTimer == nil else { return }
        guard let deadline = visibility.nextFadeDeadline(now: now) else { return }
        let delay = max(deadline - now, 0.05)
        fadeTimer = Timer.scheduledTimer(withTimeInterval: delay,
                                         repeats: false) { [weak self] _ in
            guard let self else { return }
            self.fadeTimer = nil
            self.fadeTimerFired()
        }
    }

    private func fadeTimerFired() {
        if visibility.visible(now: now) {
            // Activity (or hover/drag) since the timer was armed — re-arm for
            // the new deadline instead of fading.
            armFadeTimer()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.visibility.visible(now: self.now) else { return }
            self.isHidden = true
        })
    }

    // MARK: - Hit testing (never eat terminal events while hidden)

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.1, pane?.canScroll == true else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let metrics = currentMetrics() else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let page = OverlayScrollerLayout.trackClick(at: p.y, metrics: metrics) {
            switch page {
            case .pageUp: pane?.pageUp()
            case .pageDown: pane?.pageDown()
            }
            noteScrollActivity()
            return
        }
        guard let knob = OverlayScrollerLayout.knob(metrics) else { return }
        dragGrabDelta = p.y - knob.offset
        visibility.isDragging = true
        presentIfNeeded()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab = dragGrabDelta, let metrics = currentMetrics() else { return }
        let p = convert(event.locationInWindow, from: nil)
        let position = OverlayScrollerLayout.position(forKnobOffset: p.y - grab,
                                                      metrics: metrics)
        pane?.scroll(toPosition: Double(position))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragGrabDelta = nil
        visibility.isDragging = false
        visibility.noteActivity(now: now)
        armFadeTimer()
    }

    /// The wheel belongs to the terminal even over the band.
    override func scrollWheel(with event: NSEvent) {
        pane?.scrollWheel(with: event)
    }

    // MARK: - Hover pins the bar (macOS overlay-scroller behavior)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited,
                                                 .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        guard pane?.canScroll == true, !isHidden else { return }
        visibility.isHovering = true
        presentIfNeeded()
    }

    override func mouseExited(with event: NSEvent) {
        visibility.isHovering = false
        visibility.noteActivity(now: now)
        armFadeTimer()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let metrics = currentMetrics() else { return }
        renderBand(in: bounds, metrics: metrics)
    }

    /// The band's actual drawing, parameterized so the probe can render it
    /// into an offscreen context of known geometry and assert real pixels
    /// (quiet probe windows never earn a display pass — see the probe legs).
    /// `rect` supplies the track: rect.height is the track length, offsets
    /// are top-origin within it.
    func renderBand(in rect: NSRect, metrics: OverlayScrollerMetrics) {
        guard let knob = OverlayScrollerLayout.knob(metrics) else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let darkGround = isOverDarkBackground()

        // Track: a faint full-height band; opaque under reduced transparency.
        let trackColor: NSColor = if reduce {
            darkGround ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.85, alpha: 1)
        } else {
            darkGround ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.08)
        }
        trackColor.setFill()
        rect.fill()

        // Knob.
        let knobColor: NSColor = if reduce {
            darkGround ? NSColor(white: 0.75, alpha: 1) : NSColor(white: 0.35, alpha: 1)
        } else {
            darkGround ? NSColor(white: 1, alpha: 0.45) : NSColor(white: 0, alpha: 0.4)
        }
        knobColor.setFill()
        let knobRect = knobRect(in: rect, knob: knob)
        NSBezierPath(roundedRect: knobRect,
                     xRadius: knobRect.width / 2, yRadius: knobRect.width / 2).fill()
    }

    private func knobRect(in rect: NSRect,
                          knob: (offset: CGFloat, length: CGFloat)) -> NSRect {
        let thickness = OverlayScrollerLayout.knobThickness
        return NSRect(x: rect.minX + rect.width - thickness - 2,
                      y: rect.minY + knob.offset,
                      width: thickness, height: knob.length)
    }

    private func isOverDarkBackground() -> Bool {
        guard let bg = pane?.nativeBackgroundColor.usingColorSpace(.sRGB) else { return true }
        let luminance = 0.2126 * bg.redComponent + 0.7152 * bg.greenComponent
            + 0.0722 * bg.blueComponent
        return luminance < 0.5
    }

    // MARK: - Probe seams (read-only)

    /// Whether the band draws light-on-dark (white knob over a dark terminal)
    /// or dark-on-light — the probe composites its render over the OPPOSITE
    /// ground so the knob can never vanish into the test backdrop.
    var probeDarkGround: Bool { isOverDarkBackground() }

    /// Whether the bar is currently shown (visible state machine AND the
    /// AppKit presentation agree it is on screen).
    var probeVisible: Bool {
        !isHidden && alphaValue > 0.1 && visibility.visible(now: now)
    }

    /// Knob frame in this view's (flipped) coordinates, nil when no knob.
    func probeKnobFrame() -> CGRect? {
        updateFrameToBand()
        guard let metrics = currentMetrics(),
              let knob = OverlayScrollerLayout.knob(metrics) else { return nil }
        return knobRect(in: bounds, knob: knob)
    }
}
