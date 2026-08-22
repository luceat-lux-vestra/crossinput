import CoreGraphics
import XCTest
import Carbon.HIToolbox
@testable import InputCapture

/// Regression tests for the in-tap emergency shortcut detection (issue #53).
///
/// The tap consumes every keyboard event while suppressing, so events never
/// reach the window server's Carbon hot-key matching; ⇧⌘X must therefore be
/// detected inside the tap itself or a trapped user has no manual escape.
private final class EmergencyShortcutObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(SuppressionReleaseReason, UInt64)] = []

    var releases: [(SuppressionReleaseReason, UInt64)] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ reason: SuppressionReleaseReason, _ generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        storage.append((reason, generation))
    }
}

private final class SilentCursorVisibility: CursorVisibilityAPI {
    func hideCursor() -> CGError { .success }
    func showCursor() -> CGError { .success }
}

final class EmergencyShortcutTests: XCTestCase {
    private func makeCapture(
        released: @escaping @Sendable (SuppressionReleaseReason, UInt64) -> Void
    ) -> InputCapture {
        let capture = InputCapture(
            cursorVisibility: SilentCursorVisibility(),
            pointerRestoreOverride: {}
        )
        capture.onSuppressionReleased = released
        return capture
    }

    private func makeKeyDownEvent(keyCode: Int, flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyCode),
            keyDown: true
        )!
        event.flags = flags
        return event
    }

    func testShiftCmdXReleasesSuppressionSynchronouslyAndConsumesTheEvent() {
        let observation = EmergencyShortcutObservation()
        let capture = makeCapture { observation.append($0, $1) }
        defer { capture.stop() }

        XCTAssertEqual(capture.suppress(), 1)
        let event = makeKeyDownEvent(
            keyCode: kVK_ANSI_X,
            flags: [.maskCommand, .maskShift]
        )

        let result = capture.handleForTesting(type: .keyDown, event: event)

        XCTAssertNil(result, "the triggering event must be consumed")
        XCTAssertFalse(capture.isSuppressed, "the shortcut must restore listening mode immediately")
        XCTAssertEqual(observation.releases.map(\.0), [.emergencyHotkey])
        XCTAssertEqual(observation.releases.first?.1, 1)
    }

    func testPlainXIsForwardedAsAKeyWithoutReleasing() {
        let observation = EmergencyShortcutObservation()
        let capture = makeCapture { observation.append($0, $1) }
        defer { capture.stop() }

        XCTAssertEqual(capture.suppress(), 1)
        let event = makeKeyDownEvent(keyCode: kVK_ANSI_X, flags: [])

        let result = capture.handleForTesting(type: .keyDown, event: event)

        XCTAssertNil(result, "keyboard input stays suppressed")
        XCTAssertTrue(capture.isSuppressed)
        XCTAssertTrue(observation.releases.isEmpty)
    }

    func testExtraModifierPreventsTheEmergencyTrigger() {
        let observation = EmergencyShortcutObservation()
        let capture = makeCapture { observation.append($0, $1) }
        defer { capture.stop() }

        XCTAssertEqual(capture.suppress(), 1)
        let controlVariant = makeKeyDownEvent(
            keyCode: kVK_ANSI_X,
            flags: [.maskCommand, .maskShift, .maskControl]
        )
        XCTAssertNil(capture.handleForTesting(type: .keyDown, event: controlVariant))

        let optionVariant = makeKeyDownEvent(
            keyCode: kVK_ANSI_X,
            flags: [.maskCommand, .maskAlternate, .maskShift]
        )
        XCTAssertNil(capture.handleForTesting(type: .keyDown, event: optionVariant))

        XCTAssertTrue(capture.isSuppressed)
        XCTAssertTrue(observation.releases.isEmpty)
    }

    func testCommandOnlyXDoesNotTrigger() {
        let observation = EmergencyShortcutObservation()
        let capture = makeCapture { observation.append($0, $1) }
        defer { capture.stop() }

        XCTAssertEqual(capture.suppress(), 1)
        let event = makeKeyDownEvent(keyCode: kVK_ANSI_X, flags: [.maskCommand])

        XCTAssertNil(capture.handleForTesting(type: .keyDown, event: event))
        XCTAssertTrue(capture.isSuppressed)
        XCTAssertTrue(observation.releases.isEmpty)
    }

    func testUnsuppressedShortcutPassesThroughUntouched() {
        let observation = EmergencyShortcutObservation()
        let capture = makeCapture { observation.append($0, $1) }
        defer { capture.stop() }

        let event = makeKeyDownEvent(
            keyCode: kVK_ANSI_X,
            flags: [.maskCommand, .maskShift]
        )

        let result = capture.handleForTesting(type: .keyDown, event: event)

        XCTAssertNotNil(result, "without suppression the event belongs to macOS")
        XCTAssertTrue(capture.isSuppressed == false)
        XCTAssertTrue(observation.releases.isEmpty)
    }
}
