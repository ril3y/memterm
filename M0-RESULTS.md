# M0 Spike Results

**Date:** 2026-08-30 · **Machine:** Apple Silicon, macOS 26.2 · **Toolchain:** Swift 6.3.3 / Xcode 26.6 · **Build:** `swift build -c release` · **Stack under test:** SwiftTerm (1.2.x) `LocalProcessTerminalView`, stock CoreText renderer, bare AppKit window (980×640)

## Exit criteria (REQUIREMENTS.md §10, M0)

| Criterion | Status |
|---|---|
| SwiftTerm in a bare AppKit window, real pty (`forkpty` via `LocalProcess`) | ✅ builds and runs (`.build/release/memterm`) |
| `TerminalEngine` protocol drawn | ✅ `Sources/memterm/TerminalEngine.swift` |
| p95 latency measured | ✅ see below |
| `yes`-flood behavior measured | ✅ see below |

## Measurements

Reproduce with: `swift build -c release && .build/release/memterm --bench` (headless), `--latency`, `--flood` (each opens a window briefly and auto-quits).

**Headless parser/grid throughput** (120×40 grid, 64 MB per workload):

| Workload | Throughput | Notes |
|---|---|---|
| `yes`-flood (2-byte lines) | 4.0 MB/s | worst case = scroll/line churn; still ≈2M lines/s, far above display needs |
| escape-heavy (SGR-colored lines) | 36.3 MB/s | |
| long lines (4 KB, hard wrap) | 169.9 MB/s | |

**In-window latency probe** (300 draw samples, 200 pty round trips):

| Metric | p50 | p95 | max |
|---|---|---|---|
| pty echo RTT (send → zsh echo → parse → `displayIfNeeded`) | 3.31 ms | **4.58 ms** | 5.05 ms |
| draw latency (feed → `displayIfNeeded`) | ~0 ms | ~0 ms | 0.19 ms |

Caveat: SwiftTerm marks dirty regions and schedules its actual redraw asynchronously, so `displayIfNeeded` immediately after `feed` largely no-ops — the draw-latency row measures parse + no-op display, not glyphs-on-screen. True keypress-to-glyph adds up to one display-link frame (~8.3 ms at 120 Hz / 16.7 ms at 60 Hz) on top of the RTT. Even with that worst-case frame added, p95 ≈ 21 ms.

**In-window flood** (32 MB of `yes` output fed on the main loop, 12 ms feed budget per frame, display every frame):

- 3.3 MB/s sustained with rendering; **worst main-thread stall 1.8 ms** — the UI never freezes.
- Implication for M2+: pty reads must be fed in bounded chunks per frame (as the probe does); a single 64 KB chunk of tiny lines costs ~16 ms of parse, i.e. one whole frame budget.

## Decision (kill criterion: >35 ms p95 or UI freeze under flood)

**Not triggered — proceed on plan.** CoreText renderer stays for v0.1; Metal renderer remains deferred to v0.3 as scheduled. Estimated worst-case p95 keypress-to-glyph ≈ 21 ms is marginally above the NFR-1 20 ms target and well under the 35 ms kill line; re-measure with a proper frame-callback rig (CVDisplayLink timestamping) early in M1 before optimizing anything.

## Follow-ups carried into M1

1. Replace the draw-latency rig with display-link frame timestamping (measure to the frame the glyph actually appears in).
2. Wire `TerminalEngine` conformance onto SwiftTerm (currently a drawn seam, not yet adopted).
3. Bounded per-frame pty feed pump in the real data path (flood probe proved the pattern).
