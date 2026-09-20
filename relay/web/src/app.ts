// Remote-attach web client (decision doc 2026-09-19): pairing, the
// workspace/tab/pane tree, attaching a pane with xterm.js, resize, and
// online/offline presence. No framework -- plain DOM, wired up here.

import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import {
  type Identity,
  generateIdentity,
  makeHello,
  verifyHello,
  encodeHello,
  decodeHello,
  deriveKeys,
  pairProof,
  SessionKeys,
} from "./crypto.js";
import { idFromPublicKey } from "../../src/auth.js";
import { type RemoteMessage, type RemoteTree, encodeMessage, decodeMessage } from "./codec.js";
import { RelayClient } from "./relay.js";

// -- IndexedDB: `memterm-remote` / `keys` -- identity + the paired host. --

const DB_NAME = "memterm-remote";
const STORE_NAME = "keys";

interface StoredHost {
  hostId: string;
  hostPublicKey: Uint8Array;
}

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE_NAME);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function idbGet<T>(db: IDBDatabase, key: string): Promise<T | undefined> {
  return new Promise((resolve, reject) => {
    const req = db.transaction(STORE_NAME, "readonly").objectStore(STORE_NAME).get(key);
    req.onsuccess = () => resolve(req.result as T | undefined);
    req.onerror = () => reject(req.error);
  });
}

