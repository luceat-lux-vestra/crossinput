import Foundation
import InputDomain
import Diagnostics

#if canImport(CoreHID)
import CoreHID

@available(macOS 15.0, *)
private final class CoreHIDPointerClientSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var client: HIDDeviceClient?
    private weak var clientProbe: HIDDeviceClient?

    init(_ client: HIDDeviceClient) {
        self.client = client
        self.clientProbe = client
    }

    @discardableResult
    func dropClient() -> Bool {
        lock.withLock {
            client = nil
            return clientProbe == nil
        }
    }

    var isClientDeinitialized: Bool {
        lock.withLock { clientProbe == nil }
    }
}

private final class CoreHIDMonitorCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var completed = false

    func finish() {
        let shouldSignal = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        if shouldSignal {
            semaphore.signal()
        }
    }

    func wait(timeout: DispatchTimeInterval) -> Bool {
        if lock.withLock({ completed }) {
            return true
        }
        return semaphore.wait(timeout: .now() + timeout) == .success
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
    private(set) var silenceContactEnds = 0
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

    mutating func observeSilenceContactEnd() {
        silenceContactEnds += 1
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
            + "silenceContactEnds=\(silenceContactEnds) "
            + "tapDecisions=\(tapDecisions) "
            + "semanticButtons=\(semanticButtonEvents)"
    }
}

@available(macOS 15.0, *)
private final class CoreHIDPointerStreamState: @unchecked Sendable {
    /// Physical evidence on the target MacBook shows the seized Report-ID-2
    /// stream carries continuous contact-present reports but no terminal
    /// zero-contact report. A short report-silence interval is therefore the
    /// bounded public-surface end-of-contact oracle.
    private static let tapSilenceDelay = DispatchTimeInterval.milliseconds(50)

    private let lock = NSLock()
    private let tapSilenceQueue = DispatchQueue(
        label: "crossinput.corehid.tap-silence",
        qos: .userInteractive
    )
    private let onDeferredEvent: @Sendable (SemanticPointerEvent) -> Void

    private var active = true
    private var translator = AppleTrackpadSemanticTranslator()
    private var lastRawPrimary = false
    private var lastRawSecondary = false
    private var lastRawOther = false
    private var lastRawContactPresent = false
    private var contactReportSequence: UInt64 = 0
    private var lastContactReportNanos: UInt64?
    private var tapSilenceWorkItem: DispatchWorkItem?
    private var tapSurfaceDiagnostics = CoreHIDTapSurfaceDiagnostics()

    init(
        onDeferredEvent: @escaping @Sendable (SemanticPointerEvent) -> Void
    ) {
        self.onDeferredEvent = onDeferredEvent
    }

    func consume(_ data: Data) throws -> [SemanticPointerEvent] {
        let result = try lock.withLock {
            guard active else {
                return (events: [SemanticPointerEvent](), armSilence: false, token: UInt64(0))
            }
            let report = try AppleTrackpadRawReportDecoder.decode(data)
            let nowNanos = DispatchTime.now().uptimeNanoseconds

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

            let events = try translator.translate(
                report,
                nowNanos: nowNanos
            )
            if contactTransition, !contactPresent,
               let resolution = translator.takeTapResolution() {
                tapSurfaceDiagnostics.observeTapDecision()
                Diagnostics.log(
                    "corehid tap decision outcome=\(resolution.rawValue)"
                )
            }
            for event in events {
                recordSemanticButtonIfNeeded(event)
            }

            contactReportSequence &+= 1
            if contactReportSequence == 0 {
                contactReportSequence = 1
            }

            if contactPresent {
                lastContactReportNanos = nowNanos
            } else {
                lastContactReportNanos = nil
            }

            // Physical Button1 still has explicit transition semantics. The
            // silence oracle is needed only for touch contact lifecycle.
            let armSilence = contactPresent && !report.buttons.primary
            return (
                events: events,
                armSilence: armSilence,
                token: contactReportSequence
            )
        }

        if result.armSilence {
            armTapSilence(token: result.token)
        } else {
            cancelTapSilence()
        }
        return result.events
    }

