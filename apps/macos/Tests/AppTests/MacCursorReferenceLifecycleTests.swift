import CoreGraphics
import XCTest
@testable import App

private final class CursorLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var eventsStorage: [String] = []
    private var liveDisplayStorage: CGDirectDisplayID?
    private var showResultsStorage: [CGError]

    init(liveDisplay: CGDirectDisplayID? = 7, showResults: [CGError] = [.success]) {
        liveDisplayStorage = liveDisplay
        showResultsStorage = showResults
    }

    var events: [String] { lock.withLock { eventsStorage } }

    func setLiveDisplay(_ displayID: CGDirectDisplayID?) {
        lock.withLock { liveDisplayStorage = displayID }
    }

    func liveDisplay() -> CGDirectDisplayID? {
        lock.withLock { liveDisplayStorage }
    }

    func record(_ event: String) {
        lock.withLock { eventsStorage.append(event) }
    }

    func nextShowResult() -> CGError {
        lock.withLock {
            guard !showResultsStorage.isEmpty else { return .success }
            return showResultsStorage.removeFirst()
        }
    }
}

@MainActor
final class MacCursorReferenceLifecycleTests: XCTestCase {
    private func makeLifecycle(
        recorder: CursorLifecycleRecorder,
        backgroundResult: Int32? = 0,
        hideResult: CGError = .success
    ) -> MacCursorReferenceLifecycle {
        MacCursorReferenceLifecycle(operations: .init(
            liveDisplayID: { recorder.liveDisplay() },
            setCursorInBackground: {
                recorder.record("background")
                return backgroundResult
            },
            hideCursor: { displayID in
                recorder.record("hide:\(displayID)")
                return hideResult
            },
            showCursor: { displayID in
                recorder.record("show:\(displayID)")
                return recorder.nextShowResult()
            },
            associateCursor: {
                recorder.record("associate")
                return .success
            }
        ))
    }

    func testReferenceSequenceReassertsBackgroundAroundBalancedVisibility() {
        let recorder = CursorLifecycleRecorder(liveDisplay: 7)
        let lifecycle = makeLifecycle(recorder: recorder)

        lifecycle.enterRemote()
        lifecycle.returnLocal()

        XCTAssertEqual(
            recorder.events,
            ["background", "hide:7", "associate", "background", "show:7", "associate"]
        )
        XCTAssertFalse(lifecycle.hasHiddenCursorForTesting)
    }

    func testDuplicateTransitionsDoNotAccumulateVisibilityCount() {
        let recorder = CursorLifecycleRecorder(liveDisplay: 7)
        let lifecycle = makeLifecycle(recorder: recorder)

        lifecycle.enterRemote()
        lifecycle.enterRemote()
        lifecycle.returnLocal()
        lifecycle.returnLocal()

        XCTAssertEqual(
            recorder.events,
            ["background", "hide:7", "associate", "background", "show:7", "associate"]
        )
    }

    func testSPIUnavailableLeavesPublicCursorVisibilityUntouched() {
        let recorder = CursorLifecycleRecorder(liveDisplay: 7)
        let lifecycle = makeLifecycle(recorder: recorder, backgroundResult: nil)

        lifecycle.enterRemote()
        lifecycle.returnLocal()

        XCTAssertEqual(recorder.events, ["background"])
        XCTAssertFalse(lifecycle.hasHiddenCursorForTesting)
    }

    func testHideFailureDoesNotCreateShowDebt() {
        let recorder = CursorLifecycleRecorder(liveDisplay: 7)
        let lifecycle = makeLifecycle(recorder: recorder, hideResult: .failure)

        lifecycle.enterRemote()
        lifecycle.returnLocal()

        XCTAssertEqual(recorder.events, ["background", "hide:7", "associate"])
        XCTAssertFalse(lifecycle.hasHiddenCursorForTesting)
    }

    func testShowBalancesExactlyTheDisplayWhoseHideSucceeded() {
        let recorder = CursorLifecycleRecorder(liveDisplay: 7)
        let lifecycle = makeLifecycle(recorder: recorder)

        lifecycle.enterRemote()
        recorder.setLiveDisplay(11)
        lifecycle.returnLocal()

        XCTAssertEqual(
            recorder.events,
            ["background", "hide:7", "associate", "background", "show:7", "associate"]
        )
    }

    func testFailedShowRetainsDebtAndLaterReturnRetriesIt() {
        let recorder = CursorLifecycleRecorder(
            liveDisplay: 7,
            showResults: [.failure, .success]
        )
        let lifecycle = makeLifecycle(recorder: recorder)

        lifecycle.enterRemote()
        lifecycle.returnLocal()
        XCTAssertTrue(lifecycle.hasHiddenCursorForTesting)

        lifecycle.returnLocal()

        XCTAssertEqual(
            recorder.events,
            [
                "background", "hide:7", "associate",
                "background", "show:7", "associate",
                "background", "show:7", "associate"
            ]
        )
        XCTAssertFalse(lifecycle.hasHiddenCursorForTesting)
    }
}