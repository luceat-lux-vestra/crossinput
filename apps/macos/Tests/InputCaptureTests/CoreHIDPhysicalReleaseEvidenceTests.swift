import XCTest
@testable import InputCapture

@available(macOS 15.0, *)
final class CoreHIDPhysicalReleaseEvidenceTests: XCTestCase {
    func testPhysicalReleaseRequiresProcessExitAndIndependentUnseize() {
        XCTAssertFalse(
            CoreHIDPhysicalReleaseEvidence.isProven(
                processExited: false,
                deviceUnseized: false
            )
        )
        XCTAssertFalse(
            CoreHIDPhysicalReleaseEvidence.isProven(
                processExited: true,
                deviceUnseized: false
            ),
            "helper exit alone must never publish local ownership"
        )
        XCTAssertFalse(
            CoreHIDPhysicalReleaseEvidence.isProven(
                processExited: false,
                deviceUnseized: true
            ),
            "witness notification cannot substitute for owner-process exit"
        )
        XCTAssertTrue(
            CoreHIDPhysicalReleaseEvidence.isProven(
                processExited: true,
                deviceUnseized: true
            )
        )
    }
    func testWitnessReleaseEvidenceRequiresOrderedSeizeThenUnseize() {
        var state = CoreHIDUnseizeWitnessState.monitoring

        XCTAssertFalse(
            state.observeUnseized(),
            "unseize before this generation's seizure is not release proof"
        )
        XCTAssertFalse(state.sawSeized)
        XCTAssertFalse(state.isCurrentlySeized)
        XCTAssertFalse(state.releaseProven)

        XCTAssertTrue(state.observeSeized())
        XCTAssertTrue(state.sawSeized)
        XCTAssertTrue(state.isCurrentlySeized)
        XCTAssertFalse(state.releaseProven)

        XCTAssertTrue(state.observeUnseized())
        XCTAssertTrue(state.sawSeized)
        XCTAssertFalse(state.isCurrentlySeized)
        XCTAssertTrue(state.releaseProven)
    }

    func testWitnessFailureCannotBecomeReleaseProof() {
        var state = CoreHIDUnseizeWitnessState.monitoring
        state.fail()

        XCTAssertFalse(state.observeSeized())
        XCTAssertFalse(state.observeUnseized())
        XCTAssertFalse(state.sawSeized)
        XCTAssertFalse(state.isCurrentlySeized)
        XCTAssertFalse(state.releaseProven)
    }

}
