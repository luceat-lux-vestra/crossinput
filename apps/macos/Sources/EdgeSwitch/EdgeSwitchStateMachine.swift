import Foundation

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

public enum ScreenEdge: Sendable, Equatable {
    case left, right, top, bottom
}

/// Edge Switch state machine.
///
/// Flow: disabled -> disconnected -> connecting -> macActive; pointer reaches a
/// screen edge -> edgeArmed -> dexActive (pointer captured by the device); the
/// pointer returning across the entry edge, the emergency shortcut, or a lost
/// connection brings control back to macOS.
public final class EdgeSwitchStateMachine: @unchecked Sendable {
    public private(set) var state: SwitchState = .disabled
    public var onStateChange: (@Sendable (SwitchState) -> Void)?

    /// Edge the pointer used to leave macOS for DeX.
    public private(set) var entryEdge: ScreenEdge = .left

    private let lock = NSLock()
    private var returnAccumulator: CGFloat = 0

    /// Distance the pointer must travel back across the entry edge to return.
    public var returnThreshold: CGFloat = 60

    public init() {}

    // MARK: - Public transitions

    public func activate() {
        guard state == .disabled else { return }
        transition(to: .disconnected)
    }

    public func deactivate() {
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
            lock.withLock { returnAccumulator = 0 }
            transition(to: .dexActive)
        case .edgeArmed:
            entryEdge = edge
            lock.withLock { returnAccumulator = 0 }
        default: break
        }
    }

    /// Relative pointer movement while DeX owns the pointer.
    public func pointerMoved(dx: CGFloat, dy: CGFloat) {
        guard state == .dexActive else { return }
        let delta: CGFloat
        switch entryEdge {
        case .left: delta = dx // moving right (positive) heads back into the screen
        case .right: delta = -dx
        case .top: delta = -dy
        case .bottom: delta = dy
        }
        let accumulator = lock.withLock {
            returnAccumulator += delta
            return returnAccumulator
        }
        if accumulator >= returnThreshold {
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
        transition(to: .error)
    }

    // MARK: - Internal

    private func returnToMacOS() {
        lock.withLock { returnAccumulator = 0 }
        transition(to: .recovering)
        transition(to: .macActive)
    }

    private func transition(to newState: SwitchState) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }
}
