import CoreGraphics
import XCTest
@testable import InputCapture

private final class DeskflowCursorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var eventsStorage: [String] = []
    private var backgroundResults: [Int32?]
    private var associateResults: [CGError]
    private var suppressionResults: [Int32?]

    init(
        backgroundResults: [Int32?] = [0, 0],
        associateResults: [CGError] = [.success, .success, .success, .success],
        suppressionResults: [Int32?] = [0, 0]
    ) {
        self.backgroundResults = backgroundResults
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
    private func makeIsolation(_ recorder: DeskflowCursorRecorder) -> DeskflowCursorIsolation {
        DeskflowCursorIsolation(
            operations: .init(
                setCursorInBackground: { recorder.background() },
                associate: { recorder.associate($0) },
                setSuppressionInterval: { recorder.suppression($0) }
            )
        )
    }

    func testVisibleCursorEntryAndReturnOrderingContainsNoVisibilityMutation() {
        let recorder = DeskflowCursorRecorder()
        let isolation = makeIsolation(recorder)

        XCTAssertTrue(isolation.begin(generation: 10))
        XCTAssertEqual(isolation.activeGenerationForTesting, 10)
        XCTAssertTrue(isolation.isDisassociatedForTesting)

        XCTAssertTrue(isolation.end(generation: 10))
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertFalse(isolation.isDisassociatedForTesting)

        XCTAssertEqual(
            recorder.events,
            [
                "background", "associate:true", "suppression:0.0001", "associate:false",
                "background", "associate:true", "associate:true", "suppression:0"
            ]
        )
        XCTAssertFalse(recorder.events.contains { $0.contains("hide") || $0.contains("show") })
    }

    func testBackgroundSPIIsAdmissionPrecondition() {
        let recorder = DeskflowCursorRecorder(backgroundResults: [nil])
        let isolation = makeIsolation(recorder)

        XCTAssertFalse(isolation.begin(generation: 1))
        XCTAssertEqual(recorder.events, ["background"])
        XCTAssertNil(isolation.activeGenerationForTesting)
    }

    func testSuppressionIntervalUnavailableRejectsAdmissionWithoutDisassociation() {
        let recorder = DeskflowCursorRecorder(suppressionResults: [nil, 0])
        let isolation = makeIsolation(recorder)

        XCTAssertFalse(isolation.begin(generation: 22))
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertFalse(isolation.isDisassociatedForTesting)
        XCTAssertEqual(
            recorder.events,
            ["background", "associate:true", "suppression:0.0001", "suppression:0"]
        )
    }

    func testDisassociateFailureReassociatesAndResetsSuppressionInterval() {
        let recorder = DeskflowCursorRecorder(
            associateResults: [.success, .failure, .success]
        )
        let isolation = makeIsolation(recorder)

        XCTAssertFalse(isolation.begin(generation: 3))
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertFalse(isolation.isDisassociatedForTesting)
        XCTAssertEqual(
            recorder.events,
            [
                "background", "associate:true", "suppression:0.0001", "associate:false",
                "associate:true", "suppression:0"
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

    func testCleanupFailureRetainsEpochAndForceResetRetriesOnlyAssociationDebt() {
        let recorder = DeskflowCursorRecorder(
            associateResults: [.success, .success, .failure, .success],
            suppressionResults: [0, 0, 0]
        )
        let isolation = makeIsolation(recorder)

        XCTAssertTrue(isolation.begin(generation: 6))
        XCTAssertFalse(isolation.end(generation: 6))
        XCTAssertEqual(isolation.activeGenerationForTesting, 6)
        XCTAssertTrue(isolation.isDisassociatedForTesting,
                      "failed first return association must retain hardware-coupling debt")

        isolation.forceReset()
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertFalse(isolation.isDisassociatedForTesting)
        XCTAssertFalse(recorder.events.contains { $0.contains("hide") || $0.contains("show") })
    }

    func testProductionPolicyUsesNoAbsoluteHoldMutationButKeepsRestore() {
        XCTAssertFalse(CursorMutationExecutor.productionPerformsPositionMutation(for: .hold))
        XCTAssertTrue(CursorMutationExecutor.productionPerformsPositionMutation(for: .restore))
    }
}
