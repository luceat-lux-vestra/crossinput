import XCTest
import InputDomain
@testable import InputCapture

final class CoreHIDPointerIPCTests: XCTestCase {
    func testSemanticEventsRoundTrip() throws {
        let events = [
            SemanticPointerEvent(.move(dx: -42, dy: 17)),
            SemanticPointerEvent(.button(button: 3, down: true)),
            SemanticPointerEvent(.button(button: 3, down: false)),
            SemanticPointerEvent(.scroll(horizontal: -1.5, vertical: 2.25)),
        ]

        var buffer = Data()
        for event in events {
            buffer.append(CoreHIDPointerIPC.encode(CoreHIDPointerIPC.frame(for: event)))
        }

        let frames = try CoreHIDPointerIPC.decodeAvailable(from: &buffer)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(frames.compactMap(CoreHIDPointerIPC.event(from:)), events)
    }

    func testDecoderRetainsIncompleteTrailingFrame() throws {
        let ready = CoreHIDPointerIPC.encode(.init(kind: .ready))
        let move = CoreHIDPointerIPC.encode(
            .init(
                kind: .move,
                a: UInt32(bitPattern: Int32(-7)),
                b: UInt32(bitPattern: Int32(9))
            )
        )

        var buffer = Data()
        buffer.append(ready)
        buffer.append(move.prefix(5))

        let first = try CoreHIDPointerIPC.decodeAvailable(from: &buffer)
        XCTAssertEqual(first, [.init(kind: .ready)])
        XCTAssertEqual(buffer, move.prefix(5))

        buffer.append(move.dropFirst(5))
        let second = try CoreHIDPointerIPC.decodeAvailable(from: &buffer)
        XCTAssertEqual(
            second,
            [
                .init(
                    kind: .move,
                    a: UInt32(bitPattern: Int32(-7)),
                    b: UInt32(bitPattern: Int32(9))
                )
            ]
        )
        XCTAssertTrue(buffer.isEmpty)
    }

    func testUnknownKindFailsClosedWithoutDiscardingBuffer() {
        var buffer = Data(repeating: 0, count: CoreHIDPointerIPC.frameSize)
        buffer[buffer.startIndex] = 0xff
        let original = buffer

        XCTAssertThrowsError(
            try CoreHIDPointerIPC.decodeAvailable(from: &buffer)
        ) { error in
            XCTAssertEqual(
                error as? CoreHIDPointerIPC.CodecError,
                .unknownKind(0xff)
            )
        }
        XCTAssertEqual(buffer, original)
    }

    func testMalformedButtonDoesNotBecomeSemanticEvent() {
        let frame = CoreHIDPointerIPC.Frame(kind: .button, a: 1, b: 2)
        XCTAssertNil(CoreHIDPointerIPC.event(from: frame))
    }
}
