import AppKit
import Sparkle

// Self-update, iTerm2-style (founder ask 2026-09-09): Sparkle 2 checks the
// GitHub Releases appcast (SUFeedURL in Info.plist — scripts/make-app.sh),
// verifies each DMG's EdDSA signature against SUPublicEDKey, and swaps the
// bundle in place. Only a PACKAGED app can update: a bare `swift build`
// binary has no Info.plist feed, and automated runs (probe / smoke / bench)
// must never touch the network — both stay updater-less.
final class UpdaterHost {
    let controller: SPUStandardUpdaterController

    static var isSupported: Bool {
        guard !ProbeSupport.isUIProbe, !ProbeSupport.isSmoke else { return false }
        return Bundle.main.infoDictionary?["SUFeedURL"] != nil
    }

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }
}
