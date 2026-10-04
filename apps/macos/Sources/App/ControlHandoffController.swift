import Foundation
import InputCapture
import InputCapability
import EdgeSwitch
import Diagnostics
import Delivery

enum ControlEnableResult: Equatable {
    case enabled
    case alreadyEnabled
    case missingAccessibility
    case missingInputMonitoring
    case captureUnavailable
}

final class HostPointerLeaseSlot: @unchecked Sendable {
    private struct Entry {
        let lease: any HostPointerOwnershipLease
        let captureGeneration: UInt64
    }

    private let lock = NSLock()
    private var pendingCaptureGeneration: UInt64?
    private var entry: Entry?

    /// Reserves the capture generation before asynchronous host acquisition.
    /// A return can invalidate this pending generation before a lease exists.
    func begin(captureGeneration: UInt64) -> Bool {
        lock.withLock {
            guard pendingCaptureGeneration == nil, entry == nil else {
                return false
            }
            pendingCaptureGeneration = captureGeneration
            return true
        }
    }

    func install(
        _ lease: any HostPointerOwnershipLease,
        captureGeneration: UInt64
    ) -> Bool {
        guard lease.isActive else {
            lock.withLock {
                guard pendingCaptureGeneration == captureGeneration,
                      entry == nil else {
                    return
                }
                pendingCaptureGeneration = nil
            }
            return false
        }
        return lock.withLock {
            guard pendingCaptureGeneration == captureGeneration,
                  entry == nil else {
                return false
            }
            pendingCaptureGeneration = nil
            entry = Entry(lease: lease, captureGeneration: captureGeneration)
            return true
        }
    }

    func isCurrent(hostGeneration: UInt64) -> Bool {
        let lease = lock.withLock { entry?.lease }
        guard let lease, lease.generation == hostGeneration else { return false }
        return lease.isActive
    }

    /// Admission-time ownership pair check. The capture generation binds a
    /// CoreHID callback to the exact control epoch that published its lease;
    /// an old host callback cannot become valid merely because a newer lease
    /// is active by the time it reaches the controller.
    func isCurrent(
        hostGeneration: UInt64,
        captureGeneration: UInt64
    ) -> Bool {
        let lease = lock.withLock { () -> (any HostPointerOwnershipLease)? in
            guard let entry,
                  entry.captureGeneration == captureGeneration,
                  entry.lease.generation == hostGeneration else {
                return nil
            }
            return entry.lease
        }
        return lease?.isActive == true
    }

    /// True once a host lease has been published for this exact capture
    /// generation. This is intentionally about publication, not current
    /// `lease.isActive`: an already-failing published lease is still past
    /// the acquisition phase and any CG pointer event must fail local.
    func hasPublishedLease(captureGeneration: UInt64) -> Bool {
        lock.withLock {
            entry?.captureGeneration == captureGeneration
        }
    }

    struct TakenOwnership {
        let captureGeneration: UInt64
        let lease: (any HostPointerOwnershipLease)?
    }

    /// Returns the current ownership without removing it. Physical release
    /// must succeed before the lifecycle owner clears this slot; otherwise the
    /// controller would discard the only generation-scoped evidence handle
    /// while the registry intentionally remains fail-closed.
    func currentOwnership() -> TakenOwnership? {
        lock.withLock {
            guard let captureGeneration =
                    entry?.captureGeneration ?? pendingCaptureGeneration else {
                return nil
            }
            return TakenOwnership(
                captureGeneration: captureGeneration,
                lease: entry?.lease
            )
        }
    }

    func currentOwnership(
        captureGeneration: UInt64
    ) -> TakenOwnership? {
        lock.withLock {
            let pendingMatches =
                pendingCaptureGeneration == captureGeneration
            let entryMatches =
                entry?.captureGeneration == captureGeneration
            guard pendingMatches || entryMatches else { return nil }
            return TakenOwnership(
                captureGeneration: captureGeneration,
                lease: entryMatches ? entry?.lease : nil
            )
        }
    }

    func currentOwnership(
        hostGeneration: UInt64
    ) -> TakenOwnership? {
        lock.withLock {
            guard let entry,
                  entry.lease.generation == hostGeneration else {
                return nil
            }
            return TakenOwnership(
                captureGeneration: entry.captureGeneration,
                lease: entry.lease
            )
        }
    }

    /// Removes the current ownership without unseizing. The lifecycle owner
    /// must withdraw keyboard remote admission before releasing the lease.
    func takeCurrent() -> TakenOwnership? {
        lock.withLock {
            guard let captureGeneration =
                    entry?.captureGeneration ?? pendingCaptureGeneration else {
                return nil
            }
            let lease = entry?.lease
            entry = nil
            pendingCaptureGeneration = nil
            return TakenOwnership(
                captureGeneration: captureGeneration,
                lease: lease
            )
        }
    }

    /// Generation-scoped removal prevents a stale capture callback from
    /// touching a replacement ownership period.
    func take(captureGeneration: UInt64) -> TakenOwnership? {
        lock.withLock {
            let pendingMatches =
                pendingCaptureGeneration == captureGeneration
            let entryMatches =
                entry?.captureGeneration == captureGeneration
            guard pendingMatches || entryMatches else { return nil }

            if pendingMatches {
                pendingCaptureGeneration = nil
            }
            let lease = entryMatches ? entry?.lease : nil
            if entryMatches {
                entry = nil
            }
            return TakenOwnership(
                captureGeneration: captureGeneration,
                lease: lease
            )
        }
    }

    /// Host-generation-scoped removal prevents an old CoreHID failure from
    /// taking a newer lease. The caller owns release ordering.
    func take(hostGeneration: UInt64) -> TakenOwnership? {
        lock.withLock {
            guard let entry,
                  entry.lease.generation == hostGeneration else {
                return nil
            }
            self.entry = nil
            return TakenOwnership(
                captureGeneration: entry.captureGeneration,
                lease: entry.lease
            )
        }
    }
}

private final class HostPointerAcquisitionTaskSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var captureGeneration: UInt64?
    private var task: Task<Void, Never>?

    /// Reserves a generation before the Task is created, closing the race
    /// where local return happens between Task creation and registration.
    func prepare(captureGeneration: UInt64) -> Bool {
        lock.withLock {
            guard self.captureGeneration == nil else { return false }
            self.captureGeneration = captureGeneration
            return true
        }
    }

    /// Returns false if the generation was already cancelled or completed.
    func attach(_ task: Task<Void, Never>, captureGeneration: UInt64) -> Bool {
        lock.withLock {
            guard self.captureGeneration == captureGeneration else {
                return false
            }
            self.task = task
            return true
        }
    }

    func finish(captureGeneration: UInt64) {
        lock.withLock {
            guard self.captureGeneration == captureGeneration else { return }
            self.captureGeneration = nil
            task = nil
        }
    }

    func cancel(captureGeneration: UInt64) {
        let task = lock.withLock { () -> Task<Void, Never>? in
            guard self.captureGeneration == captureGeneration else {
                return nil
            }
            self.captureGeneration = nil
            let task = self.task
            self.task = nil
            return task
        }
        task?.cancel()
    }

    func cancelCurrent() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            captureGeneration = nil
            let task = self.task
            self.task = nil
            return task
        }
        task?.cancel()
    }
}

final class HostPhysicalReleaseAttemptCoordinator: @unchecked Sendable {
    private final class Attempt {
        let generation: UInt64
        private let condition = NSCondition()
        private var result: Bool?

        init(generation: UInt64) {
            self.generation = generation
        }

        func finish(_ result: Bool) {
            condition.lock()
            self.result = result
            condition.broadcast()
            condition.unlock()
        }

        func wait() -> Bool {
            condition.lock()
            while result == nil {
                condition.wait()
            }
            let completed = result ?? false
            condition.unlock()
            return completed
        }
    }

    private let lock = NSLock()
    private var activeAttempt: Attempt?

    /// Coalesces all callers for one host-ownership generation onto the same
    /// synchronous release attempt. A different generation can never join an
    /// in-flight attempt; that would violate the registry ownership invariant.
    @discardableResult
    func perform(
        generation: UInt64,
        operation: () -> Bool
    ) -> Bool {
        let decision = lock.withLock {
            () -> (attempt: Attempt, owner: Bool)? in
            if let activeAttempt {
                guard activeAttempt.generation == generation else {
                    return nil
                }
                return (activeAttempt, false)
            }
            let attempt = Attempt(generation: generation)
            activeAttempt = attempt
            return (attempt, true)
        }

        guard let decision else {
            return false
        }
        if !decision.owner {
            return decision.attempt.wait()
        }

        let result = operation()
        decision.attempt.finish(result)
        lock.withLock {
            if activeAttempt === decision.attempt {
                activeAttempt = nil
            }
        }
        return result
    }
}

