import Foundation

/// Fail-closed decoder for the Apple built-in trackpad CoreHID report shape.
///
/// Evidence basis:
/// - the public HID descriptor for Apple Internal Keyboard / Trackpad report 2
///   exposes: 3 button bits, 5 bits padding, X, Y, 4 constant bytes, then
///   vendor page 0xFF00 usage 0x0C;
/// - therefore the vendor payload begins 8 bytes into the complete report
///   (including the report-ID byte);
/// - upstream Linux applespi defines the multitouch payload with
///   number_of_fingers at byte 30, clicked2 at byte 31, first finger at byte 48,
///   and 30 bytes per finger;
/// - observed CoreHID report lengths 76 / 106 / 136 and vendor lengths
///   68 / 98 / 128 satisfy that layout with the final transport CRC16 stripped.
///
/// This decoder still treats the mapping as research-only. Any structural
/// disagreement is rejected rather than guessed.
public enum AppleTrackpadRawReportDecoder {
    public struct Buttons: Equatable, Sendable {
        public let primary: Bool
        public let secondary: Bool
        public let other: Bool
    }

    public struct Contact: Equatable, Sendable {
        public let origin: Int16
        public let absoluteX: Int16
        public let absoluteY: Int16
        public let relativeX: Int16
        public let relativeY: Int16
        public let toolMajor: Int16
        public let toolMinor: Int16
        public let orientation: Int16
        public let touchMajor: Int16
        public let touchMinor: Int16
        public let pressure: Int16
        public let multi: Int16
    }

    public struct Report: Equatable, Sendable {
        public let reportID: UInt8
        public let buttons: Buttons
        public let pointerX: Int8
        public let pointerY: Int8
        public let physicalClicked: Bool
        public let contactCount: Int
        public let contacts: [Contact]
        public let rawLength: Int
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case unsupportedLength(Int)
        case unexpectedReportID(UInt8)
        case unsupportedContactCount(Int)
        case embeddedContactCountMismatch(inferred: Int, embedded: Int)
        case invalidPhysicalClickValue(UInt8)
        case truncatedContact(index: Int, requiredEndOffset: Int, actualLength: Int)
    }

    static let expectedReportID: UInt8 = 2
    static let fixedTouchpadPrefixBytes = 48
    static let fingerStrideBytes = 30
    static let strippedTrailingCRCBytes = 2
    static let maximumSupportedContacts = 16

    // Complete CoreHID report offsets.
    static let reportIDOffset = 0
    static let buttonsOffset = 1
    static let pointerXOffset = 2
    static let pointerYOffset = 3
    static let contactCountOffset = 30
    static let physicalClickOffset = 31
    static let firstFingerOffset = 48

    public static func decode(_ data: Data) throws -> Report {
        let bytes = Array(data)

        let adjustedLength = bytes.count + strippedTrailingCRCBytes
        guard adjustedLength >= fixedTouchpadPrefixBytes + fingerStrideBytes else {
            throw DecodeError.unsupportedLength(bytes.count)
        }

        let fingerBytes = adjustedLength - fixedTouchpadPrefixBytes
        guard fingerBytes.isMultiple(of: fingerStrideBytes) else {
            throw DecodeError.unsupportedLength(bytes.count)
        }

        let inferredCount = fingerBytes / fingerStrideBytes
        guard (1...maximumSupportedContacts).contains(inferredCount) else {
            throw DecodeError.unsupportedContactCount(inferredCount)
        }

        let reportID = bytes[reportIDOffset]
        guard reportID == expectedReportID else {
            throw DecodeError.unexpectedReportID(reportID)
        }

        let embeddedCount = Int(bytes[contactCountOffset])
        guard embeddedCount == inferredCount else {
            throw DecodeError.embeddedContactCountMismatch(
                inferred: inferredCount,
                embedded: embeddedCount
            )
        }

        let physicalClickByte = bytes[physicalClickOffset]
        guard physicalClickByte <= 1 else {
            throw DecodeError.invalidPhysicalClickValue(physicalClickByte)
        }

        let buttonBits = bytes[buttonsOffset]
        let buttons = Buttons(
            primary: (buttonBits & 0b001) != 0,
            secondary: (buttonBits & 0b010) != 0,
            other: (buttonBits & 0b100) != 0
        )

        var contacts: [Contact] = []
        contacts.reserveCapacity(inferredCount)

        for index in 0..<inferredCount {
            let base = firstFingerOffset + (index * fingerStrideBytes)

            // The complete CoreHID report omits the final transport CRC16.
            // Every semantic field consumed here ends at byte 27 in the
            // 30-byte finger record, so the final contact still has all fields.
            let requiredEnd = base + 28
            guard requiredEnd <= bytes.count else {
                throw DecodeError.truncatedContact(
                    index: index,
                    requiredEndOffset: requiredEnd,
                    actualLength: bytes.count
                )
            }

            contacts.append(
                Contact(
                    origin: int16LE(bytes, base + 0),
                    absoluteX: int16LE(bytes, base + 2),
                    absoluteY: int16LE(bytes, base + 4),
                    relativeX: int16LE(bytes, base + 6),
                    relativeY: int16LE(bytes, base + 8),
                    toolMajor: int16LE(bytes, base + 10),
                    toolMinor: int16LE(bytes, base + 12),
                    orientation: int16LE(bytes, base + 14),
                    touchMajor: int16LE(bytes, base + 16),
                    touchMinor: int16LE(bytes, base + 18),
                    pressure: int16LE(bytes, base + 24),
                    multi: int16LE(bytes, base + 26)
                )
            )
        }

        return Report(
            reportID: reportID,
            buttons: buttons,
            pointerX: Int8(bitPattern: bytes[pointerXOffset]),
            pointerY: Int8(bitPattern: bytes[pointerYOffset]),
            physicalClicked: physicalClickByte == 1,
            contactCount: inferredCount,
            contacts: contacts,
            rawLength: bytes.count
        )
    }

    private static func int16LE(_ bytes: [UInt8], _ offset: Int) -> Int16 {
        let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        return Int16(bitPattern: raw)
    }
}
