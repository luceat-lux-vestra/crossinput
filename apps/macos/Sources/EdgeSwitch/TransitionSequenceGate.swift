import Foundation

/// Pure gate enforcing monotonic application of state transitions.
///
/// AppModel applies transitions on the main actor via `Task { @MainActor }`
/// blocks, whose execution order is not guaranteed. `TransitionSequenceGate`
/// is the final safety net required by the concurrency contract: a stale
/// transition (lower or equal sequence than the last applied one) is
/// discarded, so an old `.remoteActive` callback arriving after a newer
/// fail-safe return can never re-suppress the capture.
public struct TransitionSequenceGate: Sendable {
    private(set) public var lastAppliedSequence: UInt64 = 0

    public init() {}

    /// Returns `true` when the transition is newer than the last applied one
    /// and should be applied, and records it as the new last applied
    /// sequence. Returns `false` (no state change) for stale or duplicate
    /// transitions.
    @discardableResult
    public mutating func shouldApply(_ transition: StateTransition) -> Bool {
        guard transition.sequence > lastAppliedSequence else { return false }
        lastAppliedSequence = transition.sequence
        return true
    }

    /// Invalidates callbacks already queued before a lifecycle boundary. A
    /// later transition gets a higher sequence and remains eligible, while a
    /// delayed callback from the previous control epoch cannot re-apply old
    /// state after Disable or Disconnect.
    public mutating func advance(to sequence: UInt64) {
        guard sequence > lastAppliedSequence else { return }
        lastAppliedSequence = sequence
    }
}
