import AppKit
import SwiftTerm

// M0 probe harness, kept intact per REQUIREMENTS.md M0 exit criteria. The
// interactive app lives in MemtermApp.swift; these modes keep a single bare
// pane so measurements stay comparable across milestones.
//   --latency  measure draw latency (feed -> displayed frame) and pty echo
//              round trip, print p50/p95, then quit.
//   --flood    feed 32 MB of `yes`-style output through the view on the main
//              loop with 60 Hz display, report wall time + worst stall, quit.

final class ProbeTerminalView: LocalProcessTerminalView {
    var onPtyData: ((Int) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice) // parse + mark dirty first, so the probe measures through draw
        if let onPtyData {
            let count = slice.count
            if Thread.isMainThread {
                onPtyData(count)
            } else {
                DispatchQueue.main.async { onPtyData(count) }
            }
        }
    }
}

final class ProbeAppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    let mode: RunMode
    var window: NSWindow!
    var termView: ProbeTerminalView!

    init(mode: RunMode) {
        self.mode = mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentRect = NSRect(x: 0, y: 0, width: 980, height: 640)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "memterm"
        window.center()

        termView = ProbeTerminalView(frame: contentRect)
        termView.autoresizingMask = [.width, .height]
        termView.processDelegate = self
        window.contentView = termView
        window.makeFirstResponder(termView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        termView.startProcess(executable: shell, execName: "-\(shellName)")

        // TESTING.md §2.7: every perf gate log self-identifies its binary and
        // records occlusion state so numbers are interpretable.
        let occluded = !window.occlusionState.contains(.visible)
        switch mode {
        case .interactive:
            break
        case .latency:
            print("LATENCY-BEGIN build=\(BuildStamp.describe) occluded=\(occluded)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.runLatencyProbe() }
        case .flood:
            print("FLOOD-BEGIN build=\(BuildStamp.describe) occluded=\(occluded)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.runFloodProbe() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Probes

    private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 } // ms

    /// Draw latency: parse one small feed + full synchronous redisplay.
    /// Echo RTT: send a byte to the pty, stamp when the shell's echo comes back
    /// through feed(). Together they bracket the app's share of keypress-to-glyph.
    private func runLatencyProbe() {
        var drawSamples: [Double] = []
        for i in 0..<300 {
            let t0 = now()
            termView.feed(text: i % 10 == 0 ? "\u{1b}[1;33mx\u{1b}[0m" : "x")
            window.displayIfNeeded()
            drawSamples.append(now() - t0)
        }
        termView.feed(text: "\r\n")

        var rttSamples: [Double] = []
        var sentAt: Double = 0
        var pending = false
        termView.onPtyData = { [weak self] _ in
            guard let self, pending else { return }
            pending = false
            self.window.displayIfNeeded()
            rttSamples.append(self.now() - sentAt)
        }

        var iteration = 0
        func step() {
            if iteration >= 200 {
                self.report(draw: drawSamples, rtt: rttSamples)
                NSApp.terminate(nil)
                return
            }
            iteration += 1
            pending = true
            sentAt = now()
            termView.send(txt: " ")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { step() }
        }
        step()
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
        return sorted[idx]
    }

    private func report(draw: [Double], rtt: [Double]) {
        let d = draw.sorted(), r = rtt.sorted()
        print("memterm M0 latency probe (CoreText renderer, 980x640 window)")
        print(String(format: "draw latency   n=%3d  p50=%6.2f ms  p95=%6.2f ms  max=%6.2f ms",
                     d.count, percentile(d, 0.5), percentile(d, 0.95), d.last ?? .nan))
        print(String(format: "pty echo rtt   n=%3d  p50=%6.2f ms  p95=%6.2f ms  max=%6.2f ms",
                     r.count, percentile(r, 0.5), percentile(r, 0.95), r.last ?? .nan))
        // ENFORCED kill-criterion (REQUIREMENTS.md M0 / TESTING.md §2.7): the
        // probe stops describing its threshold and starts applying it — a
        // violation exits nonzero. A waiver happens in verify.sh with a
        // printed reason, never by this probe silently passing.
        let p95Total = percentile(d, 0.95) + percentile(r, 0.95)
        let required = 35.0
        if p95Total.isFinite, p95Total < required, !d.isEmpty, !r.isEmpty {
            print(String(format: "LATENCY-PASS p95_total=%.2f required=%.0f", p95Total, required))
            fflush(stdout)
            exit(0)
        } else {
            print(String(format: "LATENCY-FAIL p95=%.2f required=%.0f", p95Total, required))
            fflush(stdout)
            exit(1)
        }
    }

    /// Flood: 32 MB of tiny lines fed on the main loop with a display every
    /// frame budget; measures total wall time and the worst main-thread stall.
    private func runFloodProbe() {
        let yesLine = Array("y\n".utf8)
        var chunk: [UInt8] = []
        while chunk.count < 65_536 { chunk += yesLine }
        let totalBytes = 32 * 1_048_576
        var fed = 0
        var worstStall: Double = 0
        var lastTick = now()
        let t0 = now()

        func pump() {
            let tickStart = now()
            worstStall = max(worstStall, tickStart - lastTick)
            let budgetDeadline = tickStart + 12.0 // leave headroom in a 16.7ms frame
            while fed < totalBytes && now() < budgetDeadline {
                termView.feed(byteArray: chunk[0...])
                fed += chunk.count
            }
            window.displayIfNeeded()
            lastTick = now()
            if fed < totalBytes {
                DispatchQueue.main.async { pump() }
            } else {
                let dt = (now() - t0) / 1000.0
                print("memterm M0 flood probe (in-window, main-loop feed + 60Hz display)")
                print(String(format: "fed %d MB in %.2f s  ->  %.1f MB/s;  worst main-thread stall %.1f ms",
                             totalBytes / 1_048_576, dt, Double(totalBytes) / 1_048_576.0 / dt, worstStall))
                // ENFORCED kill-criterion (TESTING.md §2.7): UI must not
                // freeze under flood — worst main-thread stall < 100 ms.
                let required = 100.0
                if worstStall < required {
                    print(String(format: "FLOOD-PASS worst_stall=%.1f required=%.0f", worstStall, required))
                    fflush(stdout)
                    exit(0)
                } else {
                    print(String(format: "FLOOD-FAIL worst_stall=%.1f required=%.0f", worstStall, required))
                    fflush(stdout)
                    exit(1)
                }
            }
        }
        pump()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        window?.title = title.isEmpty ? "memterm" : title
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}

enum RunMode {
    case interactive, latency, flood
}

/// Dock icon: resolves Assets/memterm.icns for every launch layout — bundled
/// .app (make-app.sh puts it in Contents/Resources), bare swift-build binary
/// (.build/<config>/memterm → ../../Assets/), or run-from-repo-root. Harmless
/// no-op when nothing is found.
func installAppIcon() {
    let fm = FileManager.default
    var candidates: [URL] = []
    if let bundled = Bundle.main.url(forResource: "memterm", withExtension: "icns") {
        candidates.append(bundled)
    }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let executableDir = executable.deletingLastPathComponent()
    candidates.append(executableDir.appendingPathComponent("../../Assets/memterm.icns")
        .standardizedFileURL)
    candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath)
        .appendingPathComponent("Assets/memterm.icns"))
    for url in candidates where fm.fileExists(atPath: url.path) {
        if let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
            return
        }
    }
}

func runApp(mode: RunMode, smoke: SmokeRun? = nil) {
    let app = NSApplication.shared
    // Quiet mode (TESTING.md §2.5): probes must be cheap to run on every
    // commit — screen-stealing is why gates get skipped. Accessory policy, no
    // dock bounce, no focus theft; MEMTERM_PROBE_VISIBLE=1 restores .regular.
    app.setActivationPolicy(ProbeSupport.quiet ? .accessory : .regular)
    installAppIcon()
    let delegate: NSApplicationDelegate = mode == .interactive
        ? MemtermAppDelegate(smokeRun: smoke)
        : ProbeAppDelegate(mode: mode)
    app.delegate = delegate
    app.run()
}
