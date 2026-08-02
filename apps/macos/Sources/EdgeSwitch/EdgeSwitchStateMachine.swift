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

/// Edge Switch state machine (skeleton — transition rules implemented in Phase 5)
public final class EdgeSwitchStateMachine {
    public private(set) var state: SwitchState = .disabled

    public init() {}

    public func transition(to newState: SwitchState) {
        state = newState
    }
}
