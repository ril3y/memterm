# Agent status: always-on (FR-61, FR-62)

**Status:** approved in conversation, 2026-11-20. Founder choice: "always-on status" (no separate mode).
First version covers Claude Code, Codex, and Gemini CLI.

## What the founder asked for

"There is a github repo called herdr, it's kind of like memterm … see if we can make memterm like it, agents,
claude codex gemini stuff." After the comparison, the founder picked step 1 (agent status and alerts), as
always-on status rather than a separate view.

## What already exists

- **Which agent.** `MemoryEngine.pollPane` classifies each pane's foreground process every 2 s through
  `Adapters.classify` (kernel argv, no shell integration needed). Claude and Codex adapters exist.
- **A Claude-only badge.** `ClaudeBadgePlanner` (Claude sessions extension) marks a tab "needs attention"
  when the session jsonl has been quiet for 30 s. A long tool run looks the same as a permission prompt,
  the selected tab never shows it, and the workspace chip never sees it.
- **Indicator slots.** The tab strip's spinner/dot (`TabActivityIndicatorView`) and the workspace chip's
  pulse/ring (`WorkspaceChipView.applyActivity`).
- **No alerts.** No notifications and no Dock badge; BEL only bounces the Dock.

## Design

### States (FR-61)

Each pane whose foreground process is a known agent has one of:

| State | Meaning | Tab | Workspace chip |
|---|---|---|---|
| working | The agent is busy | spinner | (output pulse as today) |
| blocked | The agent is waiting for you: a permission prompt, a question, a trust dialog | orange dot, **shown even on the selected tab** | orange badge, outranks the ring |
| idle | Prompt visible, nothing happening | nothing | nothing |
| done | Went working → idle while you weren't looking; cleared when you look | green dot | green badge |

"Looking" means memterm is the active app, the pane's window is key, its workspace is showing, and its tab
is selected.

### Detection

1. **Which agent** comes from the existing process capture. Gemini CLI gets an adapter that detects `gemini`
   (or `node …/gemini`). It makes no resume offer in this version.
2. **Which state** comes from pattern rules over the terminal title and the visible screen. The rules are
   ported by hand from herdr's manifests (Apache-2.0, github.com/herdrdev/herdr at e8d7d97): `claude.toml` and `codex.toml`
   version 2026.10.11.1, and `gemini.toml` 2026.06.10.1. The engine keeps herdr's semantics:
   - a rule reads one region (`osc_title`, `whole_recent`, `bottom_non_empty_lines(n)`,
     `top_non_empty_lines(n)`, `after_last_horizontal_rule`, `prompt_box_body`,
     `last_non_empty_above_prompt_box`, and the Codex prompt-marker regions);
   - gates are `contains` (case-insensitive, all must appear), `regex` (all must match the region),
     `line_regex` (each must match some line), and nested `all` / `any` / `not`;
   - the highest-priority matching rule wins; a rule may say "skip update" (a transcript viewer or picker
     is on screen, so keep the previous state);
   - a known agent with no matching rule reads as idle, without visible idle chrome.
3. **Self-reports.** A program running in an agent pane may report its own state with OSC 7501
   (`ESC ] 7501 ; state=…:kind=…:progress=…:app=…:title=<b64>:msg=<b64> ST`, herdr's Program Status
   Protocol). A report wins over the screen rules until the program sends `state=idle` or clears it, or the
   agent process changes. `done` and `error` from 7501 map to idle and blocked. Reports carrying an `id`
   describe sub-tasks and are ignored. In this version only panes running a known agent honor 7501.
4. **Hysteresis** (herdr's pending-idle rule). A working → idle change without visible idle chrome waits for 3
   confirmations or 700 ms, whichever comes first, so a gap between tool calls doesn't flash "done". Every
   other change applies at once.

Evaluation runs only for panes with a known agent: on pty output (coalesced to 300 ms), on a title change, and
on a 1 s tick. Panes without an agent cost nothing.

### Alerts (FR-62)

- Entering **blocked** always alerts. Reaching **done** alerts only if you weren't looking. This is herdr's
  rule. When you are already looking at the pane, the alert plays its sound (if set) but posts no banner.
- An alert can be a macOS notification, a sound, or both, and each is configurable. Clicking the
  notification brings that pane forward (window → workspace → tab → pane).
- The **Dock badge** counts panes that are blocked or done-and-unseen.
- **Privacy.** Notification text is the tab's name plus "needs your input" or "finished", never screen
  content, since notifications can show on the lock screen.
- Agent exit clears the pane's state and does not alert.

### Config

```toml
[agents]
status = true          # FR-61 indicators
notify_blocked = true
notify_done = true
dock_badge = true
sound = ""             # empty = silent; otherwise a system sound name, like bell_sound
```

## Invariants kept

- **Consent.** Status is read-only; memterm types and runs nothing.
- **Extension firewall.** Detection lives in MemtermCore, wiring in the app. The Claude sessions
  extension's jsonl badge is unchanged, but where agent status has an opinion about a tab, it wins.
- **Probe isolation.** The probe drives a fake agent script, never a real agent, with `MEMTERM_CLAUDE_DIR`
  and `MEMTERM_CODEX_DIR` pointed at fixtures. Alerts go to a recording sink.

## Out of scope

An agent list or go-to picker, more agents, an agent-control socket API (needs a permission model first),
auto-resume (breaks the consent invariant), installing hooks into agent config files, status on the phone,
and a Gemini resume offer.
