import Foundation
import Protocol

/// Metadata-only diagnostic layer beneath the product-facing
/// `PointerDeliveryResult` fail-safe abstraction (issue #62 investigation).
///
/// Privacy contract (AGENTS.md rule 4): observations never carry pointer or
/// scroll deltas, key codes, clipboard data, or any input payload. Only
/// request type, elapsed time, outcome classification, and aggregate counters.
public enum Telemetry {}

/// Phase boundaries of one production pointer request, measured end to end.
/// All durations are seconds of monotonic clock; `t0` is request issue.
public struct RequestObservation: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case hello = "HELLO"
        case listDisplays = "LIST_DISPLAYS"
        case selectDisplay = "SELECT_DISPLAY"
        case ping = "PING"
        case pointerMoveRel = "POINTER_MOVE_REL"
        case pointerButton = "POINTER_BUTTON"
        case pointerScroll = "POINTER_SCROLL"
        case shutdown = "SHUTDOWN"
        case other = "OTHER"
        public init(of type: MessageType) {
            switch type {
            case .hello: self = .hello
            case .listDisplays: self = .listDisplays
            case .selectDisplay: self = .selectDisplay
            case .ping: self = .ping
            case .pointerMoveRel: self = .pointerMoveRel
            case .pointerButton: self = .pointerButton
            case .pointerScroll: self = .pointerScroll
            case .shutdown: self = .shutdown
            default: self = .other
            }
        }
    }

    /// Failure taxonomy. Never collapsed into a single "failed" bucket.
    public enum Outcome: Sendable, Equatable {
        /// Correlated response received within the deadline.
        case success(elapsed: Double)
        /// No response before the deadline; the request was evicted from the
        /// pending table by its timeout task.
        case timedOut(requestType: Kind, timeoutBudget: Double)
        /// The transport stream/process ended before a response arrived.
        case streamClosed(requestType: Kind)
        /// Writing the frame failed (transport dead, spawn failure).
        case writeFailed(requestType: Kind)
        /// A response frame arrived but did not match expectations.
        case unexpectedResponse(requestType: Kind)
        /// A response arrived but its payload failed to decode.
        case malformedResponse(requestType: Kind)
        /// The helper reported an explicit delivery failure status.
        case helperReportedFailure(requestType: Kind)
        /// Any other thrown error from the request path.
        case otherFailure(requestType: Kind, errorDescription: String)
        /// A valid response arrived after its requester's deadline expired.
        case lateResponse(requestKind: Kind, delayBeyondTimeout: Double)
    }

    public let kind: Kind
    public let outcome: Outcome

    /// End-to-end latency in seconds when `outcome == .success`; nil otherwise.
    public var latency: Double? {
        if case let .success(elapsed) = outcome { return elapsed }
        return nil
    }

    public init(kind: Kind, outcome: Outcome) {
        self.kind = kind
        self.outcome = outcome
    }
}

/// A late response: a response frame observed after its requester had already
/// timed out and been evicted from the pending table. Metadata only.
public struct LateResponseRecord: Sendable, Equatable {
    public let requestKind: RequestObservation.Kind
    /// Seconds between timeout expiry and the response's arrival.
    public let delayBeyondTimeout: Double

    public init(requestKind: RequestObservation.Kind, delayBeyondTimeout: Double) {
        self.requestKind = requestKind
        self.delayBeyondTimeout = delayBeyondTimeout
    }
}

