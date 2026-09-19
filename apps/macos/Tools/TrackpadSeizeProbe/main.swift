import Foundation
import CoreGraphics
@preconcurrency import ApplicationServices
import HIDDescriptorSemantics

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
    case descriptorSemantics(String)
    case virtualDeviceCreation

    var description: String {
        switch self {
        case .unsupportedOS:
            return "CoreHID is unavailable on this macOS version"
        case .invalidMode(let value):
            return "invalid or missing mode=\(value ?? "nil"); use --mode discovery-only|client-only|identity-only|metadata-only|descriptor-semantics|synchronous-release|input-surface|hybrid-surface|tap-layers|component-inventory|component-activity|gdm-semantic-signature|virtual-device-capability|monitor-only|seize-only|seize-monitor"
        case .discoveryTimeout:
            return "no built-in Apple trackpad mouse component was discovered before timeout"
        case .clientCreation:
            return "HIDDeviceClient creation failed"
        case .wrongDevice(let detail):
            return "matched HID device did not satisfy the built-in trackpad identity contract: \(detail)"
        case .noXYElements:
            return "matched device exposes no Generic Desktop X/Y elements"
        case .descriptorSemantics(let detail):
            return "descriptor did not prove unambiguous relative X/Y semantics: \(detail)"
        case .virtualDeviceCreation:
            return "HIDVirtualDevice creation failed; verify virtual HID capability/entitlement and signing"
        }
    }
}

private enum ProbeMode: String {
    case discoveryOnly = "discovery-only"
    case clientOnly = "client-only"
    case identityOnly = "identity-only"
    case metadataOnly = "metadata-only"
    case descriptorSemantics = "descriptor-semantics"
    case synchronousRelease = "synchronous-release"
    case inputSurface = "input-surface"
    case hybridSurface = "hybrid-surface"
    case tapLayers = "tap-layers"
    case componentInventory = "component-inventory"
    case componentActivity = "component-activity"
    case gdmSemanticSignature = "gdm-semantic-signature"
    case virtualDeviceCapability = "virtual-device-capability"
    case monitorOnly = "monitor-only"
    case seizeOnly = "seize-only"
    case seizeMonitor = "seize-monitor"
}

#if canImport(CoreHID)
@available(macOS 15.0, *)
private actor DeviceReferenceCollector {
    private var references: [HIDDeviceClient.DeviceReference] = []

    func append(_ reference: HIDDeviceClient.DeviceReference) {
        references.append(reference)
    }

    func snapshot() -> [HIDDeviceClient.DeviceReference] {
        references
    }
}
#endif

@available(macOS 15.0, *)
private final class ProbeVirtualDeviceDelegate: HIDVirtualDeviceDelegate, @unchecked Sendable {
    func hidVirtualDevice(
        _ device: HIDVirtualDevice,
        receivedSetReportRequestOfType type: HIDReportType,
        id: HIDReportID?,
        data: Data
    ) async throws {
        // Capability probe only. No payload logging and no device-specific
        // output behavior is required.
    }

    func hidVirtualDevice(
        _ device: HIDVirtualDevice,
        receivedGetReportRequestOfType type: HIDReportType,
        id: HIDReportID?,
        maxSize: Int
    ) async throws -> Data {
        // Return an empty response rather than inventing device state. This
        // probe only validates creation/activation/visibility.
        Data()
    }
}

@available(macOS 15.0, *)
private actor ComponentActivityCounters {
    private var inputReports = 0
    private var byUsage: [String: Int] = [:]
    private var removed = false
    private var externallySeized = false
    private var unseized = false

    func reset() {
        inputReports = 0
        byUsage.removeAll(keepingCapacity: true)
        removed = false
        externallySeized = false
        unseized = false
    }

    func recordInputReport() {
        inputReports += 1
    }

    func recordElementUpdates(_ values: [HIDElement.Value]) {
        for value in values {
            let usage = String(describing: value.element.usage)
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "\n", with: "_")
            byUsage[usage, default: 0] += 1
        }
    }

    func recordRemoved() { removed = true }
    func recordExternalSeizure() { externallySeized = true }
    func recordUnseized() { unseized = true }

    func snapshot() -> (
        inputReports: Int,
        usages: [(String, Int)],
        removed: Bool,
        externallySeized: Bool,
        unseized: Bool
    ) {
        (
            inputReports,
            byUsage.sorted { $0.key < $1.key },
            removed,
            externallySeized,
            unseized
        )
    }
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


private struct GDMElementAggregate: Sendable {
    var updates = 0
    var logicalPositive = 0
    var logicalNegative = 0
    var logicalZero = 0
    var logicalDecodeFailures = 0
    var rawZero = 0
    var rawNonzero = 0
    var byteLengthCounts: [Int: Int] = [:]
    var uniqueValues: Set<Data> = []
    var bitOnes: [Int] = []
    var bitTransitions: [Int] = []
    var previousBytes: Data?

