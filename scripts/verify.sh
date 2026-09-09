#!/bin/bash
# scripts/verify.sh — THE single verification entrypoint (TESTING.md §3.3).
# Humans and agents run nothing else to claim green. Pass criterion = grepped
# sentinels with matching step counts against the STAMPED dist artifact;
# exit codes are necessary, never sufficient. Writes
# dist/verify-report-<hash>.log — the only citable gate evidence.
#
# Usage: scripts/verify.sh [--allow-dirty]   (--allow-dirty TAINTS the report)
set -u
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

ALLOW_DIRTY=0
for arg in "$@"; do [ "$arg" = "--allow-dirty" ] && ALLOW_DIRTY=1; done

# ---------------------------------------------------------------- preflight
TAINT=""
DIRTY="$(git status --porcelain)"
if [ -n "$DIRTY" ]; then
    if [ "$ALLOW_DIRTY" = "1" ]; then
        TAINT="TAINTED: run with --allow-dirty on a dirty tree — NOT evidence about a committed artifact"
        echo "verify.sh: WARNING $TAINT" >&2
    else
        echo "verify.sh: FAIL preflight — working tree dirty (commit or stash, or pass --allow-dirty for a TAINTED run):"
        echo "$DIRTY"
        exit 1
    fi
fi
HEAD_HASH="$(git rev-parse --short HEAD)"
HEAD_FULL="$(git rev-parse HEAD)"

WORK="$(mktemp -d)"
LOG="$WORK/logs"; mkdir -p "$LOG"
export MEMTERM_PROBE_OUT="$WORK/evidence"; mkdir -p "$MEMTERM_PROBE_OUT"
GOLDEN="$REPO_ROOT/Tests/goldens/smoke-restore-geometry.txt"

OVERALL=0
RESULTS="$WORK/results.txt"; : > "$RESULTS"

note() { echo "$*"; echo "$*" >> "$RESULTS"; }

# check <gate> <log> <sentinel-regex> — a gate is green ONLY if its sentinel
# line is present (completion counts are embedded in the sentinels: PASS
# lines print steps=N/N with identical numerator/denominator by construction,
# and an ABORT/FAIL line marks any partial run).
check() {
    local name="$1" log="$2" regex="$3"
    if grep -qE "ABORT|-FAIL " "$log"; then
        note "GATE FAIL $name — FAIL/ABORT sentinel present ($(grep -E 'ABORT|-FAIL ' "$log" | head -1))"
        OVERALL=1
        tail -25 "$log" | sed 's/^/    /'
        return
    fi
    if grep -qE "$regex" "$log"; then
        note "GATE PASS $name — $(grep -E "$regex" "$log" | head -1)"
    else
        note "GATE FAIL $name — required sentinel /$regex/ absent (log: $log)"
        OVERALL=1
        tail -25 "$log" | sed 's/^/    /'
    fi
}

