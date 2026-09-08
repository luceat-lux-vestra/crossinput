import Foundation
import InputCapture
import EdgeSwitch
import Diagnostics
import Delivery

/// Thin composition boundary between capture and the control-handoff machine.
/// It owns pointer safety and movement accounting, but has no session or ADB
/// vocabulary. Session failures arrive as `remoteUnavailable()`.
final class ControlHandoffController: @unchecked Sendable {
    let capture: InputCapture
    let switchMachine: EdgeSwitchStateMachine

    var onStateChange: ((ControlState) -> Void)?

    private let sender: InputSender
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
    /// Monotonic clock used for the return re-entry guard. Injectable so the
    /// boundary can be proved without sleeping in deterministic tests.
    private let monotonicNow: @Sendable () -> TimeInterval
    /// Controller-level ownership gate: once return begins, no edge callback
    /// may reacquire remote control during this interval. InputCapture keeps
    /// its existing cooldown/leave-zone gate; this closes the orchestration
    /// boundary before local suppression is released (issue #96 evidence).
    private var edgeReentryBlockedUntil: TimeInterval = 0
    private static let edgeReentryCooldown: TimeInterval = 0.5

    init(sender: InputSender,
         capture: InputCapture = InputCapture(),
         switchMachine: EdgeSwitchStateMachine = EdgeSwitchStateMachine(),
         monotonicNow: @escaping @Sendable () -> TimeInterval = {
             ProcessInfo.processInfo.systemUptime
         }) {
        self.sender = sender
        self.capture = capture
        self.switchMachine = switchMachine
        self.monotonicNow = monotonicNow

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
            // watchdog fired (issue #50). A return that has already begun also
            // owns a short controller-level no-reacquire interval so a return
            // event cannot create a fresh suppression generation (issue #96).
            guard let self, self.canAcquireEdgeSwitch, self.sender.hasLiveConnection else { return }
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
            Task { @MainActor in
                guard let self, generation == self.currentSuppressionGeneration else { return }
                // Controller-initiated returns move the state machine local
                // before InputCapture publishes this callback. Do not extend
                // the return gate again from that delayed callback. Only a
                // capture-initiated release (watchdog/takeover/etc.) still
                // leaves the machine owning the remote epoch here.
                guard self.isRemoteOwnedState else { return }
                self.armEdgeReentryGate()
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

    @MainActor
    private func endControlEpoch(stopCapture: Bool) {
        // Release while the session reference is still live so held keys and
        // buttons get their best-effort cleanup before the caller tears down
        // the transport.
        lifecycleLock.withLock {
            lifecycleStarted = true
            edgeSwitchEnabled = false
            controlEpoch &+= 1
            activeSuppressionGeneration = nil
            // An event callback that wins this lock before Disable is admitted
            // before the generation barrier and is cancelled below. Anything
            // after the barrier sees the disabled gate and cannot be forwarded.
            sender.cancelPendingPointerEvents()
        }

        // Deactivate before releasing suppression so an edge callback already
        // queued in the state machine cannot create a new remote epoch. The
        // deactivation transition itself remains observable; older callbacks
        // are invalidated by the sequence gate.
        let deactivation = switchMachine.deactivate()
        if let deactivation {
            transitionGate.advance(to: deactivation.sequence &- 1)
        } else {
            transitionGate.advance(to: switchMachine.latestSequence)
        }

        capture.release(reason: .captureStopped)
        sender.waitForDrain()
        sender.releaseRemotelyHeldButtonsAndWait()
        if stopCapture { capture.stop() }
    }

    func emergencyReturn() {
        if isRemoteOwnedState { armEdgeReentryGate() }
        sender.cancelPendingPointerEvents()
        switchMachine.forceReturn()
    }

    func remoteUnavailable() {
        if isRemoteOwnedState { armEdgeReentryGate() }
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

    private var isRemoteOwnedState: Bool {
        switch switchMachine.state {
        case .edgeArmed, .remoteActive:
            return true
        case .disabled, .localActive, .returning:
            return false
        }
    }

    /// Edge acquisition is stricter than the public enabled flag: during the
    /// bounded return window the old local-return epoch still owns the edge,
    /// so even a live session cannot create a new remote generation.
    private var canAcquireEdgeSwitch: Bool {
        let now = monotonicNow()
        return lifecycleLock.withLock {
            let enabled = edgeSwitchEnabled || (!lifecycleStarted && switchMachine.state != .disabled)
            return enabled && now >= edgeReentryBlockedUntil
        }
    }

    private func armEdgeReentryGate() {
        let blockedUntil = monotonicNow() + Self.edgeReentryCooldown
        lifecycleLock.withLock {
            // A repeated return notification may extend the guard but must
            // never shorten an already-active guard.
            edgeReentryBlockedUntil = max(edgeReentryBlockedUntil, blockedUntil)
        }
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
        if isRemoteOwnedState { armEdgeReentryGate() }
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
            if switchMachine.state == .localActive {
                // pointerMoved performs its state mutation synchronously while
                // capture is still suppressed. Arm before queued transition
                // callbacks can release local suppression.
                armEdgeReentryGate()
            }
        case let .partiallyDeliveredMovement(requestedDx, requestedDy, deliveredDx, deliveredDy):
            switchMachine.pointerMoved(requestedDx: CGFloat(requestedDx),
                                       requestedDy: CGFloat(requestedDy),
                                       deliveredDx: CGFloat(deliveredDx),
                                       deliveredDy: CGFloat(deliveredDy))
            armEdgeReentryGate()
            sender.cancelPendingPointerEvents()
            switchMachine.forceReturn(reason: .remoteUnavailable)
        case .cancelled:
            recordCancelledDelivery()
        case .delivered:
            capture.pokeWatchdog()
            logUsableSessionOnce()
        case .failed:
            // A helper-side failure is a control-oriented availability loss;
            // the state machine does not need to know whether ADB, UHID, or
            // InputManager was the underlying cause.
            armEdgeReentryGate()
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

    private func apply(state: HandoffState, reason: TransitionReason) {
        switch state {
        case .remoteActive:
            guard isEdgeSwitchEnabled else {
                sender.cancelPendingPointerEvents()
                capture.release(reason: .captureStopped)
                return
            }
            // The usable-session confirmation is exactly-once per entry:
            // cleared here so the first confirmed delivery after re-entering
            // arms a fresh marker (issue #68).
            usableSessionLogged = false
            guard let generation = capture.suppress() else {
                // Suppression never became observable, so no return-path
                // pointer mutation or synthetic move occurred. Preserve the
                // existing immediate-retry contract instead of inventing a
                // cooldown for an epoch that never acquired cursor ownership.
                switchMachine.forceReturn(reason: .remoteUnavailable)
                return
            }
            currentSuppressionGeneration = generation
            lifecycleLock.withLock { activeSuppressionGeneration = generation }
        case .localActive, .returning, .disabled:
            // Lifecycle invariant (issue #62 code-gate): when local suppression
            // ends for ANY reason — normal boundary return, remote failure,
            // emergency return, takeover, disable — the pending-pointer
            // barrier is armed (cancels queued and in-flight deliveries so a
            // late completion from session A can never credit session B with a
            // usable-session marker or stale movement) and no button
            // previously accepted by the helper may stay held remotely. Best
            // effort and session-generation-scoped; external-control takeovers
            // arrive here via the same transition after InputCapture's
            // synchronous onPointerStateReset.
            if capture.isSuppressed {
                // Critical ordering: while capture is still suppressing, edge
                // callbacks cannot be emitted. Arm the controller gate before
                // release makes local input observable or posts a synthetic
                // return move. This is the last-resort ordering invariant even
                // if queued returning/localActive callbacks are reordered.
                armEdgeReentryGate()
            }
            lifecycleLock.withLock {
                controlEpoch &+= 1
                activeSuppressionGeneration = nil
            }
            sender.cancelPendingPointerEvents()
            sender.releaseRemotelyHeldButtons()
            capture.release(reason: releaseReason(for: reason))
        case .edgeArmed:
            break
        }
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
