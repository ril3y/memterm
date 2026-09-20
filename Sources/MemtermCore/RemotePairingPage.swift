import Foundation

/// Where the pairing QR sends a phone — the browser page's URL, with the
/// pairing payload in its FRAGMENT.
///
/// Pure string/URL work, kept here rather than in the app target so it is
/// reachable from `swift test`: it decides what a scanned code actually
/// opens, and the security review's C1 answer (serve the page from
/// somewhere that is not the relay) rests entirely on it.
///
/// Whoever serves this page chooses the JavaScript that does the encrypting
/// for a browser device, so it can read every pane and type into the Mac.
/// The default is GitHub Pages, built by this repository's CI from this
/// repository's source — which moves that trust off the relay and onto
/// GitHub plus the commit history, where it is at least auditable. The
/// relay is then only a forwarder of bytes. `[remote] web_url` points the
/// code at any other origin: a self-hoster's own relay, or their own static
/// host.
public enum RemotePairingPage {

    /// The page URL for a pairing code.
    ///
    /// - Parameters:
    ///   - relay: the payload's `relay` (a `ws:`/`wss:` URL). Used as the
    ///     page origin only when `webBase` is blank, which is the
    ///     self-hosted "the relay serves the page too" case.
    ///   - webBase: `[remote] web_url`. Blank falls back to `relay`.
    ///   - fragment: the fragment to attach, without the leading `#`.
    /// - Returns: nil when neither input yields a URL with a host, so a
    ///   mistyped `web_url` fails loudly instead of silently falling back
    ///   to the relay and undoing the one thing setting it was for.
    public static func url(relay: String, webBase: String, fragment: String) -> URL? {
        guard var parts = components(relay: relay, webBase: webBase) else { return nil }
        parts.fragment = fragment
        return parts.url
    }

    static func components(relay: String, webBase: String) -> URLComponents? {
        let trimmed = webBase.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            guard let url = URL(string: trimmed), url.host != nil,
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return nil }
            parts.path = directoryPath(parts.path)
            parts.query = nil
            parts.fragment = nil
            return parts
        }
        guard let url = URL(string: relay),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        parts.scheme = url.scheme == "ws" ? "http" : "https"
        parts.path = "/"
        parts.query = nil
        parts.fragment = nil
        return parts
    }

    /// A page path normalized to exactly one trailing slash.
    ///
    /// `web_url` names a directory a page is served from — a Pages project
    /// site is `https://user.github.io/repo/` — and the fragment has to
    /// land after that path, not at the origin's root. Ending it in exactly
    /// one slash means `…/memterm`, `…/memterm/` and `…/memterm//` all mint
    /// the same code, and the phone never eats a redirect on its way to the
    /// page it is meant to open.
    static func directoryPath(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed + "/"
    }
}
