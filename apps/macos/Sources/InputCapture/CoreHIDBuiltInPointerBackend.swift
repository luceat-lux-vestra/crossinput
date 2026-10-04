import Foundation
import InputDomain
import Diagnostics

#if canImport(CoreHID)
import CoreHID

@available(macOS 15.0, *)
enum CoreHIDPhysicalReleaseEvidence {
    static func isProven(
        processExited: Bool,
        deviceUnseized: Bool
    ) -> Bool {
        processExited && deviceUnseized
    }
}

@available(macOS 15.0, *)
enum CoreHIDUnseizeWitnessState: Equatable, Sendable {
    case monitoring
    case seized
    case unseized
    case failed

    /// A release notification is evidence only if this witness observed the
    /// matching seizure first. CoreHID notification streams are asynchronous;
    /// an initial/stale unseized notification must never satisfy a new
    /// generation's physical-release proof.
    mutating func observeSeized() -> Bool {
        switch self {
        case .monitoring, .seized:
            self = .seized
            return true
        case .unseized, .failed:
            return false
        }
    }

    mutating func observeUnseized() -> Bool {
        guard self == .seized else { return false }
        self = .unseized
        return true
    }

    mutating func fail() {
        guard self != .unseized else { return }
        self = .failed
    }

    var sawSeized: Bool {
        self == .seized || self == .unseized
    }

    var isCurrentlySeized: Bool {
        self == .seized
    }

    var releaseProven: Bool {
        self == .unseized
    }
}

@available(macOS 15.0, *)
private final class CoreHIDUnseizeWitness: @unchecked Sendable {
    private let generation: UInt64
    private let lock = NSLock()
    private var state: CoreHIDUnseizeWitnessState = .monitoring
    private var task: Task<Void, Never>?
    private var client: HIDDeviceClient?

    init(
        generation: UInt64,
        client: HIDDeviceClient
    ) {
        self.generation = generation
        self.client = client
    }

    func start(
        stream: AsyncThrowingStream<HIDDeviceClient.Notification, any Error>
    ) {
        let task = Task { [weak self] in
            do {
                for try await notification in stream {
                    guard let self else { return }
                    if Task.isCancelled { return }

                    switch notification {
                    case .deviceSeized:
                        let accepted = self.lock.withLock {
                            self.state.observeSeized()
                        }
                        if accepted {
                            Diagnostics.log(
                                "corehid unseize witness generation=\(generation) event=device-seized"
                            )
                        }

                    case .deviceUnseized:
                        let accepted = self.lock.withLock {
                            self.state.observeUnseized()
                        }
                        guard accepted else {
                            Diagnostics.log(
                                "corehid unseize witness generation=\(generation) "
                                    + "event=device-unseized-ignored reason=seize-not-observed"
                            )
                            continue
                        }
                        Diagnostics.log(
                            "corehid unseize witness generation=\(generation) event=device-unseized"
                        )
                        return

                    case .deviceRemoved:
                        self.lock.withLock {
                            self.state.fail()
                        }
                        Diagnostics.log(
                            "corehid unseize witness generation=\(generation) event=device-removed"
                        )
                        return

                    case .inputReport, .elementUpdates:
                        break

                    @unknown default:
                        self.lock.withLock {
                            self.state.fail()
                        }
                        Diagnostics.log(
                            "corehid unseize witness generation=\(generation) event=unknown"
                        )
                        return
                    }
                }

                guard let self else { return }
                self.lock.withLock {
                    self.state.fail()
                }
            } catch is CancellationError {
                // Expected when acquisition fails or the lease is torn down.
            } catch {
                guard let self else { return }
                self.lock.withLock {
                    self.state.fail()
                }
                Diagnostics.log(
                    "corehid unseize witness generation=\(generation) event=stream-error"
                )
            }
        }

        lock.withLock {
            self.task = task
        }
    }

    var sawSeized: Bool {
        lock.withLock { state.sawSeized }
    }

    func awaitSeized(
        maxChecks: Int = 100,
        delay: Duration = .milliseconds(2)
    ) async -> Bool {
        for _ in 0..<maxChecks {
            let snapshot = lock.withLock { state }
            switch snapshot {
            case .seized:
                return true
            case .unseized, .failed:
                return false
            case .monitoring:
                break
            }
            try? await Task.sleep(for: delay)
        }
        return lock.withLock { state.isCurrentlySeized }
    }

    var isCurrentlySeized: Bool {
        lock.withLock { state.isCurrentlySeized }
    }

    func awaitUnseized(
        maxChecks: Int = 400,
        delay: Duration = .milliseconds(2)
    ) async -> Bool {
        for _ in 0..<maxChecks {
            let snapshot = lock.withLock { state }
            switch snapshot {
            case .unseized:
                return true
            case .failed:
                return false
            case .monitoring, .seized:
                break
            }
            try? await Task.sleep(for: delay)
        }
        return lock.withLock { state.releaseProven }
    }

    func stop() {
        let task = lock.withLock {
            let task = self.task
            self.task = nil
            client = nil
            return task
        }
        task?.cancel()
    }

