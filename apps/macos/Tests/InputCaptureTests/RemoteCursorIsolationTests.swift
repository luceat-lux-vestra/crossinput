import CoreGraphics
import XCTest
@testable import InputCapture

private final class CursorIsolationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var eventsStorage: [String] = []
    private var associateResults: [CGError]
    private var hideResults: [CGError]
    private var showResults: [CGError]

    init(
        associateResults: [CGError] = [.success, .success],
        hideResults: [CGError] = [.success],
        showResults: [CGError] = [.success]
    ) {
        self.associateResults = associateResults
        self.hideResults = hideResults
        self.showResults = showResults
    }

    var events: [String] { lock.withLock { eventsStorage } }

    func associate(_ value: Bool) -> CGError {
        lock.withLock {
            eventsStorage.append("associate:\(value)")
            return associateResults.isEmpty ? .success : associateResults.removeFirst()
        }
    }

    func hide() -> CGError {
        lock.withLock {
            eventsStorage.append("hide")
            return hideResults.isEmpty ? .success : hideResults.removeFirst()
        }
    }

    func show() -> CGError {
        lock.withLock {
            eventsStorage.append("show")
            return showResults.isEmpty ? .success : showResults.removeFirst()
        }
    }
}

final class RemoteCursorIsolationTests: XCTestCase {
    private func makeIsolation(_ recorder: CursorIsolationRecorder) -> RemoteCursorIsolation {
        RemoteCursorIsolation(
            operations: .init(
                associate: { recorder.associate($0) },
                hide: { recorder.hide() },
                show: { recorder.show() }
            )
        )
    }

    func testBalancedLifecycleDisassociatesBeforeHideAndReassociatesBeforeShow() {
        let recorder = CursorIsolationRecorder()
        let isolation = makeIsolation(recorder)

        XCTAssertTrue(isolation.begin(generation: 7))
        XCTAssertEqual(isolation.activeGenerationForTesting, 7)
        XCTAssertTrue(isolation.end(generation: 7))
        XCTAssertNil(isolation.activeGenerationForTesting)

        XCTAssertEqual(
            recorder.events,
            ["associate:false", "hide", "associate:true", "show"]
        )
    }

    func testDisassociateFailureRejectsAdmissionWithoutCreatingHideDebt() {
        let recorder = CursorIsolationRecorder(associateResults: [.failure])
        let isolation = makeIsolation(recorder)

        XCTAssertFalse(isolation.begin(generation: 1))
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertEqual(recorder.events, ["associate:false"])
    }

    func testHideFailureImmediatelyReassociatesBeforeAdmissionFails() {
        let recorder = CursorIsolationRecorder(
            associateResults: [.success, .success],
            hideResults: [.failure]
        )
        let isolation = makeIsolation(recorder)

        XCTAssertFalse(isolation.begin(generation: 2))
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertEqual(
            recorder.events,
            ["associate:false", "hide", "associate:true"]
        )
    }

    func testStaleGenerationCannotBalanceCurrentIsolation() {
        let recorder = CursorIsolationRecorder()
        let isolation = makeIsolation(recorder)

        XCTAssertTrue(isolation.begin(generation: 10))
        XCTAssertFalse(isolation.end(generation: 9))
        XCTAssertEqual(isolation.activeGenerationForTesting, 10)
        XCTAssertEqual(recorder.events, ["associate:false", "hide"])

        XCTAssertTrue(isolation.end(generation: 10))
        XCTAssertNil(isolation.activeGenerationForTesting)
    }

    func testCleanupFailureRetainsDebtAndForceResetRetriesBalance() {
        let recorder = CursorIsolationRecorder(
            associateResults: [.success, .failure, .success],
            hideResults: [.success],
            showResults: [.failure, .success]
        )
        let isolation = makeIsolation(recorder)

        XCTAssertTrue(isolation.begin(generation: 20))
        XCTAssertFalse(isolation.end(generation: 20))
        XCTAssertEqual(isolation.activeGenerationForTesting, 20)

        isolation.forceReset()
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertEqual(
            recorder.events,
            [
                "associate:false", "hide",
                "associate:true", "show",
                "associate:true", "show"
            ]
        )
    }

    func testSecondBeginCannotStackVisibilityOrAssociationDebt() {
        let recorder = CursorIsolationRecorder()
        let isolation = makeIsolation(recorder)

        XCTAssertTrue(isolation.begin(generation: 30))
        XCTAssertFalse(isolation.begin(generation: 31))
        XCTAssertEqual(isolation.activeGenerationForTesting, 30)
        XCTAssertEqual(recorder.events, ["associate:false", "hide"])
    }

    func testProductionPolicyPerformsNoAbsoluteHoldMutationButKeepsRestore() {
        XCTAssertFalse(CursorMutationExecutor.productionPerformsPositionMutation(for: .hold))
        XCTAssertTrue(CursorMutationExecutor.productionPerformsPositionMutation(for: .restore))
    }
}