import Foundation
import InputCapture
import EdgeSwitch
import Diagnostics
import Delivery

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
        guard lease.isActive else { return false }
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

    /// Invalidates pending or active ownership and returns its capture epoch.
    /// Lease release happens outside the lock because it may touch CoreHID.
    @discardableResult
    func releaseCurrent() -> UInt64? {
        let result = lock.withLock {
            let captureGeneration =
                entry?.captureGeneration ?? pendingCaptureGeneration
            let lease = entry?.lease
            entry = nil
            pendingCaptureGeneration = nil
            return (captureGeneration, lease)
        }
        result.1?.release()
        return result.0
    }

    @discardableResult
    func release(captureGeneration: UInt64) -> Bool {
        let result = lock.withLock {
            let pendingMatches =
                pendingCaptureGeneration == captureGeneration
            if pendingMatches {
                pendingCaptureGeneration = nil
            }

            let entryMatches =
                entry?.captureGeneration == captureGeneration
            let lease = entryMatches ? entry?.lease : nil
            if entryMatches {
                entry = nil
            }
            return (pendingMatches || entryMatches, lease)
        }
        result.1?.release()
        return result.0
    }

    /// Releases only the active host generation; stale host failure callbacks
    /// cannot touch a newer lease.
    @discardableResult
    func release(hostGeneration: UInt64) -> UInt64? {
        let result = lock.withLock {
            guard entry?.lease.generation == hostGeneration else {
                return (nil as UInt64?, nil as (any HostPointerOwnershipLease)?)
            }
            let captureGeneration = entry?.captureGeneration
            let lease = entry?.lease
            entry = nil
            return (captureGeneration, lease)
        }
        result.1?.release()
        return result.0
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
    private let hostPointerBackend: (any HostPointerOwnershipBackend)?
    private let hostPointerLeaseSlot = HostPointerLeaseSlot()
    private let hostPointerAcquisitionTaskSlot = HostPointerAcquisitionTaskSlot()
    private var transitionGate = TransitionSequenceGate()
    private var currentSuppressionGeneration: UInt64 = 0
    /// Serializes the control enable gate with capture callbacks. A callback
    /// already admitted before Disable is invalidated by the pointer
    /// generation; callbacks arriving after Disable are rejected locally.
    private let lifecycleLock = NSLock()
    private var edgeSwitchEnabled = false
    private var lifecycleStarted = false
    private var controlEpoch: UInt64 = 0
    private var activeSuppressionGeneration: UInt64?

    init(
        sender: InputSender,
        capture: InputCapture = InputCapture(),
        switchMachine: EdgeSwitchStateMachine = EdgeSwitchStateMachine(),
        hostPointerBackend: (any HostPointerOwnershipBackend)? = nil
    ) {
        self.sender = sender
        self.capture = capture
        self.switchMachine = switchMachine
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
            guard let self, self.isEdgeSwitchEnabled, self.sender.hasLiveConnection else { return }
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
        capture.onSuppressionReleased = { [weak self] reason, generation in
            guard let self else { return }
            // Local pointer ownership must not wait for the main actor.
            // The capture generation pair prevents a stale callback from
            // releasing a newer host-pointer lease.
            self.hostPointerAcquisitionTaskSlot.cancel(
                captureGeneration: generation
            )
            self.hostPointerLeaseSlot.release(captureGeneration: generation)
            Task { @MainActor in
                guard generation == self.currentSuppressionGeneration else { return }
                self.switchMachine.forceReturn(reason: self.transitionReason(for: reason))
            }
        }
    }

    @MainActor
    func enable() -> Bool {
        guard !isEdgeSwitchEnabled else { return true }
        guard capture.start() else { return false }
        lifecycleLock.withLock {
            lifecycleStarted = true
            edgeSwitchEnabled = true
        }
        switchMachine.activate()
        return true
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

    /// Synchronous local-return gate shared by every controller-originated
    /// return path. Pending acquisition is cancelled before an active lease is
    /// dropped; capture release is generation-scoped when possible.
    private func releaseHostOwnershipAndCapture(
        reason: SuppressionReleaseReason
    ) {
        hostPointerAcquisitionTaskSlot.cancelCurrent()
        if let generation = hostPointerLeaseSlot.releaseCurrent() {
            capture.release(reason: reason, generation: generation)
        } else {
            // Legacy compatibility/test seam has no host lease generation.
            capture.release(reason: reason)
        }
    }

    @MainActor
    private func endControlEpoch(stopCapture: Bool) {
        lifecycleLock.withLock {
            lifecycleStarted = true
            edgeSwitchEnabled = false
            controlEpoch &+= 1
            activeSuppressionGeneration = nil
            sender.cancelPendingPointerEvents()
        }

        // Host ownership and keyboard suppression return locally before any
        // remote drain/cleanup. Neither may depend on transport progress.
        releaseHostOwnershipAndCapture(reason: .captureStopped)

        let deactivation = switchMachine.deactivate()
        if let deactivation {
            transitionGate.advance(to: deactivation.sequence &- 1)
        } else {
            transitionGate.advance(to: switchMachine.latestSequence)
        }

        sender.waitForDrain()
        sender.releaseRemotelyHeldButtonsAndWait()
        if stopCapture { capture.stop() }
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
        hostPointerLeaseSlot.isCurrent(hostGeneration: generation)
    }
    /// Production capture→sender wiring: one captured event, one admission
    /// decision, and — only when the event became a new batch owner — one
    /// delivery completion routed to handoff accounting on the main actor.
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
                Task { @MainActor in
                    self?.apply(delivery: result, controlEpoch: epoch)
                }
            }
            return (outcome, epoch)
        }
        guard let admission, admission.outcome == .safetyRejected else { return }
        Task { @MainActor in
            self.handleButtonSafetyRejection(controlEpoch: admission.controlEpoch)
        }
    }

    private func enqueue(_ event: PointerEvent, suppressionGeneration: UInt64) {
        let admission: (outcome: PointerAdmissionOutcome, controlEpoch: UInt64)? = lifecycleLock.withLock {
            guard edgeSwitchEnabled, activeSuppressionGeneration == suppressionGeneration else { return nil }
            let epoch = controlEpoch
            let outcome = sender.enqueuePointer(event) { [weak self] result in
                Task { @MainActor in
                    self?.apply(delivery: result, controlEpoch: epoch)
                }
            }
            return (outcome, epoch)
        }
        guard let admission, admission.outcome == .safetyRejected else { return }
        Task { @MainActor in
            self.handleButtonSafetyRejection(controlEpoch: admission.controlEpoch)
        }
    }

    private func enqueueHostPointer(
        _ event: PointerEvent,
        hostGeneration: UInt64
    ) {
        guard hostPointerLeaseSlot.isCurrent(hostGeneration: hostGeneration) else {
            return
        }

        let admission: (outcome: PointerAdmissionOutcome, controlEpoch: UInt64)? =
            lifecycleLock.withLock {
                guard edgeSwitchEnabled, activeSuppressionGeneration != nil else {
                    return nil
                }
                let epoch = controlEpoch
                let outcome = sender.enqueuePointer(event) { [weak self] result in
                    Task { @MainActor in
                        self?.apply(delivery: result, controlEpoch: epoch)
                    }
                }
                return (outcome, epoch)
            }

        guard let admission, admission.outcome == .safetyRejected else { return }
        Task { @MainActor in
            self.handleButtonSafetyRejection(controlEpoch: admission.controlEpoch)
        }
    }

    private func enqueue(key event: CapturedKeyEvent) {
        lifecycleLock.withLock {
            guard edgeSwitchEnabled || (!lifecycleStarted && switchMachine.state != .disabled) else { return }
            let epoch = controlEpoch
            sender.enqueueKey(event) { [weak self] in
                guard let self else { return false }
                return self.isControlEpochCurrent(epoch) && self.isEdgeSwitchEnabled
            }
        }
    }

    private func enqueue(key event: CapturedKeyEvent, suppressionGeneration: UInt64) {
        lifecycleLock.withLock {
            guard edgeSwitchEnabled, activeSuppressionGeneration == suppressionGeneration else { return }
            let epoch = controlEpoch
            sender.enqueueKey(event) { [weak self] in
                guard let self else { return false }
                return self.isControlEpochCurrent(epoch) && self.isEdgeSwitchEnabled
            }
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

    /// Logs a single metadata-only confirmation per suppression session that
    /// at least one semantic pointer delivery was accepted by the remote
    /// target. This is the ADR-0012 "usable remote session" evidence for the
    /// Level-3 analyzer: it is backend-neutral (UHID and InputManager both
    /// flow through here) and carries no input payloads. Reset implicitly by
    /// the capture suppression generation on each entry.
    private func logUsableSessionOnce() {
        guard !usableSessionLogged else { return }
        usableSessionLogged = true
        Diagnostics.log("handoff usable-session confirmed")
    }

    /// Cancelled deliveries while remoteActive mean the pipeline dropped work
    /// without a failure signal; if that persists, only the watchdog can save
    /// the user, so the burst must leave a metadata-only trace (issue #50).
    /// Rate-limited: one line per window, counts are never input contents.
    private func recordCancelledDelivery() {
        guard capture.isSuppressed else { return }
        cancelledDeliveryCount += 1
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastCancelledDeliveryLog >= Self.cancelledLogWindow else { return }
        let count = cancelledDeliveryCount
        cancelledDeliveryCount = 0
        lastCancelledDeliveryLog = now
        Diagnostics.log("pointer deliveries cancelled count=\(count) windowSeconds=\(Int(Self.cancelledLogWindow))")
    }

    private static let cancelledLogWindow: TimeInterval = 5
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
            usableSessionLogged = false

            if hostPointerBackend == nil {
                // Compatibility seam for the pre-Leap regression suite only.
                // Production AppModel always injects makeDefault(), including
                // an unavailable fail-closed backend on unsupported systems.
                if let generation = capture.suppress() {
                    currentSuppressionGeneration = generation
                    lifecycleLock.withLock {
                        activeSuppressionGeneration = generation
                    }
                }
                return
            }

            beginHostPointerAcquisition()

        case .localActive, .returning, .disabled:
            lifecycleLock.withLock {
                controlEpoch &+= 1
                activeSuppressionGeneration = nil
            }

            // Local-return gate: host ownership first, transport cleanup later.
            releaseHostOwnershipAndCapture(reason: releaseReason(for: reason))
            sender.cancelPendingPointerEvents()
            sender.releaseRemotelyHeldButtons()

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
            sender.cancelPendingPointerEvents()
            switchMachine.forceReturn(reason: .remoteUnavailable)
            return
        }

        currentSuppressionGeneration = captureGeneration
        lifecycleLock.withLock {
            activeSuppressionGeneration = captureGeneration
        }

        guard hostPointerLeaseSlot.begin(
            captureGeneration: captureGeneration
        ), hostPointerAcquisitionTaskSlot.prepare(
            captureGeneration: captureGeneration
        ) else {
            lifecycleLock.withLock { activeSuppressionGeneration = nil }
            hostPointerLeaseSlot.release(captureGeneration: captureGeneration)
            capture.release(
                reason: .remoteUnavailable,
                generation: captureGeneration
            )
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
                        self.lifecycleLock.withLock {
                            if self.activeSuppressionGeneration
                                == captureGeneration {
                                self.activeSuppressionGeneration = nil
                            }
                        }
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

                guard lease.isActive,
                      self.isControlEpochCurrent(epoch),
                      self.isEdgeSwitchEnabled,
                      self.capture.isSuppressed,
                      self.lifecycleLock.withLock({
                          self.activeSuppressionGeneration
                              == captureGeneration
                      }),
                      self.switchMachine.state == .remoteActive else {
                    self.hostPointerLeaseSlot.release(
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
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }

                self.hostPointerLeaseSlot.release(
                    captureGeneration: captureGeneration
                )
                self.capture.release(
                    reason: .remoteUnavailable,
                    generation: captureGeneration
                )

                guard self.isControlEpochCurrent(epoch),
                      self.isEdgeSwitchEnabled,
                      self.switchMachine.state == .remoteActive else {
                    return
                }
                self.sender.cancelPendingPointerEvents()
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
        guard let captureGeneration =
                hostPointerLeaseSlot.release(
                    hostGeneration: hostGeneration
                ) else {
            // A failure before lease publication is handled by acquire()
            // returning an inactive lease or throwing.
            return
        }

        hostPointerAcquisitionTaskSlot.cancel(
            captureGeneration: captureGeneration
        )
        lifecycleLock.withLock {
            if activeSuppressionGeneration == captureGeneration {
                activeSuppressionGeneration = nil
            }
        }
        capture.release(
            reason: .remoteUnavailable,
            generation: captureGeneration
        )

        guard isControlEpochCurrent(acquisitionEpoch),
              isEdgeSwitchEnabled,
              switchMachine.state == .remoteActive else {
            return
        }
        sender.cancelPendingPointerEvents()
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
        case .normalReturn: return .suppressionReleased
        }
    }

    private func isControlEpochCurrent(_ epoch: UInt64) -> Bool {
        lifecycleLock.withLock { controlEpoch == epoch }
    }
}
