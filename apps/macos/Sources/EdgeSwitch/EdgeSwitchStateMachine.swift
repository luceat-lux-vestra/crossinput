import Foundation
import Diagnostics

public enum SwitchState: String, Sendable {
    case disabled
    case disconnected
    case connecting
    case macActive
    case edgeArmed
    case dexActive
    case recovering
    case error
}

public enum ScreenEdge: String, Sendable, Equatable {
    case left, right, top, bottom
}

/// Why a state transition happened. Every transition is logged with its
/// reason so on-device traces distinguish an intentional boundary crossing
/// from fail-safe paths (watchdog, hotkey, suppression release, connection
/// loss) — the root-cause questions AGENTS.md verification demands.
public enum TransitionReason: String, Sendable {
    case activation
    case connectionBegan
    case connectionReady
    case connectionLost
    case edgeEntered
    case boundaryCrossed
    case emergencyReturn
    case watchdogTimeout
    case suppressionReleased
    case fatalError
    case deactivated
}

/// Edge Switch state machine.
///
/// Flow: disabled -> disconnected -> connecting -> macActive; pointer reaches a
/// screen edge -> edgeArmed -> dexActive (pointer captured by the device); the
/// pointer moving back across the entry edge and beyond the return hysteresis,
/// the emergency shortcut, or a lost connection brings control back to macOS.
///
/// Movement model: while DeX owns the pointer, movement is tracked along a
/// virtual axis perpendicular to the entry edge. Position 0 is the entry
/// boundary; positive positions are inside Android/DeX; negative positions are
/// beyond the boundary toward macOS. macOS only regains control once the
/// position reaches `-returnHysteresis` — the pointer must actually cross the
/// boundary it entered through and keep going, so brief wobbles and orthogonal
/// movement never trigger an accidental return.
///
/// Direction conventions (verified against the CGEvent delta conventions on
/// device: deltaX positive = right, deltaY positive = down):
/// - left edge:    moving left  (dx < 0) goes inside  -> delta = -dx
/// - right edge:   moving right (dx > 0) goes inside  -> delta = dx
/// - top edge:     moving up    (dy < 0) goes inside  -> delta = -dy
/// - bottom edge:  moving down  (dy > 0) goes inside  -> delta = dy
///
/// Note: origin/main had the top/bottom cases inverted (a return fired when
/// moving INTO DeX). The PR that introduced this model fixed that; see the
/// equivalence table in the ADR.
///
/// First-event rule (issue #37): the first movement event after entering is
/// never treated as a return. Warp/synthetic leftover deltas right after
/// capture starts are not deliberate user movement toward macOS, so they are
/// accumulated into the position but excluded from the return check. This is
/// the actual fix for the "left edge instantly returns" bug — the accumulator
/// math itself was equivalent to origin/main.
public final class EdgeSwitchStateMachine: @unchecked Sendable {
    public private(set) var state: SwitchState = .disabled
    public var onStateChange: (@Sendable (SwitchState, TransitionReason) -> Void)?

    /// Edge the pointer used to leave macOS for DeX.
    public private(set) var entryEdge: ScreenEdge = .left

    private let lock = NSLock()

    /// Virtual pointer position along the axis perpendicular to the entry edge.
    /// 0 = entry boundary, positive = inside Android/DeX, negative = beyond the
    /// boundary toward macOS. Return fires only when position <= -returnHysteresis.
    private var virtualAxisPosition: CGFloat = 0

    /// False until the first movement event after entering is accumulated.
    /// The first event never triggers a return (issue #37).
    private var hasReceivedFirstMove = false

    /// Distance the pointer must travel past the entry boundary toward macOS
    /// before control returns (hysteresis against accidental wobble).
    public var returnHysteresis: CGFloat = 60

    /// When enabled, `pointerMoved` logs movement metadata only (entryEdge, raw
    /// dx/dy, axis delta, virtual position, state) — never key codes, clipboard
    /// contents, or input payloads (AGENTS.md hard rule 4). Off by default.
    public var isDiagnosticsEnabled = false

    public init() {}

    // MARK: - Public transitions