    private func armTapSilence(token: UInt64) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.finalizeContactAfterSilence(token: token)
        }
        let previous = lock.withLock {
            let previous = tapSilenceWorkItem
            tapSilenceWorkItem = workItem
            return previous
        }
        previous?.cancel()
        tapSilenceQueue.asyncAfter(
            deadline: .now() + Self.tapSilenceDelay,
            execute: workItem
        )
    }

    private func cancelTapSilence() {
        let previous = lock.withLock {
            let previous = tapSilenceWorkItem
            tapSilenceWorkItem = nil
            return previous
        }
        previous?.cancel()
    }

    private func finalizeContactAfterSilence(token: UInt64) {
        let events: [SemanticPointerEvent] = lock.withLock {
            guard active,
                  token == contactReportSequence,
                  lastRawContactPresent,
                  let lastContactReportNanos else {
                return []
            }

            // Treat the silence boundary as contact end only after the token
            // survived the full delay. Any newer report invalidates this token.
            lastRawContactPresent = false
            self.lastContactReportNanos = nil
            tapSilenceWorkItem = nil
            tapSurfaceDiagnostics.observeSilenceContactEnd()
            Diagnostics.log(
                "corehid contact lifecycle end source=report-silence"
            )

            do {
                let events = try translator.finishContact(
                    nowNanos: lastContactReportNanos
                )
                if let resolution = translator.takeTapResolution() {
                    tapSurfaceDiagnostics.observeTapDecision()
                    Diagnostics.log(
                        "corehid tap decision outcome=\(resolution.rawValue) "
                            + "source=report-silence"
                    )
                }
                for event in events {
                    recordSemanticButtonIfNeeded(event)
                }
                return events
            } catch {
                Diagnostics.log(
                    "corehid tap silence finalization failed"
                )
                return []
            }
        }

        for event in events {
            onDeferredEvent(event)
        }
    }

    private func recordSemanticButtonIfNeeded(
        _ event: SemanticPointerEvent
    ) {
        if case let .button(button, down) = event.kind {
            _ = button
            _ = down
            tapSurfaceDiagnostics.observeSemanticButton()
            Diagnostics.log("corehid semantic input type=button")
        }
    }

    func deactivateAndReset() -> [SemanticPointerEvent] {
        let result = lock.withLock {
            guard active else {
                return (
                    events: [SemanticPointerEvent](),
                    workItem: Optional<DispatchWorkItem>.none
                )
            }
            active = false
            contactReportSequence &+= 1
            let workItem = tapSilenceWorkItem
            tapSilenceWorkItem = nil
            Diagnostics.log(tapSurfaceDiagnostics.summary)
            return (events: translator.reset(), workItem: workItem)
        }
        result.workItem?.cancel()
        return result.events
    }

    /// Returns true only for the first terminal failure.
    func fail() -> Bool {
        let result = lock.withLock {
            guard active else {
                return (
                    failed: false,
                    workItem: Optional<DispatchWorkItem>.none
                )
            }
            active = false
            contactReportSequence &+= 1
            let workItem = tapSilenceWorkItem
            tapSilenceWorkItem = nil
            Diagnostics.log(tapSurfaceDiagnostics.summary)
            _ = translator.reset()
            return (failed: true, workItem: workItem)
        }
        result.workItem?.cancel()
        return result.failed
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
    private let monitorCompletion: CoreHIDMonitorCompletion
    private let releaseLock = NSLock()
    private var released = false

    fileprivate init(
        generation: UInt64,
        registry: CoreHIDPointerLeaseRegistry,
        clientSlot: CoreHIDPointerClientSlot,
        streamState: CoreHIDPointerStreamState,
        releaseResponsibility: CoreHIDPointerReleaseResponsibility,
        monitorTask: Task<Void, Never>,
        monitorCompletion: CoreHIDMonitorCompletion
    ) {
        self.generation = generation
        self.registry = registry
        self.clientSlot = clientSlot
        self.streamState = streamState
        self.releaseResponsibility = releaseResponsibility
        self.monitorTask = monitorTask
        self.monitorCompletion = monitorCompletion
    }

    func transferReleaseResponsibilityToLifecycleOwner() {
        releaseResponsibility.transferToLifecycleOwner()
    }

    /// Non-blocking local-return boundary.
    ///
    /// CrossInput stops admitting stream events and cancels monitoring
    /// synchronously, then retires the seizing HIDDeviceClient off the caller.
    /// CoreHID frees the device when that client deinitializes, so the return
    /// caller must never execute potentially blocking client teardown while an
    /// outstanding monitor call is retiring. MainActor and emergency recovery
    /// remain live throughout release.
    func release() {
        let shouldRelease = releaseLock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        guard shouldRelease else { return }

        // Close semantic admission before cancellation so no late report can
        // enqueue remote work after return has started.
        _ = streamState.deactivateAndReset()
        monitorTask.cancel()

        // Withdraw CrossInput ownership immediately, but do NOT drop the last
        // HIDDeviceClient reference on this caller. CoreHID frees a seized
        // device when that client deinitializes, and deinit can synchronize
        // with an outstanding monitor call. Running that teardown inline can
        // therefore stall MainActor and make the emergency-return path
        // unreachable. Retire the monitor first, then deinitialize the client
        // on a detached release worker.
        registry.release(generation)
        Diagnostics.log(
            "corehid pointer release scheduled generation=\(generation)"
        )

        let releaseGeneration = generation
        let monitorCompletion = monitorCompletion
        let clientSlot = clientSlot
        Task.detached(priority: .userInitiated) {
            let monitorStopped = monitorCompletion.wait(
                timeout: .seconds(1)
            )
            Diagnostics.log(
                "corehid pointer monitor retirement generation=\(releaseGeneration) "
                    + "stopped=\(monitorStopped)"
            )

            // Even if monitor retirement exceeds the diagnostic bound, keep
            // any potentially blocking HIDDeviceClient deinit off the return
            // caller. Cancellation was already requested and stream admission
            // is closed, so this worker is the sole teardown owner.
            let deinitialized = clientSlot.dropClient()
            Diagnostics.log(
                "corehid pointer client release generation=\(releaseGeneration) "
                    + "deinitialized=\(deinitialized)"
            )
        }
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
            let registry = self.registry
            let streamState = CoreHIDPointerStreamState(
                onDeferredEvent: { event in
                    guard registry.isCurrent(generation) else { return }
                    onEvent(event, generation)
                }
            )
            let releaseResponsibility =
                CoreHIDPointerReleaseResponsibility()
            let monitorCompletion = CoreHIDMonitorCompletion()

            // Critical ownership shape: the task captures the stream and slot,
            // never the seizing HIDDeviceClient directly. release() can drop
            // the final explicit client reference without awaiting this task.
            let monitorTask = Task {
                defer { monitorCompletion.finish() }

                func failClosed(_ reason: String) {
                    guard streamState.fail() else { return }
                    Diagnostics.log(
                        "corehid pointer stream failed generation=\(generation) reason=\(reason)"
                    )

                    // A published lease is owned by Control. Dispatch the
                    // lifecycle callback out of this monitor task so release()
                    // can synchronously wait for monitor retirement without
                    // ever self-waiting on the task that detected the failure.
                    if releaseResponsibility.isLifecycleOwned {
                        Task {
                            onFailure(generation)
                        }
                    } else {
                        onFailure(generation)
                        if registry.isCurrent(generation) {
                            _ = clientSlot.dropClient()
                            registry.release(generation)
                        }
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
                monitorTask: monitorTask,
                monitorCompletion: monitorCompletion
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
