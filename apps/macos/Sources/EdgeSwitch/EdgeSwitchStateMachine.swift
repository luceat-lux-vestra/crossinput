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
public final class EdgeSwitchStateMachine: @unchecked Sendable {
    public private(set) var state: SwitchState = .disabled
    public var onStateChange: (@Sendable (SwitchState) -> Void)?

    /// Edge the pointer used to leave macOS for DeX.
    public private(set) var entryEdge: ScreenEdge = .left

    private let lock = NSLock()

    /// Virtual pointer position along the axis perpendicular to the entry edge.
    /// 0 = entry boundary, positive = inside Android/DeX, negative = beyond the
    /// boundary toward macOS. Return fires only when position <= -returnHysteresis.
    private var virtualAxisPosition: CGFloat = 0

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
        transition(to: .disconnected)
    }

    public func deactivate() {
        lock.withLock { virtualAxisPosition = 0 }
        transition(to: .disabled)
    }

    public func connectionBegan() {
        switch state {
        case .disconnected, .recovering: transition(to: .connecting)
        case .macActive: transition(to: .connecting)
        default: break
        }
    }

    public func connectionReady() {
        switch state {
        case .connecting, .disconnected, .error: transition(to: .macActive)
        default: break
        }
    }

    public func connectionLost() {
        switch state {
        case .connecting, .macActive, .edgeArmed, .dexActive, .recovering:
            lock.withLock { virtualAxisPosition = 0 }
            transition(to: .recovering)
        default: break
        }
    }

    /// Pointer reached a screen edge while macOS is active.
    public func pointerAtEdge(_ edge: ScreenEdge) {
        switch state {
        case .macActive:
            transition(to: .edgeArmed)
            entryEdge = edge
            lock.withLock { virtualAxisPosition = 0 }
            transition(to: .dexActive)
        case .edgeArmed:
            entryEdge = edge
            lock.withLock { virtualAxisPosition = 0 }
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
        let position = lock.withLock {
            virtualAxisPosition += delta
            return virtualAxisPosition
        }
        if isDiagnosticsEnabled {
            Diagnostics.log(
                "edge pointerMoved entry=\(entryEdge.rawValue) state=\(state.rawValue) "
                    + "dx=\(dx) dy=\(dy) axisDelta=\(delta) virtualPos=\(position)"
            )
        }
        if position <= -returnHysteresis {
            returnToMacOS()
        }
    }

    /// Emergency return: always works, regardless of connection state.
    public func emergencyReturn() {
        switch state {
        case .edgeArmed, .dexActive:
            returnToMacOS()
        default: break
        }
    }

    public func fatal() {
        lock.withLock { virtualAxisPosition = 0 }
        transition(to: .error)
    }

    // MARK: - Internal

    private func returnToMacOS() {
        lock.withLock { virtualAxisPosition = 0 }
        transition(to: .recovering)
        transition(to: .macActive)
    }

    private func transition(to newState: SwitchState) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }
}