    mutating func record(_ value: HIDElement.Value) {
        updates += 1

        if let logical = value.logicalValue(asTypeTruncatingIfNeeded: Int64.self) {
            if logical > 0 {
                logicalPositive += 1
            } else if logical < 0 {
                logicalNegative += 1
            } else {
                logicalZero += 1
            }
        } else {
            logicalDecodeFailures += 1
        }

        let raw = value.integerValue(asTypeTruncatingIfNeeded: UInt64.self)
        if raw == 0 {
            rawZero += 1
        } else {
            rawNonzero += 1
        }

        let bytes = value.bytes
        byteLengthCounts[bytes.count, default: 0] += 1
        uniqueValues.insert(bytes)

        let bitCount = bytes.count * 8
        if bitOnes.count < bitCount {
            bitOnes.append(contentsOf: repeatElement(0, count: bitCount - bitOnes.count))
            bitTransitions.append(
                contentsOf: repeatElement(0, count: bitCount - bitTransitions.count)
            )
        }

        let previous = previousBytes.map(Array.init)
        let current = Array(bytes)
        for bitIndex in 0..<bitCount {
            let byteIndex = bitIndex / 8
            let mask = UInt8(1) << UInt8(bitIndex % 8)
            let isOne = (current[byteIndex] & mask) != 0
            if isOne {
                bitOnes[bitIndex] += 1
            }

            if let previous, byteIndex < previous.count {
                let wasOne = (previous[byteIndex] & mask) != 0
                if wasOne != isOne {
                    bitTransitions[bitIndex] += 1
                }
            }
        }

        previousBytes = bytes
    }
}

@available(macOS 15.0, *)
private actor GDMSemanticSignatureCounters {
    private var inputReports = 0
    private var reportIDCounts: [String: Int] = [:]
    private var reportLengthCounts: [Int: Int] = [:]
    private var byUsage: [String: GDMElementAggregate] = [:]

    func reset() {
        inputReports = 0
        reportIDCounts.removeAll(keepingCapacity: true)
        reportLengthCounts.removeAll(keepingCapacity: true)
        byUsage.removeAll(keepingCapacity: true)
    }

    func recordInputReport(id: HIDReportID?, data: Data) {
        inputReports += 1
        let reportID = String(describing: id)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
        reportIDCounts[reportID, default: 0] += 1
        reportLengthCounts[data.count, default: 0] += 1
    }

    func recordElementUpdates(_ values: [HIDElement.Value]) {
        for value in values {
            let usage = String(describing: value.element.usage)
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "\n", with: "_")
            var aggregate = byUsage[usage] ?? GDMElementAggregate()
            aggregate.record(value)
            byUsage[usage] = aggregate
        }
    }

    func summaryLines(phase: String) -> [String] {
        var lines: [String] = []
        lines.append(
            "PROBE_GDM_SIGNATURE_PHASE_END name=\(phase) "
                + "input_reports=\(inputReports) "
                + "usage_bucket_count=\(byUsage.count)"
        )

        for (reportID, count) in reportIDCounts.sorted(by: { $0.key < $1.key }) {
            lines.append(
                "PROBE_GDM_REPORT_ID phase=\(phase) id=\(reportID) count=\(count)"
            )
        }
        for (length, count) in reportLengthCounts.sorted(by: { $0.key < $1.key }) {
            lines.append(
                "PROBE_GDM_REPORT_LENGTH phase=\(phase) bytes=\(length) count=\(count)"
            )
        }

        for (usage, aggregate) in byUsage.sorted(by: { $0.key < $1.key }) {
            let lengths = aggregate.byteLengthCounts
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            lines.append(
                "PROBE_GDM_USAGE phase=\(phase) "
                    + "usage=\(usage) "
                    + "updates=\(aggregate.updates) "
                    + "logical_positive=\(aggregate.logicalPositive) "
                    + "logical_negative=\(aggregate.logicalNegative) "
                    + "logical_zero=\(aggregate.logicalZero) "
                    + "logical_decode_failures=\(aggregate.logicalDecodeFailures) "
                    + "raw_zero=\(aggregate.rawZero) "
                    + "raw_nonzero=\(aggregate.rawNonzero) "
                    + "unique_value_count=\(aggregate.uniqueValues.count) "
                    + "byte_lengths=\(lengths)"
            )

            if usage.contains("page:_65280,_usage:_12") {
                for bitIndex in aggregate.bitOnes.indices {
                    let ones = aggregate.bitOnes[bitIndex]
                    let transitions = aggregate.bitTransitions[bitIndex]
                    if ones > 0 || transitions > 0 {
                        lines.append(
                            "PROBE_GDM_VENDOR_BIT phase=\(phase) "
                                + "bit=\(bitIndex) ones=\(ones) transitions=\(transitions)"
                        )
                    }
                }
            }
        }

        return lines
    }
}

private struct SurfaceBucket: Sendable {
    var updates = 0
    var positive = 0
    var negative = 0
    var zero = 0
    var decodeFailures = 0
}

private final class EventTypeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [UInt32: Int] = [:]

    func reset() {
        lock.withLock {
            counts.removeAll(keepingCapacity: true)
        }
    }

    func record(_ type: CGEventType) {
        lock.withLock {
            counts[type.rawValue, default: 0] += 1
        }
    }

    func snapshot() -> [(UInt32, Int)] {
        lock.withLock {
            counts.sorted { lhs, rhs in lhs.key < rhs.key }
        }
    }
}