function idbPut(db: IDBDatabase, key: string, value: unknown): Promise<void> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, "readwrite");
    tx.objectStore(STORE_NAME).put(value, key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

async function loadOrCreateIdentity(db: IDBDatabase): Promise<Identity> {
  const existing = await idbGet<Identity>(db, "identity");
  if (existing) return existing;
  const identity = await generateIdentity();
  await idbPut(db, "identity", identity);
  return identity;
}

// -- Base64 helpers for the wire strings that aren't already handled by codec.ts/crypto.ts. --

function standardBase64ToBytes(s: string): Uint8Array | undefined {
  try {
    const binary = atob(s);
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
    return out;
  } catch {
    return undefined;
  }
}

function base64urlToBytes(s: string): Uint8Array | undefined {
  const std = s.replace(/-/g, "+").replace(/_/g, "/");
  const pad = std.length % 4 === 0 ? "" : "=".repeat(4 - (std.length % 4));
  return standardBase64ToBytes(std + pad);
}

// -- Pairing: `#pair=<base64url(JSON)>`, matching `RemoteHost.PairingPayload`. --

interface PairingPayload {
  relay: string;
  hostId: string;
  hostPublicKey: string;
  /** The routing half of the pairing token: the only half the relay sees. */
  token: string;
  /** The secret half, base64url. Never sent; only ever HMAC'd over our own
   *  public key so the host can tell we really scanned this code. */
  secret: string;
  expiresAt: number;
}

function decodePairingHash(hash: string): PairingPayload | undefined {
  const match = /^#pair=(.+)$/.exec(hash);
  if (!match) return undefined;
  const bytes = base64urlToBytes(match[1]);
  if (!bytes) return undefined;
  try {
    const value: unknown = JSON.parse(new TextDecoder().decode(bytes));
    if (typeof value !== "object" || value === null) return undefined;
    const obj = value as Record<string, unknown>;
    if (
      typeof obj.relay !== "string" ||
      typeof obj.hostId !== "string" ||
      typeof obj.hostPublicKey !== "string" ||
      typeof obj.token !== "string" ||
      typeof obj.secret !== "string" ||
      typeof obj.expiresAt !== "number"
    ) {
      return undefined;
    }
    return {
      relay: obj.relay,
      hostId: obj.hostId,
      hostPublicKey: obj.hostPublicKey,
      token: obj.token,
      secret: obj.secret,
      expiresAt: obj.expiresAt,
    };
  } catch {
    return undefined;
  }
}

function deviceName(): string {
  const ua = navigator.userAgent;
  if (/iPhone/.test(ua)) return "iPhone";
  if (/iPad/.test(ua)) return "iPad";
  if (/Android/.test(ua)) return "Android";
  if (/Macintosh/.test(ua)) return "Mac";
  if (/Windows/.test(ua)) return "Windows";
  if (/Linux/.test(ua)) return "Linux";
  return "Browser";
}

function relayWsUrl(): string {
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  return `${scheme}//${location.host}`;
}

// -- Module state. One page, one connection, one attached pane at a time. --

let db: IDBDatabase;
let identity: Identity;
let host: StoredHost | undefined;
/** A pairing the user has confirmed: the `pair` message is in flight or about to be. */
let pendingPairing: PairingPayload | undefined;
/**
 * A `#pair=` payload that has been parsed but NOT yet confirmed by the
 * person holding the phone (security review L3). Opening a link used to
 * pair on page load with no confirmation, and silently overwrite an
 * existing host -- so a link someone sends you could re-point your browser
 * at their terminal tree, which you might then type secrets into.
 */
let awaitingConfirm: PairingPayload | undefined;
let relay: RelayClient | undefined;
let relayAuthed = false;

interface PendingHandshake {
  gen: number;
  ephemeralPrivate: CryptoKey;
}

// Bumped by every startSession() call, so a Hello reply belonging to a
// superseded handshake (onPaired/onAuthed/onOnline can each kick one off,
// and they can overlap -- e.g. the relay socket reconnects and authenticates
// again while an earlier handshake attempt is still in flight) is
// recognizable as stale and dropped instead of corrupting key derivation.
let handshakeGen = 0;
let pendingHandshake: PendingHandshake | undefined;
let session: SessionKeys | undefined;

let tree: RemoteTree | undefined;
let term: Terminal | undefined;
let fitAddon: FitAddon | undefined;
// The pane we were last attached to, kept across a dropped session (offline,
// a failed `open`, a lost relay socket) so a successful re-handshake can
// silently re-attach it. Cleared only by an explicit user Back/detach.
let lastAttachedPaneId: string | undefined;

let relayUnreachable = false;
let hostOfflineSince: number | undefined;

// -- View / banner / toast plumbing. --

type ViewName = "not-paired" | "confirm-pair" | "pairing" | "tree" | "terminal";

const VIEWS = ["not-paired", "confirm-pair", "pairing", "tree", "terminal"] as const;

function showView(name: ViewName): void {
  for (const v of VIEWS) {
    const el = document.getElementById(`view-${v}`);
    if (el) el.hidden = v !== name;
  }
}

function recomputeBanner(): void {
  const el = document.getElementById("banner");
  if (!el) return;
  if (relayUnreachable) {
    el.textContent = "Relay unreachable";
    el.hidden = false;
  } else if (hostOfflineSince !== undefined) {
    el.textContent = `Host offline since ${new Date(hostOfflineSince).toLocaleTimeString()}`;
    el.hidden = false;
  } else {
    el.hidden = true;
  }
}

function updateTreeDisabled(): void {
  const el = document.getElementById("tree");
  if (el) el.classList.toggle("disabled", hostOfflineSince !== undefined);
}

let toastTimer: ReturnType<typeof setTimeout> | undefined;
function showToast(text: string): void {
  const el = document.getElementById("toast");
  if (!el) return;
  el.textContent = text;
  el.hidden = false;
  if (toastTimer !== undefined) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    el.hidden = true;
  }, 4000);
}

function paneExists(t: RemoteTree, paneId: string): boolean {
  for (const ws of t.workspaces) {
    for (const win of ws.windows) {
      for (const tab of win.tabs) {
        for (const pane of tab.panes) {
          if (pane.id === paneId) return true;
        }
      }
    }
  }
  return false;
}

// -- Tree rendering: workspace -> tabs -> panes as buttons. --

