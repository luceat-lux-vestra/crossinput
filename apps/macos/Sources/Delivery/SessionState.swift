import AndroidBridge

/// Connection/helper lifecycle. This is intentionally independent of control
/// ownership and target selection.
public enum SessionState: Equatable {
    case disconnected
    case connecting
    case ready
    case reconnecting
    case failed(String)
}
