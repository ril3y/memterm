import XCTest
@testable import MemtermCore

final class SerialAutoBaudTests: XCTestCase {

    /// Plausible boot chatter — what a chatty device looks like at the
    /// RIGHT rate.
    private let cleanSample = [UInt8](
        "boot: ESP-IDF v5.1\r\nI (312) cpu_start: Pro cpu up.\r\n> ".utf8)

    /// Wrong-rate garbage: framing errors surface as 0x00/0xFF and
    /// high-bit noise.
    private let garbageSample: [UInt8] = [
        0x00, 0xFF, 0xF8, 0x00, 0x9C, 0xFF, 0x00, 0xE0, 0x81, 0xFF,
        0x00, 0xFE, 0xC0, 0x00, 0xFF, 0x86, 0x00, 0xFF, 0xB1, 0x00,
    ]

    // MARK: Scoring

    func testCleanAsciiScoresHigh() {
        XCTAssertGreaterThan(SerialAutoBaud.score(cleanSample), 0.9)
    }

    func testGarbageScoresLow() {
        XCTAssertLessThan(SerialAutoBaud.score(garbageSample), 0.1)
    }

    func testValidUTF8MultibyteCountsAsClean() {
        let utf8 = [UInt8]("température: 23°C — café\r\n".utf8)
        XCTAssertGreaterThan(SerialAutoBaud.score(utf8), 0.9)
    }

    func testEmptyScoresZero() {
        XCTAssertEqual(SerialAutoBaud.score([]), 0)
    }

    // MARK: Ranking

    func testCleanAtOneRateWinsClearly() {
        var samples: [(rate: Int, bytes: [UInt8])] = SerialAutoBaud.candidateRates
            .map { ($0, self.garbageSample) }
        samples[0] = (115200, cleanSample)
        guard case let .likely(rate, confidence, ranking) = SerialAutoBaud.rank(samples: samples) else {
            return XCTFail("expected .likely")
        }
        XCTAssertEqual(rate, 115200)
        XCTAssertGreaterThan(confidence, SerialAutoBaud.acceptThreshold)
        XCTAssertEqual(ranking.first?.rate, 115200)
        XCTAssertEqual(ranking.count, SerialAutoBaud.candidateRates.count)
    }

    func testSilentDeviceIsNoDataNotAGuess() {
        let samples: [(rate: Int, bytes: [UInt8])] = SerialAutoBaud.candidateRates
            .map { ($0, [UInt8]("ok".utf8)) }   // below minimumSampleBytes
        XCTAssertEqual(SerialAutoBaud.rank(samples: samples), .noData)
        XCTAssertEqual(SerialAutoBaud.rank(samples: []), .noData)
    }

    func testAmbiguousRatesAreInconclusiveNeverSilentlyChosen() {
        // Two rates decoding equally well: no winner may be declared.
        let samples: [(rate: Int, bytes: [UInt8])] = [
            (115200, cleanSample), (57600, cleanSample),
            (9600, garbageSample),
        ]
        guard case .inconclusive(let ranking) = SerialAutoBaud.rank(samples: samples) else {
            return XCTFail("expected .inconclusive when two rates tie")
        }
        XCTAssertEqual(ranking.count, 3)
    }

    func testAllGarbageIsInconclusive() {
        let samples: [(rate: Int, bytes: [UInt8])] = SerialAutoBaud.candidateRates
            .map { ($0, self.garbageSample) }
        guard case .inconclusive = SerialAutoBaud.rank(samples: samples) else {
            return XCTFail("expected .inconclusive for all-garbage")
        }
    }

    // MARK: Probe plumbing

    func testProbeVisitsRatesInOrderAndRanks() throws {
        var visited: [Int] = []
        let result = try SerialAutoBaud.probe { rate in
            visited.append(rate)
            return rate == 9600 ? self.cleanSample : self.garbageSample
        }
        XCTAssertEqual(visited, SerialAutoBaud.candidateRates)
        XCTAssertEqual(visited.first, 115200)   // dominant modern rate first
        guard case let .likely(rate, _, _) = result else {
            return XCTFail("expected .likely")
        }
        XCTAssertEqual(rate, 9600)
    }

    func testProbePropagatesSamplerErrors() {
        XCTAssertThrowsError(try SerialAutoBaud.probe { _ in
            throw SerialError.vanished
        })
    }
}
