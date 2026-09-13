import XCTest
@testable import InputCapability

private final class FakeInputCapabilitySystem: InputCapabilitySystem, @unchecked Sendable {
    private let lock = NSLock()
    private var accessibilityStorage: Bool
    private var inputMonitoringStorage: Bool
    private var accessibilityRequestsStorage = 0
    private var inputMonitoringRequestsStorage = 0

    init(accessibility: Bool, inputMonitoring: Bool) {
        accessibilityStorage = accessibility
        inputMonitoringStorage = inputMonitoring
    }

    func accessibilityTrusted() -> Bool {
        lock.withLock { accessibilityStorage }
    }

    func requestAccessibility() {
        lock.withLock { accessibilityRequestsStorage += 1 }
    }

    func listenEventAccessGranted() -> Bool {
        lock.withLock { inputMonitoringStorage }
    }

    func requestListenEventAccess() {
        lock.withLock { inputMonitoringRequestsStorage += 1 }
    }

    func set(accessibility: Bool? = nil, inputMonitoring: Bool? = nil) {
        lock.withLock {
            if let accessibility { accessibilityStorage = accessibility }
            if let inputMonitoring { inputMonitoringStorage = inputMonitoring }
        }
    }

    var accessibilityRequests: Int { lock.withLock { accessibilityRequestsStorage } }
    var inputMonitoringRequests: Int { lock.withLock { inputMonitoringRequestsStorage } }
}

@MainActor
final class InputCapabilityTests: XCTestCase {
    func testInitialSnapshotIsSilent() {
        let system = FakeInputCapabilitySystem(accessibility: false, inputMonitoring: false)
        let controller = InputCapabilityController(system: system)

        XCTAssertEqual(controller.snapshot,
                       InputCapabilitySnapshot(accessibilityGranted: false,
                                               inputMonitoringGranted: false))
        XCTAssertEqual(system.accessibilityRequests, 0)
        XCTAssertEqual(system.inputMonitoringRequests, 0)
    }

    func testRefreshPublishesOnlyRealChanges() {
        let system = FakeInputCapabilitySystem(accessibility: false, inputMonitoring: false)
        let controller = InputCapabilityController(system: system)
        var snapshots: [InputCapabilitySnapshot] = []
        controller.onChange = { snapshots.append($0) }

        _ = controller.refresh()
        XCTAssertTrue(snapshots.isEmpty)

        system.set(accessibility: true)
        _ = controller.refresh()
        XCTAssertEqual(snapshots, [
            InputCapabilitySnapshot(accessibilityGranted: true,
                                    inputMonitoringGranted: false),
        ])
    }

    func testAccessibilityRequestIsExplicitAndIdempotentAfterGrant() {
        let system = FakeInputCapabilitySystem(accessibility: false, inputMonitoring: true)
        let controller = InputCapabilityController(system: system)

        _ = controller.requestAccessibility()
        XCTAssertEqual(system.accessibilityRequests, 1)

        system.set(accessibility: true)
        _ = controller.requestAccessibility()
        XCTAssertEqual(system.accessibilityRequests, 1)
    }

    func testInputMonitoringRequestIsExplicitAndIdempotentAfterGrant() {
        let system = FakeInputCapabilitySystem(accessibility: true, inputMonitoring: false)
        let controller = InputCapabilityController(system: system)

        _ = controller.requestInputMonitoring()
        XCTAssertEqual(system.inputMonitoringRequests, 1)

        system.set(inputMonitoring: true)
        _ = controller.requestInputMonitoring()
        XCTAssertEqual(system.inputMonitoringRequests, 1)
    }
}
