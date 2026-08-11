import CoreGraphics
import XCTest
@testable import InputCapture
@testable import EdgeSwitch

private final class CaptureObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var pointerStorage: [PointerEvent] = []
    private var keyStorage: [CapturedKeyEvent] = []
    private var releaseStorage: [SuppressionReleaseReason] = []
    private var resetCountStorage = 0

    var pointerEvents: [PointerEvent] {
        lock.lock(); defer { lock.unlock() }
        return pointerStorage
    }

    var keyEvents: [CapturedKeyEvent] {
        lock.lock(); defer { lock.unlock() }
        return keyStorage
    }

    var releases: [SuppressionReleaseReason] {
        lock.lock(); defer { lock.unlock() }
        return releaseStorage
    }

    var resetCount: Int {
        lock.lock(); defer { lock.unlock() }
        return resetCountStorage
    }

    func append(pointer: PointerEvent) {
        lock.lock(); defer { lock.unlock() }
        pointerStorage.append(pointer)
    }

    func append(key: CapturedKeyEvent) {
        lock.lock(); defer { lock.unlock() }
        keyStorage.append(key)
    }

    func append(release: SuppressionReleaseReason) {
        lock.lock(); defer { lock.unlock() }
        releaseStorage.append(release)
    }

    func resetPointerState() {
        lock.lock(); defer { lock.unlock() }
        resetCountStorage += 1
    }
}

final class ExternalControlClassifierTests: XCTestCase {
    func testPhysicalSourceIsNotExternalControl() {
        let classifier = ExternalControlEventClassifier(ownProcessID: 100)
        let source = ExternalControlEventSource(
            processID: 200,
            bundleIdentifier: "com.apple.AppKit")

        XCTAssertFalse(classifier.isExternalControl(source))
    }

    func testCrossInputSelfSourceIsNotExternalControl() {
        let classifier = ExternalControlEventClassifier(ownProcessID: 100)
        let source = ExternalControlEventSource(
            processID: 100,
            bundleIdentifier: "com.carriez.rustdesk")

        XCTAssertFalse(classifier.isExternalControl(source))
    }

    func testRecognizedExternalSourceIsExternalControl() {
        let classifier = ExternalControlEventClassifier(ownProcessID: 100)
        let source = ExternalControlEventSource(
            processID: 200,
            bundleIdentifier: "com.carriez.rustdesk")

        XCTAssertEqual(classifier.provider(for: source), "rustdesk")
        XCTAssertTrue(classifier.isExternalControl(source))
    }

    func testUnknownAndLooseNameSourcesAreNotExternalControl() {
        let classifier = ExternalControlEventClassifier(ownProcessID: 100)
        let unknown = ExternalControlEventSource(
            processID: 200,
            bundleIdentifier: "com.example.remote-client")
        let looseName = ExternalControlEventSource(
            processID: 201,
            bundleIdentifier: "com.example.rustdesk-clone",
            processName: "RustDesk Helper")

        XCTAssertFalse(classifier.isExternalControl(unknown))
        XCTAssertFalse(classifier.isExternalControl(looseName))
    }
}

final class ExternalControlTakeoverTests: XCTestCase {
    private let remoteProcessID: Int32 = 4242
    private let physicalProcessID: Int32 = 4243

    private func makeCapture(_ observation: CaptureObservation) -> InputCapture {
        let resolver: @Sendable (Int32) -> ExternalControlEventSource? = { [remoteProcessID, physicalProcessID] processID in
            switch processID {
            case remoteProcessID:
                return ExternalControlEventSource(processID: processID,
                                                   bundleIdentifier: "com.carriez.rustdesk",
                                                   executablePath: "/Applications/RustDesk.app/Contents/MacOS/RustDesk",
                                                   processName: "RustDesk")
            case physicalProcessID:
                return ExternalControlEventSource(processID: processID,
                                                   bundleIdentifier: "com.apple.AppKit",
                                                   processName: "WindowServer")
            case Int32(ProcessInfo.processInfo.processIdentifier):
                // The self-PID guard must win even when a synthetic event has
                // a provider-looking identity attached to it.
                return ExternalControlEventSource(processID: processID,
                                                   bundleIdentifier: "com.carriez.rustdesk",
                                                   processName: "CrossInput")
            default:
                return nil
            }
        }
        let capture = InputCapture(sourceIdentityResolver: resolver)
        capture.onPointerEvent = { event in observation.append(pointer: event) }
        capture.onKeyEvent = { event in observation.append(key: event) }
        capture.onPointerStateReset = { observation.resetPointerState() }
        capture.onSuppressionReleased = { reason, _ in observation.append(release: reason) }
        return capture
    }

