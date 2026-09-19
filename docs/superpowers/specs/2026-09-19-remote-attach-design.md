# Remote attach: mirror and control memterm sessions from another device

**Status:** design approved in conversation 2026-09-15 → 2026-09-19; not implemented.
**Sub-projects decided:** (1) this — remote attach via a blind relay; (2) SSH host manager, separate spec; (3) workspace locks, separate bounded follow-up (two protocol hooks reserved here).

## Goal

From a phone or another computer on any network, see and type into the terminal sessions that are running inside memterm on the Mac mini — the same session, not a copy. tmux-attach semantics over the internet, without opening ports on the mini and without a service that can read the traffic.

Non-goals for this project: moving a session to another machine (journal sync), a native iOS app, notifications, the SSH host manager, workspace locks (hooks only).

## Constraints carried from REQUIREMENTS

- "No accounts, no cloud, no telemetry": remote access is **off by default**, opt-in per install, and the relay is **blind** (end-to-end encrypted) and **self-hostable** (one container, holds no secrets).
- The host is the running memterm app: the ptys are its processes. No second daemon. If memterm is not running on the mini, nothing is reachable — consistent with the disk-is-the-persistence-layer thesis.
- Everything a remote client can do is exactly what a local keyboard can do to the same pane. No side channel that bypasses the terminal, so FR-30/31 denylist and consent rules hold remotely by construction.

## Architecture

Three units.

### 1. Remote host (inside memterm, app target `Sources/memterm/Remote/`, pure parts in `MemtermCore/Remote/`)

- Runs while Settings ▸ Remote is on. Keeps one outbound WebSocket to the relay (URLSessionWebSocketTask), reconnecting with backoff.
- Identity: a P-256 key pair generated on first enable, stored in the Keychain (stable under the Developer ID signing identity). Host ID = SHA-256 of the public key, base32, first 16 chars.
- Exposes the live model: workspaces → windows/tabs → panes with titles and adapter kind (the same tree the timeline lists). A viewer attaches to a pane; the host fans that pane's raw pty output to every attached viewer and writes viewer input into the pty.
- On attach, sends the pane's current screen first (the visible grid as bytes: clear + redraw from the engine's grid snapshot), then streams.
- Per-viewer output backlog capped (256 KB, oldest dropped) so a slow viewer never stalls the pty.
- Lock hooks (sub-project 3): `list` marks a workspace `locked`; `attach` on a locked pane replies `refused locked`; `unlock` is accepted, rate-limited (5/min per device), and verified by the host. In this project no workspace is ever locked; the fields and refusal path exist and are tested.

### 2. Relay (new repo dir `relay/`, Node 20 + TypeScript + `ws`, Dockerfile + fly.toml cloned from SmartFoodie's api)

- Endpoints: `wss://…/host` (a host connects, proves its ID by signing a nonce with its key), `wss://…/client` (a device connects, proves its device ID the same way), `GET /` (serves the static web client), `GET /healthz`.
- State: `hosts: hostId → {socket, allowedDevices: Set<deviceIdHash>}`; `pairings: token → {hostId, expiresAt}`. All in memory; a restart drops connections, which reconnect and re-announce their allow-lists. Nothing persisted, no database, no secrets.
- Forwarding: an envelope `{to, from, payload}`; the relay checks `from` matches the authenticated socket and `to` is an allowed pair, then forwards the opaque payload. It never decrypts.
- Pairing: host registers a token (from its QR code); a device presents the token with its public key; the relay forwards the pairing request to the host; the host answers accept/deny; on accept the relay adds the device hash to the host's allow-list for this connection (the host re-announces the list on every connect, so the host's device list is the truth).
- Runs on one `shared-cpu-1x`/512 MB Fly machine, `force_https`, `min_machines_running = 1`, no volume.

### 3. Web client (`relay/web/`, TypeScript, xterm.js, no framework)

