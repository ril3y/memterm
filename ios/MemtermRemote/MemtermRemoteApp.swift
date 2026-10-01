import Combine
import Foundation
import SwiftUI
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
            case .background, .inactive: model.sceneWentToBackground()
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

    private let identityStore: PhoneIdentityStoring = SecureEnclaveIdentity()
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
        let flow = PairingFlow(signer: signer, store: hostStore) { url, events in
            RelayConnection(base: url, role: .client, signer: signer, events: events)
        }
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
