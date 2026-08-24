import Foundation
import Protocol
import AndroidBridge

/// Aggregates `RequestObservation` streams from both the delivery layer
/// (`InputSender.onDeliveryObservation`) and the transport layer
/// (`RemoteSession.onObservation`) into the issue #62 evidence record.
///
/// Thread-safety: mutations are serialized by the owning tool's lock; each
/// observation is metadata-only by construction.
struct OutcomeCounter {
    struct Record: Codable {
        var profile: String = ""
        var startedUTC = ""
        var endedUTC = ""
        var serialRedacted = true
        var requests = 0
        var successes = 0
        var timeouts = 0
        var streamClosed = 0
        var writeFailed = 0
        var unexpectedResponse = 0
        var malformedResponse = 0
        var helperReportedFailure = 0
        var otherFailure = 0
        var cancelled = 0
        var safetyRejected = 0
        var coalescedIntoExistingBatch = 0
        var shedLocally = 0
        var acceptedAsNewBatch = 0
        var lateResponses = 0
        var lateDelaySeconds: [Double] = []
        /// Success latency samples in seconds. Metadata only: no deltas.
        var latencySamples: [Double] = []
        var timeoutBudgets: [Double] = []
        var helperCapabilities: UInt32 = 0
        // Product-facing delivery results (review round 2): rc=1 must be
        // explainable from the evidence itself.
        var deliveredMovementCount = 0
        var partiallyDeliveredMovementCount = 0
        var deliveredCount = 0
        var cancelledCount = 0
        var failedCount = 0
    }

    var record = Record()
    /// Deduplicated request accounting: RemoteSession observes every request,
    /// InputSender re-observes pointer requests. Keyed by nothing stable — so
    /// instead of deduplication, delivery-layer and session-layer counters are
    /// tracked in separate namespaces and only the session layer feeds
    /// request-level totals.
    private var sawSessionObservationForRequest = false

    mutating func observe(_ observation: RequestObservation, layer: Layer) {
        // Request-level taxonomy comes solely from the session layer, which
        // sees every request exactly once. The delivery layer's observations
        // are folded into the same buckets for pointer-only outcomes that the
        // session cannot see (unexpected response / malformed payload /
        // helper-reported failure are classified above the session).
        switch layer {
        case .session:
            record.requests += 1
            switch observation.outcome {
            case .success(let elapsed):
                record.successes += 1
                record.latencySamples.append(elapsed)
            case .timedOut(_, let budget):
                record.timeouts += 1
                record.timeoutBudgets.append(budget)
            case .streamClosed:
                record.streamClosed += 1
            case .writeFailed:
                record.writeFailed += 1
            case .unexpectedResponse:
                record.unexpectedResponse += 1
            case .malformedResponse:
                record.malformedResponse += 1
            case .helperReportedFailure:
                record.helperReportedFailure += 1
            case .otherFailure:
                record.otherFailure += 1
            case .lateResponse(_, let delay):
                record.lateResponses += 1
                record.lateDelaySeconds.append(delay)
            }
        case .delivery:
            switch observation.outcome {
            case .success, .timedOut, .streamClosed, .writeFailed:
                break // already accounted at the session layer
            case .unexpectedResponse:
                record.unexpectedResponse += 1
            case .malformedResponse:
                record.malformedResponse += 1
            case .helperReportedFailure:
                record.helperReportedFailure += 1
            case .otherFailure:
                record.otherFailure += 1
            case .lateResponse(_, let delay):
                record.lateResponses += 1
                record.lateDelaySeconds.append(delay)
            }
        }
    }

    enum Layer {
        case session
        case delivery
    }

    func percentile(_ p: Double) -> Double? {
        let samples = record.latencySamples.sorted()
        guard samples.count >= 20 else { return nil }
        let rank = Int(((p / 100) * Double(samples.count)).rounded(.up))
        return samples[max(0, min(samples.count - 1, rank - 1))]
    }

    func countsAbove(_ threshold: Double) -> Int? {
        guard record.latencySamples.count >= 20 else { return nil }
        return record.latencySamples.lazy.filter { $0 > threshold }.count
    }

    func summaryLines() -> [String] {
        var lines: [String] = []
        lines.append("requests=\(record.requests)")
        lines.append("successes=\(record.successes)")
        lines.append("timeouts=\(record.timeouts)")
        lines.append("stream_closed=\(record.streamClosed)")
        lines.append("write_failed=\(record.writeFailed)")
        lines.append("unexpected_response=\(record.unexpectedResponse)")
        lines.append("malformed_response=\(record.malformedResponse)")
        lines.append("helper_reported_failure=\(record.helperReportedFailure)")
        lines.append("other_failure=\(record.otherFailure)")
        if let p50 = percentile(50) { lines.append(String(format: "p50=%.3f", p50)) }
        if let p90 = percentile(90) { lines.append(String(format: "p90=%.3f", p90)) }
        if let p95 = percentile(95) { lines.append(String(format: "p95=%.3f", p95)) }
        if let p99 = percentile(99) { lines.append(String(format: "p99=%.3f", p99)) }
        if let maxLatency = record.latencySamples.max() {
            lines.append(String(format: "max_latency=%.3f", maxLatency))
        }
        if let over250 = countsAbove(0.25) { lines.append("over_250ms=\(over250)") }
        if let over500 = countsAbove(0.5) { lines.append("over_500ms=\(over500)") }
        if let over750 = countsAbove(0.75) { lines.append("over_750ms=\(over750)") }
        if let over1000 = countsAbove(1.0) { lines.append("over_1000ms=\(over1000)") }
        lines.append("late_responses=\(record.lateResponses)")
        return lines
    }
}

/// Thread-safe box so observation closures can append without capturing
/// mutable struct state (Swift concurrency requires Sendable captures).
final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _counter = OutcomeCounter()

    var counter: OutcomeCounter {
        lock.withLock { _counter }
    }

    func append(_ observation: RequestObservation, layer: OutcomeCounter.Layer) {
        lock.withLock { _counter.observe(observation, layer: layer) }
    }

    func finalize(profile: String, started: String, ended: String,
                  lateResponses: [LateResponseRecord],
                  capabilities: UInt32,
                  admission: (accepted: Int, coalesced: Int, shed: Int, rejected: Int),
                  deliveryResults: (deliveredMovement: Int, partial: Int,
                                    delivered: Int, cancelled: Int, failed: Int)) -> OutcomeCounter.Record {
        lock.withLock {
            _counter.record.lateResponses += lateResponses.count
            _counter.record.lateDelaySeconds.append(
                contentsOf: lateResponses.map(\.delayBeyondTimeout))
            _counter.record.profile = profile
            _counter.record.startedUTC = started
            _counter.record.endedUTC = ended
            _counter.record.helperCapabilities = capabilities
            _counter.record.acceptedAsNewBatch = admission.accepted
            _counter.record.coalescedIntoExistingBatch = admission.coalesced
            _counter.record.shedLocally = admission.shed
            _counter.record.safetyRejected = admission.rejected
            _counter.record.deliveredMovementCount = deliveryResults.deliveredMovement
            _counter.record.partiallyDeliveredMovementCount = deliveryResults.partial
            _counter.record.deliveredCount = deliveryResults.delivered
            _counter.record.cancelledCount = deliveryResults.cancelled
            _counter.record.failedCount = deliveryResults.failed
            return _counter.record
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
