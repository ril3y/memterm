import AppKit
import MemtermCore

// ProbeKit — the harness v2 core (TESTING.md §2). One event-driven step queue
// replaces the asyncAfter cascade: steps run sequentially, each gated on a
// polled CONDITION with a per-step timeout, never on a wall-clock offset —
// which deletes the "fixed clock racing async work" defect class (bug 4)
// instead of patching legs one at a time. The runner owns process exit: no
// probe path can exit without either the PASS sentinel (full completion), a
// FAIL line naming a step, or the atexit ABORT line — a partial run can NEVER
// read green (bug 4's completion-sentinel escape).

// MARK: - Failure plumbing

struct ProbeFailure: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// Fails the CURRENT step of the active runner (prints the FAIL sentinel,
/// dumps diagnostics, exits 1). Legacy leg bodies call this instead of the
/// old silent `exit(1)` — by construction every failure names a step.
func probeFail(_ reason: String) -> Never {
    if let runner = ProbeRunner.current {
        runner.fail(reason: reason)
    }
    print("PROBE-FAIL (no runner) reason=\(reason)")
    fflush(stdout)
    exit(1)
}

// MARK: - Environment / mode support

/// Explicit smoke run selection (TESTING.md §2.6).
enum SmokeRun: String {
    case save, verify

    /// Written by --smoke=save on completion; --smoke=verify refuses a state
    /// dir that lacks it.
    static let markerFileName = "smoke-save-complete.marker"
}

enum ProbeSupport {
    static var isUIProbe: Bool {
        ProcessInfo.processInfo.environment["MEMTERM_UI_PROBE"] == "1"
    }

    /// fresh | restored | observe (TESTING.md §2.4). Default fresh.
    static var mode: String {
        ProcessInfo.processInfo.environment["MEMTERM_PROBE_MODE"] ?? "fresh"
    }

    /// MEMTERM_PROBE_VISIBLE=1 opts into on-screen windows + real fullscreen
    /// + the composited pixel pass; the default is quiet (§2.5).
    static var visible: Bool {
        ProcessInfo.processInfo.environment["MEMTERM_PROBE_VISIBLE"] == "1"
    }

    static var smokeArg: String? {
        for arg in CommandLine.arguments.dropFirst() where arg.hasPrefix("--smoke") {
            return arg
        }
        return nil
    }

    static var isSmoke: Bool { smokeArg != nil }

    /// Quiet automated run: accessory activation, no activate(), offscreen
    /// windows. True for probe AND smoke unless MEMTERM_PROBE_VISIBLE=1.
    static var quiet: Bool { (isUIProbe || isSmoke) && !visible }

    /// Where failure screenshots / bitmaps land.
    static var outDir: URL {
        if let dir = ProcessInfo.processInfo.environment["MEMTERM_PROBE_OUT"],
           !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("memterm-probe-out", isDirectory: true)
    }

    /// Isolation hard gate (TESTING.md §2.2, belt-and-suspenders): a probe or
    /// smoke run must be structurally unable to touch the founder's real
    /// state — the probe deletes journal rows and scrollback through the
    /// FR-56 forget path. Exit 2, printed reason, if the resolved state dir
    /// is anywhere under ~/Library/Application Support/memterm.
    static func refuseRealStateDir(prefix: String) {
        let real = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("memterm").standardizedFileURL.path
        let resolved = MemoryEngine.baseDir.standardizedFileURL.path
        if resolved == real || resolved.hasPrefix(real + "/") {
            print("\(prefix)-FAIL refusing to run against the real state dir \(resolved) — set MEMTERM_STATE_DIR to an isolated location")
            fflush(stdout)
            exit(2)
        }
    }
}

// MARK: - Step + runner

struct ProbeStep {
    let name: String                // machine-parseable, e.g. "close-pane"
    let timeout: TimeInterval       // per-step budget
    let action: () -> Void          // perform the gesture / mutation
    let condition: () -> Bool       // polled on main every 50 ms until true
    let assert: () throws -> Void   // outcome assertions once condition holds
    let onFailure: () -> Void       // extra leg-specific diagnostics