final class HostReturnAttemptCoordinator: @unchecked Sendable {
    private final class Attempt {
        let captureGeneration: UInt64
        private let condition = NSCondition()
        private var result: Bool?

        init(captureGeneration: UInt64) {
            self.captureGeneration = captureGeneration
        }

        func finish(_ result: Bool) {
            condition.lock()
            self.result = result
            condition.broadcast()
            condition.unlock()
        }

        func wait() -> Bool {
            condition.lock()
            while result == nil {
                condition.wait()
            }
            let completed = result ?? false
            condition.unlock()
            return completed
        }
    }

    private enum Decision {
        case owner(Attempt)
        case join(Attempt)
        case standalone
        case reject
    }

    private let lock = NSLock()
    private var activeAttempt: Attempt?

    /// Coalesces the complete host-return transaction for one capture
    /// generation. A caller that arrives after admissions/lease state has been
    /// cleared may still join the in-flight attempt with a nil generation;
    /// a concrete different generation is never allowed to join.
    @discardableResult
    func perform(
        captureGeneration: UInt64?,
        operation: () -> Bool
    ) -> Bool {
        let decision = lock.withLock { () -> Decision in
            if let activeAttempt {
                if let captureGeneration,
                   captureGeneration != activeAttempt.captureGeneration {
                    return .reject
                }
                return .join(activeAttempt)
            }

            guard let captureGeneration else {
                return .standalone
            }
            let attempt = Attempt(captureGeneration: captureGeneration)
            activeAttempt = attempt
            return .owner(attempt)
        }

        switch decision {
        case .reject:
            return false
        case .standalone:
            return operation()
        case .join(let attempt):
            return attempt.wait()
        case .owner(let attempt):
            let result = operation()
            attempt.finish(result)
            lock.withLock {
                if activeAttempt === attempt {
                    activeAttempt = nil
                }
            }
            return result
        }
    }
}

/// Thin composition boundary between capture and the control-handoff machine.
/// It owns pointer safety and movement accounting, but has no session or ADB
/// vocabulary. Session failures arrive as `remoteUnavailable()`.
final class ControlHandoffController: @unchecked Sendable {
    let capture: InputCapture
    let switchMachine: EdgeSwitchStateMachine

    var onStateChange: ((ControlState) -> Void)?

    private let sender: InputSender
    private let boundaryWatch: any BoundaryWatchServicing
    private let capabilityController: InputCapabilityController
    private let captureStart: @MainActor () -> Bool
    private let captureStop: @MainActor () -> Void
    private let hostPointerBackend: (any HostPointerOwnershipBackend)?
    private let remoteCursorPresenter: any RemoteCursorPresenting
    private let useEventTapNoWarp: Bool
    private let hostPointerLeaseSlot = HostPointerLeaseSlot()
    private let hostPointerAcquisitionTaskSlot = HostPointerAcquisitionTaskSlot()
    private let hostPhysicalReleaseAttemptCoordinator =
        HostPhysicalReleaseAttemptCoordinator()
    private let hostReturnAttemptCoordinator =
        HostReturnAttemptCoordinator()
    private var transitionGate = TransitionSequenceGate()
    /// Serializes the control enable gate with capture callbacks. A callback
    /// already admitted before Disable is invalidated by the pointer
    /// generation; callbacks arriving after Disable are rejected locally.
    private let lifecycleLock = NSLock()
    private var edgeSwitchEnabled = false
    private var lifecycleStarted = false
    private var controlEpoch: UInt64 = 0
    private var activeSuppressionGeneration: UInt64?
    private var selectedRemoteTargetID: UInt32?
    private var boundaryTokenCounter: UInt64 = 0
    private var pendingBoundaryToken: UInt64?
    private var activeBoundaryWatch: PreparedBoundaryWatch?
    private var boundaryReturnIntentActive = false
    /// Emergency return is a fail-safe escape, not an invitation to re-enter
    /// the same remote edge from residual drag/movement. Keep handoff blocked
    /// until a listening-mode move is observed back into the local display.
    private var emergencyReentryBlocked = false

    @MainActor
    init(
        sender: InputSender,
        boundaryWatch: any BoundaryWatchServicing =
            UnavailableBoundaryWatchService(),
        capture: InputCapture = InputCapture(),
        switchMachine: EdgeSwitchStateMachine = EdgeSwitchStateMachine(),
        capabilityController: InputCapabilityController = InputCapabilityController(),
        captureStart: (@MainActor () -> Bool)? = nil,
        captureStop: (@MainActor () -> Void)? = nil,
        hostPointerBackend: (any HostPointerOwnershipBackend)? = nil,
        remoteCursorPresenter: any RemoteCursorPresenting =
            NativeRemoteCursorPresenter(),
        useEventTapNoWarp: Bool = false
    ) {
        self.sender = sender
        self.boundaryWatch = boundaryWatch
        self.capture = capture
        self.switchMachine = switchMachine
        self.capabilityController = capabilityController
        self.captureStart = captureStart ?? { capture.startTrusted() }
        self.captureStop = captureStop ?? { capture.stop() }
        self.hostPointerBackend = hostPointerBackend
        self.remoteCursorPresenter = remoteCursorPresenter
        self.useEventTapNoWarp = useEventTapNoWarp

        switchMachine.onStateChange = { [weak self] transition in
            Task { @MainActor in
                guard let self, self.transitionGate.shouldApply(transition) else { return }
                guard transition.to != .remoteActive || self.isEdgeSwitchEnabled else { return }
                Diagnostics.log("handoff transition \(transition.from.rawValue) -> \(transition.to.rawValue) reason=\(transition.reason.rawValue) sequence=\(transition.sequence)")
                self.onStateChange?(self.controlState(for: transition.to))
                self.apply(state: transition.to, reason: transition.reason)
            }
        }
        capture.onScreenEdge = { [weak self] edge in
            // A dead session must never re-arm handoff. After a fail-safe
            // return the pointer can rest on the configured edge; entering
            // remoteActive with no live transport trapped the user until the
            // watchdog fired (issue #50).
            guard let self,
                  self.isEdgeSwitchEnabled,
                  self.sender.isHandoffReady,
                  !self.lifecycleLock.withLock({
                      self.emergencyReentryBlocked
                  }) else {
                return
            }
            self.switchMachine.pointerAtEdge(
                edge,
                requiresPreparation: true
            )
        }
        capture.onListeningPointerMove = { [weak self] dx, dy in
            self?.handleListeningPointerMove(dx: dx, dy: dy)
        }
        capture.onPointerEvent = { [weak self] event in
            self?.enqueue(event)
        }
        capture.onPointerEventWithGeneration = { [weak self] event, generation in
            self?.enqueue(event, suppressionGeneration: generation)
        }
        capture.onKeyEvent = { [weak self] event in
            self?.enqueue(key: event)
        }
        capture.onKeyEventWithGeneration = { [weak self] event, generation in
            self?.enqueue(key: event, suppressionGeneration: generation)
        }
        capture.onCleanupKeyEvent = { [weak self] event in
            // InputCapture invokes this only for synthesized key-up cleanup.
            // It intentionally bypasses the ordinary enabled gate, but stays
            // inside the current session until the caller drains the queue.
            self?.sender.enqueueKey(event)
        }
        capture.onPointerStateReset = { [weak self] in
            // InputCapture invokes this synchronously after queuing held-key
            // releases. Schedule remote cleanup without delaying the external
            // controller's triggering event or local pointer recovery.
            self?.sender.resetCapturedInputState()
        }
        capture.onExternalPointerOwnerActivity = {
            [weak self] generation, activity in
            self?.handleExternalPointerOwnerActivity(
                captureGeneration: generation,
                activity: activity
            )
        }
        capture.onEmergencyReturnRequested = { [weak self] in
            // This must bypass capture/state assumptions. The emergency chord
            // is the last-resort local-control primitive and therefore asks
            // the lifecycle owner to drop any current/pending host ownership.
            self?.emergencyReturn()
        }
        capture.onSuppressionReleased = { [weak self] reason, generation in
            guard let self else { return }

            // Controller-originated capture.release() runs synchronously inside
            // the already-owned return transaction after admissions and the
            // lease slot have been cleared. Do not recursively join that same
            // transaction from its callback thread. A genuinely
            // capture-originated release still owns either the admission epoch
            // or its generation-scoped lease/pending slot and therefore enters
            // the shared whole-return coordinator below.
            let ownsReturnBoundary =
                self.lifecycleLock.withLock {
                    self.activeSuppressionGeneration == generation
                }
                || self.hostPointerLeaseSlot.currentOwnership(
                    captureGeneration: generation
                ) != nil
            guard ownsReturnBoundary else { return }

            let released = self.releaseHostOwnershipAndCapture(
                reason: reason,
                captureGeneration: generation,
                captureAlreadyReleased: true
            )
            self.sender.cancelPendingPointerEvents()
            guard released else {
                Diagnostics.log(
                    "capture-originated return blocked "
                        + "reason=host-return-unproven "
                        + "captureGeneration=\(generation)"
                )
                return
            }

            Task { @MainActor in
                self.switchMachine.forceReturn(
                    reason: self.transitionReason(for: reason)
                )
            }
        }
    }

