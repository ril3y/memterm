import Foundation
import SwiftTerm

// M0: headless parser/grid throughput (NFR-9 groundwork).
// Runs SwiftTerm's Terminal with no view attached and measures MB/s for three
// workload shapes. This is the CI-runnable half of the flood measurement; the
// in-window half lives in the --flood mode of the app.

private final class NullTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

private func megabytes(_ bytes: Int) -> Double { Double(bytes) / 1_048_576.0 }

@discardableResult
private func run(workload name: String, chunk: [UInt8], totalMB: Int) -> Double {
    let delegate = NullTerminalDelegate()
    let term = Terminal(delegate: delegate, options: TerminalOptions(cols: 120, rows: 40))
    let targetBytes = totalMB * 1_048_576
    var fed = 0
    let t0 = DispatchTime.now()
    while fed < targetBytes {
        term.feed(buffer: chunk[0...])
        fed += chunk.count
    }
    let dt = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
    let rate = megabytes(fed) / dt
    print(String(format: "%-14s %6.0f MB in %6.2f s  ->  %8.1f MB/s",
                 (name as NSString).utf8String!, megabytes(fed), dt, rate))
    return rate
}

func runBench() {
    print("BENCH-BEGIN build=\(BuildStamp.describe)")
    print("memterm M0 bench — SwiftTerm headless throughput (120x40 grid)")

    // 1. `yes`-style flood: tiny lines, maximal scroll pressure.
    let yesLine = Array("y\n".utf8)
    var yesChunk: [UInt8] = []
    while yesChunk.count < 65_536 { yesChunk += yesLine }

    // 2. Escape-heavy: SGR-colored ls/build-log-like lines.
    let colored = "\u{1b}[1;32mOK\u{1b}[0m \u{1b}[36m/src/parser/tokenizer.swift\u{1b}[0m \u{1b}[33m47ms\u{1b}[0m compiled with \u{1b}[1m0 warnings\u{1b}[0m\n"
    let coloredLine = Array(colored.utf8)
    var escChunk: [UInt8] = []
    while escChunk.count < 65_536 { escChunk += coloredLine }

    // 3. Long lines: 4 KB per line, wraps hard across the grid.
    let longLine = Array((String(repeating: "abcdefgh", count: 512) + "\n").utf8)
    var longChunk: [UInt8] = []
    while longChunk.count < 65_536 { longChunk += longLine }

    // ENFORCED kill-criteria (TESTING.md §2.7, NFR-9 groundwork), calibrated
    // per workload at HALF the M0-RESULTS.md baselines (4.0 / 36.3 / 169.9
    // MB/s): the floors exist to catch a collapse (an accidental O(n^2), a
    // debug-build artifact masquerading as release), not to race the CPU.
    let workloads: [(name: String, rate: Double, floor: Double)] = [
        ("yes-flood", run(workload: "yes-flood", chunk: yesChunk, totalMB: 64), 2.0),
        ("escape-heavy", run(workload: "escape-heavy", chunk: escChunk, totalMB: 64), 18.0),
        ("long-lines", run(workload: "long-lines", chunk: longChunk, totalMB: 64), 85.0),
    ]
    let violations = workloads.filter { $0.rate < $0.floor }
    if violations.isEmpty {
        let summary = workloads
            .map { String(format: "%@=%.1f/%.0f", $0.name, $0.rate, $0.floor) }
            .joined(separator: " ")
        print("BENCH-PASS \(summary)")
    } else {
        for v in violations {
            print(String(format: "BENCH-FAIL workload=%@ rate=%.1f required=%.0f",
                         v.name, v.rate, v.floor))
        }
        exit(1)
    }
}
