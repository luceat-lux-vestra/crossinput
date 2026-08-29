import XCTest
@testable import InputCapture

private final class RecordingCursorVisibility: CursorVisibilityAPI {
    private(set) var hideCount = 0
    private(set) var showCount = 0

    func hideCursor() -> CGError {
        hideCount += 1
        return .success
    }

    func showCursor() -> CGError {
        showCount += 1
        return .success
    }
}

final class CursorVisibilityTests: XCTestCase {
    private func makeCapture(_ cursor: RecordingCursorVisibility) -> InputCapture {
        InputCapture(
            cursorVisibility: cursor,
            pointerRestoreOverride: {}
        )
    }

    func testDuplicateSuppressionAndReleaseBalanceVisibilityCalls() {
        let cursor = RecordingCursorVisibility()
        let capture = makeCapture(cursor)

        XCTAssertNotNil(capture.suppress())
        XCTAssertNil(capture.suppress())
        capture.release(reason: .normalReturn)
        capture.release(reason: .normalReturn)

        XCTAssertEqual(cursor.hideCount, 1)
        XCTAssertEqual(cursor.showCount, 1)
    }

    func testEveryReleaseReasonShowsCursorExactlyOnce() {
        let reasons: [SuppressionReleaseReason] = [
            .normalReturn,
            .watchdogTimeout,
            .emergencyHotkey,
            .remoteUnavailable,
            .captureStopped,
            .externalControl,
        ]

        for reason in reasons {
            let cursor = RecordingCursorVisibility()
            let capture = makeCapture(cursor)

            XCTAssertNotNil(capture.suppress(), "suppression must start for \(reason)")
            capture.release(reason: reason)
            capture.release(reason: reason)

            XCTAssertEqual(cursor.hideCount, 1, "hide count for \(reason)")
            XCTAssertEqual(cursor.showCount, 1, "show count for \(reason)")
        }
    }

    func testCaptureStopReleasesActiveSuppressionOnce() {
        let cursor = RecordingCursorVisibility()
        let capture = makeCapture(cursor)

        XCTAssertNotNil(capture.suppress())
        capture.stop()
        capture.stop()

        XCTAssertEqual(cursor.hideCount, 1)
        XCTAssertEqual(cursor.showCount, 1)
    }
}
