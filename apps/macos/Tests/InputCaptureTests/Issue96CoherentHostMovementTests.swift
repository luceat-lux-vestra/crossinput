import CoreGraphics
import XCTest
@testable import InputCapture
@testable import EdgeSwitch

private final class Issue96HostMoveObservation: @unchecked Sendable {
    struct Mutation {
        let kind: String
        let point: CGPoint
    }

    private let lock = NSLock()
    private var pointerKindsStorage: [PointerEvent.Kind] = []
    private var mutationsStorage: [Mutation] = []

    var pointerKinds: [PointerEvent.Kind] {
        lock.withLock { pointerKindsStorage }
    }

    var mutations: [Mutation] {
        lock.withLock { mutationsStorage }
    }

    func append(pointer: PointerEvent) {
        lock.withLock { pointerKindsStorage.append(pointer.kind) }
    }

    func append(kind: CursorMutationExecutor.Kind, point: CGPoint) {
        lock.withLock {
            mutationsStorage.append(Mutation(kind: kind.rawValue, point: point))
        }
    }
}

/// Supplies the designated cursor-mutation run loop required for suppression
/// admission without installing a real system event tap.
private final class Issue96HostMoveCursorOwner: @unchecked Sendable {
    let executor: CursorMutationExecutor

    private let queue = DispatchQueue(label: "crossinput.issue96-host-move-owner")
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
            "issue #96 cursor owner must bind its run loop"
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

final class Issue96CoherentHostMovementTests: XCTestCase {
    private struct Fixture {
        let capture: InputCapture
        let owner: Issue96HostMoveCursorOwner
        let observation: Issue96HostMoveObservation
        let displayID: CGDirectDisplayID
        let frame: CGRect
    }

    private func makeFixture(edge: ScreenEdge?) -> Fixture {
        let observation = Issue96HostMoveObservation()
        let executor = CursorMutationExecutor { kind, point in
            observation.append(kind: kind, point: point)
        }
        let owner = Issue96HostMoveCursorOwner(executor: executor)
        let capture = InputCapture(
            pointerRestoreOverride: {},
            cursorMutationExecutor: executor
        )
        capture.onPointerEventWithGeneration = { event, _ in
            observation.append(pointer: event)
        }
        let displayID = CGMainDisplayID()
        let frame = CGDisplayBounds(displayID)
        capture.setAndroidEdge(edge, forDisplay: displayID)
        return Fixture(
            capture: capture,
            owner: owner,
            observation: observation,
            displayID: displayID,
            frame: frame
        )
    }

    private func mouseEvent(
        type: CGEventType,
        at point: CGPoint,
        dx: Int64,
        dy: Int64
    ) -> CGEvent {
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        )!
        event.setIntegerValueField(.mouseEventDeltaX, value: dx)
        event.setIntegerValueField(.mouseEventDeltaY, value: dy)
        return event
    }

    private func returnedEvent(_ result: Unmanaged<CGEvent>?, is event: CGEvent) -> Bool {
        result?.takeUnretainedValue() === event
    }

    private func cleanUp(_ fixture: Fixture) {
        fixture.capture.release(reason: .externalControl)
        fixture.capture.stop()
        fixture.owner.stop()
    }

