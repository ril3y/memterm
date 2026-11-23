# memterm

**The terminal that remembers.**

memterm is a macOS terminal that saves your whole working setup as you go: windows, workspaces, tabs, splits, working directories, scrollback, and what each pane was running. Reboot, crash, or quit, and the next launch puts it all back. Claude Code, Codex, SSH, and serial sessions come back one keystroke from resuming.

## Install

Download the latest DMG from [Releases](https://github.com/ril3y/memterm/releases). It is signed with a Developer ID and notarized, so it opens normally. memterm updates itself: it checks daily, and **memterm ▸ Check for Updates…** checks now.

Requires macOS 14 or later.

## Memory

- **Everything restores on every launch.** Old scrollback comes back dimmed above a "restored" divider, and ⌘F searches it.
- **Resume what was running.** A pane that was running Claude Code offers `claude --resume <session>`. Codex panes offer their resume command too. SSH panes offer the same command again, and serial panes reconnect to the same device and settings.
- **You always press Enter.** ⌘R types the resume command and stops; memterm never runs a captured command for you. Dangerous commands (`sudo`, `rm`, `git push --force`, …) are never offered at all.
- **Quit keeps, close files away, Forget deletes.** Quitting keeps everything open for next time. Closing a tab moves it to the Timeline, where you can search it, reopen it, or forget it. Forget commands, up to Forget Everything, really delete.
- **Per-tab shell history.** ↑ in a restored tab shows that tab's commands first. Your `~/.zsh_history` is never touched.

## Workspaces

- Named, colored groups of tabs in a bar at the top. Click to switch, double-click to rename.
- Switching hides and shows. Nothing restarts, so a running build or `ping` keeps going.
- A workspace with unseen output shows a ring, and a pulsing dot while output is flowing.
- Closing a workspace's last tab parks it in the Parked menu with its name and color kept.
- In a narrow window the bar shortens workspace names to initials, then dots.
- ⌃⌘1–9 switches workspaces; ⌘1–9 switches tabs.

## Terminal

- Tab colors, drag to reorder, double-click to rename.
- Splits (⌘D / ⌘⇧D), find in pane (⌘F), and selection that holds still while output streams.
- Right-click a file path or URL to copy it, open it, or reveal it in Finder. Paths that wrap across lines work too.
- New tabs open in the current directory, read from the system, so no shell setup is needed.
- Six built-in themes plus `.itermcolors` import, transparency and blur, Nerd Font detection, option-as-meta.
- **Drop-down terminal:** a global hotkey (a key combo, or a double-tap of ⌃ ⌥ ⌘ ⇧ or Esc) slides a terminal in from the top, left, or right edge. Turn it on in **Settings ▸ Appearance**.

## Agents

Tabs running Claude Code, Codex, or Gemini CLI show what the agent is doing:

- A spinner while it works, an orange dot when it needs you (a permission prompt, a question), and a green dot when it finished while you were in another tab. The workspace chip shows orange or green too.
- A notification when an agent needs you, or finishes while you're not looking. Click it to jump to the pane. The Dock icon counts the agents waiting on you.
- Read-only: memterm watches the screen and never types for the agent. Notifications show the tab's name, never what's on screen.

Settings ▸ Agents turns each part on or off and picks an alert sound. Detection rules are ported from [herdr](https://github.com/herdrdev/herdr) (Apache-2.0).

## Remote attach

Watch and type into your Mac's panes from a phone or another computer's browser. It is off by default, and experimental.

**Bring your own relay for now.** The default relay is a private test server and isn't open to other users yet. Run your own (see below) and point `relay_url` at it.

1. Turn it on in **Settings ▸ Remote**, then click **Pair a device…** to show a QR code.
2. Scan it. The Mac asks "Allow ‹device›?" before anything is granted, so a photo of the QR code is not enough to get in.
3. Revoke any device from the same tab. It is cut off immediately.

A paired device can do what your keyboard can do: see a pane's output, type, resize, and open tabs.

Everything is end-to-end encrypted between the Mac and the device. The relay only passes along encrypted messages and stores nothing. The browser page is built from `relay/web` in this repo and served from GitHub Pages.

To run your own relay, run `fly launch` in `relay/` (it has a `fly.toml` and `Dockerfile`; keep it to one machine), then set `relay_url` under `[remote]` in your config to your app's `wss://` address. `web_url` can point the pairing page at your own copy of `relay/web` too.

## Extensions

- **Timeline:** every closed tab, searchable, with Reopen Here, Resume, and Forget.
- **Claude sessions:** browse your Claude Code conversations and resume one in a new tab.

## Serial

For embedded work: ⌘⇧K opens the connect sheet.

- Ports are listed by USB product name, and baud rate is detected automatically.
- Hex view (⌘⇧X), Send Hex, DTR/RTS toggles, break, and a Reset Board that works for ESP32 and Arduino.
- A status bar shows connection state, baud (changeable live), and TX/RX counters.
- Unplug a device and plug it back in: it reconnects with scrollback intact.

## Keyboard

| | |
|---|---|
| ⌘T / ⌘N | new tab / new window |
| ⌘D / ⌘⇧D | split right / down |
| ⌘⌥ arrows | move between panes |
| ⌘1–9 · ⌃⌘1–9 | tab N · workspace N |
| ⌘F / ⌘G | find in pane |
| ⌘R | type the pane's resume command |
| ⌘⇧K | new serial connection |
| ⌘⇧X | hex view (serial) |
| ⌘, | settings |

## Configuration

One file, `~/.config/memterm/config.toml`, created with commented defaults on first launch. The Settings window (⌘,) reads and writes the same file.

## Building from source

```sh
git clone https://github.com/ril3y/memterm.git && cd memterm
bash scripts/make-app.sh     # release build → dist/memterm.app
open dist/memterm.app
```

Needs a Swift 6 toolchain (Xcode, including its Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`). `dist/memterm.app/Contents/MacOS/memterm --version` prints the commit a binary was built from.

- `swift test` runs the unit tests. `scripts/verify.sh` is the full gate: tests, restore smoke test, UI probes, and performance checks against the release app. See `TESTING.md`.
- `REQUIREMENTS.md` is the product spec.
- **Releasing:** push a `vX.Y.Z` tag. The Release workflow builds, signs, and notarizes the DMG, publishes it on GitHub Releases, and updates the Sparkle feed that running copies check.

Written in Swift on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), with an AppKit interface and a SQLite journal. No background daemons.
