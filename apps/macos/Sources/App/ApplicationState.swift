import AndroidBridge
import EdgeSwitch


/// Ownership of local versus remote input. The edge state machine still owns
/// hysteresis and stale-transition safety; this model is the application-facing
/// control projection.
enum ControlState: Equatable {
    /// Edge switching is intentionally disabled while the Android session may
    /// remain ready for a later re-enable.
    case disabled
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