    init(name: String, timeout: TimeInterval = 10,
         action: @escaping () -> Void = {},
         condition: @escaping () -> Bool = { true },
         assert: @escaping () throws -> Void = {},
         onFailure: @escaping () -> Void = {}) {
        self.name = name
        self.timeout = timeout
        self.action = action
        self.condition = condition
        self.assert = assert
        self.onFailure = onFailure
    }
}

final class ProbeRunner {
    /// The active runner — read by the atexit abort guard and probeFail().
    private(set) static var current: ProbeRunner?

    let prefix: String              // "UIPROBE" or "SMOKE"
    let mode: String                // fresh | restored | observe | save | verify
    private var steps: [ProbeStep] = []
    private(set) var completed = 0
    private(set) var finished = false
    private(set) var currentStepName = "(setup)"
    private var currentStepStarted: TimeInterval = 0
    /// App-supplied diagnostics dump (tree dumps, window list, tabs debug,
    /// screenshot) run on every failure before exit.
    var diagnostics: (String) -> Void = { _ in }

    var totalSteps: Int { steps.count }

    init(prefix: String, mode: String) {
        self.prefix = prefix
        self.mode = mode
    }

    func add(_ step: ProbeStep) { steps.append(step) }

    /// TESTING.md §2.4: a STATEFUL step (a gesture whose behavior depends on
    /// where its target state came from) registers for BOTH the fresh and
    /// restored manifests by construction — the shared step list is what
    /// makes fresh-only stateful coverage structurally impossible. In
    /// observe mode (the side-effect quarantine) stateful gesture steps are
    /// excluded: observe creates and forces nothing.
    func addStateful(_ step: ProbeStep) {
        guard mode != "observe" else { return }
        steps.append(step)
    }

    /// Config-conditional skip: legal, loud, and never a pass (§2.2).
    func skipLine(step: String, reason: String) {
        print("\(prefix)-SKIP step=\(step) reason=\(reason)")
    }

    func run() {
        ProbeRunner.current = self
        installProbeAbortGuard()
        try? FileManager.default.createDirectory(at: ProbeSupport.outDir,
                                                 withIntermediateDirectories: true)
        // The manifest line: every gate log self-identifies its binary
        // (bug 5) and its world before the first step runs.
        print("\(prefix)-BEGIN steps=\(steps.count) build=\(BuildStamp.describe) mode=\(mode) statedir=\(MemoryEngine.baseDir.path) quiet=\(ProbeSupport.quiet)")
        fflush(stdout)
        advance()
    }

    func fail(reason: String) -> Never {
        let waited = Int((ProcessInfo.processInfo.systemUptime - currentStepStarted) * 1000)
        finished = true  // suppress the ABORT line — this exit is accounted for
        print("\(prefix)-FAIL step=\(currentStepName) waited=\(waited) reason=\(reason)")
        diagnostics(currentStepName)
        fflush(stdout)
        exit(1)
    }

    private func advance() {
        guard completed < steps.count else {
            finished = true
            // Success sentinel — the ONLY green. Runners grep for it with
            // matching counts; exit code 0 alone is never a pass.
            let runTag = prefix == "SMOKE" ? " run=\(mode)" : ""
            print("\(prefix)-PASS\(runTag) steps=\(completed)/\(steps.count)")
            if prefix == "UIPROBE" {
                print("UIPROBE-DONE all-legs-complete")  // legacy sentinel
            }
            fflush(stdout)
            onAllStepsComplete()
            exit(0)
        }
        let step = steps[completed]
        currentStepName = step.name
        currentStepStarted = ProcessInfo.processInfo.systemUptime
        step.action()
        pollCondition(step)
    }

    /// Runs after PASS is printed, before exit(0) — smoke's save run hangs
    /// its marker write here.
    var onAllStepsComplete: () -> Void = {}

