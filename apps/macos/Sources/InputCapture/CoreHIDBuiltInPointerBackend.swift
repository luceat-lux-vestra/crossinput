import Foundation
import InputDomain

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
private final class CoreHIDPointerStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var translator = AppleTrackpadSemanticTranslator()

    func consume(_ data: Data) throws -> [SemanticPointerEvent] {
        try lock.withLock {
            guard active else { return [] }
            let report = try AppleTrackpadRawReportDecoder.decode(data)
            return try translator.translate(report)
        }
    }

    func deactivateAndReset() -> [SemanticPointerEvent] {
        lock.withLock {
            guard active else { return [] }
            active = false
            return translator.reset()
        }
    }

    /// Returns true only for the first terminal failure.
    func fail() -> Bool {
        lock.withLock {
            guard active else { return false }
            active = false
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
    private let monitorTask: Task<Void, Never>
    private let releaseLock = NSLock()
    private var released = false

    fileprivate init(
        generation: UInt64,
        registry: CoreHIDPointerLeaseRegistry,
        clientSlot: CoreHIDPointerClientSlot,
        streamState: CoreHIDPointerStreamState,
        monitorTask: Task<Void, Never>
    ) {
        self.generation = generation
        self.registry = registry
        self.clientSlot = clientSlot
        self.streamState = streamState
        self.monitorTask = monitorTask
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
            let registry = self.registry

            // Critical ownership shape: the task captures the stream and slot,
            // never the seizing HIDDeviceClient directly. release() can drop
            // the final explicit client reference without awaiting this task.
            let monitorTask = Task {
                func failClosed() {
                    guard streamState.fail() else { return }
                    clientSlot.dropClient()
                    registry.release(generation)
                    onFailure(generation)
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
                                failClosed()
                                return
                            }

                        case .deviceRemoved:
                            failClosed()
                            return

                        case .deviceSeized:
                            failClosed()
                            return

                        case .deviceUnseized:
                            failClosed()
                            return

                        case .elementUpdates:
                            break

                        @unknown default:
                            failClosed()
                            return
                        }
                    }

                    if !Task.isCancelled {
                        failClosed()
                    }
                } catch is CancellationError {
                    // Normal synchronous release cancels this task after
                    // invalidating streamState and before dropping the client.
                } catch {
                    failClosed()
                }
            }

            return CoreHIDPointerLease(
                generation: generation,
                registry: registry,
                clientSlot: clientSlot,
                streamState: streamState,
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
