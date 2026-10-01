# iOS remote-attach client — verification checklist

Built during task 4 (tree + terminal screens, real end-to-end run).

Read the marker on every line before trusting a checkmark:

- **[sim]** — run in the Simulator as part of this task.
- **[driver]** — the control's underlying `HostSession` call was driven
  directly against a real Mac, from a command-line tool. Real protocol
  traffic, real Mac, **no tap**: a button wired to the wrong call, or wired
  to nothing, would still have passed. The view layer's own wiring is
  unproven until someone repeats these with a finger.
- **[device]** — needs a physical iPhone or iPad; no simulator substitute.

## Build

- [x] **[sim]** `swift test` — 545 tests pass.
- [x] **[sim]** `scripts/check-extension-firewall.sh` — `FIREWALL-PASS`.
- [x] **[sim]** `xcodegen generate --spec ios/project.yml --project ios`, then
      `xcodebuild -scheme MemtermRemote -skipPackagePluginValidation -destination 'generic/platform=iOS' build`
      — `BUILD SUCCEEDED`, zero warnings from this task's own files.
      **`-scheme` is required, and this line used to omit it.** Without it,
      `xcodebuild` builds the target without building the SwiftPM packages it
      links, so the first build on a machine with no DerivedData for this
      project fails with `unable to resolve module dependency:
      'MemtermRemoteApp'` and a missing `SwiftTerm_SwiftTerm.bundle`. It
      passed before only because a previous build had already populated
      DerivedData — which is exactly the kind of thing this checklist exists
      to stop anyone believing.
- [x] **[sim]** Simulator build (`platform=iOS Simulator`) — `BUILD SUCCEEDED`.
- [x] **[sim]** Install + launch on an iPhone 17 Pro simulator (iOS 26.5,
      runtime actually installed on this Mac — there is no iPhone 16 Pro
      runtime here). Screenshot of the empty "No Paired Macs" list.

## Debug seeding (Simulator has no camera)

- [x] **[sim]** `-memterm-seed-host` + `MEMTERM_SEED_HOST_JSON` (env, via
      `SIMCTL_CHILD_` prefix with `simctl launch`) inserts a `PairedHost` into
      the Keychain store at launch. Both `#if DEBUG`-only; absent from a
      release build by construction (grep for `#if DEBUG` in
      `MemtermRemoteApp.swift` / `SecureEnclaveIdentity.swift`).
- [x] **[sim]** Companion `MEMTERM_SEED_IDENTITY_KEY_B64` (also `#if DEBUG`,
      `SecureEnclaveIdentity.debugSeedIdentity`) installs a specific raw P-256
      key into this device's identity slot. Added beyond the task brief's
      literal ask, because without it a seeded `PairedHost` can never actually
      connect: the Mac's `RemoteHost.handleEnvelope` drops every envelope from
      a device id it does not already hold in its own paired-device store
      (`guard let device = store.device(id: envelope.from) else { return }`)
      — a `PairedHost` dropped into the PHONE's storage, on its own, proves
      nothing about whether the MAC will talk to it. See the task-4 report for
      how the matching identity was produced (a real pairing handshake, not a
      fabricated key).

## The real end-to-end run

Mac host: `dist/memterm.app` (stamped via `scripts/make-app.sh`,
`MEMTERM_ALLOW_DIRTY=1` — task 4's own uncommitted files were present at build
time), run with an isolated `MEMTERM_CONFIG_PATH` / `MEMTERM_STATE_DIR` and
`[remote] enabled = true`, `relay_url = "ws://127.0.0.1:8787"` (a locally
spawned copy of `relay/dist/src/server.js` — the same local, plain-`ws://`
relay the in-tree `ProbeLegs.swift` `addRemoteSteps` leg already uses for this
exact purpose; `wss://` is not needed to run this locally). Pairing link
minted via `MEMTERM_REMOTE_PAIR_LINK_FILE`.

