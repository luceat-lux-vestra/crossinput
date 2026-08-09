import Foundation

/// Why pointer suppression was lifted. Every release is tagged with its
/// cause so the app phase and on-device traces never collapse a real cause
/// (connection loss, fatal error) into a normal return (issue #37).
public enum SuppressionReleaseReason: String, Sendable {
    /// Normal boundary-crossing return while the connection is alive.
    case normalReturn
    /// Fail-safe watchdog fired because no pointer events arrived for a while.
    case watchdogTimeout
    /// Emergency shortcut (⇧⌘X) pressed by the user.
    case emergencyHotkey
    /// Suppression stopped because the connection was lost mid-capture.
    case connectionLost
    /// Capture stopped as part of an explicit disconnect/deactivate.
    case captureStopped
    /// Suppression released because the helper reported a fatal error.
    case fatalError
}

/// App connection phase after a suppression release (pure, testable policy).
public enum SuppressionPhaseOutcome: String, Sendable {
    case idle
    case ready
    case error
}

/// Pure reducer deciding the app phase after a suppression release.
/// Rule set (issue #37):
/// - connection lost or no connection   -> idle (reconnect path, never ready)
/// - fatal error                        -> error
/// - live-connection releases           -> ready (normal return, watchdog, hotkey)
/// - explicit deactivate/disconnect     -> idle
public enum SuppressionPhasePolicy {
    public static func nextPhase(after reason: SuppressionReleaseReason,
                                 isConnected: Bool) -> SuppressionPhaseOutcome {
        switch reason {
        case .connectionLost, .captureStopped:
            return .idle
        case .fatalError:
            return .error
        case .normalReturn, .watchdogTimeout, .emergencyHotkey:
            return isConnected ? .ready : .idle
        }
    }
}
