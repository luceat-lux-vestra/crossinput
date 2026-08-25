import AndroidBridge
import EdgeSwitch


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