Camera-less pairing used a temporary headless tool speaking the pair/hello
control frames directly (the same wire shapes `RemoteProbeClient` and
`PairingFlow` use) — not `PairingFlow` itself, which enforces `wss://` at
`scanned(_:)` by design (see `PairingFlowTests`, "ws:// ... must not be
dialled"). That tool and its identity key are not part of this commit; the
report has the full recipe to reproduce it.

- [x] **[sim]** The tree lists the Mac's real pane: workspace "Default", one
      row titled with the real shell prompt (`ril3y@ril3ys-Mac-mini:...`),
      `shell · <real cwd>` subtitle, `attachable=true`.
- [x] **[driver]** Typing `echo ios-ok` reaches the Mac's pane — confirmed twice, by
      reading the Mac's own scrollback file after each run (not just this
      viewer's local echo).
- [x] **[driver]** Fit's underlying call, `session.resize(cols:rows:)`, changes the Mac's
      actual grid — confirmed twice via `tput cols; tput lines` in the Mac's
      own scrollback, before and after an explicit resize (120×33 → 51×16 on
      the first run, 120×33 → 47×13 on the second). What this does NOT cover:
      the driver passed its own cols and rows, so Fit's own measuring step
      (`Handle.proposeDimensions()`, reading the live `TerminalView`'s grid)
      has never run. A wrong size there would resize the Mac to the wrong
      shape while every check above still passed.
- [x] **[driver]** Back's underlying call, `session.detach()`, returns the session to
      `.ready` (the tree) — confirmed via `HostSession.phase`.
- [x] **[driver]** Closing the pane on the Mac returns the viewer to the tree on its own —
      confirmed at the `HostSession` level by the existing, passing unit test
      `HostSessionTests` ("a vanished pane drops the viewer back to the
      tree", `session.phase == .ready` after a `.tree` without the attached
      pane arrives). The LIVE run only had one window on the Mac, so exiting
      its one shell quit the whole host app rather than merely pruning one
      pane from a surviving tree — `HostSession` still handled that
      correctly, moving to `.offline` rather than hanging. The literal
      "other panes remain, only one closes" scenario needs either a
      multi-window Mac session or a device/Accessibility-enabled host to set
      up the second window by hand; see the report.

### What this task's sandbox could NOT exercise with real taps

This agent's Simulator has no Accessibility ("assistive access") grant —
`osascript ... tell application "System Events"` returns -1719 for any
window-level UI scripting, confirmed while attempting it. So the screens'
actual on-screen behavior (tapping a tree row, pressing Fit/Back, seeing the
offline banner render) could not be driven by a simulated finger tap in this
session. Instead, the exact same `HostSession` calls each control makes
(`attach`, `input`, `resize`, `detach`) were driven directly against the real
Mac from a temporary command-line tool built on the same tested
`MemtermRemoteApp` target — real protocol traffic, real Mac, just not a real
tap. A session with Accessibility permission (or a physical device) should
re-run the interactive parts below and confirm the screens render as this
task's `TreeView.swift` / `TerminalScreen.swift` intend.

## Physical-device-only (not reachable in any simulator)

- [ ] **[device]** Camera QR scan actually pairs (this task used the
      DEBUG seed instead, by necessity).
- [ ] **[device]** Type through the on-screen keyboard and confirm the shell
      receives exactly what was typed. The driver called `session.input()`
      directly, so no keystroke has ever passed through the software keyboard
      or `Coordinator.send(source:data:)`. Type a straight apostrophe and a
      pair of double quotes in a command (`echo "it's fine"`) and confirm
      they arrive straight: iOS substitutes curly quotes and en-dashes by
      default, which silently changes a shell command. `TerminalViewHost`
      turns all six input traits off, but only a real keyboard proves it.
- [ ] **[device]** Press Fit and confirm the Mac's grid matches what the
      phone is actually showing (see the Fit note above: the measuring step
      has never run).
- [ ] **[device]** The device-key callout on the Pair screen matches the key
      in the Mac's own "Allow ‹name›?" prompt.
- [ ] **[device]** Rotating the device changes only what the viewer can see
      (SwiftTerm's own frame-driven reflow) — the Mac's pane size is
      unaffected until Fit is pressed. (Code-level guarantee already checked:
      `grep -rn "\.resize(" ios/MemtermRemote/` finds exactly one call site,
      `TerminalScreen.fit()`; there is no `layoutSubviews`,
      `traitCollectionDidChange`, or `onChange(of: <geometry>)` anywhere in
      this target.)
- [ ] **[device]** Split View / Slide Over / Stage Manager resize the view
      only, same guarantee.
- [ ] **[device]** Backgrounding and returning re-attaches
      (`sceneBecameActive`/`sceneWentToBackground` are wired in
      `MemtermRemoteApp.swift`; needs a device to see the actual
      foreground/background transition).
- [ ] **[device]** Revoking this device from the Mac's Settings ▸ Remote list
      produces `.failed("This Mac no longer allows this device.")` on the
      phone (`HostSession.handleControl`'s `"refused"`/`"not-allowed"` case —
      code-level only, not live-fired this session).
