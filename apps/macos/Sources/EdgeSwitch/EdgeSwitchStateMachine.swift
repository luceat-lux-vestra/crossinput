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

/// Edge Switch 상태 머신 (스켈레톤 — 전이 규칙은 Phase 5에서 구현)
public final class EdgeSwitchStateMachine {
    public private(set) var state: SwitchState = .disabled

    public init() {}

    public func transition(to newState: SwitchState) {
        state = newState
    }
}
