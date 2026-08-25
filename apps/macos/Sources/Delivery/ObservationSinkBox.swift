import Foundation
import Protocol
import AndroidBridge

/// Thread-safe holder for the production observation sink (review round 5):
/// owns its own `NSLock` and is `@unchecked Sendable` — all access to
/// `_sink` is lock-guarded, so callers need no actor isolation and no
/// `nonisolated(unsafe)` annotation on actor-isolated controller state.
/// The single mutable field is confined by the box's lock, which is what
/// makes the unchecked conformance sound.
public final class ObservationSinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _sink: (@Sendable (RequestObservation) -> Void)?

    public init() {}

    public func set(_ sink: (@Sendable (RequestObservation) -> Void)?) {
        lock.lock()
        _sink = sink
        lock.unlock()
    }

    /// Returns a copy of the current sink; invoke it outside the lock to
    /// avoid re-entrancy if a sink logs back into telemetry.
    public func current() -> (@Sendable (RequestObservation) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return _sink
    }
}
