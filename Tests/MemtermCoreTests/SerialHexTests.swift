import XCTest
@testable import MemtermCore

final class SerialHexTests: XCTestCase {

    // MARK: Dump

    func testClassicFullRow() {
        let data = Data("Hello, world!!!!".utf8)   // exactly 16 bytes
        XCTAssertEqual(
            SerialHex.dump(data),
            "00000000  48 65 6c 6c 6f 2c 20 77  6f 72 6c 64 21 21 21 21  |Hello, world!!!!|\n")
    }

    func testPartialRowPadsHexColumnAndShortensGutter() {
        let data = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F])   // "Hello"
        XCTAssertEqual(
            SerialHex.dump(data),
            "00000000  48 65 6c 6c 6f                                    |Hello|\n")
    }

    func testNonPrintablesBecomeDots() {
        let data = Data([0x00, 0x1B, 0x41, 0x7F, 0xFF])
        let out = SerialHex.dump(data)
        XCTAssertTrue(out.hasSuffix("|..A..|\n"), out)
    }

    func testOffsetsAdvancePerRow() {
        let data = Data(repeating: 0x61, count: 40)   // 2.5 rows of 'a'
        let lines = SerialHex.dump(data).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("00000000  "))
        XCTAssertTrue(lines[1].hasPrefix("00000010  "))
        XCTAssertTrue(lines[2].hasPrefix("00000020  "))
        XCTAssertTrue(lines[2].hasSuffix("|aaaaaaaa|"))
    }

    func testEmptyDumpIsEmpty() {
        XCTAssertEqual(SerialHex.dump(Data()), "")
    }

    // MARK: Incremental streaming

    func testStreamingChunksMatchOneShotDump() {
        let bytes = (0..<77).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) }
        var formatter = HexDumpFormatter()
        var streamed = ""
        var i = 0
        for chunkSize in [1, 7, 3, 16, 30, 20] {   // ragged chunks, total 77
            let chunk = Array(bytes[i..<min(i + chunkSize, bytes.count)])
            streamed += formatter.append(chunk)
            i += chunk.count
        }
        streamed += formatter.flush()
        XCTAssertEqual(streamed, SerialHex.dump(Data(bytes)))
    }

    func testAppendOnlyEmitsCompleteRows() {
        var formatter = HexDumpFormatter()
        XCTAssertEqual(formatter.append([0x41, 0x42]), "")     // partial held back
        let out = formatter.append(Array(repeating: 0x43, count: 14))
        XCTAssertEqual(out.split(separator: "\n").count, 1)     // exactly one row
        XCTAssertEqual(formatter.flush(), "")                   // nothing pending
    }

    func testConfigurableRowWidth() {
        let out = SerialHex.dump(Data([1, 2, 3, 4, 5, 6, 7, 8, 9]), bytesPerRow: 8)
        let lines = out.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasPrefix("00000008  "))
    }

    // MARK: Input parsing

    func testParseForgivingForms() {
        let expected: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        for form in ["DE AD BE EF", "de ad be ef", "deadbeef", "DEADBEEF",
                     "0xde,0xad,0xbe,0xef", "de:ad:be:ef", "dead beef",
                     "0xDEAD 0xBEEF", "de;ad;be;ef", "  de\tad\nbe ef  "] {
            XCTAssertEqual(SerialHex.parseInput(form), expected, form)
        }
    }

    func testParseEmptyIsEmptyBytes() {
        XCTAssertEqual(SerialHex.parseInput(""), [])
        XCTAssertEqual(SerialHex.parseInput("   \n"), [])
    }

    func testParseRejectsMalformed() {
        for bad in ["xyz", "deadbee", "1", "0x", "12 3", "0xg0", "de ad q", "0x123"] {
            XCTAssertNil(SerialHex.parseInput(bad), bad)
        }
    }

    func testParseDumpRoundTrip() {
        let bytes: [UInt8] = [0x00, 0x7F, 0xFF, 0x41, 0x0A]
        let hexOnly = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        XCTAssertEqual(SerialHex.parseInput(hexOnly), bytes)
    }
}
