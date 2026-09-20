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

/// Thin composition boundary between capture and the control-handoff machine.
/// It owns pointer safety and movement accounting, but has no session or ADB
/// vocabulary. Session failures arrive as `remoteUnavailable()`.
final class ControlHandoffController: @unchecked Sendable {
    let capture: InputCapture
    let switchMachine: EdgeSwitchStateMachine

    var onStateChange: ((ControlState) -> Void)?

    private let sender: InputSender
    private let capabilityController: InputCapabilityController
    private let captureStart: @MainActor () -> Bool
    private let captureStop: @MainActor () -> Void
    private let hostPointerBackend: (any HostPointerOwnershipBackend)?
    private let hostPointerLeaseSlot = HostPointerLeaseSlot()
    private let hostPointerAcquisitionTaskSlot = HostPointerAcquisitionTaskSlot()
    private var transitionGate = TransitionSequenceGate()
    /// Serializes the control enable gate with capture callbacks. A callback
    /// already admitted before Disable is invalidated by the pointer
    /// generation; callbacks arriving after Disable are rejected locally.
    private let lifecycleLock = NSLock()
    private var edgeSwitchEnabled = false
    private var lifecycleStarted = false
    private var controlEpoch: UInt64 = 0
    private var activeSuppressionGeneration: UInt64?