function renderTree(): void {
  const container = document.getElementById("tree");
  if (!container) return;
  container.innerHTML = "";
  if (!tree || tree.workspaces.length === 0) {
    container.textContent = "No workspaces.";
    return;
  }
  for (const ws of tree.workspaces) {
    const section = document.createElement("section");
    section.className = "workspace" + (ws.parked ? " parked" : "");
    const headingRow = document.createElement("div");
    headingRow.className = "workspace-heading";
    const heading = document.createElement("h2");
    heading.textContent = (ws.locked ? "\u{1F512} " : "") + ws.name;
    headingRow.appendChild(heading);
    // "Open tabs" (README / FR-60): a remote client can do exactly what a
    // local keyboard can do to a workspace, including ⌘T — mirrors the
    // host's own lock check (RemoteHost+Dispatch.newTab).
    const newTabBtn = document.createElement("button");
    newTabBtn.type = "button";
    newTabBtn.className = "new-tab-btn";
    newTabBtn.textContent = "New tab";
    newTabBtn.disabled = ws.locked;
    newTabBtn.addEventListener("click", () => {
      void sendMessage({ t: "newTab", workspaceId: ws.id });
    });
    headingRow.appendChild(newTabBtn);
    section.appendChild(headingRow);
    for (const win of ws.windows) {
      for (const tab of win.tabs) {
        const tabDiv = document.createElement("div");
        tabDiv.className = "tab";
        const title = document.createElement("span");
        title.className = "tab-title";
        title.textContent = tab.title;
        tabDiv.appendChild(title);
        for (const pane of tab.panes) {
          const btn = document.createElement("button");
          btn.textContent = pane.cwd ? `${pane.adapter} · ${pane.cwd}` : pane.adapter;
          btn.disabled = ws.locked;
          btn.addEventListener("click", () => onPaneClick(pane.id));
          tabDiv.appendChild(btn);
        }
        section.appendChild(tabDiv);
      }
    }
    container.appendChild(section);
  }
}

// -- Session: handshake with the stored host, seal/open the inner protocol. --

/** Leaves an attached terminal (if any) back to the tree, without touching `lastAttachedPaneId`. */
function leaveTerminal(): void {
  term?.dispose();
  term = undefined;
  fitAddon = undefined;
  showView("tree");
}

/** Kills any live session/in-flight handshake and drops a live terminal back to the tree. */
function dropSession(): void {
  handshakeGen++; // invalidate any handshake still in flight
  session = undefined;
  pendingHandshake = undefined;
  if (term) leaveTerminal(); // a session or handshake never outlives its terminal
}

async function startSession(): Promise<void> {
  if (!host || !relay) return;
  // Every fresh handshake starts from the tree: a terminal left over from a
  // previous (now-dead) session would otherwise sit there with no session to
  // send its input through, and the "tree" handler's re-attach logic only
  // runs when no terminal is currently open.
  if (term) leaveTerminal();
  // Unconditionally supersedes any handshake already in flight: its Hello
  // reply, whenever it arrives, will carry a stale `gen` and be dropped.
  const gen = ++handshakeGen;
  session = undefined;
  const { hello, ephemeralPrivate } = await makeHello(identity.privateKey);
  if (gen !== handshakeGen) return; // superseded again while awaiting makeHello
  pendingHandshake = { gen, ephemeralPrivate };
  relay.sendEnvelope(host.hostId, new TextEncoder().encode(encodeHello(hello)));
}

function teardownSession(message: string): void {
  dropSession();
  showToast(message);
  updateTreeDisabled();
}

async function sendMessage(m: RemoteMessage): Promise<void> {
  if (!session || !host || !relay) return;
  const sealed = await session.seal(new TextEncoder().encode(encodeMessage(m)));
  relay.sendEnvelope(host.hostId, sealed);
}

