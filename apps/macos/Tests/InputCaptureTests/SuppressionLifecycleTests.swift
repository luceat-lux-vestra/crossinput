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

private final class PointerEmissionObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PointerEvent] = []

    func append(_ event: PointerEvent) {
        lock.withLock { storage.append(event) }
    }

    var events: [PointerEvent] {
        lock.withLock { storage }
    }
}

private final class ExternalOwnerActivityObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(UInt64, ExternalPointerOwnerActivity)] = []

    func append(
        _ generation: UInt64,
        _ activity: ExternalPointerOwnerActivity
    ) {
        lock.withLock {
            storage.append((generation, activity))
        }
    }

    var values: [(UInt64, ExternalPointerOwnerActivity)] {
        lock.withLock { storage }
    }
}

private final class BoolObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func set(_ value: Bool) {
        lock.withLock { storage = value }
    }

    var value: Bool {
        lock.withLock { storage }
    }
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

        XCTAssertEqual(observation.ordinary.map(\.transition), [.down])
        XCTAssertEqual(observation.cleanup.map(\.transition), [.up])
        XCTAssertEqual(observation.cleanup.map(\.key), [.a])
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

    func testExternalPointerOwnerPassesPointerThroughWithoutSemanticForwarding() {
        let capture = makeCapture()
        let pointerObservation = PointerEmissionObservation()
        let activityObservation = ExternalOwnerActivityObservation()
        capture.onPointerEvent = { pointerObservation.append($0) }
        capture.onExternalPointerOwnerActivity = {
            activityObservation.append($0, $1)
        }

        XCTAssertEqual(capture.suppressWithExternalPointerOwner(), 1)

        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: .zero,
            mouseButton: .left
        )!
        event.setIntegerValueField(.mouseEventDeltaX, value: 8)
        event.setIntegerValueField(.mouseEventDeltaY, value: -4)

        XCTAssertNotNil(capture.handleForTesting(type: .mouseMoved, event: event))
        XCTAssertTrue(pointerObservation.events.isEmpty)
        XCTAssertEqual(activityObservation.values.count, 1)
        XCTAssertEqual(activityObservation.values.first?.0, 1)
        XCTAssertEqual(
            activityObservation.values.first?.1,
            .incompatibleLocalInput
        )

        capture.release(reason: .normalReturn)
    }

    func testExternalPointerOwnerRefusesHandoffWhileObservedLocalKeyIsHeld() {
        let capture = makeCapture()
        let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        )!
        let keyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: false
        )!

        XCTAssertNotNil(capture.handleForTesting(type: .keyDown, event: keyDown))
        XCTAssertNil(capture.suppressWithExternalPointerOwner())
        XCTAssertFalse(capture.isSuppressed)

        XCTAssertNotNil(capture.handleForTesting(type: .keyUp, event: keyUp))
        let generation = try! XCTUnwrap(
            capture.suppressWithExternalPointerOwner()
        )
        capture.release(reason: .captureStopped, generation: generation)
    }

    func testExternalPointerOwnerRefusesHandoffForHeldModifierAtEdge() {
        let capture = makeCapture()
        let move = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: .zero,
            mouseButton: .left
        )!
        move.flags = [.maskShift]

        XCTAssertNotNil(
            capture.handleForTesting(type: .mouseMoved, event: move)
        )
        XCTAssertNil(capture.suppressWithExternalPointerOwner())

        move.flags = []
        XCTAssertNotNil(
            capture.handleForTesting(type: .mouseMoved, event: move)
        )
        let generation = try! XCTUnwrap(
            capture.suppressWithExternalPointerOwner()
        )
        capture.release(reason: .captureStopped, generation: generation)
    }

    func testExternalPointerOwnerRefusesHandoffForPreexistingDraggedButton() {
        let capture = makeCapture()
        let drag = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: .zero,
            mouseButton: .left
        )!
        let buttonUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: .zero,
            mouseButton: .left
        )!

        XCTAssertNotNil(
            capture.handleForTesting(type: .leftMouseDragged, event: drag)
        )
        XCTAssertNil(capture.suppressWithExternalPointerOwner())

        XCTAssertNotNil(
            capture.handleForTesting(type: .leftMouseUp, event: buttonUp)
        )
        let generation = try! XCTUnwrap(
            capture.suppressWithExternalPointerOwner()
        )
        capture.release(reason: .captureStopped, generation: generation)
    }

    func testTapLifecycleTrustLossBlocksUntilFreshLocalEvent() {
        let capture = makeCapture()
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: .zero,
            mouseButton: .left
        )!

        XCTAssertNotNil(
            capture.handleForTesting(
                type: .tapDisabledByTimeout,
                event: event
            )
        )
        XCTAssertNil(capture.suppressWithExternalPointerOwner())

        XCTAssertNotNil(
            capture.handleForTesting(type: .mouseMoved, event: event)
        )
        let generation = try! XCTUnwrap(
            capture.suppressWithExternalPointerOwner()
        )
        capture.release(reason: .captureStopped, generation: generation)
    }

    func testUnmatchedRemoteKeyUpFailsLocalAndPassesThrough() {
        let capture = makeCapture()
        let activityObservation = ExternalOwnerActivityObservation()
        capture.onExternalPointerOwnerActivity = {
            generation, activity in
            activityObservation.append(generation, activity)
            capture.release(
                reason: .externalControl,
                generation: generation
            )
        }

        let generation = try! XCTUnwrap(
            capture.suppressWithExternalPointerOwner()
        )
        XCTAssertTrue(
            capture.activateExternalPointerOwner(generation: generation)
        )

        let keyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: false
        )!
        XCTAssertNotNil(
            capture.handleForTesting(type: .keyUp, event: keyUp)
        )
        XCTAssertFalse(capture.isSuppressed)
        XCTAssertEqual(
            activityObservation.values.map(\.1),
            [.incompatibleLocalInput]
        )
    }

    func testExternalPointerOwnerKeepsKeyboardLocalUntilLeaseReady() {
        let capture = makeCapture()
        let keyObservation = KeyCleanupObservation()
        let activityObservation = ExternalOwnerActivityObservation()
        capture.onKeyEvent = { keyObservation.ordinary.append($0) }
        capture.onExternalPointerOwnerActivity = {
            activityObservation.append($0, $1)
        }

        let generation = try! XCTUnwrap(
            capture.suppressWithExternalPointerOwner()
        )
        XCTAssertFalse(
            capture.isExternalPointerOwnerActive(generation: generation)
        )

        let localKeyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 1,
            keyDown: true
        )!
        let localKeyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 1,
            keyDown: false
        )!
        XCTAssertNotNil(
            capture.handleForTesting(type: .keyDown, event: localKeyDown)
        )
        XCTAssertTrue(keyObservation.ordinary.isEmpty)
        XCTAssertEqual(
            activityObservation.values.map(\.1),
            [.incompatibleLocalInput]
        )

        capture.release(
            reason: .externalControl,
            generation: generation
        )
        XCTAssertNotNil(
            capture.handleForTesting(type: .keyUp, event: localKeyUp)
        )
        let remoteGeneration = try! XCTUnwrap(
            capture.suppressWithExternalPointerOwner()
        )
        XCTAssertTrue(
            capture.activateExternalPointerOwner(
                generation: remoteGeneration
            )
        )
        XCTAssertTrue(
            capture.isExternalPointerOwnerActive(generation: generation)
        )

        let remoteKeyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        )!
        XCTAssertNil(
            capture.handleForTesting(type: .keyDown, event: remoteKeyDown)
        )
        let remoteKeyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: false
        )!
        XCTAssertNil(
            capture.handleForTesting(type: .keyUp, event: remoteKeyUp)
        )
        XCTAssertEqual(keyObservation.ordinary.map(\.key), [.a, .a])
        XCTAssertEqual(
            keyObservation.ordinary.map(\.transition),
            [.down, .up]
        )

        capture.release(
            reason: .captureStopped,
            generation: remoteGeneration
        )
    }

    func testExternalPointerOwnerDeactivationReturnsKeyboardLocalBeforeRelease() {
        let capture = makeCapture()
        let keyObservation = KeyCleanupObservation()
        let activityObservation = ExternalOwnerActivityObservation()
        capture.onKeyEvent = { keyObservation.ordinary.append($0) }
        capture.onExternalPointerOwnerActivity = {
            activityObservation.append($0, $1)
        }

        let generation = try! XCTUnwrap(
            capture.suppressWithExternalPointerOwner()
        )
        XCTAssertTrue(
            capture.activateExternalPointerOwner(generation: generation)
        )
        XCTAssertTrue(
            capture.deactivateExternalPointerOwner(generation: generation)
        )
        XCTAssertTrue(capture.isSuppressed)
        XCTAssertFalse(
            capture.isExternalPointerOwnerActive(generation: generation)
        )

        let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        )!
        XCTAssertNotNil(
            capture.handleForTesting(type: .keyDown, event: keyDown)
        )
        XCTAssertTrue(keyObservation.ordinary.isEmpty)
        XCTAssertEqual(
            activityObservation.values.map(\.1),
            [.incompatibleLocalInput]
        )

        capture.release(reason: .captureStopped)
    }

    func testExternalPointerOwnerRejectsStaleReadyGeneration() {
        let capture = makeCapture()

        let first = try! XCTUnwrap(
            capture.suppressWithExternalPointerOwner()
        )
        capture.release(reason: .normalReturn)

        let second = try! XCTUnwrap(
            capture.suppressWithExternalPointerOwner()
        )
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(
            capture.activateExternalPointerOwner(generation: first)
        )
        XCTAssertTrue(
            capture.activateExternalPointerOwner(generation: second)
        )

        capture.release(reason: .captureStopped)
    }

    func testExternalPointerOwnerNormalReturnNeverRestoresQuartzPointer() {
        let observation = PointerStateObservation()
        let capture = makeCapture(restore: { observation.restoreCount += 1 })

        XCTAssertEqual(capture.suppressWithExternalPointerOwner(), 1)
        capture.release(reason: .normalReturn)

        XCTAssertEqual(observation.restoreCount, 0)
        XCTAssertTrue(capture.isAwaitingEdgeExitForTesting)
        XCTAssertFalse(capture.isSuppressed)
    }

    func testLegacySuppressionStillUsesPointerRestore() {
        let observation = PointerStateObservation()
        let capture = makeCapture(restore: { observation.restoreCount += 1 })

        XCTAssertEqual(capture.suppress(), 1)
        capture.release(reason: .normalReturn)

        XCTAssertEqual(observation.restoreCount, 1)
    }

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

    func testKeyboardCallbackPassesThroughWhenLocalReturnWinsAdmissionRace() {
        let enteredAdmission = DispatchSemaphore(value: 0)
        let continueAdmission = DispatchSemaphore(value: 0)
        let capture = InputCapture(
            pointerRestoreOverride: {},
            beforeSuppressedKeyboardAdmission: {
                enteredAdmission.signal()
                _ = continueAdmission.wait(timeout: .now() + 2)
            }
        )

        XCTAssertEqual(capture.suppress(), 1)
        let event = TestEventBox(
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: 0,
                keyDown: true
            )!
        )
        let passedThrough = BoolObservation()
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            let result = capture.handleForTesting(
                type: .keyDown,
                event: event.event
            )
            passedThrough.set(result != nil)
            finished.signal()
        }

        XCTAssertEqual(
            enteredAdmission.wait(timeout: .now() + 1),
            .success
        )
        capture.release()
        continueAdmission.signal()

        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(passedThrough.value)
    }

    func testStaleExternalPointerCallbackAbortsReplacementEpoch() {
        let enteredEmission = DispatchSemaphore(value: 0)
        let continueEmission = DispatchSemaphore(value: 0)
        let capture = InputCapture(
            pointerRestoreOverride: {},
            beforeSuppressedEventEmission: {
                enteredEmission.signal()
                _ = continueEmission.wait(timeout: .now() + 2)
            }
        )
        let activity = ExternalOwnerActivityObservation()
        capture.onExternalPointerOwnerActivity = {
            activity.append($0, $1)
        }

        let first = try! XCTUnwrap(
            capture.suppressWithExternalPointerOwner()
        )
        let event = TestEventBox(
            CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: .zero,
                mouseButton: .left
            )!
        )
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = capture.handleForTesting(
                type: .mouseMoved,
                event: event.event
            )
            finished.signal()
        }

        XCTAssertEqual(
            enteredEmission.wait(timeout: .now() + 1),
            .success
        )
        capture.release(reason: .normalReturn, generation: first)
        let replacement = try! XCTUnwrap(
            capture.suppressWithExternalPointerOwner()
        )
        XCTAssertNotEqual(first, replacement)
        continueEmission.signal()

        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(activity.values.count, 1)
        XCTAssertEqual(activity.values.first?.0, replacement)
        XCTAssertEqual(
            activity.values.first?.1,
            .incompatibleLocalInput
        )

        capture.release(
            reason: .captureStopped,
            generation: replacement
        )
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
