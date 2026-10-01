import Combine
import Foundation
import SwiftUI
import UIKit
import MemtermRemoteApp
import MemtermRemoteKit

@main
struct MemtermRemoteApp_: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MacsView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.sceneBecameActive()
            case .background: model.sceneWentToBackground()
            case .inactive:
                // Deliberately NOT a teardown. `.inactive` fires for every
                // transient interruption — an incoming-call banner, Control
                // Center, Notification Center, the app switcher, a system
                // alert — and stopping the session there closed the WebSocket,
                // forced a full re-auth and re-handshake on the way back, and
                // made the Mac run `endSession` and drop its viewer attach.
                // The plan's interface contract says `.background` stops; this
                // is that, exactly.
                break
            @unknown default: break
            }
        }
    }
}

/// The app's one piece of shared state: the paired-host list, this device's
/// identity, and the single live `HostSession` for whichever Mac is on
/// screen. Deliberately thin — every decision that matters (what a scan
/// means, what a handshake proves, when a session should reconnect) belongs
/// to `PairingFlow` or `HostSession`, both already covered by `swift test`.
/// This class only wires the Keychain-backed stores from Task 2 to the
/// screens from Task 3.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var hosts: [PairedHost] = []
    /// The one live session: starting a new one (`startSession(for:)`) tears
    /// down whatever was running before, the same one-at-a-time rule the
    /// Mac side already keeps for its own attach state.
    @Published private(set) var session: HostSession?

    /// One sentence to put at the top of the Macs list, for the one condition
    /// this app can detect but not fix: this device's stored identity key was
    /// unreadable and had to be replaced, which orphans every Mac that was
    /// paired with the old one.
    @Published private(set) var identityNotice: String?

    /// Concretely typed, not `PhoneIdentityStoring`: the protocol exists so the
    /// tested brain can be driven without a Keychain, while this class is the
    /// app target's own wiring and does read one thing the protocol has no
    /// business carrying (`replacedUnreadableIdentity`).
    private let identityStore = SecureEnclaveIdentity()
    private let hostStore: PairedHostStoring = KeychainHostStore()

    /// Reused across scans — `PairingFlow` is documented as good for
    /// repeated attempts, each `scanned(_:)` starting a fresh one — so the
    /// same instance backs however many times the person opens `PairView`.
    /// `nil` only if this device's identity could not be loaded at all.
    private var cachedFlow: PairingFlow?
    private var sessionForwarding: AnyCancellable?

    init() {
        #if DEBUG
        // Companion to the `PairedHost` seed below: installs the exact
        // identity key that earned it, when the Mac's allow-list is checked
        // by key, not by claim — see `SecureEnclaveIdentity.debugSeedIdentity`.
        // Done FIRST and unconditionally on the seed flag, before
        // `identity()` is ever called (including by `reloadHosts()` below),
        // so there is no window where the wrong (freshly-generated) key
        // could already be cached.
        if CommandLine.arguments.contains("-memterm-seed-host"),
           let keyB64 = ProcessInfo.processInfo.environment["MEMTERM_SEED_IDENTITY_KEY_B64"] {
            SecureEnclaveIdentity.debugSeedIdentity(rawKeyBase64: keyB64)
        }
        // The Simulator cannot scan a QR code, so this is the only way to
        // reach `TreeView`/`TerminalScreen` there against a real Mac host:
        // `-memterm-seed-host` on the launch arguments plus a `PairedHost`
        // (JSON, ISO 8601 dates) in `MEMTERM_SEED_HOST_JSON` inserts that
        // host into the Keychain store exactly as a real pairing would have.
        // `#if DEBUG` keeps this out of a release build entirely — there is
        // no runtime check here that could be tricked into firing in one.
        if CommandLine.arguments.contains("-memterm-seed-host"),
           let json = ProcessInfo.processInfo.environment["MEMTERM_SEED_HOST_JSON"],
           let data = json.data(using: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let host = try? decoder.decode(PairedHost.self, from: data) {
                hostStore.add(host)
            } else {
                NSLog("memterm: -memterm-seed-host set but MEMTERM_SEED_HOST_JSON did not decode as a PairedHost")
            }
        }
        #endif
        reloadHosts()
        // Resolved here rather than lazily at the first tap, so that if the
        // stored identity was unreadable the person is told on the screen that
        // lists the Macs it just orphaned, instead of discovering it as a
        // handshake that fails for no stated reason.
        _ = try? identityStore.identity()
        if identityStore.replacedUnreadableIdentity && !hosts.isEmpty {
            identityNotice = "This device's identity key had to be replaced, so the Macs below no longer recognise it. Pair with each one again."
        }
    }

    func reloadHosts() {
        hosts = hostStore.load()
    }

    func remove(id: String) {
        hostStore.remove(id: id)
        reloadHosts()
    }

    /// `PairView`'s flow, created the first time this device's identity can
    /// be loaded and cached after that. `nil` means the Secure Enclave key
    /// could not be read or created — `PairView` shows that rather than
    /// crashing into a force-unwrap.
    func pairingFlow() -> PairingFlow? {
        if let cachedFlow { return cachedFlow }
        guard let signer = try? identityStore.identity() else { return nil }
        let flow = PairingFlow(
            signer: signer, store: hostStore,
            makeConnection: { url, events in
                RelayConnection(base: url, role: .client, signer: signer, events: events)
            },
            // The name the Mac's "Allow ‹name›?" prompt shows. `PairingFlow`
            // cannot reach this itself (it is Foundation-only by the extension
            // firewall) and its Foundation stand-in, `ProcessInfo.hostName`, is
            // not a name anyone recognises on iOS — which matters, because that
            // prompt is one of the person's two defences at pairing time.
            // `PairingFlow` still sanitizes whatever this returns.
            deviceName: { UIDevice.current.name })
        cachedFlow = flow
        return flow
    }

    /// Starts (or restarts) the one live session for `host`. A Mac row
    /// pushes a placeholder that calls this and shows `session.phase` —
    /// `TreeView` (Task 4) replaces that placeholder without changing this
    /// method.
    func startSession(for host: PairedHost) {
        guard let signer = try? identityStore.identity() else { return }
        let newSession = HostSession(host: host, signer: signer) { url, events in
            RelayConnection(base: url, role: .client, signer: signer, events: events)
        }
        // `HostSession` is its own `ObservableObject`; forwarding its
        // `objectWillChange` into this one lets a view that only observes
        // `AppModel` still redraw on every `phase` change, without needing
        // `@ObservedObject` over an Optional (which `ObservableObject`
        // cannot conform to).
        sessionForwarding = newSession.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        session = newSession
        newSession.start()
    }

    func stopSession() {
        session?.stop()
        sessionForwarding = nil
        session = nil
    }

    func sceneBecameActive() { session?.sceneBecameActive() }
    func sceneWentToBackground() { session?.sceneWentToBackground() }
}
