import Foundation
import Diagnostics

public enum HandoffState: String, Sendable, Hashable {
    case disabled
    case localActive
    case edgeArmed
    case remoteActive
    case returning
}

/// Compatibility name for clients and fixtures from the pre-rebaseline edge
/// machine. New application code uses `ControlState` and `HandoffState`.
public typealias SwitchState = HandoffState

/// Compatibility spellings retained so the large safety regression suite can
/// migrate independently from the behavior-preserving state rename.
public extension HandoffState {
    @available(*, deprecated, renamed: "localActive")
    static var macActive: Self { .localActive }

    @available(*, deprecated, renamed: "remoteActive")
    static var dexActive: Self { .remoteActive }

    @available(*, deprecated, renamed: "returning")
    static var recovering: Self { .returning }
}

public enum ScreenEdge: String, Sendable, Equatable, CaseIterable {
    case left, right, top, bottom
}

/// Why a state transition happened. The handoff machine records only control
/// and safety causes. External availability causes are translated by the
/// application layer into the control-oriented `remoteUnavailable` command.
public enum TransitionReason: String, Sendable {
    case activation
    case edgeEntered
    case boundaryCrossed
    case emergencyReturn
    case watchdogTimeout
    case suppressionReleased
    case externalControlTakeover
    case remoteUnavailable
    case deactivated
}

/// A concrete state transition with a monotonically increasing sequence.
/// Consumers apply transitions in sequence order and discard stale ones
/// (`sequence` lower than the last applied value) so an old remote callback can
/// never re-suppress the capture after a newer failure or return transition.
public struct StateTransition: Sendable, Equatable {
    public let sequence: UInt64
    public let from: HandoffState
    public let to: HandoffState
    public let reason: TransitionReason

    public init(sequence: UInt64, from: HandoffState, to: HandoffState, reason: TransitionReason) {
        self.sequence = sequence
        self.from = from
        self.to = to
        self.reason = reason
    }
}