    deinit {
        stop()
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
final class CoreHIDPointerStreamState: @unchecked Sendable {
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

    var hasActiveContact: Bool {
        lock.withLock { lastRawContactPresent }
    }
}

@available(macOS 15.0, *)
final class CoreHIDPointerLease: HostPointerOwnershipLease, @unchecked Sendable {
    let generation: UInt64

    var isActive: Bool {
        ownershipProcess.isRunning
            && unseizeWitness.isCurrentlySeized
            && registry.isCurrent(generation)
    }

    private let registry: CoreHIDPointerLeaseRegistry
    private let ownershipProcess: CoreHIDPointerOwnershipProcess
    private let unseizeWitness: CoreHIDUnseizeWitness

    private enum PhysicalReleaseState {
        case active
        case releasing
        case released
        case failed
    }

    private let releaseCondition = NSCondition()
    private var physicalReleaseState: PhysicalReleaseState = .active

    fileprivate init(
        generation: UInt64,
        registry: CoreHIDPointerLeaseRegistry,
        ownershipProcess: CoreHIDPointerOwnershipProcess,
        unseizeWitness: CoreHIDUnseizeWitness
    ) {
        self.generation = generation
        self.registry = registry
        self.ownershipProcess = ownershipProcess
        self.unseizeWitness = unseizeWitness
    }

    func transferReleaseResponsibilityToLifecycleOwner() {
        ownershipProcess.markPublished()
    }

    private func completePhysicalRelease(
        physicallyReleased: Bool
    ) {
        releaseCondition.lock()
        physicalReleaseState =
            physicallyReleased ? .released : .failed
        releaseCondition.broadcast()
        releaseCondition.unlock()
    }

    /// Physical local-return boundary.
    ///
    /// The CoreHID seizing client exists only in a disposable child process.
    /// A successful return therefore requires two independent facts:
    /// 1. the owning child process is gone (graceful EOF or SIGKILL fallback);
    /// 2. a non-seizing CoreHID witness observed deviceUnseized.
    ///
    /// The registry remains reserved until both facts are true, preventing a
    /// new generation from stacking on an ownership state the OS has not
    /// independently acknowledged as released.
    @discardableResult
    func release() -> Bool {
        var shouldStartWorker = false

        releaseCondition.lock()
        switch physicalReleaseState {
        case .released:
            releaseCondition.unlock()
            return true
        case .active:
            physicalReleaseState = .releasing
            shouldStartWorker = true
        case .failed:
            releaseCondition.unlock()
            Diagnostics.log(
                "corehid pointer release gate generation=\(generation) "
                    + "completed=false terminal=true"
            )
            return false
        case .releasing:
            break
        }
        releaseCondition.unlock()

        if shouldStartWorker {
            let releaseGeneration = generation
            let ownershipProcess = ownershipProcess
            let registry = registry
            let unseizeWitness = unseizeWitness

            Diagnostics.log(
                "corehid pointer release scheduled generation=\(generation) "
                    + "owner=process"
            )

            Task.detached(priority: .userInitiated) { [weak self] in
                let processEvidence = ownershipProcess.stopAndWait()
                let unseized: Bool
                if processEvidence.processExited {
                    unseized = await unseizeWitness.awaitUnseized(
                        maxChecks: 750,
                        delay: .milliseconds(2)
                    )
                } else {
                    unseized = false
                }

                Diagnostics.log(
                    "corehid pointer process release generation=\(releaseGeneration) "
                        + "processExited=\(processEvidence.processExited) "
                        + "forced=\(processEvidence.forced) "
                        + "status=\(processEvidence.status.map(String.init) ?? "none")"
                )
                Diagnostics.log(
                    "corehid pointer os release generation=\(releaseGeneration) "
                        + "deviceUnseized=\(unseized) "
                        + "witnessSawSeized=\(unseizeWitness.sawSeized)"
                )

                let physicallyReleased =
                    CoreHIDPhysicalReleaseEvidence.isProven(
                        processExited: processEvidence.processExited,
                        deviceUnseized: unseized
                    )
                if physicallyReleased {
                    registry.release(releaseGeneration)
                    unseizeWitness.stop()
                }

                self?.completePhysicalRelease(
                    physicallyReleased: physicallyReleased
                )
            }
        }

        // The worker's bounded path is at most 1.25 s of process teardown plus
        // 1.5 s of witness polling, before scheduling/logging overhead. Keep
        // the caller deadline strictly wider than that internal budget so the
        // controller cannot observe a synthetic timeout immediately before a
        // successful worker completion.
        let deadline = Date().addingTimeInterval(4.0)
        releaseCondition.lock()
        while physicalReleaseState == .releasing {
            if !releaseCondition.wait(until: deadline) {
                break
            }
        }
        let released = physicalReleaseState == .released
        releaseCondition.unlock()

        Diagnostics.log(
            "corehid pointer release gate generation=\(generation) "
                + "completed=\(released)"
        )
        return released
    }

    deinit {
        _ = release()
    }
}

@available(macOS 15.0, *)
final class CoreHIDBuiltInPointerBackend: HostPointerOwnershipBackend {
    enum AcquisitionError: Error, Equatable, Sendable {
        case discoveryTimeout
        case clientCreation
        case deviceIdentity
        case helperStart
        case helperPrepared
        case helperActivation
        case helperReady
        case unseizeWitness
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
        var witness: CoreHIDUnseizeWitness?
        var ownershipProcess: CoreHIDPointerOwnershipProcess?

        do {
            try Task.checkCancellation()

            let reference: HIDDeviceClient.DeviceReference
            do {
                reference = try await CoreHIDPointerDeviceDiscovery
                    .discoverBuiltInTrackpadMouse(timeout: discoveryTimeout)
            } catch {
                throw AcquisitionError.discoveryTimeout
            }
            try Task.checkCancellation()

            guard let witnessClient = HIDDeviceClient(
                deviceReference: reference
            ) else {
                throw AcquisitionError.clientCreation
            }
            guard let deviceIdentity = CoreHIDPointerDeviceIdentity(
                vendorID: await witnessClient.vendorID,
                productID: await witnessClient.productID,
                uniqueID: await witnessClient.uniqueID,
                locationID: await witnessClient.locationID
            ) else {
                // Cross-process ownership is allowed only when the witness and
                // seizer can be bound to the same specific physical device.
                throw AcquisitionError.deviceIdentity
            }
            let witnessStream = await witnessClient.monitorNotifications(
                reportIDsToMonitor: [HIDReportID.allReports],
                elementsToMonitor: []
            )
            let releaseWitness = CoreHIDUnseizeWitness(
                generation: generation,
                client: witnessClient
            )
            witness = releaseWitness
            releaseWitness.start(stream: witnessStream)
            await Task.yield()
            try Task.checkCancellation()

            let helper = CoreHIDPointerOwnershipProcess(
                generation: generation,
                launchConfiguration: .production(
                    generation: generation,
                    identity: deviceIdentity
                ),
                onEvent: onEvent,
                onFailure: onFailure
            )
            ownershipProcess = helper
            do {
                try helper.start()
            } catch {
                throw AcquisitionError.helperStart
            }

            do {
                try await helper.awaitPrepared(timeout: discoveryTimeout)
            } catch {
                throw AcquisitionError.helperPrepared
            }
            try Task.checkCancellation()

            do {
                try helper.activateSeizure()
            } catch {
                throw AcquisitionError.helperActivation
            }
            try Task.checkCancellation()

            do {
                try await helper.awaitReady(timeout: discoveryTimeout)
            } catch {
                throw AcquisitionError.helperReady
            }

            guard await releaseWitness.awaitSeized(
                maxChecks: 500,
                delay: .milliseconds(2)
            ) else {
                throw AcquisitionError.unseizeWitness
            }

            Diagnostics.log(
                "corehid pointer seized generation=\(generation) "
                    + "witness=true owner=process"
            )
            try Task.checkCancellation()

            return CoreHIDPointerLease(
                generation: generation,
                registry: registry,
                ownershipProcess: helper,
                unseizeWitness: releaseWitness
            )
        } catch {
            await cleanupFailedAcquisition(
                generation: generation,
                ownershipProcess: ownershipProcess,
                witness: witness
            )
            throw error
        }
    }

    private func cleanupFailedAcquisition(
        generation: UInt64,
        ownershipProcess: CoreHIDPointerOwnershipProcess?,
        witness: CoreHIDUnseizeWitness?
    ) async {
        guard let ownershipProcess else {
            witness?.stop()
            registry.release(generation)
            return
        }

        // Before the explicit activation commit, the helper is provably
        // non-seizing. After commit, cleanup conservatively requires
        // independent deviceUnseized evidence even if cancellation or process
        // death races the helper's ready acknowledgement.
        let seizureWasPossible =
            ownershipProcess.seizureMayHaveOccurred
        let processEvidence = ownershipProcess.stopAndWait()

        let unseized: Bool
        if seizureWasPossible, let witness, processEvidence.processExited {
            unseized = await witness.awaitUnseized(
                maxChecks: 1000,
                delay: .milliseconds(2)
            )
        } else {
            unseized = !seizureWasPossible
        }

        let physicallyReleased =
            processEvidence.processExited && unseized
        Diagnostics.log(
            "corehid acquisition cleanup generation=\(generation) "
                + "processExited=\(processEvidence.processExited) "
                + "deviceUnseized=\(unseized) "
                + "seizureWasPossible=\(seizureWasPossible)"
        )

        guard physicallyReleased else {
            // Fail closed. There is no seizing child left to retry; retaining
            // the registry reservation prevents a second ownership generation
            // from stacking on an OS state that lacks independent proof.
            Diagnostics.log(
                "corehid acquisition cleanup unresolved generation=\(generation)"
            )
            return
        }

        registry.release(generation)
        witness?.stop()
    }
}

#endif
