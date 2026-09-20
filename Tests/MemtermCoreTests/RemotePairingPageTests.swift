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

    // MARK: - Validation (security re-review N1)

    /// `web_url` decides which origin a scanned code opens, and that page
    /// is handed the pairing secret. A local process that writes a
    /// plaintext or credential-bearing origin into config.toml must not be
    /// able to redirect the next phone there.
    func testCheckRejectsOriginsThatAreNeverADeliberateChoice() {
        // Plaintext: the page, and therefore the pairing secret, is
        // readable and rewritable by anything on the path.
        for bad in ["http://evil.example/", "http://192.168.1.10/memterm/",
                    "http://ril3y.github.io/memterm/"] {
            guard case .rejected(let reason) = RemotePairingPage.check(webURL: bad) else {
                return XCTFail("accepted \(bad)")
            }
            XCTAssertTrue(reason.contains("https"), reason)
        }

        // Credentials exist here mainly to make a displayed origin read as
        // somewhere it is not.
        for bad in ["https://ril3y.github.io@evil.example/",
                    "https://user:pw@evil.example/"] {
            guard case .rejected(let reason) = RemotePairingPage.check(webURL: bad) else {
                return XCTFail("accepted \(bad)")
            }
            XCTAssertTrue(reason.contains("credentials"), reason)
        }

        // Neither a URL nor a host.
        for bad in ["not a url", "/just/a/path", "ril3y.github.io/memterm/",
                    "javascript:alert(1)", "file:///Users/me/evil.html", "data:text/html,x"] {
            guard case .rejected = RemotePairingPage.check(webURL: bad) else {
                return XCTFail("accepted \(bad)")
            }
        }
    }

    /// What must keep working: the shipped default, any https origin the
    /// user chooses, blank (the relay serves the page), and http on
    /// loopback, where there is no network to intercept.
    func testCheckAcceptsHTTPSBlankAndLoopback() {
        for good in [Config.defaultRemoteWebURL, "https://pages.example.test/client/",
                     "HTTPS://pages.example.test/", "", "   ",
                     "http://127.0.0.1:8787/", "http://localhost:8787/"] {
            XCTAssertEqual(RemotePairingPage.check(webURL: good), .accepted, "rejected \(good)")
        }
    }

    /// A rejected origin never reaches a QR code, whatever put it in the
    /// config: validation at parse decides the value, and the URL builder
    /// refuses independently.
    func testARejectedOriginMintsNoCodeAndIsDroppedAtParse() {
        XCTAssertNil(RemotePairingPage.url(relay: "wss://relay.example.test",
                                           webBase: "http://evil.example/",
                                           fragment: fragment))
        XCTAssertNil(RemotePairingPage.url(relay: "wss://relay.example.test",
                                           webBase: "https://good.example@evil.example/",
                                           fragment: fragment))

        // Config drops it in favour of the default, and says why.
        let c = Config.parse("[remote]\nweb_url = \"http://evil.example/\"\n")
        XCTAssertEqual(c.remoteWebURL, Config.defaultRemoteWebURL)
        let warning = c.remoteWebURLWarning ?? ""
        XCTAssertTrue(warning.contains("http://evil.example/"), warning)
        XCTAssertTrue(warning.contains("ignored"), warning)

        // A value that is fine passes through with nothing to report, and
        // so does the blank self-hosted case.
        let ok = Config.parse("[remote]\nweb_url = \"https://pages.example.test/\"\n")
        XCTAssertEqual(ok.remoteWebURL, "https://pages.example.test/")
        XCTAssertNil(ok.remoteWebURLWarning)
        let blank = Config.parse("[remote]\nweb_url = \"\"\n")
        XCTAssertEqual(blank.remoteWebURL, "")
        XCTAssertNil(blank.remoteWebURLWarning)
    }

    /// The Settings line states the origin a code would OPEN, not what the
    /// config file says — a blank `web_url` means the relay serves it.
    func testDisplayOriginFollowsTheCodeRatherThanTheConfigText() {
        XCTAssertEqual(
            RemotePairingPage.displayOrigin(relay: "wss://memterm-relay.fly.dev",
                                            webBase: Config.defaultRemoteWebURL),
            "https://ril3y.github.io/memterm/")
        XCTAssertEqual(
            RemotePairingPage.displayOrigin(relay: "wss://relay.example.test", webBase: ""),
            "https://relay.example.test/")
        XCTAssertNil(RemotePairingPage.displayOrigin(relay: "wss://relay.example.test",
                                                     webBase: "http://evil.example/"))
    }
}
