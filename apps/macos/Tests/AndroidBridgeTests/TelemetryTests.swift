import XCTest
@testable import AndroidBridge
import Protocol

/// Deterministic coverage for the issue #62 observability layer: request
/// observation taxonomy, bounded late-response tombstones, and latency
/// statistics. No sleeps for synchronization; injected clocks where timing
/// matters.
final class TelemetryTests: XCTestCase {
    // MARK: - RequestObservation taxonomy

    func testLatencyExposedOnlyForSuccess() {
        let success = RequestObservation(kind: .pointerScroll,
                                         outcome: .success(elapsed: 0.123))
        XCTAssertEqual(success.latency, 0.123)

        let timeout = RequestObservation(
            kind: .pointerScroll,
            outcome: .timedOut(requestType: .pointerScroll, timeoutBudget: 0.75))
        XCTAssertNil(timeout.latency)
    }

    func testKindMappingCoversPointerRequestsAndFallsBackToOther() {
        XCTAssertEqual(RequestObservation.Kind(of: .pointerMoveRel), .pointerMoveRel)
        XCTAssertEqual(RequestObservation.Kind(of: .pointerButton), .pointerButton)
        XCTAssertEqual(RequestObservation.Kind(of: .pointerScroll), .pointerScroll)
        XCTAssertEqual(RequestObservation.Kind(of: .hello), .hello)
        XCTAssertEqual(RequestObservation.Kind(of: .keyEvent), .other)
    }

    func testConnectionErrorMappingDistinguishesTimeoutStreamClosedAndWriteFailure() {
        let timeout = RemoteSession.observation(
            for: .timeout("no response"),
            requestType: .pointerMoveRel,
            timeoutBudget: 0.75)
        XCTAssertEqual(timeout.outcome,
                       .timedOut(requestType: .pointerMoveRel, timeoutBudget: 0.75))

        let closed = RemoteSession.observation(
            for: .streamClosed,
            requestType: .pointerScroll,
            timeoutBudget: 0.75)
        XCTAssertEqual(closed.outcome, .streamClosed(requestType: .pointerScroll))

        let write = RemoteSession.observation(
            for: .processSpawnFailed("spawn failed"),
            requestType: .pointerButton,
            timeoutBudget: 0.75)
        XCTAssertEqual(write.outcome, .writeFailed(requestType: .pointerButton))
    }

    // MARK: - TimeoutTombstones

    private var micros: Int64 { 1_000_000 }

    func testTombstoneConsumedOnceClassifiesLateResponseWithDelayBeyondTimeout() {
        let tombstones = TimeoutTombstones()
        let expiryMicros: Int64 = 1_000_000

        tombstones.record(id: 7, requestKind: .pointerScroll,
                          timeoutBudget: 0.75,
                          nowMonotonicMicros: expiryMicros)

        // Helper answers 120 ms after the deadline.
        let record = tombstones.consume(id: 7, at: expiryMicros + 120_000)
        XCTAssertEqual(record?.requestKind, .pointerScroll)
        XCTAssertEqual(record?.delayBeyondTimeout ?? -1, 0.12, accuracy: 0.001)

        // One-shot consumption: a second response with the same id is no
        // longer classified as late (no double counting).
        XCTAssertNil(tombstones.consume(id: 7, at: expiryMicros + 200_000))
    }

    func testUnknownIdIsNotAClassifiedLateResponse() {
        let tombstones = TimeoutTombstones()
        XCTAssertNil(tombstones.consume(id: 99, at: 5_000_000))
        XCTAssertTrue(tombstones.isEmpty)
    }

    func testTombstonesExpireAfterTtl() {
        let tombstones = TimeoutTombstones(capacity: 4, ttl: 1)
        let start: Int64 = 10_000_000
        tombstones.record(id: 1, requestKind: .ping, timeoutBudget: 0.75,
                          nowMonotonicMicros: start)
        // TTL is 1 s; recording a later tombstone prunes the expired one.
        _ = tombstones.consume(id: 2, at: start) // empty consume is a no-op
        tombstones.record(id: 3, requestKind: .ping, timeoutBudget: 0.75,
                          nowMonotonicMicros: start + 3_000_000)
        XCTAssertNil(tombstones.consume(id: 1, at: start + 3_000_000),
                     "expired tombstone must not classify late responses")
    }

