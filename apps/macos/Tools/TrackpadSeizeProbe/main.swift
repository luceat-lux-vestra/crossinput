import Foundation

#if canImport(CoreHID)
import CoreHID
#endif

private enum ProbeFailure: Error, CustomStringConvertible {
    case unsupportedOS
    case invalidMode(String?)
    case discoveryTimeout
    case clientCreation
    case wrongDevice(String)
    case noXYElements

    var description: String {
        switch self {
        case .unsupportedOS:
            return "CoreHID is unavailable on this macOS version"
        case .invalidMode(let value):
            return "invalid or missing mode=\(value ?? "nil"); use --mode discovery-only|client-only|identity-only|metadata-only|monitor-only|seize-only|seize-monitor"
        case .discoveryTimeout:
            return "no built-in Apple trackpad mouse component was discovered before timeout"
        case .clientCreation:
            return "HIDDeviceClient creation failed"
        case .wrongDevice(let detail):
            return "matched HID device did not satisfy the built-in trackpad identity contract: \(detail)"
        case .noXYElements:
            return "matched device exposes no Generic Desktop X/Y elements"
        }
    }
}

private enum ProbeMode: String {
    case discoveryOnly = "discovery-only"
    case clientOnly = "client-only"
    case identityOnly = "identity-only"
    case metadataOnly = "metadata-only"
    case monitorOnly = "monitor-only"
    case seizeOnly = "seize-only"
    case seizeMonitor = "seize-monitor"
}

private actor ProbeCounters {
    private(set) var inputReports = 0
    private(set) var xyElementNotifications = 0
    private(set) var removed = false
    private(set) var externallySeized = false
    private(set) var unseized = false

    func recordInputReport() {
        inputReports += 1
    }

    func recordXYElementNotification(_ count: Int) {
        xyElementNotifications += count
    }

    func recordRemoved() {
        removed = true
    }

    func recordExternalSeizure() {
        externallySeized = true
    }

    func recordUnseized() {
        unseized = true
    }

    func snapshot() -> (
        inputReports: Int,
        xyElementNotifications: Int,
        removed: Bool,
        externallySeized: Bool,
        unseized: Bool
    ) {
        (inputReports, xyElementNotifications, removed, externallySeized, unseized)
    }
}