# ---------------------------------------------------------------- L1/L2
echo "== [1/8] swift test (L1 model truth + L2 headless seams)"
if swift test > "$LOG/swift-test.log" 2>&1; then
    TESTCOUNT="$(grep -cE " passed \(" "$LOG/swift-test.log" || true)"
    note "GATE PASS swift-test — $TESTCOUNT tests passed"
else
    note "GATE FAIL swift-test"
    OVERALL=1
    grep -E "error|failed" "$LOG/swift-test.log" | head -20 | sed 's/^/    /'
fi

# ---------------------------------------------------------------- firewall
echo "== [2/8] extension import firewall (structural CI backstop)"
scripts/check-extension-firewall.sh > "$LOG/firewall.log" 2>&1
check "extension-firewall" "$LOG/firewall.log" "FIREWALL-PASS "

# ---------------------------------------------------------------- artifact
echo "== [3/8] stamped release artifact (make-app.sh)"
if [ "$ALLOW_DIRTY" = "1" ]; then
    MEMTERM_ALLOW_DIRTY=1 scripts/make-app.sh > "$LOG/make-app.log" 2>&1
else
    scripts/make-app.sh > "$LOG/make-app.log" 2>&1
fi
if [ $? -ne 0 ]; then
    note "GATE FAIL make-app.sh"
    OVERALL=1
    tail -20 "$LOG/make-app.log" | sed 's/^/    /'
    # Without an artifact nothing downstream is meaningful.
    echo "verify.sh: cannot continue without dist/memterm.app"
    exit 1
fi
BIN="$REPO_ROOT/dist/memterm.app/Contents/MacOS/memterm"
BIN_SHA="$(shasum -a 256 "$BIN" | cut -d' ' -f1)"

# Founder rule: exactly ONE app build at dist/memterm.app.
APPCOUNT="$(find "$REPO_ROOT/dist" -maxdepth 1 -name "*.app" | wc -l | tr -d ' ')"
if [ "$APPCOUNT" = "1" ]; then
    note "GATE PASS single-artifact — dist holds exactly one .app"
else
    note "GATE FAIL single-artifact — $APPCOUNT .app bundles under dist/"
    OVERALL=1
fi

# ---------------------------------------------------------------- identity
echo "== [4/8] artifact identity (--version vs HEAD; no rebuild after this)"
VERSION_LINE="$("$BIN" --version)"
note "ARTIFACT $VERSION_LINE"
note "ARTIFACT sha256(post-codesign)=$BIN_SHA"
if echo "$VERSION_LINE" | grep -q "($HEAD_HASH)"; then
    note "GATE PASS identity — artifact reports HEAD $HEAD_HASH, clean"
elif [ "$ALLOW_DIRTY" = "1" ] && echo "$VERSION_LINE" | grep -q "($HEAD_HASH-dirty)"; then
    note "GATE PASS identity (TAINTED) — artifact reports $HEAD_HASH-dirty"
else
    note "GATE FAIL identity — artifact says '$VERSION_LINE', HEAD is $HEAD_HASH"
    OVERALL=1
fi

# ---------------------------------------------------------------- gates
echo "== [5/8] headless + perf gates against the dist binary"
CFGDIR="$WORK/configs"; mkdir -p "$CFGDIR"
: > "$CFGDIR/default.toml"
printf 'window_opacity = 0.37\nwindow_blur = true\n' > "$CFGDIR/founder.toml"
printf 'workspace_bar = false\n' > "$CFGDIR/nobar.toml"
printf '[theme]\nbackground = "#ffffff"\nforeground = "#1d1f21"\ncursor = "#1d1f21"\n' > "$CFGDIR/light.toml"
printf '[theme]\nbackground = "#1d1f21"\nforeground = "#c5c8c6"\ncursor = "#c5c8c6"\n' > "$CFGDIR/dark.toml"

MEMTERM_CONFIG_PATH="$CFGDIR/default.toml" "$BIN" --config-dump > "$LOG/config-dump.log" 2>&1
check "config-dump" "$LOG/config-dump.log" "^config: "

"$BIN" --bench   > "$LOG/bench.log" 2>&1;  check "bench"   "$LOG/bench.log"   "BENCH-PASS "
"$BIN" --latency > "$LOG/latency.log" 2>&1; check "latency" "$LOG/latency.log" "LATENCY-PASS p95_total="
"$BIN" --flood   > "$LOG/flood.log" 2>&1;  check "flood"   "$LOG/flood.log"   "FLOOD-PASS worst_stall="

echo "== [6/8] smoke (reboot-restore promise, capture -> crash-sim -> restore)"
SMOKEDIR="$(mktemp -d)"
MEMTERM_STATE_DIR="$SMOKEDIR" MEMTERM_CONFIG_PATH="$CFGDIR/default.toml" \
    "$BIN" --smoke=save > "$LOG/smoke-save.log" 2>&1
check "smoke-save" "$LOG/smoke-save.log" "SMOKE-PASS run=save steps=([0-9]+)/\1"
MEMTERM_STATE_DIR="$SMOKEDIR" MEMTERM_CONFIG_PATH="$CFGDIR/default.toml" \
    MEMTERM_SMOKE_GOLDEN="$GOLDEN" \
    "$BIN" --smoke=verify > "$LOG/smoke-verify.log" 2>&1
check "smoke-verify" "$LOG/smoke-verify.log" "SMOKE-PASS run=verify steps=([0-9]+)/\1"
check "smoke-geometry-golden" "$LOG/smoke-verify.log" "SMOKE-GEOMETRY golden=match"
# Founder bug 2026-09-09 (duplicate window at launch): the seed carries a
# hidden-unparked workspace; launch must show exactly the active one and
# leave C journaled for a lazy resurrect on switch-in.
check "smoke-launch-visible" "$LOG/smoke-verify.log" "SMOKE-LAUNCH-VISIBLE hosts=1 visible=1 stray=0 c_restored=false"
check "smoke-lazy-resurrect" "$LOG/smoke-verify.log" "SMOKE-LAZY-RESURRECT c_tabs=1 visible=1 stray=0 "

echo "== [7/8] UI probe: fresh / restored / observe + config matrix (+1 visible pass)"
probe() {  # probe <label> <mode> <configfile> <statedir(optional)> [visible]
    local label="$1" pmode="$2" cfg="$3" sdir="${4:-}" vis="${5:-}"
    local envs=(MEMTERM_UI_PROBE=1 "MEMTERM_PROBE_MODE=$pmode" "MEMTERM_CONFIG_PATH=$cfg")
    [ -n "$sdir" ] && envs+=("MEMTERM_STATE_DIR=$sdir")
    [ -n "$vis" ] && envs+=(MEMTERM_PROBE_VISIBLE=1)
    env "${envs[@]}" "$BIN" > "$LOG/probe-$label.log" 2>&1
    check "probe-$label" "$LOG/probe-$label.log" "UIPROBE-PASS steps=([0-9]+)/\1"
}

# fresh world, default config (quiet). The serial legs inside every probe
# pass run against a pty pair (never /dev/cu.*) — the MEMTERM_SERIAL_PROBE_PTY
# stand-in convention's harness-owned twin.
probe "fresh-default" fresh "$CFGDIR/default.toml"

# restored world: seeded from a REAL --smoke=save capture, restored through
# the REAL restoreWindows() pipeline. Bugs 1 and 3's permanent gate.
SEED1="$(mktemp -d)"
MEMTERM_STATE_DIR="$SEED1" MEMTERM_CONFIG_PATH="$CFGDIR/default.toml" \
    "$BIN" --smoke=save > "$LOG/seed-restored.log" 2>&1
check "seed-for-restored" "$LOG/seed-restored.log" "SMOKE-PASS run=save steps=([0-9]+)/\1"
probe "restored-default" restored "$CFGDIR/default.toml" "$SEED1"

# observe: the side-effect quarantine — a pristine seed, zero fixtures.
SEED2="$(mktemp -d)"
MEMTERM_STATE_DIR="$SEED2" MEMTERM_CONFIG_PATH="$CFGDIR/default.toml" \
    "$BIN" --smoke=save > "$LOG/seed-observe.log" 2>&1
check "seed-for-observe" "$LOG/seed-observe.log" "SMOKE-PASS run=save steps=([0-9]+)/\1"
probe "observe" observe "$CFGDIR/default.toml" "$SEED2"

# config matrix, quiet (chip contrast asserted per config — bug 2's gate;
# founder-like = the exact opacity 0.37 + blur that shipped the escape).
probe "matrix-founder" fresh "$CFGDIR/founder.toml"
# Founder bug 2026-09-09 (translucent margin seam): the leg must MEASURE a
# match at 0.37, never skip; opaque configs skip by design.
check "matrix-founder-seam" "$LOG/probe-matrix-founder.log" "UIPROBE-SEAM-MODEL opacity=0.37 pane_alpha=0.00 window_alpha=0.37 cells_follow_opacity=true ok=true"
check "fresh-default-seam-skips" "$LOG/probe-fresh-default.log" "UIPROBE-SKIP step=translucent-ground-seam reason=window_opacity=1"
check "fresh-default-capture-cells" "$LOG/probe-fresh-default.log" "UIPROBE-CAPTURE-CELLS gap_ok=true nul=false"
probe "matrix-nobar"   fresh "$CFGDIR/nobar.toml"
check "matrix-nobar-skips" "$LOG/probe-matrix-nobar.log" "UIPROBE-SKIP step=chip-contrast-rendered reason=workspace_bar=false"
check "matrix-nobar-skips-centering" "$LOG/probe-matrix-nobar.log" "UIPROBE-SKIP step=chip-vertical-centering reason=workspace_bar=false"
check "matrix-nobar-skips-chipclick" "$LOG/probe-matrix-nobar.log" "UIPROBE-SKIP step=chip-click-rename-gate reason=workspace_bar=false"
check "matrix-nobar-skips-hierarchy" "$LOG/probe-matrix-nobar.log" "UIPROBE-SKIP step=chip-pill-hierarchy reason=workspace_bar=false"
# Appearance › Size scales the chrome (founder bug 2026-09-09): the leg
# must MEASURE a grown pill, never pass vacuously.
check "fresh-default-chrome-scales" "$LOG/probe-fresh-default.log" "UIPROBE-CHROME-SCALE size=20 tab_font=11.0->17.0 "
probe "matrix-light"   fresh "$CFGDIR/light.toml"
probe "matrix-dark"    fresh "$CFGDIR/dark.toml"

# ONE visible pixel pass (founder-like config): on-screen windows, real
# fullscreen round-trip, and the composited probeWindowImage truths that
# cacheDisplay cannot see. This WILL briefly show windows on screen.
probe "visible-founder" fresh "$CFGDIR/founder.toml" "" visible

# ---------------------------------------------------------------- report
echo "== [8/8] report"
REPORT="$REPO_ROOT/dist/verify-report-$HEAD_HASH.log"
{
    echo "memterm verify report"
    echo "commit: $HEAD_FULL ($HEAD_HASH)"
    echo "date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "artifact: $VERSION_LINE"
    echo "artifact sha256 (post-codesign): $BIN_SHA"
    [ -n "$TAINT" ] && echo "$TAINT"
    echo ""
    echo "== gate results"
    cat "$RESULTS"
    echo ""
    echo "== state-dir isolation (every automated run's own statement; none may be under ~/Library/Application Support/memterm)"
    grep -h -E "statedir=|SMOKE-STATE-DIR" "$LOG"/*.log | sort -u
    echo ""
    echo "== evidence screenshots ($MEMTERM_PROBE_OUT)"
    ls -1 "$MEMTERM_PROBE_OUT" 2>/dev/null || echo "(none)"
    echo ""
    echo "== classification (e5231a9 discipline)"
    if [ "$OVERALL" = "0" ]; then
        echo "no findings — all gates green against the stamped artifact"
    else
        echo "REAL-BUG-vs-PROBE-ONLY triage required for the FAIL gates above before any merge"
    fi
    echo ""
    echo "logs retained at: $LOG"
} > "$REPORT"

# Isolation self-check: the report must show no run against the real dir.
if grep -E "statedir=|SMOKE-STATE-DIR" "$LOG"/*.log | grep -q "Library/Application Support/memterm"; then
    echo "verify.sh: GATE FAIL isolation — a run touched the real state dir!" | tee -a "$REPORT"
    OVERALL=1
fi

echo ""
echo "report: $REPORT"
if [ "$OVERALL" = "0" ]; then
    echo "verify.sh: GREEN — all sentinels present against $VERSION_LINE"
else
    echo "verify.sh: RED — see $REPORT"
fi
exit $OVERALL