    @MainActor
    func enable() -> ControlEnableResult {
        guard !isEdgeSwitchEnabled else { return .alreadyEnabled }

        let capabilities = capabilityController.refresh()
        guard capabilities.accessibilityGranted else {
            return .missingAccessibility
        }

        guard captureStart() else {
            let afterFailure = capabilityController.refresh()
            if !afterFailure.inputMonitoringGranted {
                return .missingInputMonitoring
            }
            return .captureUnavailable
        }

        lifecycleLock.withLock {
            lifecycleStarted = true
            edgeSwitchEnabled = true
            emergencyReentryBlocked = false
        }
        switchMachine.activate()
        return .enabled
    }

    /// Capability loss is a local host-control failure, never a Session
    /// failure. Tear down host ownership and capture/control while leaving the
    /// Android Session and selected Target untouched for a fresh retry.
    @MainActor
    func inputCapabilityLost() {
        if isEdgeSwitchEnabled || capture.isSuppressed {
            endControlEpoch(stopCapture: true)
            return
        }

        // Edge Switch may already be disabled while a stale listening event
        // tap remains installed. Fail closed across the whole host-ownership
        // boundary as well: an inconsistent pending acquisition or published
        // lease must not survive a TCC capability change merely because the
        // presentation gate was already disabled.
        let released = releaseHostOwnershipAndCapture(
            reason: .captureStopped
        )
        sender.cancelPendingPointerEvents()
        guard released else { return }
        captureStop()
    }

    /// Disables only edge-switch acquisition. The capture tap remains
    /// installed in listening mode and the current session/target stay alive.
    @MainActor
    func disableEdgeSwitch() {
        endControlEpoch(stopCapture: false)
    }

    /// Stops macOS capture after releasing remote input. The session layer
    /// calls this before it tears down the helper so cleanup remains attached
    /// to the old session generation.
    @MainActor
    func disable() {
        endControlEpoch(stopCapture: true)
    }

    /// Invalidates the active capture/control admission epoch before local
    /// ownership is released. This is the ordering barrier for callbacks that
    /// were already in flight: pointer work is cancelled and queued keyboard
    /// delivery guards observe a newer control epoch.
    private func invalidateControlAdmissionsGeneration(
        captureGeneration expectedGeneration: UInt64? = nil
    ) -> UInt64? {
        let generation: UInt64? = lifecycleLock.withLock {
            if let expectedGeneration,
               activeSuppressionGeneration != expectedGeneration {
                return nil
            }
            guard let generation = activeSuppressionGeneration else {
                return nil
            }
            activeSuppressionGeneration = nil
            controlEpoch &+= 1
            return generation
        }

        // Pointer cancellation invokes dropped-batch completions synchronously.
        // Keep it outside lifecycleLock so those callbacks can safely observe
        // the newly advanced epoch without recursively acquiring this NSLock.
        if generation != nil {
            sender.cancelPendingPointerEvents()
        }
        return generation
    }

    @discardableResult
    private func invalidateControlAdmissions(
        captureGeneration expectedGeneration: UInt64? = nil
    ) -> Bool {
        invalidateControlAdmissionsGeneration(
            captureGeneration: expectedGeneration
        ) != nil
    }

    /// An acquired lease can lose the publication race after CoreHID has
    /// already seized the device. Release it exactly once through the same
    /// physical proof gate used by published ownership. A failed proof is
    /// terminal for this in-process generation: the CoreHID registry remains
    /// reserved and blocks replacement seizure until process restart instead
    /// of spawning a retry loop that cannot change terminal release state.
    private func releaseUnpublishedLease(
        _ lease: any HostPointerOwnershipLease,
        context: String
    ) {
        let released = lease.release()
        Diagnostics.log(
            context
                + " hostGeneration=\(lease.generation) "
                + "physical=\(released)"
        )
        if !released {
            Diagnostics.log(
                context
                    + " hostGeneration=\(lease.generation) "
                    + "terminal=true action=registry-held"
            )
        }
    }

    @discardableResult
    private func releasePublishedLease(
        _ lease: any HostPointerOwnershipLease,
        context: String
    ) -> Bool {
        let released = hostPhysicalReleaseAttemptCoordinator.perform(
            generation: lease.generation
        ) {
            lease.release()
        }
        Diagnostics.log(
            context
                + " hostGeneration=\(lease.generation) "
                + "physical=\(released)"
        )
        return released
    }

    /// Releases the exact published/pending ownership generation without
    /// discarding its generation-scoped evidence before physical proof succeeds.
    @discardableResult
    private func releaseOwnershipIfPresent(
        captureGeneration: UInt64,
        context: String
    ) -> Bool {
        guard let ownership = hostPointerLeaseSlot.currentOwnership(
            captureGeneration: captureGeneration
        ) else {
            return true
        }

        if let lease = ownership.lease {
            let released = releasePublishedLease(
                lease,
                context: context
            )
            guard released else {
                Diagnostics.log(
                    context
                        + " blocked reason=corehid-still-owned "
                        + "hostGeneration=\(lease.generation)"
                )
                return false
            }
            _ = hostPointerLeaseSlot.take(
                hostGeneration: lease.generation
            )
        } else {
            _ = hostPointerLeaseSlot.take(
                captureGeneration: captureGeneration
            )
        }
        return true
    }

    /// Returns the exact capture generation that currently owns (or is
    /// acquiring) host control. Once the owner has cleared those slots, a
    /// concurrent caller may pass nil to HostReturnAttemptCoordinator and join
    /// the still-published in-flight attempt.
    private func currentHostReturnGeneration() -> UInt64? {
        let lifecycleGeneration = lifecycleLock.withLock {
            activeSuppressionGeneration
        }
        return lifecycleGeneration
            ?? hostPointerLeaseSlot.currentOwnership()?.captureGeneration
    }

    /// Synchronous local-return gate shared by every controller-originated
    /// return path and by capture-originated release callbacks. The complete
    /// cursor cleanup -> admission -> keyboard -> CoreHID -> post-release
    /// cursor observation -> capture transaction is coalesced per capture generation.
    @discardableResult
    private func releaseHostOwnershipAndCapture(
        reason: SuppressionReleaseReason,
        captureGeneration expectedCaptureGeneration: UInt64? = nil,
        captureAlreadyReleased: Bool = false
    ) -> Bool {
        let returnGeneration =
            expectedCaptureGeneration ?? currentHostReturnGeneration()

        return hostReturnAttemptCoordinator.perform(
            captureGeneration: returnGeneration
        ) {
            self.performHostReturn(
                reason: reason,
                expectedCaptureGeneration: expectedCaptureGeneration,
                captureAlreadyReleased: captureAlreadyReleased
            )
        }
    }