    @MainActor
    init(
        sender: InputSender,
        capture: InputCapture = InputCapture(),
        switchMachine: EdgeSwitchStateMachine = EdgeSwitchStateMachine(),
        capabilityController: InputCapabilityController = InputCapabilityController(),
        captureStart: (@MainActor () -> Bool)? = nil,
        captureStop: (@MainActor () -> Void)? = nil,
        hostPointerBackend: (any HostPointerOwnershipBackend)? = nil
    ) {
        self.sender = sender
        self.capture = capture
        self.switchMachine = switchMachine
        self.capabilityController = capabilityController
        self.captureStart = captureStart ?? { capture.startTrusted() }
        self.captureStop = captureStop ?? { capture.stop() }
        self.hostPointerBackend = hostPointerBackend

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
                  self.sender.isHandoffReady else {
                return
            }
            self.switchMachine.pointerAtEdge(edge)
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
        capture.onSuppressionReleased = { [weak self] reason, generation in
            guard let self else { return }
            // Close admissions synchronously for this exact capture epoch.
            // A stale release callback cannot invalidate a replacement epoch.
            let invalidated = self.invalidateControlAdmissions(
                captureGeneration: generation
            )
            // Local pointer ownership must not wait for the main actor.
            // The capture generation pair prevents a stale callback from
            // releasing a newer host-pointer lease.
            self.hostPointerAcquisitionTaskSlot.cancel(
                captureGeneration: generation
            )
            self.hostPointerLeaseSlot
                .take(captureGeneration: generation)?
                .lease?
                .release()

            // Only a capture-originated release that actually closed the
            // current admission epoch owns the async state-machine return.
            // Controller-originated paths invalidate first and perform their
            // own synchronous/ordered state transition.
            guard invalidated else { return }

            // Remote cleanup is deliberately after host ownership is already
            // local, but it must be scheduled from this exact return boundary.
            // A later MainActor state projection may be superseded by rapid
            // re-entry and therefore cannot be the sole cleanup owner.
            self.sender.releaseRemotelyHeldButtons()

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
        releaseHostOwnershipAndCapture(reason: .captureStopped)
        sender.cancelPendingPointerEvents()
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

    /// Synchronous local-return gate shared by every controller-originated
    /// return path. Admissions are invalidated before pending acquisition is
    /// cancelled and before an active host lease is dropped.
    private func releaseHostOwnershipAndCapture(
        reason: SuppressionReleaseReason
    ) {
        let lifecycleGeneration = invalidateControlAdmissionsGeneration()
        hostPointerAcquisitionTaskSlot.cancelCurrent()

        // Remove publication first, but do not unseize yet. If lifecycle state
        // was already lost, the slot still carries the capture generation.
        let ownership = hostPointerLeaseSlot.takeCurrent()
        let captureGeneration =
            lifecycleGeneration ?? ownership?.captureGeneration

        // Keyboard must be local before the seizing CoreHID client is dropped.
        if let captureGeneration {
            _ = capture.deactivateExternalPointerOwner(
                generation: captureGeneration
            )
        }
        ownership?.lease?.release()

        if let captureGeneration {
            capture.release(reason: reason, generation: captureGeneration)

            // Schedule remote persistent-state cleanup immediately after the
            // synchronous host return. Do not depend on the asynchronous
            // state-machine/UI projection: rapid re-entry can legitimately
            // make an older local transition stale before MainActor applies it.
            sender.releaseRemotelyHeldButtons()
        }
        // No generation means another return path already invalidated this
        // ownership period. Never issue an unscoped release here: a concurrent
        // replacement epoch may already exist by the time this stale caller
        // reaches the capture boundary.

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

        // Host ownership and keyboard suppression return locally before any
        // remote drain/cleanup. Neither may depend on transport progress.
        releaseHostOwnershipAndCapture(reason: .captureStopped)
        sender.cancelPendingPointerEvents()

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

    func emergencyReturn() {
        releaseHostOwnershipAndCapture(reason: .emergencyHotkey)
        sender.cancelPendingPointerEvents()
        switchMachine.forceReturn()
    }

    func remoteUnavailable() {
        releaseHostOwnershipAndCapture(reason: .remoteUnavailable)
        sender.cancelPendingPointerEvents()
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
        let admission: (outcome: PointerAdmissionOutcome, controlEpoch: UInt64)? = lifecycleLock.withLock {
            guard edgeSwitchEnabled || (!lifecycleStarted && switchMachine.state != .disabled) else { return nil }
            let epoch = controlEpoch
            let outcome = sender.enqueuePointer(event) { [weak self] result in
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
        let admission: (outcome: PointerAdmissionOutcome, controlEpoch: UInt64)? = lifecycleLock.withLock {
            guard edgeSwitchEnabled, activeSuppressionGeneration == suppressionGeneration else { return nil }
            let epoch = controlEpoch
            let outcome = sender.enqueuePointer(event) { [weak self] result in
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
                let outcome = sender.enqueuePointer(event) { [weak self] result in
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
        releaseHostOwnershipAndCapture(reason: .remoteUnavailable)
        sender.cancelPendingPointerEvents()
        // A rejected button transition means remote button state can no longer
        // be trusted: release whatever was previously accepted by the helper
        // before treating cleanup as complete (best effort, generation-safe).
        sender.releaseRemotelyHeldButtons()
        switchMachine.forceReturn(reason: .remoteUnavailable)
    }

    private func apply(delivery: PointerDeliveryResult, controlEpoch: UInt64) {
        guard isControlEpochCurrent(controlEpoch), isEdgeSwitchEnabled, capture.isSuppressed else { return }
        switch delivery {
        case let .deliveredMovement(requestedDx, requestedDy, deliveredDx, deliveredDy):
            // Confirmed acceptance proves the delivery pipeline is live; keep
            // the fail-safe watchdog from expiring during long sessions.
            capture.pokeWatchdog()
            logUsableSessionOnce()
            // The handoff position is credited through the machine's intent
            // rule (issue #45): return-direction movement counts even when
            // the helper's display-bound clamp reported zero accepted
            // movement; inward movement only counts what was accepted.
            switchMachine.pointerMoved(requestedDx: CGFloat(requestedDx),
                                       requestedDy: CGFloat(requestedDy),
                                       deliveredDx: CGFloat(deliveredDx),
                                       deliveredDy: CGFloat(deliveredDy))
            if switchMachine.state != .remoteActive {
                // Boundary return is decided synchronously by the machine.
                // Do not wait for its async transition callback to restore
                // native host pointer and keyboard ownership.
                releaseHostOwnershipAndCapture(reason: .normalReturn)
            }
        case let .partiallyDeliveredMovement(requestedDx, requestedDy, deliveredDx, deliveredDy):
            switchMachine.pointerMoved(requestedDx: CGFloat(requestedDx),
                                       requestedDy: CGFloat(requestedDy),
                                       deliveredDx: CGFloat(deliveredDx),
                                       deliveredDy: CGFloat(deliveredDy))
            releaseHostOwnershipAndCapture(reason: .remoteUnavailable)
            sender.cancelPendingPointerEvents()
            switchMachine.forceReturn(reason: .remoteUnavailable)
        case .cancelled:
            recordCancelledDelivery()
        case .delivered:
            capture.pokeWatchdog()
            logUsableSessionOnce()
        case .failed:
            // A helper-side failure is a control-oriented availability loss.
            // Restore host ownership synchronously before state-machine/UI work.
            releaseHostOwnershipAndCapture(reason: .remoteUnavailable)
            sender.cancelPendingPointerEvents()
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
            releaseHostOwnershipAndCapture(
                reason: .remoteUnavailable
            )
            sender.cancelPendingPointerEvents()
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
            guard isEdgeSwitchEnabled else {
                releaseHostOwnershipAndCapture(reason: .captureStopped)
                sender.cancelPendingPointerEvents()
                switchMachine.forceReturn(reason: .deactivated)
                return
            }
            deliveryAccountingLock.withLock {
                usableSessionLogged = false
            }

            if hostPointerBackend == nil {
                // Compatibility seam for the pre-Leap regression suite only.
                // Production AppModel always injects makeDefault(), including
                // an unavailable fail-closed backend on unsupported systems.
                if let generation = capture.suppress() {
                    lifecycleLock.withLock {
                        activeSuppressionGeneration = generation
                    }
                }
                return
            }

            beginHostPointerAcquisition()

        case .localActive, .returning, .disabled:
            // Local-return fallback: preserve the capture generation until
            // remote keyboard admission is withdrawn and the CoreHID lease
            // has been released. Most paths already linearize synchronously;
            // this callback remains the fail-safe owner for direct transitions.
            releaseHostOwnershipAndCapture(reason: releaseReason(for: reason))
            sender.cancelPendingPointerEvents()

        case .edgeArmed:
            break
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
            releaseHostOwnershipAndCapture(reason: .remoteUnavailable)
            sender.cancelPendingPointerEvents()
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
                    lease.release()
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
                    lease.release()

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
                    self.hostPointerLeaseSlot
                        .take(captureGeneration: captureGeneration)?
                        .lease?
                        .release()
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

                guard self.capture.activateExternalPointerOwner(
                    generation: captureGeneration
                ) else {
                    let invalidated = self.invalidateControlAdmissions(
                        captureGeneration: captureGeneration
                    )
                    self.hostPointerLeaseSlot
                        .take(captureGeneration: captureGeneration)?
                        .lease?
                        .release()
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

                Diagnostics.log(
                    "host pointer ownership ready captureGeneration=\(captureGeneration) "
                        + "hostGeneration=\(lease.generation)"
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
                self.hostPointerLeaseSlot
                    .take(captureGeneration: captureGeneration)?
                    .lease?
                    .release()
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

    private func handleHostPointerFailure(
        hostGeneration: UInt64,
        acquisitionEpoch: UInt64
    ) {
        guard let ownership =
                hostPointerLeaseSlot.take(
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

        let belongsToAcquisitionEpoch =
            isControlEpochCurrent(acquisitionEpoch)
        let invalidated = invalidateControlAdmissions(
            captureGeneration: captureGeneration
        )
        hostPointerAcquisitionTaskSlot.cancel(
            captureGeneration: captureGeneration
        )

        // Failure follows the same return linearization as normal paths:
        // keyboard local -> CoreHID unseize -> capture teardown.
        _ = capture.deactivateExternalPointerOwner(
            generation: captureGeneration
        )
        ownership.lease?.release()
        capture.release(
            reason: .remoteUnavailable,
            generation: captureGeneration
        )

        guard belongsToAcquisitionEpoch,
              invalidated,
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
        case .boundaryCrossed, .suppressionReleased, .activation, .edgeEntered:
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
