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

    var description: String {
        switch self {
        case .unsupportedOS:
            return "CoreHID is unavailable on this macOS version"
        case .invalidMode(let value):
            return "invalid or missing mode=\(value ?? "nil"); use --mode discovery-only|client-only|identity-only|metadata-only|descriptor-semantics|synchronous-release|input-surface|hybrid-surface|tap-layers|monitor-only|seize-only|seize-monitor"
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

        case .discoveryOnly, .clientOnly, .identityOnly, .metadataOnly, .descriptorSemantics, .synchronousRelease, .inputSurface, .hybridSurface, .tapLayers:
            fatalError("pre-monitor probe mode should have returned before control-stage switch")
        }
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