    private func performHostReturn(
        reason: SuppressionReleaseReason,
        expectedCaptureGeneration: UInt64?,
        captureAlreadyReleased: Bool
    ) -> Bool {
        Diagnostics.log(
            "host return phase=requested reason=\(String(describing: reason)) "
                + "captureGeneration="
                + (expectedCaptureGeneration.map { String($0) } ?? "current")
        )

        // Cursor presentation is part of the same capture epoch. Cleanup must
        // complete (or be explicitly reported unproven) before CoreHID release
        // can begin. The post-CoreHID visible-cursor oracle is evaluated later,
        // at the boundary where the system can actually converge.
        let cursorCleanupSucceeded = remoteCursorPresenter.restoreLocal()
        Diagnostics.log(
            "host return phase=cursor-cleanup-completed success="
                + "\(cursorCleanupSucceeded)"
        )

        let lifecycleGeneration: UInt64?
        if let expectedCaptureGeneration {
            let invalidated = invalidateControlAdmissions(
                captureGeneration: expectedCaptureGeneration
            )
            lifecycleGeneration =
                invalidated ? expectedCaptureGeneration : nil
        } else {
            lifecycleGeneration = invalidateControlAdmissionsGeneration()
        }
        Diagnostics.log(
            "host return phase=admissions-invalidated captureGeneration="
                + (lifecycleGeneration.map { String($0) } ?? "none")
        )

        if let expectedCaptureGeneration {
            hostPointerAcquisitionTaskSlot.cancel(
                captureGeneration: expectedCaptureGeneration
            )
        } else {
            hostPointerAcquisitionTaskSlot.cancelCurrent()
        }
        Diagnostics.log("host return phase=acquisition-cancelled")

        // Keep the generation slot until cursor-helper cleanup and physical
        // CoreHID release are proven. A post-release NSCursor appearance sample
        // is diagnostic only: the local UI may legitimately choose a cursor
        // different from the pre-remote snapshot.
        let ownership: HostPointerLeaseSlot.TakenOwnership?
        if let expectedCaptureGeneration {
            ownership = hostPointerLeaseSlot.currentOwnership(
                captureGeneration: expectedCaptureGeneration
            )
        } else {
            ownership = hostPointerLeaseSlot.currentOwnership()
        }
        let captureGeneration =
            lifecycleGeneration
            ?? ownership?.captureGeneration
            ?? (captureAlreadyReleased ? expectedCaptureGeneration : nil)

        // Keyboard must be local before the seizing CoreHID client is dropped.
        if let captureGeneration {
            Diagnostics.log(
                "host return phase=keyboard-local-requested captureGeneration=\(captureGeneration)"
            )
            let deactivated = capture.deactivateExternalPointerOwner(
                generation: captureGeneration
            )
            Diagnostics.log(
                "host return phase=keyboard-local-completed captureGeneration=\(captureGeneration) "
                    + "accepted=\(deactivated)"
            )
        }

        if let lease = ownership?.lease {
            Diagnostics.log(
                "host return phase=corehid-release-requested hostGeneration=\(lease.generation)"
            )
            let released = releasePublishedLease(
                lease,
                context: "host return phase=corehid-release-completed"
            )
            guard released else {
                Diagnostics.log(
                    "host return phase=blocked reason=corehid-still-owned "
                        + "hostGeneration=\(lease.generation)"
                )
                return false
            }
        } else if ownership == nil {
            Diagnostics.log(
                "host return phase=corehid-release-skipped reason=no-active-lease"
            )
        }

        // The helper cleanup result is the presentation-ownership proof: the
        // helper removed cursor ownership, disabled its private background
        // authority, and exited before CoreHID release. NSCursor.currentSystem
        // after physical release is still useful telemetry, but exact equality
        // with a pre-remote TIFF snapshot is not a sound ownership oracle: the
        // local application under the pointer may legitimately select a
        // different native cursor.
        let cursorAppearanceRestored = remoteCursorPresenter.observeLocalAppearanceRestored()
        Diagnostics.log(
            "host return phase=cursor-local-observation-completed restored="
                + "\(cursorAppearanceRestored)"
        )
        guard cursorCleanupSucceeded else {
            Diagnostics.log(
                "host return phase=blocked reason=cursor-cleanup-unproven"
            )
            return false
        }

        if let lease = ownership?.lease {
            _ = hostPointerLeaseSlot.take(
                hostGeneration: lease.generation
            )
        } else if let ownership {
            _ = hostPointerLeaseSlot.take(
                captureGeneration: ownership.captureGeneration
            )
        }

        if let captureGeneration, !captureAlreadyReleased {
            Diagnostics.log(
                "host return phase=capture-release-requested captureGeneration=\(captureGeneration)"
            )
            capture.release(reason: reason, generation: captureGeneration)
            Diagnostics.log(
                "host return phase=capture-release-completed captureGeneration=\(captureGeneration)"
            )
        } else if captureAlreadyReleased {
            Diagnostics.log(
                "host return phase=capture-release-skipped reason=already-released"
            )
        }

        if captureGeneration != nil {
            sender.releaseRemotelyHeldButtons()
        }

        return true
    }

    @MainActor
    private func endControlEpoch(stopCapture: Bool) {
        // Close the enable gate first. Keep the active capture generation
        // intact until releaseHostOwnershipAndCapture() has withdrawn remote
        // keyboard admission and dropped the matching CoreHID lease.
        lifecycleLock.withLock {
            lifecycleStarted = true
            edgeSwitchEnabled = false
        }

        retireBoundaryWatch()

        // Host ownership and keyboard suppression return locally before any
        // remote drain/cleanup. Neither may depend on transport progress.
        let released = releaseHostOwnershipAndCapture(
            reason: .captureStopped
        )
        sender.cancelPendingPointerEvents()
        guard released else { return }

        let deactivation = switchMachine.deactivate()
        if let deactivation {
            transitionGate.advance(to: deactivation.sequence &- 1)
        } else {
            transitionGate.advance(to: switchMachine.latestSequence)
        }

        sender.waitForDrain()
        sender.releaseRemotelyHeldButtonsAndWait()
        if stopCapture { captureStop() }
    }

    /// Pointer CGEvents are not a second semantic source while CoreHID owns
    /// the built-in trackpad. During asynchronous acquisition, an ordinary
    /// move that remains pinned to the configured edge is allowed to pass
    /// through so the user can keep pushing outward without corrupting native
    /// cursor tracking. Leaving the edge (or clicking/scrolling) cancels the
    /// acquisition. Once a CoreHID lease has been published, any CG pointer
    /// event is an ownership anomaly and fails local immediately.
    private func handleExternalPointerOwnerActivity(
        captureGeneration: UInt64,
        activity: ExternalPointerOwnerActivity
    ) {
        let ownsGeneration = lifecycleLock.withLock {
            activeSuppressionGeneration == captureGeneration
        }
        guard ownsGeneration, isEdgeSwitchEnabled else { return }

        let leasePublished = hostPointerLeaseSlot.hasPublishedLease(
            captureGeneration: captureGeneration
        )
        guard leasePublished || activity != .edgePinnedPointerMove else {
            return
        }

        Diagnostics.log(
            "external-owner local input phase="
                + (leasePublished ? "owned" : "acquiring")
                + " action=local-return"
        )
        capture.release(
            reason: .externalControl,
            generation: captureGeneration
        )
    }

    @MainActor
    func setAutomaticReturnAuthority(_ authority: AutomaticReturnAuthority) {
        switchMachine.setAutomaticReturnAuthority(authority)
    }

    @MainActor
    func updateRemoteTarget(_ targetID: UInt32?) {
        let previous = lifecycleLock.withLock { () -> UInt32? in
            let previous = selectedRemoteTargetID
            selectedRemoteTargetID = targetID
            return previous
        }
        guard previous != targetID else { return }

        retireBoundaryWatch()
        if switchMachine.state == .edgeArmed ||
            switchMachine.state == .remoteActive {
            let released = releaseHostOwnershipAndCapture(
                reason: .remoteUnavailable
            )
            sender.cancelPendingPointerEvents()
            guard released else { return }
            switchMachine.forceReturn(reason: .remoteUnavailable)
        }
    }

    @MainActor
    func handleBoundarySignal(_ signal: BoundaryWatchSignal) {
        switch signal {
        case let .reached(token, targetID, edge):
            let accepted = lifecycleLock.withLock {
                guard let activeBoundaryWatch,
                      activeBoundaryWatch.mode == .compositor,
                      activeBoundaryWatch.controlToken == token,
                      activeBoundaryWatch.targetID == targetID,
                      selectedRemoteTargetID == targetID,
                      boundaryReturnIntentActive else {
                    return false
                }
                return true
            }
            guard accepted,
                  switchMachine.state == .remoteActive,
                  capture.isSuppressed,
                  edge == Self.remoteReturnEdge(
                      for: switchMachine.entryEdge
                  ) else {
                return
            }

            // Do not publish .returning while CoreHID is still physically
            // seized. Keep the machine remote-owned while the controller holds
            // the internal pending physical-return attempt.
            retireBoundaryWatch()
            let released = releaseHostOwnershipAndCapture(
                reason: .normalReturn
            )
            sender.cancelPendingPointerEvents()
            guard released,
                  switchMachine.beginAuthoritativeBoundaryReturn() else {
                return
            }
            switchMachine.completeReturn(reason: .boundaryCrossed)

        case let .failed(token, _):
            let matches = lifecycleLock.withLock {
                activeBoundaryWatch?.controlToken == token ||
                    pendingBoundaryToken == token
            }
            guard matches else { return }
            retireBoundaryWatch()
            let released = releaseHostOwnershipAndCapture(
                reason: .remoteUnavailable
            )
            sender.cancelPendingPointerEvents()
            guard released else { return }
            switchMachine.forceReturn(reason: .remoteUnavailable)
        }
    }

