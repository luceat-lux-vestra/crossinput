import AndroidBridge
import EdgeSwitch

/// Connection/helper lifecycle. This is intentionally independent of control
/// ownership and target selection.
enum SessionState: Equatable {
    case disconnected
    case connecting
    case ready
    case reconnecting
    case failed(String)
}

/// Ownership of local versus remote input. The edge state machine still owns
/// hysteresis and stale-transition safety; this model is the application-facing
/// control projection.
enum ControlState: Equatable {
    case local
    case arming(ScreenEdge)
    case remote
    case returning
}

enum TargetState: Equatable {
    case unavailable
    case available
    case selecting(RemoteTargetID)
    case selected(RemoteTargetID)
}
