import Foundation

let arguments = CommandLine.arguments.dropFirst()

if arguments.contains("--bench") {
    runBench()
    exit(0)
}

// Headless check of config parsing + font resolution (FR-44 wiring).
if arguments.contains("--config-dump") {
    let c = Config.load()
    print("config: \(Config.configURL.path)")
    print("font_family=\(c.fontFamily ?? "(auto)") -> \(c.resolveFont(size: c.fontSize).fontName) @ \(c.fontSize)pt")
    print("copy_on_select=\(c.copyOnSelect) scrollback_lines=\(c.scrollbackLines) shell=\(c.shell ?? "(env $SHELL)")")
    print("theme: bg=\(c.themeBackground != nil) fg=\(c.themeForeground != nil) cursor=\(c.themeCursor != nil) ansi16=\(c.ansiColors != nil)")
    exit(0)
}

let mode: RunMode = arguments.contains("--latency") ? .latency
                  : arguments.contains("--flood") ? .flood
                  : .interactive
// --smoke: deterministic capture/restore self-test (see MemtermApp.runSmoke).
runApp(mode: mode, smoke: arguments.contains("--smoke"))
