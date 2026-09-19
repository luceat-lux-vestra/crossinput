import Foundation
import XCTest
@testable import App
import Delivery
import EdgeSwitch
import InputCapture

private enum FakeHostPointerError: Error {
    case acquisitionFailed
}

private final class FakeHostPointerLease: HostPointerOwnershipLease, @unchecked Sendable {
    let generation: UInt64

    private let lock = NSLock()
    private var active = true
    private var released = false
    private var releaseCountStorage = 0

    init(generation: UInt64) {
        self.generation = generation
    }

    var isActive: Bool {
        lock.withLock { active && !released }
    }

    var releaseCount: Int {
        lock.withLock { releaseCountStorage }
    }

    func fail() {
        lock.withLock { active = false }
    }

    func release() {
        lock.withLock {
            guard !released else { return }
            released = true
            active = false
            releaseCountStorage += 1
        }
    }
}

private final class FakeHostPointerBackend: HostPointerOwnershipBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<any HostPointerOwnershipLease, Error>?
    private var failureHandler: HostPointerFailureHandler?
    private var currentLease: FakeHostPointerLease?
    private var startedStorage = false

    var hasStarted: Bool {
        lock.withLock { startedStorage }
    }

    func acquire(
        onEvent: @escaping HostPointerEventHandler,
        onFailure: @escaping HostPointerFailureHandler
    ) async throws -> any HostPointerOwnershipLease {
        _ = onEvent
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<any HostPointerOwnershipLease, Error>) in
            lock.withLock {
                self.continuation = continuation
                self.failureHandler = onFailure
                self.startedStorage = true
            }
        }
    }

    func succeed(with lease: FakeHostPointerLease) {
        let continuation = lock.withLock {
            currentLease = lease
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: lease)
    }

    func failAcquisition() {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(throwing: FakeHostPointerError.acquisitionFailed)
    }

    func failBeforePublication(with lease: FakeHostPointerLease) {
        let state = lock.withLock {
            currentLease = lease
            let continuation = self.continuation
            self.continuation = nil
            return (continuation, failureHandler)
        }
        lease.fail()
        state.1?(lease.generation)
        state.0?.resume(returning: lease)
    }

    func failActiveLease() {
        let state = lock.withLock {
            (currentLease, failureHandler)
        }
        guard let lease = state.0 else { return }
        lease.fail()
        state.1?(lease.generation)
    }
}

final class HostPointerLeaseSlotTests: XCTestCase {
    func testStaleCaptureGenerationCannotReleaseNewerLease() {
        let slot = HostPointerLeaseSlot()
        let first = FakeHostPointerLease(generation: 10)
        let second = FakeHostPointerLease(generation: 11)

        XCTAssertTrue(slot.begin(captureGeneration: 1))
        XCTAssertTrue(slot.install(first, captureGeneration: 1))
        slot.release(captureGeneration: 1)
        XCTAssertEqual(first.releaseCount, 1)

        XCTAssertTrue(slot.begin(captureGeneration: 2))
        XCTAssertTrue(slot.install(second, captureGeneration: 2))
        slot.release(captureGeneration: 1)

        XCTAssertTrue(second.isActive)
        XCTAssertEqual(second.releaseCount, 0)
        XCTAssertTrue(slot.isCurrent(hostGeneration: 11))

        slot.release(captureGeneration: 2)
        XCTAssertEqual(second.releaseCount, 1)
    }

    func testStaleHostGenerationCannotReleaseNewerLease() {
        let slot = HostPointerLeaseSlot()
        let first = FakeHostPointerLease(generation: 20)
        let second = FakeHostPointerLease(generation: 21)

        XCTAssertTrue(slot.begin(captureGeneration: 3))
        XCTAssertTrue(slot.install(first, captureGeneration: 3))
        slot.release(hostGeneration: 20)
        XCTAssertTrue(slot.begin(captureGeneration: 4))
        XCTAssertTrue(slot.install(second, captureGeneration: 4))

        slot.release(hostGeneration: 20)

        XCTAssertTrue(second.isActive)
        XCTAssertEqual(second.releaseCount, 0)
        XCTAssertTrue(slot.isCurrent(hostGeneration: 21))
    }
}

