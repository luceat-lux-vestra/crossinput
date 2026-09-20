import Foundation
import XCTest
@testable import App
import Delivery
import EdgeSwitch
@testable import InputCapture

private enum FakeHostPointerError: Error {
    case acquisitionFailed
}

private final class BoolObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func set(_ value: Bool) {
        lock.withLock { storage = value }
    }

    var value: Bool {
        lock.withLock { storage }
    }
}

private final class FakeHostPointerLease: HostPointerOwnershipLease, @unchecked Sendable {
    let generation: UInt64

    private let lock = NSLock()
    private var active = true
    private var released = false
    private var releaseCountStorage = 0
    private var lifecycleOwnsReleaseStorage = false
    private let onRelease: (@Sendable () -> Void)?

    init(
        generation: UInt64,
        onRelease: (@Sendable () -> Void)? = nil
    ) {
        self.generation = generation
        self.onRelease = onRelease
    }

    var isActive: Bool {
        lock.withLock { active && !released }
    }

    var releaseCount: Int {
        lock.withLock { releaseCountStorage }
    }

    var lifecycleOwnsRelease: Bool {
        lock.withLock { lifecycleOwnsReleaseStorage }
    }

    func transferReleaseResponsibilityToLifecycleOwner() {
        lock.withLock {
            lifecycleOwnsReleaseStorage = true
        }
    }

    func fail() {
        lock.withLock { active = false }
    }