private final class ListenOnlyEventTap: @unchecked Sendable {
    private let counter: EventTypeCounter
    private let location: CGEventTapLocation
    private let queue: DispatchQueue
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    init(counter: EventTypeCounter, location: CGEventTapLocation, label: String) {
        self.counter = counter
        self.location = location
        self.queue = DispatchQueue(
            label: "crossinput.trackpad-probe.event-tap.\(label)",
            qos: .userInteractive
        )
    }

    func start() -> Bool {
        var mask: CGEventMask = 0
        let eventTypes: [CGEventType] = [
            .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .scrollWheel
        ]
        for type in eventTypes {
            mask |= CGEventMask(1 << type.rawValue)
        }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }
            let owner = Unmanaged<ListenOnlyEventTap>.fromOpaque(refcon).takeUnretainedValue()
            owner.counter.record(type)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: location,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        self.tap = tap
        self.source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        queue.async { [weak self] in
            guard let self, let source = self.source else { return }
            let runLoop = CFRunLoopGetCurrent()
            self.runLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CFRunLoopRun()
        }
        return true
    }

    func stop() {
        if let tap {
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        source = nil
        if let runLoop {
            CFRunLoopStop(runLoop)
            self.runLoop = nil
        }
    }

    deinit {
        stop()
    }
}

