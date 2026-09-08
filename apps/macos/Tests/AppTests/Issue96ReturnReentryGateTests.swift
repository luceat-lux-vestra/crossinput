import XCTest
import CoreGraphics
@testable import App
@testable import Delivery
@testable import InputCapture
import AndroidBridge
import Protocol
import EdgeSwitch

private final class Issue96Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var nowStorage: TimeInterval = 100

    var now: TimeInterval {
        lock.withLock { nowStorage }
    }

    func advance(_ delta: TimeInterval) {
        lock.withLock { nowStorage += delta }
    }
}

private final class Issue96LiveSession: SessionConnection, @unchecked Sendable {
    let serial = "issue-96-live"
    let isConnected = true
    var onEvent: (@Sendable (CxiFrame) -> Void)?
    var onDisconnect: (@Sendable () -> Void)?

    func connect() async throws {}

    func request(_ type: MessageType,
                 payload: Data,
                 timeout: TimeInterval?) async throws -> CxiFrame {
        guard type == .pointerMoveRel else {
            throw Issue96TestError.unexpectedRequest
        }
        return CxiFrame(
            type: .pointerResult,
            requestId: 1,
            payload: Messages.pointerResult(
                status: .delivered,
                deliveredDx: 0,
                deliveredDy: 0
            )
        )
    }

    func send(_ frame: CxiFrame) throws {}
    func shutdownAndWait() {}
}

private enum Issue96TestError: Error {
    case unexpectedRequest
}

/// Supplies the designated cursor-mutation run loop required for suppression
/// admission without installing a system event tap.
private final class Issue96CursorOwner: @unchecked Sendable {
    let executor: CursorMutationExecutor

    private let queue = DispatchQueue(label: "crossinput.issue96-return-gate-owner")
    private let ready = DispatchSemaphore(value: 0)
    private let running = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var runLoop: CFRunLoop?
    private var stopped = false

    init(executor: CursorMutationExecutor) {
        self.executor = executor
        queue.async { [weak self] in
            guard let self, let runLoop = CFRunLoopGetCurrent() else { return }
            guard executor.bind(to: runLoop) else { return }
            self.stateLock.withLock { self.runLoop = runLoop }
            self.ready.signal()
            self.running.signal()
            CFRunLoopRun()
            self.finished.signal()
        }
        XCTAssertEqual(
            ready.wait(timeout: .now() + 1),
            .success,
            "issue #96 test cursor owner must bind its run loop"
        )
    }

    func stop() {
        let shouldStop = stateLock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }
        guard running.wait(timeout: .now() + 1) == .success else { return }
        guard let runLoop = stateLock.withLock({ self.runLoop }) else { return }
        executor.unbind()
        CFRunLoopStop(runLoop)
        CFRunLoopWakeUp(runLoop)
        _ = finished.wait(timeout: .now() + 1)
    }

    deinit {
        stop()
    }
}

@MainActor
final class Issue96ReturnReentryGateTests: XCTestCase {
    private func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    private func makeController(
        clock: Issue96Clock
    ) -> (ControlHandoffController, InputSender, InputCapture, EdgeSwitchStateMachine, Issue96CursorOwner) {
        let executor = CursorMutationExecutor(mutation: { _, _ in })
        let cursorOwner = Issue96CursorOwner(executor: executor)
        let capture = InputCapture(
            pointerRestoreOverride: {},
            cursorMutationExecutor: executor
        )
        let reference = SessionReference()
        reference.set(Issue96LiveSession())
        let sender = InputSender(session: reference)
        let machine = EdgeSwitchStateMachine()
        let controller = ControlHandoffController(
            sender: sender,
            capture: capture,
            switchMachine: machine,
            monotonicNow: { clock.now }
        )
        return (controller, sender, capture, machine, cursorOwner)
    }

