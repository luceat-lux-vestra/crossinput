import Foundation

/// CXI 프로토콜 프레임 헤더 (리틀엔디언)
/// 자세한 정의는 protocol/protocol.md 참조.
public enum Protocol {
    public static let magic: [UInt8] = [0x43, 0x58, 0x49] // "CXI"
    public static let version: UInt16 = 1
}
