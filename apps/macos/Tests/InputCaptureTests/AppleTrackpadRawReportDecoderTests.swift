import Foundation
import Testing
@testable import InputCapture

@Suite("Apple trackpad raw report decoder")
struct AppleTrackpadRawReportDecoderTests {
    @Test("decodes common proven HID prefix")
    func decodesCommonPrefix() throws {
        let data = makeReport(
            length: 76,
            buttons: 0b001,
            pointerX: 7,
            pointerY: -3,
            contactCount: 1
        )
        let report = try AppleTrackpadRawReportDecoder.decode(data)

        #expect(report.rawLength == 76)
        #expect(report.reportID == 2)
        #expect(report.buttons.primary)
        #expect(!report.buttons.secondary)
        #expect(!report.buttons.other)
        #expect(report.pointerX == 7)
        #expect(report.pointerY == -3)
        #expect(report.contactCount == 1)
    }

    @Test("report length never classifies contact count")
    func lengthDoesNotClassifyContacts() throws {
        // Physical seized evidence showed one-finger activity in extended
        // 106-byte reports. Conversely, semantics are read from byte 30.
        let extendedOne = makeReport(length: 106, contactCount: 1)
        let shortTwo = makeReport(length: 76, contactCount: 2)
        let extendedThree = makeReport(length: 136, contactCount: 3)

        #expect(
            try AppleTrackpadRawReportDecoder.decode(extendedOne).contactCount
                == 1
        )
        #expect(
            try AppleTrackpadRawReportDecoder.decode(shortTwo).contactCount
                == 2
        )
        #expect(
            try AppleTrackpadRawReportDecoder.decode(extendedThree).contactCount
                == 3
        )
    }

    @Test("parses standardized HID button bits independently")
    func parsesButtonBits() throws {
        let report = try AppleTrackpadRawReportDecoder.decode(
            makeReport(length: 76, buttons: 0b111, contactCount: 1)
        )
        #expect(report.buttons.primary)
        #expect(report.buttons.secondary)
        #expect(report.buttons.other)
    }

    @Test("shorter than the proven common prefix fails closed")
    func rejectsTruncatedPrefix() {
        #expect(
            throws: AppleTrackpadRawReportDecoder.DecodeError
                .unsupportedLength(75)
        ) {
            try AppleTrackpadRawReportDecoder.decode(
                Data(repeating: 0, count: 75)
            )
        }
    }

    @Test("unexpected report ID fails closed")
    func rejectsUnexpectedReportID() {
        var data = makeReport(length: 76, contactCount: 1)
        data[0] = 3
        #expect(
            throws: AppleTrackpadRawReportDecoder.DecodeError
                .unexpectedReportID(3)
        ) {
            try AppleTrackpadRawReportDecoder.decode(data)
        }
    }

    private func makeReport(
        length: Int,
        buttons: UInt8 = 0,
        pointerX: Int8 = 0,
        pointerY: Int8 = 0,
        contactCount: Int
    ) -> Data {
        precondition(length >= 31)
        precondition((0...255).contains(contactCount))
        var bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = 2
        bytes[1] = buttons
        bytes[2] = UInt8(bitPattern: pointerX)
        bytes[3] = UInt8(bitPattern: pointerY)
        bytes[30] = UInt8(contactCount)
        return Data(bytes)
    }
}