- Single page: unlock → host list (one host for now) → tree → terminal. Keys: a P-256 key pair in IndexedDB (clearing site data un-pairs the browser; shown honestly in the host's device list).
- Renders the pane's byte stream with xterm.js; sends keystrokes as `input`. "Fit to me" sends `resize`. Shows `offline` with last-seen when the host is away, retries with backoff.
- All crypto through WebCrypto (ECDH P-256, HKDF-SHA256, AES-256-GCM) — matches CryptoKit on the Mac with no third-party crypto on either side.

memterm-as-client (attach from another Mac, remote pane as a tab) is a later client that speaks the same inner protocol; not in scope.

## Crypto

- Long-lived identity keys (host, device): P-256. Pairing exchanges public keys; each side stores the other's.
- Session: on every client↔host connection, both sides generate ephemeral P-256 keys, exchange them signed by their identity keys (authentication), derive `k = HKDF-SHA256(ECDH(eph), info: "memterm-remote-v1" ‖ hostId ‖ deviceId)`, split into two directional AES-256-GCM keys. Frame nonce = 96-bit counter per direction; a repeated or out-of-order counter tears the session down.
- Every inner message is one AES-GCM record; the GCM tag authenticates it. The relay sees only envelopes.

## Inner protocol (after decryption; one JSON message per record)

Client → host: `list`, `attach {paneId}`, `detach`, `input {bytesB64}`, `resize {cols, rows}`, `newTab {workspaceId}`, `unlock {workspaceId, passphrase}` (hook).
Host → client: `tree {workspaces:[{id,name,color,locked,parked,windows:[{id,tabs:[{id,title,panes:[{id,adapter,cwd}]}]}]}]}`, `screen {cols, rows, bytesB64}` (on attach), `output {bytesB64}`, `tree-changed`, `refused {reason}`, `resized {cols, rows}`.
Relay → client: `offline {lastSeen}`, `online`.

## Pairing UX (Settings ▸ Remote)

On/off switch; relay URL (default: the Fly app); "Pair a device…" shows a QR code with `{relayURL, hostId, hostPublicKey, token}` — token single-use, 2-minute expiry; the host shows "Allow ‹device name›?" before adding; device list with name, last seen, Remove (revokes at the host; the relay's allow-list follows on the next announce). The host's key pair and device list live in the Keychain / state dir, not the journal.

## Multiple viewers and size

Any number of paired devices plus the mini's own window may view one pane. Output fans out; input interleaves in arrival order. The pty has one size: the mini's window wins while it exists and remote viewers render that grid (scrolling if smaller); a viewer's explicit "Fit to me" resizes the pty to its grid and the mini's pane reflows. Nothing resizes silently.

## Failure handling

- Host offline / app quit / mini asleep: relay sends `offline`; client shows it and retries with backoff on `online`. The relay buffers nothing.
- Client drop: pane keeps running; next attach gets a fresh `screen`.
- Relay down: host reconnects with backoff; client shows "relay unreachable".
- Bad/replayed frame: session torn down, logged once, never acted on.
- Revoked device: relay refuses the pair on the next envelope; host drops any live session for it.

## Testing (house style: pure seams + probe legs + one real end-to-end)

- MemtermCore (headless): frame codec round-trips; handshake + HKDF against fixed test vectors (also run in the web client's test suite with the same vectors, so both crypto stacks agree); tree serialization; backlog cap; lock refusal and unlock rate limit.
- Relay: in-process test spins the relay and drives fake host + device sockets through auth, pairing (accept/deny/expiry), forwarding, host-drop → `offline`, revocation.
- Web client: codec + crypto vectors in Node; xterm rendering is not unit-tested.
- Probe leg (fresh mode): start the relay locally on a random port, pair a headless Swift client with the running app through the real QR payload, `list`, `attach` a real pane, send `echo remote-probe\r`, assert the bytes round-trip and the `screen` snapshot equals the pane's rendered grid; then kill the relay and assert `offline`; then revoke and assert refusal. verify.sh greps the measured lines.
- Release: `relay/` gets its own CI job (Node tests) and a `fly deploy` step behind a `FLY_API_TOKEN` secret.

## Open items deliberately deferred

memterm-as-client; native iOS app; notifications; workspace locks UI/Touch ID (hooks only); per-workspace remote opt-out; multi-host in the web client (the data model allows it; the UI shows one).
