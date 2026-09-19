import Foundation
import Testing
@testable import InputCapture

@Suite("Apple trackpad raw report decoder")
struct AppleTrackpadRawReportDecoderTests {
    @Test("decodes one-contact HID report")
    func decodesOneContact() throws {
        let data = makeReport(
            buttons: 0b001,
            pointerX: 7,
            pointerY: -3,
            contactCount: 1
        )
        #expect(data.count == 76)

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

    @Test("decodes two- and three-contact report shapes")
    func decodesMultipleContactShapes() throws {
        let two = makeReport(contactCount: 2)
        let three = makeReport(contactCount: 3)
        #expect(two.count == 106)
        #expect(three.count == 136)
        #expect(try AppleTrackpadRawReportDecoder.decode(two).contactCount == 2)
        #expect(try AppleTrackpadRawReportDecoder.decode(three).contactCount == 3)
    }

    @Test("parses standardized HID button bits independently")
    func parsesButtonBits() throws {
        let report = try AppleTrackpadRawReportDecoder.decode(
            makeReport(buttons: 0b111, contactCount: 1)
        )
        #expect(report.buttons.primary)
        #expect(report.buttons.secondary)
        #expect(report.buttons.other)
    }

    @Test("nonconforming length fails closed")
    func rejectsUnsupportedLength() {
        #expect(throws: AppleTrackpadRawReportDecoder.DecodeError.unsupportedLength(77)) {
            try AppleTrackpadRawReportDecoder.decode(Data(repeating: 0, count: 77))
        }
    }

    @Test("unexpected report ID fails closed")
    func rejectsUnexpectedReportID() {
        var data = makeReport(contactCount: 1)
        data[0] = 3
        #expect(
            throws: AppleTrackpadRawReportDecoder.DecodeError.unexpectedReportID(3)
        ) {
            try AppleTrackpadRawReportDecoder.decode(data)
        }
    }

    @Test("embedded contact count must agree with structural length")
    func rejectsContactCountMismatch() {
        var data = makeReport(contactCount: 2)
        data[30] = 1
        #expect(
            throws: AppleTrackpadRawReportDecoder.DecodeError
                .embeddedContactCountMismatch(inferred: 2, embedded: 1)
        ) {
            try AppleTrackpadRawReportDecoder.decode(data)
        }
    }

    private func makeReport(
        buttons: UInt8 = 0,
        pointerX: Int8 = 0,
        pointerY: Int8 = 0,
        contactCount: Int
    ) -> Data {
        precondition(contactCount > 0)
        let length = 46 + (30 * contactCount)
        var bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = 2
        bytes[1] = buttons
        bytes[2] = UInt8(bitPattern: pointerX)
        bytes[3] = UInt8(bitPattern: pointerY)
        bytes[30] = UInt8(contactCount)
        return Data(bytes)
    }
}
