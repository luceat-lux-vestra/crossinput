import CoreGraphics
import XCTest
@testable import InputCapture

/// Regression tests for the fail-safe suppression watchdog (issue #50).
///
/// The watchdog timer previously targeted the same serial dispatch queue whose
/// thread was permanently parked inside CFRunLoopRun(), so its handler could
/// never execute and a trapped user had no automatic recovery path.
private final class WatchdogObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(SuppressionReleaseReason, UInt64)] = []

    var releases: [(SuppressionReleaseReason, UInt64)] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ reason: SuppressionReleaseReason, _ generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        storage.append((reason, generation))
    }
}

final class SuppressionWatchdogTests: XCTestCase {
    private var owners: [InputCaptureTestOwner] = []

    override func tearDown() {
        owners.forEach { $0.stop() }
        owners.removeAll()
        super.tearDown()
    }

    private func makeCapture(
        timeout: TimeInterval,
        released: @escaping @Sendable (SuppressionReleaseReason, UInt64) -> Void
    ) -> InputCapture {
        let executor = CursorMutationExecutor(mutation: { _, _ in })
        let owner = InputCaptureTestOwner(executor: executor)
        owners.append(owner)
        let capture = InputCapture(
            pointerRestoreOverride: {},
            suppressionTimeoutOverride: timeout,
            cursorMutationExecutor: executor
        )
        capture.onSuppressionReleased = released
        return capture
    }

    func testWatchdogFiresAfterTimeoutWithoutAnyPoke() {
        let observation = WatchdogObservation()
        let capture = makeCapture(timeout: 0.2) { observation.append($0, $1) }
        defer { capture.stop() }

        let expectation = expectation(description: "watchdog releases suppression")
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            expectation.fulfill()
        }

        XCTAssertEqual(capture.suppress(), 1)
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(observation.releases.count, 1, "watchdog must fire exactly once")
        XCTAssertEqual(observation.releases.first?.0, .watchdogTimeout)
        XCTAssertEqual(observation.releases.first?.1, 1)
        XCTAssertFalse(capture.isSuppressed, "watchdog release must restore listening mode")
    }

    func testPokeExtendsDeadlinePastTheOriginalTimeout() {
        let observation = WatchdogObservation()
        // Original deadline 0.3s; keep poking every 0.1s for 0.9s (3x deadline).
        let capture = makeCapture(timeout: 0.3) { observation.append($0, $1) }
        defer { capture.stop() }

        XCTAssertEqual(capture.suppress(), 1)
        for _ in 0..<9 {
            Thread.sleep(forTimeInterval: 0.1)
            capture.pokeWatchdog()
            XCTAssertTrue(
                observation.releases.isEmpty,
                "poked session must survive past the original deadline"
            )
        }

        let expectation = expectation(description: "watchdog fires after pokes stop")
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(observation.releases.map(\.0), [.watchdogTimeout])
    }

    func testStopCancelsAPendingWatchdog() throws {
        let observation = WatchdogObservation()
        let capture = makeCapture(timeout: 0.3) { observation.append($0, $1) }

        XCTAssertEqual(capture.suppress(), 1)
        capture.stop()

        // Past the original deadline only the stop-release may be recorded.
        Thread.sleep(forTimeInterval: 0.7)

        XCTAssertEqual(observation.releases.map(\.0), [.captureStopped])
        XCTAssertFalse(capture.isSuppressed)
    }
}
