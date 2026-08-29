import XCTest
import CoreGraphics
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

private final class GenerationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64?

    func set(_ generation: UInt64) {
        lock.withLock { self.generation = generation }
    }

    var value: UInt64? {
        lock.withLock { generation }
    }
}

private final class TestEventBox: @unchecked Sendable {
    let event: CGEvent

    init(_ event: CGEvent) {
        self.event = event
    }
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

    /// A tap callback that began in suppression generation A must retain A's
    /// identity even when return and a new suppression generation B complete
    /// before the callback emits its event.
    func testSuppressedEventRetainsGenerationAcrossReturnAndReentry() {
        let enteredEmission = DispatchSemaphore(value: 0)
        let continueEmission = DispatchSemaphore(value: 0)
        let capture = InputCapture(
            pointerRestoreOverride: {},
            beforeSuppressedEventEmission: {
                enteredEmission.signal()
                _ = continueEmission.wait(timeout: .now() + 2)
            }
        )
        let observedGeneration = GenerationObservation()
        capture.onPointerEventWithGeneration = { _, generation in
            observedGeneration.set(generation)
        }

        XCTAssertEqual(capture.suppress(), 1)
        let event = TestEventBox(CGEvent(mouseEventSource: nil,
                                         mouseType: .mouseMoved,
                                         mouseCursorPosition: .zero,
                                         mouseButton: .left)!)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = capture.handleForTesting(type: .mouseMoved, event: event.event)
            finished.signal()
        }

        XCTAssertEqual(enteredEmission.wait(timeout: .now() + 1), .success)
        capture.release()
        XCTAssertEqual(capture.suppress(), 2)
        continueEmission.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(observedGeneration.value, 1,
                       "the event must not be relabelled with the re-entry generation")
    }

    func testSuppressedKeyboardEventRetainsGenerationAcrossReturnAndReentry() {
        let enteredEmission = DispatchSemaphore(value: 0)
        let continueEmission = DispatchSemaphore(value: 0)
        let capture = InputCapture(
            pointerRestoreOverride: {},
            beforeSuppressedEventEmission: {
                enteredEmission.signal()
                _ = continueEmission.wait(timeout: .now() + 2)
            }
        )
        let observedGeneration = GenerationObservation()
        capture.onKeyEventWithGeneration = { _, generation in
            observedGeneration.set(generation)
        }

        XCTAssertEqual(capture.suppress(), 1)
        let event = TestEventBox(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = capture.handleForTesting(type: .keyUp, event: event.event)
            finished.signal()
        }

        XCTAssertEqual(enteredEmission.wait(timeout: .now() + 1), .success)
        capture.release()
        XCTAssertEqual(capture.suppress(), 2)
        continueEmission.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(observedGeneration.value, 1,
                       "the key event must not be relabelled with the re-entry generation")
    }
}
