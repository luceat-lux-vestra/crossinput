import Foundation
import XCTest
@testable import App
@testable import Delivery
import AndroidBridge
import Protocol
import EdgeSwitch
import InputCapture

@MainActor
final class BoundaryHandoffControllerTests: XCTestCase {
    func testCompositorModeIgnoresRelativeDistanceUntilMatchingBoundarySignal() async {
        let fixture = makeFixture()
        await enterRemote(fixture)

        for _ in 0..<10 {
            fixture.controller.capture.onPointerEvent?(PointerEvent(.move(dx: -500, dy: 0)))
        }
        fixture.sender.waitForDrain()
        fixture.machine.flushCallbacks()
        await settle()

        XCTAssertEqual(fixture.machine.state, .remoteActive,
                       "relative HID distance must not be boundary authority in compositor mode")

        fixture.controller.handleBoundarySignal(.reached(
            controlToken: fixture.watch.latestToken,
            targetID: 2,
            edge: .left
        ))
        fixture.machine.flushCallbacks()
        await settle()

        XCTAssertEqual(fixture.machine.state, .localActive)
        XCTAssertFalse(fixture.controller.capture.isSuppressed)
    }

    func testDuplicateBoundaryConfirmationIsSingleShot() async {
        let fixture = makeFixture()
        await enterRemote(fixture)
        let token = fixture.watch.latestToken

        fixture.controller.handleBoundarySignal(.reached(
            controlToken: token,
            targetID: 2,
            edge: .left
        ))
        fixture.machine.flushCallbacks()
        await settle()
        XCTAssertEqual(fixture.machine.state, .localActive)

        fixture.controller.handleBoundarySignal(.reached(
            controlToken: token,
            targetID: 2,
            edge: .left
        ))
        fixture.machine.flushCallbacks()
        await settle()

        XCTAssertEqual(fixture.machine.state, .localActive)
        XCTAssertEqual(fixture.watch.stopCount, 1)
    }

    func testStaleBoundaryTokenIsIgnored() async {
        let fixture = makeFixture()
        await enterRemote(fixture)
        let activeToken = fixture.watch.latestToken

        fixture.controller.handleBoundarySignal(.reached(
            controlToken: activeToken &+ 1,
            targetID: 2,
            edge: .left
        ))
        fixture.machine.flushCallbacks()
        await settle()

        XCTAssertEqual(fixture.machine.state, .remoteActive)
        XCTAssertTrue(fixture.controller.capture.isSuppressed)
    }

    func testMatchingWatchFailureReturnsLocal() async {
        let fixture = makeFixture()
        await enterRemote(fixture)

        fixture.controller.handleBoundarySignal(.failed(
            controlToken: fixture.watch.latestToken,
            code: .observationFailed
        ))
        fixture.machine.flushCallbacks()
        await settle()

        XCTAssertEqual(fixture.machine.state, .localActive)
        XCTAssertFalse(fixture.controller.capture.isSuppressed)
    }

    func testTargetReplacementInvalidatesActiveWatch() async {
        let fixture = makeFixture()
        await enterRemote(fixture)

        fixture.controller.updateRemoteTarget(3)
        fixture.machine.flushCallbacks()
        await settle()

        XCTAssertEqual(fixture.machine.state, .localActive)
        XCTAssertFalse(fixture.controller.capture.isSuppressed)
        XCTAssertEqual(fixture.watch.stopCount, 1)
    }

    func testMoveAwayWhilePreparationPendingNeverSuppresses() async {
        let watch = BoundaryWatchServiceFake(suspendStarts: true)
        let fixture = makeFixture(watch: watch)

        fixture.controller.capture.onScreenEdge?(.right)
        fixture.machine.flushCallbacks()
        await settle()

        XCTAssertEqual(fixture.machine.state, .edgeArmed)
        XCTAssertFalse(fixture.controller.capture.isSuppressed)
        XCTAssertTrue(watch.hasPendingStart)

        fixture.controller.capture.onListeningPointerMove?(-10, 0)
        fixture.machine.flushCallbacks()
        await settle()

        XCTAssertEqual(fixture.machine.state, .localActive)
        XCTAssertFalse(fixture.controller.capture.isSuppressed)

        watch.completePendingStart()
        await settle()
        fixture.machine.flushCallbacks()
        await settle()

        XCTAssertEqual(fixture.machine.state, .localActive,
                       "late READY after reversal must not reactivate remote control")
        XCTAssertFalse(fixture.controller.capture.isSuppressed)
        XCTAssertEqual(watch.stopCount, 1,
                       "late prepared watch must be cleaned up exactly once")
    }

