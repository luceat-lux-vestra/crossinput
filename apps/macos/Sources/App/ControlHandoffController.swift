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

    init(sender: InputSender,
         capture: InputCapture = InputCapture(),
         switchMachine: EdgeSwitchStateMachine = EdgeSwitchStateMachine()) {
        self.sender = sender
        self.capture = capture
        self.switchMachine = switchMachine

        switchMachine.onStateChange = { [weak self] transition in
            Task { @MainActor in
                guard let self, self.transitionGate.shouldApply(transition) else { return }
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
            guard let self, self.sender.hasLiveConnection else { return }
            self.switchMachine.pointerAtEdge(edge)
        }
        capture.onPointerEvent = { [weak self] event in
            self?.enqueue(event)
        }
        capture.onKeyEvent = { [weak self] event in
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
                self.switchMachine.forceReturn(reason: self.transitionReason(for: reason))
            }
        }
    }

    func enable() -> Bool {
        guard capture.start() else { return false }
        switchMachine.activate()
        return true
    }

    func disable() {
        // Release while the session reference is still live so held keys and
        // buttons get their best-effort cleanup before the caller tears down
        // the transport.
        sender.cancelPendingPointerEvents()
        capture.release(reason: .captureStopped)
        sender.waitForDrain()
        switchMachine.deactivate()
        capture.stop()
    }

    func emergencyReturn() {
        sender.cancelPendingPointerEvents()
        switchMachine.forceReturn()
    }

    func remoteUnavailable() {
        sender.cancelPendingPointerEvents()
        switchMachine.forceReturn(reason: .remoteUnavailable)
    }

    func applyEdgeConfig(_ apply: (InputCapture) -> Void) {
        apply(capture)
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
        let outcome = sender.enqueuePointer(event) { [weak self] result in
            Task { @MainActor in
                self?.apply(delivery: result)
            }
        }
        guard outcome == .safetyRejected else { return }
        Task { @MainActor in
            self.handleButtonSafetyRejection()
        }
    }

    private func handleButtonSafetyRejection() {
        sender.cancelPendingPointerEvents()
        // A rejected button transition means remote button state can no longer
        // be trusted: release whatever was previously accepted by the helper
        // before treating cleanup as complete (best effort, generation-safe).
        sender.releaseRemotelyHeldButtons()
        switchMachine.forceReturn(reason: .remoteUnavailable)
    }

    private func apply(delivery: PointerDeliveryResult) {
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
        case let .partiallyDeliveredMovement(requestedDx, requestedDy, deliveredDx, deliveredDy):
            switchMachine.pointerMoved(requestedDx: CGFloat(requestedDx),
                                       requestedDy: CGFloat(requestedDy),
                                       deliveredDx: CGFloat(deliveredDx),
                                       deliveredDy: CGFloat(deliveredDy))
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
            // The usable-session confirmation is exactly-once per entry:
            // cleared here so the first confirmed delivery after re-entering
            // arms a fresh marker (issue #68).
            usableSessionLogged = false
            if let generation = capture.suppress() {
                currentSuppressionGeneration = generation
            }
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
        case .localActive, .disabled: return .local
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
}
