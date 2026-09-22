import Foundation
import XCTest
@testable import Delivery
import AndroidBridge
import Protocol

final class BoundaryWatchClientTests: XCTestCase {
    func testStartAcceptsMatchingReadyOnSameSessionGeneration() async throws {
        let session = BoundarySessionFake(response: CxiFrame(
            type: .boundaryWatchReady,
            requestId: 1,
            payload: boundaryReadyPayload(token: 42, displayId: 2, mode: 1, layerStack: 2)
        ))
        let reference = SessionReference()
        reference.set(session)
        let client = BoundaryWatchClient(session: reference)

        let prepared = try await client.start(
            controlToken: 42,
            targetID: 2,
            edge: .left
        )

        XCTAssertEqual(prepared.controlToken, 42)
        XCTAssertEqual(prepared.targetID, 2)
        XCTAssertEqual(prepared.mode, .compositor)
        XCTAssertEqual(prepared.layerStack, 2)
        XCTAssertEqual(session.requestTypes, [.boundaryWatchStart])
    }

    func testStartRejectsHelperError() async {
        let session = BoundarySessionFake(response: CxiFrame(
            type: .boundaryWatchError,
            requestId: 1,
            payload: boundaryErrorPayload(token: 7, code: 2)
        ))
        let reference = SessionReference()
        reference.set(session)
        let client = BoundaryWatchClient(session: reference)

        do {
            _ = try await client.start(controlToken: 7, targetID: 2, edge: .right)
            XCTFail("expected helper rejection")
        } catch let error as BoundaryWatchClientError {
            XCTAssertEqual(error, .helperRejected(.oracleUnavailable))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStartRejectsResponseAfterSessionReplacement() async {
        let old = BoundarySessionFake(
            response: CxiFrame(
                type: .boundaryWatchReady,
                requestId: 1,
                payload: boundaryReadyPayload(token: 9, displayId: 2, mode: 1, layerStack: 2)
            ),
            delayNanoseconds: 50_000_000
        )
        let replacement = BoundarySessionFake(response: CxiFrame(type: .pong, requestId: 1))
        let reference = SessionReference()
        reference.set(old)
        let client = BoundaryWatchClient(session: reference)

        let task = Task {
            try await client.start(controlToken: 9, targetID: 2, edge: .left)
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        reference.set(replacement)

        do {
            _ = try await task.value
            XCTFail("expected stale session rejection")
        } catch let error as BoundaryWatchClientError {
            XCTAssertEqual(error, .staleSession)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDecodeUnsolicitedSignals() {
        let reference = SessionReference()
        let client = BoundaryWatchClient(session: reference)

        let reached = client.decodeSignal(CxiFrame(
            type: .boundaryReached,
            requestId: 0,
            payload: boundaryReachedPayload(token: 11, displayId: 2, edge: 1)
        ))
        XCTAssertEqual(reached, .reached(controlToken: 11, targetID: 2, edge: .right))

        let failed = client.decodeSignal(CxiFrame(
            type: .boundaryWatchError,
            requestId: 0,
            payload: boundaryErrorPayload(token: 11, code: 3)
        ))
        XCTAssertEqual(failed, .failed(controlToken: 11, code: .backendChanged))
    }

    private func boundaryReadyPayload(token: UInt64, displayId: UInt32,
                                      mode: UInt8, layerStack: Int32) -> Data {
        var data = Data()
        var t = token.littleEndian
        var d = displayId.littleEndian
        var l = layerStack.littleEndian
        withUnsafeBytes(of: &t) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &d) { data.append(contentsOf: $0) }
        data.append(mode)
        withUnsafeBytes(of: &l) { data.append(contentsOf: $0) }
        return data
    }

    private func boundaryReachedPayload(token: UInt64, displayId: UInt32,
                                        edge: UInt8) -> Data {
        var data = Data()
        var t = token.littleEndian
        var d = displayId.littleEndian
        withUnsafeBytes(of: &t) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &d) { data.append(contentsOf: $0) }
        data.append(edge)
        return data
    }

    private func boundaryErrorPayload(token: UInt64, code: UInt8) -> Data {
        var data = Data()
        var t = token.littleEndian
        withUnsafeBytes(of: &t) { data.append(contentsOf: $0) }
        data.append(code)
        return data
    }
}

private final class BoundarySessionFake: SessionConnection, @unchecked Sendable {
    let serial = "boundary-test"
    var isConnected = true
    var onEvent: (@Sendable (CxiFrame) -> Void)?
    var onDisconnect: (@Sendable () -> Void)?

    private let response: CxiFrame
    private let delayNanoseconds: UInt64
    private let lock = NSLock()
    private var _requestTypes: [MessageType] = []

    init(response: CxiFrame, delayNanoseconds: UInt64 = 0) {
        self.response = response
        self.delayNanoseconds = delayNanoseconds
    }

    var requestTypes: [MessageType] {
        lock.withLock { _requestTypes }
    }

    func connect() async throws {}

    func request(_ type: MessageType, payload: Data,
                 timeout: TimeInterval?) async throws -> CxiFrame {
        lock.withLock {
            _requestTypes.append(type)
        }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return response
    }

    func send(_ frame: CxiFrame) throws {}
    func shutdownAndWait() { isConnected = false }
}