    func release() {
        let shouldNotify = lock.withLock {
            guard !released else { return false }
            released = true
            active = false
            releaseCountStorage += 1
            return true
        }
        if shouldNotify {
            onRelease?()
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

    var hasPendingAcquisition: Bool {
        lock.withLock { continuation != nil }
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

    func signalFailure(generation: UInt64) {
        let handler = lock.withLock { failureHandler }
        handler?(generation)
    }
}

final class HostPointerLeaseSlotTests: XCTestCase {
    func testStaleCaptureGenerationCannotReleaseNewerLease() {
        let slot = HostPointerLeaseSlot()
        let first = FakeHostPointerLease(generation: 10)
        let second = FakeHostPointerLease(generation: 11)

        XCTAssertTrue(slot.begin(captureGeneration: 1))
        XCTAssertTrue(slot.install(first, captureGeneration: 1))
        slot.take(captureGeneration: 1)?.lease?.release()
        XCTAssertEqual(first.releaseCount, 1)

        XCTAssertTrue(slot.begin(captureGeneration: 2))
        XCTAssertTrue(slot.install(second, captureGeneration: 2))
        slot.take(captureGeneration: 1)?.lease?.release()

        XCTAssertTrue(second.isActive)
        XCTAssertEqual(second.releaseCount, 0)
        XCTAssertTrue(slot.isCurrent(hostGeneration: 11))

        slot.take(captureGeneration: 2)?.lease?.release()
        XCTAssertEqual(second.releaseCount, 1)
    }

    func testStaleHostGenerationCannotReleaseNewerLease() {
        let slot = HostPointerLeaseSlot()
        let first = FakeHostPointerLease(generation: 20)
        let second = FakeHostPointerLease(generation: 21)

        XCTAssertTrue(slot.begin(captureGeneration: 3))
        XCTAssertTrue(slot.install(first, captureGeneration: 3))
        slot.take(hostGeneration: 20)?.lease?.release()
        XCTAssertTrue(slot.begin(captureGeneration: 4))
        XCTAssertTrue(slot.install(second, captureGeneration: 4))

        slot.take(hostGeneration: 20)?.lease?.release()

        XCTAssertTrue(second.isActive)
        XCTAssertEqual(second.releaseCount, 0)
        XCTAssertTrue(slot.isCurrent(hostGeneration: 21))
    }

    func testTakeCurrentDoesNotReleaseUntilLifecycleOwnerChooses() {
        let slot = HostPointerLeaseSlot()
        let lease = FakeHostPointerLease(generation: 22)

        XCTAssertTrue(slot.begin(captureGeneration: 5))
        XCTAssertTrue(slot.install(lease, captureGeneration: 5))

        let ownership = slot.takeCurrent()
        XCTAssertEqual(ownership?.captureGeneration, 5)
        XCTAssertEqual(lease.releaseCount, 0)

        ownership?.lease?.release()
        XCTAssertEqual(lease.releaseCount, 1)
    }

    func testHostGenerationMustMatchItsCaptureGenerationAtAdmission() {
        let slot = HostPointerLeaseSlot()
        let first = FakeHostPointerLease(generation: 30)
        let second = FakeHostPointerLease(generation: 31)

        XCTAssertTrue(slot.begin(captureGeneration: 7))
        XCTAssertTrue(slot.install(first, captureGeneration: 7))
        XCTAssertTrue(
            slot.isCurrent(hostGeneration: 30, captureGeneration: 7)
        )
        XCTAssertFalse(
            slot.isCurrent(hostGeneration: 30, captureGeneration: 8)
        )

        slot.take(captureGeneration: 7)?.lease?.release()
        XCTAssertTrue(slot.begin(captureGeneration: 8))
        XCTAssertTrue(slot.install(second, captureGeneration: 8))

        // An old CoreHID callback cannot become valid against the replacement
        // control epoch merely because another host lease is now active.
        XCTAssertFalse(
            slot.isCurrent(hostGeneration: 30, captureGeneration: 8)
        )
        XCTAssertTrue(
            slot.isCurrent(hostGeneration: 31, captureGeneration: 8)
        )
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
    func testHeldHostInputBlocksAcquisitionAndReturnsLocal() async {
        let backend = FakeHostPointerBackend()
        let capture = InputCapture(
            pointerRestoreOverride: {},
            hostInputNeutralProvider: { false }
        )
        let machine = EdgeSwitchStateMachine()
        let sender = InputSender(session: SessionReference())
        let controller = ControlHandoffController(
            sender: sender,
            capture: capture,
            switchMachine: machine,
            hostPointerBackend: backend
        )
        _ = controller

        await enterRemote(machine)

        let returnedLocal = await waitUntil {
            machine.state == .localActive
        }
        XCTAssertTrue(returnedLocal)
        XCTAssertFalse(capture.isSuppressed)
        XCTAssertFalse(backend.hasStarted)
    }

    @MainActor
    func testEdgePinnedPointerActivityDoesNotCancelPendingAcquisition() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        let admission = context.controller.controlAdmissionStateForTesting()
        let generation = try! XCTUnwrap(admission.captureGeneration)

        context.capture.onExternalPointerOwnerActivity?(generation, .edgePinnedPointerMove)

        XCTAssertTrue(context.capture.isSuppressed)
        XCTAssertEqual(context.machine.state, .remoteActive)

        context.controller.emergencyReturn()
        let lateLease = FakeHostPointerLease(generation: 90)
        backend.succeed(with: lateLease)
        let lateLeaseReleased = await waitUntil { lateLease.releaseCount == 1 }
        XCTAssertTrue(lateLeaseReleased)
    }

    @MainActor
    func testKeyboardDuringPendingAcquisitionPassesThroughAndFailsLocal() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        )!
        XCTAssertNotNil(
            context.capture.handleForTesting(type: .keyDown, event: keyDown)
        )

        let returnedLocal = await waitUntil {
            context.machine.state == .localActive
                && !context.capture.isSuppressed
        }
        XCTAssertTrue(returnedLocal)

        let lateLease = FakeHostPointerLease(generation: 93)
        backend.succeed(with: lateLease)
        let lateLeaseReleased = await waitUntil {
            lateLease.releaseCount == 1
        }
        XCTAssertTrue(lateLeaseReleased)
    }

    @MainActor
    func testPointerLeavingEdgeCancelsPendingAcquisitionFailLocal() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        let admission = context.controller.controlAdmissionStateForTesting()
        let generation = try! XCTUnwrap(admission.captureGeneration)

        context.capture.onExternalPointerOwnerActivity?(generation, .incompatibleLocalInput)

        let returnedLocal = await waitUntil {
            context.machine.state == .localActive
                && !context.capture.isSuppressed
        }
        XCTAssertTrue(returnedLocal)

        let lateLease = FakeHostPointerLease(generation: 91)
        backend.succeed(with: lateLease)
        let lateLeaseReleased = await waitUntil { lateLease.releaseCount == 1 }
        XCTAssertTrue(lateLeaseReleased)
    }