async function handleEnvelope(from: string, payload: Uint8Array): Promise<void> {
  if (!host || from !== host.hostId) return;

  if (!session) {
    // Snapshot the pending handshake and check it against the current
    // generation right away: a Hello reply for a handshake that startSession()
    // has since superseded (a newer onPaired/onAuthed/onOnline call) is
    // stale and gets silently dropped rather than processed.
    const handshake = pendingHandshake;
    if (!handshake || handshake.gen !== handshakeGen) return;
    const hello = decodeHello(new TextDecoder().decode(payload));
    if (!hello) {
      teardownSession("The host's handshake reply was malformed");
      return;
    }
    const verified = await verifyHello(hello, host.hostPublicKey);
    // Re-check IMMEDIATELY after every await, before any branch below that
    // might call teardownSession() -- a superseded handshake's `verified`/
    // `hostEphemeralRaw` are meaningless and must never tear down whatever
    // newer handshake `startSession()` has since started.
    if (handshake.gen !== handshakeGen) return; // superseded while verifying; drop silently
    if (!verified) {
      teardownSession("Host verification failed");
      return;
    }
    const hostEphemeralRaw = standardBase64ToBytes(hello.ephemeralRaw);
    if (!hostEphemeralRaw) {
      teardownSession("The host's handshake reply was malformed");
      return;
    }
    // hostId for the key schedule always comes from the STORED SPKI, never
    // from a wire field (the envelope's `from`, or a prior "paired"/"online"
    // message) -- see the task brief's binding warning.
    const hostIdForKeys = await idFromPublicKey(host.hostPublicKey);
    if (handshake.gen !== handshakeGen) return; // superseded while computing the host id; drop silently
    const keys = await deriveKeys(handshake.ephemeralPrivate, hostEphemeralRaw, hostIdForKeys, identity.id, false);
    if (handshake.gen !== handshakeGen) return; // superseded while deriving keys; drop silently
    pendingHandshake = undefined;
    session = new SessionKeys(keys.sendKey, keys.recvKey);
    void sendMessage({ t: "list" });
    return;
  }

  let plain: Uint8Array;
  try {
    plain = await session.open(payload);
  } catch {
    teardownSession("The session with the host could not be read; reconnecting");
    return;
  }
  const msg = decodeMessage(new TextDecoder().decode(plain));
  if (!msg) return;
  handleRemoteMessage(msg);
}

function handleRemoteMessage(msg: RemoteMessage): void {
  switch (msg.t) {
    case "tree":
      tree = msg.tree;
      if (term) {
        // Already attached (a `tree-changed` arrived mid-session): keep
        // showing the terminal, just refresh the cached tree for later --
        // unless the attached pane itself is gone (closed locally on the
        // host: final-review Important 1's tree-changed now actually fires
        // for that). Left open, every further keystroke would just come
        // back refused("unknown-pane") as a toast, one per keystroke.
        // lastAttachedPaneId is left as-is -- this is not the dropped-session
        // recovery path below, just leaving a dead terminal.
        if (lastAttachedPaneId && !paneExists(msg.tree, lastAttachedPaneId)) {
          leaveTerminal();
          renderTree();
        }
        return;
      }
      showView("tree");
      renderTree();
      if (lastAttachedPaneId) {
        // Recovering from a dropped session (offline, a failed `open`, a
        // lost relay socket): silently re-attach the pane we had open, if
        // the host still has it.
        if (paneExists(msg.tree, lastAttachedPaneId)) {
          void sendMessage({ t: "attach", paneId: lastAttachedPaneId });
        } else {
          lastAttachedPaneId = undefined;
        }
      }
      return;
    case "tree-changed":
      void sendMessage({ t: "list" });
      return;
    case "screen":
      openTerminal(msg.cols, msg.rows, msg.b);
      return;
    case "output":
      term?.write(msg.b);
      return;
    case "resized":
      term?.resize(msg.cols, msg.rows);
      return;
    case "refused":
      showToast(msg.reason);
      return;
    default:
      return; // list/attach/detach/input/resize/newTab/unlock are outbound only.
  }
}

// -- Terminal: xterm.js, sized to the host's `screen`, resized on request. --

function openTerminal(cols: number, rows: number, screen: Uint8Array): void {
  showView("terminal");
  const container = document.getElementById("terminal-container");
  if (!container) return;
  container.innerHTML = "";
  term = new Terminal({ cols, rows });
  fitAddon = new FitAddon();
  term.loadAddon(fitAddon);
  term.open(container);
  term.write(screen);
  term.onData((data) => {
    void sendMessage({ t: "input", b: new TextEncoder().encode(data) });
  });
}

