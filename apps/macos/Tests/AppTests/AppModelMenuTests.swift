import XCTest
@testable import App
import AndroidBridge

@MainActor
final class AppModelMenuTests: XCTestCase {
    private let selectedTarget = RemoteTarget(
        id: RemoteTargetID(rawValue: 7), name: "DeX", kind: .external,
        availability: .available, width: 1920, height: 1080,
        densityDpi: 160, rotation: 0, uniqueId: "dex")

    func testReadyMenuShowsDisableWhenEdgeSwitchIsEnabled() {
        let model = AppModel()
        model.sessionState = .ready
        model.targetState = .selected(selectedTarget.id)
        model.controlState = .local

        XCTAssertEqual(model.edgeSwitchActionTitle, "Disable Edge Switch")
    }

    func testReadyMenuShowsEnableWhenEdgeSwitchIsDisabled() {
        let model = AppModel()
        model.sessionState = .ready
        model.targetState = .selected(selectedTarget.id)
        model.controlState = .disabled

        XCTAssertEqual(model.edgeSwitchActionTitle, "Enable Edge Switch")
    }

    func testDisconnectedMenuHasNoConnectedLifecycleAction() {
        let model = AppModel()
        model.sessionState = .disconnected
        model.targetState = .unavailable

        XCTAssertNil(model.edgeSwitchActionTitle)
        XCTAssertFalse(model.shouldShowDisconnect)
    }

    func testReadySessionKeepsDisconnectAvailableWithoutTargetSelection() {
        let model = AppModel()
        model.sessionState = .ready
        model.targetState = .available

        XCTAssertNil(model.edgeSwitchActionTitle)
        XCTAssertTrue(model.shouldShowDisconnect)
    }
}
