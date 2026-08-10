import Foundation
import InputCapture
import EdgeSwitch
import Diagnostics

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
        capture.onScreenEdge = { [weak switchMachine] edge in
            switchMachine?.pointerAtEdge(edge)
        }
        capture.onPointerEvent = { [weak self] event in
            self?.sender.enqueuePointer(event) { [weak self] result in
                Task { @MainActor in
                    self?.apply(delivery: result)
                }
            }
        }
        capture.onKeyEvent = { [weak self] event in
            self?.sender.enqueueKey(event)
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
        capture.release(reason: .captureStopped)
        sender.waitForDrain()
        switchMachine.deactivate()
        capture.stop()
    }

    func emergencyReturn() {
        switchMachine.forceReturn()
    }

    func remoteUnavailable() {
        switchMachine.forceReturn(reason: .remoteUnavailable)
    }

    func applyEdgeConfig(_ apply: (InputCapture) -> Void) {
        apply(capture)
    }

    private func apply(delivery: PointerDeliveryResult) {
        switch delivery {
        case let .deliveredMovement(dx, dy):
            // The handoff position is credited only with the movement that
            // the helper reported as accepted. Failed writes never advance
            // this state.
            switchMachine.pointerMoved(dx: CGFloat(dx), dy: CGFloat(dy))
        case let .partiallyDeliveredMovement(dx, dy):
            switchMachine.pointerMoved(dx: CGFloat(dx), dy: CGFloat(dy))
            switchMachine.forceReturn(reason: .remoteUnavailable)
        case .delivered:
            break
        case .failed:
            // A helper-side failure is a control-oriented availability loss;
            // the state machine does not need to know whether ADB, UHID, or
            // InputManager was the underlying cause.
            switchMachine.forceReturn(reason: .remoteUnavailable)
        }
    }

    private func apply(state: HandoffState, reason: TransitionReason) {
        switch state {
        case .remoteActive:
            if let generation = capture.suppress() {
                currentSuppressionGeneration = generation
            }
        case .localActive, .returning, .disabled:
            capture.release(reason: releaseReason(for: reason))
        case .edgeArmed:
            break
        }
    }

    private func controlState(for state: HandoffState) -> ControlState {
        switch state {
        case .edgeArmed: return .arming(switchMachine.entryEdge)
        case .remoteActive: return .remote(nil)
        case .returning: return .returning
        case .localActive, .disabled: return .local
        }
    }

    private func releaseReason(for reason: TransitionReason) -> SuppressionReleaseReason {
        switch reason {
        case .watchdogTimeout: return .watchdogTimeout
        case .emergencyReturn: return .emergencyHotkey
        case .remoteUnavailable: return .remoteUnavailable
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
        case .captureStopped: return .deactivated
        case .normalReturn: return .suppressionReleased
        }
    }
}
