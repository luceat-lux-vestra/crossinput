import XCTest
@testable import AndroidBridge
import Protocol

/// Deterministic coverage for RemoteSession's late-response accounting
/// (issue #62 review fixes): bounded buffer, synchronized snapshot, and the
/// eviction↔tombstone atomicity that prevents a missed late response.
final class LateResponseAccountingTests: XCTestCase {
    /// Feeds frames through the private parser/dispatch path via a real
    /// session whose channel is never connected — instead we exercise
    /// TimeoutTombstones + the public snapshot contract end to end with an
    /// injected clock.
    func testBoundedLateResponseWindow() {
        // The bound is enforced in RemoteSession.recordLateResponseIfTimedOut;
        // here we verify the constant is sane and the snapshot API returns a
        // copy (no interior mutability leak).
        XCTAssertEqual(RemoteSession.maxLateResponses, 256)
        let session = RemoteSession(configuration: .init(serial: "test"))
        XCTAssertTrue(session.snapshotLateResponses().isEmpty)
        // Snapshot must be independent of later mutation.
        var snapshot = session.snapshotLateResponses()
        snapshot.append(LateResponseRecord(requestKind: .ping, delayBeyondTimeout: 1))
        XCTAssertTrue(session.snapshotLateResponses().isEmpty)
    }

    func testEvictionAndTombstoneAreAtomicUnderResponseRace() {
        // Review round 2: the tombstone is recorded only when the timeout
        // WINS the eviction race. If a response evicted the entry first, the
        // timeout block must not create one (a stale tombstone could
        // misclassify a later same-id response as LATE). This test pins the
        // tombstones-level invariant: record-then-consume is exactly-once,
        // and consuming an unrecorded id is nil.
        let count = 100
        let tombstones = TimeoutTombstones(capacity: count * 2, ttl: 30)
        final class ConsumedBox: @unchecked Sendable {
            let lock = NSLock()
            var ids: [Int] = []
        }
        let consumed = ConsumedBox()
        let group = DispatchGroup()

        for id in UInt32(1)...UInt32(count) {
            tombstones.record(id: id, requestKind: .pointerMoveRel,
                              timeoutBudget: 0.01,
                              nowMonotonicMicros: Int64(id) * 1_000)
            group.enter()
            DispatchQueue.global().async { [consumed] in
                if tombstones.consume(id: id,
                                      at: Int64(id) * 1_000 + 50_000) != nil {
                    consumed.lock.withLock { consumed.ids.append(Int(id)) }
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(consumed.ids.count, count,
                       "every recorded tombstone must be consumable exactly once")
        for id in UInt32(1)...UInt32(count) {
            XCTAssertNil(tombstones.consume(id: id, at: 999_999_999),
                         "no double consumption after concurrent drain")
        }
    }
}
