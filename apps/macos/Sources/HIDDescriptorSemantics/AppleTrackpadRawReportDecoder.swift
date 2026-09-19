import Foundation

/// Fail-closed decoder for the Apple built-in trackpad raw report shape
/// observed through CoreHID.
///
/// This layout is research-only until target-device fixtures prove every
/// invariant. The shape matches the upstream Linux Apple SPI touchpad
/// protocol structurally:
///
/// - 48-byte fixed touchpad prefix
/// - 30 bytes per reported finger
/// - the transport-level trailing 16-bit CRC is not present in the CoreHID
///   input-report data observed by the probe
///
/// Therefore an N-contact CoreHID report is expected to be:
///
///     48 + (30 * N) - 2 bytes
///
/// The decoder rejects any report that does not satisfy both the structural
/// length and the embedded contact-count/click-mirror invariants.
public enum AppleTrackpadRawReportDecoder {
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
        public let clicked: Bool
        public let contactCount: Int
        public let contacts: [Contact]
        public let rawLength: Int
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case unsupportedLength(Int)
        case unsupportedContactCount(Int)
        case embeddedContactCountMismatch(inferred: Int, embedded: Int)
        case invalidClickValue(offset: Int, value: UInt8)
        case clickMirrorMismatch(primary: UInt8, mirror: UInt8)
        case truncatedContact(index: Int, requiredEndOffset: Int, actualLength: Int)
    }

    static let fixedPrefixBytes = 48
    static let fingerStrideBytes = 30
    static let strippedTrailingCRCBytes = 2
    static let maximumSupportedContacts = 16

    static let clickedOffset = 1
    static let contactCountOffset = 30
    static let clickedMirrorOffset = 31
    static let firstFingerOffset = 48

    public static func decode(_ data: Data) throws -> Report {
        let bytes = Array(data)

        let adjustedLength = bytes.count + strippedTrailingCRCBytes
        guard adjustedLength >= fixedPrefixBytes + fingerStrideBytes else {
            throw DecodeError.unsupportedLength(bytes.count)
        }

        let fingerBytes = adjustedLength - fixedPrefixBytes
        guard fingerBytes.isMultiple(of: fingerStrideBytes) else {
            throw DecodeError.unsupportedLength(bytes.count)
        }

        let inferredCount = fingerBytes / fingerStrideBytes
        guard (1...maximumSupportedContacts).contains(inferredCount) else {
            throw DecodeError.unsupportedContactCount(inferredCount)
        }

        let embeddedCount = Int(bytes[contactCountOffset])
        guard embeddedCount == inferredCount else {
            throw DecodeError.embeddedContactCountMismatch(
                inferred: inferredCount,
                embedded: embeddedCount
            )
        }

        let clicked = bytes[clickedOffset]
        let clickedMirror = bytes[clickedMirrorOffset]
        guard clicked <= 1 else {
            throw DecodeError.invalidClickValue(offset: clickedOffset, value: clicked)
        }
        guard clickedMirror <= 1 else {
            throw DecodeError.invalidClickValue(
                offset: clickedMirrorOffset,
                value: clickedMirror
            )
        }
        guard clicked == clickedMirror else {
            throw DecodeError.clickMirrorMismatch(
                primary: clicked,
                mirror: clickedMirror
            )
        }

        var contacts: [Contact] = []
        contacts.reserveCapacity(inferredCount)

        for index in 0..<inferredCount {
            let base = firstFingerOffset + (index * fingerStrideBytes)

            // The final report omits only the trailing CRC16. Every semantic
            // field used below ends at byte 27 of the 30-byte finger record.
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
            clicked: clicked == 1,
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
