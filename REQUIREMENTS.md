# memterm — Product Requirements & Plan

*A macOS terminal that survives reboots.*

**Document status:** Final synthesis (v1.0) — built on the winning "Journal & Resurrect" architecture, incorporating the boot-UUID discrimination, spool/degrade ideas from "Keel," the visible-session-object and degradation-floor ideas from the UX-first design, and fixes for every judge-confirmed flaw (duplicate Claude session ambiguity, vanished cwd, app-update regression, capture-layer reconciliation, consent-model edge cases).

---

## 1. Vision & Positioning

**Vision.** Every terminal on macOS loses your work at reboot. iTerm2 keeps ptys alive in daemons — until the machine restarts, at which point its own docs concede "your jobs will terminate and not be restored." Warp restores text, not programs. tmux keeps a server alive that dies with the host. We invert the architecture: **the disk is the persistence layer, not a daemon.** The terminal continuously journals a durable description of your workspace — window/tab/split topology, per-pane working directory, scrollback, and *what was running*, with enough adapter-specific metadata to bring it back — then, on the next launch after a reboot, crash, or quit, silently recreates your workspace and offers one-keystroke resumption of the sessions that matter most: **Claude Code sessions** (`claude --resume <uuid>`, lossless by construction) and **SSH connections** (exact argv replay). Wrapped in a Ghostty-grade native, minimal, fast UI — no accounts, no cloud, no telemetry, no preference-pane sprawl.

**Elevator pitch.** *"The terminal that comes back. Reboot your Mac mid-workday and everything returns — every window, split, directory, and scrollback line — with your Claude Code conversations and SSH sessions one keystroke from resuming exactly where they were. Like Chrome's 'Restore tabs?', but for your entire terminal life."*

**Competitive position:**

| | **This product** | iTerm2 | Warp | Ghostty | tmux + resurrect |
|---|---|---|---|---|---|
| Layout survives app restart | Yes | Yes | Yes | No | Yes (server) |
| Layout + scrollback survive **reboot** | **Yes** | Partial (text via macOS restore) | Yes | No | Yes (with plugin, manual) |
| **Running programs restorable after reboot** | **Yes — consent-gated, adapter-aware** | No | No | No | Whitelist, tmux-only, manual keybind |
| **Claude Code sessions resume after reboot** | **Yes — first-class, session-ID aware** | No | No | No | No |
| SSH reconnect after reboot | Yes — exact argv replay | No | No | No | Config-gated |
| Native macOS UI | Yes (AppKit) | Yes (dated, sprawling) | No (custom Rust UI) | Yes | N/A (TUI) |
| No account / no telemetry / local-only | Yes | Yes | Historically no | Yes | Yes |
| Config model | One TOML file + ⌘K palette | ~10-tab preferences modal | GUI + cloud settings | One text file | Text file |
| Live processes survive app update | v0.4 (holder layer) | Yes | No | No | Yes (server) |

The bottom two rows are the honest gaps: iTerm2 beats us on app-update survival until v0.4, and its 30 years of features beat everyone on breadth. We do not compete on breadth. We compete on the one cell no product fills — the bolded column — plus elegance.

---

## 2. The Core Insight: The Restore Taxonomy

After a reboot, every process, pty, and kernel object is gone. No daemon architecture can shortcut this — iTerm2's pty servers, tmux's server, mosh's SSP state all die "by physics." What survives is disk state. Reboot persistence is therefore purely a **capture-and-recreate** problem, and the fidelity ceiling of recreation differs by program. That yields a four-tier taxonomy which drives every restore decision in the product:

1. **RESUMABLE** — the program maintains its own durable session state; recreation is *lossless*. Flagship: **Claude Code** (every conversation continuously persisted to `~/.claude/projects/` with a stable session UUID; `claude --resume <uuid>` verified to restore full context from any cwd). Also: `tmux attach` to a surviving remote server.
2. **RECONNECTABLE** — the connection can be re-established from its captured command line, but the far-side session state is gone. Flagship: **SSH** (full post-expansion argv incl. `-p/-i/-L/-J/-o` verified recoverable via `KERN_PROCARGS2`; keys/agent/`UseKeychain` auth flows naturally). Honest labeling: "Reconnect — remote state not restored," upgradeable to genuinely lossless via opt-in remote auto-tmux wrapping.
3. **REPLAYABLE** — re-executing the same argv in the same cwd approximates the prior state (`tail -f`, `htop`, `npm run dev`, `watch`). Safe only for a read-only allowlist by default; everything else requires explicit click-to-confirm because arbitrary re-execution is dangerous (deploys, `rm`).
4. **SNAPSHOT-ONLY** — irreproducible in-memory state (unsaved editor buffer, REPL variables, half-run build). The honest floor: frozen ghost scrollback + "was running: `<cmd>`" + the command one gesture away from re-running.

**Why this territory is unowned.** The research is unambiguous: iTerm2 documents that reboots kill jobs; Warp restores only text/layout and command-replay-on-restore is an open feature request; Ghostty and Alacritty explicitly reject persistence; Kitty sessions are hand-written startup files; WezTerm/tmux/mosh persistence is process-lifetime-bound. tmux-resurrect and zellij prove the serialize-and-resurrect model works — but inside tmux/zellij, with fragile ps-parsing, lossy argument capture, and no GUI. **And nobody, anywhere, treats agentic CLI sessions as first-class resumable state**, even though Claude Code makes this trivially lossless. The intersection (native macOS GUI) × (survives reboot) × (restores what was running, incl. agent CLIs) is empty. That intersection is the product.

The second insight, from the winning design, is a reliability property: **crash, quit, and reboot all flow through the same restore pipeline, exercised on every single launch.** Restore code that runs daily cannot silently rot until the one moment it matters — the structural antidote to tmux-resurrect's empty-save and zellij's serialization-consistency failure modes.

---

## 3. Product Name

**memterm** — chosen by the founder. The name states the thesis literally: the terminal with memory. It reads naturally in lowercase alongside its peers (tmux, mosh, zsh), the `.app` / domain / brew-cask namespace is plausible, and it makes the elevator pitch self-explanatory: *"memterm remembers."*

Tagline candidates: *"The terminal that remembers."* / *"The terminal that comes back."*

