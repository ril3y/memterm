import XCTest
@testable import MemtermCore

/// The pairing QR's URL builder — `RemoteHost.pairingURL(for:webBase:)`'s
/// pure half. It decides which origin a scanned code opens, and therefore
/// who gets to ship JavaScript into a paired browser (security review C1),
/// so every shape `[remote] web_url` can take is pinned here.
final class RemotePairingPageTests: XCTestCase {

    private let fragment = "pair=eyJhIjoxfQ"

    /// The shipped default: a GitHub Pages PROJECT site, so the page lives
    /// under a path. The fragment has to land after that path — at the
    /// origin root it would open a 404 with the payload attached to it.
    func testDefaultPagesOriginKeepsItsPath() {
        let url = RemotePairingPage.url(relay: "wss://memterm-relay.fly.dev",
                                        webBase: Config.defaultRemoteWebURL,
                                        fragment: fragment)
        XCTAssertEqual(url?.absoluteString,
                       "https://ril3y.github.io/memterm/#" + fragment)
    }

    /// A custom origin with and without a trailing slash mints the same
    /// code: one trailing slash, always, so the phone never eats a redirect
    /// on its way to the page.
    func testCustomOriginNormalizesTheTrailingSlash() {
        for base in ["https://pages.example.test/client",
                     "https://pages.example.test/client/",
                     "https://pages.example.test/client//"] {
            XCTAssertEqual(
                RemotePairingPage.url(relay: "wss://relay.example.test",
                                      webBase: base,
                                      fragment: fragment)?.absoluteString,
                "https://pages.example.test/client/#" + fragment,
                "web_url \(base)")
        }
        // A bare origin gets the same treatment: exactly one slash.
        for base in ["https://pages.example.test", "https://pages.example.test/"] {
            XCTAssertEqual(
                RemotePairingPage.url(relay: "wss://relay.example.test",
                                      webBase: base,
                                      fragment: fragment)?.absoluteString,
                "https://pages.example.test/#" + fragment,
                "web_url \(base)")
        }
    }

    /// Blank is the self-hosted case: the relay serves the page too, so the
    /// code points at the relay's own https origin, rooted.
    func testBlankFallsBackToTheRelayOrigin() {
        XCTAssertEqual(
            RemotePairingPage.url(relay: "wss://relay.example.test",
                                  webBase: "",
                                  fragment: fragment)?.absoluteString,
            "https://relay.example.test/#" + fragment)
        // Whitespace is not a configuration choice.
        XCTAssertEqual(
            RemotePairingPage.url(relay: "wss://relay.example.test:8443/ignored",
                                  webBase: "   ",
                                  fragment: fragment)?.absoluteString,
            "https://relay.example.test:8443/#" + fragment)
        // A loopback relay is ws:, and its page is therefore http:.
        XCTAssertEqual(
            RemotePairingPage.url(relay: "ws://127.0.0.1:8787",
                                  webBase: "",
                                  fragment: fragment)?.absoluteString,
            "http://127.0.0.1:8787/#" + fragment)
    }

    /// A query or fragment already on `web_url` is dropped rather than
    /// fought with: the payload owns the fragment.
    func testQueryAndFragmentOnWebURLAreDropped() {
        XCTAssertEqual(
            RemotePairingPage.url(relay: "wss://relay.example.test",
                                  webBase: "https://pages.example.test/memterm/?x=1#stale",
                                  fragment: fragment)?.absoluteString,
            "https://pages.example.test/memterm/#" + fragment)
    }

    /// A mistyped `web_url` fails loudly. Falling back to the relay would
    /// silently undo the one thing setting it was for.
    func testUnusableWebURLYieldsNoCodeAtAll() {
        XCTAssertNil(RemotePairingPage.url(relay: "wss://relay.example.test",
                                           webBase: "not a url",
                                           fragment: fragment))
        XCTAssertNil(RemotePairingPage.url(relay: "wss://relay.example.test",
                                           webBase: "/just/a/path",
                                           fragment: fragment))
        // And an unusable relay with no web_url to rescue it.
        XCTAssertNil(RemotePairingPage.url(relay: "", webBase: "", fragment: fragment))
    }
}
