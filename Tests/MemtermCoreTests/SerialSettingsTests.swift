import XCTest
@testable import MemtermCore

final class SerialSettingsTests: XCTestCase {

    // MARK: Formatting

    func testDefaultsFormatAsResearchConsensus() {
        let s = SerialSettings()
        XCTAssertEqual(s.baud, 115200)
        XCTAssertEqual(s.compactString, "115200-8N1")
        XCTAssertEqual(s.flow, .none)
    }

    func testFlowSuffixOnlyWhenNotNone() {
        var s = SerialSettings()
        s.flow = .rtscts
        XCTAssertEqual(s.compactString, "115200-8N1-rtscts")
        s.flow = .xonxoff
        XCTAssertEqual(s.compactString, "115200-8N1-xonxoff")
        s.flow = .none
        XCTAssertEqual(s.compactString, "115200-8N1")
    }

    // MARK: Round trips

    func testRoundTripsIncludingEdgeRates() {
        let forms = [
            "115200-8N1", "9600-7E1-xonxoff", "115200-8N1-rtscts",
            "74880-8N1",          // ESP8266 boot rate — non-standard
            "31250-8N1",          // MIDI
            "300-5O2", "921600-8N1", "250000-8E2-rtscts",
        ]
        for form in forms {
            let parsed = SerialSettings.parse(form)
            XCTAssertNotNil(parsed, form)
            XCTAssertEqual(parsed?.compactString, form, form)
        }
    }

    func testParseIsForgivingAboutCaseAndExplicitNone() {
        let lower = SerialSettings.parse("9600-7e1-XONXOFF")
        XCTAssertEqual(lower?.compactString, "9600-7E1-xonxoff")

        let explicitNone = SerialSettings.parse("115200-8N1-none")
        XCTAssertEqual(explicitNone?.flow, SerialSettings.FlowControl.none)
        XCTAssertEqual(explicitNone?.compactString, "115200-8N1")

        let padded = SerialSettings.parse("  115200-8N1 ")
        XCTAssertEqual(padded?.compactString, "115200-8N1")
    }

    func testParseRejectsMalformed() {
        for bad in ["", "garbage", "115200", "115200-9N1", "115200-4N1",
                    "115200-8X1", "115200-8N3", "115200-8N0", "0-8N1",
                    "-8N1", "abc-8N1", "115200-8N1-warp",
                    "115200-8N1-rtscts-extra", "115200-N1", "115200-8NN1"] {
            XCTAssertNil(SerialSettings.parse(bad), bad)
        }
    }

    // MARK: Standard-rate helpers

    func testStandardBaudClassification() {
        XCTAssertTrue(SerialSettings(baud: 115200).isStandardBaud)
        XCTAssertTrue(SerialSettings(baud: 9600).isStandardBaud)
        XCTAssertFalse(SerialSettings(baud: 74880).isStandardBaud)
        XCTAssertFalse(SerialSettings(baud: 31250).isStandardBaud)
    }

    func testNearestStandardBaudForArbitraryRates() {
        XCTAssertEqual(SerialSettings(baud: 74880).nearestStandardBaud, 57600)
        XCTAssertEqual(SerialSettings(baud: 31250).nearestStandardBaud, 38400)
        XCTAssertEqual(SerialSettings(baud: 1000000).nearestStandardBaud, 921600)
        XCTAssertEqual(SerialSettings(baud: 115200).nearestStandardBaud, 115200)
    }

    // MARK: Codable

    func testCodableRoundTrip() throws {
        let s = SerialSettings(baud: 74880, dataBits: 7, parity: .even,
                               stopBits: 2, flow: .rtscts)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SerialSettings.self, from: data)
        XCTAssertEqual(back, s)
    }
}
