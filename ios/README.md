# MemtermRemote (iOS/iPadOS)

The iPhone/iPad client for memterm's remote attach: pair with a Mac by
scanning the QR code it shows, then mirror and type into its terminal
sessions over the relay.

The Xcode project is **generated**, not committed. `ios/project.yml` is the
single source of truth for targets, settings, and dependencies — never hand
edit `MemtermRemote.xcodeproj`, and never commit it (it's gitignored).

## Building

```sh
brew install xcodegen          # once
xcodegen generate --spec ios/project.yml --project ios
open ios/MemtermRemote.xcodeproj
```

Re-run `xcodegen generate` any time `project.yml` changes, or whenever Xcode
complains the project looks stale. If you want to change a build setting, a
dependency, or a target, edit `ios/project.yml` and regenerate — don't do it
in Xcode's project editor, since that only edits the generated (and
gitignored) `.xcodeproj`.

## Structure

- `MemtermRemote/` — the app target's sources (SwiftUI screens, storage).
- Links `MemtermRemoteKit` and `MemtermRemoteApp` from the root SwiftPM
  package (`../Package.swift`) — the handshake, crypto, protocol, session
  state machine, and storage contracts are all shared with (and unit-tested
  by) the Mac app's `swift test` suite, headlessly, with no iOS target
  involved.
- Links `SwiftTerm` for the terminal view (used starting with the tree/
  attach screens).