    @MainActor
    func testLeasePublicationActivatesKeyboardSuppression() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        let lease = FakeHostPointerLease(generation: 94)
        backend.succeed(with: lease)
        let ready = await waitUntil {
            context.controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            )
        }
        XCTAssertTrue(ready)
        XCTAssertTrue(
            lease.lifecycleOwnsRelease,
            "published lease must transfer self-release responsibility to Control"
        )

        let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        )!
        XCTAssertNil(
            context.capture.handleForTesting(type: .keyDown, event: keyDown)
        )

        context.controller.emergencyReturn()
        XCTAssertEqual(lease.releaseCount, 1)
    }

    @MainActor
    func testPointerActivityAfterLeasePublicationFailsLocalAndReleasesLease() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        let lease = FakeHostPointerLease(generation: 92)
        backend.succeed(with: lease)
        let published = await waitUntil {
            context.controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            )
        }
        XCTAssertTrue(published)

        let admission = context.controller.controlAdmissionStateForTesting()
        let generation = try! XCTUnwrap(admission.captureGeneration)

        // Even if the CG event still sits on the configured edge, a published
        // CoreHID lease means CG pointer activity is an ownership anomaly.
        context.capture.onExternalPointerOwnerActivity?(generation, .edgePinnedPointerMove)

        let returnedLocal = await waitUntil {
            context.machine.state == .localActive
                && !context.capture.isSuppressed
        }
        XCTAssertTrue(returnedLocal)
        XCTAssertEqual(lease.releaseCount, 1)
    }

    @MainActor
    func testReturnWithdrawsKeyboardOwnershipBeforeLeaseDrop() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        let admission = context.controller.controlAdmissionStateForTesting()
        let generation = try! XCTUnwrap(admission.captureGeneration)
        let capture = context.capture
        let keyboardWasLocalAtLeaseRelease = BoolObservation()
        let lease = FakeHostPointerLease(
            generation: 95,
            onRelease: {
                keyboardWasLocalAtLeaseRelease.set(
                    !capture.isExternalPointerOwnerActive(
                        generation: generation
                    )
                )
            }
        )
        backend.succeed(with: lease)

        let ready = await waitUntil {
            context.controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            )
        }
        XCTAssertTrue(ready)

        context.controller.emergencyReturn()

        XCTAssertEqual(lease.releaseCount, 1)
        XCTAssertTrue(keyboardWasLocalAtLeaseRelease.value)
        XCTAssertFalse(context.capture.isSuppressed)
        XCTAssertEqual(context.machine.state, .localActive)
    }

    @MainActor
    func testCapabilityLossWithdrawsKeyboardBeforeLeaseDrop() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        let generation = try! XCTUnwrap(
            context.controller.controlAdmissionStateForTesting().captureGeneration
        )
        let capture = context.capture
        let keyboardWasLocalAtLeaseRelease = BoolObservation()
        let lease = FakeHostPointerLease(
            generation: 96,
            onRelease: {
                keyboardWasLocalAtLeaseRelease.set(
                    !capture.isExternalPointerOwnerActive(generation: generation)
                )
            }
        )
        backend.succeed(with: lease)
        let published = await waitUntil {
            context.controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            )
        }
        XCTAssertTrue(published)

        context.controller.inputCapabilityLost()

        XCTAssertEqual(lease.releaseCount, 1)
        XCTAssertTrue(keyboardWasLocalAtLeaseRelease.value)
        XCTAssertFalse(context.capture.isSuppressed)
    }

    @MainActor
    func testCapabilityLossDuringPendingAcquisitionRejectsLateLease() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        context.controller.inputCapabilityLost()
        XCTAssertFalse(context.capture.isSuppressed)

        let lateLease = FakeHostPointerLease(generation: 97)
        backend.succeed(with: lateLease)

        let released = await waitUntil { lateLease.releaseCount == 1 }
        XCTAssertTrue(released)
        XCTAssertFalse(context.capture.isSuppressed)
    }

    @MainActor
    func testDirectStateMachineReturnWithdrawsKeyboardBeforeLeaseDrop() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        let generation = try! XCTUnwrap(
            context.controller.controlAdmissionStateForTesting().captureGeneration
        )
        let capture = context.capture
        let keyboardWasLocalAtLeaseRelease = BoolObservation()
        let lease = FakeHostPointerLease(
            generation: 98,
            onRelease: {
                keyboardWasLocalAtLeaseRelease.set(
                    !capture.isExternalPointerOwnerActive(generation: generation)
                )
            }
        )
        backend.succeed(with: lease)
        let published = await waitUntil {
            context.controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            )
        }
        XCTAssertTrue(published)

        context.machine.forceReturn(reason: .remoteUnavailable)
        let released = await waitUntil { lease.releaseCount == 1 }
        XCTAssertTrue(released)

        XCTAssertTrue(keyboardWasLocalAtLeaseRelease.value)
        XCTAssertFalse(context.capture.isSuppressed)
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
        let beforeReturn =
            context.controller.controlAdmissionStateForTesting()
        XCTAssertNotNil(beforeReturn.captureGeneration)

        context.controller.emergencyReturn()

        let afterReturn =
            context.controller.controlAdmissionStateForTesting()
        XCTAssertNil(afterReturn.captureGeneration)
        XCTAssertGreaterThan(afterReturn.epoch, beforeReturn.epoch)
        XCTAssertEqual(lease.releaseCount, 1)
        XCTAssertFalse(context.capture.isSuppressed)
        XCTAssertEqual(context.machine.state, .localActive)
    }

    @MainActor
    func testTapDisableDuringPublishedLeaseFailsLocalAndReleasesLease() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let pending = await waitUntil { backend.hasPendingAcquisition }
        XCTAssertTrue(pending)

        let lease = FakeHostPointerLease(generation: 199)
        backend.succeed(with: lease)
        let published = await waitUntil {
            context.controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            )
        }
        XCTAssertTrue(published)
        XCTAssertTrue(context.capture.isSuppressed)

        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: .zero,
            mouseButton: .left
        )!
        XCTAssertNotNil(
            context.capture.handleForTesting(
                type: .tapDisabledByTimeout,
                event: event
            )
        )

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
    func testCaptureOriginatedReturnInvalidatesAdmissionsSynchronously() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        let lease = FakeHostPointerLease(generation: 103)
        backend.succeed(with: lease)
        let published = await waitUntil {
            context.controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            )
        }
        XCTAssertTrue(published)

        let beforeReturn =
            context.controller.controlAdmissionStateForTesting()
        XCTAssertNotNil(beforeReturn.captureGeneration)

        // Models watchdog/external capture release: the callback must close
        // admission before its MainActor force-return task runs.
        context.capture.release(reason: .watchdogTimeout)

        let afterReturn =
            context.controller.controlAdmissionStateForTesting()
        XCTAssertNil(afterReturn.captureGeneration)
        XCTAssertGreaterThan(afterReturn.epoch, beforeReturn.epoch)
        XCTAssertEqual(lease.releaseCount, 1)
        XCTAssertFalse(context.capture.isSuppressed)

        let returnedLocal = await waitUntil {
            context.machine.state == .localActive
        }
        XCTAssertTrue(returnedLocal)
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
    func testStaleFailureAfterReplacementLeaseCannotBreakSecondCycle() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let firstPending = await waitUntil { backend.hasPendingAcquisition }
        XCTAssertTrue(firstPending)

        let first = FakeHostPointerLease(generation: 201)
        backend.succeed(with: first)
        let firstPublished = await waitUntil {
            context.controller.hasActiveHostPointerLeaseForTesting(
                generation: first.generation
            )
        }
        XCTAssertTrue(firstPublished)

        context.controller.emergencyReturn()
        XCTAssertEqual(first.releaseCount, 1)
        XCTAssertEqual(context.machine.state, .localActive)

        context.machine.pointerAtEdge(.left)
        context.machine.flushCallbacks()
        let secondPending = await waitUntil { backend.hasPendingAcquisition }
        XCTAssertTrue(secondPending)

        let second = FakeHostPointerLease(generation: 202)
        backend.succeed(with: second)
        let secondPublished = await waitUntil {
            context.controller.hasActiveHostPointerLeaseForTesting(
                generation: second.generation
            )
        }
        XCTAssertTrue(secondPublished)

        // Simulate a delayed failure callback from the retired first lease.
        backend.signalFailure(generation: first.generation)
        await Task.yield()

        XCTAssertEqual(second.releaseCount, 0)
        XCTAssertTrue(second.isActive)
        XCTAssertTrue(context.capture.isSuppressed)
        XCTAssertEqual(context.machine.state, .remoteActive)

        context.controller.emergencyReturn()
        XCTAssertEqual(second.releaseCount, 1)
        XCTAssertFalse(context.capture.isSuppressed)
        XCTAssertEqual(context.machine.state, .localActive)
    }

    @MainActor
    func testRepeatedOwnershipCyclesDoNotLeakLeaseOrSuppressionState() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)

        for cycle in 0..<25 {
            if cycle > 0 {
                context.machine.pointerAtEdge(.left)
                context.machine.flushCallbacks()
            }

            let pending = await waitUntil {
                backend.hasPendingAcquisition
            }
            XCTAssertTrue(pending, "cycle \(cycle): acquisition must start")

            let lease = FakeHostPointerLease(
                generation: UInt64(300 + cycle)
            )
            backend.succeed(with: lease)

            let published = await waitUntil {
                context.controller.hasActiveHostPointerLeaseForTesting(
                    generation: lease.generation
                )
            }
            XCTAssertTrue(published, "cycle \(cycle): lease must publish")
            XCTAssertTrue(context.capture.isSuppressed)

            context.controller.emergencyReturn()

            XCTAssertEqual(
                lease.releaseCount,
                1,
                "cycle \(cycle): lease must release exactly once"
            )
            XCTAssertFalse(context.capture.isSuppressed)
            XCTAssertEqual(context.machine.state, .localActive)
            XCTAssertNil(
                context.controller
                    .controlAdmissionStateForTesting()
                    .captureGeneration
            )
        }
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

        // Regression: an inactive lease must consume the pending slot
        // reservation. Otherwise the next begin() sees a permanent collision
        // and every later handoff fails local.
        context.machine.pointerAtEdge(.left)
        context.machine.flushCallbacks()
        let retryPending = await waitUntil {
            backend.hasPendingAcquisition
        }
        XCTAssertTrue(
            retryPending,
            "pre-publication failure must not poison the next acquisition"
        )

        let retryLease = FakeHostPointerLease(generation: 151)
        backend.succeed(with: retryLease)
        let retryPublished = await waitUntil {
            context.controller.hasActiveHostPointerLeaseForTesting(
                generation: retryLease.generation
            )
        }
        XCTAssertTrue(retryPublished)
        XCTAssertTrue(context.capture.isSuppressed)

        context.controller.emergencyReturn()
        XCTAssertEqual(retryLease.releaseCount, 1)
        XCTAssertFalse(context.capture.isSuppressed)
        XCTAssertEqual(context.machine.state, .localActive)
    }

    @MainActor
    func testBackendFailureReleasesCaptureAndReturnsLocal() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        let generation = try! XCTUnwrap(
            context.controller.controlAdmissionStateForTesting().captureGeneration
        )
        let capture = context.capture
        let keyboardWasLocalAtLeaseRelease = BoolObservation()
        let lease = FakeHostPointerLease(
            generation: 102,
            onRelease: {
                keyboardWasLocalAtLeaseRelease.set(
                    !capture.isExternalPointerOwnerActive(generation: generation)
                )
            }
        )
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
        XCTAssertTrue(keyboardWasLocalAtLeaseRelease.value)
    }
}
