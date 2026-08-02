import Foundation
import Testing

@testable import Protocol

struct ProtocolTests {
    @Test func magicIsCXI() {
        #expect(Protocol.magic == [0x43, 0x58, 0x49])
        #expect(String(bytes: Protocol.magic, encoding: .utf8) == "CXI")
    }

    @Test func versionIsV1() {
        #expect(Protocol.version == 1)
    }
}
