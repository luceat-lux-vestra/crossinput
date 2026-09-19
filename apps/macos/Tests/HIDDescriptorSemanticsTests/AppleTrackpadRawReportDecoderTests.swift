import Foundation
import Testing
@testable import HIDDescriptorSemantics

@Suite("Apple trackpad raw report decoder")
struct AppleTrackpadRawReportDecoderTests {
    @Test("decodes one-contact report with HID prefix and stripped trailing CRC")
    func decodesOneContact() throws {
        let data = makeReport(
            buttons: 0b001,
            pointerX: 7,
            pointerY: -3,
            physicalClicked: false,
            contacts: [
                .init(relativeX: 17, relativeY: -9, pressure: 123, multi: 7)
            ]
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
        #expect(!report.physicalClicked)
        #expect(report.contactCount == 1)
        #expect(report.contacts.count == 1)
        #expect(report.contacts[0].relativeX == 17)
        #expect(report.contacts[0].relativeY == -9)
        #expect(report.contacts[0].pressure == 123)
        #expect(report.contacts[0].multi == 7)
    }

    @Test("decodes two-contact physical click report")
    func decodesTwoContactClicked() throws {
        let data = makeReport(
            buttons: 0b001,
            physicalClicked: true,
            contacts: [
                .init(relativeX: 4, relativeY: 2, pressure: 80, multi: 1),
                .init(relativeX: 6, relativeY: 3, pressure: 90, multi: 2)
            ]
        )

        #expect(data.count == 106)

        let report = try AppleTrackpadRawReportDecoder.decode(data)

        #expect(report.contactCount == 2)
        #expect(report.physicalClicked)
        #expect(report.contacts.map(\.relativeX) == [4, 6])
        #expect(report.contacts.map(\.relativeY) == [2, 3])
    }

    @Test("parses all three standardized HID button bits independently")
    func parsesButtonBits() throws {
        let data = makeReport(
            buttons: 0b111,
            contacts: [.init(relativeX: 0, relativeY: 0)]
        )

        let report = try AppleTrackpadRawReportDecoder.decode(data)

        #expect(report.buttons.primary)
        #expect(report.buttons.secondary)
        #expect(report.buttons.other)
    }

    @Test("three contacts produce the observed 136-byte shape")
    func threeContactLength() throws {
        let data = makeReport(
            contacts: [
                .init(relativeX: 1, relativeY: 1),
                .init(relativeX: 2, relativeY: 2),
                .init(relativeX: 3, relativeY: 3)
            ]
        )

        #expect(data.count == 136)
        #expect(try AppleTrackpadRawReportDecoder.decode(data).contactCount == 3)
    }

    @Test("nonconforming lengths fail closed")
    func rejectsUnsupportedLength() {
        #expect(throws: AppleTrackpadRawReportDecoder.DecodeError.unsupportedLength(77)) {
            try AppleTrackpadRawReportDecoder.decode(Data(repeating: 0, count: 77))
        }
    }

    @Test("unexpected report ID fails closed")
    func rejectsUnexpectedReportID() {
        var data = makeReport(
            contacts: [.init(relativeX: 0, relativeY: 0)]
        )
        data[0] = 3

        #expect(
            throws: AppleTrackpadRawReportDecoder.DecodeError.unexpectedReportID(3)
        ) {
            try AppleTrackpadRawReportDecoder.decode(data)
        }
    }

    @Test("embedded contact count must agree with structural length")
    func rejectsContactCountMismatch() {
        var data = makeReport(
            contacts: [
                .init(relativeX: 1, relativeY: 1),
                .init(relativeX: 2, relativeY: 2)
            ]
        )
        data[30] = 1

        #expect(
            throws: AppleTrackpadRawReportDecoder.DecodeError.embeddedContactCountMismatch(
                inferred: 2,
                embedded: 1
            )
        ) {
            try AppleTrackpadRawReportDecoder.decode(data)
        }
    }

    @Test("physical click byte outside zero or one fails closed")
    func rejectsInvalidPhysicalClickValue() {
        var data = makeReport(
            contacts: [.init(relativeX: 0, relativeY: 0)]
        )
        data[31] = 2

        #expect(
            throws: AppleTrackpadRawReportDecoder.DecodeError.invalidPhysicalClickValue(2)
        ) {
            try AppleTrackpadRawReportDecoder.decode(data)
        }
    }

    private struct ContactFixture {
        let relativeX: Int16
        let relativeY: Int16
        let pressure: Int16
        let multi: Int16

        init(
            relativeX: Int16,
            relativeY: Int16,
            pressure: Int16 = 0,
            multi: Int16 = 0
        ) {
            self.relativeX = relativeX
            self.relativeY = relativeY
            self.pressure = pressure
            self.multi = multi
        }
    }

    private func makeReport(
        buttons: UInt8 = 0,
        pointerX: Int8 = 0,
        pointerY: Int8 = 0,
        physicalClicked: Bool = false,
        contacts: [ContactFixture]
    ) -> Data {
        precondition(!contacts.isEmpty)

        let length = 46 + (30 * contacts.count)
        var bytes = [UInt8](repeating: 0, count: length)

        bytes[0] = 2
        bytes[1] = buttons
        bytes[2] = UInt8(bitPattern: pointerX)
        bytes[3] = UInt8(bitPattern: pointerY)
        bytes[30] = UInt8(contacts.count)
        bytes[31] = physicalClicked ? 1 : 0

        for (index, contact) in contacts.enumerated() {
            let base = 48 + (index * 30)
            putInt16LE(contact.relativeX, into: &bytes, at: base + 6)
            putInt16LE(contact.relativeY, into: &bytes, at: base + 8)
            putInt16LE(contact.pressure, into: &bytes, at: base + 24)
            putInt16LE(contact.multi, into: &bytes, at: base + 26)
        }

        return Data(bytes)
    }

    private func putInt16LE(
        _ value: Int16,
        into bytes: inout [UInt8],
        at offset: Int
    ) {
        let raw = UInt16(bitPattern: value)
        bytes[offset] = UInt8(truncatingIfNeeded: raw)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: raw >> 8)
    }
}