/// Bounded short-lived tombstone store for timed-out request ids. When the
/// reader later observes a response whose id no longer has a live pending
/// entry, it checks here to classify the response as LATE rather than
/// UNCORRELATED. Entries expire; memory is bounded by `capacity`.
public final class TimeoutTombstones: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UInt32: Tombstone] = [:]
    private var order: [UInt32] = []
    private let capacity: Int
    private let ttl: TimeInterval

    private struct Tombstone {
        let requestKind: RequestObservation.Kind
        let expiredAtMicros: Int64
        let budget: Double
    }

    public init(capacity: Int = 64, ttl: TimeInterval = 30) {
        self.capacity = max(1, capacity)
        self.ttl = ttl
    }

    /// Records that request `id` timed out at `now`. Evicts expired entries,
    /// then enforces FIFO capacity.
    public func record(id: UInt32, requestKind: RequestObservation.Kind,
                       timeoutBudget: Double, nowMonotonicMicros: Int64) {
        lock.withLock {
            prune(nowMonotonicMicros: nowMonotonicMicros)
            guard entries[id] == nil else { return }
            entries[id] = Tombstone(requestKind: requestKind,
                                    expiredAtMicros: nowMonotonicMicros,
                                    budget: timeoutBudget)
            order.append(id)
            while order.count > capacity, let oldest = order.first {
                order.removeFirst()
                entries.removeValue(forKey: oldest)
            }
        }
    }

    /// If `id` names a recent tombstone, consumes it and returns the delay
    /// beyond the original deadline plus the request metadata. A second lookup
    /// for the same id returns nil (one-shot consumption keeps accounting
    /// free of double-counting).
    public func consume(id: UInt32, at nowMonotonicMicros: Int64) -> LateResponseRecord? {
        lock.withLock {
            guard let index = order.firstIndex(of: id),
                  let tombstone = entries.removeValue(forKey: id) else { return nil }
            order.remove(at: index)
            // TTL applies at consumption too (review fix): a stale tombstone
            // that survived because no newer timeout pruned it must not
            // classify an arbitrarily late response as LATE.
            let ageMicros = nowMonotonicMicros - tombstone.expiredAtMicros
            guard ageMicros <= Int64(ttl * 1_000_000) else { return nil }
            // The tombstone is written when the deadline expires, so the
            // observed lateness is simply response arrival minus expiry.
            let delayMicros = nowMonotonicMicros - tombstone.expiredAtMicros
            return LateResponseRecord(
                requestKind: tombstone.requestKind,
                delayBeyondTimeout: max(0, Double(delayMicros) / 1_000_000))
        }
    }

    public var isEmpty: Bool {
        lock.withLock { entries.isEmpty }
    }

    /// Drops expired entries; caller holds the lock.
    private func prune(nowMonotonicMicros: Int64) {
        guard !entries.isEmpty else { return }
        let ttlMicros = Int64(ttl * 1_000_000)
        let survivors = order.filter { id in
            guard let entry = entries[id] else { return false }
            return nowMonotonicMicros - entry.expiredAtMicros <= ttlMicros
        }
        order = survivors
        let liveIds = Set(survivors)
        entries = entries.filter { liveIds.contains($0.key) }
    }
}

/// Order-statistics accumulator for latency samples. Deterministic; no
/// probabilistic sketching. Not thread-safe: owners gate mutations behind
/// their own synchronization (RemoteSession uses its reader queue).
public struct LatencyAccumulator: Sendable, Equatable {
    private(set) public var samplesMicros: [Int64] = []

    public init() {}

    public var count: Int { samplesMicros.count }

    public mutating func add(seconds: Double) {
        let micros = Int64((seconds * 1_000_000).rounded())
        samplesMicros.append(max(0, micros))
    }

    /// Percentile in [0, 100] via nearest-rank on the sorted sample set.
    /// Returns nil below `minimumSamples` so tiny datasets never produce
    /// fabricated percentiles.
    public func percentile(_ p: Double, minimumSamples: Int = 20) -> Double? {
        guard count >= minimumSamples, count > 0 else { return nil }
        let sorted = samplesMicros.sorted()
        let rank = Int(((p / 100) * Double(count)).rounded(.up))
        return Double(sorted[max(0, min(count - 1, rank - 1))]) / 1_000_000
    }

    public var maximum: Double? {
        guard let maxMicros = samplesMicros.max() else { return nil }
        return Double(maxMicros) / 1_000_000
    }

    /// Counts of samples above each threshold, in seconds. Meaningful only
    /// when `count` is statistically meaningful.
    public func countsAbove(_ thresholds: [Double], minimumSamples: Int = 20) -> [Double: Int]? {
        guard count >= minimumSamples else { return nil }
        var result: [Double: Int] = [:]
        for threshold in thresholds {
            result[threshold] = samplesMicros.lazy
                .filter { Double($0) / 1_000_000 > threshold }.count
        }
        return result
    }
}
