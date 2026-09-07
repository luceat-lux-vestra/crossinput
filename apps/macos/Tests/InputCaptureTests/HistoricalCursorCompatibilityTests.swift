import CoreGraphics
import XCTest
@testable import InputCapture

private final class HistoricalCursorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var eventsStorage: [String] = []
    private var visibleStorage = false
    private var showFailureBudgetStorage: [CGDirectDisplayID: Int] = [:]
    var liveDisplay: CGDirectDisplayID? = 7
    var pointDisplay: CGDirectDisplayID? = 7
    var mainDisplay: CGDirectDisplayID = 1
    var backgroundResult: Int32? = 0
    var hideFailures: Set<CGDirectDisplayID> = []

    var events: [String] { lock.withLock { eventsStorage } }

    func record(_ event: String) {
        lock.withLock { eventsStorage.append(event) }
    }

    var visible: Bool {
        get { lock.withLock { visibleStorage } }
        set { lock.withLock { visibleStorage = newValue } }
    }

    func failNextShows(displayID: CGDirectDisplayID, count: Int) {
        lock.withLock { showFailureBudgetStorage[displayID] = count }
    }

    func showResult(for displayID: CGDirectDisplayID) -> CGError {
        lock.withLock {
            let remaining = showFailureBudgetStorage[displayID] ?? 0
            guard remaining > 0 else { return .success }
            showFailureBudgetStorage[displayID] = remaining - 1
            return .failure
        }
    }
}

final class HistoricalCursorCompatibilityTests: XCTestCase {
    private func makeCompatibility(
        recorder: HistoricalCursorRecorder
    ) -> HistoricalCursorCompatibility {
        HistoricalCursorCompatibility(operations: .init(
            liveDisplayID: { recorder.liveDisplay },
            displayIDAtPoint: { _ in recorder.pointDisplay },
            mainDisplayID: { recorder.mainDisplay },
            setCursorInBackground: { enabled in
                recorder.record("background:\(enabled)")
                return recorder.backgroundResult
            },
            hideCursor: { displayID in
                recorder.record("hide:\(displayID)")
                return recorder.hideFailures.contains(displayID) ? .failure : .success
            },
            showCursor: { displayID in
                recorder.record("show:\(displayID)")
                return recorder.showResult(for: displayID)
            },
            cursorIsVisible: { recorder.visible },
            associateCursor: {
                recorder.record("associate")
            }
        ))
    }

    func testHistoricalSequenceTogglesBackgroundAndBalancesEverySuccessfulHide() {
        let recorder = HistoricalCursorRecorder()
        let compatibility = makeCompatibility(recorder: recorder)

        compatibility.enterRemote()
        XCTAssertTrue(compatibility.ownsRemoteCursorForTesting)
        XCTAssertEqual(compatibility.successfulHideCountForTesting, 2)

        // PR #16 intended to re-hide only if macOS made the cursor visible
        // after a hold warp. Current macOS hide calls are reference-counted,
        // so a still-hidden cursor must not accumulate additional debt.
        compatibility.didHoldWarp(at: .zero)
        XCTAssertEqual(compatibility.successfulHideCountForTesting, 2)

        recorder.visible = true
        compatibility.didHoldWarp(at: .zero)
        XCTAssertEqual(compatibility.successfulHideCountForTesting, 3)

        compatibility.didRestoreWarp()
        compatibility.leaveRemote()

        XCTAssertEqual(
            recorder.events,
            [
                "background:true", "hide:7", "hide:1",
                "hide:7", "associate",
                "background:false", "show:7", "show:1", "show:7"
            ]
        )
        XCTAssertFalse(compatibility.ownsRemoteCursorForTesting)
        XCTAssertEqual(compatibility.successfulHideCountForTesting, 0)
    }

    func testDuplicateOwnershipTransitionsAreIdempotent() {
        let recorder = HistoricalCursorRecorder()
        let compatibility = makeCompatibility(recorder: recorder)

        compatibility.enterRemote()
        compatibility.enterRemote()
        compatibility.leaveRemote()
        compatibility.leaveRemote()

        XCTAssertEqual(
            recorder.events,
            ["background:true", "hide:7", "hide:1", "background:false", "show:1", "show:7"]
        )
    }

    func testPrivateSPIUnavailableStillPreservesHistoricalPublicHideShowPath() {
        let recorder = HistoricalCursorRecorder()
        recorder.backgroundResult = nil
        let compatibility = makeCompatibility(recorder: recorder)

        compatibility.enterRemote()
        compatibility.leaveRemote()

        XCTAssertEqual(
            recorder.events,
            ["background:true", "hide:7", "hide:1", "background:false", "show:1", "show:7"]
        )
    }

    func testFailedHideCreatesNoShowDebt() {
        let recorder = HistoricalCursorRecorder()
        recorder.hideFailures = [7]
        let compatibility = makeCompatibility(recorder: recorder)

        compatibility.enterRemote()
        compatibility.leaveRemote()

        XCTAssertEqual(
            recorder.events,
            ["background:true", "hide:7", "hide:1", "background:false", "show:1"]
        )
        XCTAssertEqual(compatibility.successfulHideCountForTesting, 0)
    }

    func testFailedShowDebtIsRetainedAndRetriedWithoutRetogglingBackground() {
        let recorder = HistoricalCursorRecorder()
        recorder.failNextShows(displayID: 1, count: 1)
        let compatibility = makeCompatibility(recorder: recorder)

        compatibility.enterRemote()
        compatibility.leaveRemote()
        XCTAssertFalse(compatibility.ownsRemoteCursorForTesting)
        XCTAssertEqual(compatibility.successfulHideCountForTesting, 1)

        compatibility.leaveRemote()

        XCTAssertEqual(
            recorder.events,
            [
                "background:true", "hide:7", "hide:1",
                "background:false", "show:1", "show:7",
                "show:1"
            ]
        )
        XCTAssertEqual(compatibility.successfulHideCountForTesting, 0)
    }
}
