import Foundation
import InputDomain
import Diagnostics

#if canImport(CoreHID)
import CoreHID

@available(macOS 15.0, *)
private final class CoreHIDPointerClientSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var client: HIDDeviceClient?

    init(_ client: HIDDeviceClient) {
        self.client = client
    }

    func dropClient() {
        lock.withLock {
            client = nil
        }
    }
}

@available(macOS 15.0, *)
private final class CoreHIDPointerReleaseResponsibility: @unchecked Sendable {
    private let lock = NSLock()
    private var lifecycleOwned = false

    func transferToLifecycleOwner() {
        lock.withLock {
            lifecycleOwned = true
        }
    }

    var isLifecycleOwned: Bool {
        lock.withLock { lifecycleOwned }
    }
}

@available(macOS 15.0, *)
struct CoreHIDTapSurfaceDiagnostics: Equatable, Sendable {
    private(set) var reports = 0
    private(set) var contactPresentReports = 0
    private(set) var zeroContactReports = 0
    private(set) var contactTransitions = 0
    private(set) var tapDecisions = 0
    private(set) var semanticButtonEvents = 0

    mutating func observeReport(
        contactPresent: Bool,
        contactTransition: Bool
    ) {
        reports += 1
        if contactPresent {
            contactPresentReports += 1
        } else {
            zeroContactReports += 1
        }
        if contactTransition {
            contactTransitions += 1
        }
    }

    mutating func observeTapDecision() {
        tapDecisions += 1
    }

    mutating func observeSemanticButton() {
        semanticButtonEvents += 1
    }

    var summary: String {
        "corehid tap surface summary "
            + "reports=\(reports) "
            + "contactPresentReports=\(contactPresentReports) "
            + "zeroContactReports=\(zeroContactReports) "
            + "contactTransitions=\(contactTransitions) "
            + "tapDecisions=\(tapDecisions) "
            + "semanticButtons=\(semanticButtonEvents)"
    }
}

@available(macOS 15.0, *)
private final class CoreHIDPointerStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var translator = AppleTrackpadSemanticTranslator()
    private var lastRawPrimary = false
    private var lastRawSecondary = false
    private var lastRawOther = false
    private var lastRawContactPresent = false
    private var tapSurfaceDiagnostics = CoreHIDTapSurfaceDiagnostics()

    func consume(_ data: Data) throws -> [SemanticPointerEvent] {
        try lock.withLock {
            guard active else { return [] }
            let report = try AppleTrackpadRawReportDecoder.decode(data)

            // Metadata-only physical diagnostics. These transitions reveal
            // whether the seized CoreHID stream actually exposes button state
            // without logging raw reports, coordinates, or other payload data.
            if report.buttons.primary != lastRawPrimary {
                lastRawPrimary = report.buttons.primary
                Diagnostics.log("corehid raw input type=button-transition")
            }
            if report.buttons.secondary != lastRawSecondary {
                lastRawSecondary = report.buttons.secondary
                Diagnostics.log("corehid raw input type=button-transition")
            }
            if report.buttons.other != lastRawOther {
                lastRawOther = report.buttons.other
                Diagnostics.log("corehid raw input type=button-transition")
            }

            let contactPresent = report.contactCount > 0
            let contactTransition = contactPresent != lastRawContactPresent
            tapSurfaceDiagnostics.observeReport(
                contactPresent: contactPresent,
                contactTransition: contactTransition
            )
            if contactTransition {
                lastRawContactPresent = contactPresent
                Diagnostics.log("corehid raw input type=contact-transition")
            }

            let events = try translator.translate(report)
            if contactTransition, !contactPresent,
               let resolution = translator.takeTapResolution() {
                tapSurfaceDiagnostics.observeTapDecision()
                Diagnostics.log(
                    "corehid tap decision outcome=\(resolution.rawValue)"
                )
            }
            for event in events {
                if case let .button(button, down) = event.kind {
                    _ = button
                    _ = down
                    tapSurfaceDiagnostics.observeSemanticButton()
                    Diagnostics.log("corehid semantic input type=button")
                }
            }
            return events
        }
    }

    func deactivateAndReset() -> [SemanticPointerEvent] {
        lock.withLock {
            guard active else { return [] }
            active = false
            Diagnostics.log(tapSurfaceDiagnostics.summary)
            return translator.reset()
        }
    }

    /// Returns true only for the first terminal failure.
    func fail() -> Bool {
        lock.withLock {
            guard active else { return false }
            active = false
            Diagnostics.log(tapSurfaceDiagnostics.summary)
            _ = translator.reset()
            return true
        }
    }

    var isActive: Bool {
        lock.withLock { active }
    }
}

