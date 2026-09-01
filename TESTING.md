# TESTING.md — memterm Testing Charter (v2)

This document is both the testing constitution and the implementation spec for the harness redesign. It was written after five bugs shipped through all-green gates. Every rule below traces to one of those escapes; the calibration question for any future change to this file is: **"would this have caught bugs 1–5?"**

Ground truth (the calibration set):
1. Restored split trees collapsed at launch (0x0 container at attach) — probes asserted model state, never rendered output; probe runs self-masked by creating fixtures mid-run.
2. Workspace chips invisible at `window_opacity 0.37` — invisible to model-level assertions; probes only ever ran at default config.
3. Close-pane blanked a restored tab — every gesture leg only ever ran against fresh tabs.
4. Probe false-greens — no completion sentinel (early clean exit = pass), fixed wall-clock `asyncAfter` racing async work, fresh-state assumptions applied to restored state.
5. Evidence hygiene — dirty-tree debug builds presented as evidence about the shipped artifact; `dist/memterm.app` carried no version stamp.

---

## 1. LAYER MAP

Each layer certifies exactly one kind of truth. Presenting a layer's green as evidence about a truth it cannot see is a charter violation (this is how 240 green XCTests laundered bugs 1–3).

| Layer | Surface | Certifies | Can NEVER see |
|---|---|---|---|
| **L1 — Core XCTests** | `Tests/MemtermCoreTests` (`swift test`) | Model correctness: stores, adapters, split math, persistence bytes, shell integration, security denylists | AppKit layout, attach ordering, rendering, focus, compositing |
| **L2 — Headless UI seams** (new, in L1's target) | `SplitLayout`, `ChromeContrast`, `FocusIntent` in MemtermCore | Layout geometry as pure functions; contrast math; focus-intent state machine | Whether AppKit actually obeys the computed answer |
| **L3 — Smoke** | `--smoke=save` / `--smoke=verify` pair | The reboot-restore product promise end-to-end through the REAL capture and launch-restore pipelines | Gestures on restored state; rendering |
| **L4 — UI probe v2** | `MEMTERM_UI_PROBE=1` + `MEMTERM_PROBE_MODE=fresh\|restored\|observe` | Real gesture routing, presented geometry, rendered pixels — in fresh AND restored worlds | Cross-reboot persistence (that is L3's job) |
| **L5 — Perf probes** | `--bench` / `--latency` / `--flood` with **enforced** thresholds | Numeric kill-criteria on the release artifact | Correctness |
| **L6 — verify.sh** | `scripts/verify.sh` | That all of the above ran, against the stamped release artifact, with sentinels — and produced citable evidence | — |
| **Manual** | Founder use + one opt-in visible pixel pass | Composited on-screen truths (occlusion, blur, Spaces) and taste | Everything reproducible — which must live in L1–L5 |

**No XCUITest target.** The probe layer, upgraded per §2, is our AppKit integration truth; adding a second UI-automation stack would split investment without adding a truth the probe cannot reach.

**Placement rule for every new user-visible behavior** (mechanically checkable at merge, §3.4):
1. Logic that can be a pure function gets extracted and tested in L1/L2 (the `TabStripLayout`/`SwitchSupport` extraction pattern — proven, reuse it).
2. Every behavior gets a probe step in L4.
3. Every **stateful** behavior gets that step executed in BOTH `fresh` and `restored` modes — by construction (§2.4, `addStateful`), not by author diligence.
4. Anything persisted gets an L3 assertion in the verify run.
5. Anything visual gets a rendered-bitmap assertion (§2.3), and a config-matrix entry if config-sensitive.

L1's ~240 tests are relabeled, not touched: they certify **model correctness only** and are never again cited as evidence about presented UI.

---

## 2. HARNESS V2 SPEC

### 2.1 ProbeKit: event-driven step queue (replaces the asyncAfter cascade)

`Sources/memterm/ProbeKit.swift` defines:

```swift
struct ProbeStep {
    let name: String                     // machine-parseable, e.g. "close-pane"
    let timeout: TimeInterval            // per-step budget, generous (default 10s)
    let action: () -> Void               // perform the gesture / mutation
    let condition: () -> Bool            // polled on main every 50ms until true
    let assert: () throws -> Void        // outcome assertions, run once condition holds
    let onFailure: () -> Void            // extra diagnostics (tree dumps, screenshots)
}

final class ProbeRunner {
    init(prefix: String, mode: String)   // "UIPROBE" or "SMOKE"
    func add(_ step: ProbeStep)
    func addStateful(_ step: ProbeStep)  // registers for fresh AND restored manifests
    func run()                           // sequential: action → poll condition → assert → next
}
```

Semantics:
- **Sequential and condition-driven.** A step starts only when the previous step's `condition` held and its `assert` passed. No absolute wall-clock offsets anywhere; the only clock is the per-step `timeout`. This deletes the entire "fixed asyncAfter racing async work" defect class (bug 4) rather than patching legs one at a time (the e5231a9 pattern).
- **Per-step output, always:** `UIPROBE-STEP i/N name=<name> ms=<elapsed>` on success; on failure `UIPROBE-FAIL step=<name> waited=<ms> reason=<...>` followed by the standard dump: `probeTreeDump()` for every controller, window list with frames, `UIPROBE-TABS-DEBUG`, and a screenshot PNG written to `$MEMTERM_PROBE_OUT/<step>.png`. **No `exit(1)` may execute without a printed FAIL line naming a step** — legs call `probeFail(_:)` / throw `ProbeFailure`, and the runner owns exit.
- **Sentinel protocol — a partial run can NEVER read green:**
  - `ProbeRunner.run()` prints the manifest first: `UIPROBE-BEGIN steps=<N> build=<stamp> mode=<mode> statedir=<dir>`.
  - Success prints exactly `UIPROBE-PASS steps=N/N` then `exit(0)`.
  - An `atexit` handler installed at probe start prints `UIPROBE-ABORT completed=i/N` if the process exits by any other path (crash-safe teardown, last-window-close, terminate).
  - In probe/smoke modes `applicationShouldTerminateAfterLastWindowClosed` returns `false` — a mid-run empty app is a FAIL, not a clean quit.
  - **The runner (verify.sh) greps for the PASS sentinel with matching step counts; exit code 0 alone is never a pass.** Same protocol for smoke: `SMOKE-PASS run=save|verify steps=N/N`.
- `MEMTERM_UI_PROBE=1` combined with `--smoke` is rejected at startup with a printed error and exit 2.
- Kept verbatim inside steps: the ObjectIdentifier identity sets, `kill(pid, 0)` on original shell pids, tcgetpgrp foreground checks, byte-identical frame checks, gesture-path fidelity (`probeClickClose` through the real button action, rename through the real sheet, Esc via the field editor's `doCommand(cancelOperation:)`), journal round-trip assertions, and the consent-gated serial restore assertions. The step queue changed *scheduling and reporting*, not the assertions.

### 2.2 State and config isolation — enforced, not conventional

- `main.swift` extends the `--smoke` temp-dir defaulting to `MEMTERM_UI_PROBE=1`: any probe launch without `MEMTERM_STATE_DIR` gets a fresh temp dir.
- Belt-and-suspenders: `runUIProbe`/`runSmoke` (and main.swift before them) **refuse to start** (exit 2, printed reason) if the resolved state dir is under `~/Library/Application Support/memterm`. The probe deletes journal rows and scrollback bytes through the FR-56 forget path; it must be structurally unable to do that to the founder's real state.
- Env override `MEMTERM_CONFIG_PATH` in `Config.load()`, parallel to `MEMTERM_STATE_DIR`. Probe/smoke runs never read `~/.config/memterm/config.toml` and never write a default file into the founder's home: unset in probe mode means built-in defaults from a temp path. This is what makes the config matrix (§2.3) possible and closes the "runner's personal config silently changes coverage" hole.
- Config-conditional steps (e.g. `workspace_bar=false`) print `UIPROBE-SKIP step=<name> reason=<config>` — loud and legal only where the config warrants it. Skip ≠ pass; verify.sh asserts the expected skips per config.

### 2.3 Frame + pixel assertion helpers (the layer bugs 1 and 2 lived above)

In `ProbeKit.swift`:

```swift
func probeBitmap(_ view: NSView) -> NSBitmapImageRep?          // cacheDisplay(in: bounds)
func probeWindowImage(_ window: NSWindow) -> CGImage?          // CGWindowListCreateImage; visible mode only
func assertPaneGeometry(_ pane: NSView, paneId: String, minSide: CGFloat = 50) throws
func assertRendered(_ bmp: NSBitmapImageRep, region: CGRect, what: String) throws
    // region non-empty AND non-uniform (>= 2 distinct sampled colors, 16x16 grid)
func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat      // WCAG relative luminance
func assertChipVisible(chipFrame: CGRect, in bmp: NSBitmapImageRep, what: String, minRatio: CGFloat = 1.6) throws
```

Mandatory uses:
- **At-launch geometry step (first step of every restored/observe run):** for every restored pane, `assertPaneGeometry` + `assertRendered` on a `probeBitmap` of the content view after layout settles. The old `UIPROBE-TREE at_launch` print is an assertion now. *(Catches bug 1: the 979/0 collapse fails in the first step of every restored run.)*
- **Chip visibility** is asserted over the rendered chrome bitmap (`chip-contrast-rendered`), not layer-color equality.
- **Config matrix:** verify.sh runs the probe over `{default, founder-like: opacity 0.37 + blur, workspace_bar=false, light theme, dark theme}` via `MEMTERM_CONFIG_PATH`, with chip contrast asserted per config. *(Catches bug 2.)*
- All failure-path bitmaps (and the per-config chip-bar success shots) are archived as PNGs under `$MEMTERM_PROBE_OUT` and listed in the verify report so a human can eyeball what the gate saw.
- Caveat, documented here so nobody "fixes" it: `cacheDisplay` sees the view's own rendering, not window-server compositing. Opacity/blur/occlusion truths need the on-screen `probeWindowImage` pass, which is why one **visible** pixel pass survives in verify.sh (§2.5).

### 2.4 Fresh / restored / observe — every stateful step runs in both worlds by construction

`MEMTERM_PROBE_MODE` selects the world; the step list is shared:

- **`fresh`** (the old behavior, rescheduled): fixtures created in-run, gesture steps against them.
- **`restored`**: verify.sh seeds `MEMTERM_STATE_DIR` from a `--smoke=save` capture, then launches the probe. Restoration happens through the REAL `restoreWindows()` launch pipeline — attach-before-first-layout ordering, `fadeInPending`, and all. The first step asserts restored topology, geometry, and rendering (§2.3) **before any step creates fresh state**; then the same gesture steps run against the *restored* world — close-pane targets the restored 2-pane tab. *(Catches bug 3 — close-pane on a restored split is now a permanent gate step — and bug 1.)* The one surviving hand-built `TabRestore` fixture is the serial consent-gate leg, which asserts the never-auto-open-on-restore contract; it is not a stand-in for restored-world gesture coverage.
- **`observe`** — the side-effect quarantine step: launch against the seeded dir, create **nothing**, force **nothing** (no fixtures, no probe workspace), assert the bar, tabs, and restored tree exactly as a plain founder launch would present them, print the sentinel, exit. This is the anti-self-masking gate: a run that cannot mask launch-path bugs with probe interference.
- Registration API makes the matrix structural: `runner.addStateful(_:)` registers a step for both `fresh` and `restored` manifests (and excludes it from `observe`); a stateful step cannot be registered fresh-only.

### 2.5 Quiet mode by default

Probes must be cheap to run on every commit — screen-stealing is why gates get skipped.

- Default: `NSApp.setActivationPolicy(.accessory)`, **no** `activate(ignoringOtherApps:)`, windows positioned offscreen via a `constrainFrameRect(_:to:)` override on the probe window class (`ProbeQuietWindow`). Focus assertions survive because `keyHost()` falls back to `lastFocusedHost` when activation is denied (this is precisely why that mechanism is on the keep-list).
- The fullscreen step in quiet mode asserts the chrome across a styleMask-scale frame transition instead of driving a real Spaces animation.
- `MEMTERM_PROBE_VISIBLE=1` opts into the old behavior: `.regular` policy, on-screen windows, real fullscreen toggle, and the composited `probeWindowImage` contrast pass. verify.sh runs the matrix quiet and ONE visible pass (founder-like config) for the composited-pixel truths.

### 2.6 Smoke v2

The two-run capture→restore shape is correct and kept; run selection is explicit:
- `--smoke=save` and `--smoke=verify` replace inference-from-`restoredAnything`. Bare `--smoke` is an error naming the two subcommands.
- The runner always creates a fresh `mktemp -d` state dir and passes it to both runs; the stable `$TMPDIR/memterm-smoke` dir is gone. `--smoke=verify` refuses (loud FAIL) a dir missing the marker file `--smoke=save` writes; `--smoke=save` refuses a non-empty dir.
- `--smoke=save`'s deliberate `exit()`-without-teardown is kept and named in its output: `SMOKE-SAVE crash-sim=true` — proving the journal survives a hard kill is a feature.
- Run-2 assertions include the restored-geometry golden: dump `(pane → rect, dividerCount, focusedTab, firstResponder target)` at a fixed window size and diff against the committed golden (`Tests/goldens/smoke-restore-geometry.txt`), extending the `PreMigrationRestoreTests` byte-fixture pattern up one layer.
- Both runs print the `SMOKE-PASS run=... steps=N/N` sentinel; smoke keeps `switchFadeEnabled=false`, and the probe (which runs with fades on) covers the fade path in its workspace-switch legs.

### 2.7 Perf probes stop lying

`--latency`, `--flood`, `--bench` compare their measurements to the printed kill-criteria and exit nonzero on violation (`LATENCY-FAIL p95=<ms> required=<ms>`), printing `*-PASS` sentinels otherwise. They record window occlusion state and the build stamp so numbers are interpretable. If a threshold must be waived, it is waived in verify.sh with a printed reason — never by the probe silently passing.

---

## 3. PROCESS SPEC

### 3.1 Build identity

- `scripts/make-app.sh` generates `Sources/memterm/BuildStamp.generated.swift` (gitignored; the checked-in `BuildStamp.swift` fallback carries `"dev-unstamped"`): `gitHash` (`git rev-parse --short HEAD`, `-dirty` suffixed when applicable), `buildTimeUTC`, and writes `CFBundleVersion = git rev-list --count HEAD`, `CFBundleShortVersionString = 0.1.<count>` into Info.plist.
- `main.swift` handles `--version` **before any other flag**: prints `memterm <version> (<hash>[-dirty]) built <time>` and exits 0.
- **Every** probe/smoke/bench run prints the stamp as its first output line (it is part of the `*-BEGIN` line) — every gate log self-identifies its binary. *(Bug 5's fix.)*

### 3.2 make-app.sh clean-tree enforcement

- `git status --porcelain` non-empty → refuse with the dirty file list, unless `MEMTERM_ALLOW_DIRTY=1`, and a forced dirty build ALWAYS carries the `-dirty` stamp. A `-dirty` artifact can never satisfy the verify identity check (§3.3), so dirty evidence is structurally unable to masquerade as artifact evidence.
- Keeps: exactly one artifact at `dist/memterm.app`, `rm -rf` before assemble, `dist/` gitignored. Artifact identity = embedded git stamp + **post-codesign** sha256 of the binary (codesign mutates it, so `.build/release` hashes never match — record the dist hash).

### 3.3 scripts/verify.sh — the single verification entrypoint

The gate IS this script. Humans and agents run nothing else to claim green.

1. **Preflight:** `git status --porcelain` empty (or explicit `--allow-dirty`, which taints the report); record HEAD sha.
2. `swift test` (L1/L2).
3. `scripts/make-app.sh` → the one stamped release artifact.
4. **Identity check:** `dist/memterm.app/Contents/MacOS/memterm --version` must report the recorded HEAD hash, non-dirty. Never rebuild between this check and the probes.
5. Run everything **against the dist binary**: `--config-dump`; `--bench`/`--latency`/`--flood` with enforced thresholds; `--smoke=save` + `--smoke=verify` in a fresh `mktemp` dir; `MEMTERM_UI_PROBE=1` in `fresh`, `restored` (seeded from a smoke save), and `observe` modes; the config matrix (quiet) + one visible pixel pass; serial coverage via the probe's pty-pair legs (real `/dev/cu.*` nodes are never touched; `MEMTERM_SERIAL_PROBE_PTY` remains the connect-sheet stand-in hook).
6. **Pass criterion = grepped sentinels with matching step counts** (`UIPROBE-PASS steps=N/N`, `SMOKE-PASS`, `LATENCY-PASS`, ...). Exit codes are necessary, never sufficient.
7. Write `dist/verify-report-<hash>.log`: build stamp, post-sign binary sha256, per-gate results, state-dir lines proving isolation, screenshot paths. This file is the ONLY citable gate evidence.

### 3.4 Pre-merge checklist (feature branch → main; each item mechanically checkable)

1. Working tree clean; branch rebased on main.
2. `scripts/verify.sh` green AT the candidate commit; its report file cited by name in the merge commit.
3. `--version` of `dist/memterm.app` matches that commit's hash; exactly one app at `dist/memterm.app`.
4. Every new user-visible behavior has its L1/L2 test where logic permits, its probe step, and — if stateful — the restored twin (§1 placement rule).
5. Screenshot evidence at default AND founder-like config attached via the report.
6. Report's state-dir lines confirm no run touched `~/Library/Application Support/memterm`.
7. Consent invariants re-asserted (⌘R no-newline, denylist-precedes-offers, never-auto-open serial on restore).
8. No step weakened, deleted, or threshold loosened without being called out in the merge description.
9. **Flake policy:** a step that needed a retry is a bug in the step, filed before merge. "Exit 0 (twice)" is banned as evidence.

### 3.5 Evidence rules

- Gate evidence must name the commit sha and artifact hash it ran against; commit prose stops carrying hand-typed result numbers — it references the verify report.
- Keep e5231a9's epistemic discipline in every report: findings classified REAL BUG vs PROBE-ONLY, with observed frequencies.

---

## 4. FOUNDER-BUG REGRESSION MAP (named checks)

| Escape | Named regression check |
|---|---|
| 1 — restored splits collapse at launch | probe step `at-launch-geometry` (restored/observe modes; assertPaneGeometry + assertRendered) · `SplitLayoutTests.testNoZeroPaneInNonZeroContainer` · smoke `verify-restore-geometry-golden` |
| 2 — chips invisible at opacity 0.37 | probe step `chip-contrast-rendered` under the verify.sh config matrix (incl. founder-like 0.37+blur) · `ChromeContrastTests.testOpaqueChromeRowHoldsFloorAcrossOpacityRange` / `testTranslucentChromeRowFailsAtFounderOpacity` |
| 3 — close-pane blanked a restored tab | probe step `close-pane` in `MEMTERM_PROBE_MODE=restored` (targets the restored 2-pane tab) |
| 4 — probe false-greens | ProbeRunner sentinel protocol (`*-BEGIN`/`*-PASS steps=N/N`/`*-ABORT`), condition-driven steps, `addStateful` shared manifests, probe-never-auto-quits |
| 5 — evidence hygiene | `BuildStamp` + `--version`-in-every-BEGIN-line · make-app.sh dirty refusal + `-dirty` stamp · verify.sh identity check + report |

---

## 5. KEEP-LIST (the do-not-break contract)

- MemtermCore extraction + all ~240 outcome-first XCTests untouched — StateStoreTests corruption/torn-write coverage, PreMigrationRestoreTests byte-authored fixtures, CloseForgetTests bytes-on-disk FR-56/57 semantics, AdaptersTests FR-30 adversarial denylist cases, SerialAdversarialTests hand-computed hex oracle, ShellIntegrationZshTests hermetic real-zsh runs, ScrollbackTextTests path-traversal containment. Relabeled: model-correctness evidence only.
- The extracted-seam pattern (TabStripLayout, SwitchSupport, TabActivity/WorkspaceActivity with injected clocks, CwdFallback, FindSupport, SplitNode JSON round-trip) — the template for the SplitLayout/ChromeContrast/FocusIntent seams.
- MEMTERM_STATE_DIR isolation (MemoryEngine.baseDir override) and temp-dir defaulting — now enforced for the UI probe too; never weaken.
- Kernel-truth probe assertions verbatim: kill(pid,0) on original shell pids, tcgetpgrp/ProcessInspector foreground checks, ObjectIdentifier identity sets over controllers AND panes, byte-identical frame checks across FR-59 switches.
- Gesture-path fidelity: probeClickClose through the real button action, rename via the real sheet controls, Esc via the field editor's doCommand(cancelOperation:).
- Journal round-trip assertions at the store (flushSync/pollNow + loadState/counts/barrier).
- The two-run capture-then-restore smoke CONCEPT, including run 1's deliberate exit()-as-crash-simulation (`SMOKE-SAVE crash-sim=true`) and its identity/parked/FR-56 non-restore assertions.
- The pty-pair serial stand-in (posix_openpt, full termios, revoke-on-close) + the MEMTERM_SERIAL_PROBE_PTY hook and the hard rule that real /dev/cu.* nodes are never touched.
- Consent-gate serial restore assertions: never auto-open on restore, honest ⌘R-with-absent-device line, denylist-precedes-offers.
- lastFocusedHost as the model's own focus notion (keyHost fallback under denied activation) — what makes quiet/accessory probe mode feasible.
- Greppable key=value evidence lines (UIPROBE-*/SMOKE-*) and the rich diagnostic dumps — generalized to every step under the sentinel protocol.
- The strip hit-test primitives (probeTabId(atContentX:), probeItemFrame) and label/body-color contrast-flip accessors — kept alongside the rendered-bitmap assertions.
- make-app.sh minimalism: exactly one artifact at dist/memterm.app, rm -rf before assemble, dist/ gitignored — extended with stamping and the dirty guard, not replaced.
- --config-dump self-check and the --bench/--latency/--flood workloads with their named M0 kill-criteria — in verify.sh, with enforced thresholds.
- e5231a9's epistemic discipline: findings classified REAL BUG vs PROBE-ONLY with observed frequencies — institutionalized in the verify report format.
- Founder-bug-to-leg traceability (§4) and rich narrative commit messages — with RESULTS moved out of prose into the cited verify report.