(The design panel's alternates, for the record: memterm, Ember, Keel, Continuum, Tether.)

---

## 4. Personas & Key Journeys

**Persona A — "The Claude-heavy builder" (primary).** Solo developer or small-team engineer running 2–5 concurrent Claude Code sessions across projects, plus SSH to a dev box, plus watchers. Today a reboot (macOS update, kernel panic, battery death) costs 20+ minutes of reconstructing which session was where and losing all visual context. Currently on iTerm2 or Ghostty; tried Warp, bounced off login/telemetry.

**Persona B — "The tmux-resurrect refugee" (secondary).** Power user who already believes in serialize-and-resurrect — they built it themselves out of tmux plugins. Wants the same guarantee without the tmux tax and with native macOS UX. The most persistence-literate, most trust-sensitive segment; they will read our disk format.

**Persona C — "The minimalist switcher" (tertiary).** Ghostty/Alacritty user who chose speed and cleanliness over features. Will only switch if the terminal is *as fast and as clean*, and treats persistence as a bonus. This persona sets our performance and design bar; they punish sprawl and chrome.

### Journey 1: The reboot moment (the product's reason to exist)
Tuesday 4:32 PM: macOS forces a security restart. Riley has three windows: (1) two splits — Claude Code refactoring a parser (2h conversation) and `tail -f` on its test log; (2) SSH to `prod-bastion` via a jump host; (3) a build that was 40 minutes in. She reboots, launches memterm. **Instantly and silently:** all three windows return with exact splits, every pane cd'd correctly, ghost scrollback dimmed above a hairline "restored — Tue 4:32 PM" divider. Pane 1 shows a chip: *"was running: claude (2h, ~/proj/parser) — [Resume ⏎]"*. Pane 2: *"Reconnect: ssh -J bastion riley@prod-01"*. A corner HUD: *"3 sessions can resume — ⌘⇧R."* She hits ⌘⇧R: Claude resumes mid-conversation with full context, SSH reconnects via her keychain-held key, `tail -f` restarts. The build pane honestly shows frozen output ending at the error she was reading, with `make -j8` displayed one gesture from re-running. Total time back to work: under 15 seconds. **This journey, recorded, is the launch asset.**

### Journey 2: The daily driver (why it doesn't feel like a persistence tool)
Every day, memterm is simply a fast, clean terminal: native tabs, ⌘D splits, ⌘F search, jump-to-prompt. The differentiator is *visible while working*: each Claude pane carries a subtle live badge (session age, model, cwd) — continuous proof that the session is tracked and will come back. ⌘Q quits instantly (state is always already on disk). Every launch — even a plain morning launch — runs the identical restore pipeline, so the user sees their layout return daily and learns to trust it before the first reboot ever tests it.

### Journey 3: The skeptical evaluation (Persona B's first hour)
The tmux-resurrect refugee installs from a notarized DMG. No account. No network calls. They find `~/Library/Application Support/memterm/` — one SQLite DB and per-pane compressed scrollback chunks, all inspectable. They `kill -9` the app; relaunch restores everything. They read the config TOML, find the denylist, try to make it auto-execute a command — and discover no such setting exists. They stay.

---

## 5. Functional Requirements

MoSCoW: **M** = Must (v0.1), **S** = Should (v0.1 if schedule holds, else v0.2), **C** = Could (post-v0.1), **W** = Won't (v1.x).

### Group A — Terminal core parity

- **FR-1 (M)** — VT/xterm-compatible emulation via the SwiftTerm engine: correct UTF-8/grapheme/wide-char handling, 256/24-bit color, mouse protocols, reflow-on-resize; conformance-tested (esctest subset + vim/tmux/htop/fzf corpus in CI).
- **FR-2 (M)** — Native macOS windows and tabs (AppKit): standard shortcuts (⌘T/⌘N/⌘W), traffic lights, native tab bar, full keyboard navigation.
- **FR-3 (M)** — Split panes, arbitrary h/v tree (⌘D / ⌘⇧D), arrow-key pane navigation, drag-to-resize, 1px hairline dividers; implemented in AppKit, not SwiftUI.
- **FR-4 (M)** — Per-pane search (⌘F) with incremental highlight and match navigation, **searching restored ghost scrollback as well as the live buffer** in one continuous result set.
- **FR-5 (M)** — Auto-injected shell integration for zsh/bash/fish at pane spawn (ZDOTDIR/ENV wrapper; zero dotfile edits) emitting OSC 133 A/B/C/D prompt marks, OSC 7 cwd, OSC 1337 RemoteHost/CurrentDir; visible indicator when active; one-key opt-out; graceful degradation to kernel-only capture.
- **FR-6 (M)** — OSC 133-powered navigation: jump to previous/next prompt (⌘↑/⌘↓), select-command-output; exit-status marks in the scrollbar gutter.
- **FR-7 (S)** — Hotkey dropdown window (global shortcut, slide-down), its session persisted and restored like any window.
- **FR-8 (S)** — Profiles-lite: named font/theme/shell/cwd presets applicable per pane; no per-profile keybinding sprawl.
- **FR-9 (C)** — Triggers-lite: user regex on output → highlight or notification **only, never exec**; shares the OSC/journal event pipeline.
- **FR-10 (C)** — tmux -CC control-mode integration (native tabs/splits for tmux windows). Explicitly post-1.0; courts the persistence-conscious segment but is a large orthogonal subsystem.
- **FR-11 (W v1)** — Password manager, scripting API (AppleScript/Python), instant replay, Mac App Store distribution (sandbox-incompatible by design).

### Group B — Persistence engine (capture → journal)

- **FR-12 (M)** — Continuous capture of window/tab/split topology (ratios, focus, frames, zoom) to the state store, written transactionally on every layout mutation. Never save-on-quit-only.
- **FR-13 (M)** — Per-pane cwd captured from kernel truth (`proc_pidinfo` `PROC_PIDVNODEPATHINFO`) corroborated by OSC 7; checkpointed on every `chpwd`/command boundary. Works with zero shell cooperation.
- **FR-14 (M)** — Per-pane foreground-process capture: exe path, **full argv** (`sysctl KERN_PROCARGS2`), process tree (`tcgetpgrp(master_fd)` + `proc_listchildpids`), `procStart` timestamp (PID-reuse guard); polled at 1–2 s and pinned on every OSC 133 D event.
- **FR-15 (M)** — **Capture-layer reconciliation rule** (fixes judge-flagged race): the OSC 133 journal is authoritative for *command text, boundaries, and exit codes*; the kernel poll is authoritative for *what is running right now* (argv, cwd, process identity). On disagreement (fast command turnover, programs launched from inside vim, integration disabled), the kernel snapshot taken at the most recent poll tick wins for restore classification, and the journal record is annotated `low_confidence`. Adapters must state which layer each field came from.
- **FR-16 (M)** — Per-pane scrollback serialized to per-pane append-only zstd-compressed chunk files (outside the DB), debounced ≤5 s idle / 64 KB dirty, capped (default **10,000 lines** captured and restorable — the restore moment is the product; do not skimp), full flush on quit and `NSWorkspace.willPowerOffNotification`.
- **FR-17 (M)** — Atomic, corruption-resistant state store: SQLite WAL (`synchronous=NORMAL`), single-writer actor, generational snapshot rotation with integrity check on load and restore-from-last-known-good. A torn write must never lose more than the last checkpoint (tmux-resurrect's empty-save failure is a named anti-goal, verified by kill-9-mid-write property tests).
- **FR-18 (M)** — **Boot-session discrimination** via `kern.bootsessionuuid` stamped on all state: a launch under the same boot UUID is an app-restart restore; a different UUID is a reboot restore. Zero heuristics. (Same UX in v0.1 either way; prerequisite for the v0.4 holder layer's adopt-vs-resurrect branch.)
- **FR-19 (M)** — Command journal: every command's text, cwd, start/end timestamps, exit code, keyed to scrollback offsets (foundation for timeline, triggers, navigation).
- **FR-20 (M)** — `NSProcessInfo` sudden-termination toggled around dirty state; `applicationSupportsSecureRestorableState = YES`; shutdown is instant and lossless.
- **FR-21 (S)** — Per-pane privacy: secure-keyboard-entry auto-detection plus a per-pane incognito toggle excluding the pane from scrollback capture, journal, and timeline.
- **FR-22 (C)** — Optional at-rest encryption of scrollback chunks with a Keychain-held key.
- **FR-23 (C)** — Raw byte spool ring per pane (Keel's spool≠chunks separation): a crash-replay log distinct from durable rendered history; enables byte-exact same-boot replay and, later, instant-replay scrubbing. Lands with the v0.4 holder layer.

### Group C — Restore UX

- **FR-24 (M)** — On **every** launch (reboot, crash, quit — one pipeline): silently recreate full topology, spawn a live login shell cd'd to each pane's saved cwd, render ghost scrollback dimmed (~55–60% opacity) above a hairline divider labeled "restored — `<relative timestamp>`". No modal, no launch prompt (macOS Resume / VS Code convention). Ghost history stays scrollable and searchable.
- **FR-25 (M)** — **Vanished-cwd handling** (fixes judge-confirmed flaw): before spawning, stat the saved cwd. If missing (unmounted volume, deleted worktree), spawn in the nearest existing ancestor (else `$HOME`), show an inline notice "directory not available: `<path>`", and adjust adapter offers accordingly — cwd-dependent restores are downgraded or disabled, but `claude --resume <uuid>` (verified to work from any cwd) is still offered with a "project directory unavailable" caveat. Never a broken pane, never a silently wrong `cd`.
- **FR-26 (M)** — Per-pane resume chip for reconstructible sessions, pinned above the prompt: *"was running: claude (2h, ~/proj/foo) — [Resume ⏎] [Just shell] [✕]"*. Expanded state always shows the **exact command line** that will run before it runs. Enter on the focused chip resumes; typing any character dismisses (implicit "just shell"); Esc dismisses.
- **FR-27 (M)** — **Universal degradation floor** (adapter contract invariant): the worst case for any pane is always *correct-or-fallback cwd + ghost scrollback + the original command displayed one gesture from insertion* — never a broken pane, never silent re-execution. The command is shown in the chip, not pre-typed into the input line (avoids the accidental-Enter consent regression Judge 2 flagged); a single gesture inserts it at the prompt, still requiring Enter.
- **FR-28 (M)** — Restore-all: ⌘⇧R resumes every pane classified RESUMABLE or RECONNECTABLE plus the read-only allowlist — never snapshot-only panes, under any setting. Corner HUD on first launch after an abnormal exit or reboot: *"N sessions can resume — ⌘⇧R"*; non-modal, dismissible, gone after one interaction or 30 s.
- **FR-29 (M)** — **Absolute consent rule (architecture, not policy):** no captured command ever executes without a user gesture (chip Enter/click or ⌘⇧R). Silent restore covers layout/cwd/scrollback only. No auto-exec setting exists in v0.1.
- **FR-30 (M)** — Hard denylist never offered for re-run under any configuration: `sudo` anything, `rm`, `dd`, `mkfs`, `kill`, `shutdown`, `git push --force`, `curl … | sh` patterns, multiline/heredoc unknowns. Such panes restore as scrollback + fresh shell only.
- **FR-31 (M)** — Non-allowlisted commands degrade to snapshot+offer: ghost scrollback + passive chip *"was running: npm run dev — [Run again] [Just shell]"*; "Run again" expands to show the full command and requires a click — no Enter shortcut.
- **FR-32 (S)** — Ghost scrollback lazy-loads per pane (last visible screen renders immediately; rest streams in) so a 20-pane restore never blocks the first keystroke.
- **FR-33 (S)** — Crash-loop safe mode: two consecutive startup crashes → launch with restore disabled and a plain recovery banner offering per-window restore. A corrupt journal must never brick the terminal.

### Group D — Program adapters

- **FR-34 (M)** — Typed, compiled-in adapter interface: `detect(exe, argv, cwd, pid, tree) -> AdapterState?`, `restoreCommand(state) -> Command`, `degrade() -> SnapshotOnly`, `fidelityClass`, `label/badge`. Compiled-in Swift types only in v0.1 (the allowlist is code-reviewed, not string-matched).
- **FR-35 (M)** — **Claude Code adapter** (the hero — full spec in §8): live capture of session UUID from `~/.claude/sessions/<pid>.json` with `procStart` guard; resolved UUID persisted in *our* store; three-deep fallback chain; version-gated per Claude Code release; restore via `cd <cwd> && claude --resume <uuid>`.
- **FR-36 (M)** — **Duplicate-session disambiguation** (fixes judge-confirmed flaw): session UUIDs are bound to pane UUIDs at capture time via the pid-keyed registry, so two Claude panes in the same cwd normally resolve distinctly. When only the newest-mtime projects-dir fallback is available for multiple panes sharing a cwd, the engine assigns distinct jsonl files by matching each file's mtime activity window against each pane's recorded process lifetime; any pane it cannot uniquely assign is offered `claude --continue` (honestly labeled "most recent session in this directory") — **the same `--resume <uuid>` is never offered on two panes.**
- **FR-37 (M)** — **SSH adapter**: capture exact post-expansion argv + cwd; restore by identical re-exec labeled "Reconnect"; one-line notice "reconnected — remote session state was not restored"; interactive password/2FA re-prompts naturally in the new pty; `ssh -G` resolution shown in the chip's expanded detail.
- **FR-38 (M)** — Read-only watcher adapter: `tail -f`, `less`, `more`, `man`, `htop`, `top`, `watch` (tmux-resurrect's battle-tested defaults) — Resume-chip and restore-all eligible.
- **FR-39 (M)** — Live Claude session badge **while running** (from the UX-first design): a compact, unobtrusive badge on any pane with an active Claude session showing session age, model, and cwd — the differentiator visible daily, and continuous proof capture is working.
- **FR-40 (S)** — Opt-in per-host SSH auto-tmux wrapping (`ssh -t host 'tmux new -A -s <pane-id>'`) making remote state genuinely reboot-proof; restore then re-attaches.
- **FR-41 (C)** — Additional adapters: local/remote `tmux attach` (local marked degraded — the local server also died), `docker exec` / `kubectl exec` with existence pre-check then argv replay, REPLs (python/node/irb) as explicit snapshot-only with "state not restored" banner, mosh relaunch (MOSH_KEY path flagged experimental).
- **FR-42 (C)** — User-extensible resurrection rules in config with tmux-resurrect-style command rewrite (`grunt -> grunt development`), gated behind an explicit `i_understand_this_reexecutes_commands = true` key; denylist still applies and cannot be overridden.

### Group E — Session timeline

- **FR-43 (S)** — Session timeline browser (⌘⇧T): durable, FTS-searchable history of past panes grouped by day and reboot ("Today", "Yesterday", "Aug 12 — reboot"): icon (claude/ssh/shell), cwd, last command, duration; search across command text and scrollback; frozen-scrollback preview; actions: "Reopen here" (new pane, that cwd, ghost loaded), "Resume" (if adapter), "Copy commands". Private panes excluded by default. *(v0.2 headline feature; the command journal that powers it is M in v0.1.)*

### Group F — Configuration & trust

- **FR-44 (M)** — Single human-editable TOML config file as source of truth; sane defaults doctrine: zero required configuration; persistence ON, silent restore ON, auto-resume OFF by default.
- **FR-45 (M)** — 100% local data, no account, no telemetry, no network calls except the Sparkle update check (user-visible, disable-able); documented on-disk location surfaced in the UI; one-command "Forget everything" wipe.
- **FR-46 (M)** — Developer ID signed, notarized, hardened runtime, **non-sandboxed** (App Sandbox denies libproc/sysctl — disqualifying), Sparkle auto-updates, distributed via direct download + Homebrew cask. No login items or background processes in v0.1.
- **FR-47 (M)** — **Graceful-update flush** (mitigates the app-update regression vs iTerm2): Sparkle installs on quit, never mid-session; the pre-update quit path performs a full journal + scrollback flush, so an update is exactly a clean quit/relaunch — everything restores, with resume chips for what was running. Release notes and onboarding state the limitation honestly until the v0.4 holder layer closes it.
- **FR-48 (S)** — ⌘K command palette as the primary settings surface (Raycast/Linear style): every setting searchable and togglable inline with live preview, writing to the TOML file. No multi-pane preferences window, ever; at most a one-page General sheet (font/theme/default shell).

### Group G — Workspaces (tab groups) — first-class citizen

*Founder decision 2026-08-30: promoted to MUST. A workspace is a named, colored group of tabs (with their pane trees). It is the natural unit of the memory engine: parking a workspace and restoring after a reboot are the same journal → restore pipeline, which turns memterm's persistence from a disaster-recovery feature into a daily driver ("close the infra workspace, reopen it Thursday, everything — cwds, ghost scrollback, resumable Claude/SSH sessions — comes back"). tmux-session semantics, native macOS UI; no competing terminal has this.*

- **FR-49 (M)** — Workspace entity: every tab belongs to exactly one workspace; workspaces have a name and a color chip; a default workspace exists so single-context users never see the concept until they want it.
- **FR-50 (M)** — Workspace switcher: create / rename / recolor / delete from the titlebar control and the Shell menu; switching swaps the window's tab set in place. Deleting offers "park" vs "forget."
- **FR-51 (M)** — Park / reopen: closing a workspace parks it — full layout, per-pane cwd, scrollback, and adapter state (Claude session IDs, SSH argv) stay in the journal; reopening runs the standard restore pipeline (ghost scrollback + consent-gated resume offers). Reboot-restore restores workspaces, not bare tabs.
- **FR-52 (M)** — Keyboard model (founder-specified):
  - **⌘1–⌘8** — jump to tab N in the active workspace; **⌘9** — last tab (browser convention).
  - **⌃⌘1–9** — jump to workspace N; **⌃⌘← / ⌃⌘→** — cycle workspaces.
  - **⌘⇧[ / ⌘⇧]** (and ⌃Tab / ⌃⇧Tab) — previous / next tab.
  - ⌘⌥arrows stay pane-focus navigation (FR-3). All bindings rebindable in config; defaults must not collide with common shell/tmux/vim chords beyond macOS conventions.
- **FR-53 (S)** — Auto-workspace suggestion: when a window's cwds cluster under one repo root, offer to name the workspace after it (never rename silently).
- **FR-54 (S)** — Session timeline (FR-43) groups by workspace; a parked workspace appears as one reopenable card.
- **FR-55 (C)** — Per-workspace defaults: starting cwd, profile/theme tint, env.

---

## 6. Non-Functional Requirements

- **NFR-1 Input latency:** keypress-to-glyph < 20 ms p95 (MUST, v0.1 CoreText renderer, typical window sizes); < 10 ms p95 target once the Metal renderer lands (v0.3). Measured by an automated latency harness from M1 (harness is a simple photodiode-free frame-timestamp rig, not a research project).
- **NFR-2 Cold launch:** < 300 ms to first interactive prompt (MUST); < 150 ms target. Restore path adds < 200 ms for 10 panes (topology + shells; ghost scrollback lazy).
- **NFR-3 Restore responsiveness:** post-reboot restore of 20 panes renders topology + each pane's last visible screen in < 1 s; the first keystroke is never blocked by ghost loading.
- **NFR-4 Checkpoint overhead:** command-boundary checkpoint = one WAL transaction < 1 ms p99; capture polling ≤ 0.3% CPU per idle pane; scrollback flushes never on the render or input thread; zero fsync stalls on the input path.
- **NFR-5 Durability:** app crash or force-quit loses zero committed journal rows and ≤ 5 s of scrollback (debounce window); kernel panic/power loss loses at most the last checkpoint; the store self-recovers from torn writes and never refuses to launch (safe mode instead).
- **NFR-6 Restore correctness:** 100% of topology and cwd restored (or explicitly flagged per FR-25); ≥ 99% of Claude panes offer the correct session UUID, measured by the integration-test matrix against the installed Claude Code version; zero duplicate-UUID offers (FR-36).
- **NFR-7 Memory:** < 120 MB with 10 idle panes at default 10k-line scrollback; no growth over a 2-week soak.
- **NFR-8 Disk:** compressed scrollback ≤ 5 MB per pane at cap; total store capped and rotated (default ≤ 500 MB, configurable); DB auto-vacuumed.
- **NFR-9 Throughput:** full-screen output floods (`yes`, build spew) never freeze the UI; frames coalesce; verified in the M0 spike with a kill criterion (§10).
- **NFR-10 Footprint & trust:** single .app < 30 MB; no login items, no background processes (v0.1); 0700 data directories; private panes excluded from all persistence; no network I/O beyond Sparkle.
- **NFR-11 Battery:** polling and flush timers coalesced; near-zero wakeups with all panes idle; battery-neutral vs iTerm2 in a 4-hour idle comparison.
- **NFR-12 Compatibility:** macOS 14+, Apple Silicon native (x86_64 via Rosetta acceptable at launch); zsh/bash/fish integration with graceful kernel-only degradation; TERM=xterm-256color validated against the vim/tmux/htop/fzf corpus.

---

## 7. Architecture

### 7.1 Chosen stack (decisive)

**One stack:** 100% Swift. **Engine:** SwiftTerm (MIT; 7 years mature, actively maintained, ships in La Terminal/Secure ShellFish/CodeEdit) wrapped behind a thin `TerminalEngine` protocol (~15 methods: feed, resize, snapshotGrid, serializeScrollback, OSC handlers) so libghostty-vt — the strongest future core, currently API-unstable by its own documentation — can be swapped post-1.0. **Shell:** AppKit-first (NSWindow, native tabs, NSSplitView split tree, NSTextInputClient terminal view); SwiftUI only for leaf chrome (chips, HUD, palette, settings sheet) — Ghostty's PR #7523 lesson applied literally. **Renderer:** SwiftTerm's stock CoreText renderer at v0.1, with an M0 measurement gate; custom Metal glyph-atlas renderer in v0.3, starting from the trsdn/SwiftTerm fork and using the shape-first (CoreText shaping → atlas → instanced quads) design so ligatures stay on the GPU path — never iTerm2's per-cell-atlas trap. **Store:** SQLite WAL. **Processes:** single app process, **no daemon in v0.1** — restore-on-next-launch needs none; the pty-holder layer is v0.4. **Distribution:** non-sandboxed, Developer ID + notarized + hardened runtime, Sparkle, Homebrew cask.

Why this and not the alternatives: the killer feature requires reaching *into* grid/scrollback structures to serialize them — SwiftTerm's pure-Swift in-process Buffer/CircularList puts zero FFI between the grid and the serializer; Rust cores (alacritty_terminal, wezterm) put a marshalling boundary exactly there. From-scratch is a multi-year conformance trap. The three-tier daemon design (Keel) spends a distributed-systems tax on app-crash survival — which the journal does not need for reboot survival, the actual differentiator — and would be the least-shipped option for a solo developer. **GPL hygiene: iTerm2 source (GPL-2.0-or-later), including its restoration daemon, is never read or ported; behavior reference from documentation only.**

### 7.2 Component diagram

```
┌────────────────────────────────────────────────────────────────────┐
│ memterm.app (single process, v0.1)                                │
│                                                                    │
│  ┌───────────── AppKit Shell ─────────────┐   ┌─ SwiftUI leaves ─┐ │
│  │ NSWindow / native tabs / NSSplitView   │   │ chips · HUD ·    │ │
│  │ split tree / terminal NSView per pane  │   │ ⌘K palette ·     │ │
│  └───────┬────────────────────────────────┘   │ settings sheet   │ │
│          │                                    └──────────────────┘ │
│  ┌───────▼──────────────┐    ┌──────────────────────────────────┐  │
│  │ TerminalEngine proto │    │  CAPTURE ENGINE (per pane)       │  │
│  │  └─ SwiftTerm (v1)   │    │  ├ Kernel truth: tcgetpgrp,      │  │
│  │  └─ libghostty-vt(v2)│    │  │  proc_listchildpids,          │  │
│  │  pty master (forkpty)│───▶│  │  KERN_PROCARGS2, VNODEPATHINFO│  │
│  └──────────────────────┘    │  │  (1–2 s poll)                 │  │
│          │ OSC 133/7/1337    │  ├ Semantic: OSC 133/7/1337      │  │
│          └──────────────────▶│  │  journal (auto-injected hooks)│  │
│                              │  └ Reconciliation (FR-15)        │  │
│                              └───────────────┬──────────────────┘  │
│  ┌────────────────────────┐   ┌──────────────▼─────────────────┐   │
│  │ RESTORE ENGINE         │   │ STATE STORE (single-writer     │   │
│  │ boot-UUID discriminate │◀──│ actor)                         │   │
│  │ classify via adapters  │   │ SQLite WAL  state.db           │   │
│  │ vanished-cwd handling  │   │ + scrollback/<pane>/*.zst      │   │
│  │ chips · HUD · ⌘⇧R      │   │ generations · integrity checks │   │
│  └───────────┬────────────┘   └────────────────────────────────┘   │
│              ▼                                                     │
│  ┌────────────────────────────────────────┐                        │
│  │ ADAPTER REGISTRY (compiled-in, typed)  │                        │
│  │ claude · ssh · watchers · plain shell  │                        │
│  │ detect() restoreCommand() degrade()    │                        │
│  └────────────────────────────────────────┘                        │
└────────────────────────────────────────────────────────────────────┘
   v0.4 additive layer: per-pane pty-holder processes + spool rings
   (clean-room; same-boot adopt path keyed off kern.bootsessionuuid)
```

### 7.3 The capture → journal → restore pipeline

**Capture (continuous — a reboot is never scheduled):**
1. *Layout*: every mutation (split, tab, resize, focus, frame) → immediate transactional write.
2. *Kernel poll* (1–2 s per pane): `tcgetpgrp(master_fd)` → foreground pgid; walk tree; `KERN_PROCARGS2` argv; `PROC_PIDVNODEPATHINFO` cwd; `procStart`. Snapshot into `pane_snapshot` on change.
3. *Semantic events*: OSC 133 D (command finished + exit code) and `chpwd` → journal row + checkpoint (< 1 ms WAL transaction). OSC 133 D is the natural debounce point.
4. *Adapter capture*: on detecting an adapter-matched process, resolve and persist adapter state **while the process is alive** (e.g., the Claude session UUID — the pid-keyed registry is meaningless after reboot; we store the resolved string, never the lookup path).
5. *Scrollback*: serialized from the engine buffer to zstd chunks, debounced ≤ 5 s idle / 64 KB dirty.
6. *Flush points*: `applicationShouldTerminate`, `NSWorkspace.willPowerOffNotification`, Sparkle pre-update quit; sudden-termination enabled whenever clean.

**Restore (every launch — one pipeline):**
1. Open store; integrity-check; on failure, roll back to last good generation; on repeated startup crash, enter safe mode (FR-33).
2. Compare stored vs live `kern.bootsessionuuid` → tag restore as same-boot or reboot (identical UX in v0.1; branches in v0.4).
3. Rebuild topology; per pane: stat cwd (FR-25 fallback), spawn login shell cd'd, lazy-render ghost scrollback with timestamped divider.
4. Classify each `pane_snapshot` through the adapter registry, run duplicate-UUID disambiguation (FR-36), attach chips; count resumables → HUD.
5. Execute nothing. Wait for gestures.

### 7.4 SQLite schema sketch

```sql
PRAGMA journal_mode = WAL;  PRAGMA synchronous = NORMAL;

CREATE TABLE meta            (key TEXT PRIMARY KEY, value TEXT);
                             -- schema_version, boot_session_uuid, generation

CREATE TABLE windows         (id TEXT PRIMARY KEY, frame TEXT, is_hotkey INT,
                              focused_tab TEXT, updated_at INT);
CREATE TABLE tabs            (id TEXT PRIMARY KEY, window_id TEXT REFERENCES windows,
                              ord INT, title TEXT, split_tree JSON, updated_at INT);
                             -- split_tree: nested {h|v, ratio, [child|pane_id]}

CREATE TABLE panes           (id TEXT PRIMARY KEY, tab_id TEXT REFERENCES tabs,
                              shell TEXT, cwd TEXT, cwd_source TEXT, -- kernel|osc7
                              is_private INT, created_at INT, last_seen_at INT);

CREATE TABLE pane_snapshot   (pane_id TEXT PRIMARY KEY REFERENCES panes,
                              exe TEXT, argv JSON, pid INT, proc_start INT,
                              adapter TEXT, adapter_state JSON, -- e.g. {sessionId,...}
                              confidence TEXT,                  -- kernel|osc|low
                              updated_at INT);

CREATE TABLE command_journal (id INTEGER PRIMARY KEY, pane_id TEXT,
                              cmd TEXT, cwd TEXT, exit_code INT,
                              started_at INT, ended_at INT,
                              scrollback_offset INT, low_confidence INT);

CREATE TABLE scrollback_idx  (pane_id TEXT, chunk_file TEXT, first_row INT,
                              last_row INT, bytes INT, created_at INT,
                              PRIMARY KEY (pane_id, chunk_file));

CREATE VIRTUAL TABLE journal_fts USING fts5(cmd, content='command_journal'); -- v0.2 timeline
```

Scrollback bytes live outside the DB in `scrollback/<pane-id>/<n>.zst`; the DB stores only the index. Generations: on each successful launch, the previous `state.db` is rotated to `state.db.gen-1` (keep 3).

### 7.5 Process lifecycle (v0.1: no daemon — by design)

v0.1 installs **zero** background processes: no launchd agent, no login item, no helper. Lifecycle is exactly: launch → integrity check → restore pipeline → run (continuous capture) → quit (flush, sudden-termination-clean). This is a trust feature for the post-Warp segment (`ps aux` shows one process) and a scope feature for the solo developer.

**v0.4 additive holder layer (planned, clean-room):** per-pane micro-holder processes (own the pty master + raw spool ring, frozen 4-message protocol: ATTACH/DETACH/RESIZE/STAT), launched detached so app crash/update no longer kills live jobs; the boot-UUID check (already shipped in v0.1) selects adopt-and-replay (same boot) vs journal resurrect (reboot). A circuit breaker degrades to embedded-engine mode if holders misbehave — the terminal always works. **SMAppService login agent** remains an optional post-MVP nicety for relaunch-at-login, never core architecture. The journal remains the foundation; holders are additive.

---

## 8. Adapter Registry Spec

Interface (compiled-in Swift, v0.1):

```swift
protocol ResurrectionAdapter {
    static func detect(_ ctx: PaneProcessContext) -> AdapterState?  // exe, argv, cwd, pid, tree
    func refresh(_ ctx: PaneProcessContext)                          // live re-verification per poll
    func restoreCommand() -> RestorePlan                             // exact command + label + caveats
    func degrade() -> SnapshotOnly                                   // FR-27 universal floor
    var fidelity: FidelityClass { get }                              // resumable|reconnectable|replayable|snapshot
    var badge: LiveBadge? { get }                                    // e.g. Claude session age/model/cwd
}
```

| Adapter | Detection rule | Captured state | Restore command | Fidelity | Restore-all | Notes / degradation |
|---|---|---|---|---|---|---|
| **claude** (v0.1) | Process in pane tree whose exe basename is `claude`, or node running the claude entrypoint (argv match) | **Primary:** `sessionId` from `~/.claude/sessions/<pid>.json`, `procStart`-guarded, read live and re-verified each poll; persisted as a resolved string. **Fallbacks recorded at capture:** `--resume <id>` in argv; cwd → encoded projects slug (every non-alphanumeric → `-`; always map cwd→dir, never invert) + jsonl mtime-window match against pane lifetime | `cd <cwd> && claude --resume <uuid>`; if only cwd trustworthy: `claude --continue` (labeled "most recent session in this directory"); if cwd vanished: `claude --resume <uuid>` still offered with caveat (verified global) | **Resumable** (lossless) | Yes | Version-gated per Claude Code release; integration-test matrix per release; duplicate-UUID disambiguation per FR-36; degrade → snapshot + command shown |
| **ssh** (v0.1) | exe basename `ssh` in pane tree | Verbatim post-expansion argv (incl. `-p -i -L -R -J -o`), cwd, `ssh -G` resolution for display | Re-exec identical argv in restored cwd; label **"Reconnect"** | **Reconnectable** | Yes | One-line "remote state not restored" notice; keys/agent/UseKeychain flow naturally, password/2FA re-prompts; opt-in per-host auto-tmux wrap (FR-40) upgrades to genuinely lossless; port-forward conflicts surfaced, not silently dropped |
| **watchers** (v0.1) | exe basename ∈ {tail, less, more, man, htop, top, watch} | argv + cwd | Re-exec identical argv | **Replayable** (read-only allowlist) | Yes | tmux-resurrect's proven defaults; anything reading stdin pipelines degrades to snapshot |
| **plain shell** (v0.1) | Foreground = the pane's own shell | cwd, journal tail | (nothing — a live shell in cwd *is* the restore) | Snapshot floor | n/a | The silent default every pane gets |
| **tmux attach** (v0.2) | argv `tmux attach\|new -A` | target session, local/remote | Local: degraded (server also died) — offer command with honest label; remote (via ssh wrap): replay + attach | Resumable (remote) / Snapshot (local) | Remote only | Pairs with FR-40 |
| **docker/kubectl exec** (v0.2) | argv match | full argv, container/pod id | Existence pre-check (`docker inspect` / `kubectl get`) then replay; else degrade | Reconnectable | No (click) | Never replay against a different container silently |
| **mosh** (v0.3) | argv match | `user@host` (+ experimental MOSH_KEY/ip/port env capture) | `mosh user@host` relaunch; MOSH_KEY relaunch flagged experimental, off by default | Reconnectable | No | mosh solves roaming, not client reboot — never marketed as our persistence story |
| **REPLs** (v0.2) | basename ∈ {python, node, irb, …} with tty | argv, cwd | Fresh interpreter offer + "state not restored" banner | **Snapshot-only** | No | The honest tier; ghost scrollback does most of the perceived work |
| **user rules** (v0.3) | Config-defined match → rewrite | per rule | Rewritten command, click-to-confirm only | Replayable | No | Behind explicit acknowledgment key (FR-42); denylist non-overridable |

**Every** adapter's `degrade()` returns the FR-27 floor. The denylist (FR-30) is checked *before* any adapter offer and cannot be bypassed by any adapter or config.

---

## 9. Restore UX Spec

**Governing rule:** restore **state** silently and instantly; never restore **side effects** without one explicit, low-friction gesture. (VS Code revive + Chrome bubble + tmux-resurrect allowlist + macOS Resume conventions, synthesized.)

**The flow, first launch after reboot:**
1. **0–1 s, silent:** all windows/tabs/splits rebuilt; every pane holds a live shell in its saved cwd (or FR-25 fallback with inline notice); the last visible screen of ghost scrollback renders dimmed (~55–60% opacity) beneath the live prompt area, separated by a hairline divider: *"restored — Tue 4:32 PM"*. Remaining scrollback lazy-loads. No modal. No launch prompt. Nothing executes.
2. **Chips:** panes with reconstructible sessions show one compact chip pinned above the prompt (SF Pro, system accent, 8pt grid — the chip and HUD are the only ornamental UI in the product and share one visual system). Chip anatomy: *"was running: claude (2h, ~/proj/parser) — [Resume ⏎] [Just shell] [✕]"*. Expanded state always shows the literal command line before execution. Enter on focused chip = resume. Typing any character = implicit "Just shell" (chip dismisses, ghost stays). Esc dismisses. ✕ dismisses and clears ghost state.
3. **HUD:** a Chrome-style non-modal corner bubble — *"3 sessions can resume — ⌘⇧R"* — dismissible, auto-gone after one interaction or 30 s, never blocks typing. Shown only after abnormal exit or reboot (normal quit/relaunch restores silently without the HUD).
4. **⌘⇧R restore-all:** executes RESUMABLE + RECONNECTABLE + read-only-allowlist panes only. Snapshot-only panes are never included, under any setting.
5. **Snapshot-only panes:** ghost scrollback + passive chip *"was running: npm run dev — [Run again] [Just shell]"*; Run again requires a click on the fully displayed command. Denylisted commands: scrollback only, no offer, no override.
6. **Ghost behavior:** ghost scrollback is scrollable, selectable, and included in ⌘F results; it persists until dismissed or the pane is closed. Visual states are unmistakable: ghost (dimmed, divider) vs live (full opacity) — the product promise is "your workspace and your resumable sessions come back," never an implied process freeze.

**Safety rules (restated as invariants):**
- No command executes without a user gesture. There is no auto-exec setting in v0.1.
- Resume-eligible commands come only from compiled-in, code-reviewed adapters.
- The exact command line is always visible before it runs.
- The denylist is absolute and precedes all other logic.
- The same Claude session UUID is never offered on two panes.
- Worst case for any pane, always: cwd (or flagged fallback) + ghost scrollback + original command one gesture from the prompt. Never a broken pane; never a silent wrong execution.
- Private/incognito panes and secure-keyboard-entry periods are excluded from capture entirely.

---

## 10. MVP Definition & Roadmap

**v0.1 = "a clean, native terminal that brings your Claude and SSH sessions back after reboot."**

**In:** SwiftTerm engine behind `TerminalEngine`, stock CoreText renderer, AppKit windows/tabs/splits, workspaces (named tab groups with park/reopen + ⌘1–9 / ⌃⌘1–9 switching, FR-49..52), ⌘F (incl. ghost), auto-injected shell integration (zsh first, bash/fish before beta ends), full capture→SQLite WAL→restore pipeline with boot-UUID stamping, ghost scrollback, chips + HUD + ⌘⇧R, adapters: claude (with live badge) + ssh + watchers + plain shell, denylist, vanished-cwd handling, duplicate-UUID disambiguation, crash-loop safe mode, graceful-update flush, TOML config, "Forget everything," signed/notarized DMG + Sparkle + Homebrew cask.

**Out (deferred):** Metal renderer (v0.3), ⌘K palette (v0.2), timeline browser (v0.2), hotkey window (v0.2), triggers-lite (v0.3), profiles (v0.2), tmux -CC (post-1.0), pty-holder layer (v0.4), user-extensible adapters (v0.3), at-rest encryption (fast-follow; privacy toggle is the v0.1 mitigation).

**Milestones (solo dev, ~5.5 months to public beta):**

- **M0 — Spike (wk 1–2).** SwiftTerm in a bare AppKit window; forkpty; `TerminalEngine` protocol drawn; latency + flood-throughput measured. **Exit:** measured p95 latency and `yes`-flood behavior recorded. **Kill criterion:** if CoreText is unusable (>35 ms p95 or UI freezes under flood), adopt the trsdn Metal fork immediately in M1 and cut M4 polish — decided by measurement, not vibes.
- **M1 — A terminal you can live in (wk 3–6).** Tabs, AppKit split tree, ⌘F, TOML config, shell-integration injection with visible indicator, OSC 133/7 parsing. **Exit:** developer dogfoods full-time from here; integration verified on zsh/bash/fish + oh-my-zsh + starship.
- **M2 — Capture engine (wk 7–10).** Kernel poller, reconciliation rules, OSC journal, SQLite WAL store + generations, scrollback chunks, willPowerOff/sudden-termination wiring, boot-UUID stamping. **Exit (CI-automated from here):** `kill -9` mid-write, relaunch → everything visible and correct; property-based kill-9 tests green; checkpoint p99 < 1 ms measured.
- **M3 — Restore + hero adapters (wk 11–15).** Silent restore pipeline on every launch, ghost UI, chips, HUD, ⌘⇧R; Claude adapter (registry + full fallback chain + dedupe + live badge), SSH adapter, watchers, denylist, vanished-cwd handling. **Exit: reboot the Mac mid-Claude-session on video — three Claude panes and two SSH panes, all back in one keystroke. This recording is the launch marketing asset.**
- **M4 — Hardening + trust (wk 16–19).** Lazy ghost loading, privacy toggle, crash-loop safe mode, graceful-update flush, empty states, "Forget everything," notarization, Sparkle, Claude-version integration-test matrix, 1-week 30-pane soak. **Exit:** soak clean; update-installs-on-quit verified lossless; NFR-5/6/7 measured green.
- **M5 — Private beta → public v0.1 (wk 20–23).** 20–30 testers recruited from tmux-resurrect and Claude power-user communities; fix cycle; ship. **Exit:** ≥ 99% correct-UUID rate across beta telemetry-free bug reports; zero consent-model violations reported.

**v0.2:** timeline browser, ⌘K palette, hotkey window, profiles-lite, tmux/docker/REPL adapters, SSH auto-tmux. **v0.3:** Metal renderer (shape-then-atlas), triggers-lite, user-extensible rules, encryption default-option. **v0.4:** pty-holder layer (app-update/crash survival — closing the last iTerm2 gap), spool rings, instant-replay scrubbing. **v1.0+:** tmux -CC, libghostty-vt engine evaluation.

---

## 11. Top 10 Risks & Mitigations

1. **Claude Code internals change** (`~/.claude/sessions/<pid>.json` is undocumented). → Persist the resolved sessionId string, never the lookup path; keep the argv and projects-dir fallbacks permanently; version-gate the adapter; integration-test matrix per Claude release (budgeted as a standing M4+ task, ~half a day per release); ultimate degrade: `claude --continue` after cd, honestly labeled.
2. **Serialization corruption at the worst moment** (tmux-resurrect empty-save, zellij #4129 — the product failing at its one job). → SQLite WAL, single-writer actor, generation rotation + integrity check on load, restore-from-last-known-good, crash-loop safe mode, and property-based kill-9-mid-write tests in CI from M2.
3. **Re-executed command harms a user** (deploy, `rm`) — existential trust risk. → Structural, not policy: gesture-required execution, compiled-in adapters only in restore-all, absolute denylist, exact command always displayed, no auto-exec setting exists, user extensions (v0.3) behind explicit acknowledgment with denylist still enforced.
4. **App update / Cmd-Q kills live processes — a real weekly regression vs iTerm2.** → Graceful-update flush makes updates lossless-restore events; onboarding and marketing promise "workspace + resumable sessions," never process freezing; Claude/SSH (the sessions users care most about) are lossless anyway; v0.4 holder layer closes the gap fully; never overpromise before then.
5. **CoreText renderer too slow; Metal work drags forward and starves the differentiator.** → M0 measurement gate with a named kill criterion and a named schedule trade (cut M4 polish, not M3 adapters); trsdn fork as starting point; `TerminalEngine` keeps the libghostty-vt swap open.
6. **Capture races** (1–2 s poll misses short-lived state; kernel vs OSC disagreement; panic seconds after a Claude session starts). → OSC 133 D pins snapshots at command boundaries; explicit reconciliation rules (FR-15); adapter `refresh()` re-verifies each poll; fallback chain covers a missed live capture; dedupe (FR-36) prevents the fallback's ambiguity from producing wrong offers.
7. **Scope creep toward iTerm2 parity** (the 1000-checkbox gravity well). → The MoSCoW list is the contract; anything not M/S is refused until v0.2; palette-not-preferences caps settings surface structurally; dogfooding from M1 keeps pressure on restore, not exotic parity; M3's demo video is the forcing function.
8. **A funded competitor ships reboot-restore first** (Warp adding command replay, Ghostty adding persistence). → Speed is the strategy (5.5 months to beta); the Claude adapter + reboot video is the defensible wedge neither is positioned for (Warp restores text only; Ghostty rejects persistence); local-only/no-account positioning targets exactly the users Warp alienated.
9. **Shell-integration injection breaks exotic setups** (custom ZDOTDIR, direnv, nix). → Kernel-truth layer works with zero shell cooperation, so capture degrades gracefully; injection is visible and one-key disableable; test matrix covers zsh/bash/fish + oh-my-zsh + starship + direnv.
10. **Scrollback contains secrets; continuous capture perceived as surveillance.** → Local-only data in one documented, inspectable directory; zero telemetry/account/network; private-pane + secure-input auto-exclusion; "Forget everything"; at-rest encryption fast-follow; source-available core under active consideration (see open questions) — the Warp backlash shows this segment punishes anything less.

---

## 12. Open Questions for the Founder

1. **Source posture:** open-source, source-available, or closed? The target segment materially rewards source-available (trust in the capture engine), but it constrains monetization. Recommendation to decide before beta: source-available core (capture/restore engine) + proprietary app, or full OSS with a paid binary (Ghostty/Sketch models).
2. **Business model:** one-time purchase, subscription, or free-during-beta-then-paid? Affects Sparkle licensing flow and how aggressively to court Homebrew distribution. No account is a hard constraint either way — license keys must work offline.
3. **Name clearance:** trademark/domain search for memterm vs Keel — needed before M3, since the demo video carries the name.
4. **Claude adapter relationship:** approach Anthropic about the undocumented `~/.claude/sessions/` registry — a documented/stable interface (or even co-marketing around the resume story) would eliminate risk #1. Is the founder comfortable building the hero feature on an undocumented format in the interim (with the fallback chain as insurance)?
5. **Ghost scrollback default depth:** spec says capture 10k lines, restore all lazily. Is there a memory/disk ceiling on older Macs that argues for a smaller *restored* default with "load more"? Decide from M4 soak data.
6. **bash/fish priority:** zsh covers most of macOS; is shipping v0.1 beta with zsh-only integration acceptable (kernel layer still covers bash/fish users) if it buys two weeks of schedule?
7. **Beta channel:** recruit from tmux-resurrect GitHub + Claude Code communities as planned, or also HN/lobste.rs early? Earlier public exposure sharpens positioning but burns the one first-impression the demo video is being saved for.
8. **v0.4 holder layer commitment:** the app-update regression is the one honest daily downgrade vs iTerm2. Confirm v0.4 prioritization now so launch messaging ("coming: live processes survive app updates") can be made truthfully — or decide to stay journal-only permanently and own that positioning.
9. **macOS floor:** spec says macOS 14+. Any known user base on 13 (e.g., older Intel machines) worth the support cost? Recommendation: hold at 14+.
10. **Windows/tab identity across reboots:** should restored windows return to their original Spaces/displays (flaky macOS territory) or simply restore frames on the current display arrangement? Recommendation: frames-only in v0.1, Spaces as a v0.2 investigation.