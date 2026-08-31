import Foundation
import MemtermCore

let arguments = CommandLine.arguments.dropFirst()

if arguments.contains("--bench") {
    runBench()
    exit(0)
}

// Headless check of config parsing + font resolution (FR-44 wiring).
if arguments.contains("--config-dump") {
    let c = Config.load()
    print("config: \(Config.configURL.path)")
    print("font_family=\(c.fontFamily ?? "(auto)") -> \(c.resolveFont(size: CGFloat(c.fontSize)).fontName) @ \(c.fontSize)pt")
    print("copy_on_select=\(c.copyOnSelect) scrollback_lines=\(c.scrollbackLines) shell=\(c.shell ?? "(env $SHELL)")")
    print("new_tab_same_cwd=\(c.newTabSameCwd) option_as_meta=\(c.optionAsMeta) bell_style=\(c.bellStyle) cursor_style=\(c.cursorStyle) always_show_tab_bar=\(c.alwaysShowTabBar)")
    print("confirm_quit=\(c.confirmQuit) allow_mouse_reporting=\(c.allowMouseReporting) bell_sound=\(c.bellSound ?? "(system beep)") line_spacing=\(c.lineSpacing) window_opacity=\(c.windowOpacity) window_blur=\(c.windowBlur)")
    print("theme: bg=\(c.themeBackground != nil) fg=\(c.themeForeground != nil) cursor=\(c.themeCursor != nil) selection=\(c.themeSelection != nil) ansi16=\(c.ansiColors != nil) preset=\(c.themePreset ?? "(none)")")
    exit(0)
}

let mode: RunMode = arguments.contains("--latency") ? .latency
                  : arguments.contains("--flood") ? .flood
                  : .interactive
// --smoke: deterministic capture/restore self-test (see MemtermApp.runSmoke).
// It defaults the state dir to a stable temp location (two consecutive runs
// share it — run 1 saves, run 2 restores) so the gate is hermetic and never
// touches ~/Library/Application Support/memterm. MEMTERM_STATE_DIR overrides.
let smokeMode = arguments.contains("--smoke")
if smokeMode, ProcessInfo.processInfo.environment["MEMTERM_STATE_DIR"] == nil {
    let smokeDir = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("memterm-smoke")
    setenv("MEMTERM_STATE_DIR", smokeDir, 1)
}
runApp(mode: mode, smoke: smokeMode)
