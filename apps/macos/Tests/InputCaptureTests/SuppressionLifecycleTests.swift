import XCTest
@testable import InputCapture

private final class ReleaseObservation: @unchecked Sendable {
    var releases: [(SuppressionReleaseReason, UInt64)] = []
}

private final class PointerStateObservation: @unchecked Sendable {
    var restoreCount = 0
    var resetCount = 0
}

private final class KeyCleanupObservation: @unchecked Sendable {
    var ordinary: [CapturedKeyEvent] = []
    var cleanup: [CapturedKeyEvent] = []
}

final class SuppressionLifecycleTests: XCTestCase {
    private func makeCapture(
        released: (@Sendable (SuppressionReleaseReason, UInt64) -> Void)? = nil,
        restore: (() -> Void)? = {}
    ) -> InputCapture {
        let capture = InputCapture(pointerRestoreOverride: restore)
        capture.onSuppressionReleased = released
        return capture
    }

    func testDuplicateSuppressionDoesNotDuplicateReleaseOrGeneration() {
        let reasons: [SuppressionReleaseReason] = [
            .normalReturn,
            .watchdogTimeout,
            .emergencyHotkey,
            .remoteUnavailable,
            .externalControl,
        ]

        for reason in reasons {
            let observation = ReleaseObservation()
            let capture = makeCapture { observation.releases.append(($0, $1)) }

            XCTAssertEqual(capture.suppress(), 1, "suppression must start for \(reason)")
            XCTAssertNil(capture.suppress(), "duplicate suppression must be ignored")
            capture.release(reason: reason)
            capture.release(reason: reason)

            XCTAssertFalse(capture.isSuppressed)
            XCTAssertEqual(observation.releases.map(\.0), [reason])
            XCTAssertEqual(observation.releases.map(\.1), [1])
        }
    }

    func testCaptureStopReleasesActiveSuppressionOnce() {
        let observation = ReleaseObservation()
        let capture = makeCapture { observation.releases.append(($0, $1)) }

        XCTAssertEqual(capture.suppress(), 1)
        capture.stop()
        capture.stop()

        XCTAssertFalse(capture.isSuppressed)
        XCTAssertEqual(observation.releases.map(\.0), [.captureStopped])
        XCTAssertEqual(observation.releases.map(\.1), [1])
    }

    func testCleanupKeyReleaseUsesLifecycleCleanupCallback() {
        let capture = makeCapture()
        let observation = KeyCleanupObservation()
        capture.onKeyEvent = { observation.ordinary.append($0) }
        capture.onCleanupKeyEvent = { observation.cleanup.append($0) }

        XCTAssertEqual(capture.suppress(), 1)
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        XCTAssertNil(capture.handleForTesting(type: .keyDown, event: keyDown))
        capture.release(reason: .captureStopped)

        XCTAssertEqual(observation.ordinary.map(\.action), [0])
        XCTAssertEqual(observation.cleanup.map(\.action), [1])
        XCTAssertEqual(observation.cleanup.map(\.keyCode), [29])
    }

    func testSuppressionGenerationAdvancesAfterRelease() {
        let observation = ReleaseObservation()
        let capture = makeCapture { observation.releases.append(($0, $1)) }

        XCTAssertEqual(capture.suppress(), 1)
        capture.release()
        XCTAssertEqual(capture.suppress(), 2)
        capture.release(reason: .remoteUnavailable)

        XCTAssertEqual(observation.releases.map(\.1), [1, 2])
        XCTAssertEqual(observation.releases.map(\.0), [.normalReturn, .remoteUnavailable])
    }

    func testExternalControlResetsPointerStateWithoutPointerRestore() {
        let observation = PointerStateObservation()
        let capture = makeCapture(restore: { observation.restoreCount += 1 })
        capture.onPointerStateReset = { observation.resetCount += 1 }

        XCTAssertNotNil(capture.suppress())
        capture.release(reason: .externalControl)

        XCTAssertEqual(observation.restoreCount, 0)
        XCTAssertEqual(observation.resetCount, 1)
    }

    func testNormalReturnUsesPointerRestore() {
        let observation = PointerStateObservation()
        let capture = makeCapture(restore: { observation.restoreCount += 1 })

        XCTAssertNotNil(capture.suppress())
        capture.release(reason: .normalReturn)

        XCTAssertEqual(observation.restoreCount, 1)
    }
}
