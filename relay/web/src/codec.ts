// Remote-attach inner protocol, web-client side (decision doc 2026-09-19).
// Mirrors `Sources/MemtermCore/Remote/RemoteMessage.swift` exactly: the "t"
// tag values and field names below are a cross-language wire contract with
// that file and with the relay, not an implementation detail -- do not
// rename without updating both in lockstep. This module never throws:
// `decodeMessage`/`parseEnvelope` return `undefined` on anything that isn't
// exactly the expected shape (unknown tag, missing/mistyped field, bad
// base64), so a malicious or buggy peer never crashes the caller.

function toBase64(bytes: Uint8Array): string {
  if (typeof Buffer !== "undefined") return Buffer.from(bytes).toString("base64");
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

const BASE64_RE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{4})?$/;

/** Decodes base64 to bytes, or `undefined` if `s` isn't valid base64. */
function fromBase64(s: string): Uint8Array | undefined {
  if (!BASE64_RE.test(s)) return undefined;
  try {
    if (typeof Buffer !== "undefined") return new Uint8Array(Buffer.from(s, "base64"));
    const binary = atob(s);
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
    return out;
  } catch {
    return undefined;
  }
}

// -- Tree shape: `{workspaces:[{id,name,color,locked,parked,windows:[...]}]}` --

export interface RemotePane {
  id: string;
  adapter: string;
  cwd?: string;
}

export interface RemoteTab {
  id: string;
  title: string;
  panes: RemotePane[];
}

export interface RemoteWindow {
  id: string;
  tabs: RemoteTab[];
}

export interface RemoteWorkspace {
  id: string;
  name: string;
  color: string;
  locked: boolean;
  parked: boolean;
  windows: RemoteWindow[];
}

export interface RemoteTree {
  workspaces: RemoteWorkspace[];
}

function isString(v: unknown): v is string {
  return typeof v === "string";
}
function isBoolean(v: unknown): v is boolean {
  return typeof v === "boolean";
}
function isNumber(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v);
}
function isArray(v: unknown): v is unknown[] {
  return Array.isArray(v);
}
function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function parsePane(v: unknown): RemotePane | undefined {
  if (!isRecord(v)) return undefined;
  if (!isString(v.id) || !isString(v.adapter)) return undefined;
  if (v.cwd !== undefined && !isString(v.cwd)) return undefined;
  return v.cwd === undefined ? { id: v.id, adapter: v.adapter } : { id: v.id, adapter: v.adapter, cwd: v.cwd };
}

function parseTab(v: unknown): RemoteTab | undefined {
  if (!isRecord(v)) return undefined;
  if (!isString(v.id) || !isString(v.title) || !isArray(v.panes)) return undefined;
  const panes: RemotePane[] = [];
  for (const p of v.panes) {
    const pane = parsePane(p);
    if (!pane) return undefined;
    panes.push(pane);
  }
  return { id: v.id, title: v.title, panes };
}

function parseWindow(v: unknown): RemoteWindow | undefined {
  if (!isRecord(v)) return undefined;
  if (!isString(v.id) || !isArray(v.tabs)) return undefined;
  const tabs: RemoteTab[] = [];
  for (const t of v.tabs) {
    const tab = parseTab(t);
    if (!tab) return undefined;
    tabs.push(tab);
  }
  return { id: v.id, tabs };
}

function parseWorkspace(v: unknown): RemoteWorkspace | undefined {
  if (!isRecord(v)) return undefined;
  if (
    !isString(v.id) ||
    !isString(v.name) ||
    !isString(v.color) ||
    !isBoolean(v.locked) ||
    !isBoolean(v.parked) ||
    !isArray(v.windows)
  )
    return undefined;
  const windows: RemoteWindow[] = [];
  for (const w of v.windows) {
    const window = parseWindow(w);
    if (!window) return undefined;
    windows.push(window);
  }
  return { id: v.id, name: v.name, color: v.color, locked: v.locked, parked: v.parked, windows };
}

function parseTree(v: unknown): RemoteTree | undefined {
  if (!isRecord(v) || !isArray(v.workspaces)) return undefined;
  const workspaces: RemoteWorkspace[] = [];
  for (const w of v.workspaces) {
    const workspace = parseWorkspace(w);
    if (!workspace) return undefined;
    workspaces.push(workspace);
  }
  return { workspaces };
}

// -- The message union: exact "t" tags and field names, byte fields under "b" as base64. --