@available(macOS 15.0, *)
private actor InputSurfaceCounters {
    private var inputReports = 0
    private var byUsage: [String: SurfaceBucket] = [:]

    func reset() {
        inputReports = 0
        byUsage.removeAll(keepingCapacity: true)
    }

    func recordInputReport() {
        inputReports += 1
    }

    func record(_ values: [HIDElement.Value]) {
        for value in values {
            let usage = String(describing: value.element.usage)
            var bucket = byUsage[usage] ?? SurfaceBucket()
            bucket.updates += 1

            if let logical = value.logicalValue(asTypeTruncatingIfNeeded: Int64.self) {
                if logical > 0 {
                    bucket.positive += 1
                } else if logical < 0 {
                    bucket.negative += 1
                } else {
                    bucket.zero += 1
                }
            } else {
                bucket.decodeFailures += 1
            }

            byUsage[usage] = bucket
        }
    }

    func snapshot() -> (inputReports: Int, usages: [(String, SurfaceBucket)]) {
        (
            inputReports,
            byUsage.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        )
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

        if mode == .componentInventory {
            try await runComponentInventoryProbe()
            return
        }

        if mode == .componentActivity {
            try await runComponentActivityProbe()
            return
        }

        if mode == .virtualDeviceCapability {
            try await runVirtualDeviceCapabilityProbe()
            return
        }

        let reference = try await discoverBuiltInTrackpadMouse(timeout: .seconds(3))
        print("PROBE_DISCOVERY_OK")

        if mode == .synchronousRelease {
            try await runSynchronousReleaseProbe(reference: reference)
            return
        }

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
        let descriptor = await client.descriptor
        let descriptorLength = descriptor.count
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

        if mode == .gdmSemanticSignature {
            try await runGDMSemanticSignatureProbe(client: client, elements: elements)
            return
        }

        if mode == .descriptorSemantics {
            let semantics: HIDPointerXYSemantics
            do {
                semantics = try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)
            } catch {
                throw ProbeFailure.descriptorSemantics(String(describing: error))
            }

            let x = semantics.xDataVariableDeclarations
            let y = semantics.yDataVariableDeclarations
            print(
                "PROBE_DESCRIPTOR_SEMANTICS "
                    + "x_data_variable_count=\(x.count) "
                    + "y_data_variable_count=\(y.count) "
                    + "x_relative_count=\(x.filter { $0.isRelative }.count) "
                    + "y_relative_count=\(y.filter { $0.isRelative }.count) "
                    + "strict_relative_xy=\(semantics.provesUnambiguousRelativeXY)"
            )

            guard semantics.provesUnambiguousRelativeXY else {
                throw ProbeFailure.descriptorSemantics(
                    "x_data_variable_count=\(x.count) y_data_variable_count=\(y.count)"
                )
            }

            print("PROBE_DESCRIPTOR_RELATIVE_XY_OK")
            print("PROBE_END boundary=descriptor_semantics result=PASS")
            return
        }

        if mode == .inputSurface {
            try await runInputSurfaceProbe(client: client, elements: elements)
            return
        }

        if mode == .hybridSurface {
            try await runHybridSurfaceProbe(client: client)
            return
        }

        if mode == .tapLayers {
            try await runTapLayersProbe(client: client)
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

        case .discoveryOnly, .clientOnly, .identityOnly, .metadataOnly, .descriptorSemantics, .synchronousRelease, .inputSurface, .hybridSurface, .tapLayers, .componentInventory, .componentActivity, .gdmSemanticSignature, .virtualDeviceCapability:
            fatalError("pre-monitor probe mode should have returned before control-stage switch")
        }
    }

    @available(macOS 15.0, *)
    private static func runGDMSemanticSignatureProbe(
        client: HIDDeviceClient,
        elements: [HIDElement]
    ) async throws {
        print("PROBE_GDM_SIGNATURE_BEGIN seize=false raw_payload_logging=false")

        for element in elements {
            let usage = String(describing: element.usage)
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "\n", with: "_")
            let reportID = String(describing: element.reportID)
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "\n", with: "_")
            print(
                "PROBE_GDM_ELEMENT "
                    + "usage=\(usage) "
                    + "report_id=\(reportID) "
                    + "report_size_bits=\(element.reportSize) "
                    + "logical_min=\(String(describing: element.logicalMinimum)) "
                    + "logical_max=\(String(describing: element.logicalMaximum)) "
                    + "type=\(String(describing: element.type))"
            )
        }

        let counters = GDMSemanticSignatureCounters()
        let monitorTask = Task {
            do {
                for try await notification in await client.monitorNotifications(
                    reportIDsToMonitor: [HIDReportID.allReports],
                    elementsToMonitor: elements
                ) {
                    if Task.isCancelled { break }
                    switch notification {
                    case .inputReport(let reportID, let reportData, _):
                        await counters.recordInputReport(id: reportID, data: reportData)
                    case .elementUpdates(let values):
                        await counters.recordElementUpdates(values)
                    case .deviceRemoved:
                        print("PROBE_GDM_SIGNATURE_DEVICE_REMOVED")
                    case .deviceSeized:
                        print("PROBE_GDM_SIGNATURE_EXTERNALLY_SEIZED")
                    case .deviceUnseized:
                        print("PROBE_GDM_SIGNATURE_UNSEIZED")
                    @unknown default:
                        break
                    }
                }
            } catch is CancellationError {
                // Expected at the end of this bounded characterization.
            } catch {
                fputs(
                    "PROBE_GDM_SIGNATURE_MONITOR_FAIL error=\(String(describing: error))\n",
                    stderr
                )
            }
        }

        let phases: [(name: String, instruction: String, seconds: Int)] = [
            ("IDLE", "do_not_touch_trackpad", 3),
            ("ONE_FINGER_RIGHT", "move_one_finger_right_only", 3),
            ("ONE_FINGER_DOWN", "move_one_finger_down_only", 3),
            ("PRIMARY_CLICK", "perform_normal_primary_clicks", 3),
            ("SECONDARY_CLICK", "perform_normal_secondary_clicks", 3),
            ("TWO_FINGER_UP", "move_two_fingers_up_only", 4),
            ("TWO_FINGER_RIGHT", "move_two_fingers_right_only", 4)
        ]

        for phase in phases {
            await counters.reset()
            print(
                "PROBE_GDM_SIGNATURE_PHASE_BEGIN name=\(phase.name) "
                    + "instruction=\(phase.instruction) duration_seconds=\(phase.seconds)"
            )
            try await Task.sleep(for: .seconds(phase.seconds))
            let lines = await counters.summaryLines(phase: phase.name)
            for line in lines {
                print(line)
            }
        }

        monitorTask.cancel()
        _ = await monitorTask.result
        print("PROBE_END boundary=gdm_semantic_signature")
    }

    @available(macOS 15.0, *)
    private static func runVirtualDeviceCapabilityProbe() async throws {
        print("PROBE_VIRTUAL_CAPABILITY_BEGIN physical_seize=false input_dispatch=false")

        let reference = try await discoverBuiltInTrackpadMouse(timeout: .seconds(3))
        guard let physicalClient = HIDDeviceClient(deviceReference: reference) else {
            throw ProbeFailure.clientCreation
        }

        let descriptor = await physicalClient.descriptor
        let semantics: HIDPointerXYSemantics
        do {
            semantics = try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)
        } catch {
            throw ProbeFailure.descriptorSemantics(String(describing: error))
        }
        guard semantics.provesUnambiguousRelativeXY else {
            throw ProbeFailure.descriptorSemantics("physical descriptor lost strict relative X/Y proof")
        }

        print(
            "PROBE_VIRTUAL_DESCRIPTOR_OK descriptor_length=\(descriptor.count) "
                + "strict_relative_xy=true"
        )

        let properties = HIDVirtualDevice.Properties(
            descriptor: descriptor,
            vendorID: 1,
            productID: 1,
            transport: .virtual,
            product: "Ampersand CoreHID Relay Probe",
            manufacturer: "Ampersand",
            uniqueID: "ampersand-corehid-relay-probe"
        )

        guard let virtualDevice = HIDVirtualDevice(properties: properties) else {
            print("PROBE_VIRTUAL_CREATE_FAIL")
            throw ProbeFailure.virtualDeviceCreation
        }
        print("PROBE_VIRTUAL_CREATE_OK")

        let delegate = ProbeVirtualDeviceDelegate()
        await virtualDevice.activate(delegate: delegate)
        print("PROBE_VIRTUAL_ACTIVATE_OK")

        guard let virtualClient = HIDDeviceClient(deviceReference: virtualDevice.deviceReference) else {
            throw ProbeFailure.clientCreation
        }

        let product = await virtualClient.product
        let transport = await virtualClient.transport
        let primaryUsage = await virtualClient.primaryUsage
        let virtualDescriptor = await virtualClient.descriptor

        let productMatches = product == "Ampersand CoreHID Relay Probe"
        let transportIsVirtual = transport == .virtual
        let primaryIsMouse = primaryUsage == .genericDesktop(.mouse)
        let descriptorMatches = virtualDescriptor == descriptor

        print(
            "PROBE_VIRTUAL_VISIBLE "
                + "product_matches=\(productMatches) "
                + "transport_virtual=\(transportIsVirtual) "
                + "primary_mouse=\(primaryIsMouse) "
                + "descriptor_matches=\(descriptorMatches)"
        )

        guard productMatches, transportIsVirtual, primaryIsMouse, descriptorMatches else {
            throw ProbeFailure.wrongDevice(
                "virtual device visibility contract failed"
            )
        }

        print("PROBE_END boundary=virtual_device_capability result=PASS")
    }

    @available(macOS 15.0, *)
    private static func runComponentActivityProbe() async throws {
        let manager = HIDDeviceManager()
        let criteria = HIDDeviceManager.DeviceMatchingCriteria(
            product: "Apple Internal Keyboard / Trackpad",
            isBuiltIn: true
        )
        let collector = DeviceReferenceCollector()

        let discoveryTask = Task {
            do {
                for try await notification in await manager.monitorNotifications(
                    matchingCriteria: [criteria]
                ) {
                    if Task.isCancelled { break }
                    switch notification {
                    case .deviceMatched(let reference):
                        await collector.append(reference)
                    case .deviceRemoved:
                        continue
                    @unknown default:
                        continue
                    }
                }
            } catch is CancellationError {
                // Expected when the bounded discovery window ends.
            } catch {
                fputs("PROBE_COMPONENT_ACTIVITY_DISCOVERY_FAIL error=\(String(describing: error))\n", stderr)
            }
        }

        print("PROBE_COMPONENT_ACTIVITY_DISCOVERY duration_seconds=3")
        try await Task.sleep(for: .seconds(3))
        discoveryTask.cancel()
        _ = await discoveryTask.result

        let references = await collector.snapshot()
        var monitored: [(
            label: String,
            client: HIDDeviceClient,
            elements: [HIDElement],
            counters: ComponentActivityCounters
        )] = []

        for reference in references {
            guard let client = HIDDeviceClient(deviceReference: reference) else { continue }
            let primaryUsage = await client.primaryUsage
            let primary = String(describing: primaryUsage)
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "\n", with: "_")

            // Keyboard activity is unrelated to pointer/gesture semantics and
            // would add hundreds of inert elements to the monitor set.
            if primaryUsage == .genericDesktop(.keyboard) {
                continue
            }

            let elements = await client.elements
            let descriptor = await client.descriptor
            let label = "\(primary)|d\(descriptor.count)|e\(elements.count)"
            monitored.append(
                (
                    label: label,
                    client: client,
                    elements: elements,
                    counters: ComponentActivityCounters()
                )
            )
        }

        print("PROBE_COMPONENT_ACTIVITY_COMPONENTS count=\(monitored.count)")
        for item in monitored {
            print("PROBE_COMPONENT_ACTIVITY_COMPONENT label=\(item.label)")
        }

        let monitorTasks = monitored.map { item in
            Task {
                do {
                    for try await notification in await item.client.monitorNotifications(
                        reportIDsToMonitor: [HIDReportID.allReports],
                        elementsToMonitor: item.elements
                    ) {
                        if Task.isCancelled { break }
                        switch notification {
                        case .inputReport:
                            await item.counters.recordInputReport()
                        case .elementUpdates(let values):
                            await item.counters.recordElementUpdates(values)
                        case .deviceRemoved:
                            await item.counters.recordRemoved()
                        case .deviceSeized:
                            await item.counters.recordExternalSeizure()
                        case .deviceUnseized:
                            await item.counters.recordUnseized()
                        @unknown default:
                            break
                        }
                    }
                } catch is CancellationError {
                    // Expected when characterization ends.
                } catch {
                    fputs(
                        "PROBE_COMPONENT_ACTIVITY_MONITOR_FAIL label=\(item.label) "
                            + "error=\(String(describing: error))\n",
                        stderr
                    )
                }
            }
        }

        let phases: [(name: String, instruction: String, seconds: Int)] = [
            ("IDLE", "do_not_touch_trackpad", 3),
            ("MOVE_RIGHT", "move_one_finger_right_only", 3),
            ("PRIMARY_CLICK", "perform_normal_primary_clicks", 3),
            ("SECONDARY_CLICK", "perform_normal_secondary_clicks", 3),
            ("SCROLL_VERTICAL", "two_finger_scroll_vertically", 4),
            ("SCROLL_HORIZONTAL", "two_finger_scroll_horizontally", 4)
        ]

        for phase in phases {
            for item in monitored {
                await item.counters.reset()
            }

            print(
                "PROBE_COMPONENT_ACTIVITY_PHASE_BEGIN name=\(phase.name) "
                    + "instruction=\(phase.instruction) duration_seconds=\(phase.seconds)"
            )
            try await Task.sleep(for: .seconds(phase.seconds))

            for item in monitored {
                let snapshot = await item.counters.snapshot()
                print(
                    "PROBE_COMPONENT_ACTIVITY_PHASE_END name=\(phase.name) "
                        + "label=\(item.label) "
                        + "input_reports=\(snapshot.inputReports) "
                        + "usage_bucket_count=\(snapshot.usages.count) "
                        + "device_removed=\(snapshot.removed) "
                        + "externally_seized=\(snapshot.externallySeized) "
                        + "unseized=\(snapshot.unseized)"
                )
                for (usage, count) in snapshot.usages {
                    print(
                        "PROBE_COMPONENT_ACTIVITY_USAGE phase=\(phase.name) "
                            + "label=\(item.label) "
                            + "usage=\(usage) updates=\(count)"
                    )
                }
            }
        }

        for task in monitorTasks {
            task.cancel()
        }
        for task in monitorTasks {
            _ = await task.result
        }

        print("PROBE_END boundary=component_activity")
    }

    @available(macOS 15.0, *)
    private static func runComponentInventoryProbe() async throws {
        let manager = HIDDeviceManager()
        let criteria = HIDDeviceManager.DeviceMatchingCriteria(
            product: "Apple Internal Keyboard / Trackpad",
            isBuiltIn: true
        )
        let collector = DeviceReferenceCollector()

        let monitorTask = Task {
            do {
                for try await notification in await manager.monitorNotifications(
                    matchingCriteria: [criteria]
                ) {
                    if Task.isCancelled { break }
                    switch notification {
                    case .deviceMatched(let reference):
                        await collector.append(reference)
                    case .deviceRemoved:
                        continue
                    @unknown default:
                        continue
                    }
                }
            } catch is CancellationError {
                // Expected after the bounded discovery window.
            } catch {
                fputs("PROBE_COMPONENT_INVENTORY_MONITOR_FAIL error=\(String(describing: error))\n", stderr)
            }
        }

        print("PROBE_COMPONENT_INVENTORY_DISCOVERY duration_seconds=3 product=Apple_Internal_Keyboard_Trackpad built_in=true")
        try await Task.sleep(for: .seconds(3))
        monitorTask.cancel()
        _ = await monitorTask.result

        let references = await collector.snapshot()
        print("PROBE_COMPONENT_INVENTORY_MATCHES count=\(references.count)")

        for (index, reference) in references.enumerated() {
            guard let client = HIDDeviceClient(deviceReference: reference) else {
                print("PROBE_COMPONENT index=\(index) client_creation=false")
                continue
            }

            let primaryUsage = await client.primaryUsage
            let deviceUsages = await client.deviceUsages
            let descriptor = await client.descriptor
            let elements = await client.elements
            let transport = await client.transport
            let locationID = await client.locationID
            let uniqueID = await client.uniqueID

            var usageCounts: [String: Int] = [:]
            for element in elements {
                let usage = String(describing: element.usage)
                    .replacingOccurrences(of: " ", with: "_")
                    .replacingOccurrences(of: "\n", with: "_")
                usageCounts[usage, default: 0] += 1
            }

            let primary = String(describing: primaryUsage)
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "\n", with: "_")
            let supported = deviceUsages
                .map {
                    String(describing: $0)
                        .replacingOccurrences(of: " ", with: "_")
                        .replacingOccurrences(of: "\n", with: "_")
                }
                .joined(separator: ",")

            print(
                "PROBE_COMPONENT index=\(index) "
                    + "primary_usage=\(primary) "
                    + "device_usage_count=\(deviceUsages.count) "
                    + "descriptor_length=\(descriptor.count) "
                    + "element_count=\(elements.count) "
                    + "transport=\(String(describing: transport)) "
                    + "location_id_present=\(locationID != nil) "
                    + "unique_id_present=\(uniqueID != nil)"
            )
            print("PROBE_COMPONENT_USAGES index=\(index) usages=\(supported)")
            for (usage, count) in usageCounts.sorted(by: { $0.key < $1.key }) {
                print(
                    "PROBE_COMPONENT_ELEMENT_USAGE index=\(index) "
                        + "usage=\(usage) count=\(count)"
                )
            }
        }

        print("PROBE_END boundary=component_inventory")
    }

    @available(macOS 15.0, *)
    private static func runTapLayersProbe(
        client: HIDDeviceClient
    ) async throws {
        let layers: [(name: String, location: CGEventTapLocation, counter: EventTypeCounter)] = [
            ("hid", .cghidEventTap, EventTypeCounter()),
            ("session", .cgSessionEventTap, EventTypeCounter()),
            ("annotated_session", .cgAnnotatedSessionEventTap, EventTypeCounter())
        ]

        var taps: [ListenOnlyEventTap] = []
        for layer in layers {
            let tap = ListenOnlyEventTap(
                counter: layer.counter,
                location: layer.location,
                label: layer.name
            )
            guard tap.start() else {
                for started in taps { started.stop() }
                print("PROBE_TAP_LAYERS_FAIL layer=\(layer.name) reason=cg_event_tap_creation_failed")
                throw ProbeFailure.wrongDevice("listen-only CGEventTap creation failed for \(layer.name)")
            }
            taps.append(tap)
            print("PROBE_TAP_LAYER_OK layer=\(layer.name) mode=listen_only")
        }
        defer {
            for tap in taps { tap.stop() }
        }

        try await client.seizeDevice()
        print("PROBE_SEIZE_OK")
        print("PROBE_TAP_LAYERS payload_logging=false event_types_only=true host_pointer_stationary=true")

        let phases: [(name: String, instruction: String, seconds: Int)] = [
            ("MOVE_RIGHT", "move_one_finger_right_only", 3),
            ("PRIMARY_CLICK", "perform_normal_primary_clicks", 3),
            ("SECONDARY_CLICK", "perform_normal_secondary_clicks", 3),
            ("SCROLL_VERTICAL", "two_finger_scroll_vertically", 4),
            ("SCROLL_HORIZONTAL", "two_finger_scroll_horizontally", 4)
        ]

        for phase in phases {
            for layer in layers { layer.counter.reset() }
            print(
                "PROBE_TAP_LAYERS_PHASE_BEGIN name=\(phase.name) "
                    + "instruction=\(phase.instruction) duration_seconds=\(phase.seconds)"
            )
            try await Task.sleep(for: .seconds(phase.seconds))

            for layer in layers {
                let snapshot = layer.counter.snapshot()
                print(
                    "PROBE_TAP_LAYERS_PHASE_END name=\(phase.name) "
                        + "layer=\(layer.name) event_type_count=\(snapshot.count)"
                )
                for (rawType, count) in snapshot {
                    print(
                        "PROBE_TAP_LAYER_EVENT phase=\(phase.name) "
                            + "layer=\(layer.name) type_raw=\(rawType) count=\(count)"
                    )
                }
            }
        }

        print("PROBE_RELEASE client_lifetime_ending=true")
        print("PROBE_END boundary=corehid_seize_plus_three_listen_only_event_taps")
    }

    @available(macOS 15.0, *)
    private static func runHybridSurfaceProbe(
        client: HIDDeviceClient
    ) async throws {
        let counter = EventTypeCounter()
        let tap = ListenOnlyEventTap(
            counter: counter,
            location: .cghidEventTap,
            label: "hid"
        )

        guard tap.start() else {
            print("PROBE_HYBRID_TAP_FAIL reason=cg_event_tap_creation_failed")
            throw ProbeFailure.wrongDevice("listen-only CGEventTap creation failed")
        }
        defer { tap.stop() }

        print("PROBE_HYBRID_TAP_OK mode=listen_only payload_logging=false")
        try await client.seizeDevice()
        print("PROBE_SEIZE_OK")
        print("PROBE_HYBRID_EXPECTATION host_pointer_stationary=true")

        let phases: [(name: String, instruction: String, seconds: Int)] = [
            ("MOVE_RIGHT", "move_one_finger_right_only", 3),
            ("PRIMARY_CLICK", "perform_normal_primary_clicks", 3),
            ("SECONDARY_CLICK", "perform_normal_secondary_clicks", 3),
            ("SCROLL_VERTICAL", "two_finger_scroll_vertically", 4),
            ("SCROLL_HORIZONTAL", "two_finger_scroll_horizontally", 4)
        ]

        for phase in phases {
            counter.reset()
            print(
                "PROBE_HYBRID_PHASE_BEGIN name=\(phase.name) "
                    + "instruction=\(phase.instruction) duration_seconds=\(phase.seconds)"
            )
            try await Task.sleep(for: .seconds(phase.seconds))

            let snapshot = counter.snapshot()
            print(
                "PROBE_HYBRID_PHASE_END name=\(phase.name) "
                    + "event_type_count=\(snapshot.count)"
            )
            for (rawType, count) in snapshot {
                print(
                    "PROBE_HYBRID_EVENT phase=\(phase.name) "
                        + "type_raw=\(rawType) "
                        + "count=\(count)"
                )
            }
        }

        print("PROBE_RELEASE client_lifetime_ending=true")
        print("PROBE_END boundary=corehid_seize_plus_listen_only_event_tap")
    }

    @available(macOS 15.0, *)
    private static func runInputSurfaceProbe(
        client: HIDDeviceClient,
        elements: [HIDElement]
    ) async throws {
        try await client.seizeDevice()
        print("PROBE_SEIZE_OK")
        print("PROBE_INPUT_SURFACE payload_logging=false logical_signs_only=true")
        print("PROBE_INPUT_SURFACE element_count=\(elements.count)")

        let counters = InputSurfaceCounters()
        let monitorTask = Task {
            do {
                for try await notification in await client.monitorNotifications(
                    reportIDsToMonitor: [HIDReportID.allReports],
                    elementsToMonitor: elements
                ) {
                    if Task.isCancelled { break }
                    switch notification {
                    case .inputReport:
                        await counters.recordInputReport()
                    case .elementUpdates(let values):
                        await counters.record(values)
                    case .deviceRemoved:
                        print("PROBE_INPUT_SURFACE_DEVICE_REMOVED")
                    case .deviceSeized, .deviceUnseized:
                        break
                    @unknown default:
                        break
                    }
                }
            } catch is CancellationError {
                // Expected when the bounded probe ends.
            } catch {
                fputs("PROBE_INPUT_SURFACE_MONITOR_FAIL error=\(String(describing: error))\n", stderr)
            }
        }

        let phases: [(name: String, instruction: String, seconds: Int)] = [
            ("MOVE_RIGHT", "move_one_finger_right_only", 3),
            ("MOVE_DOWN", "move_one_finger_down_only", 3),
            ("PRIMARY_CLICK", "perform_normal_primary_clicks", 3),
            ("SECONDARY_CLICK", "perform_normal_secondary_clicks", 3),
            ("SCROLL_VERTICAL", "two_finger_scroll_vertically", 4),
            ("SCROLL_HORIZONTAL", "two_finger_scroll_horizontally", 4)
        ]

        for phase in phases {
            await counters.reset()
            print(
                "PROBE_INPUT_SURFACE_PHASE_BEGIN name=\(phase.name) "
                    + "instruction=\(phase.instruction) duration_seconds=\(phase.seconds)"
            )
            try await Task.sleep(for: .seconds(phase.seconds))
            let snapshot = await counters.snapshot()
            print(
                "PROBE_INPUT_SURFACE_PHASE_END name=\(phase.name) "
                    + "input_reports=\(snapshot.inputReports) "
                    + "usage_bucket_count=\(snapshot.usages.count)"
            )
            for (usage, bucket) in snapshot.usages {
                let safeUsage = usage
                    .replacingOccurrences(of: " ", with: "_")
                    .replacingOccurrences(of: "\n", with: "_")
                print(
                    "PROBE_INPUT_SURFACE_USAGE phase=\(phase.name) "
                        + "usage=\(safeUsage) "
                        + "updates=\(bucket.updates) "
                        + "positive=\(bucket.positive) "
                        + "negative=\(bucket.negative) "
                        + "zero=\(bucket.zero) "
                        + "decode_failures=\(bucket.decodeFailures)"
                )
            }
        }

        monitorTask.cancel()
        _ = await monitorTask.result
        print("PROBE_RELEASE client_lifetime_ending=true")
        print("PROBE_END boundary=input_surface_characterization")
    }

    @available(macOS 15.0, *)
    private static func runSynchronousReleaseProbe(
        reference: HIDDeviceClient.DeviceReference
    ) async throws {
        var client: HIDDeviceClient? = HIDDeviceClient(deviceReference: reference)
        guard client != nil else {
            throw ProbeFailure.clientCreation
        }

        let xyElements: [HIDElement]
        let stream: AsyncThrowingStream<HIDDeviceClient.Notification, any Error>

        do {
            guard let activeClient = client else {
                throw ProbeFailure.clientCreation
            }

            let primaryUsage = await activeClient.primaryUsage
            let isBuiltIn = await activeClient.isBuiltIn
            let product = await activeClient.product
            guard primaryUsage == .genericDesktop(.mouse), isBuiltIn,
                  product == "Apple Internal Keyboard / Trackpad" else {
                throw ProbeFailure.wrongDevice(
                    "synchronous-release identity validation failed"
                )
            }

            let elements = await activeClient.elements
            xyElements = elements.filter {
                $0.usage == .genericDesktop(.x) || $0.usage == .genericDesktop(.y)
            }
            guard !xyElements.isEmpty else {
                throw ProbeFailure.noXYElements
            }

            try await activeClient.seizeDevice()
            print("PROBE_SEIZE_OK")
            stream = await activeClient.monitorNotifications(
                reportIDsToMonitor: [HIDReportID.allReports],
                elementsToMonitor: xyElements
            )
        }

        let counters = ProbeCounters()
        let monitorTask = Task {
            do {
                for try await notification in stream {
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
                // Expected on release.
            } catch {
                fputs("PROBE_MONITOR_FAIL error=\(String(describing: error))\n", stderr)
            }
        }

        print("PROBE_CONTROL seize=true monitor=true duration_seconds=5")
        print("PROBE_MOVE_NOW expected_host_pointer=stationary expected_xy_notifications=nonzero")
        try await Task.sleep(for: .seconds(5))

        let snapshot = await counters.snapshot()
        printObservation(snapshot)

        // Critical production-shape experiment: cancellation is requested and
        // the final explicit HIDDeviceClient reference is dropped without
        // awaiting monitorTask completion. If local pointer ownership resumes
        // immediately, local return does not require an async stream-drain
        // barrier. The task is awaited only after the human observation window
        // to clean up this bounded probe.
        print("PROBE_SYNCHRONOUS_RELEASE_BEGIN cancel_monitor=true await_monitor_before_client_drop=false")
        monitorTask.cancel()
        client = nil
        print("PROBE_SYNCHRONOUS_RELEASE_CLIENT_DROPPED")
        print("PROBE_RELEASE_CHECK_NOW expected_local_pointer=immediate expected_cursor_health=HEALTHY duration_seconds=8")
        try await Task.sleep(for: .seconds(8))
        print("PROBE_RELEASE_CHECK_END")

        _ = await monitorTask.result
        print("PROBE_MONITOR_RETIRED_AFTER_OBSERVATION=true")
        print("PROBE_END boundary=synchronous_release_without_stream_await")
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
