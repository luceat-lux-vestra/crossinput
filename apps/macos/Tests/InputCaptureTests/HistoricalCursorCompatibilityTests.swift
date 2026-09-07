import XCTest
@testable import InputCapture

private final class HistoricalStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var eventsStorage: [String] = []
    var backgroundResult: Int32? = 0

    var events: [String] { lock.withLock { eventsStorage } }

    func record(_ event: String) {
        lock.withLock { eventsStorage.append(event) }
    }
}

final class HistoricalCursorCompatibilityTests: XCTestCase {
    private func makeCompatibility(
        recorder: HistoricalStateRecorder
    ) -> HistoricalCursorCompatibility {
        HistoricalCursorCompatibility(operations: .init(
            setCursorInBackground: { enabled in
                recorder.record("background:\(enabled)")
                return recorder.backgroundResult
            },
            associateCursor: {
                recorder.record("associate")
            }
        ))
    }

    func testHistoricalStateSequenceDoesNotManageCursorVisibility() {
        let recorder = HistoricalStateRecorder()
        let compatibility = makeCompatibility(recorder: recorder)

        compatibility.enterRemote()
        compatibility.didHoldWarp(at: .zero)
        compatibility.leaveRemote()
        compatibility.didRestoreWarp()

        XCTAssertEqual(
            recorder.events,
            ["background:true", "background:false", "associate"]
        )
        XCTAssertFalse(compatibility.ownsRemoteCursorStateForTesting)
    }

    func testDuplicateOwnershipTransitionsAreIdempotent() {
        let recorder = HistoricalStateRecorder()
        let compatibility = makeCompatibility(recorder: recorder)

        compatibility.enterRemote()
        compatibility.enterRemote()
        compatibility.leaveRemote()
        compatibility.leaveRemote()

        XCTAssertEqual(
            recorder.events,
            ["background:true", "background:false"]
        )
    }

    func testPrivateSPIUnavailableDoesNotChangeLifecycleContract() {
        let recorder = HistoricalStateRecorder()
        recorder.backgroundResult = nil
        let compatibility = makeCompatibility(recorder: recorder)

        compatibility.enterRemote()
        XCTAssertTrue(compatibility.ownsRemoteCursorStateForTesting)
        compatibility.leaveRemote()

        XCTAssertEqual(
            recorder.events,
            ["background:true", "background:false"]
        )
        XCTAssertFalse(compatibility.ownsRemoteCursorStateForTesting)
    }

    func testRestoreAssociationIsIndependentOfVisibilityLifecycle() {
        let recorder = HistoricalStateRecorder()
        let compatibility = makeCompatibility(recorder: recorder)

        compatibility.didRestoreWarp()
        compatibility.didRestoreWarp()

        XCTAssertEqual(recorder.events, ["associate", "associate"])
    }
}