@available(macOS 15.0, *)
final class CoreHIDPointerLease: HostPointerOwnershipLease, @unchecked Sendable {
    let generation: UInt64

    var isActive: Bool {
        streamState.isActive && registry.isCurrent(generation)
    }

    private let registry: CoreHIDPointerLeaseRegistry
    private let clientSlot: CoreHIDPointerClientSlot
    private let streamState: CoreHIDPointerStreamState
    private let releaseResponsibility: CoreHIDPointerReleaseResponsibility
    private let monitorTask: Task<Void, Never>
    private let releaseLock = NSLock()
    private var released = false

    fileprivate init(
        generation: UInt64,
        registry: CoreHIDPointerLeaseRegistry,
        clientSlot: CoreHIDPointerClientSlot,
        streamState: CoreHIDPointerStreamState,
        releaseResponsibility: CoreHIDPointerReleaseResponsibility,
        monitorTask: Task<Void, Never>
    ) {
        self.generation = generation
        self.registry = registry
        self.clientSlot = clientSlot
        self.streamState = streamState
        self.releaseResponsibility = releaseResponsibility
        self.monitorTask = monitorTask
    }

    func transferReleaseResponsibilityToLifecycleOwner() {
        releaseResponsibility.transferToLifecycleOwner()
    }

    /// Synchronous local-return boundary.
    ///
    /// Cancellation is requested, then the final explicit HIDDeviceClient
    /// reference is dropped before this method returns. Stream retirement is
    /// intentionally not awaited. Returned events are remote cleanup only and
    /// must not delay local ownership restoration.
    func release() {
        let shouldRelease = releaseLock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        guard shouldRelease else { return }

        monitorTask.cancel()
        clientSlot.dropClient()
        registry.release(generation)
        Diagnostics.log(
            "corehid pointer ownership released generation=\(generation)"
        )

        // Remote cleanup is intentionally after local ownership restoration.
        // Even if this bounded translator lock briefly contends with an
        // in-flight decode, native pointer control is already local again.
        _ = streamState.deactivateAndReset()
    }

    deinit {
        release()
    }
}

@available(macOS 15.0, *)
final class CoreHIDBuiltInPointerBackend: HostPointerOwnershipBackend {
    enum AcquisitionError: Error, Equatable, Sendable {
        case discoveryTimeout
        case clientCreation
        case wrongDevice
        case descriptorSemantics
    }

    private let registry: CoreHIDPointerLeaseRegistry

    init(registry: CoreHIDPointerLeaseRegistry = .shared) {
        self.registry = registry
    }

    func acquire(
        onEvent: @escaping HostPointerEventHandler,
        onFailure: @escaping HostPointerFailureHandler
    ) async throws -> any HostPointerOwnershipLease {
        try await acquire(
            discoveryTimeout: .seconds(3),
            onEvent: onEvent,
            onFailure: onFailure
        )
    }