    private func mouseEvent(type: CGEventType, processID: Int32) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil,
                            mouseType: type,
                            mouseCursorPosition: .zero,
                            mouseButton: .left)!
        event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(processID))
        event.setIntegerValueField(.mouseEventDeltaX, value: 4)
        event.setIntegerValueField(.mouseEventDeltaY, value: 0)
        return event
    }

    private func keyEvent(type: CGEventType, processID: Int32) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil,
                            virtualKey: 0,
                            keyDown: type == .keyDown)!
        event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(processID))
        return event
    }

    private func returnedEvent(_ result: Unmanaged<CGEvent>?, is event: CGEvent) -> Bool {
        result?.takeUnretainedValue() === event
    }

    func testPhysicalMouseRemainsForwardedWhileSuppressed() {
        let observation = CaptureObservation()
        let capture = makeCapture(observation)
        _ = capture.suppress()
        let event = mouseEvent(type: .mouseMoved, processID: physicalProcessID)

        XCTAssertFalse(returnedEvent(capture.handleForTesting(type: .mouseMoved, event: event), is: event))
        XCTAssertEqual(observation.pointerEvents.count, 1)
        XCTAssertTrue(capture.isSuppressed)
        capture.release(reason: .externalControl)
    }

    func testCrossInputSyntheticMouseDoesNotTakeOver() {
        let observation = CaptureObservation()
        let capture = makeCapture(observation)
        _ = capture.suppress()
        let selfPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let event = mouseEvent(type: .mouseMoved, processID: selfPID)

        XCTAssertFalse(returnedEvent(capture.handleForTesting(type: .mouseMoved, event: event), is: event))
        XCTAssertEqual(observation.pointerEvents.count, 1)
        XCTAssertTrue(capture.isSuppressed)
        capture.release(reason: .externalControl)
    }

    func testExternalMouseTakesOverAndPassesTheSameEvent() {
        let observation = CaptureObservation()
        let capture = makeCapture(observation)
        _ = capture.suppress()
        let event = mouseEvent(type: .mouseMoved, processID: remoteProcessID)

        XCTAssertTrue(returnedEvent(capture.handleForTesting(type: .mouseMoved, event: event), is: event))
        XCTAssertFalse(capture.isSuppressed)
        XCTAssertTrue(observation.pointerEvents.isEmpty)
        XCTAssertEqual(observation.releases, [.externalControl])
        XCTAssertEqual(observation.resetCount, 1)
    }

    func testExternalClickTakesOverAndPassesTheSameEvent() {
        let observation = CaptureObservation()
        let capture = makeCapture(observation)
        _ = capture.suppress()
        let event = mouseEvent(type: .leftMouseDown, processID: remoteProcessID)

        XCTAssertTrue(returnedEvent(capture.handleForTesting(type: .leftMouseDown, event: event), is: event))
        XCTAssertFalse(capture.isSuppressed)
        XCTAssertTrue(observation.pointerEvents.isEmpty)
        XCTAssertEqual(observation.resetCount, 1)
    }

    func testExternalKeyboardTakesOverAndPassesTheSameEvent() {
        let observation = CaptureObservation()
        let capture = makeCapture(observation)
        _ = capture.suppress()
        let event = keyEvent(type: .keyDown, processID: remoteProcessID)

        XCTAssertTrue(returnedEvent(capture.handleForTesting(type: .keyDown, event: event), is: event))
        XCTAssertFalse(capture.isSuppressed)
        XCTAssertTrue(observation.keyEvents.isEmpty)
        XCTAssertEqual(observation.resetCount, 1)
    }

    func testExternalEventWhileLocalPassesThroughNormally() {
        let observation = CaptureObservation()
        let capture = makeCapture(observation)
        let event = mouseEvent(type: .mouseMoved, processID: remoteProcessID)

        XCTAssertTrue(returnedEvent(capture.handleForTesting(type: .mouseMoved, event: event), is: event))
        XCTAssertFalse(capture.isSuppressed)
        XCTAssertTrue(observation.releases.isEmpty)
        XCTAssertTrue(observation.pointerEvents.isEmpty)
    }

    func testTakeoverFlushesHeldKeyboardStateAndPointerState() {
        let observation = CaptureObservation()
        let capture = makeCapture(observation)
        _ = capture.suppress()

        _ = capture.handleForTesting(type: .keyDown, event: keyEvent(type: .keyDown, processID: physicalProcessID))
        _ = capture.handleForTesting(type: .leftMouseDown, event: mouseEvent(type: .leftMouseDown, processID: physicalProcessID))
        XCTAssertEqual(observation.keyEvents.map(\.action), [0])

        let takeover = mouseEvent(type: .mouseMoved, processID: remoteProcessID)
        _ = capture.handleForTesting(type: .mouseMoved, event: takeover)

        XCTAssertEqual(observation.keyEvents.map(\.action), [0, 1])
        XCTAssertEqual(observation.resetCount, 1)
        XCTAssertEqual(observation.releases, [.externalControl])
    }
}