export type RemoteMessage =
  | { t: "list" }
  | { t: "attach"; paneId: string }
  | { t: "detach" }
  | { t: "input"; b: Uint8Array }
  | { t: "resize"; cols: number; rows: number }
  | { t: "newTab"; workspaceId: string }
  | { t: "unlock"; workspaceId: string; passphrase: string }
  | { t: "tree"; tree: RemoteTree }
  | { t: "screen"; cols: number; rows: number; b: Uint8Array }
  | { t: "output"; b: Uint8Array }
  | { t: "tree-changed" }
  | { t: "refused"; reason: string }
  | { t: "resized"; cols: number; rows: number };

/** Encodes a `RemoteMessage` to its wire JSON, base64-encoding byte fields. */
export function encodeMessage(m: RemoteMessage): string {
  switch (m.t) {
    case "list":
    case "detach":
    case "tree-changed":
      return JSON.stringify({ t: m.t });
    case "attach":
      return JSON.stringify({ t: m.t, paneId: m.paneId });
    case "input":
    case "output":
      return JSON.stringify({ t: m.t, b: toBase64(m.b) });
    case "resize":
    case "resized":
      return JSON.stringify({ t: m.t, cols: m.cols, rows: m.rows });
    case "newTab":
      return JSON.stringify({ t: m.t, workspaceId: m.workspaceId });
    case "unlock":
      return JSON.stringify({ t: m.t, workspaceId: m.workspaceId, passphrase: m.passphrase });
    case "tree":
      return JSON.stringify({ t: m.t, tree: m.tree });
    case "screen":
      return JSON.stringify({ t: m.t, cols: m.cols, rows: m.rows, b: toBase64(m.b) });
    case "refused":
      return JSON.stringify({ t: m.t, reason: m.reason });
  }
}

/** Decodes a `RemoteMessage`, or `undefined` on an unknown tag, a missing/mistyped field, or bad base64. Never throws. */
export function decodeMessage(s: string): RemoteMessage | undefined {
  let value: unknown;
  try {
    value = JSON.parse(s);
  } catch {
    return undefined;
  }
  if (!isRecord(value)) return undefined;
  const t = value.t;
  switch (t) {
    case "list":
      return { t: "list" };
    case "detach":
      return { t: "detach" };
    case "tree-changed":
      return { t: "tree-changed" };
    case "attach": {
      if (!isString(value.paneId)) return undefined;
      return { t: "attach", paneId: value.paneId };
    }
    case "input":
    case "output": {
      if (!isString(value.b)) return undefined;
      const b = fromBase64(value.b);
      if (!b) return undefined;
      return { t, b };
    }
    case "resize":
    case "resized": {
      if (!isNumber(value.cols) || !isNumber(value.rows)) return undefined;
      return { t, cols: value.cols, rows: value.rows };
    }
    case "newTab": {
      if (!isString(value.workspaceId)) return undefined;
      return { t: "newTab", workspaceId: value.workspaceId };
    }
    case "unlock": {
      if (!isString(value.workspaceId) || !isString(value.passphrase)) return undefined;
      return { t: "unlock", workspaceId: value.workspaceId, passphrase: value.passphrase };
    }
    case "tree": {
      const tree = parseTree(value.tree);
      if (!tree) return undefined;
      return { t: "tree", tree };
    }
    case "screen": {
      if (!isNumber(value.cols) || !isNumber(value.rows) || !isString(value.b)) return undefined;
      const b = fromBase64(value.b);
      if (!b) return undefined;
      return { t: "screen", cols: value.cols, rows: value.rows, b };
    }
    case "refused": {
      if (!isString(value.reason)) return undefined;
      return { t: "refused", reason: value.reason };
    }
    default:
      return undefined;
  }
}

// -- Outer envelope: the relay's routing-only JSON, `{"type":"env",...}`. --

export interface Envelope {
  to: string;
  from: string;
  payload: Uint8Array;
}

/** The relay envelope string: `{"type":"env","to":...,"from":...,"payload":<b64>}`. */
export function envelope(to: string, from: string, payloadBytes: Uint8Array): string {
  return JSON.stringify({ type: "env", to, from, payload: toBase64(payloadBytes) });
}

/** Parses a relay envelope, or `undefined` on anything that isn't exactly that shape. Never throws. */
export function parseEnvelope(s: string): Envelope | undefined {
  let value: unknown;
  try {
    value = JSON.parse(s);
  } catch {
    return undefined;
  }
  if (!isRecord(value)) return undefined;
  if (value.type !== "env" || !isString(value.to) || !isString(value.from) || !isString(value.payload)) {
    return undefined;
  }
  const payload = fromBase64(value.payload);
  if (!payload) return undefined;
  return { to: value.to, from: value.from, payload };
}