    func acquire(
        discoveryTimeout: Duration,
        onEvent: @escaping HostPointerEventHandler,
        onFailure: @escaping HostPointerFailureHandler
    ) async throws -> CoreHIDPointerLease {
        let generation = try registry.reserve()

        do {
            try Task.checkCancellation()
            let reference = try await Self.discoverBuiltInTrackpadMouse(
                timeout: discoveryTimeout
            )
            try Task.checkCancellation()

            guard let client = HIDDeviceClient(deviceReference: reference) else {
                throw AcquisitionError.clientCreation
            }

            let primaryUsage = await client.primaryUsage
            let isBuiltIn = await client.isBuiltIn
            let product = await client.product
            guard primaryUsage == .genericDesktop(.mouse),
                  isBuiltIn,
                  product == "Apple Internal Keyboard / Trackpad" else {
                throw AcquisitionError.wrongDevice
            }
            try Task.checkCancellation()

            let descriptor = await client.descriptor
            let xy = try HIDReportDescriptorSemantics.analyzePointerXY(
                descriptor: descriptor
            )
            guard xy.provesUnambiguousRelativeXY else {
                throw AcquisitionError.descriptorSemantics
            }
            try AppleTrackpadReportDescriptorVerifier.verify(descriptor)
            try Task.checkCancellation()

            let elements = await client.elements
            try Task.checkCancellation()

            // CoreHID requires seizure before opening the monitor stream.
            try await client.seizeDevice()
            Diagnostics.log(
                "corehid pointer seized generation=\(generation)"
            )
            // A return can cancel acquisition while CoreHID is completing the
            // seize. Throwing here drops the local client reference from this
            // scope immediately instead of publishing late ownership.
            try Task.checkCancellation()

            guard let reportID = HIDReportID(rawValue: 2) else {
                throw AcquisitionError.descriptorSemantics
            }
            let stream = await client.monitorNotifications(
                reportIDsToMonitor: [reportID...reportID],
                elementsToMonitor: elements
            )
            try Task.checkCancellation()

            let clientSlot = CoreHIDPointerClientSlot(client)
            let streamState = CoreHIDPointerStreamState()
            let releaseResponsibility =
                CoreHIDPointerReleaseResponsibility()
            let registry = self.registry

            // Critical ownership shape: the task captures the stream and slot,
            // never the seizing HIDDeviceClient directly. release() can drop
            // the final explicit client reference without awaiting this task.
            let monitorTask = Task {
                func failClosed(_ reason: String) {
                    guard streamState.fail() else { return }
                    Diagnostics.log(
                        "corehid pointer stream failed generation=\(generation) reason=\(reason)"
                    )

                    // A published lease is owned by Control: notify it while
                    // the seizing client is still alive so keyboard admission
                    // can go local before pointer ownership returns.
                    onFailure(generation)

                    // Before responsibility transfers, the callback may
                    // have no lifecycle-owned lease to take, so the backend
                    // must restore local pointer ownership itself. Once Control
                    // owns release responsibility, never self-unseize here:
                    // Control must withdraw keyboard admission first even when
                    // its slot has already been taken by a concurrent return.
                    if !releaseResponsibility.isLifecycleOwned,
                       registry.isCurrent(generation) {
                        clientSlot.dropClient()
                        registry.release(generation)
                    }
                }

                do {
                    for try await notification in stream {
                        if Task.isCancelled { break }

                        switch notification {
                        case .inputReport(_, let data, _):
                            do {
                                let events = try streamState.consume(data)
                                for event in events {
                                    // Registry check narrows the race; the
                                    // generation tag remains the final stale
                                    // event barrier at the Control owner.
                                    guard registry.isCurrent(generation) else {
                                        continue
                                    }
                                    onEvent(event, generation)
                                }
                            } catch {
                                failClosed("semantic-decode")
                                return
                            }

                        case .deviceRemoved:
                            failClosed("device-removed")
                            return

                        case .deviceSeized:
                            failClosed("device-seized")
                            return

                        case .deviceUnseized:
                            failClosed("device-unseized")
                            return

                        case .elementUpdates:
                            break

                        @unknown default:
                            failClosed("unknown-notification")
                            return
                        }
                    }

                    if !Task.isCancelled {
                        failClosed("stream-ended")
                    }
                } catch is CancellationError {
                    // Normal synchronous release cancels this task after
                    // invalidating streamState and before dropping the client.
                } catch {
                    failClosed("stream-error")
                }
            }

            return CoreHIDPointerLease(
                generation: generation,
                registry: registry,
                clientSlot: clientSlot,
                streamState: streamState,
                releaseResponsibility: releaseResponsibility,
                monitorTask: monitorTask
            )
        } catch {
            registry.release(generation)
            throw error
        }
    }

    private static func discoverBuiltInTrackpadMouse(
        timeout: Duration
    ) async throws -> HIDDeviceClient.DeviceReference {
        try await withThrowingTaskGroup(
            of: HIDDeviceClient.DeviceReference.self
        ) { group in
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
                throw AcquisitionError.discoveryTimeout
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw AcquisitionError.discoveryTimeout
            }

            defer { group.cancelAll() }
            guard let reference = try await group.next() else {
                throw AcquisitionError.discoveryTimeout
            }
            return reference
        }
    }
}
#endif
