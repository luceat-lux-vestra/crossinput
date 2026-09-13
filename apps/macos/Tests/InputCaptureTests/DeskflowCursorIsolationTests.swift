import CoreGraphics
import XCTest
@testable import InputCapture

private final class DeskflowCursorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var eventsStorage: [String] = []
    private var backgroundResults: [Int32?]
    private var hideResults: [CGError]
    private var showResults: [CGError]
    private var associateResults: [CGError]
    private var suppressionResults: [Int32?]

    init(
        backgroundResults: [Int32?] = [0, 0],
        hideResults: [CGError] = [.success],
        showResults: [CGError] = [.success],
        associateResults: [CGError] = [.success, .success, .success, .success],
        suppressionResults: [Int32?] = [0, 0]
    ) {
        self.backgroundResults = backgroundResults
        self.hideResults = hideResults
        self.showResults = showResults
        self.associateResults = associateResults
        self.suppressionResults = suppressionResults
    }

    var events: [String] { lock.withLock { eventsStorage } }

    func background() -> Int32? {
        lock.withLock {
            eventsStorage.append("background")
            return backgroundResults.isEmpty ? 0 : backgroundResults.removeFirst()
        }
    }

    func hide(_ display: CGDirectDisplayID) -> CGError {
        lock.withLock {
            eventsStorage.append("hide:\(display)")
            return hideResults.isEmpty ? .success : hideResults.removeFirst()
        }
    }

    func show(_ display: CGDirectDisplayID) -> CGError {
        lock.withLock {
            eventsStorage.append("show:\(display)")
            return showResults.isEmpty ? .success : showResults.removeFirst()
        }
    }

    func associate(_ value: Bool) -> CGError {
        lock.withLock {
            eventsStorage.append("associate:\(value)")
            return associateResults.isEmpty ? .success : associateResults.removeFirst()
        }
    }

    func suppression(_ value: Double) -> Int32? {
        lock.withLock {
            eventsStorage.append(value == 0 ? "suppression:0" : "suppression:0.0001")
            return suppressionResults.isEmpty ? 0 : suppressionResults.removeFirst()
        }
    }
}

final class DeskflowCursorIsolationTests: XCTestCase {
    private func makeIsolation(
        _ recorder: DeskflowCursorRecorder,
        displayID: CGDirectDisplayID = 7
    ) -> DeskflowCursorIsolation {
        DeskflowCursorIsolation(
            operations: .init(
                liveDisplayID: { displayID },
                setCursorInBackground: { recorder.background() },
                hide: { recorder.hide($0) },
                show: { recorder.show($0) },
                associate: { recorder.associate($0) },
                setSuppressionInterval: { recorder.suppression($0) }
            )
        )
    }

    func testExactDeskflowEntryAndReturnOrdering() {
        let recorder = DeskflowCursorRecorder()
        let isolation = makeIsolation(recorder)

        XCTAssertTrue(isolation.begin(generation: 10))
        XCTAssertEqual(isolation.activeGenerationForTesting, 10)
        XCTAssertEqual(isolation.hiddenDisplayIDForTesting, 7)
        XCTAssertTrue(isolation.isDisassociatedForTesting)

        XCTAssertTrue(isolation.end(generation: 10))
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertNil(isolation.hiddenDisplayIDForTesting)
        XCTAssertFalse(isolation.isDisassociatedForTesting)

        XCTAssertEqual(
            recorder.events,
            [
                "background", "hide:7", "associate:true", "suppression:0.0001", "associate:false",
                "background", "show:7", "associate:true", "associate:true", "suppression:0"
            ]
        )
    }

    func testBackgroundSPIIsAdmissionPrecondition() {
        let recorder = DeskflowCursorRecorder(backgroundResults: [nil])
        let isolation = makeIsolation(recorder)

        XCTAssertFalse(isolation.begin(generation: 1))
        XCTAssertEqual(recorder.events, ["background"])
        XCTAssertNil(isolation.activeGenerationForTesting)
    }

    func testHideFailureDoesNotCreateVisibilityOrAssociationDebt() {
        let recorder = DeskflowCursorRecorder(hideResults: [.failure])
        let isolation = makeIsolation(recorder)

        XCTAssertFalse(isolation.begin(generation: 2))
        XCTAssertEqual(recorder.events, ["background", "hide:7"])
        XCTAssertNil(isolation.hiddenDisplayIDForTesting)
        XCTAssertFalse(isolation.isDisassociatedForTesting)
    }

    func testSuppressionIntervalUnavailableRejectsAdmissionAndRollsBackVisibility() {
        let recorder = DeskflowCursorRecorder(suppressionResults: [nil])
        let isolation = makeIsolation(recorder)

        XCTAssertFalse(isolation.begin(generation: 22))
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertNil(isolation.hiddenDisplayIDForTesting)
        XCTAssertFalse(isolation.isDisassociatedForTesting)
        XCTAssertEqual(
            recorder.events,
            [
                "background", "hide:7", "associate:true", "suppression:0.0001",
                "background", "show:7"
            ]
        )
    }

    func testDisassociateFailureRollsBackVisibilityAndSuppressionInterval() {
        let recorder = DeskflowCursorRecorder(
            showResults: [.success],
            associateResults: [.success, .failure, .success]
        )
        let isolation = makeIsolation(recorder)

        XCTAssertFalse(isolation.begin(generation: 3))
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertNil(isolation.hiddenDisplayIDForTesting)
        XCTAssertFalse(isolation.isDisassociatedForTesting)
        XCTAssertEqual(
            recorder.events,
            [
                "background", "hide:7", "associate:true", "suppression:0.0001", "associate:false",
                "associate:true", "background", "show:7", "suppression:0"
            ]
        )
    }

    func testStaleGenerationCannotBalanceCurrentLifecycle() {
        let recorder = DeskflowCursorRecorder()
        let isolation = makeIsolation(recorder)

        XCTAssertTrue(isolation.begin(generation: 4))
        XCTAssertFalse(isolation.end(generation: 5))
        XCTAssertEqual(isolation.activeGenerationForTesting, 4)
        XCTAssertTrue(isolation.isDisassociatedForTesting)
    }

    func testPartialCleanupDoesNotDoubleShowDuringForceReset() {
        let recorder = DeskflowCursorRecorder(
            showResults: [.success],
            associateResults: [.success, .success, .success, .failure]
        )
        let isolation = makeIsolation(recorder)

        XCTAssertTrue(isolation.begin(generation: 6))
        XCTAssertFalse(isolation.end(generation: 6))
        XCTAssertNil(isolation.hiddenDisplayIDForTesting, "successful show must clear visibility debt immediately")
        XCTAssertFalse(isolation.isDisassociatedForTesting, "first return association already restored hardware coupling")

        isolation.forceReset()
        XCTAssertEqual(recorder.events.filter { $0 == "show:7" }.count, 1)
    }

    func testProductionPolicyUsesNoAbsoluteHoldMutationButKeepsRestore() {
        XCTAssertFalse(CursorMutationExecutor.productionPerformsPositionMutation(for: .hold))
        XCTAssertTrue(CursorMutationExecutor.productionPerformsPositionMutation(for: .restore))
    }
}