    func testSuppressedMouseMoveForwardsRawDeltaAndReturnsSameZeroDeltaHoldEvent() {
        let fixture = makeFixture(edge: .right)
        defer { cleanUp(fixture) }
        XCTAssertEqual(fixture.capture.suppress(), 1)

        let rawPoint = CGPoint(x: fixture.frame.midX, y: fixture.frame.midY)
        let event = mouseEvent(type: .mouseMoved, at: rawPoint, dx: 37, dy: -12)
        let expectedHold = DisplayEdgeResolver.pointerPosition(
            for: .right,
            in: fixture.frame,
            at: rawPoint,
            threshold: 2
        )

        let result = fixture.capture.handleForTesting(type: .mouseMoved, event: event)

        XCTAssertTrue(returnedEvent(result, is: event), "the active tap must return the same incoming event")
        XCTAssertEqual(fixture.observation.pointerKinds, [.move(dx: 37, dy: -12)])
        XCTAssertEqual(fixture.observation.mutations.count, 1)
        XCTAssertEqual(fixture.observation.mutations.first?.kind, "hold")
        XCTAssertEqual(fixture.observation.mutations.first?.point, expectedHold)
        XCTAssertEqual(event.type, .mouseMoved)
        XCTAssertEqual(event.location, expectedHold)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaX), 0)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaY), 0)
        XCTAssertTrue(fixture.capture.isSuppressed)
    }

    func testSuppressedDragIsLoweredToMouseMovedWithoutLosingRemoteDelta() {
        let fixture = makeFixture(edge: .top)
        defer { cleanUp(fixture) }
        XCTAssertEqual(fixture.capture.suppress(), 1)

        let rawPoint = CGPoint(x: fixture.frame.midX, y: fixture.frame.midY)
        let event = mouseEvent(type: .leftMouseDragged, at: rawPoint, dx: -8, dy: 19)
        let expectedHold = DisplayEdgeResolver.pointerPosition(
            for: .top,
            in: fixture.frame,
            at: rawPoint,
            threshold: 2
        )

        let result = fixture.capture.handleForTesting(type: .leftMouseDragged, event: event)

        XCTAssertTrue(returnedEvent(result, is: event))
        XCTAssertEqual(fixture.observation.pointerKinds, [.move(dx: -8, dy: 19)])
        XCTAssertEqual(event.type, .mouseMoved,
                       "remote drag movement must never preserve local drag semantics")
        XCTAssertEqual(event.location, expectedHold)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaX), 0)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaY), 0)
    }

    func testMissingConfiguredEdgeFailsClosedAndDoesNotReturnRawMovement() {
        let fixture = makeFixture(edge: nil)
        defer { cleanUp(fixture) }
        XCTAssertEqual(fixture.capture.suppress(), 1)

        let event = mouseEvent(
            type: .mouseMoved,
            at: CGPoint(x: fixture.frame.midX, y: fixture.frame.midY),
            dx: 5,
            dy: 6
        )

        XCTAssertNil(fixture.capture.handleForTesting(type: .mouseMoved, event: event))
        XCTAssertEqual(fixture.observation.pointerKinds, [.move(dx: 5, dy: 6)])
        XCTAssertTrue(fixture.observation.mutations.isEmpty)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaX), 5,
                       "a fail-closed event is consumed, not partially rewritten")
        XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaY), 6)
    }

    func testOutOfDisplayCoordinateFailsClosedWithoutCursorMutation() {
        let fixture = makeFixture(edge: .left)
        defer { cleanUp(fixture) }
        XCTAssertEqual(fixture.capture.suppress(), 1)

        let event = mouseEvent(
            type: .mouseMoved,
            at: CGPoint(x: 1_000_000_000, y: 1_000_000_000),
            dx: 11,
            dy: -3
        )

        XCTAssertNil(fixture.capture.handleForTesting(type: .mouseMoved, event: event))
        XCTAssertEqual(fixture.observation.pointerKinds, [.move(dx: 11, dy: -3)])
        XCTAssertTrue(fixture.observation.mutations.isEmpty)
    }

    func testUnavailableCursorOwnerFailsClosedAfterSuppressionAdmission() {
        let fixture = makeFixture(edge: .bottom)
        defer {
            fixture.capture.release(reason: .externalControl)
            fixture.capture.stop()
            fixture.owner.stop()
        }
        XCTAssertEqual(fixture.capture.suppress(), 1)
        fixture.owner.stop()

        let event = mouseEvent(
            type: .mouseMoved,
            at: CGPoint(x: fixture.frame.midX, y: fixture.frame.midY),
            dx: 9,
            dy: 4
        )

        XCTAssertNil(fixture.capture.handleForTesting(type: .mouseMoved, event: event))
        XCTAssertEqual(fixture.observation.pointerKinds, [.move(dx: 9, dy: 4)])
        XCTAssertTrue(fixture.observation.mutations.isEmpty)
        XCTAssertTrue(fixture.capture.isSuppressed,
                       "host-stream rewrite failure must not invent a control-state transition")
    }

    func testUnsuppressedLocalMovementPassesSameEventUnchanged() {
        let fixture = makeFixture(edge: .right)
        defer {
            fixture.capture.stop()
            fixture.owner.stop()
        }
        let rawPoint = CGPoint(x: fixture.frame.midX, y: fixture.frame.midY)
        let event = mouseEvent(type: .mouseMoved, at: rawPoint, dx: 7, dy: -2)

        let result = fixture.capture.handleForTesting(type: .mouseMoved, event: event)

        XCTAssertTrue(returnedEvent(result, is: event))
        XCTAssertEqual(event.type, .mouseMoved)
        XCTAssertEqual(event.location, rawPoint)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaX), 7)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaY), -2)
        XCTAssertTrue(fixture.observation.pointerKinds.isEmpty)
        XCTAssertTrue(fixture.observation.mutations.isEmpty)
    }

    func testSuppressedNonMovementInputsRemainConsumed() {
        let fixture = makeFixture(edge: .right)
        defer { cleanUp(fixture) }
        XCTAssertEqual(fixture.capture.suppress(), 1)
        let point = CGPoint(x: fixture.frame.midX, y: fixture.frame.midY)

        let button = mouseEvent(type: .leftMouseDown, at: point, dx: 0, dy: 0)
        XCTAssertNil(fixture.capture.handleForTesting(type: .leftMouseDown, event: button))

        let scroll = CGEvent(scrollWheelEvent2Source: nil,
                             units: .pixel,
                             wheelCount: 2,
                             wheel1: 3,
                             wheel2: -4,
                             wheel3: 0)!
        XCTAssertNil(fixture.capture.handleForTesting(type: .scrollWheel, event: scroll))

        let key = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        XCTAssertNil(fixture.capture.handleForTesting(type: .keyDown, event: key))
    }
}
