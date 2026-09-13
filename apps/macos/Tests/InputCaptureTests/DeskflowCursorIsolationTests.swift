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

    func background(_ enabled: Bool) -> Int32? {
        lock.withLock {
            eventsStorage.append("background:\(enabled)")
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
                setCursorInBackground: { recorder.background($0) },
                associate: { recorder.associate($0) },
                setSuppressionInterval: { recorder.suppression($0) }
            )
        )
    }

    func testVisibleCursorEntryAndReturnBalancesBackgroundAuthority() {
        let recorder = DeskflowCursorRecorder()
        let isolation = makeIsolation(recorder)

        XCTAssertTrue(isolation.begin(generation: 10))
        XCTAssertEqual(isolation.activeGenerationForTesting, 10)
        XCTAssertTrue(isolation.isDisassociatedForTesting)
        XCTAssertTrue(isolation.backgroundAuthorityEnabledForTesting)

        XCTAssertTrue(isolation.end(generation: 10))
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertFalse(isolation.isDisassociatedForTesting)
        XCTAssertFalse(isolation.backgroundAuthorityEnabledForTesting)

        XCTAssertEqual(
            recorder.events,
            [
                "background:true", "associate:true", "suppression:0.0001", "associate:false",
                "associate:true", "associate:true", "suppression:0", "background:false"
            ]
        )
        XCTAssertFalse(recorder.events.contains { $0.contains("hide") || $0.contains("show") })
    }

    func testBackgroundSPIIsAdmissionPrecondition() {
        let recorder = DeskflowCursorRecorder(backgroundResults: [nil])
        let isolation = makeIsolation(recorder)

        XCTAssertFalse(isolation.begin(generation: 1))
        XCTAssertEqual(recorder.events, ["background:true"])
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertFalse(isolation.backgroundAuthorityEnabledForTesting)
    }

    func testSuppressionIntervalFailureRollsBackBackgroundAuthority() {
        let recorder = DeskflowCursorRecorder(
            backgroundResults: [0, 0],
            suppressionResults: [nil, 0]
        )
        let isolation = makeIsolation(recorder)

        XCTAssertFalse(isolation.begin(generation: 22))
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertFalse(isolation.isDisassociatedForTesting)
        XCTAssertFalse(isolation.backgroundAuthorityEnabledForTesting)
        XCTAssertEqual(
            recorder.events,
            [
                "background:true", "associate:true", "suppression:0.0001",
                "suppression:0", "background:false"
            ]
        )
    }

    func testDisassociateFailureReassociatesAndRollsBackBackgroundAuthority() {
        let recorder = DeskflowCursorRecorder(
            backgroundResults: [0, 0],
            associateResults: [.success, .failure, .success]
        )
        let isolation = makeIsolation(recorder)

        XCTAssertFalse(isolation.begin(generation: 3))
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertFalse(isolation.isDisassociatedForTesting)
        XCTAssertFalse(isolation.backgroundAuthorityEnabledForTesting)
        XCTAssertEqual(
            recorder.events,
            [
                "background:true", "associate:true", "suppression:0.0001", "associate:false",
                "associate:true", "suppression:0", "background:false"
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
        XCTAssertTrue(isolation.backgroundAuthorityEnabledForTesting)
    }

    func testCleanupFailureRetainsEpochButDoesNotLeakBalancedSPI() {
        let recorder = DeskflowCursorRecorder(
            backgroundResults: [0, 0],
            associateResults: [.success, .success, .failure, .success],
            suppressionResults: [0, 0, 0]
        )
        let isolation = makeIsolation(recorder)

        XCTAssertTrue(isolation.begin(generation: 6))
        XCTAssertFalse(isolation.end(generation: 6))
        XCTAssertEqual(isolation.activeGenerationForTesting, 6)
        XCTAssertFalse(isolation.isDisassociatedForTesting,
                       "second return association restored hardware coupling")
        XCTAssertFalse(isolation.backgroundAuthorityEnabledForTesting,
                       "successful SPI=false must clear background authority immediately")

        isolation.forceReset()
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertEqual(recorder.events.filter { $0 == "background:false" }.count, 1)
    }

    func testBackgroundResetFailureCreatesDebtAndTeardownRetriesIt() {
        let recorder = DeskflowCursorRecorder(
            backgroundResults: [0, 7, 0],
            suppressionResults: [0, 0, 0]
        )
        let isolation = makeIsolation(recorder)

        XCTAssertTrue(isolation.begin(generation: 7))
        XCTAssertFalse(isolation.end(generation: 7))
        XCTAssertTrue(isolation.backgroundAuthorityEnabledForTesting)
        XCTAssertFalse(isolation.begin(generation: 8))

        isolation.forceReset()
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertFalse(isolation.backgroundAuthorityEnabledForTesting)
        XCTAssertEqual(recorder.events.filter { $0 == "background:false" }.count, 2)
    }

    func testProductionPolicyUsesNoAbsoluteHoldMutationButKeepsRestore() {
        XCTAssertFalse(CursorMutationExecutor.productionPerformsPositionMutation(for: .hold))
        XCTAssertTrue(CursorMutationExecutor.productionPerformsPositionMutation(for: .restore))
    }
}