    private func enterRemote(
        capture: InputCapture,
        machine: EdgeSwitchStateMachine
    ) async {
        machine.activate()
        machine.flushCallbacks()
        await Task.yield()
        XCTAssertEqual(machine.state, .localActive)

        capture.onScreenEdge?(.left)
        machine.flushCallbacks()
        XCTAssertEqual(machine.state, .remoteActive)
        let becameSuppressed = await eventually { capture.isSuppressed }
        XCTAssertTrue(becameSuppressed)
    }

    func testEmergencyReturnBlocksImmediateEdgeReacquireUntilCooldownExpires() async {
        let clock = Issue96Clock()
        let (controller, _, capture, machine, cursorOwner) = makeController(clock: clock)
        defer {
            capture.stop()
            cursorOwner.stop()
        }

        await enterRemote(capture: capture, machine: machine)

        // The controller arms before forceReturn, and apply(state:) arms again
        // before capture.release() as a last-resort ordering invariant.
        controller.emergencyReturn()
        machine.flushCallbacks()
        XCTAssertEqual(machine.state, .localActive)
        let becameLocal = await eventually { !capture.isSuppressed }
        XCTAssertTrue(becameLocal)

        capture.onScreenEdge?(.left)
        XCTAssertEqual(machine.state, .localActive,
                       "an immediate return-path edge event must not create a new remote epoch")
        XCTAssertFalse(capture.isSuppressed)

        clock.advance(0.499)
        capture.onScreenEdge?(.left)
        XCTAssertEqual(machine.state, .localActive,
                       "the controller gate must remain closed for the full cooldown")

        clock.advance(0.002)
        capture.onScreenEdge?(.left)
        machine.flushCallbacks()
        XCTAssertEqual(machine.state, .remoteActive,
                       "edge acquisition must recover after the bounded guard expires")
        let reacquiredSuppression = await eventually { capture.isSuppressed }
        XCTAssertTrue(reacquiredSuppression)

        controller.emergencyReturn()
        machine.flushCallbacks()
        _ = await eventually { !capture.isSuppressed }
    }

    func testBoundaryCrossedReturnBlocksImmediateEdgeReacquire() async {
        let clock = Issue96Clock()
        let (controller, sender, capture, machine, cursorOwner) = makeController(clock: clock)
        defer {
            capture.stop()
            cursorOwner.stop()
        }

        await enterRemote(capture: capture, machine: machine)

        // A fresh capture starts at suppression generation 1. Exercise the
        // generation-tagged production callback: the first return-directed
        // movement is normalized by issue #37, the second crosses the default
        // 60-point return hysteresis. The helper reports the movement delivered
        // but clamped at its bound; requested intent still owns return credit.
        capture.onPointerEventWithGeneration?(PointerEvent(.move(dx: 1, dy: 0)), 1)
        sender.waitForDrain()
        await Task.yield()
        XCTAssertEqual(machine.state, .remoteActive)

        capture.onPointerEventWithGeneration?(PointerEvent(.move(dx: 100, dy: 0)), 1)
        sender.waitForDrain()
        let returnedToLocal = await eventually { machine.state == .localActive }
        XCTAssertTrue(returnedToLocal)
        machine.flushCallbacks()
        let releasedSuppression = await eventually { !capture.isSuppressed }
        XCTAssertTrue(releasedSuppression)

        capture.onScreenEdge?(.left)
        XCTAssertEqual(machine.state, .localActive,
                       "normal boundary return must not immediately reacquire the same edge")
        XCTAssertFalse(capture.isSuppressed)

        clock.advance(0.501)
        capture.onScreenEdge?(.left)
        machine.flushCallbacks()
        XCTAssertEqual(machine.state, .remoteActive)
        let reacquiredSuppression = await eventually { capture.isSuppressed }
        XCTAssertTrue(reacquiredSuppression)

        controller.emergencyReturn()
        machine.flushCallbacks()
        _ = await eventually { !capture.isSuppressed }
    }
}