    private func pollCondition(_ step: ProbeStep) {
        let deadline = currentStepStarted + step.timeout
        func poll() {
            if step.condition() {
                do {
                    try step.assert()
                } catch let failure as ProbeFailure {
                    step.onFailure()
                    fail(reason: failure.reason)
                } catch {
                    step.onFailure()
                    fail(reason: String(describing: error))
                }
                let ms = Int((ProcessInfo.processInfo.systemUptime - currentStepStarted) * 1000)
                completed += 1
                print("\(prefix)-STEP \(completed)/\(steps.count) name=\(step.name) ms=\(ms)")
                fflush(stdout)
                DispatchQueue.main.async { self.advance() }
                return
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                step.onFailure()
                fail(reason: "timeout waiting for condition")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        poll()
    }
}

/// Crash-safe teardown sentinel: if the process exits by ANY path other than
/// the runner's own PASS/FAIL (early clean exit, last-window-close, crash-ish
/// teardown), the log ends in an ABORT line — an early exit can never be
/// mistaken for green again (bug 4).
private var probeAbortGuardInstalled = false
func installProbeAbortGuard() {
    guard !probeAbortGuardInstalled else { return }
    probeAbortGuardInstalled = true
    atexit {
        if let runner = ProbeRunner.current, !runner.finished {
            // Meta-gate hardening: name the in-flight leg — an early exit's
            // ABORT must point at WHERE the run died, not just how far it got.
            print("\(runner.prefix)-ABORT completed=\(runner.completed)/\(runner.totalSteps) in_flight=\(runner.currentStepName)")
            fflush(stdout)
        }
    }
}

// MARK: - Frame + pixel assertion helpers (TESTING.md §2.3 — the layer bugs
// 1 and 2 lived above every model-level assertion)

/// The view's own rendering (cacheDisplay). NOTE, so nobody "fixes" it: this
/// does NOT see window-server compositing — opacity/blur/occlusion truths
/// need probeWindowImage in a visible run.
func probeBitmap(_ view: NSView) -> NSBitmapImageRep? {
    guard view.bounds.width >= 1, view.bounds.height >= 1 else { return nil }
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// The composited on-screen window image (window-server truth). Visible runs
/// only; returns nil without screen-capture permission.
func probeWindowImage(_ window: NSWindow) -> CGImage? {
    CGWindowListCreateImage(.null, .optionIncludingWindow,
                            CGWindowID(window.windowNumber), [.boundsIgnoreFraming])
}

/// Writes a PNG of `view` (or the key window's content view) for failure
/// forensics; returns the path when written.
@discardableResult
func probeScreenshot(_ view: NSView?, name: String) -> String? {
    guard let view, let rep = probeBitmap(view),
          let png = rep.representation(using: .png, properties: [:]) else { return nil }
    let url = ProbeSupport.outDir.appendingPathComponent("\(name).png")
    try? FileManager.default.createDirectory(at: ProbeSupport.outDir,
                                             withIntermediateDirectories: true)
    do {
        try png.write(to: url)
        return url.path
    } catch { return nil }
}

/// Composited evidence shot (visible runs only): the window-server truth via
/// `screencapture -l <CGWindowID>` — the same compositor pixels the founder
/// sees, titlebar overlays and translucency included (content-view bitmaps
/// lie about both). `includeSheet` widens to a region capture spanning the
/// window plus its attached sheet (a sheet is its own window; -l would crop
/// it out). Falls back to CGWindowListCreateImage when screencapture writes
/// nothing. Evidence only — never asserted on, never run in quiet mode.
@discardableResult
func probeCompositedShot(_ window: NSWindow?, name: String,
                         includeSheet: Bool = false) -> String? {
    guard ProbeSupport.visible, let window else { return nil }
    let url = ProbeSupport.outDir.appendingPathComponent("\(name).png")
    try? FileManager.default.createDirectory(at: ProbeSupport.outDir,
                                             withIntermediateDirectories: true)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    if includeSheet, let sheet = window.attachedSheet,
       let primary = NSScreen.screens.first {
        let union = window.frame.union(sheet.frame).insetBy(dx: -2, dy: -2)
        let topY = primary.frame.height - union.maxY  // global top-left origin
        task.arguments = ["-x", "-o",
                          "-R\(Int(union.minX)),\(Int(topY)),\(Int(union.width)),\(Int(union.height))",
                          url.path]
    } else {
        task.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
    }
    try? task.run()
    task.waitUntilExit()
    if FileManager.default.fileExists(atPath: url.path) {
        print("UIPROBE-CAPTURE name=\(name) path=\(url.path) source=screencapture")
        return url.path
    }
    guard let cg = probeWindowImage(window),
          let png = NSBitmapImageRep(cgImage: cg)
              .representation(using: .png, properties: [:]) else { return nil }
    try? png.write(to: url)
    print("UIPROBE-CAPTURE name=\(name) path=\(url.path) source=cgwindowlist")
    return url.path
}

/// The composited on-screen window as a bitmap for ASSERTIONS (visible runs
/// only): `screencapture -o -l` into the probe out dir — the path that works
/// without the CGWindowListCreateImage screen-recording grant — with the CG
/// image as fallback. Nil when neither source produced pixels.
func probeCompositedBitmap(_ window: NSWindow, name: String) -> NSBitmapImageRep? {
    guard ProbeSupport.visible else { return nil }
    let url = ProbeSupport.outDir.appendingPathComponent("\(name).png")
    try? FileManager.default.createDirectory(at: ProbeSupport.outDir,
                                             withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: url)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
    try? task.run()
    task.waitUntilExit()
    if let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) {
        return rep
    }
    guard let cg = probeWindowImage(window) else { return nil }
    return NSBitmapImageRep(cgImage: cg)
}

/// Bug-1 class: a pane must PRESENT with real size — frame-in-window width
/// and height at least `minSide`, inside a non-zero container.
func assertPaneGeometry(_ pane: NSView, paneId: String,
                        minSide: CGFloat = 50) throws {
    let frame = pane.frame
    guard frame.width >= minSide, frame.height >= minSide else {
        throw ProbeFailure("pane \(paneId.prefix(8)) collapsed: frame=\(Int(frame.width))x\(Int(frame.height)) (min \(Int(minSide)))")
    }
    if let container = pane.superview {
        guard container.bounds.width >= 1, container.bounds.height >= 1 else {
            throw ProbeFailure("pane \(paneId.prefix(8)) sits in a zero-sized container")
        }
    }
}

private func sampleColors(_ bmp: NSBitmapImageRep, region: CGRect,
                          grid: Int = 16) -> [NSColor] {
    // Region is in (bottom-left-origin) view points; the rep is top-left
    // origin and may be Retina-scaled.
    let sx = CGFloat(bmp.pixelsWide) / max(bmp.size.width, 1)
    let sy = CGFloat(bmp.pixelsHigh) / max(bmp.size.height, 1)
    var colors: [NSColor] = []
    for i in 0..<grid {
        for j in 0..<grid {
            let viewX = region.minX + region.width * (CGFloat(i) + 0.5) / CGFloat(grid)
            let viewY = region.minY + region.height * (CGFloat(j) + 0.5) / CGFloat(grid)
            let px = Int(viewX * sx)
            let py = Int((max(bmp.size.height, 1) - viewY) * sy)
            guard px >= 0, py >= 0, px < bmp.pixelsWide, py < bmp.pixelsHigh,
                  let color = bmp.colorAt(x: px, y: py) else { continue }
            colors.append(color)
        }
    }
    return colors
}

/// Bug-1 class, pixel half: the region actually RENDERED something — it is
/// non-empty and non-uniform (>= 2 distinct quantized colors on a 16x16
/// sample grid). A blank/collapsed pane fails here even when its frame lies.
func assertRendered(_ bmp: NSBitmapImageRep, region: CGRect,
                    what: String) throws {
    guard region.width >= 1, region.height >= 1 else {
        throw ProbeFailure("\(what): empty region \(region)")
    }
    let colors = sampleColors(bmp, region: region)
    guard !colors.isEmpty else {
        throw ProbeFailure("\(what): no samples inside the bitmap")
    }
    var quantized = Set<String>()
    for color in colors {
        guard let c = color.usingColorSpace(.sRGB) else { continue }
        quantized.insert(String(format: "%02x%02x%02x",
                                Int(c.redComponent * 15), Int(c.greenComponent * 15),
                                Int(c.blueComponent * 15)))
    }
    guard quantized.count >= 2 else {
        throw ProbeFailure("\(what): rendered uniformly (\(quantized.first ?? "no color")) — nothing visibly drawn")
    }
}

/// Founder polish (chip centering, 2026-09-01): the bounding box of a
/// region's CONTENT pixels — those visibly different from the region's
/// dominant background colors. Background = every quantized color bucket
/// covering >= 20% of the region's pixels (the bar ground; the active chip's
/// low-alpha pill fill either buckets there too or sits within
/// `minDistance` of it); content = pixels far from ALL background buckets
/// (glyphs, the color dot). Scans every device pixel — regions here are
/// chip-sized. Returns the box in the same bottom-left-origin view points as
/// `region`; nil when nothing qualifies.
func probeContentBoundingBox(_ bmp: NSBitmapImageRep, region: CGRect,
                             minDistance: CGFloat = 0.18) -> CGRect? {
    let sx = CGFloat(bmp.pixelsWide) / max(bmp.size.width, 1)
    let sy = CGFloat(bmp.pixelsHigh) / max(bmp.size.height, 1)
    let x0 = max(0, Int(region.minX * sx)), x1 = min(bmp.pixelsWide, Int(ceil(region.maxX * sx)))
    let y0 = max(0, Int((bmp.size.height - region.maxY) * sy))
    let y1 = min(bmp.pixelsHigh, Int(ceil((bmp.size.height - region.minY) * sy)))
    guard x1 > x0, y1 > y0 else { return nil }

    struct Sample { let px: Int; let py: Int; let r: CGFloat; let g: CGFloat; let b: CGFloat }
    var samples: [Sample] = []
    samples.reserveCapacity((x1 - x0) * (y1 - y0))
    var histogram: [Int: Int] = [:]
    for py in y0..<y1 {
        for px in x0..<x1 {
            guard let c = bmp.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
            samples.append(Sample(px: px, py: py, r: c.redComponent,
                                  g: c.greenComponent, b: c.blueComponent))
            let key = (Int(c.redComponent * 15) << 8) | (Int(c.greenComponent * 15) << 4)
                | Int(c.blueComponent * 15)
            histogram[key, default: 0] += 1
        }
    }
    guard !samples.isEmpty else { return nil }
    let floor = max(1, samples.count / 5)  // >= 20% of pixels = background
    // Spelled out step by step: the one-expression filter/map form is fine
    // on Swift 6.2 but Swift 6.0 (macos-15 CI runners) gives up
    // type-checking it.
    func bucketCenter(_ nibble: Int) -> CGFloat { (CGFloat(nibble) + 0.5) / 16 }
    var backgrounds: [(CGFloat, CGFloat, CGFloat)] = []
    for (key, count) in histogram where count >= floor {
        let r = bucketCenter((key >> 8) & 15)
        let g = bucketCenter((key >> 4) & 15)
        let b = bucketCenter(key & 15)
        backgrounds.append((r, g, b))
    }
    guard !backgrounds.isEmpty else { return nil }

    var minPX = Int.max, maxPX = Int.min, minPY = Int.max, maxPY = Int.min
    for s in samples {
        let isContent = backgrounds.allSatisfy { bg in
            max(abs(s.r - bg.0), abs(s.g - bg.1), abs(s.b - bg.2)) > minDistance
        }
        guard isContent else { continue }
        minPX = min(minPX, s.px); maxPX = max(maxPX, s.px)
        minPY = min(minPY, s.py); maxPY = max(maxPY, s.py)
    }
    guard minPX <= maxPX else { return nil }
    // Pixel bbox (top-left-origin device pixels) back to view points.
    let minX = CGFloat(minPX) / sx
    let maxX = CGFloat(maxPX + 1) / sx
    let minY = bmp.size.height - CGFloat(maxPY + 1) / sy
    let maxY = bmp.size.height - CGFloat(minPY) / sy
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

/// WCAG relative-luminance contrast between two colors (AppKit-side twin of
/// MemtermCore.ChromeContrast, for sampled NSColors).
func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
    func luminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

/// Council #2 (chrome-vs-theme coherence): the region's most common sampled
/// color — the rendered GROUND of a chrome row, decorations excluded by
/// majority vote. Nil when the region yields no samples.
func probeDominantColor(_ bmp: NSBitmapImageRep, region: CGRect) -> NSColor? {
    let colors = sampleColors(bmp, region: region)
    guard !colors.isEmpty else { return nil }
    var histogram: [Int: (count: Int, color: NSColor)] = [:]
    for color in colors {
        guard let c = color.usingColorSpace(.sRGB) else { continue }
        let key = (Int(c.redComponent * 15) << 8) | (Int(c.greenComponent * 15) << 4)
            | Int(c.blueComponent * 15)
        let entry = histogram[key]
        histogram[key] = ((entry?.count ?? 0) + 1, entry?.color ?? c)
    }
    return histogram.values.max { $0.count < $1.count }?.color
}

/// WCAG relative luminance of a color (0 dark … 1 light) — the "which world
/// is this ground in" half of the chrome-vs-theme coherence gate.
func probeLuminance(_ color: NSColor) -> CGFloat {
    guard let c = color.usingColorSpace(.sRGB) else { return 0 }
    func channel(_ v: CGFloat) -> CGFloat {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent)
        + 0.0722 * channel(c.blueComponent)
}

/// One synthetic keyboard event addressed to `window`.
func probeKeyEvent(_ window: NSWindow, keyCode: UInt16,
                   characters: String) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: keyCode)
}

/// Sends one real key event through the window's own dispatch (sendEvent →
/// responder chain / key-equivalent routing) — the gesture-fidelity way to
/// press Esc in a sheet. Esc = (53, "\u{1b}"), Return = (36, "\r").
func probeSendKey(_ window: NSWindow, keyCode: UInt16, characters: String) {
    guard let event = probeKeyEvent(window, keyCode: keyCode,
                                    characters: characters) else { return }
    window.sendEvent(event)
}

/// Presses Return in a dialog: asserts the Enter mapping structurally — the
/// window HAS a default button (its `defaultButtonCell`, or a button wired
/// to keyEquivalent "\r"; on this AppKit an alert's Return routing lives in
/// the defaultButtonCell, the button's own keyEquivalent stays empty —
/// verified live) — and drives that button's real click. Synthetic Return
/// keyDowns cannot take the native route in a quiet probe run: the focused
/// field editor consumes a raw sendEvent and the key-equivalent pass
/// refuses in a never-key window (both verified live).
/// `expectedTitle` pins WHICH button Enter commits through (the verb).
@discardableResult
func probePressReturn(in window: NSWindow, expectedTitle: String? = nil) -> Bool {
    if let cell = window.defaultButtonCell {
        if let expectedTitle, cell.title != expectedTitle { return false }
        cell.performClick(nil)
        return true
    }
    func findDefaultButton(_ view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.keyEquivalent == "\r" {
            return button
        }
        for sub in view.subviews {
            if let found = findDefaultButton(sub) { return found }
        }
        return nil
    }
    guard let root = window.contentView,
          let button = findDefaultButton(root),
          expectedTitle == nil || button.title == expectedTitle else { return false }
    button.performClick(nil)
    return true
}

/// Bug-2 regression, rendered half: the chip's REGION of the composited
/// chrome bitmap must contain visibly contrasting pixels (glyphs vs chip
/// ground) — a washed-out/invisible chip samples near-uniform and fails.
func assertChipVisible(chipFrame: CGRect, in bmp: NSBitmapImageRep,
                       what: String, minRatio: CGFloat = 1.6) throws {
    let colors = sampleColors(bmp, region: chipFrame)
    guard colors.count >= 8 else {
        throw ProbeFailure("\(what): chip region yielded \(colors.count) samples")
    }
    var best: CGFloat = 1.0
    // Lightest vs darkest sample bounds the max pairwise ratio.
    var lightest = colors[0], darkest = colors[0]
    var lightLum: CGFloat = -1, darkLum: CGFloat = 2
    for color in colors {
        guard let c = color.usingColorSpace(.sRGB) else { continue }
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        if lum > lightLum { lightLum = lum; lightest = color }
        if lum < darkLum { darkLum = lum; darkest = color }
    }
    best = contrastRatio(lightest, darkest)
    guard best >= minRatio else {
        throw ProbeFailure("\(what): chip renders at contrast \(String(format: "%.2f", best)) < \(minRatio) — visually washed out")
    }
}

// MARK: - Quiet-mode window (TESTING.md §2.5)

/// Probe windows in quiet mode live offscreen; AppKit's default
/// constrainFrameRect would drag them back onto a screen, so the probe
/// window class disables constraining entirely.
final class ProbeQuietWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
