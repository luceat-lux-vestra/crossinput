import Foundation

/// Decoder for only the CoreHID fields supported by the exact descriptor and
/// target-device evidence.
///
/// The proven semantic surface is entirely inside the common report prefix:
/// - report ID 2;
/// - standard HID Button1/2/3 bits;
/// - standard relative X/Y;
/// - contact count at full-report byte 30.
///
/// Report length is deliberately NOT used as a contact-count classifier.
/// Under seizure, one-finger and primary-click phases frequently produced
/// extended 106-byte reports, so 76/106/136-byte shapes do not identify
/// one/two/three contacts. Only byte 30 drives contact semantics.
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
    }

    private static let expectedReportID: UInt8 = 2
    /// 76 bytes is the shortest target-device report physically observed and
    /// contains the complete common prefix used by production semantics.
    private static let minimumProvenReportLength = 76

    private static let reportIDOffset = 0
    private static let buttonsOffset = 1
    private static let pointerXOffset = 2
    private static let pointerYOffset = 3
    private static let contactCountOffset = 30

    static func decode(_ data: Data) throws -> Report {
        let bytes = Array(data)
        guard bytes.count >= minimumProvenReportLength else {
            throw DecodeError.unsupportedLength(bytes.count)
        }

        let reportID = bytes[reportIDOffset]
        guard reportID == expectedReportID else {
            throw DecodeError.unexpectedReportID(reportID)
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
            contactCount: Int(bytes[contactCountOffset]),
            rawLength: bytes.count
        )
    }
}
