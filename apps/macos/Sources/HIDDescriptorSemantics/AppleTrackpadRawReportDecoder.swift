import Foundation

/// Fail-closed decoder for the minimum Apple built-in trackpad CoreHID surface
/// that is supported by both public structure and target-device evidence.
///
/// Proven/grounded fields:
/// - report ID 2 from the HID descriptor;
/// - byte 1: standard HID button bits;
/// - bytes 2/3: standard relative X/Y;
/// - byte 30: contact count.
///
/// Why byte 30 is accepted:
/// - the report descriptor places the FF00:0C vendor payload at full-report
///   byte 8;
/// - upstream Linux applespi places number_of_fingers at touchpad byte 30;
/// - therefore it is vendor bit 176/177 for counts 1/2;
/// - the target-device repeated seized-signature run separated primary
///   (one contact) and secondary (two contacts) on those exact bits in all
///   three rounds.
///
/// The decoder intentionally does NOT depend on upstream clicked2 or per-finger
/// offsets. Those fields have not been independently proven through CoreHID.
public enum AppleTrackpadRawReportDecoder {
    public struct Buttons: Equatable, Sendable {
        public let primary: Bool
        public let secondary: Bool
        public let other: Bool
    }

    public struct Report: Equatable, Sendable {
        public let reportID: UInt8
        public let buttons: Buttons
        public let pointerX: Int8
        public let pointerY: Int8
        public let contactCount: Int
        public let rawLength: Int
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case unsupportedLength(Int)
        case unexpectedReportID(UInt8)
        case unsupportedContactCount(Int)
        case embeddedContactCountMismatch(inferred: Int, embedded: Int)
    }

    static let expectedReportID: UInt8 = 2
    static let fixedTouchpadPrefixBytes = 48
    static let fingerStrideBytes = 30
    static let strippedTrailingCRCBytes = 2
    static let maximumSupportedContacts = 16

    static let reportIDOffset = 0
    static let buttonsOffset = 1
    static let pointerXOffset = 2
    static let pointerYOffset = 3
    static let contactCountOffset = 30

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

        let buttonBits = bytes[buttonsOffset]
        let buttons = Buttons(
            primary: (buttonBits & 0b001) != 0,
            secondary: (buttonBits & 0b010) != 0,
            other: (buttonBits & 0b100) != 0
        )

        return Report(
            reportID: reportID,
            buttons: buttons,
            pointerX: Int8(bitPattern: bytes[pointerXOffset]),
            pointerY: Int8(bitPattern: bytes[pointerYOffset]),
            contactCount: inferredCount,
            rawLength: bytes.count
        )
    }
}
