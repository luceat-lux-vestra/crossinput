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

private final class IntObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.withLock { storage += 1 }
    }

    var value: Int {
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
    private var releaseSucceedsStorage = true
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

    func setReleaseSucceeds(_ value: Bool) {
        lock.withLock {
            releaseSucceedsStorage = value
        }
    }

    func transferReleaseResponsibilityToLifecycleOwner() {
        lock.withLock {
            lifecycleOwnsReleaseStorage = true
        }
    }

    func fail() {
        lock.withLock { active = false }
    }

    @discardableResult
    func release() -> Bool {
        let result = lock.withLock { () -> (success: Bool, notify: Bool) in
            if released {
                return (true, false)
            }
            releaseCountStorage += 1
            guard releaseSucceedsStorage else {
                return (false, false)
            }
            released = true
            active = false
            return (true, true)
        }
        if result.notify {
            onRelease?()
        }
        return result.success
    }
}

private final class FakeRemoteCursorPresenter:
    RemoteCursorPresenting, @unchecked Sendable
{
    private let lock = NSLock()
    private var presentedEdgesStorage: [ScreenEdge] = []
    private var effectiveRestoreCountStorage = 0
    private var presented = false
    private var presentResultStorage = true
    private var presentationAllowedStorage = true
    private var failureHandler: (@Sendable () -> Void)?
    private var restoreGateStorage: DispatchSemaphore?
    private var restoreStartedStorage = 0
    private var localAppearanceObservationResultStorage = true

    var presentedEdges: [ScreenEdge] {
        lock.withLock { presentedEdgesStorage }
    }

    var effectiveRestoreCount: Int {
        lock.withLock { effectiveRestoreCountStorage }
    }

    var restoreStartedCount: Int {
        lock.withLock { restoreStartedStorage }
    }

    func setRestoreGate(_ gate: DispatchSemaphore?) {
        lock.withLock {
            restoreGateStorage = gate
        }
    }

    func setLocalAppearanceObservationResult(_ result: Bool) {
        lock.withLock {
            localAppearanceObservationResultStorage = result
        }
    }

    func setPresentResult(_ result: Bool) {
        lock.withLock {
            presentResultStorage = result
        }
    }

    func setPresentationAllowed(_ allowed: Bool) {
        lock.withLock {
            presentationAllowedStorage = allowed
        }
    }

    func failPresentation() {
        let handler = lock.withLock { failureHandler }
        handler?()
    }

    @discardableResult
    func presentRemote(
        edge: ScreenEdge,
        onFailure: @escaping @Sendable () -> Void
    ) async -> Bool {
        lock.withLock {
            presentedEdgesStorage.append(edge)
            failureHandler = onFailure
        }

        while !lock.withLock({ presentationAllowedStorage }) {
            try? await Task.sleep(for: .milliseconds(5))
        }

        return lock.withLock {
            guard presentResultStorage else {
                presented = false
                return false
            }
            presented = true
            return true
        }
    }

    @discardableResult
    func restoreLocal() -> Bool {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            failureHandler = nil
            guard presented else { return nil }
            presented = false
            effectiveRestoreCountStorage += 1
            restoreStartedStorage += 1
            return restoreGateStorage
        }
        gate?.wait()
        return true
    }

    func observeLocalAppearanceRestored() -> Bool {
        lock.withLock { localAppearanceObservationResultStorage }
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

final class HostPhysicalReleaseAttemptCoordinatorTests: XCTestCase {
    func testSameGenerationConcurrentCallersShareOneReleaseOperation() {
        let coordinator = HostPhysicalReleaseAttemptCoordinator()
        let releaseEntered = expectation(description: "release entered")
        let secondReturned = expectation(description: "second returned")
        let firstReturned = expectation(description: "first returned")
        let allowReleaseToFinish = DispatchSemaphore(value: 0)
        let releaseCount = IntObservation()
        let firstResult = BoolObservation()
        let secondResult = BoolObservation()

        DispatchQueue.global(qos: .userInitiated).async {
            firstResult.set(
                coordinator.perform(generation: 701) {
                    releaseCount.increment()
                    releaseEntered.fulfill()
                    allowReleaseToFinish.wait()
                    return true
                }
            )
            firstReturned.fulfill()
        }

        wait(for: [releaseEntered], timeout: 1)

        DispatchQueue.global(qos: .userInitiated).async {
            secondResult.set(
                coordinator.perform(generation: 701) {
                    releaseCount.increment()
                    return true
                }
            )
            secondReturned.fulfill()
        }

        // The first operation remains blocked, so a concurrent second caller
        // must join it rather than execute a second physical release closure.
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(releaseCount.value, 1)

        allowReleaseToFinish.signal()
        wait(for: [firstReturned, secondReturned], timeout: 1)

        XCTAssertEqual(releaseCount.value, 1)
        XCTAssertTrue(firstResult.value)
        XCTAssertTrue(secondResult.value)
    }

    func testDifferentGenerationCannotJoinInFlightRelease() {
        let coordinator = HostPhysicalReleaseAttemptCoordinator()
        let releaseEntered = expectation(description: "release entered")
        let firstReturned = expectation(description: "first returned")
        let allowReleaseToFinish = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = coordinator.perform(generation: 801) {
                releaseEntered.fulfill()
                allowReleaseToFinish.wait()
                return true
            }
            firstReturned.fulfill()
        }

        wait(for: [releaseEntered], timeout: 1)
        let staleResult = coordinator.perform(generation: 802) {
            XCTFail("different generation must not execute while another owns release")
            return true
        }
        XCTAssertFalse(staleResult)

        allowReleaseToFinish.signal()
        wait(for: [firstReturned], timeout: 1)
    }
}

