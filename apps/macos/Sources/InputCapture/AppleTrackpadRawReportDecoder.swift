import Foundation

/// Decoder for only the CoreHID fields supported by descriptor evidence and
/// target-device proof. Any structural mismatch fails closed.
enum AppleTrackpadRawReportDecoder {
    struct Buttons: Equatable, Sendable {
        let primary: Bool
        let secondary: Bool
        let other: Bool
    }

    struct Report: Equatable, Sendable {
        let reportID: UInt8
        let buttons: Buttons
        let pointerX: Int8
        let pointerY: Int8
        let contactCount: Int
        let rawLength: Int
    }

    enum DecodeError: Error, Equatable, Sendable {
        case unsupportedLength(Int)
        case unexpectedReportID(UInt8)
        case unsupportedContactCount(Int)
        case embeddedContactCountMismatch(inferred: Int, embedded: Int)
    }

    private static let expectedReportID: UInt8 = 2
    private static let fixedTouchpadPrefixBytes = 48
    private static let fingerStrideBytes = 30
    private static let strippedTrailingCRCBytes = 2
    private static let maximumSupportedContacts = 16

    private static let reportIDOffset = 0
    private static let buttonsOffset = 1
    private static let pointerXOffset = 2
    private static let pointerYOffset = 3
    private static let contactCountOffset = 30

    static func decode(_ data: Data) throws -> Report {
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
        return Report(
            reportID: reportID,
            buttons: Buttons(
                primary: (buttonBits & 0b001) != 0,
                secondary: (buttonBits & 0b010) != 0,
                other: (buttonBits & 0b100) != 0
            ),
            pointerX: Int8(bitPattern: bytes[pointerXOffset]),
            pointerY: Int8(bitPattern: bytes[pointerYOffset]),
            contactCount: inferredCount,
            rawLength: bytes.count
        )
    }
}