@main
private struct TrackpadSeizeProbe {
    static func main() async {
        do {
            #if canImport(CoreHID)
            if #available(macOS 15.0, *) {
                let mode = try parseMode()
                try await runCoreHIDProbe(mode: mode)
                return
            }
            #endif
            throw ProbeFailure.unsupportedOS
        } catch {
            fputs("PROBE_FAIL reason=\(error)\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func parseMode() throws -> ProbeMode {
        let arguments = CommandLine.arguments
        guard arguments.count == 3,
              arguments[1] == "--mode",
              let mode = ProbeMode(rawValue: arguments[2]) else {
            throw ProbeFailure.invalidMode(arguments.dropFirst().last)
        }
        return mode
    }

    #if canImport(CoreHID)
    @available(macOS 15.0, *)
    private static func runCoreHIDProbe(mode: ProbeMode) async throws {
        print("PROBE_BEGIN backend=CoreHID target=built-in-trackpad mode=\(mode.rawValue)")
        print("PROBE_PRECONDITION active_key_resizable_window_required=true native_directional_cursor_must_be_HEALTHY_before_start=true")
        print("PROBE_ORACLE keep_same_window_key=true test_same_resize_edge_before_and_after=true")

        let reference = try await discoverBuiltInTrackpadMouse(timeout: .seconds(3))
        print("PROBE_DISCOVERY_OK")

        if mode == .discoveryOnly {
            await liveHealthCheck(boundary: "manager_discovery_lifecycle")
            print("PROBE_END boundary=manager_discovery_lifecycle expected_post_cursor_health=HEALTHY")
            return
        }

        guard let client = HIDDeviceClient(deviceReference: reference) else {
            throw ProbeFailure.clientCreation
        }
        print("PROBE_CLIENT_OK")

        if mode == .clientOnly {
            await liveHealthCheck(boundary: "device_client_construction")
            print("PROBE_END boundary=device_client_construction expected_post_cursor_health=HEALTHY")
            return
        }

        let primaryUsage = await client.primaryUsage
        let isBuiltIn = await client.isBuiltIn
        let product = await client.product

        guard primaryUsage == .genericDesktop(.mouse) else {
            throw ProbeFailure.wrongDevice("primaryUsage=\(primaryUsage)")
        }
        guard isBuiltIn else {
            throw ProbeFailure.wrongDevice("isBuiltIn=false")
        }
        guard product == "Apple Internal Keyboard / Trackpad" else {
            throw ProbeFailure.wrongDevice("product=\(product ?? "nil")")
        }

        print("PROBE_IDENTITY_OK built_in=true usage=generic_desktop_mouse product=Apple_Internal_Keyboard_Trackpad")

        if mode == .identityOnly {
            await liveHealthCheck(boundary: "identity_reads")
            print("PROBE_END boundary=identity_reads expected_post_cursor_health=HEALTHY")
            return
        }

        let transport = await client.transport
        let locationID = await client.locationID
        let descriptorLength = await client.descriptor.count
        let elements = await client.elements
        let xyElements = elements.filter {
            $0.usage == .genericDesktop(.x) || $0.usage == .genericDesktop(.y)
        }
        guard !xyElements.isEmpty else {
            throw ProbeFailure.noXYElements
        }

        print(
            "PROBE_METADATA_OK "
                + "transport=\(String(describing: transport)) "
                + "location_id_present=\(locationID != nil) "
                + "descriptor_length=\(descriptorLength) "
                + "xy_element_count=\(xyElements.count)"
        )

        if mode == .metadataOnly {
            await liveHealthCheck(boundary: "metadata_reads")
            print("PROBE_END boundary=metadata_reads expected_post_cursor_health=HEALTHY")
            return
        }

        switch mode {
        case .monitorOnly:
            print("PROBE_CONTROL no_seize=true monitor=true duration_seconds=5")
            print("PROBE_MOVE_NOW expected_host_pointer=moving expected_xy_notifications=nonzero")
            let snapshot = await monitor(client: client, xyElements: xyElements, duration: .seconds(5))
            printObservation(snapshot)
            await liveHealthCheck(boundary: "device_notification_monitor_cancelled_client_alive")
            print("PROBE_END boundary=device_notification_monitor expected_post_cursor_health=HEALTHY")

        case .seizeOnly:
            try await seize(client)
            print("PROBE_CONTROL seize=true monitor=false duration_seconds=5")
            print("PROBE_MOVE_NOW expected_host_pointer=stationary")
            try await Task.sleep(for: .seconds(5))
            print("PROBE_RELEASE client_lifetime_ending=true")
            print("PROBE_END boundary=device_seizure expected_local_pointer=immediate expected_post_cursor_health=HEALTHY")

        case .seizeMonitor:
            try await seize(client)
            print("PROBE_CONTROL seize=true monitor=true duration_seconds=5")
            print("PROBE_MOVE_NOW expected_host_pointer=stationary expected_xy_notifications=nonzero")
            let snapshot = await monitor(client: client, xyElements: xyElements, duration: .seconds(5))
            printObservation(snapshot)
            print("PROBE_RELEASE client_lifetime_ending=true")
            print("PROBE_END boundary=device_seizure_plus_monitor expected_local_pointer=immediate expected_post_cursor_health=HEALTHY")

        case .discoveryOnly, .clientOnly, .identityOnly, .metadataOnly:
            fatalError("pre-monitor probe mode should have returned before control-stage switch")
        }
    }

    private static func liveHealthCheck(boundary: String) async {
        print("PROBE_LIVE_HEALTH_CHECK_NOW boundary=\(boundary) process_alive=true duration_seconds=8")
        print("PROBE_LIVE_HEALTH_CHECK_ACTION test_native_directional_or_resize_cursor_now=true")
        do {
            try await Task.sleep(for: .seconds(8))
        } catch {
            // No cancellation is expected in the bounded manual probe.
        }
        print("PROBE_LIVE_HEALTH_CHECK_END boundary=\(boundary) process_exit_next=true")
    }

    @available(macOS 15.0, *)
    private static func seize(_ client: HIDDeviceClient) async throws {
        do {
            try await client.seizeDevice()
        } catch {
            print("PROBE_SEIZE_FAIL error=\(String(describing: error))")
            throw error
        }
        print("PROBE_SEIZE_OK")
    }

    @available(macOS 15.0, *)
    private static func monitor(
        client: HIDDeviceClient,
        xyElements: [HIDElement],
        duration: Duration
    ) async -> (
        inputReports: Int,
        xyElementNotifications: Int,
        removed: Bool,
        externallySeized: Bool,
        unseized: Bool
    ) {
        let counters = ProbeCounters()
        let monitorTask = Task {
            do {
                for try await notification in await client.monitorNotifications(
                    reportIDsToMonitor: [HIDReportID.allReports],
                    elementsToMonitor: xyElements
                ) {
                    if Task.isCancelled { break }
                    switch notification {
                    case .inputReport:
                        await counters.recordInputReport()
                    case .elementUpdates(let values):
                        let xyCount = values.reduce(into: 0) { count, value in
                            if value.element.usage == .genericDesktop(.x)
                                || value.element.usage == .genericDesktop(.y) {
                                count += 1
                            }
                        }
                        if xyCount > 0 {
                            await counters.recordXYElementNotification(xyCount)
                        }
                    case .deviceSeized:
                        await counters.recordExternalSeizure()
                    case .deviceUnseized:
                        await counters.recordUnseized()
                    case .deviceRemoved:
                        await counters.recordRemoved()
                    @unknown default:
                        break
                    }
                }
            } catch is CancellationError {
                // Expected when the bounded observation window ends.
            } catch {
                fputs("PROBE_MONITOR_FAIL error=\(String(describing: error))\n", stderr)
            }
        }

        do {
            try await Task.sleep(for: duration)
        } catch {
            monitorTask.cancel()
        }
        monitorTask.cancel()
        _ = await monitorTask.result
        return await counters.snapshot()
    }

    private static func printObservation(
        _ snapshot: (
            inputReports: Int,
            xyElementNotifications: Int,
            removed: Bool,
            externallySeized: Bool,
            unseized: Bool
        )
    ) {
        print(
            "PROBE_OBSERVATION input_reports=\(snapshot.inputReports) "
                + "xy_element_notifications=\(snapshot.xyElementNotifications) "
                + "device_removed=\(snapshot.removed) "
                + "externally_seized=\(snapshot.externallySeized) "
                + "unseized=\(snapshot.unseized)"
        )
    }

    @available(macOS 15.0, *)
    private static func discoverBuiltInTrackpadMouse(
        timeout: Duration
    ) async throws -> HIDDeviceClient.DeviceReference {
        try await withThrowingTaskGroup(of: HIDDeviceClient.DeviceReference.self) { group in
            group.addTask {
                let manager = HIDDeviceManager()
                let criteria = HIDDeviceManager.DeviceMatchingCriteria(
                    primaryUsage: .genericDesktop(.mouse),
                    product: "Apple Internal Keyboard / Trackpad",
                    isBuiltIn: true
                )

                for try await notification in await manager.monitorNotifications(
                    matchingCriteria: [criteria]
                ) {
                    switch notification {
                    case .deviceMatched(let reference):
                        return reference
                    case .deviceRemoved:
                        continue
                    @unknown default:
                        continue
                    }
                }
                throw ProbeFailure.discoveryTimeout
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProbeFailure.discoveryTimeout
            }

            defer { group.cancelAll() }
            guard let reference = try await group.next() else {
                throw ProbeFailure.discoveryTimeout
            }
            return reference
        }
    }
    #endif
}