function onPaneClick(paneId: string): void {
  lastAttachedPaneId = paneId;
  void sendMessage({ t: "attach", paneId });
}

function onFitClick(): void {
  if (!fitAddon) return;
  const dims = fitAddon.proposeDimensions();
  if (!dims) return;
  void sendMessage({ t: "resize", cols: dims.cols, rows: dims.rows });
}

function onBackClick(): void {
  lastAttachedPaneId = undefined; // an explicit detach, not a dropped session: don't auto-reattach
  void sendMessage({ t: "detach" });
  leaveTerminal();
}

// -- Entry point. --

/** Drops the `#pair=` fragment so a reload doesn't re-offer the same code. */
function clearPairingHash(): void {
  history.replaceState(null, "", location.pathname + location.search);
}

/** Back to wherever this browser belongs when a pairing is abandoned. */
function showIdleView(): void {
  showView(host ? "tree" : "not-paired");
}

/**
 * The in-page confirmation (security review L3). It names the Mac the code
 * came from, and says plainly when confirming would REPLACE the Mac this
 * browser is already paired with -- the case that turns a link someone
 * sent you into a terminal tree you might type secrets into.
 */
function showConfirmPair(payload: PairingPayload): void {
  const text = document.getElementById("confirm-pair-text");
  if (text) {
    text.textContent =
      host && host.hostId !== payload.hostId
        ? `This code pairs this browser with the Mac ${payload.hostId}, replacing ${host.hostId}. ` +
          `You will no longer see ${host.hostId}'s sessions here. Only continue if you are looking at that Mac's screen.`
        : `This code pairs this browser with the Mac ${payload.hostId}. ` +
          `It will be able to show you that Mac's terminal sessions, and what you type here goes into them. ` +
          `Only continue if you are looking at that Mac's screen.`;
  }
  showView("confirm-pair");
}

/**
 * Sends the `pair` message for a confirmed payload, with the proof that
 * binds our public key to the QR code (security review C2). Called on
 * confirmation, or from `onAuthed` when the socket wasn't ready yet.
 */
async function sendPair(): Promise<void> {
  if (!pendingPairing || !relay) return;
  const secret = base64urlToBytes(pendingPairing.secret);
  if (!secret || secret.length === 0) {
    // An old or hand-made code with no secret half cannot produce a proof,
    // and the host would refuse it anyway. Say so instead of hanging on
    // "Waiting for the host to accept…".
    pendingPairing = undefined;
    showToast("This pairing code is incomplete; show a fresh one from Settings ▸ Remote");
    showIdleView();
    return;
  }
  const proof = await pairProof(secret, identity.publicKeySPKI);
  if (!pendingPairing) return; // cancelled while the HMAC was computing
  relay.pair(pendingPairing.token, deviceName(), proof);
}

function onConfirmPairClick(): void {
  if (!awaitingConfirm) return;
  pendingPairing = awaitingConfirm;
  awaitingConfirm = undefined;
  clearPairingHash();
  showView("pairing");
  if (relayAuthed) void sendPair();
}

function onCancelPairClick(): void {
  awaitingConfirm = undefined;
  pendingPairing = undefined;
  clearPairingHash();
  showIdleView();
}

async function onPaired(hostId: string, hostPublicKeyB64: string): Promise<void> {
  // Security review L4: a `paired` we did not ask for is the relay talking
  // out of turn. It used to yank an attached client back to "not paired";
  // now it is ignored unless a pairing is actually in flight.
  if (!pendingPairing) return;
  if (hostId !== pendingPairing.hostId || hostPublicKeyB64 !== pendingPairing.hostPublicKey) {
    showToast("The host's reply did not match the scanned code");
    pendingPairing = undefined;
    showIdleView();
    return;
  }
  const hostPublicKey = standardBase64ToBytes(hostPublicKeyB64);
  if (!hostPublicKey) {
    showToast("The host sent an unreadable key");
    pendingPairing = undefined;
    showView("not-paired");
    return;
  }
  host = { hostId, hostPublicKey };
  await idbPut(db, "host", host);
  pendingPairing = undefined;
  clearPairingHash();
  showView("tree");
  void startSession();
}

