import XCTest
@testable import InputCapture
import Diagnostics

private final class RecordingCursorVisibility: CursorVisibilityAPI {
    private(set) var hideCount = 0
    private(set) var showCount = 0
    let hideResult: CGError
    let showResult: CGError

    init(hideResult: CGError = .success, showResult: CGError = .success) {
        self.hideResult = hideResult
        self.showResult = showResult
    }

    func hideCursor() -> CGError {
        hideCount += 1
        return hideResult
    }

    func showCursor() -> CGError {
        showCount += 1
        return showResult
    }
}

private final class ReleaseObservation: @unchecked Sendable {
    var releases: [(SuppressionReleaseReason, UInt64)] = []
}

final class CursorVisibilityTests: XCTestCase {
    private func makeCapture(
        _ cursor: RecordingCursorVisibility,
        released: (@Sendable (SuppressionReleaseReason, UInt64) -> Void)? = nil
    ) -> InputCapture {
        let capture = InputCapture(
            cursorVisibility: cursor,
            pointerRestoreOverride: {}
        )
        capture.onSuppressionReleased = released
        return capture
    }

    func testEveryReleaseReasonBalancesOneHideAndOneShow() {
        let reasons: [SuppressionReleaseReason] = [
            .normalReturn,
            .watchdogTimeout,
            .emergencyHotkey,
            .remoteUnavailable,
            .externalControl,
        ]

        for reason in reasons {
            let cursor = RecordingCursorVisibility()
            let observation = ReleaseObservation()
            let capture = makeCapture(cursor) {
                observation.releases.append(($0, $1))
            }

            XCTAssertNotNil(capture.suppress(), "suppression must start for \(reason)")
            XCTAssertNil(capture.suppress(), "duplicate suppression must be ignored")
            capture.release(reason: reason)
            capture.release(reason: reason)

            XCTAssertEqual(cursor.hideCount, 1, "hide count for \(reason)")
            XCTAssertEqual(cursor.showCount, 1, "show count for \(reason)")
            XCTAssertEqual(observation.releases.map(\.0), [reason])
            XCTAssertEqual(observation.releases.map(\.1), [1])
        }
    }

    func testCaptureStopReleasesAnActiveSuppressionOnce() {
        let cursor = RecordingCursorVisibility()
        let capture = makeCapture(cursor)

        XCTAssertNotNil(capture.suppress())
        capture.stop()
        capture.stop()

        XCTAssertEqual(cursor.hideCount, 1)
        XCTAssertEqual(cursor.showCount, 1)
    }

    func testNonMainHandoffAndMutableEventDisplayDoNotAffectCursorBalance() {
        let cursor = RecordingCursorVisibility()
        let capture = makeCapture(cursor)

        // The handoff starts on a non-main display, then the current event
        // display becomes nil and another display before release.
        capture.setCurrentEventDisplayForTesting(42)
        XCTAssertNotNil(capture.suppress())
        capture.setCurrentEventDisplayForTesting(nil)
        capture.setCurrentEventDisplayForTesting(99)
        capture.release(reason: .emergencyHotkey)
        capture.release(reason: .emergencyHotkey)

        XCTAssertEqual(cursor.hideCount, 1)
        XCTAssertEqual(cursor.showCount, 1)
    }

    func testDiagnosticsRecordActualCursorResultsAndTransitions() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-diag-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let logURL = tempDir.appendingPathComponent("diag.log")
        let previousLogURL = Diagnostics.logURL
        Diagnostics.logURL = logURL
        defer {
            Diagnostics.flushSync()
            Diagnostics.logURL = previousLogURL
            try? FileManager.default.removeItem(at: tempDir)
        }

        let cursor = RecordingCursorVisibility()
        let capture = InputCapture(
            cursorVisibility: cursor,
            pointerRestoreOverride: {},
            cursorVisibilityDiagnosticsEnabled: true
        )
        XCTAssertNotNil(capture.suppress())
        capture.release(reason: .normalReturn)
        Diagnostics.flushSync()

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("cursor hide requested"))
        XCTAssertTrue(contents.contains("cursor hide result=CGError(0)"))
        XCTAssertTrue(contents.contains("cursor show requested"))
        XCTAssertTrue(contents.contains("cursor show result=CGError(0)"))
        XCTAssertTrue(contents.contains("isCursorHidden transition false->true"))
        XCTAssertTrue(contents.contains("isCursorHidden transition true->false"))
        XCTAssertFalse(contents.contains("cursor shown (balanced)"))
    }

    func testFailedCoreGraphicsResultsStillUseOneBalancedCallEach() {
        let cursor = RecordingCursorVisibility(hideResult: .cannotComplete, showResult: .cannotComplete)
        let capture = makeCapture(cursor)

        XCTAssertNotNil(capture.suppress())
        capture.release(reason: .remoteUnavailable)

        XCTAssertEqual(cursor.hideCount, 1)
        XCTAssertEqual(cursor.showCount, 1)
    }
}