    private func retireBoundaryWatch() {
        let active = lifecycleLock.withLock {
            pendingBoundaryToken = nil
            boundaryReturnIntentActive = false
            let active = activeBoundaryWatch
            activeBoundaryWatch = nil
            return active
        }
        if let active {
            boundaryWatch.stop(active)
        }
    }

    @MainActor
    private func beginBoundaryPreparation(edge: ScreenEdge) {
        let context = lifecycleLock.withLock {
            () -> (token: UInt64, targetID: UInt32)? in
            guard edgeSwitchEnabled,
                  let targetID = selectedRemoteTargetID else {
                return nil
            }
            boundaryTokenCounter &+= 1
            if boundaryTokenCounter == 0 {
                boundaryTokenCounter = 1
            }
            let token = boundaryTokenCounter
            pendingBoundaryToken = token
            boundaryReturnIntentActive = false
            return (token, targetID)
        }

        guard let context else {
            switchMachine.forceReturn(reason: .remoteUnavailable)
            return
        }

        let returnEdge = Self.remoteReturnEdge(for: edge)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let prepared = try await boundaryWatch.start(
                    controlToken: context.token,
                    targetID: context.targetID,
                    edge: returnEdge
                )
                completeBoundaryPreparation(prepared)
            } catch {
                failBoundaryPreparation(
                    token: context.token,
                    reason: String(describing: error)
                )
            }
        }
    }

    @MainActor
    private func completeBoundaryPreparation(
        _ prepared: PreparedBoundaryWatch
    ) {
        let accepted = lifecycleLock.withLock {
            guard edgeSwitchEnabled,
                  pendingBoundaryToken == prepared.controlToken,
                  selectedRemoteTargetID == prepared.targetID else {
                return false
            }
            pendingBoundaryToken = nil
            activeBoundaryWatch = prepared
            boundaryReturnIntentActive = false
            return true
        }

        guard accepted, switchMachine.state == .edgeArmed else {
            lifecycleLock.withLock {
                if activeBoundaryWatch?.controlToken ==
                    prepared.controlToken {
                    activeBoundaryWatch = nil
                }
            }
            boundaryWatch.stop(prepared)
            return
        }

        Diagnostics.log(
            "boundary watch prepared mode="
                + (prepared.mode == .compositor
                    ? "compositor"
                    : "delivered-coordinates")
                + " target=\(prepared.targetID)"
        )

        guard switchMachine.remotePrepared() else {
            retireBoundaryWatch()
            return
        }
    }

    @MainActor
    private func failBoundaryPreparation(
        token: UInt64,
        reason: String
    ) {
        let stillPending = lifecycleLock.withLock {
            guard pendingBoundaryToken == token else { return false }
            pendingBoundaryToken = nil
            return true
        }
        guard stillPending else { return }
        Diagnostics.log(
            "boundary watch preparation failed reason=\(reason)"
        )
        switchMachine.forceReturn(reason: .remoteUnavailable)
    }

    private func observeBoundaryReturnIntent(_ event: PointerEvent) {
        guard case let .move(dx, dy) = event.kind else { return }
        let directed = EdgeSwitchStateMachine.androidDirectedDelta(
            entryEdge: switchMachine.entryEdge,
            dx: CGFloat(dx),
            dy: CGFloat(dy)
        )
        guard directed > 0 else { return }
        lifecycleLock.withLock {
            guard activeBoundaryWatch?.mode == .compositor else {
                return
            }
            boundaryReturnIntentActive = false
        }
    }

    private func confirmBoundaryReturnIntent(
        requestedDx: Int32,
        requestedDy: Int32
    ) {
        let directed = EdgeSwitchStateMachine.androidDirectedDelta(
            entryEdge: switchMachine.entryEdge,
            dx: CGFloat(requestedDx),
            dy: CGFloat(requestedDy)
        )
        guard directed != 0 else { return }
        lifecycleLock.withLock {
            guard activeBoundaryWatch?.mode == .compositor else {
                return
            }
            boundaryReturnIntentActive = directed < 0
        }
    }

    private func handleListeningPointerMove(
        dx: Int32,
        dy: Int32
    ) {
        let entryEdge = switchMachine.entryEdge
        let directed = EdgeSwitchStateMachine.androidDirectedDelta(
            entryEdge: entryEdge,
            dx: CGFloat(dx),
            dy: CGFloat(dy)
        )
        let releasedEmergencyLatch = lifecycleLock.withLock {
            guard switchMachine.state == .localActive,
                  emergencyReentryBlocked,
                  directed < 0 else {
                return false
            }
            emergencyReentryBlocked = false
            return true
        }
        if releasedEmergencyLatch {
            Diagnostics.log(
                "emergency reentry latch released reason=local-direction-move"
            )
        }

        cancelBoundaryPreparationIfMovingAway(dx: dx, dy: dy)
    }

    private func cancelBoundaryPreparationIfMovingAway(
        dx: Int32,
        dy: Int32
    ) {
        guard switchMachine.state == .edgeArmed else { return }
        let directed = EdgeSwitchStateMachine.androidDirectedDelta(
            entryEdge: switchMachine.entryEdge,
            dx: CGFloat(dx),
            dy: CGFloat(dy)
        )
        guard directed < 0 else { return }

        let cancellation = lifecycleLock.withLock {
            () -> (cancelled: Bool, active: PreparedBoundaryWatch?) in
            guard pendingBoundaryToken != nil ||
                    activeBoundaryWatch != nil else {
                return (false, nil)
            }
            pendingBoundaryToken = nil
            boundaryReturnIntentActive = false
            let active = activeBoundaryWatch
            activeBoundaryWatch = nil
            return (true, active)
        }
        if let active = cancellation.active {
            boundaryWatch.stop(active)
        }
        if cancellation.cancelled {
            switchMachine.cancelEdgePreparation()
        }
    }

    private static func remoteReturnEdge(
        for hostEntryEdge: ScreenEdge
    ) -> RemoteBoundaryEdge {
        switch hostEntryEdge {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    func emergencyReturn() {
        Diagnostics.log("emergency return phase=controller-requested")
        let state = switchMachine.state
        if state == .edgeArmed || state == .remoteActive {
            lifecycleLock.withLock {
                emergencyReentryBlocked = true
            }
            Diagnostics.log(
                "emergency reentry latch armed state=\(state.rawValue)"
            )
        }
        // Emergency return is fail-safe only; ordinary product return is the
        // authoritative remote-boundary path.
        retireBoundaryWatch()
        let released = releaseHostOwnershipAndCapture(
            reason: .emergencyHotkey
        )
        sender.cancelPendingPointerEvents()
        guard released else {
            Diagnostics.log(
                "emergency return phase=blocked reason=corehid-still-owned"
            )
            return
        }
        Diagnostics.log("emergency return phase=state-return-requested")
        switchMachine.forceReturn()
    }

    func remoteUnavailable() {
        retireBoundaryWatch()
        let released = releaseHostOwnershipAndCapture(
            reason: .remoteUnavailable
        )
        sender.cancelPendingPointerEvents()
        guard released else { return }
        switchMachine.forceReturn(reason: .remoteUnavailable)
    }

    func applyEdgeConfig(_ apply: (InputCapture) -> Void) {
        apply(capture)
    }

    var isEdgeSwitchEnabled: Bool {
        lifecycleLock.withLock {
            edgeSwitchEnabled || (!lifecycleStarted && switchMachine.state != .disabled)
        }
    }

    func isEmergencyReentryBlockedForTesting() -> Bool {
        lifecycleLock.withLock { emergencyReentryBlocked }
    }

    func hasPublishedHostPointerLeaseForTesting(
        generation: UInt64
    ) -> Bool {
        hostPointerLeaseSlot.isCurrent(hostGeneration: generation)
    }

    func hasActiveHostPointerLeaseForTesting(
        generation: UInt64
    ) -> Bool {
        guard hostPointerLeaseSlot.isCurrent(hostGeneration: generation),
              let captureGeneration = lifecycleLock.withLock({
                  activeSuppressionGeneration
              }) else {
            return false
        }
        return capture.isExternalPointerOwnerActive(
            generation: captureGeneration
        )
    }

    func controlAdmissionStateForTesting()
        -> (epoch: UInt64, captureGeneration: UInt64?) {
        lifecycleLock.withLock {
            (controlEpoch, activeSuppressionGeneration)
        }
    }
    /// Production capture→sender wiring: one captured event, one admission
    /// decision, and — only when the event became a new batch owner — one
    /// delivery completion applied synchronously on the delivery queue so a
    /// terminal result closes admission before the next batch can execute.
    ///
    /// Admission decisions never masquerade as remote results (ADR-0011):
    /// - shed additive samples are silent lossy degradation;
    /// - a safety-rejected button transition is a local fail-safe decision,
    ///   handled here with the same control-oriented force-return as a
    ///   genuine remote failure (dropping an ordered button boundary can
    ///   strand remote button state).
    private func enqueue(_ event: PointerEvent) {
        observeBoundaryReturnIntent(event)
        let admission: (outcome: PointerAdmissionOutcome, controlEpoch: UInt64)? = lifecycleLock.withLock {
            guard edgeSwitchEnabled || (!lifecycleStarted && switchMachine.state != .disabled) else { return nil }
            let epoch = controlEpoch
            let movementMode: PointerMovementDeliveryMode =
                activeBoundaryWatch?.mode == .compositor
                    ? .streaming
                    : .acknowledged
            let outcome = sender.enqueuePointer(
                event,
                movementDeliveryMode: movementMode
            ) { [weak self] result in
                self?.apply(delivery: result, controlEpoch: epoch)
            }
            return (outcome, epoch)
        }
        guard let admission, admission.outcome == .safetyRejected else { return }
        handleButtonSafetyRejection(
            controlEpoch: admission.controlEpoch
        )
    }

    private func enqueue(_ event: PointerEvent, suppressionGeneration: UInt64) {
        observeBoundaryReturnIntent(event)
        let admission: (outcome: PointerAdmissionOutcome, controlEpoch: UInt64)? = lifecycleLock.withLock {
            guard edgeSwitchEnabled, activeSuppressionGeneration == suppressionGeneration else { return nil }
            let epoch = controlEpoch
            let movementMode: PointerMovementDeliveryMode =
                activeBoundaryWatch?.mode == .compositor
                    ? .streaming
                    : .acknowledged
            let outcome = sender.enqueuePointer(
                event,
                movementDeliveryMode: movementMode
            ) { [weak self] result in
                self?.apply(delivery: result, controlEpoch: epoch)
            }
            return (outcome, epoch)
        }
        guard let admission, admission.outcome == .safetyRejected else { return }
        handleButtonSafetyRejection(
            controlEpoch: admission.controlEpoch
        )
    }

    private func enqueueHostPointer(
        _ event: PointerEvent,
        hostGeneration: UInt64
    ) {
        observeBoundaryReturnIntent(event)
        let admission: (outcome: PointerAdmissionOutcome, controlEpoch: UInt64)? =
            lifecycleLock.withLock {
                guard edgeSwitchEnabled,
                      let captureGeneration = activeSuppressionGeneration,
                      hostPointerLeaseSlot.isCurrent(
                          hostGeneration: hostGeneration,
                          captureGeneration: captureGeneration
                      ),
                      capture.isExternalPointerOwnerActive(
                          generation: captureGeneration
                      ) else {
                    return nil
                }
                let epoch = controlEpoch
                let movementMode: PointerMovementDeliveryMode =
                    activeBoundaryWatch?.mode == .compositor
                        ? .streaming
                        : .acknowledged
                let outcome = sender.enqueuePointer(
                    event,
                    movementDeliveryMode: movementMode
                ) { [weak self] result in
                    self?.apply(delivery: result, controlEpoch: epoch)
                }
                return (outcome, epoch)
            }

        guard let admission, admission.outcome == .safetyRejected else { return }
        handleButtonSafetyRejection(
            controlEpoch: admission.controlEpoch
        )
    }

    private func enqueue(key event: CapturedKeyEvent) {
        lifecycleLock.withLock {
            guard edgeSwitchEnabled || (!lifecycleStarted && switchMachine.state != .disabled) else { return }
            let epoch = controlEpoch
            sender.enqueueKey(
                event,
                deliveryGuard: { [weak self] in
                    guard let self else { return false }
                    return self.isControlEpochCurrent(epoch)
                        && self.isEdgeSwitchEnabled
                        && self.capture.isSuppressed
                },
                completion: { [weak self] result in
                    self?.handleKeyDelivery(
                        result,
                        controlEpoch: epoch
                    )
                }
            )
        }
    }

    private func enqueue(key event: CapturedKeyEvent, suppressionGeneration: UInt64) {
        lifecycleLock.withLock {
            guard edgeSwitchEnabled, activeSuppressionGeneration == suppressionGeneration else { return }
            let epoch = controlEpoch
            sender.enqueueKey(
                event,
                deliveryGuard: { [weak self] in
                    guard let self else { return false }
                    return self.isControlEpochCurrent(epoch)
                        && self.isEdgeSwitchEnabled
                        && self.capture.isSuppressed
                },
                completion: { [weak self] result in
                    self?.handleKeyDelivery(
                        result,
                        controlEpoch: epoch
                    )
                }
            )
        }
    }

    private func handleButtonSafetyRejection(controlEpoch: UInt64) {
        guard isControlEpochCurrent(controlEpoch), isEdgeSwitchEnabled else { return }
        let released = releaseHostOwnershipAndCapture(
            reason: .remoteUnavailable
        )
        sender.cancelPendingPointerEvents()
        guard released else { return }
        // A rejected button transition means remote button state can no longer
        // be trusted: release whatever was previously accepted by the helper
        // before treating cleanup as complete (best effort, generation-safe).
        sender.releaseRemotelyHeldButtons()
        switchMachine.forceReturn(reason: .remoteUnavailable)
    }

    private func apply(delivery: PointerDeliveryResult, controlEpoch: UInt64) {
        guard isControlEpochCurrent(controlEpoch), isEdgeSwitchEnabled, capture.isSuppressed else { return }
        switch delivery {
        case let .submittedMovement(requestedDx, requestedDy):
            // Compositor-authoritative DeX movement is intentionally not
            // stalled on one POINTER_RESULT RTT per trackpad batch. A
            // successful local write keeps the watchdog alive; Android's
            // active boundary watch remains the fail-local authority if the
            // UHID route changes or becomes unavailable.
            capture.pokeWatchdog()
            confirmBoundaryReturnIntent(
                requestedDx: requestedDx,
                requestedDy: requestedDy
            )

        case let .deliveredMovement(
            requestedDx,
            requestedDy,
            deliveredDx,
            deliveredDy
        ):
            // Confirmed acceptance proves the delivery pipeline is live; keep
            // the fail-safe watchdog from expiring during long sessions.
            capture.pokeWatchdog()
            logUsableSessionOnce()

            let boundaryMode = lifecycleLock.withLock {
                activeBoundaryWatch?.mode
            }
            if boundaryMode == .compositor {
                // Relative UHID deltas are return intent only. The Android
                // compositor remains the sole screen-boundary authority.
                confirmBoundaryReturnIntent(
                    requestedDx: requestedDx,
                    requestedDy: requestedDy
                )
                return
            }

            // Explicit-coordinate routes retain the existing delivered
            // movement authority. Native host ownership is still released
            // before localActive is published.
            let returnPrepared =
                switchMachine.prepareBoundaryReturnIfNeeded(
                    requestedDx: CGFloat(requestedDx),
                    requestedDy: CGFloat(requestedDy),
                    deliveredDx: CGFloat(deliveredDx),
                    deliveredDy: CGFloat(deliveredDy)
                )
            if returnPrepared {
                let released = releaseHostOwnershipAndCapture(
                    reason: .normalReturn
                )
                sender.cancelPendingPointerEvents()
                guard released,
                      switchMachine.beginAuthoritativeBoundaryReturn() else {
                    return
                }
                switchMachine.completeReturn(reason: .boundaryCrossed)
            }
        case .partiallyDeliveredMovement:
            // Partial delivery is a remote-availability failure, not a valid
            // normal-boundary observation. Fail local before publishing state.
            let released = releaseHostOwnershipAndCapture(
                reason: .remoteUnavailable
            )
            sender.cancelPendingPointerEvents()
            guard released else { return }
            switchMachine.forceReturn(reason: .remoteUnavailable)
        case .cancelled:
            recordCancelledDelivery()
        case .delivered:
            capture.pokeWatchdog()
            logUsableSessionOnce()
        case .failed:
            // A helper-side failure is a control-oriented availability loss.
            // Restore host ownership synchronously before state-machine/UI work.
            let released = releaseHostOwnershipAndCapture(
                reason: .remoteUnavailable
            )
            sender.cancelPendingPointerEvents()
            guard released else { return }
            switchMachine.forceReturn(reason: .remoteUnavailable)
        }
    }

    private func handleKeyDelivery(
        _ result: KeyDeliveryResult,
        controlEpoch: UInt64
    ) {
        guard isControlEpochCurrent(controlEpoch),
              isEdgeSwitchEnabled,
              capture.isSuppressed else {
            return
        }

        switch result {
        case .delivered:
            // A successful key write is real remote activity, so keep the
            // watchdog alive. Do not emit ADR-0012 pointer-delivery evidence:
            // KEY_EVENT remains fire-and-forget at CXI v1.
            capture.pokeWatchdog()

        case .cancelled:
            break

        case .failed:
            // Close remote admission synchronously on the keyboard delivery
            // queue. Later queued transitions must observe the new epoch
            // before they can reach transport.
            Diagnostics.log(
                "keyboard delivery failed action=local-return"
            )
            let released = releaseHostOwnershipAndCapture(
                reason: .remoteUnavailable
            )
            sender.cancelPendingPointerEvents()
            guard released else { return }
            switchMachine.forceReturn(
                reason: .remoteUnavailable
            )
        }
    }

    /// Logs a single metadata-only confirmation per suppression session that
    /// at least one semantic pointer delivery was accepted by the remote
    /// target. This is the ADR-0012 "usable remote session" evidence for the
    /// Level-3 analyzer: it is backend-neutral (UHID and InputManager both
    /// flow through here) and carries no input payloads. Reset implicitly by
    /// the capture suppression generation on each entry.
    private func logUsableSessionOnce() {
        let shouldLog = deliveryAccountingLock.withLock {
            guard !usableSessionLogged else { return false }
            usableSessionLogged = true
            return true
        }
        if shouldLog {
            Diagnostics.log("handoff usable-session confirmed")
        }
    }

    /// Cancelled deliveries while remoteActive mean the pipeline dropped work
    /// without a failure signal; if that persists, only the watchdog can save
    /// the user, so the burst must leave a metadata-only trace (issue #50).
    /// Rate-limited: one line per window, counts are never input contents.
    private func recordCancelledDelivery() {
        guard capture.isSuppressed else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let countToLog: Int? = deliveryAccountingLock.withLock {
            cancelledDeliveryCount += 1
            guard now - lastCancelledDeliveryLog
                    >= Self.cancelledLogWindow else {
                return nil
            }
            let count = cancelledDeliveryCount
            cancelledDeliveryCount = 0
            lastCancelledDeliveryLog = now
            return count
        }
        if let countToLog {
            Diagnostics.log(
                "pointer deliveries cancelled count=\(countToLog) "
                    + "windowSeconds=\(Int(Self.cancelledLogWindow))"
            )
        }
    }

    private static let cancelledLogWindow: TimeInterval = 5
    private let deliveryAccountingLock = NSLock()
    private var cancelledDeliveryCount = 0
    private var lastCancelledDeliveryLog: TimeInterval = 0
    /// One-shot gate for the ADR-0012 usable-session confirmation line;
    /// cleared on every entry to remoteActive (issue #68).
    private var usableSessionLogged = false

    @MainActor
    private func apply(state: HandoffState, reason: TransitionReason) {
        switch state {
        case .remoteActive:
            if switchMachine.requiresRemotePreparation {
                let prepared = lifecycleLock.withLock {
                    activeBoundaryWatch
                }
                guard prepared != nil else {
                    sender.cancelPendingPointerEvents()
                    switchMachine.forceReturn(
                        reason: .remoteUnavailable
                    )
                    return
                }
            }

            guard isEdgeSwitchEnabled else {
                let released = releaseHostOwnershipAndCapture(
                    reason: .captureStopped
                )
                sender.cancelPendingPointerEvents()
                guard released else { return }
                switchMachine.forceReturn(reason: .deactivated)
                return
            }
            deliveryAccountingLock.withLock {
                usableSessionLogged = false
            }

            if useEventTapNoWarp {
                guard let generation = capture.suppressWithoutWarp() else {
                    sender.cancelPendingPointerEvents()
                    switchMachine.forceReturn(reason: .remoteUnavailable)
                    return
                }
                lifecycleLock.withLock {
                    activeSuppressionGeneration = generation
                }
                Diagnostics.log(
                    "host pointer ownership ready source=event-tap-no-warp "
                        + "captureGeneration=\(generation)"
                )
                return
            }

            if hostPointerBackend == nil {
                // Legacy compatibility seam for regression tests only.
                if let generation = capture.suppress() {
                    lifecycleLock.withLock {
                        activeSuppressionGeneration = generation
                    }
                }
                return
            }

            beginHostPointerAcquisition()

        case .returning:
            // Production return paths may enter .returning only after physical
            // host ownership has already been restored. Never re-enter release
            // from the projection callback for the same generation.
            retireBoundaryWatch()

        case .localActive, .disabled:
            retireBoundaryWatch()
            // Fail-safe projection for direct lifecycle transitions. Normal
            // controller-owned paths have already removed the lease, so this
            // is a no-op there rather than a second physical release attempt.
            let released = releaseHostOwnershipAndCapture(
                reason: releaseReason(for: reason)
            )
            sender.cancelPendingPointerEvents()
            if !released {
                Diagnostics.log(
                    "host return projection blocked reason=corehid-still-owned"
                )
            }

        case .edgeArmed:
            if switchMachine.requiresRemotePreparation {
                beginBoundaryPreparation(
                    edge: switchMachine.entryEdge
                )
            }
        }
    }

    @MainActor
    private func beginHostPointerAcquisition() {
        guard let backend = hostPointerBackend else {
            sender.cancelPendingPointerEvents()
            switchMachine.forceReturn(reason: .remoteUnavailable)
            return
        }

        let epoch = lifecycleLock.withLock { controlEpoch }
        guard let captureGeneration =
                capture.suppressWithExternalPointerOwner() else {
            Diagnostics.log(
                "host pointer acquisition blocked action=local-return"
            )
            sender.cancelPendingPointerEvents()
            switchMachine.forceReturn(reason: .remoteUnavailable)
            return
        }

        lifecycleLock.withLock {
            activeSuppressionGeneration = captureGeneration
        }
        Diagnostics.log(
            "host pointer acquisition started captureGeneration=\(captureGeneration)"
        )

        guard hostPointerLeaseSlot.begin(
            captureGeneration: captureGeneration
        ), hostPointerAcquisitionTaskSlot.prepare(
            captureGeneration: captureGeneration
        ) else {
            // A slot collision means lifecycle state is inconsistent. Do not
            // clean only the new generation and leave a stale seizing lease or
            // acquisition task behind; fail the entire host-ownership boundary
            // local before returning the state machine.
            let released = releaseHostOwnershipAndCapture(
                reason: .remoteUnavailable
            )
            sender.cancelPendingPointerEvents()
            guard released else { return }
            switchMachine.forceReturn(reason: .remoteUnavailable)
            return
        }

        let task = Task { [weak self, backend] in
            guard let self else { return }
            defer {
                self.hostPointerAcquisitionTaskSlot.finish(
                    captureGeneration: captureGeneration
                )
            }

            do {
                try Task.checkCancellation()
                let lease = try await backend.acquire(
                    onEvent: { [weak self] event, generation in
                        self?.enqueueHostPointer(
                            event,
                            hostGeneration: generation
                        )
                    },
                    onFailure: { [weak self] generation in
                        self?.handleHostPointerFailure(
                            hostGeneration: generation,
                            acquisitionEpoch: epoch
                        )
                    }
                )

                do {
                    try Task.checkCancellation()
                } catch {
                    self.releaseUnpublishedLease(
                        lease,
                        context: "cancelled acquisition release"
                    )
                    return
                }

                // Transfer release responsibility before publication. From
                // this point the backend must never self-unseize on monitor
                // failure: Control owns the ordering barrier
                // keyboard-local -> CoreHID release.
                lease.transferReleaseResponsibilityToLifecycleOwner()

                // Publish directly from the acquisition task. This removes the
                // former MainActor gap between successful seizure and a
                // synchronously releasable lease.
                guard self.hostPointerLeaseSlot.install(
                    lease,
                    captureGeneration: captureGeneration
                ) else {
                    self.releaseUnpublishedLease(
                        lease,
                        context: "failed publication release"
                    )

                    // Publication can lose for two different reasons:
                    // local return already invalidated this capture epoch, or
                    // the backend failed after seizure but before publication.
                    // The first case is already safe; the second must return
                    // locally now instead of waiting for the watchdog.
                    let stillOwnsCapture = self.lifecycleLock.withLock {
                        self.activeSuppressionGeneration
                            == captureGeneration
                    }
                    if stillOwnsCapture,
                       self.isControlEpochCurrent(epoch),
                       self.isEdgeSwitchEnabled,
                       self.capture.isSuppressed,
                       self.switchMachine.state == .remoteActive {
                        _ = self.invalidateControlAdmissions(
                            captureGeneration: captureGeneration
                        )
                        self.capture.release(
                            reason: .remoteUnavailable,
                            generation: captureGeneration
                        )
                        self.sender.cancelPendingPointerEvents()
                        self.switchMachine.forceReturn(
                            reason: .remoteUnavailable
                        )
                    }
                    return
                }

                Diagnostics.log(
                    "host pointer lease published captureGeneration=\(captureGeneration) "
                        + "hostGeneration=\(lease.generation)"
                )

                guard lease.isActive,
                      self.isControlEpochCurrent(epoch),
                      self.isEdgeSwitchEnabled,
                      self.capture.isSuppressed,
                      self.lifecycleLock.withLock({
                          self.activeSuppressionGeneration
                              == captureGeneration
                      }),
                      self.switchMachine.state == .remoteActive else {
                    let invalidated = self.invalidateControlAdmissions(
                        captureGeneration: captureGeneration
                    )
                    let physicallyReleased =
                        self.releaseOwnershipIfPresent(
                            captureGeneration: captureGeneration,
                            context: "post-publication validation release"
                        )
                    guard physicallyReleased else { return }
                    self.capture.release(
                        reason: .remoteUnavailable,
                        generation: captureGeneration
                    )
                    if invalidated {
                        self.switchMachine.forceReturn(
                            reason: .remoteUnavailable
                        )
                    }
                    return
                }

                // Cursor presentation is part of the remote-epoch commit,
                // not a best-effort decoration after input admission. CoreHID
                // already owns/fixes the host pointer here, so prove the
                // WindowServer-visible cursor first while keyboard/pointer
                // delivery remains locally inadmissible.
                let cursorReady = await self.remoteCursorPresenter.presentRemote(
                    edge: self.switchMachine.entryEdge,
                    onFailure: { [weak self] in
                        self?.handleRemoteCursorFailure(
                            captureGeneration: captureGeneration,
                            hostGeneration: lease.generation,
                            acquisitionEpoch: epoch
                        )
                    }
                )
                guard cursorReady,
                      lease.isActive,
                      self.isControlEpochCurrent(epoch),
                      self.isEdgeSwitchEnabled,
                      self.capture.isSuppressed,
                      self.hostPointerLeaseSlot.isCurrent(
                          hostGeneration: lease.generation,
                          captureGeneration: captureGeneration
                      ) else {
                    self.handleRemoteCursorFailure(
                        captureGeneration: captureGeneration,
                        hostGeneration: lease.generation,
                        acquisitionEpoch: epoch
                    )
                    return
                }

                // This is the remote-input commit point. No CoreHID pointer
                // event or keyboard transition may be admitted before cursor
                // presentation has independently reached READY.
                guard self.capture.activateExternalPointerOwner(
                    generation: captureGeneration
                ) else {
                    self.handleRemoteCursorFailure(
                        captureGeneration: captureGeneration,
                        hostGeneration: lease.generation,
                        acquisitionEpoch: epoch
                    )
                    return
                }

                Diagnostics.log(
                    "host pointer ownership ready captureGeneration=\(captureGeneration) "
                        + "hostGeneration=\(lease.generation) cursorReady=true "
                        + "inputAdmission=true"
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                Diagnostics.log(
                    "host pointer acquisition failed captureGeneration=\(captureGeneration) "
                        + "errorType=\(String(reflecting: type(of: error)))"
                )

                let invalidated = self.invalidateControlAdmissions(
                    captureGeneration: captureGeneration
                )
                let physicallyReleased =
                    self.releaseOwnershipIfPresent(
                        captureGeneration: captureGeneration,
                        context: "acquisition failure release"
                    )
                guard physicallyReleased else { return }
                self.capture.release(
                    reason: .remoteUnavailable,
                    generation: captureGeneration
                )

                guard invalidated,
                      self.isEdgeSwitchEnabled,
                      self.switchMachine.state == .remoteActive else {
                    return
                }
                self.switchMachine.forceReturn(reason: .remoteUnavailable)
            }
        }

        if !hostPointerAcquisitionTaskSlot.attach(
            task,
            captureGeneration: captureGeneration
        ) {
            // Local return raced Task registration. Cancellation checks in the
            // backend prevent a late acquisition from becoming persistent.
            task.cancel()
        }
    }

    private func handleRemoteCursorFailure(
        captureGeneration: UInt64,
        hostGeneration: UInt64,
        acquisitionEpoch: UInt64
    ) {
        guard isControlEpochCurrent(acquisitionEpoch),
              hostPointerLeaseSlot.isCurrent(
                  hostGeneration: hostGeneration,
                  captureGeneration: captureGeneration
              ),
              lifecycleLock.withLock({
                  activeSuppressionGeneration == captureGeneration
              }) else {
            return
        }

        Diagnostics.log(
            "host cursor presentation failed action=local-return "
                + "captureGeneration=\(captureGeneration) "
                + "hostGeneration=\(hostGeneration)"
        )

        let released = releaseHostOwnershipAndCapture(
            reason: .remoteUnavailable
        )
        sender.cancelPendingPointerEvents()
        guard released,
              switchMachine.state == .remoteActive else {
            return
        }
        switchMachine.forceReturn(reason: .remoteUnavailable)
    }

    private func handleHostPointerFailure(
        hostGeneration: UInt64,
        acquisitionEpoch: UInt64
    ) {
        guard let ownership =
                hostPointerLeaseSlot.currentOwnership(
                    hostGeneration: hostGeneration
                ) else {
            // A failure before lease publication is handled by acquire()
            // returning an inactive lease or throwing.
            return
        }
        let captureGeneration = ownership.captureGeneration
        Diagnostics.log(
            "host pointer lease failure captureGeneration=\(captureGeneration) "
                + "hostGeneration=\(hostGeneration)"
        )

        // A published CoreHID failure may arrive after cursor READY and remote
        // input admission. It therefore owns no bespoke teardown path: join
        // the same generation-scoped cursor -> keyboard -> physical release ->
        // final cursor proof -> capture transaction used by every other return
        // source. This also makes a concurrent emergency/normal return wait on
        // the same result instead of racing past cursor cleanup.
        let belongsToAcquisitionEpoch =
            isControlEpochCurrent(acquisitionEpoch)
        let released = releaseHostOwnershipAndCapture(
            reason: .remoteUnavailable,
            captureGeneration: captureGeneration
        )
        sender.cancelPendingPointerEvents()

        guard released,
              belongsToAcquisitionEpoch,
              isEdgeSwitchEnabled,
              switchMachine.state == .remoteActive else {
            return
        }
        switchMachine.forceReturn(reason: .remoteUnavailable)
    }

    private func controlState(for state: HandoffState) -> ControlState {
        switch state {
        case .edgeArmed: return .arming(switchMachine.entryEdge)
        case .remoteActive: return .remote
        case .returning: return .returning
        case .localActive: return .local
        case .disabled: return .disabled
        }
    }

    private func releaseReason(for reason: TransitionReason) -> SuppressionReleaseReason {
        switch reason {
        case .watchdogTimeout: return .watchdogTimeout
        case .emergencyReturn: return .emergencyHotkey
        case .remoteUnavailable: return .remoteUnavailable
        case .externalControlTakeover: return .externalControl
        case .deactivated: return .captureStopped
        case .boundaryCrossed, .suppressionReleased, .activation,
             .edgeEntered, .edgeExited:
            return .normalReturn
        }
    }

    private func transitionReason(for reason: SuppressionReleaseReason) -> TransitionReason {
        switch reason {
        case .watchdogTimeout: return .watchdogTimeout
        case .emergencyHotkey: return .emergencyReturn
        case .remoteUnavailable: return .remoteUnavailable
        case .externalControl: return .externalControlTakeover
        case .captureStopped: return .deactivated
        case .tapDisabled: return .suppressionReleased
        case .normalReturn: return .suppressionReleased
        }
    }

    private func isControlEpochCurrent(_ epoch: UInt64) -> Bool {
        lifecycleLock.withLock { controlEpoch == epoch }
    }
}
