import XCTest
@testable import App
import InputCapability
import AndroidBridge

private final class AppTestCapabilitySystem: InputCapabilitySystem, @unchecked Sendable {
    private let lock = NSLock()
    private var accessibilityStorage: Bool
    private var monitoringStorage: Bool

    init(accessibility: Bool, monitoring: Bool) {
        accessibilityStorage = accessibility
        monitoringStorage = monitoring
    }

    func accessibilityTrusted() -> Bool { lock.withLock { accessibilityStorage } }
    func requestAccessibility() {}
    func listenEventAccessGranted() -> Bool { lock.withLock { monitoringStorage } }
    func requestListenEventAccess() {}

    func set(accessibility: Bool? = nil, monitoring: Bool? = nil) {
        lock.withLock {
            if let accessibility { accessibilityStorage = accessibility }
            if let monitoring { monitoringStorage = monitoring }
        }
    }
}

private final class AppTestCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var canStartStorage: Bool
    private var startCountStorage = 0
    private var stopCountStorage = 0

    init(canStart: Bool) {
        canStartStorage = canStart
    }

    func start() -> Bool {
        lock.withLock {
            startCountStorage += 1
            return canStartStorage
        }
    }

    func stop() {
        lock.withLock {
            stopCountStorage += 1
        }
    }

    func setCanStart(_ canStart: Bool) {
        lock.withLock {
            canStartStorage = canStart
        }
    }

    var startCount: Int { lock.withLock { startCountStorage } }
    var stopCount: Int { lock.withLock { stopCountStorage } }
}

@MainActor
final class InputCapabilityIntegrationTests: XCTestCase {
    private let selectedTarget = RemoteTarget(
        id: RemoteTargetID(rawValue: 7), name: "DeX", kind: .external,
        availability: .available, width: 1920, height: 1080,
        densityDpi: 160, rotation: 0, uniqueId: "dex")

    private func readyModel(
        accessibility: Bool,
        monitoring: Bool,
        captureStarts: Bool
    ) -> (AppModel, AppTestCapabilitySystem, InputCapabilityController) {
        let system = AppTestCapabilitySystem(accessibility: accessibility, monitoring: monitoring)
        let capabilities = InputCapabilityController(system: system)
        let model = AppModel(inputCapabilityController: capabilities,
                             captureStart: { captureStarts })
        model.sessionState = .ready
        model.targetState = .selected(selectedTarget.id)
        return (model, system, capabilities)
    }

    func testMissingAccessibilityBlocksControlWithoutFailingReadySession() {
        let (model, _, _) = readyModel(accessibility: false, monitoring: false,
                                       captureStarts: false)

        XCTAssertEqual(model.enable(), .missingAccessibility)
        XCTAssertEqual(model.sessionState, .ready)
        XCTAssertEqual(model.controlState, .disabled)
        XCTAssertEqual(model.accessibilityStatusText, "Required")
        XCTAssertEqual(model.inputControlStatusText,
                       "Accessibility is required for Edge Switch")
    }

    func testTapFailureWithMissingListenAccessClassifiesInputMonitoring() {
        let (model, _, _) = readyModel(accessibility: true, monitoring: false,
                                       captureStarts: false)

        XCTAssertEqual(model.enable(), .missingInputMonitoring)
        XCTAssertEqual(model.sessionState, .ready)
        XCTAssertTrue(model.inputMonitoringRequired)
        XCTAssertEqual(model.inputMonitoringStatusText, "Required")
    }

    func testTapFailureWithListenAccessIsNonPermissionCaptureFailure() {
        let (model, _, _) = readyModel(accessibility: true, monitoring: true,
                                       captureStarts: false)

        XCTAssertEqual(model.enable(), .captureUnavailable)
        XCTAssertEqual(model.sessionState, .ready)
        XCTAssertEqual(model.inputControlStatusText, "Input capture could not be created")
    }

    func testWorkingModifyingTapDoesNotRequireSeparateInputMonitoringGrant() {
        let (model, _, _) = readyModel(accessibility: true, monitoring: false,
                                       captureStarts: true)

        XCTAssertEqual(model.enable(), .enabled)
        XCTAssertEqual(model.sessionState, .ready)
        XCTAssertFalse(model.inputMonitoringRequired)
        XCTAssertEqual(model.inputMonitoringStatusText, "Not separately granted")
        XCTAssertNil(model.inputControlStatusText)
    }

    func testAccessibilityLossStopsListeningCaptureWhenEdgeSwitchAlreadyDisabled() {
        let system = AppTestCapabilitySystem(accessibility: true, monitoring: false)
        let capabilities = InputCapabilityController(system: system)
        let captureState = AppTestCaptureState(canStart: true)
        let model = AppModel(
            inputCapabilityController: capabilities,
            captureStart: { captureState.start() },
            captureStop: { captureState.stop() }
        )
        model.sessionState = .ready
        model.targetState = .selected(selectedTarget.id)

        XCTAssertEqual(model.enable(), .enabled)
        model.disableEdgeSwitch()
        XCTAssertEqual(captureState.stopCount, 0)

        system.set(accessibility: false)
        _ = capabilities.refresh()

        XCTAssertEqual(captureState.stopCount, 1)
        XCTAssertEqual(model.sessionState, .ready)
        XCTAssertEqual(model.controlState, .disabled)
    }

    func testRequiredInputMonitoringLossStopsCaptureAndAllowsFreshRetry() {
        let system = AppTestCapabilitySystem(accessibility: true, monitoring: false)
        let capabilities = InputCapabilityController(system: system)
        let captureState = AppTestCaptureState(canStart: false)
        let model = AppModel(
            inputCapabilityController: capabilities,
            captureStart: { captureState.start() },
            captureStop: { captureState.stop() }
        )
        model.sessionState = .ready
        model.targetState = .selected(selectedTarget.id)

        XCTAssertEqual(model.enable(), .missingInputMonitoring)
        XCTAssertEqual(captureState.startCount, 1)
        XCTAssertTrue(model.inputMonitoringRequired)

        system.set(monitoring: true)
        _ = capabilities.refresh()
        captureState.setCanStart(true)
        XCTAssertEqual(model.enable(), .enabled)
        XCTAssertEqual(captureState.startCount, 2)

        system.set(monitoring: false)
        _ = capabilities.refresh()

        XCTAssertEqual(captureState.stopCount, 1)
        XCTAssertEqual(model.sessionState, .ready)
        XCTAssertEqual(model.controlState, .disabled)
        XCTAssertEqual(model.inputControlStatusText,
                       "Input Monitoring is required on this Mac configuration")

        system.set(monitoring: true)
        _ = capabilities.refresh()
        XCTAssertEqual(model.enable(), .enabled)
        XCTAssertEqual(captureState.startCount, 3)
        XCTAssertEqual(model.sessionState, .ready)
    }

    func testRuntimeAccessibilityLossDisablesControlButPreservesSession() {
        let (model, system, capabilities) = readyModel(accessibility: true, monitoring: false,
                                                       captureStarts: true)
        XCTAssertEqual(model.enable(), .enabled)

        system.set(accessibility: false)
        _ = capabilities.refresh()

        XCTAssertEqual(model.sessionState, .ready)
        XCTAssertEqual(model.controlState, .disabled)
        XCTAssertEqual(model.accessibilityStatusText, "Required")
        XCTAssertEqual(model.inputControlStatusText,
                       "Accessibility is required for Edge Switch")
        XCTAssertEqual(model.edgeSwitchActionTitle, "Enable Edge Switch")
    }
}
