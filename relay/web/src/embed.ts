// Frame-busting for the pairing page (security re-review N2).
//
// The page's defence against being embedded is normally a CSP
// `frame-ancestors` directive, which browsers honour ONLY as a response
// header — never from a `<meta>` tag. GitHub Pages, which serves this page
// by default, cannot set headers at all. So on the default deployment
// there is nothing stopping an attacker from putting this page in an
// invisible iframe under `#pair=<their payload>`, overlaying a decoy, and
// harvesting the click on "Pair".
//
// That click is the whole of the L3 mitigation. Clicked through, it
// re-points the victim's browser at the attacker's Mac and relay, where
// they may type secrets into what looks like their own shell. It does not
// reach the victim's Mac.
//
// A script check is reliable enough for a single-button gate, and it is the
// only tool available on a header-less origin. The relay's own copy also
// sends `frame-ancestors 'none'` as a header, which is strictly better
// where it applies.

/** Just enough of a `Window` to decide, so this is testable without a DOM. */
export interface WindowLike {
  top: unknown;
  self: unknown;
}

/**
 * `"blocked"` when the page is running inside a frame.
 *
 * Identity comparison, not a URL check: `window.top === window.self` only
 * in a top-level document, and reading `top` is permitted cross-origin
 * (it is a WindowProxy), so this does not throw where it matters. The
 * caller still treats a throw as blocked — failing closed is right for a
 * gate whose only job is to refuse.
 */
export function embedVerdict(w: WindowLike): "ok" | "blocked" {
  return w.top === w.self ? "ok" : "blocked";
}

/** The message shown in place of the page when it is embedded. */
export const EMBED_BLOCKED_MESSAGE =
  "This page must not be embedded. Open it directly in your browser, " +
  "from the QR code shown by memterm's Settings ▸ Remote on your Mac.";