/// Edge Switch state machine.
///
/// Flow: disabled -> localActive; pointer reaches a screen edge -> edgeArmed ->
/// remoteActive (pointer captured by the device); the pointer moving back
/// across the entry edge and beyond the return hysteresis, an emergency
/// shortcut, or a remote-unavailable fail-safe command brings control back to
/// macOS. External lifecycle is deliberately outside this type.
///
/// Movement model: while the remote target owns the pointer, movement is tracked along a
/// virtual axis perpendicular to the entry edge. Position 0 is the entry
/// boundary; positive positions are inside the remote target; negative positions are
/// beyond the boundary toward macOS. macOS only regains control once the
/// position reaches `-returnHysteresis` — the pointer must actually cross the
/// boundary it entered through and keep going, so brief wobbles and orthogonal
/// movement never trigger an accidental return.
///
/// Return-direction movement is credited by *requested* intent rather than by
/// the amount the helper reports as accepted (issue #45): a helper whose
/// cursor rests against a display bound clamps relative movement and reports
/// zero accepted movement for a pull-back it fully absorbed. Crediting only
/// accepted movement would pin the virtual axis at the boundary forever while
/// delivery acknowledgements keep resetting the fail-safe watchdog — the
/// permanent-trap signature. The user's intent cannot be absorbed by that
/// clamp.
///
/// Direction conventions (verified against the CGEvent delta conventions on
/// device: deltaX positive = right, deltaY positive = down):
/// - left edge:    moving left  (dx < 0) goes inside  -> delta = -dx
/// - right edge:   moving right (dx > 0) goes inside  -> delta = dx
/// - top edge:     moving up    (dy < 0) goes inside  -> delta = -dy
/// - bottom edge:  moving down  (dy > 0) goes inside  -> delta = dy
///
/// Note: origin/main had the top/bottom cases inverted (a return fired when
/// moving into the remote target). The PR that introduced this model fixed that; see the
/// equivalence table in the ADR.
///
/// First-event rule (issue #37): the first movement event after entering is
/// never treated as a return and is normalized to `max(0, delta)` — warp/
/// synthetic leftover deltas right after capture starts are not deliberate
/// user movement toward macOS, and they must not leave a negative baseline
/// that poisons later decisions. This is the actual fix for the "left edge
/// instantly returns" bug — the accumulator math itself was equivalent to
/// origin/main.
///
/// Concurrency: every public mutation is serialized on an internal queue, and
/// `onStateChange` callbacks are fired outside the queue so a callback that
/// synchronously re-enters the machine cannot deadlock. Each real transition
/// is stamped with a monotonic sequence on the queue; consumers must discard
/// transitions whose sequence is not newer than the last one they applied.
/// Transition reasons are never dropped: a transition that does not change
/// the state fires nothing, every real transition fires exactly once.
public final class EdgeSwitchStateMachine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "crossinput.edge-switch", qos: .userInteractive)
    private let callbackQueue = DispatchQueue(label: "crossinput.edge-switch-callbacks", qos: .userInteractive)
    private var pendingTransitions: [StateTransition] = []
    private var sequenceCounter: UInt64 = 0

    // MARK: - Internal storage (mutated only on the serial queue)

    private var stateStorage: HandoffState = .disabled
    private var entryEdgeStorage: ScreenEdge = .left

    /// Virtual pointer position along the axis perpendicular to the entry edge.
    /// 0 = entry boundary, positive = inside the remote target, negative = beyond the
    /// boundary toward macOS. Return fires only when position <= -returnHysteresis.
    private var virtualAxisPosition: CGFloat = 0

    /// False until the first movement event after entering is accumulated.
    /// The first event never triggers a return (issue #37).
    private var hasReceivedFirstMove = false

    // MARK: - Public configuration (fixed at init, safe to read any time)

    /// Distance the pointer must travel past the entry boundary toward macOS
    /// before control returns (hysteresis against accidental wobble).
    public let returnHysteresis: CGFloat

    /// When enabled, `pointerMoved` logs non-payload movement metadata only
    /// (entry edge, state, and first-event marker) — never raw deltas, key
    /// codes, clipboard contents, or input payloads (AGENTS.md hard rule 4).
    /// Off by default.
    public let isDiagnosticsEnabled: Bool

    public init(returnHysteresis: CGFloat = 60, isDiagnosticsEnabled: Bool = false) {
        self.returnHysteresis = returnHysteresis
        self.isDiagnosticsEnabled = isDiagnosticsEnabled
    }

    // MARK: - Snapshot accessors (queue-protected immutable reads)

    public var state: HandoffState {
        queue.sync { stateStorage }
    }

    /// Edge the pointer used to leave macOS for the remote target.
    public var entryEdge: ScreenEdge {
        queue.sync { entryEdgeStorage }
    }

    /// Latest transition sequence, including transitions whose callbacks have
    /// not completed yet. Lifecycle owners use this to invalidate delayed
    /// callbacks when a control epoch is intentionally ended.
    public var latestSequence: UInt64 {
        queue.sync { sequenceCounter }
    }

    // MARK: - Transition handler
    //
    // Registration is intended to happen before concurrent use begins
    // (documented contract). The handler receives the full transition —
    // sequence, from, to, reason — and is invoked outside the machine queue,
    // so it may re-enter the machine without deadlocking.

    public var onStateChange: (@Sendable (StateTransition) -> Void)?

    // MARK: - Public transitions (serialized)

    public func activate() {
        run {
            guard stateStorage == .disabled else { return }
            transition(to: .localActive, reason: .activation)
        }
    }

    @discardableResult
    public func deactivate() -> StateTransition? {
        var deactivation: StateTransition?
        run {
            virtualAxisPosition = 0
            hasReceivedFirstMove = false
            deactivation = transition(to: .disabled, reason: .deactivated)
        }
        return deactivation
    }

    /// Pointer reached a screen edge while macOS is active.
    public func pointerAtEdge(_ edge: ScreenEdge) {
        run {
            switch stateStorage {
            case .localActive:
                transition(to: .edgeArmed, reason: .edgeEntered)
                entryEdgeStorage = edge
                virtualAxisPosition = 0
                hasReceivedFirstMove = false
                transition(to: .remoteActive, reason: .edgeEntered)
            case .edgeArmed:
                entryEdgeStorage = edge
                virtualAxisPosition = 0
                hasReceivedFirstMove = false
            default: break
            }
        }
    }

    /// Signed movement along the axis perpendicular to the entry edge.
    /// Positive = deeper into the remote target, negative = toward macOS, zero = off-axis.
    public static func androidDirectedDelta(entryEdge: ScreenEdge, dx: CGFloat, dy: CGFloat) -> CGFloat {
        switch entryEdge {
        case .left: return -dx // Remote on the left: moving left goes inside
        case .right: return dx // Remote on the right: moving right goes inside
        case .top: return -dy // Remote above: moving up goes inside
        case .bottom: return dy // Remote below: moving down goes inside
        }
    }

    /// Relative pointer movement while the remote target owns the pointer.
    /// Called with the movement accepted by the semantic input-delivery
    /// boundary, never with raw deltas from a failed send. Legacy spelling:
    /// requested and delivered movement are identical.
    public func pointerMoved(dx: CGFloat, dy: CGFloat) {
        pointerMoved(requestedDx: dx, requestedDy: dy,
                     deliveredDx: dx, deliveredDy: dy)
    }

    /// Relative pointer movement while the remote target owns the pointer,
    /// reported as both the requested batch delta and the delta the helper
    /// confirmed as accepted.
    ///
    /// Return-direction credit uses the full *requested* intent (issue #45):
    /// when the Android cursor is pinned at a display bound in the pull-back
    /// direction, the helper clamps the movement and acknowledges delivery
    /// with zero accepted movement. Intent still accumulates toward
    /// `-returnHysteresis` and fires `boundaryCrossed`, so a blocked pull-back
    /// can never trap the pointer on the remote target. Movement deeper into
    /// the remote target credits only the accepted amount so pushing against
    /// the opposite bound cannot inflate the position.
    ///
    /// A call with no requested and no accepted movement is a complete no-op:
    /// it neither consumes the first-movement exemption nor changes the
    /// virtual position, state, or transition callbacks.
    public func pointerMoved(requestedDx: CGFloat, requestedDy: CGFloat,
                             deliveredDx: CGFloat, deliveredDy: CGFloat) {
        run {
            guard stateStorage == .remoteActive else { return }
            // Zero delivery is not a movement: must not consume the first-event
            // exemption (a failed/empty send should leave the machine untouched).
            guard requestedDx != 0 || requestedDy != 0 || deliveredDx != 0 || deliveredDy != 0 else { return }
            let edge = entryEdgeStorage
            let requestedDelta = Self.androidDirectedDelta(entryEdge: edge, dx: requestedDx, dy: requestedDy)
            let deliveredDelta = Self.androidDirectedDelta(entryEdge: edge, dx: deliveredDx, dy: deliveredDy)
            // Issue #45: return-direction intent is credited in full even when
            // the helper's display-bound clamp absorbed all of it; inward
            // movement only ever advances by what was accepted.
            let delta = requestedDelta < 0 ? requestedDelta : deliveredDelta
            let first = !hasReceivedFirstMove
            hasReceivedFirstMove = true
            if first {
                // The first event after entering is warp/synthetic residual, not
                // deliberate user movement. It never returns control and never
                // leaves a negative baseline that would poison later decisions:
                // clamp to 0 (issue #37).
                virtualAxisPosition = max(0, delta)
            } else {
                virtualAxisPosition += delta
            }
            let position = virtualAxisPosition
            if isDiagnosticsEnabled {
                Diagnostics.log(
                    "edge pointerMoved entry=\(edge.rawValue) state=\(stateStorage.rawValue) "
                        + "movement=received first=\(first) "
                        + "boundaryClamped=\(requestedDelta < 0 && deliveredDelta != requestedDelta)"
                    )
            }
            // The first event after entering never returns (issue #37); leftover
            // warp/synthetic deltas must not bounce the user out of the remote target.
            guard !first else { return }
            if position <= -returnHysteresis {
                returnToMacOS(reason: .boundaryCrossed)
            }
        }
    }

    /// Returns control to macOS for a control-oriented fail-safe reason.
    /// The caller may use this for an external failure, a watchdog, or an
    /// emergency shortcut; the machine does not know the underlying cause.
    public func forceReturn(reason: TransitionReason = .emergencyReturn) {
        run {
            switch stateStorage {
            case .edgeArmed, .remoteActive:
                returnToMacOS(reason: reason)
            default: break
            }
        }
    }

    /// Compatibility spelling for callers that issue an explicit emergency
    /// return. New control code uses `forceReturn(reason:)` so all fail-safe
    /// causes share the same control-oriented boundary.
    public func emergencyReturn(reason: TransitionReason = .emergencyReturn) {
        forceReturn(reason: reason)
    }

    // MARK: - Internal

    /// Serializes `body` on the queue, then fires every transition callback it
    /// queued through the callback queue. Firing on a dedicated serial queue
    /// (a) avoids deadlock when a callback synchronously re-enters the
    /// machine and (b) guarantees callbacks fire in sequence order even when
    /// mutations originate from different threads: transitions are stamped on
    /// the state queue, so their callback order on the FIFO callback queue
    /// matches the sequence numbers.
    private func run(_ body: () -> Void) {
        queue.sync {
            body()
            let transitions = pendingTransitions
            pendingTransitions = []

            guard !transitions.isEmpty else { return }

            // Enqueue while the state queue is still held.
            // This guarantees callback enqueue order matches sequence order.
            callbackQueue.async { [self] in
                for transition in transitions {
                    onStateChange?(transition)
                }
            }
        }
    }

    /// Blocks until every transition callback scheduled so far has been
    /// delivered. Test-only hook (and usable from shutdown paths): because
    /// callbacks are fired asynchronously on the serial callback queue, a
    /// `sync {}` on that queue returns only after all prior work completed.
    public func flushCallbacks() {
        callbackQueue.sync {}
    }

    private func returnToMacOS(reason: TransitionReason) {
        virtualAxisPosition = 0
        hasReceivedFirstMove = false
        transition(to: .returning, reason: reason)
        transition(to: .localActive, reason: reason)
    }

    @discardableResult
    private func transition(to newState: HandoffState, reason: TransitionReason) -> StateTransition? {
        guard newState != stateStorage else { return nil }
        sequenceCounter &+= 1
        let transition = StateTransition(
            sequence: sequenceCounter,
            from: stateStorage,
            to: newState,
            reason: reason
        )
        pendingTransitions.append(transition)
        stateStorage = newState
        return transition
    }
}
