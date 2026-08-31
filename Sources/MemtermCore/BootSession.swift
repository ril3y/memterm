import Foundation

// FR-18: boot-session discrimination. The stored kern.bootsessionuuid must be
// READ AND COMPARED before the live value is stamped over it — the comparison
// is the whole point (same UX in v0.1 either way, but the v0.4 holder layer's
// adopt-vs-resurrect branch and the FR-28 abnormal-exit HUD both depend on it).

public enum LaunchKind: String {
    /// No stored boot UUID: first launch ever (or the meta table was lost).
    case firstRun = "first-run"
    /// Same boot UUID as last launch: an app-restart restore.
    case sameBoot = "same-boot"
    /// Different boot UUID: the machine rebooted since the last launch.
    case reboot
}

public enum BootSession {

    /// Zero heuristics: stored vs live kern.bootsessionuuid. A missing live
    /// value (sysctl failure) cannot discriminate and conservatively reads as
    /// an app restart.
    public static func launchKind(storedBootUUID: String?, liveBootUUID: String?) -> LaunchKind {
        guard let stored = storedBootUUID, !stored.isEmpty else { return .firstRun }
        guard let live = liveBootUUID, !live.isEmpty else { return .sameBoot }
        return stored == live ? .sameBoot : .reboot
    }
}