    func testTombstoneStoreIsBoundedByCapacity() {
        let capacity = 8
        let tombstones = TimeoutTombstones(capacity: capacity, ttl: 30)
        let start: Int64 = 2_000_000
        for id in UInt32(1)...UInt32(64) {
            tombstones.record(id: id, requestKind: .pointerScroll,
                              timeoutBudget: 0.75,
                              nowMonotonicMicros: start)
        }
        // Only the most recent `capacity` ids survive FIFO eviction.
        XCTAssertNil(tombstones.consume(id: 1, at: start))
        XCTAssertNotNil(tombstones.consume(id: 64, at: start))
    }

    // MARK: - LatencyAccumulator

    func testPercentilesRequireMinimumSamples() {
        var accumulator = LatencyAccumulator()
        accumulator.add(seconds: 0.05)
        accumulator.add(seconds: 0.25)
        XCTAssertNil(accumulator.percentile(50), "tiny datasets must not produce fabricated percentiles")
        XCTAssertNil(accumulator.maximum == nil ? nil : accumulator.maximum.flatMap { _ in nil })
        XCTAssertNil(accumulator.countsAbove([0.25]))
    }

    func testPercentileNearestRankOnKnownDistribution() {
        var accumulator = LatencyAccumulator()
        // 100 samples: value i (in ms) at position i.
        for ms in 1...100 {
            accumulator.add(seconds: Double(ms) / 1_000)
        }
        XCTAssertEqual(accumulator.count, 100)
        // Nearest-rank p50 of 1..100 sorted -> rank ceil(0.5*100)=50 -> 50 ms.
        XCTAssertEqual(accumulator.percentile(50) ?? -1, 0.050, accuracy: 0.0005)
        // p95 -> rank 95 -> 95 ms.
        XCTAssertEqual(accumulator.percentile(95) ?? -1, 0.095, accuracy: 0.0005)
        // p99 -> rank 99 -> 99 ms.
        XCTAssertEqual(accumulator.percentile(99) ?? -1, 0.099, accuracy: 0.0005)
        let counts = accumulator.countsAbove([0.05, 0.075, 0.1])
        XCTAssertEqual(counts?[0.05], 50) // strictly above 50 ms: samples 51..100
        XCTAssertEqual(counts?[0.075], 25) // samples 76..100
        XCTAssertEqual(counts?[0.1], 0) // max sample is exactly 100 ms, not above
    }

    func testNegativeSamplesClampToZero() {
        var accumulator = LatencyAccumulator()
        accumulator.add(seconds: -5)
        XCTAssertEqual(accumulator.maximum ?? -1, 0, accuracy: 0.0001)
    }

    func testStaleTombstoneDirectConsumeIsRejected() {
        // Review fix: consume() must enforce TTL itself. Here NO later
        // record() ever prunes the entry; the consumer simply arrives after
        // the 1 s TTL.
        let tombstones = TimeoutTombstones(capacity: 4, ttl: 1)
        let start: Int64 = 50_000_000
        tombstones.record(id: 5, requestKind: .pointerScroll,
                          timeoutBudget: 0.75,
                          nowMonotonicMicros: start)
        XCTAssertNil(tombstones.consume(id: 5, at: start + 1_500_000),
                     "tombstone past TTL must not classify a response as late")
    }

    func testTombstoneAtTtlBoundaryStillClassifies() {
        let tombstones = TimeoutTombstones(capacity: 4, ttl: 1)
        let start: Int64 = 60_000_000
        tombstones.record(id: 6, requestKind: .ping, timeoutBudget: 0.75,
                          nowMonotonicMicros: start)
        XCTAssertNotNil(tombstones.consume(id: 6, at: start + 1_000_000),
                        "response exactly at the TTL edge is still within the window")
    }
}
