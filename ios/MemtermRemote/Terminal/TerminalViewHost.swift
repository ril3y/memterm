import SwiftUI
import UIKit
import SwiftTerm
import MemtermRemoteApp

/// Bridges SwiftTerm's UIKit `TerminalView` into SwiftUI.
///
/// **The resize rule this type exists to keep:** only `TerminalScreen`'s Fit
/// button ever calls `session.resize`. SwiftTerm's own frame-driven layout
/// (`TerminalView.layoutSubviews` → `processSizeChange`,
/// `.build/checkouts/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift`)
/// already reflows this view's LOCAL terminal model to whatever the phone's
/// current frame affords — on rotation, a Split View resize, Slide Over, or
/// Stage Manager — and reports that through
/// `TerminalViewDelegate.sizeChanged(source:newCols:newRows:)`, which the
/// `Coordinator` below implements as a no-op. That local reflow changes only
/// how much of the Mac's pane this viewer can see; it never reaches the
/// network. The Mac's actual pane grid changes only when the person presses
/// Fit, which reads whatever this local reflow has already settled on
/// (`Handle.proposeDimensions()`) and sends exactly one explicit
/// `session.resize(cols:rows:)` — see `RemotePaneStream.resize` on the Mac
/// side for why that one call is deliberately NOT routed through
/// `TerminalView.resize(cols:rows:)` either.
struct TerminalViewHost: UIViewRepresentable {
    let session: HostSession
    let handle: Handle

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: nil, options: TerminalOptions(cols: 80, rows: 24))
        view.terminalDelegate = context.coordinator
        // A terminal must receive exactly what was typed. SwiftTerm already
        // defaults every one of these to off (iOSTerminalView.swift), but
        // they are set explicitly here so that stays true regardless of any
        // upstream change to those defaults — smart punctuation in a shell
        // is a real bug, not a cosmetic one.
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        handle.view = view
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // Nothing: output flows one way through `Coordinator`'s
        // `session.onOutput` assignment, input flows one way through
        // `Coordinator.send(source:data:)`, and size requests are pulled on
        // demand through `Handle.proposeDimensions()`. There is deliberately
        // no size-driven branch here — see this type's header comment.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, handle: handle)
    }

    /// Lets `TerminalScreen`'s Fit button read whatever columns/rows the
    /// view's own frame-driven layout has already settled on. Owned by
    /// `TerminalScreen` (not `Coordinator`, which `UIViewRepresentable` may
    /// recreate independently of the view) so Fit always has a stable
    /// reference to ask.
    final class Handle {
        fileprivate weak var view: TerminalView?

        /// `nil` only before the view exists yet (there is nothing to fit
        /// to); the Fit button simply does nothing in that case.
        func proposeDimensions() -> (cols: Int, rows: Int)? {
            guard let view else { return nil }
            let terminal = view.getTerminal()
            return (cols: terminal.cols, rows: terminal.rows)
        }
    }

    // Deliberately NOT `@MainActor` on the type itself: `HostSession` is
    // `@MainActor`-isolated, and marking this whole class `@MainActor` makes
    // its conformance to the plain (non-isolated) `TerminalViewDelegate`
    // protocol an actor-crossing conformance — a warning today, a hard error
    // under the Swift 6 language mode. Every method below that touches
    // `session` is instead called out explicitly with `MainActor.assumeIsolated`,
    // which is sound here because every one of them — UIKit's keystroke
    // delivery into `send(source:data:)`, and this `init` running inside
    // `makeCoordinator()` — is already guaranteed to run on the main thread.
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: HostSession
        private let handle: Handle

        init(session: HostSession, handle: Handle) {
            self.session = session
            self.handle = handle
            super.init()
            // `HostSession.onOutput` is the screen bytes then output chunks
            // for the attached pane — feeding them is the one and only job
            // of this closure. `[weak handle]` so a torn-down screen's view
            // is never fed into after it is gone; `feed` is documented safe
            // to call off-main, but everything else in this file is main
            // only, so this hops there too rather than relying on that.
            MainActor.assumeIsolated {
                session.onOutput = { [weak handle] data in
                    guard let view = handle?.view else { return }
                    DispatchQueue.main.async {
                        view.feed(byteArray: ArraySlice(data))
                    }
                }
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated {
                session.input(Data(data))
            }
        }

        /// SwiftTerm's own frame-driven reflow (rotation, Split View, Slide
        /// Over, Stage Manager) calls this on every local size change.
        /// Intentionally a no-op — see this file's header comment for why
        /// nothing here may call `session.resize`.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        /// OSC 8 / detected-URL taps. Only ever opens ordinary web links —
        /// this content comes from the Mac's pane, which is not a source the
        /// phone should let open arbitrary URL schemes on its behalf.
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return }
            UIApplication.shared.open(url)
        }
    }
}
