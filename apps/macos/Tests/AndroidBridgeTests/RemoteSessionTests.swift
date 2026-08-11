import XCTest
@testable import AndroidBridge
import Protocol

final class RemoteSessionTests: XCTestCase {
    func testLegacyHelperWithoutPointerResultCapabilityIsRejected() {
        let legacyAck = CxiFrame(type: .helloAck, requestId: 1, payload: Data([1, 0]))

        XCTAssertThrowsError(try RemoteSession.validateHelloAck(legacyAck)) { error in
            guard case ConnectionError.incompatibleHelper = error else {
                return XCTFail("expected incompatible helper, got \(error)")
            }
        }
    }

    func testCurrentHelperCapabilitiesAreAccepted() throws {
        var payload = Data([1, 0])
        payload.append(contentsOf: [3, 0, 0, 0])
        let ack = CxiFrame(type: .helloAck, requestId: 1, payload: payload)

        XCTAssertEqual(try RemoteSession.validateHelloAck(ack), .currentPointerPath)
    }
}