final class HostReturnAttemptCoordinatorTests: XCTestCase {
    func testDifferentCaptureGenerationCannotJoinInFlightReturn() {
        let coordinator = HostReturnAttemptCoordinator()
        let returnEntered = expectation(description: "return entered")
        let ownerReturned = expectation(description: "owner returned")
        let allowReturnToFinish = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = coordinator.perform(captureGeneration: 901) {
                returnEntered.fulfill()
                allowReturnToFinish.wait()
                return true
            }
            ownerReturned.fulfill()
        }

        wait(for: [returnEntered], timeout: 1)
        let staleResult = coordinator.perform(captureGeneration: 902) {
            XCTFail(
                "different capture generation must not join or execute "
                    + "while another return owns the lifecycle"
            )
            return true
        }
        XCTAssertFalse(staleResult)

        allowReturnToFinish.signal()
        wait(for: [ownerReturned], timeout: 1)
    }

    func testNilGenerationJoinsInFlightReturnAfterGenerationAnchorClears() {
        let coordinator = HostReturnAttemptCoordinator()
        let returnEntered = expectation(description: "return entered")
        let firstReturned = expectation(description: "first returned")
        let secondReturned = expectation(description: "second returned")
        let allowReturnToFinish = DispatchSemaphore(value: 0)
        let operationCount = IntObservation()
        let secondResult = BoolObservation()

        DispatchQueue.global(qos: .userInitiated).async {
            _ = coordinator.perform(captureGeneration: 903) {
                operationCount.increment()
                returnEntered.fulfill()
                allowReturnToFinish.wait()
                return true
            }
            firstReturned.fulfill()
        }

        wait(for: [returnEntered], timeout: 1)

        DispatchQueue.global(qos: .userInitiated).async {
            secondResult.set(
                coordinator.perform(captureGeneration: nil) {
                    operationCount.increment()
                    return true
                }
            )
            secondReturned.fulfill()
        }

        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(
            operationCount.value,
            1,
            "generation-less duplicate must join the active return"
        )

        allowReturnToFinish.signal()
        wait(for: [firstReturned, secondReturned], timeout: 1)

        XCTAssertEqual(operationCount.value, 1)
        XCTAssertTrue(secondResult.value)
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
            hostPointerBackend: backend,
            remoteCursorPresenter: FakeRemoteCursorPresenter()
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
    func testRemoteCursorPresentationFollowsPublishedOwnership() async {
        let backend = FakeHostPointerBackend()
        let presenter = FakeRemoteCursorPresenter()
        let capture = InputCapture()
        let machine = EdgeSwitchStateMachine()
        let sender = InputSender(session: SessionReference())
        let controller = ControlHandoffController(
            sender: sender,
            capture: capture,
            switchMachine: machine,
            hostPointerBackend: backend,
            remoteCursorPresenter: presenter
        )

        await enterRemote(machine)
        let backendStarted = await waitUntil { backend.hasStarted }
        XCTAssertTrue(backendStarted)
        XCTAssertTrue(
            presenter.presentedEdges.isEmpty,
            "remote cursor must not be published before CoreHID ownership is ready"
        )

        let generation = try! XCTUnwrap(
            controller.controlAdmissionStateForTesting().captureGeneration
        )
        let lease = FakeHostPointerLease(generation: 89)
        backend.succeed(with: lease)

        let ready = await waitUntil {
            controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            ) && capture.isExternalPointerOwnerActive(
                generation: generation
            ) && presenter.presentedEdges == [.left]
        }
        XCTAssertTrue(ready)

        controller.emergencyReturn()

        let restored = await waitUntil {
            presenter.effectiveRestoreCount == 1
                && machine.state == .localActive
        }
        XCTAssertTrue(restored)
        XCTAssertEqual(lease.releaseCount, 1)
        XCTAssertFalse(capture.isSuppressed)
    }

    @MainActor
    func testRemoteInputAdmissionWaitsForCursorReady() async {
        let backend = FakeHostPointerBackend()
        let presenter = FakeRemoteCursorPresenter()
        presenter.setPresentationAllowed(false)
        let capture = InputCapture()
        let machine = EdgeSwitchStateMachine()
        let sender = InputSender(session: SessionReference())
        let controller = ControlHandoffController(
            sender: sender,
            capture: capture,
            switchMachine: machine,
            hostPointerBackend: backend,
            remoteCursorPresenter: presenter
        )

        await enterRemote(machine)
        let backendStarted = await waitUntil { backend.hasStarted }
        XCTAssertTrue(backendStarted)

        let generation = try! XCTUnwrap(
            controller.controlAdmissionStateForTesting().captureGeneration
        )
        let lease = FakeHostPointerLease(generation: 8900)
        backend.succeed(with: lease)

        let cursorPending = await waitUntil {
            presenter.presentedEdges == [.left]
                && controller.hasPublishedHostPointerLeaseForTesting(
                    generation: lease.generation
                )
        }
        XCTAssertTrue(cursorPending)
        XCTAssertFalse(
            capture.isExternalPointerOwnerActive(generation: generation),
            "remote input must remain inadmissible until cursor READY"
        )

        presenter.setPresentationAllowed(true)

        let committed = await waitUntil {
            capture.isExternalPointerOwnerActive(generation: generation)
        }
        XCTAssertTrue(committed)

        controller.emergencyReturn()
        XCTAssertEqual(lease.releaseCount, 1)
        XCTAssertFalse(capture.isSuppressed)
        XCTAssertEqual(machine.state, .localActive)
    }

    @MainActor
    func testCursorAdmissionFailureReturnsLocalAndReleasesCoreHID() async {
        let backend = FakeHostPointerBackend()
        let presenter = FakeRemoteCursorPresenter()
        presenter.setPresentResult(false)
        let capture = InputCapture()
        let machine = EdgeSwitchStateMachine()
        let sender = InputSender(session: SessionReference())
        let controller = ControlHandoffController(
            sender: sender,
            capture: capture,
            switchMachine: machine,
            hostPointerBackend: backend,
            remoteCursorPresenter: presenter
        )

        await enterRemote(machine)
        let backendStarted = await waitUntil { backend.hasStarted }
        XCTAssertTrue(backendStarted)

        let lease = FakeHostPointerLease(generation: 8901)
        backend.succeed(with: lease)

        let returned = await waitUntil {
            machine.state == .localActive
                && lease.releaseCount == 1
                && !capture.isSuppressed
        }
        XCTAssertTrue(returned)
        XCTAssertFalse(
            controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            )
        )
    }

    @MainActor
    func testCursorHelperFailureDuringRemoteEpochFailsLocal() async {
        let backend = FakeHostPointerBackend()
        let presenter = FakeRemoteCursorPresenter()
        let capture = InputCapture()
        let machine = EdgeSwitchStateMachine()
        let sender = InputSender(session: SessionReference())
        let controller = ControlHandoffController(
            sender: sender,
            capture: capture,
            switchMachine: machine,
            hostPointerBackend: backend,
            remoteCursorPresenter: presenter
        )

        await enterRemote(machine)
        let backendStarted = await waitUntil { backend.hasStarted }
        XCTAssertTrue(backendStarted)

        let generation = try! XCTUnwrap(
            controller.controlAdmissionStateForTesting().captureGeneration
        )
        let lease = FakeHostPointerLease(generation: 8902)
        backend.succeed(with: lease)

        let ownershipReady = await waitUntil {
            controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            ) && capture.isExternalPointerOwnerActive(
                generation: generation
            )
        }
        XCTAssertTrue(ownershipReady)

        presenter.failPresentation()

        let returned = await waitUntil {
            machine.state == .localActive
                && lease.releaseCount == 1
                && !capture.isSuppressed
        }
        XCTAssertTrue(returned)
    }

    @MainActor
    func testEmergencyReturnBlocksResidualEdgeReentryUntilLocalMove() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let backendStarted = await waitUntil { backend.hasStarted }
        XCTAssertTrue(backendStarted)

        let lease = FakeHostPointerLease(generation: 890)
        backend.succeed(with: lease)
        let leaseActivated = await waitUntil {
            context.controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            )
        }
        XCTAssertTrue(leaseActivated)

        context.controller.emergencyReturn()

        XCTAssertEqual(context.machine.state, .localActive)
        XCTAssertTrue(
            context.controller.isEmergencyReentryBlockedForTesting()
        )

        // Residual drag/movement back toward the remote side must not re-arm
        // handoff after an emergency escape.
        context.capture.onListeningPointerMove?(-8, 0)
        XCTAssertTrue(
            context.controller.isEmergencyReentryBlockedForTesting()
        )

        // Once the user moves back into the local display, a later deliberate
        // edge approach may arm handoff again.
        context.capture.onListeningPointerMove?(8, 0)
        XCTAssertFalse(
            context.controller.isEmergencyReentryBlockedForTesting()
        )
    }

    @MainActor
    func testConcurrentEmergencyReturnsJoinWholeHostReturnBeforeCoreHIDRelease() async {
        let backend = FakeHostPointerBackend()
        let presenter = FakeRemoteCursorPresenter()
        let capture = InputCapture()
        let machine = EdgeSwitchStateMachine()
        let sender = InputSender(session: SessionReference())
        let controller = ControlHandoffController(
            sender: sender,
            capture: capture,
            switchMachine: machine,
            hostPointerBackend: backend,
            remoteCursorPresenter: presenter
        )

        await enterRemote(machine)
        let acquisitionStarted = await waitUntil { backend.hasStarted }
        XCTAssertTrue(acquisitionStarted)

        let lease = FakeHostPointerLease(generation: 8903)
        backend.succeed(with: lease)
        let leaseActivated = await waitUntil {
            controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            )
        }
        XCTAssertTrue(leaseActivated)

        let restoreGate = DispatchSemaphore(value: 0)
        presenter.setRestoreGate(restoreGate)
        let firstReturned = BoolObservation()
        let secondReturned = BoolObservation()

        DispatchQueue.global(qos: .userInitiated).async {
            controller.emergencyReturn()
            firstReturned.set(true)
        }

        let restoreStarted = await waitUntil {
            presenter.restoreStartedCount == 1
        }
        XCTAssertTrue(restoreStarted)

        DispatchQueue.global(qos: .userInitiated).async {
            controller.emergencyReturn()
            secondReturned.set(true)
        }

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            lease.releaseCount,
            0,
            "a duplicate return must not pass the owner's blocked cursor cleanup"
        )
        XCTAssertFalse(
            secondReturned.value,
            "same-generation duplicate caller must join the in-flight return"
        )
        XCTAssertEqual(machine.state, .remoteActive)

        restoreGate.signal()

        let bothReturned = await waitUntil {
            firstReturned.value && secondReturned.value
        }
        XCTAssertTrue(bothReturned)
        XCTAssertEqual(presenter.effectiveRestoreCount, 1)
        XCTAssertEqual(lease.releaseCount, 1)
        XCTAssertFalse(capture.isSuppressed)
        XCTAssertEqual(machine.state, .localActive)
    }

    @MainActor
    func testCursorAppearanceMismatchOnNormalReturnDoesNotPoisonNextRemoteGeneration() async {
        let backend = FakeHostPointerBackend()
        let presenter = FakeRemoteCursorPresenter()
        let capture = InputCapture()
        let machine = EdgeSwitchStateMachine()
        let sender = InputSender(session: SessionReference())
        let controller = ControlHandoffController(
            sender: sender,
            capture: capture,
            switchMachine: machine,
            hostPointerBackend: backend,
            remoteCursorPresenter: presenter
        )

        await enterRemote(machine)
        let acquisitionStarted = await waitUntil { backend.hasStarted }
        XCTAssertTrue(acquisitionStarted)

        let firstLease = FakeHostPointerLease(generation: 8904)
        backend.succeed(with: firstLease)
        let firstActivated = await waitUntil {
            controller.hasActiveHostPointerLeaseForTesting(
                generation: firstLease.generation
            )
        }
        XCTAssertTrue(firstActivated)

        // NSCursor.currentSystem is a post-release observation, not a local
        // ownership oracle. A local application may legitimately choose an
        // appearance different from the pre-remote snapshot.
        presenter.setLocalAppearanceObservationResult(false)
        capture.release(reason: .normalReturn)

        let firstReturnedLocal = await waitUntil {
            machine.state == .localActive
        }
        XCTAssertTrue(firstReturnedLocal)
        XCTAssertEqual(firstLease.releaseCount, 1)
        XCTAssertFalse(capture.isSuppressed)
        XCTAssertNil(
            controller
                .controlAdmissionStateForTesting()
                .captureGeneration
        )

        // Regression for the physical failure: a false appearance observation
        // after successful helper/CoreHID cleanup must not pin the old
        // generation and block the next DeX handoff.
        machine.pointerAtEdge(.left)
        machine.flushCallbacks()

        let secondPending = await waitUntil {
            backend.hasPendingAcquisition
        }
        XCTAssertTrue(
            secondPending,
            "post-return appearance mismatch must not poison re-entry"
        )

        let secondLease = FakeHostPointerLease(generation: 8905)
        backend.succeed(with: secondLease)
        let secondActivated = await waitUntil {
            controller.hasActiveHostPointerLeaseForTesting(
                generation: secondLease.generation
            )
        }
        XCTAssertTrue(secondActivated)
        XCTAssertTrue(capture.isSuppressed)

        presenter.setLocalAppearanceObservationResult(true)
        controller.emergencyReturn()
        XCTAssertEqual(secondLease.releaseCount, 1)
        XCTAssertFalse(capture.isSuppressed)
        XCTAssertEqual(machine.state, .localActive)
    }

    @MainActor
    func testEmergencyReturnRetainsOwnershipUntilPhysicalReleaseSucceeds() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let acquisitionStarted = await waitUntil { backend.hasStarted }
        XCTAssertTrue(acquisitionStarted)

        let lease = FakeHostPointerLease(generation: 891)
        backend.succeed(with: lease)
        let leasePublished = await waitUntil {
            context.controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            )
        }
        XCTAssertTrue(leasePublished)

        lease.setReleaseSucceeds(false)
        context.controller.emergencyReturn()

        XCTAssertEqual(
            context.machine.state,
            .remoteActive,
            "physical release failure must not publish .returning or .localActive"
        )
        XCTAssertTrue(
            context.capture.isSuppressed,
            "capture generation must remain available for an emergency retry"
        )
        XCTAssertEqual(lease.releaseCount, 1)

        lease.setReleaseSucceeds(true)
        context.controller.emergencyReturn()

        let returnedLocal = await waitUntil {
            context.machine.state == .localActive
        }
        XCTAssertTrue(returnedLocal)
        XCTAssertFalse(context.capture.isSuppressed)
        XCTAssertEqual(lease.releaseCount, 2)
    }

    @MainActor
    func testHeldHostInputBlocksAcquisitionAndReturnsLocal() async {
        let backend = FakeHostPointerBackend()
        let capture = InputCapture(pointerRestoreOverride: {})
        let localKeyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        )!
        XCTAssertNotNil(
            capture.handleForTesting(type: .keyDown, event: localKeyDown)
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
    func testLateAcquisitionFailedPhysicalReleaseDoesNotRetryInBackground() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        context.controller.emergencyReturn()
        XCTAssertEqual(context.machine.state, .localActive)
        XCTAssertFalse(context.capture.isSuppressed)

        let lateLease = FakeHostPointerLease(generation: 109)
        lateLease.setReleaseSucceeds(false)
        backend.succeed(with: lateLease)

        let releaseAttempted = await waitUntil {
            lateLease.releaseCount == 1
        }
        XCTAssertTrue(releaseAttempted)
        XCTAssertTrue(
            lateLease.isActive,
            "failed unpublished release remains fail-closed"
        )

        // The production CoreHID lease makes a failed physical proof terminal
        // for this process generation. Changing the fake result later must not
        // cause an unowned background retry loop.
        lateLease.setReleaseSucceeds(true)
        try? await Task.sleep(for: .milliseconds(650))

        XCTAssertEqual(lateLease.releaseCount, 1)
        XCTAssertTrue(lateLease.isActive)
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
    func testPhysicalEmergencyChordPathReleasesPublishedLease() async {
        let backend = FakeHostPointerBackend()
        let context = makeController(backend: backend)

        await enterRemote(context.machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        let generation = try! XCTUnwrap(
            context.controller.controlAdmissionStateForTesting().captureGeneration
        )
        let lease = FakeHostPointerLease(generation: 205)
        backend.succeed(with: lease)

        let ready = await waitUntil {
            context.controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            ) && context.capture.isExternalPointerOwnerActive(
                generation: generation
            )
        }
        XCTAssertTrue(ready)

        let chord = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 7, // kVK_ANSI_X
            keyDown: true
        )!
        chord.flags = [.maskCommand, .maskShift]

        // This exercises the actual InputCapture keyboard handler rather than
        // calling controller.emergencyReturn() directly.
        XCTAssertNil(
            context.capture.handleForTesting(type: .keyDown, event: chord)
        )
        XCTAssertEqual(lease.releaseCount, 1)
        XCTAssertFalse(context.capture.isSuppressed)

        let returnedLocal = await waitUntil {
            context.machine.state == .localActive
        }
        XCTAssertTrue(returnedLocal)
    }

    @MainActor
    func testBackendFailureJoinsOrderedHostReturnBeforeCoreHIDRelease() async {
        let backend = FakeHostPointerBackend()
        let presenter = FakeRemoteCursorPresenter()
        let capture = InputCapture()
        let machine = EdgeSwitchStateMachine()
        let sender = InputSender(session: SessionReference())
        let controller = ControlHandoffController(
            sender: sender,
            capture: capture,
            switchMachine: machine,
            hostPointerBackend: backend,
            remoteCursorPresenter: presenter
        )

        await enterRemote(machine)
        let started = await waitUntil { backend.hasStarted }
        XCTAssertTrue(started)

        let generation = try! XCTUnwrap(
            controller.controlAdmissionStateForTesting().captureGeneration
        )
        let keyboardWasLocalAtLeaseRelease = BoolObservation()
        let lease = FakeHostPointerLease(
            generation: 102,
            onRelease: {
                keyboardWasLocalAtLeaseRelease.set(
                    !capture.isExternalPointerOwnerActive(
                        generation: generation
                    )
                )
            }
        )
        backend.succeed(with: lease)

        let admitted = await waitUntil {
            controller.hasActiveHostPointerLeaseForTesting(
                generation: lease.generation
            ) && presenter.presentedEdges == [.left]
        }
        XCTAssertTrue(admitted)
        XCTAssertTrue(capture.isSuppressed)

        let restoreGate = DispatchSemaphore(value: 0)
        presenter.setRestoreGate(restoreGate)
        let failureReturned = BoolObservation()

        DispatchQueue.global(qos: .userInitiated).async {
            backend.failActiveLease()
            failureReturned.set(true)
        }

        let restoreStarted = await waitUntil {
            presenter.restoreStartedCount == 1
        }
        XCTAssertTrue(restoreStarted)
        XCTAssertEqual(
            lease.releaseCount,
            0,
            "backend failure must not release CoreHID before cursor cleanup"
        )
        XCTAssertFalse(
            failureReturned.value,
            "backend failure caller must remain inside the shared return transaction"
        )
        XCTAssertEqual(machine.state, .remoteActive)

        restoreGate.signal()

        let returnedLocal = await waitUntil {
            machine.state == .localActive
                && !capture.isSuppressed
                && failureReturned.value
        }
        XCTAssertTrue(returnedLocal)
        XCTAssertEqual(presenter.effectiveRestoreCount, 1)
        XCTAssertEqual(lease.releaseCount, 1)
        XCTAssertTrue(keyboardWasLocalAtLeaseRelease.value)
    }
}