    func testDisableInvalidatesWatchAndLateBoundarySignal() async {
        let fixture = makeFixture()
        await enterRemote(fixture)
        let token = fixture.watch.latestToken

        fixture.controller.disableEdgeSwitch()
        fixture.machine.flushCallbacks()
        await settle()
        XCTAssertEqual(fixture.machine.state, .disabled)

        fixture.controller.handleBoundarySignal(.reached(
            controlToken: token,
            targetID: 2,
            edge: .left
        ))
        fixture.machine.flushCallbacks()
        await settle()

        XCTAssertEqual(fixture.machine.state, .disabled)
        XCTAssertFalse(fixture.controller.capture.isSuppressed)
    }

    private struct Fixture {
        let sender: InputSender
        let controller: ControlHandoffController
        let machine: EdgeSwitchStateMachine
        let watch: BoundaryWatchServiceFake
    }

    private func makeFixture(
        watch: BoundaryWatchServiceFake = BoundaryWatchServiceFake()
    ) -> Fixture {
        let session = BoundaryHandoffSession()
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference)
        let machine = EdgeSwitchStateMachine(returnHysteresis: 60)
        let controller = ControlHandoffController(
            sender: sender,
            boundaryWatch: watch,
            switchMachine: machine
        )

        machine.activate()
        controller.updateRemoteTarget(2)
        return Fixture(sender: sender, controller: controller, machine: machine, watch: watch)
    }

    private func enterRemote(_ fixture: Fixture) async {
        fixture.controller.capture.onScreenEdge?(.right)
        fixture.machine.flushCallbacks()
        await settle()
        fixture.machine.flushCallbacks()
        await settle()

        XCTAssertEqual(fixture.machine.state, .remoteActive)
        XCTAssertTrue(fixture.controller.capture.isSuppressed)
        XCTAssertEqual(fixture.watch.startCount, 1)
    }

    private func settle() async {
        for _ in 0..<80 {
            await Task.yield()
        }
    }
}

private final class BoundaryWatchServiceFake: BoundaryWatchServicing, @unchecked Sendable {
    private struct StartRequest {
        let token: UInt64
        let targetID: UInt32
    }

    private let lock = NSLock()
    private let suspendStarts: Bool
    private var pending:
        (request: StartRequest, continuation: CheckedContinuation<PreparedBoundaryWatch, Error>)?
    private var _latestToken: UInt64 = 0
    private var _startCount = 0
    private var _stopCount = 0

    init(suspendStarts: Bool = false) {
        self.suspendStarts = suspendStarts
    }

    var latestToken: UInt64 { lock.withLock { _latestToken } }
    var startCount: Int { lock.withLock { _startCount } }
    var stopCount: Int { lock.withLock { _stopCount } }
    var hasPendingStart: Bool { lock.withLock { pending != nil } }

    func start(controlToken: UInt64,
               targetID: UInt32,
               edge: RemoteBoundaryEdge,
               timeout: TimeInterval) async throws -> PreparedBoundaryWatch {
        let request = StartRequest(token: controlToken, targetID: targetID)
        lock.withLock {
            _latestToken = controlToken
            _startCount += 1
        }

        if !suspendStarts {
            return prepared(request)
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                pending = (request, continuation)
            }
        }
    }

    func stop(_ prepared: PreparedBoundaryWatch) {
        lock.withLock {
            _stopCount += 1
        }
    }

    func completePendingStart() {
        let value = lock.withLock { () -> (
            StartRequest, CheckedContinuation<PreparedBoundaryWatch, Error>
        )? in
            guard let pending else { return nil }
            self.pending = nil
            return (pending.request, pending.continuation)
        }
        guard let value else { return }
        value.1.resume(returning: prepared(value.0))
    }

    private func prepared(_ request: StartRequest) -> PreparedBoundaryWatch {
        PreparedBoundaryWatch(
            controlToken: request.token,
            targetID: request.targetID,
            sessionGeneration: 1,
            mode: .compositor,
            layerStack: 2
        )
    }
}

private final class BoundaryHandoffSession: SessionConnection, @unchecked Sendable {
    let serial = "boundary-handoff-test"
    var isConnected = true
    var onEvent: (@Sendable (CxiFrame) -> Void)?
    var onDisconnect: (@Sendable () -> Void)?

    func connect() async throws {}

    func request(_ type: MessageType, payload: Data,
                 timeout: TimeInterval?) async throws -> CxiFrame {
        switch type {
        case .pointerMoveRel:
            return CxiFrame(
                type: .pointerResult,
                requestId: 1,
                payload: Messages.pointerResult(
                    status: .delivered,
                    deliveredDx: 0,
                    deliveredDy: 0
                )
            )
        case .pointerButton, .pointerScroll:
            return CxiFrame(
                type: .pointerResult,
                requestId: 1,
                payload: Messages.pointerResult(status: .delivered)
            )
        default:
            return CxiFrame(type: .pong, requestId: 1)
        }
    }

    func send(_ frame: CxiFrame) throws {}
    func shutdownAndWait() { isConnected = false }
}
