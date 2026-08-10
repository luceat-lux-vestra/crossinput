import Foundation
import Testing
import Protocol

@testable import Protocol

/// Parity tests: the Swift codec must encode/decode the exact same bytes as the
/// Android helper (golden fixtures in protocol/fixtures/, verified by
/// protocol/scripts/check-fixtures.mjs).
struct ProtocolTests {
    @Test func magicIsCXI() {
        #expect(Protocol.magic == [0x43, 0x58, 0x49])
        #expect(String(bytes: Protocol.magic, encoding: .utf8) == "CXI")
    }

    @Test func versionIsV1() {
        #expect(Protocol.version == 1)
    }

    // MARK: - Request encoding parity

    @Test func helloFrameMatchesFixture() {
        let frame = CxiFrame(type: .hello, requestId: 1, payload: Messages.hello())
        let bytes = encode(frame)
        #expect(bytes == fixture("hello.bin"))
        #expect(bytes.map { String(format: "%02x", $0) }.joined() ==
                "4358490100010001000000020000000100")
    }

    @Test func listDisplaysFrameMatchesFixture() {
        let frame = CxiFrame(type: .listDisplays, requestId: 2)
        #expect(encode(frame) == fixture("list-displays.bin"))
    }

    @Test func selectDisplayFrameMatchesFixture() {
        let frame = CxiFrame(type: .selectDisplay, requestId: 3,
                             payload: Messages.selectDisplay(displayId: 2))
        #expect(encode(frame) == fixture("select-display.bin"))
    }

    @Test func createHidFrameMatchesFixture() {
        let descriptor = fixture("create-hid.bin")
        let payload = descriptor.subdata(in: Protocol.headerLength..<descriptor.count)
        let frame = CxiFrame(type: .createHidDevice, requestId: 4, payload: payload)
        #expect(encode(frame) == descriptor)
    }

    @Test func hidReportFrameMatchesFixture() {
        let bytes = fixture("hid-report.bin")
        // payload: deviceId u32 + len u32 + report bytes
        let payload = bytes.subdata(in: Protocol.headerLength..<bytes.count)
        let deviceId = payload.subdata(in: 0..<4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let report = payload.subdata(in: 8..<payload.count)
        let frame = CxiFrame(type: .hidReport, requestId: 5,
                             payload: Messages.hidReport(deviceId: deviceId, report: report))
        #expect(encode(frame) == bytes)
    }

    @Test func pointerMoveRelFrameMatchesFixture() {
        let frame = CxiFrame(type: .pointerMoveRel, requestId: 10,
                             payload: Messages.pointerMoveRel(dx: 12, dy: -8))
        #expect(encode(frame) == fixture("pointer-move-rel.bin"))
    }

    @Test func pointerButtonFrameMatchesFixture() {
        let frame = CxiFrame(type: .pointerButton, requestId: 11,
                             payload: Messages.pointerButton(button: 0, down: true))
        #expect(encode(frame) == fixture("pointer-button.bin"))
    }

    @Test func pointerScrollFrameMatchesFixture() {
        let frame = CxiFrame(type: .pointerScroll, requestId: 12,
                             payload: Messages.pointerScroll(horizontal: 0, vertical: 1))
        #expect(encode(frame) == fixture("pointer-scroll.bin"))
    }

    @Test func pingFrameMatchesFixture() {
        let frame = CxiFrame(type: .ping, requestId: 6)
        #expect(encode(frame) == fixture("ping.bin"))
    }

    @Test func keyEventDownFrameMatchesFixture() {
        let frame = CxiFrame(type: .keyEvent, requestId: 6,
                             payload: Messages.keyEvent(keyCode: 29, metaState: 0x0, action: 0, repeatCount: 0))
        let bytes = encode(frame)
        #expect(bytes == fixture("key-event-down.bin"))
        #expect(bytes.map { String(format: "%02x", $0) }.joined() ==
                "43584901000c0006000000080000001d00000000000000")
    }

    @Test func keyEventUpFrameMatchesFixture() {
        let frame = CxiFrame(type: .keyEvent, requestId: 7,
                             payload: Messages.keyEvent(keyCode: 29, metaState: 0x0, action: 1, repeatCount: 0))
        let bytes = encode(frame)
        #expect(bytes == fixture("key-event-up.bin"))
        #expect(bytes.map { String(format: "%02x", $0) }.joined() ==
                "43584901000c0007000000080000001d00000000000100")
    }

    @Test func keyEventRoundTrips() throws {
        let payload = Messages.keyEvent(keyCode: 111, metaState: 0x2000, action: 1, repeatCount: 2)
        let decoded = try Messages.decodeKeyEvent(payload)
        #expect(decoded.keyCode == 111)
        #expect(decoded.metaState == 0x2000)
        #expect(decoded.action == 1)
        #expect(decoded.repeatCount == 2)
    }

    // MARK: - Response decoding parity

    @Test func helloAckDecodesFromFixture() throws {
        let payload = payloadOf(fixture("hello-ack.bin"))
        #expect(try Messages.decodeHelloAck(payload) == 1)
    }

    @Test func displayListDecodesFromFixture() throws {
        let payload = payloadOf(fixture("display-list.bin"))
        let displays = try Messages.decodeDisplayList(payload)
        #expect(displays.count == 1)
        let desktop = displays.first
        #expect(desktop != nil)
        #expect(desktop?.displayId == 2)
        #expect(desktop?.width == 1920)
        #expect(desktop?.height == 1080)
        #expect(desktop?.name == "Desktop")
    }

    @Test func pongDecodesFromFixture() throws {
        let payload = payloadOf(fixture("pong.bin"))
        #expect(payload.isEmpty)
    }

    @Test func pointerResultDecodesAcceptedMovementFromFixture() throws {
        let payload = payloadOf(fixture("pointer-result.bin"))
        let result = try Messages.decodePointerResult(payload)
        #expect(result.status == .delivered)
        #expect(result.deliveredDx == 12)
        #expect(result.deliveredDy == -8)
    }

    // MARK: - FrameParser robustness

    @Test func parserHandlesSplitFrames() {
        let frame = encode(CxiFrame(type: .hello, requestId: 1, payload: Messages.hello()))
        let parser = FrameParser()
        var frames: [CxiFrame] = []
        for byte in frame {
            frames.append(contentsOf: parser.append(Data([byte])))
        }
        #expect(frames.count == 1)
        #expect(frames[0].type == .hello)
        #expect(frames[0].requestId == 1)
    }

    @Test func parserHandlesMultipleFramesInOneChunk() {
        let ping = encode(CxiFrame(type: .ping, requestId: 6))
        let pong = encode(CxiFrame(type: .pong, requestId: 6))
        let parser = FrameParser()
        let frames = parser.append(ping + pong)
        #expect(frames.count == 2)
        #expect(frames[0].type == .ping)
        #expect(frames[1].type == .pong)
    }

    @Test func parserRejectsGarbageAndResyncs() {
        let parser = FrameParser()
        _ = parser.append(Data([0x00, 0x01, 0x02, 0xFF])) // garbage
        let ping = encode(CxiFrame(type: .ping, requestId: 6))
        let frames = parser.append(ping)
        #expect(frames.count == 1)
    }

    // MARK: - Round trip

    @Test func displayInfoRoundTrip() throws {
        let info = DisplayInfo(displayId: 2, type: 7, flags: 0x40, state: 1,
                               width: 1920, height: 1080, densityDpi: 160, rotation: 0,
                               name: "Desktop", uniqueId: "virtual:android,1000,Desktop,0",
                               layerStack: 2)
        var data = Data()
        // Re-encode using the wire layout directly (count + display).
        data.append(contentsOf: UInt32(1).littleEndianBytes)
        data.append(encodeDisplay(info))
        let decoded = try Messages.decodeDisplayList(data)
        #expect(decoded == [info])
        #expect(decoded[0].isDesktop)
    }

    @Test func hidErrorRoundTrip() throws {
        var payload = Data()
        payload.append(contentsOf: UInt32(1).littleEndianBytes)
        payload.append(contentsOf: UInt32(3).littleEndianBytes)
        payload.append(contentsOf: UInt32(4).littleEndianBytes)
        payload.append(Data("nope".utf8))
        let decoded = try Messages.decodeHidError(payload)
        #expect(decoded.deviceId == 1)
        #expect(decoded.code == 3)
        #expect(decoded.message == "nope")
    }

    // MARK: - Fixture loading

    private func fixture(_ name: String) -> Data {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // Walk up until a directory containing protocol/fixtures is found
        // (works regardless of repo depth: Tests/ProtocolTests -> ... -> repo root).
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("protocol/fixtures")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let url = candidate.appendingPathComponent(name)
                #expect(FileManager.default.fileExists(atPath: url.path), "fixture \(name) missing")
                return (try? Data(contentsOf: url)) ?? Data()
            }
            dir.deleteLastPathComponent()
        }
        #expect(false, "protocol/fixtures not found from \(#filePath)")
        return Data()
    }

    private func payloadOf(_ bytes: Data) -> Data {
        guard bytes.count >= Protocol.headerLength else { return Data() }
        return bytes.subdata(in: Protocol.headerLength..<bytes.count)
    }

    private func encodeDisplay(_ info: DisplayInfo) -> Data {
        var data = Data()
        data.append(contentsOf: UInt32(info.displayId).littleEndianBytes)
        data.append(info.type)
        data.append(contentsOf: UInt32(info.flags).littleEndianBytes)
        data.append(info.state)
        data.append(contentsOf: UInt32(info.width).littleEndianBytes)
        data.append(contentsOf: UInt32(info.height).littleEndianBytes)
        data.append(contentsOf: UInt32(info.densityDpi).littleEndianBytes)
        data.append(info.rotation)
        data.append(contentsOf: UInt32(info.name.count).littleEndianBytes)
        data.append(contentsOf: Data(info.name.utf8))
        data.append(contentsOf: UInt32(info.uniqueId.count).littleEndianBytes)
        data.append(contentsOf: Data(info.uniqueId.utf8))
        data.append(contentsOf: UInt32(info.layerStack).littleEndianBytes)
        return data
    }
}

extension UInt32 {
    var littleEndianBytes: [UInt8] {
        var v = littleEndian
        return withUnsafeBytes(of: &v) { Array($0) }
    }
}

extension Data {
    static func + (lhs: Data, rhs: Data) -> Data {
        var result = lhs
        result.append(rhs)
        return result
    }
}