final class ControlHandoffHostOwnershipTests: XCTestCase {
    @MainActor
    private func makeController(
        backend: FakeHostPointerBackend
    ) -> (
        controller: ControlHandoffController,
        capture: InputCapture,
        machine: EdgeSwitchStateMachine
    ) {
        let capture = InputCapture()
        let machine = EdgeSwitchStateMachine()
        let sender = InputSender(session: SessionReference())
        let controller = ControlHandoffController(
            sender: sender,
            capture: capture,
            switchMachine: machine,
            hostPointerBackend: backend
        )
        return (controller, capture, machine)
    }

    @MainActor
    private func enterRemote(
        _ machine: EdgeSwitchStateMachine
    ) async {
        machine.activate()
        machine.flushCallbacks()
        machine.pointerAtEdge(.left)
        machine.flushCallbacks()
        await Task.yield()
    }

    @MainActor
    private func waitUntil(
        attempts: Int = 300,
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @MainActor
    func testEmergencyReturnSynchronouslyReleasesInstalledLease() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        let lease = FakeHostPointerLease(generation: 100)
        backend.succeed(with: lease)

        let published = await waitUntil {
            context.controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            )
        }
        XCTAssertTrue(published)
        XCTAssertTrue(context.capture.isSuppressed)
        XCTAssertTrue(lease.isActive)

        context.controller.emergencyReturn()

        XCTAssertEqual(lease.releaseCount, 1)
        XCTAssertFalse(context.capture.isSuppressed)
        XCTAssertEqual(context.machine.state, .localActive)
    }

    @MainActor
    func testLateAcquisitionAfterReturnIsImmediatelyReleased() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        context.controller.emergencyReturn()
        XCTAssertEqual(context.machine.state, .localActive)
        XCTAssertFalse(context.capture.isSuppressed)

        let lateLease = FakeHostPointerLease(generation: 101)
        backend.succeed(with: lateLease)

        let released = await waitUntil { lateLease.releaseCount == 1 }
        XCTAssertTrue(released)
        XCTAssertFalse(context.capture.isSuppressed)
        XCTAssertEqual(context.machine.state, .localActive)
    }

    @MainActor
    func testAcquisitionFailureFailsClosedToLocal() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        backend.failAcquisition()

        let returnedLocal = await waitUntil {
            context.machine.state == .localActive
        }
        XCTAssertTrue(returnedLocal)
        XCTAssertFalse(context.capture.isSuppressed)
    }

    @MainActor
    func testFailureBeforeLeasePublicationFailsClosedImmediately() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)
        XCTAssertTrue(context.capture.isSuppressed)

        let lease = FakeHostPointerLease(generation: 150)
        backend.failBeforePublication(with: lease)

        let returnedLocal = await waitUntil {
            context.machine.state == .localActive
                && !context.capture.isSuppressed
        }
        XCTAssertTrue(returnedLocal)
        XCTAssertEqual(lease.releaseCount, 1)
        XCTAssertFalse(
            context.controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            )
        )
    }

    @MainActor
    func testBackendFailureReleasesCaptureAndReturnsLocal() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        let lease = FakeHostPointerLease(generation: 102)
        backend.succeed(with: lease)
        let published = await waitUntil {
            context.controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            )
        }
        XCTAssertTrue(published)
        XCTAssertTrue(context.capture.isSuppressed)

        backend.failActiveLease()

        let returnedLocal = await waitUntil {
            context.machine.state == .localActive
                && !context.capture.isSuppressed
        }
        XCTAssertTrue(returnedLocal)
        XCTAssertEqual(lease.releaseCount, 1)
    }
}
