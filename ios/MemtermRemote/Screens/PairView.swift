import SwiftUI
import VisionKit
import MemtermRemoteApp

/// Scan a Mac's pairing QR and confirm pairing with it. The camera view and
/// the confirm/waiting/refused states are driven entirely by `flow.phase` —
/// this screen holds no pairing logic of its own, only presentation.
struct PairView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let flow = model.pairingFlow() {
                    PairFlowContent(flow: flow, dismiss: dismiss)
                } else {
                    ContentUnavailableView(
                        "Can't Sign With This Device",
                        systemImage: "exclamationmark.triangle",
                        description: Text("This device's identity key could not be unlocked. Unlock your phone and try again.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

/// Split out from `PairView` so it alone observes `flow` — `PairView` itself
/// only needs `model` to fetch the flow once.
private struct PairFlowContent: View {
    @ObservedObject var flow: PairingFlow
    let dismiss: DismissAction

    /// Defaults to "Mac", same as a freshly paired host before anyone
    /// renames it; the person is standing in front of the Mac they are
    /// naming, so there is no reason not to let them do it right here
    /// (Task 2 review finding).
    @State private var macName = "Mac"

    var body: some View {
        content
            .onChange(of: flow.phase) { _, phase in
                if case .paired = phase { dismiss() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .idle:
            ZStack(alignment: .top) {
                QRScannerView { url in flow.scanned(url) }
                    .ignoresSafeArea()
                Text("Point your camera at the pairing code memterm is showing on your Mac.")
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
            }

        case .confirming(let payload):
            ConfirmPairView(
                payload: payload,
                deviceKeyId: flow.deviceKeyId,
                macName: $macName,
                onCancel: { flow.cancel() },
                onPair: { flow.confirm(name: macName) }
            )

        case .waiting:
            VStack(spacing: 20) {
                ProgressView()
                Text("Waiting for the Mac to accept…")
                    .font(.headline)
                DeviceKeyCallout(keyId: flow.deviceKeyId)
            }
            .padding()

        case .refused(let why):
            VStack(spacing: 20) {
                Image(systemName: "xmark.octagon")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text(why)
                    .multilineTextAlignment(.center)
                Button("Done") { flow.cancel() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

        case .paired:
            // `onChange` above dismisses; nothing to show in the instant
            // between `.paired` landing and the sheet closing.
            Color.clear
        }
    }
}

private struct ConfirmPairView: View {
    let payload: PairingPayload
    let deviceKeyId: String
    @Binding var macName: String
    let onCancel: () -> Void
    let onPair: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pair with the Mac \(payload.hostId)?")
                        .font(.title2).bold()
                    Text("It will show you that Mac's terminal sessions, and what you type here goes into them.")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Relay") {
                    Text(payload.relay)
                        .font(.system(.body, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Name this Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Mac", text: $macName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }

                DeviceKeyCallout(keyId: deviceKeyId)

                HStack {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Pair", action: onPair)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }
}

/// This device's key, shown next to the instruction to compare it with the
/// Mac's own Allow prompt — the person's only defense against a relay that
/// substitutes a different key, so it has to be legible, not a footnote.
/// Used in both `.confirming` and `.waiting`, since the Mac's prompt can
/// appear at either point.
private struct DeviceKeyCallout: View {
    let keyId: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This device's key")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(keyId)
                .font(.system(.title3, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            Text("The Mac will show the same key in its Allow prompt. If it shows anything else, don't allow it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Camera scanning

/// Wraps `DataScannerViewController` to recognize QR codes. Not available in
/// the Simulator or on hardware without the required Neural Engine —
/// `isSupported`/`isAvailable` guard that, falling back to a plain message
/// rather than a crash.
private struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (URL) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            return UnavailableScannerViewController()
        }
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: false
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (URL) -> Void
        init(onScan: @escaping (URL) -> Void) { self.onScan = onScan }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                guard case let .barcode(barcode) = item,
                      let text = barcode.payloadStringValue,
                      let url = URL(string: text)
                else { continue }
                onScan(url)
                return
            }
        }
    }
}

private final class UnavailableScannerViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = "Camera scanning isn't available on this device."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }
}