    public func activate() {
        guard state == .disabled else { return }
        transition(to: .disconnected, reason: .activation)
    }

    public func deactivate() {
        lock.withLock {
            virtualAxisPosition = 0
            hasReceivedFirstMove = false
        }
        transition(to: .disabled, reason: .deactivated)
    }

    public func connectionBegan() {
        switch state {
        case .disconnected, .recovering: transition(to: .connecting, reason: .connectionBegan)
        case .macActive: transition(to: .connecting, reason: .connectionBegan)
        default: break
        }
    }

    public func connectionReady() {
        switch state {
        case .connecting, .disconnected, .error: transition(to: .macActive, reason: .connectionReady)
        default: break
        }
    }

    public func connectionLost() {
        switch state {
        case .connecting, .macActive, .edgeArmed, .dexActive, .recovering:
            lock.withLock {
                virtualAxisPosition = 0
                hasReceivedFirstMove = false
            }
            transition(to: .recovering, reason: .connectionLost)
        default: break
        }
    }

    /// Pointer reached a screen edge while macOS is active.
    public func pointerAtEdge(_ edge: ScreenEdge) {
        switch state {
        case .macActive:
            transition(to: .edgeArmed, reason: .edgeEntered)
            entryEdge = edge
            lock.withLock {
                virtualAxisPosition = 0
                hasReceivedFirstMove = false
            }
            transition(to: .dexActive, reason: .edgeEntered)
        case .edgeArmed:
            entryEdge = edge
            lock.withLock {
                virtualAxisPosition = 0
                hasReceivedFirstMove = false
            }
        default: break
        }
    }

    /// Signed movement along the axis perpendicular to the entry edge.
    /// Positive = deeper into Android/DeX, negative = toward macOS, zero = off-axis.
    public static func androidDirectedDelta(entryEdge: ScreenEdge, dx: CGFloat, dy: CGFloat) -> CGFloat {
        switch entryEdge {
        case .left: return -dx // DeX on the left: moving left goes inside
        case .right: return dx // DeX on the right: moving right goes inside
        case .top: return -dy // DeX above: moving up goes inside
        case .bottom: return dy // DeX below: moving down goes inside
        }
    }

    /// Relative pointer movement while DeX owns the pointer.
    public func pointerMoved(dx: CGFloat, dy: CGFloat) {
        guard state == .dexActive else { return }
        let delta = Self.androidDirectedDelta(entryEdge: entryEdge, dx: dx, dy: dy)
        let (position, isFirst) = lock.withLock {
            virtualAxisPosition += delta
            let first = !hasReceivedFirstMove
            hasReceivedFirstMove = true
            return (virtualAxisPosition, first)
        }
        if isDiagnosticsEnabled {
            Diagnostics.log(
                "edge pointerMoved entry=\(entryEdge.rawValue) state=\(state.rawValue) "
                    + "dx=\(dx) dy=\(dy) axisDelta=\(delta) virtualPos=\(position) first=\(isFirst)"
            )
        }
        // The first event after entering never returns (issue #37); leftover
        // warp/synthetic deltas must not bounce the user out of DeX.
        guard !isFirst else { return }
        if position <= -returnHysteresis {
            returnToMacOS(reason: .boundaryCrossed)
        }
    }

    /// Emergency return: always works, regardless of connection state.
    public func emergencyReturn(reason: TransitionReason = .emergencyReturn) {
        switch state {
        case .edgeArmed, .dexActive:
            returnToMacOS(reason: reason)
        default: break
        }
    }

    public func fatal() {
        lock.withLock {
            virtualAxisPosition = 0
            hasReceivedFirstMove = false
        }
        transition(to: .error, reason: .fatalError)
    }

    // MARK: - Internal

    private func returnToMacOS(reason: TransitionReason) {
        lock.withLock {
            virtualAxisPosition = 0
            hasReceivedFirstMove = false
        }
        transition(to: .recovering, reason: reason)
        transition(to: .macActive, reason: reason)
    }

    private func transition(to newState: SwitchState, reason: TransitionReason) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState, reason)
    }
}
