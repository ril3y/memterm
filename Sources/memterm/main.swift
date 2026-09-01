import Foundation
import MemtermCore

let arguments = CommandLine.arguments.dropFirst()

// --version FIRST, before any other flag (TESTING.md §3.1): every gate and
// every human can ask a binary exactly what it is. A dev build answers
// "dev-unstamped" and can never satisfy the verify.sh identity check.
if arguments.contains("--version") {
    print("memterm \(BuildStamp.version) (\(BuildStamp.gitHash)) built \(BuildStamp.buildTimeUTC)")
    exit(0)
}

if arguments.contains("--bench") {
    runBench()
    exit(0)
}

// Headless check of config parsing + font resolution (FR-44 wiring).
if arguments.contains("--config-dump") {
    let c = Config.load()
    print("config: \(Config.configURL.path)")
    print("font_family=\(c.fontFamily ?? "(auto)") -> \(c.resolveFont(size: CGFloat(c.fontSize)).fontName) @ \(c.fontSize)pt")
    print("copy_on_select=\(c.copyOnSelect) scrollback_lines=\(c.scrollbackLines) shell=\(c.shell ?? "(env $SHELL)") shell_integration=\(c.shellIntegration)")
    print("new_tab_same_cwd=\(c.newTabSameCwd) option_as_meta=\(c.optionAsMeta) bell_style=\(c.bellStyle) cursor_style=\(c.cursorStyle) always_show_tab_bar=\(c.alwaysShowTabBar) (no-op)")
    print("confirm_quit=\(c.confirmQuit) allow_mouse_reporting=\(c.allowMouseReporting) bell_sound=\(c.bellSound ?? "(system beep)") line_spacing=\(c.lineSpacing) window_opacity=\(c.windowOpacity) window_blur=\(c.windowBlur)")
    print("serial_tx_line_ending=\(c.serialTxLineEnding) serial_local_echo=\(c.serialLocalEcho)")
    print("theme: bg=\(c.themeBackground != nil) fg=\(c.themeForeground != nil) cursor=\(c.themeCursor != nil) selection=\(c.themeSelection != nil) ansi16=\(c.ansiColors != nil) preset=\(c.themePreset ?? "(none)")")
    exit(0)
}

let mode: RunMode = arguments.contains("--latency") ? .latency
                  : arguments.contains("--flood") ? .flood
                  : .interactive

// --smoke=save / --smoke=verify (TESTING.md §2.6): run selection is explicit;
// the old inference-from-restoredAnything (and the stable $TMPDIR/memterm-smoke
// dir two runs silently shared) are gone.
var smokeRun: SmokeRun?
for arg in arguments where arg.hasPrefix("--smoke") {
    switch arg {
    case "--smoke=save": smokeRun = .save
    case "--smoke=verify": smokeRun = .verify
    default:
        print("SMOKE-FAIL bare --smoke is not a run: use --smoke=save (capture run) or --smoke=verify (restore run)")
        exit(2)
    }
}

let uiProbe = ProcessInfo.processInfo.environment["MEMTERM_UI_PROBE"] == "1"

// The probe and the smoke are different worlds; combining them is a harness
// bug, rejected loudly (TESTING.md §2.1).
if uiProbe, smokeRun != nil {
    print("UIPROBE-FAIL MEMTERM_UI_PROBE=1 cannot be combined with --smoke")
    exit(2)
}

// State isolation, ENFORCED not conventional (TESTING.md §2.2): any probe or
// smoke-save launch without MEMTERM_STATE_DIR gets a fresh temp dir; a
// smoke-verify without one has nothing to verify and fails loudly.
if uiProbe || smokeRun != nil {
    let env = ProcessInfo.processInfo.environment
    if env["MEMTERM_STATE_DIR"] == nil || env["MEMTERM_STATE_DIR"]?.isEmpty == true {
        if smokeRun == .verify {
            print("SMOKE-FAIL --smoke=verify needs MEMTERM_STATE_DIR pointing at a --smoke=save capture")
            exit(2)
        }
        let fresh = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("memterm-\(uiProbe ? "probe" : "smoke")-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: fresh,
                                                 withIntermediateDirectories: true)
        setenv("MEMTERM_STATE_DIR", fresh, 1)
    }

    // Config isolation (§2.2): probe/smoke runs never read — and never write
    // a default file into — ~/.config/memterm. Unset means built-in defaults
    // materialized at a temp path.
    if env["MEMTERM_CONFIG_PATH"] == nil || env["MEMTERM_CONFIG_PATH"]?.isEmpty == true {
        let configPath = (ProcessInfo.processInfo.environment["MEMTERM_STATE_DIR"]!
            as NSString).appendingPathComponent("probe-config.toml")
        setenv("MEMTERM_CONFIG_PATH", configPath, 1)
    }

    // Belt one of two (the other sits in runUIProbe/runSmoke): never against
    // the founder's real state.
    ProbeSupport.refuseRealStateDir(prefix: uiProbe ? "UIPROBE" : "SMOKE")

    // Smoke run preconditions (§2.6): save refuses a non-empty dir; verify
    // refuses a dir without the save marker.
    let stateDir = ProcessInfo.processInfo.environment["MEMTERM_STATE_DIR"]!
    let fm = FileManager.default
    if smokeRun == .save {
        let contents = (try? fm.contentsOfDirectory(atPath: stateDir)) ?? []
        if !contents.isEmpty {
            print("SMOKE-FAIL --smoke=save refuses non-empty state dir \(stateDir) (contents: \(contents))")
            exit(2)
        }
    }
    if smokeRun == .verify {
        let marker = (stateDir as NSString).appendingPathComponent(SmokeRun.markerFileName)
        if !fm.fileExists(atPath: marker) {
            print("SMOKE-FAIL --smoke=verify: \(stateDir) carries no \(SmokeRun.markerFileName) — not a --smoke=save capture")
            exit(2)
        }
    }
}

runApp(mode: mode, smoke: smokeRun)
