import Foundation

/// Remote-attach (decision doc 2026-09-19): unlocking a locked workspace
/// from a phone client goes through a passcode check on the Mac side.
/// `UnlockRateLimiter` throttles those checks per device with a sliding
/// window, so a lost or stolen phone (or a malicious relay peer) can't be
/// used to brute-force the passcode.
///
/// The window is a true sliding window, not a fixed bucket: a device may
/// make up to `limit` calls to `allow` within any trailing `window`-second
/// span, and as its oldest recorded attempt ages past `window` seconds, a
/// new slot opens up immediately (rather than waiting for a bucket
/// boundary). The boundary itself is exclusive: an attempt exactly
/// `window` seconds old has fully aged out and no longer counts against
/// the device.
public struct UnlockRateLimiter {
    private let limit: Int
    private let window: TimeInterval
    private var attempts: [String: [TimeInterval]] = [:]

    /// - Parameters:
    ///   - limit: maximum allowed attempts per device within `window`.
    ///   - window: the trailing time span, in seconds, over which attempts
    ///     are counted.
    public init(limit: Int = 5, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    /// Records an unlock attempt for `deviceId` at time `t` (seconds, same
    /// clock/epoch as all other calls) and reports whether it is allowed.
    ///
    /// A refused attempt is not recorded, so it does not itself count
    /// against future attempts.
    public mutating func allow(deviceId: String, at t: TimeInterval) -> Bool {
        var history = attempts[deviceId] ?? []
        // Drop attempts that have aged out of the trailing window. The
        // boundary is exclusive: an attempt exactly `window` seconds old
        // (t - attempt == window) no longer counts.
        history.removeAll { t - $0 >= window }

        guard history.count < limit else {
            attempts[deviceId] = history
            return false
        }

        history.append(t)
        attempts[deviceId] = history
        return true
    }
}