function showStartupError(err: unknown): void {
  for (const v of VIEWS) {
    const el = document.getElementById(`view-${v}`);
    if (el) el.hidden = true;
  }
  const el = document.getElementById("view-error");
  const text = document.getElementById("error-text");
  if (text) {
    text.textContent =
      "Couldn't start: this browser blocked or cleared local storage, so no identity could be created or loaded. " +
      "Allow site data for this page (leave private/incognito mode, or allow this site in a tracker/storage blocker) and reload.";
  }
  if (el) el.hidden = false;
  console.error("memterm remote: startup failed", err);
}

async function main(): Promise<void> {
  try {
    db = await openDb();
    identity = await loadOrCreateIdentity(db);
    host = await idbGet<StoredHost>(db, "host");
  } catch (err) {
    showStartupError(err);
    return;
  }

  // The Mac's "Allow ?" prompt shows the key id it is about to trust. Show
  // ours next to the wait, so there is something to compare it against
  // (security review C2): that check is what tells a substituted key from
  // the real one.
  const deviceIdEl = document.getElementById("pairing-device-id");
  if (deviceIdEl) deviceIdEl.textContent = identity.id;

  const parsed = decodePairingHash(location.hash);
  if (parsed && Date.now() > parsed.expiresAt) {
    showToast("This pairing code has expired");
    clearPairingHash();
  } else if (parsed) {
    // Parsed, not accepted: nothing is sent until the person confirms.
    awaitingConfirm = parsed;
  }

  if (awaitingConfirm) {
    showConfirmPair(awaitingConfirm);
  } else if (host) {
    showView("tree");
  } else {
    showView("not-paired");
    return;
  }

  relay = new RelayClient(relayWsUrl(), identity, {
    onAuthed: () => {
      relayAuthed = true;
      relayUnreachable = false;
      recomputeBanner();
      if (pendingPairing) {
        void sendPair();
      } else if (host) {
        void startSession();
      }
    },
    onPaired: (hostId, hostPublicKeyB64) => void onPaired(hostId, hostPublicKeyB64),
    onPairDenied: (reason) => {
      if (!pendingPairing) return; // not pairing: the relay is talking out of turn
      pendingPairing = undefined;
      showToast(`Pairing was declined (${reason})`);
      showIdleView();
    },
    onOnline: (hostId) => {
      if (!host || hostId !== host.hostId) return;
      hostOfflineSince = undefined;
      recomputeBanner();
      updateTreeDisabled();
      void startSession();
    },
    onOffline: (hostId, lastSeenMs) => {
      if (!host || hostId !== host.hostId) return;
      dropSession(); // the host is gone; keeps lastAttachedPaneId for recovery
      hostOfflineSince = lastSeenMs;
      recomputeBanner();
      updateTreeDisabled();
    },
    onRefused: (reason) => showToast(reason),
    onEnvelope: (from, payload) => void handleEnvelope(from, payload),
    onDisconnected: () => {
      relayAuthed = false;
      relayUnreachable = true;
      // The socket is gone, so whatever session was live over it is dead
      // too: don't leave a live terminal pointed at it (keystrokes would
      // silently no-op) -- onAuthed's re-handshake on reconnect will re-list
      // and, via startSession()'s own leaveTerminal(), the tree handler's
      // re-attach branch will pick lastAttachedPaneId back up.
      if (term) leaveTerminal();
      recomputeBanner();
    },
  });
  relay.connect();
}

document.getElementById("fit-btn")?.addEventListener("click", onFitClick);
document.getElementById("back-btn")?.addEventListener("click", onBackClick);
document.getElementById("confirm-pair-btn")?.addEventListener("click", onConfirmPairClick);
document.getElementById("cancel-pair-btn")?.addEventListener("click", onCancelPairClick);

void main();
