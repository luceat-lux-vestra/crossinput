import Foundation

/// CXI protocol frame header (little-endian)
/// Full definition: protocol/protocol.md.
public enum Protocol {
    public static let magic: [UInt8] = [0x43, 0x58, 0x49] // "CXI"
    public static let version: UInt16 = 1
}
