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

private func run(workload name: String, chunk: [UInt8], totalMB: Int) {
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
}

func runBench() {
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

    run(workload: "yes-flood", chunk: yesChunk, totalMB: 64)
    run(workload: "escape-heavy", chunk: escChunk, totalMB: 64)
    run(workload: "long-lines", chunk: longChunk, totalMB: 64)
}
