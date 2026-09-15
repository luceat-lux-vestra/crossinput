import Foundation

#if canImport(CoreHID)
import CoreHID
#endif

private enum ProbeFailure: Error, CustomStringConvertible {
    case unsupportedOS
    case discoveryTimeout
    case clientCreation
    case wrongDevice(String)
    case noXYElements

    var description: String {
        switch self {
        case .unsupportedOS:
            return "CoreHID is unavailable on this macOS version"
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

private actor ProbeCounters {
    private(set) var inputReports = 0
    private(set) var xyElementNotifications = 0
    private(set) var removed = false
    private(set) var externallySeized = false

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

    func snapshot() -> (inputReports: Int, xyElementNotifications: Int, removed: Bool, externallySeized: Bool) {
        (inputReports, xyElementNotifications, removed, externallySeized)
    }
}

@main
private struct TrackpadSeizeProbe {
    static func main() async {
        do {
            #if canImport(CoreHID)
            if #available(macOS 15.0, *) {
                try await runCoreHIDProbe()
                return
            }
            #endif
            throw ProbeFailure.unsupportedOS
        } catch {
            fputs("PROBE_FAIL reason=\(error)\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }
    }

    #if canImport(CoreHID)
    @available(macOS 15.0, *)
    private static func runCoreHIDProbe() async throws {
        print("PROBE_BEGIN backend=CoreHID target=built-in-trackpad duration_seconds=5")
        print("PROBE_SAFETY pointer-only seizure; built-in keyboard remains available; process exit releases the seizure")

        let reference = try await discoverBuiltInTrackpadMouse(timeout: .seconds(3))
        guard let client = HIDDeviceClient(deviceReference: reference) else {
            throw ProbeFailure.clientCreation
        }

        let primaryUsage = await client.primaryUsage
        let isBuiltIn = await client.isBuiltIn
        let product = await client.product
        let transport = await client.transport
        let locationID = await client.locationID
        let descriptorLength = await client.descriptor.count

        guard primaryUsage == .genericDesktop(.mouse) else {
            throw ProbeFailure.wrongDevice("primaryUsage=\(primaryUsage)")
        }
        guard isBuiltIn else {
            throw ProbeFailure.wrongDevice("isBuiltIn=false")
        }
        guard product == "Apple Internal Keyboard / Trackpad" else {
            throw ProbeFailure.wrongDevice("product=\(product ?? "nil")")
        }

        let elements = await client.elements
        let xyElements = elements.filter {
            $0.usage == .genericDesktop(.x) || $0.usage == .genericDesktop(.y)
        }
        guard !xyElements.isEmpty else {
            throw ProbeFailure.noXYElements
        }

        print(
            "PROBE_DEVICE_MATCH product=Apple_Internal_Keyboard_Trackpad "
                + "built_in=true usage=generic_desktop_mouse "
                + "transport=\(String(describing: transport)) "
                + "location_id_present=\(locationID != nil) "
                + "descriptor_length=\(descriptorLength) "
                + "xy_element_count=\(xyElements.count)"
        )

        // Apple requires no outstanding monitor/get/set/update calls when seizeDevice() is invoked.
        // Keep discovery and descriptor inspection complete before taking exclusive ownership.
        do {
            try await client.seizeDevice()
        } catch {
            print("PROBE_SEIZE_FAIL error=\(String(describing: error))")
            throw error
        }

        print("PROBE_SEIZE_OK")
        print("PROBE_MOVE_NOW expected_host_pointer=stationary expected_xy_notifications=nonzero")

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
                    case .deviceRemoved:
                        await counters.recordRemoved()
                    case .deviceUnseized:
                        break
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

        try await Task.sleep(for: .seconds(5))
        monitorTask.cancel()
        _ = await monitorTask.result

        let snapshot = await counters.snapshot()
        print(
            "PROBE_OBSERVATION input_reports=\(snapshot.inputReports) "
                + "xy_element_notifications=\(snapshot.xyElementNotifications) "
                + "device_removed=\(snapshot.removed) "
                + "externally_seized=\(snapshot.externallySeized)"
        )
        print("PROBE_RELEASE client_lifetime_ending=true")

        // CoreHID exposes seizure as a client-lifetime lease. Returning from this
        // function drops the final client reference after the monitor is cancelled;
        // no cursor warp/association/visibility API is touched by this probe.
        print("PROBE_END judge_native_cursor_health_after_process_exit=true")
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
