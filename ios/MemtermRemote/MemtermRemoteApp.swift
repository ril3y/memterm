import Combine
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
