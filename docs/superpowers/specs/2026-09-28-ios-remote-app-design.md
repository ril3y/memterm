# memterm Remote for iPhone — design

**Status:** approved in conversation 2026-09-28 (founder: "view and type for now, keep it simple"; "ok do this").
**Supersedes nothing.** Extends the remote-attach design (`2026-09-19-remote-attach-design.md`) with a native client; the relay and the Mac host protocol are unchanged.

## 1. Goal

A native iPhone app that pairs with a Mac running memterm and lets the person see any pane and type into it, over the existing blind relay, with the same cryptography the web client uses today.

Why native, when a web client exists:
- The security review's remaining Critical (C1) is that whoever serves the web page can inject code into a paired browser. A signed app closes that class: the code comes from TestFlight or the App Store, the phone's identity key lives in the Secure Enclave, and no pairing secret ever passes through a web page.
- A real terminal keyboard (Esc, Ctrl, Tab, arrows), no autocorrect, correct rotation, reconnect on foreground.

## 2. Scope

### v1 (this spec)
- Pair with one or more Macs by scanning the QR memterm shows (camera), or by opening the pairing link (universal link or `memterm://` scheme).
- Show the paired Macs with online/offline presence.
- Show a Mac's workspace/window/tab/pane tree; attach to a pane.
- Full-screen terminal: mirror the pane, type into it, resize it ("Fit"), detach.
- Reconnect after backgrounding; re-attach to the last pane when it still exists.
- Forget a Mac locally (the Mac's own Revoke remains the authoritative cleanup).

### Non-goals for v1
- Opening tabs, switching or parking workspaces, unlocking locked workspaces (the host supports `newTab`/`unlock`; the app does not send them).
- Push notifications, background sessions, Mac Catalyst.
- App Store listing (TestFlight only). Multiple simultaneous terminals.

## 3. Architecture

```
ios/MemtermRemote.xcodeproj            SwiftUI app (iOS 17+)
  MemtermRemote/App                     entry, routing, universal-link handling
  MemtermRemote/Screens                 MacsView, PairView, TreeView, TerminalView(Screen)
  MemtermRemote/Session                 HostSession (state machine), PairingFlow
  MemtermRemote/Storage                 PhoneIdentity (Secure Enclave), PairedHostStore (Keychain)
  MemtermRemote/Terminal                SwiftTerm wrapper (UIViewRepresentable) + key bar config
  MemtermRemoteTests                    state-machine tests against a fake relay
Sources/MemtermRemoteKit/              NEW SwiftPM target (macOS 14 / iOS 17), shared by Mac host and phone
  Protocol/  RemoteMessage, RemoteEnvelope, RemoteTree, HelloWire     (moved from MemtermCore/Remote)
  Crypto/    RemoteCrypto (identity, handshake, session keys), RemotePairing, RemoteDeviceSeal
  Relay/     RelayConnection (NEW: extracted from RemoteHost), RelayEndpoint
  Support/   OutputBacklog, UnlockRateLimiter, RemotePairingPage
Tests/MemtermRemoteKitTests/           moved Remote* tests + vectors (Tests/vectors unchanged)
```

Everything in the kit imports only Foundation and CryptoKit. The Mac app target depends on the kit; `MemtermCore` no longer contains `Remote/`.

### 3.1 `RelayConnection` (kit)

The one relay client, used by `RemoteHost` (as `/host`) and by the phone (as `/client`).

```swift
public final class RelayConnection {
    public enum Role { case host, client }
    public enum State: Equatable { case off, connecting, connected, offline(String?) }
    public struct Events {
        public var onState: (State) -> Void
        public var onControl: ([String: Any]) -> Void        // authed, paired, pair-denied, online, offline, refused, pair-request…
        public var onEnvelope: (RemoteEnvelope) -> Void
    }
    public init(url: URL, role: Role, identity: any RemoteSigner, events: Events)
    public func start()                                      // connects; reconnects with backoff 1s→30s until stop()
    public func stop()
    public func send(control: [String: Any])                 // pair, pair-token, allowed, pair-answer
    public func send(envelope: RemoteEnvelope, completion: (() -> Void)?)
    public var state: State { get }
}
```

- `RemoteSigner` is a protocol (`id`, `publicKeySPKI`, `sign(_ nonce: Data) -> Data`) so the Mac's Keychain identity and the phone's Secure Enclave identity plug in without the kit knowing either.
- Owns the challenge/auth exchange, the 30 s ping, the receive loop with generation counters, and the backoff. It does NOT know about sessions, pairing state, or devices: those stay in `RemoteHost` (Mac) and `HostSession` (phone).
- Behavior is bit-for-bit what `RemoteHost` does today; the extraction is a refactor covered by the existing relay-facing tests plus the probe leg. All delivery to `Events` is on the main queue.

### 3.2 `HostSession` (phone)

One per paired Mac while the app is in the foreground and that Mac is selected.

```swift
@MainActor final class HostSession: ObservableObject {
    enum Phase: Equatable { case idle, connecting, handshaking, ready, attached(paneId: String), offline, error(String) }
    @Published private(set) var phase: Phase
    @Published private(set) var tree: RemoteTree?
    let output: AsyncStream<Data>                // screen bytes then output chunks for the attached pane
    init(host: PairedHost, identity: PhoneIdentity, relayFactory: (URL, RelayConnection.Events) -> RelayConnection)
    func start()   func stop()
    func attach(paneId: String)   func detach()
    func input(_ bytes: Data)     func resize(cols: Int, rows: Int)
}
```

- Handshake: `RemoteHandshake.makeHello` → send in the clear → verify the host's Hello against the STORED host public key → `deriveKeys(…, iAmHost: false)` → `RemoteSessionKeys`. Same generation-guard rule as the web client: a superseded handshake's reply is dropped.
- Counters: `RemoteSessionKeys` seals and opens on the main actor, in call order — the class already reserves the counter inside its lock (the web client's 2026-09-22 nonce bug cannot recur because there is no `await` between reserve and increment).
- `tree-changed` refetches the tree; if the attached pane vanished, the phase returns to `ready` and the terminal screen pops.
- `refused` reasons map to user-visible text; `not-allowed` while paired means the Mac revoked us → mark the host as revoked and offer Forget.

### 3.3 Screens

- **Macs** (`MacsView`): list of `PairedHost` with a presence dot (from `online`/`offline` control messages, fed by a lightweight presence connection when the app is in the foreground), a "Pair a Mac" button, swipe-to-forget. Tapping a Mac opens Tree.
- **Pair** (`PairView`): `DataScannerViewController` (VisionKit) reading the QR; on a recognized `#pair=` fragment, a confirm sheet: "Pair with Mac ‹hostId›? This phone's key: ‹deviceId›. The Mac's prompt shows the same key; if it shows anything else, don't allow it." Then "Waiting for the Mac to accept…" until `paired` (verify `hostId`/`hostPublicKey` match the scanned payload exactly, as the web client does) or `pair-denied (reason)`. The proof is `RemotePairing.proof(secret:, deviceSPKI:)` from the kit.
- **Tree** (`TreeView`): sections per workspace (name, color, locked/parked badges), rows per pane (adapter, cwd). Serial and locked panes are shown disabled. Tap → attach.
- **Terminal** (`TerminalScreen`): SwiftTerm `TerminalView` (UIKit, via `UIViewRepresentable`) sized to the host's `screen` cols/rows; bytes from `HostSession.output` are fed with `feed(byteArray:)`; `TerminalViewDelegate.send` forwards keystrokes as `input`; the built-in keyboard accessory bar provides Esc/Ctrl/Tab/arrows. Toolbar: Back (detach), Fit. Fit sends `resize` with the view's proposed cols/rows; nothing else ever does.

  **Resizing the Mac's pane is always an explicit gesture** (founder decision 2026-09-30, Jev 1.0 on the iPad framing; it also settles the rotation question that was a coin flip on the iPhone alone). Rotating the device, and on iPad entering split view, slide over or Stage Manager, changes only how much of the pane this viewer SEES: the terminal view re-lays out and scrolls, and the host's grid is untouched. The reason is that a resize is visible to the person sitting at the Mac and can disturb a running full-screen program there, so it must never be a side effect of the viewer turning a device or another app taking half the screen. The rule stays "host window wins, Fit-to-me resizes" — Fit is the only thing that resizes.

### 3.4 Identity and storage

- `PhoneIdentity`: P-256 signing key created in the Secure Enclave (`SecureEnclave.P256.Signing.PrivateKey`), stored as its data representation in the Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, no iCloud). `publicKeySPKI` is built from the raw public key with the same 26-byte header the kit already pins; the device id is `RemoteIdentity.peerId(forSPKI:)`. Because the Enclave key cannot be exported, the identity is per phone; a restore to a new phone means pairing again.
- `PairedHostStore`: Keychain generic-password items, one per host: `hostId`, `hostPublicKeySPKI`, `relayURL`, `name`, `pairedAt`. Device-only. Forget deletes the item.

### 3.5 Pairing links

- The QR link is unchanged: `https://ril3y.github.io/memterm/#pair=<base64url JSON>`.
- Universal links: `https://ril3y.github.io/.well-known/apple-app-site-association` (in the founder's user-site repository, NOT this one) with `applinks` for paths `/memterm/*`, app ID `YJ6Y72HALX.com.memterm.remote`. The app's entitlement: `applinks:ril3y.github.io`. Fragments are not sent to servers and are delivered to the app intact.
- Secondary scheme `memterm://pair?payload=<base64url JSON>` registered by the app (and, later, by the Mac app for Mac-to-Mac viewing).
- Without the app, the same link opens the web page as it does today.

### 3.6 Connectivity and errors

- Foreground only. `scenePhase` → background: stop the session's connection (the host tears the session down on socket close and the relay reports us offline). → active: start again, handshake, and if `lastAttachedPaneId` exists in the fresh tree, re-attach automatically.
- Relay unreachable: phase `offline` with a banner ("Reconnecting…"); backoff is the connection's.
- Host offline (relay `offline`): banner with last-seen; the tree stays visible but disabled.
- Decrypt failure (`replay`/`malformed`): drop the session and re-handshake once; if it repeats, show the error.
- Pairing errors: `pair-denied (token)` → "Code expired or already used; show a fresh one." `pair-denied (host)` → "The Mac declined." Mismatched `paired` reply → "The Mac's reply did not match the code you scanned."

### 3.7 Build, sign, ship

- Bundle id `com.memterm.remote`, team `YJ6Y72HALX`, iOS 17 deployment target, **universal (iPhone + iPad)**. The founder owns an iPad mini, an iPad is a better terminal viewer than a phone (roughly twice the columns in landscape), and in SwiftUI the cost is the device family plus checking the four screens at iPad sizes — which v1 does. The app must also behave in a resized multitasking window, which the resize rule in 3.3 already settles by never resizing the host for a window change.
- Project: `ios/MemtermRemote.xcodeproj` committed to this repo; local package dependency on the repo root (`MemtermRemoteKit`) and SwiftTerm (`ril3y/SwiftTerm`, the same fork the Mac uses).
- CI (`.github/workflows/ios.yml`): on push to the default branch and on `v*` tags, on `macos-15`: `swift test --filter MemtermRemoteKit`, `xcodebuild test` for the app's unit tests on a simulator, then on tags `xcodebuild archive` with automatic signing through the App Store Connect API key already in secrets (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`) and `-allowProvisioningUpdates`, export for App Store distribution, and upload with `xcrun altool --upload-app --type ios` using the same key. Version = tag; build number = commit count (as the Mac app).
- The founder creates the App ID with the Associated Domains capability once in the developer portal (or the first `-allowProvisioningUpdates` run does).

## 4. Data flow

1. **Pair:** scan → payload → confirm → `RelayConnection(client)` to `payload.relay` → `authed` → `pair {token, publicKey, name, proof}` → Mac prompt → `paired {hostId, hostPublicKey}` → verify against payload → `PairedHostStore.add` → Tree.
2. **Session:** select Mac → `RelayConnection(client)` to `host.relayURL` → `authed` → Hello → host Hello → keys → `list` → `tree` → Tree screen.
3. **Attach:** tap pane → `attach` → `screen{cols,rows,bytes}` → terminal sized and painted → `output` chunks streamed → keystrokes → `input`. Fit → `resize` → `resized{cols,rows}` → terminal resized to what the host reports.
4. **Background/foreground:** as in 3.6.

## 5. Testing

- Kit: every existing Remote test moves unchanged; the shared vectors (`Tests/vectors/remote-crypto-vectors.json`) keep pinning Swift ↔ TypeScript agreement. New: `RelayConnectionTests` against a local `ws` echo-style fake (auth handshake, ping, backoff, generation guard).
- App: `HostSessionTests` drive the state machine with a fake `RelayConnection` (injected factory): handshake, list, attach, output ordering, tree-changed pruning, background/foreground re-attach, refused/revoked handling, superseded handshakes.
- Mac: the existing `remote-end-to-end` probe leg is the regression net for the extraction (host behavior unchanged).
- Manual TestFlight checklist (one page in `ios/CHECKLIST.md`): pair by camera, pair by link, key comparison, type, Fit, rotate, background/return, revoke from the Mac, forget on the phone.

## 6. Decomposition (three plans, in order)

1. **Kit extraction + `RelayConnection`** — Mac-only change, fully covered by existing tests and the probe; ships as a normal memterm release with no behavior change.
2. **iPhone app v1** — screens, session, identity, terminal; unit tests; runs on a simulator and a phone from Xcode.
3. **Links + CI + TestFlight** — universal links (user-site file), `ios.yml`, first TestFlight build.

## 7. Open items, decided defaults

- Multiple paired Macs from day one (costs nothing).
- TestFlight only; App Store listing is a later decision.
- iPad: in, from v1 (see 3.7). Mac Catalyst: not now; the SwiftUI screens should not preclude it.
- Push notifications: no; the relay is blind and holds no tokens by design.
