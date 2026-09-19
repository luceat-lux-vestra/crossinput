import Foundation

/// Fail-closed verifier for the exact built-in trackpad HID report layout that
/// the raw decoder understands.
///
/// The decoder uses fixed byte offsets only after this verifier succeeds.
/// Supporting another descriptor requires an explicit new layout implementation
/// and its own evidence; it must not silently reuse these offsets.
public enum AppleTrackpadReportDescriptorVerifier {
    public enum VerificationError: Error, Equatable, Sendable {
        case unsupportedDescriptor
    }

    /// Descriptor observed on the target Apple Internal Keyboard / Trackpad and
    /// independently visible on Apple Silicon IORegistry dumps:
    ///
    /// Report ID 2
    ///   - Button page usages 1...3, 3 x 1 bit
    ///   - 5 bits constant padding
    ///   - Generic Desktop X/Y, 2 x 8-bit relative
    ///   - 4 x 8-bit constant padding
    ///   - Vendor page FF00 usage 0C, 1751 x 8-bit variable-size input
    ///
    /// The report-ID byte plus the 7-byte standard prefix places the vendor
    /// payload at full-report byte 8.
    static let supportedDescriptor = Data([
        0x05, 0x01,
        0x09, 0x02,
        0xA1, 0x01,
        0x09, 0x01,
        0xA1, 0x00,
        0x05, 0x09,
        0x19, 0x01,
        0x29, 0x03,
        0x15, 0x00,
        0x25, 0x01,
        0x85, 0x02,
        0x95, 0x03,
        0x75, 0x01,
        0x81, 0x02,
        0x95, 0x01,
        0x75, 0x05,
        0x81, 0x01,
        0x05, 0x01,
        0x09, 0x30,
        0x09, 0x31,
        0x15, 0x81,
        0x25, 0x7F,
        0x75, 0x08,
        0x95, 0x02,
        0x81, 0x06,
        0x95, 0x04,
        0x75, 0x08,
        0x81, 0x01,
        0x06, 0x00, 0xFF,
        0x09, 0x25,
        0xA1, 0x01,
        0x06, 0x00, 0xFF,
        0x09, 0x0C,
        0x75, 0x08,
        0x96, 0xD7, 0x06,
        0x81, 0x22,
        0xC0,
        0xC0,
        0xC0
    ])

    public static func verify(_ descriptor: Data) throws {
        guard descriptor == supportedDescriptor else {
            throw VerificationError.unsupportedDescriptor
        }
    }
}
