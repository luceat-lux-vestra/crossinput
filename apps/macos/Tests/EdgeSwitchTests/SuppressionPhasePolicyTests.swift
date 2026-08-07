import XCTest
@testable import EdgeSwitch

final class SuppressionPhasePolicyTests: XCTestCase {

    // Rule set (issue #37): connection loss / explicit deactivate -> idle,
    // fatal error -> error, live-connection releases -> ready.

    func testNormalReturnWithLiveConnectionIsReady() {
        XCTAssertEqual(
            SuppressionPhasePolicy.nextPhase(after: .normalReturn, isConnected: true),
            .ready)
    }

    func testWatchdogTimeoutWithLiveConnectionIsReady() {
        XCTAssertEqual(
            SuppressionPhasePolicy.nextPhase(after: .watchdogTimeout, isConnected: true),
            .ready)
    }

    func testEmergencyHotkeyWithLiveConnectionIsReady() {
        XCTAssertEqual(
            SuppressionPhasePolicy.nextPhase(after: .emergencyHotkey, isConnected: true),
            .ready)
    }

    func testNormalReleaseWithoutConnectionIsIdleNotReady() {
        XCTAssertEqual(
            SuppressionPhasePolicy.nextPhase(after: .normalReturn, isConnected: false),
            .idle)
    }

    func testConnectionLostIsNeverReady() {
        XCTAssertEqual(
            SuppressionPhasePolicy.nextPhase(after: .connectionLost, isConnected: false),
            .idle)
        XCTAssertEqual(
            SuppressionPhasePolicy.nextPhase(after: .connectionLost, isConnected: true),
            .idle)
    }

    func testCaptureStoppedIsIdle() {
        XCTAssertEqual(
            SuppressionPhasePolicy.nextPhase(after: .captureStopped, isConnected: true),
            .idle)
    }

    func testFatalErrorIsError() {
        XCTAssertEqual(
            SuppressionPhasePolicy.nextPhase(after: .fatalError, isConnected: true),
            .error)
    }
}