import Foundation

// Heuristic baud detection (feature/serial stage 1). HONEST by design:
// macOS termios exposes no framing-error counters to userspace (adapters
// swallow PARMRK/INPCK marks), so the only software method is to sample each
// rate and score the decoded bytes for plausibility. Wrong-baud reads
// surface as 0x00/0xFF/high-bit garbage; right-baud reads of a chatty
// device are mostly printable ASCII / valid UTF-8. The result is a RANKING
// with confidence — callers show it and let the user accept, never silently
// adopt a guess. Detection is an explicit user action, never automatic.

public enum SerialAutoBaud {

    /// Probe order: 115200 first (dominant for modern boards), then the
    /// classic ladder, plus 74880 for ESP8266 boot chatter.
    public static let candidateRates: [Int] = [
        115200, 9600, 57600, 38400, 19200, 230400, 460800, 921600, 74880,
    ]

    /// Fewer bytes than this at a rate is "no data", not a low score —
    /// silent devices are undetectable.
    public static let minimumSampleBytes = 8

    /// Score at least this high to be a credible candidate…
    public static let acceptThreshold = 0.7
    /// …and lead the runner-up by at least this much to be `.likely`.
    public static let minimumLead = 0.15

    public struct Candidate: Equatable {
        public let rate: Int
        public let confidence: Double   // 0...1
        public let sampleBytes: Int
    }

    public enum Result: Equatable {
        /// One rate clearly wins; `ranking` still carries the full list.
        case likely(rate: Int, confidence: Double, ranking: [Candidate])
        /// Data seen, but no rate cleared the threshold with a lead —
        /// the caller shows the ranking and asks.
        case inconclusive(ranking: [Candidate])
        /// Nothing (or almost nothing) received at any rate; fall back to a
        /// manual pick, defaulting 115200.
        case noData
    }

    // MARK: Scoring

    /// Normalized plausibility in 0...1. Per byte: +2 printable ASCII or a
    /// byte inside a valid UTF-8 multibyte sequence, +1 common control
    /// (\r \n \t ESC), -3 for 0x00/0xFF (classic wrong-baud artifacts),
    /// -1 anything else; divided by the printable-maximum and clamped.
    public static func score(_ bytes: [UInt8]) -> Double {
        guard !bytes.isEmpty else { return 0 }
        var raw = 0
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if let len = utf8SequenceLength(first: b), len > 1,
               i + len <= bytes.count,
               bytes[(i + 1)..<(i + len)].allSatisfy({ $0 & 0xC0 == 0x80 }) {
                raw += 2 * len
                i += len
                continue
            }
            switch b {
            case 0x20...0x7E: raw += 2
            case 0x09, 0x0A, 0x0D, 0x1B: raw += 1
            case 0x00, 0xFF: raw -= 3
            default: raw -= 1
            }
            i += 1
        }
        return max(0, min(1, Double(raw) / Double(2 * bytes.count)))
    }

    private static func utf8SequenceLength(first: UInt8) -> Int? {
        switch first {
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return nil
        }
    }

    // MARK: Ranking

    /// Pure ranking over already-collected samples — the unit-testable core.
    public static func rank(samples: [(rate: Int, bytes: [UInt8])]) -> Result {
        let scored = samples.filter { $0.bytes.count >= minimumSampleBytes }
        guard !scored.isEmpty else { return .noData }
        let ranking = scored
            .map { Candidate(rate: $0.rate, confidence: score($0.bytes),
                             sampleBytes: $0.bytes.count) }
            .sorted { $0.confidence > $1.confidence }
        let best = ranking[0]
        let runnerUp = ranking.count > 1 ? ranking[1].confidence : 0
        if best.confidence >= acceptThreshold && best.confidence - runnerUp >= minimumLead {
            return .likely(rate: best.rate, confidence: best.confidence, ranking: ranking)
        }
        return .inconclusive(ranking: ranking)
    }

    /// Full probe: for each candidate rate the `sampler` closure applies the
    /// rate and returns the bytes read in its sample window (~300–500ms on
    /// real hardware — flush input first). Injected so tests drive it with
    /// synthetic streams and no hardware is ever touched from CI.
    public static func probe(rates: [Int] = candidateRates,
                             sampler: (Int) throws -> [UInt8]) rethrows -> Result {
        var samples: [(rate: Int, bytes: [UInt8])] = []
        for rate in rates {
            samples.append((rate: rate, bytes: try sampler(rate)))
        }
        return rank(samples: samples)
    }

    /// Convenience sampler over a live connection: applies the rate,
    /// flushes stale input, and collects the window. Explicit-action only.
    public static func probe(connection: SerialConnection,
                             baseSettings: SerialSettings = SerialSettings(),
                             rates: [Int] = candidateRates,
                             window: TimeInterval = 0.4) throws -> Result {
        let collector = Collector()
        let previous = connection.onData
        defer { connection.onData = previous }
        connection.onData = { collector.append($0) }
        return try probe(rates: rates) { rate in
            var s = baseSettings
            s.baud = rate
            try connection.apply(settings: s)
            collector.reset()
            Thread.sleep(forTimeInterval: window)
            return collector.snapshot()
        }
    }

    private final class Collector {
        private let lock = NSLock()
        private var bytes: [UInt8] = []
        func append(_ d: Data) { lock.lock(); bytes.append(contentsOf: d); lock.unlock() }
        func reset() { lock.lock(); bytes.removeAll(); lock.unlock() }
        func snapshot() -> [UInt8] { lock.lock(); defer { lock.unlock() }; return bytes }
    }
}
