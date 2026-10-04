import Foundation
import Darwin
import InputDomain
import Diagnostics

#if canImport(CoreHID)
@available(macOS 15.0, *)
final class CoreHIDPointerOwnershipProcess: @unchecked Sendable {
    struct StopEvidence: Equatable, Sendable {
        let processExited: Bool
        let forced: Bool
        let status: Int32?
    }

    enum StartError: Error, Equatable, Sendable {
        case launch(String)
        case helperFailure(CoreHIDPointerIPC.Failure?)
        case helperExited(Int32?)
        case preparedTimeout
        case activationFailed
        case readyTimeout
    }

    struct LaunchConfiguration: Sendable {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]?

        init(
            executableURL: URL,
            arguments: [String],
            environment: [String: String]? = nil
        ) {
            self.executableURL = executableURL
            self.arguments = arguments
            self.environment = environment
        }

        static func production(
            generation: UInt64,
            identity: CoreHIDPointerDeviceIdentity
        ) -> LaunchConfiguration {
            LaunchConfiguration(
                executableURL: URL(fileURLWithPath: CommandLine.arguments[0]),
                arguments: [
                    CoreHIDPointerOwnershipHelperMode.flag,
                    String(generation),
                ],
                environment: identity.applying(
                    to: ProcessInfo.processInfo.environment
                )
            )
        }
    }

    private let generation: UInt64
    private let onEvent: HostPointerEventHandler
    private let onFailure: HostPointerFailureHandler
    private let launchConfiguration: LaunchConfiguration

    private let condition = NSCondition()
    private var process: Process?
    private var controlWrite: FileHandle?
    private var eventRead: FileHandle?
    private var eventBuffer = Data()
    private var prepared = false
    private var activationCommitted = false
    private var ready = false
    private var helperFailure: CoreHIDPointerIPC.Failure?
    private var exited = false
    private var exitStatus: Int32?
    private var stopping = false
    private var published = false
    private var failureDelivered = false

    init(
        generation: UInt64,
        launchConfiguration: LaunchConfiguration,
        onEvent: @escaping HostPointerEventHandler,
        onFailure: @escaping HostPointerFailureHandler
    ) {
        self.generation = generation
        self.launchConfiguration = launchConfiguration
        self.onEvent = onEvent
        self.onFailure = onFailure
    }

    var isRunning: Bool {
        condition.lock()
        let running = ready && helperFailure == nil && !stopping && !exited
        condition.unlock()
        return running
    }

    var seizureMayHaveOccurred: Bool {
        condition.lock()
        let value = activationCommitted
        condition.unlock()
        return value
    }

    func start() throws {
        let child = Process()
        let control = Pipe()
        let events = Pipe()

        child.executableURL = launchConfiguration.executableURL
        child.arguments = launchConfiguration.arguments
        if let environment = launchConfiguration.environment {
            child.environment = environment
        }
        child.standardInput = control.fileHandleForReading
        child.standardOutput = events.fileHandleForWriting
        child.standardError = FileHandle.nullDevice

        child.terminationHandler = { [weak self] process in
            self?.recordExit(status: process.terminationStatus)
        }

        condition.lock()
        process = child
        controlWrite = control.fileHandleForWriting
        eventRead = events.fileHandleForReading
        condition.unlock()

        events.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.recordEventStreamEnd()
                return
            }
            self.consume(data)
        }

        do {
            try child.run()
        } catch {
            events.fileHandleForReading.readabilityHandler = nil
            try? control.fileHandleForReading.close()
            try? control.fileHandleForWriting.close()
            try? events.fileHandleForReading.close()
            try? events.fileHandleForWriting.close()

            condition.lock()
            process = nil
            controlWrite = nil
            eventRead = nil
            exited = true
            condition.broadcast()
            condition.unlock()
            throw StartError.launch(error.localizedDescription)
        }

        // The parent owns only stdin-write and stdout-read. Closing these
        // duplicate child-side descriptors is required for EOF to be a real
        // parent-lifetime signal.
        try? control.fileHandleForReading.close()
        try? events.fileHandleForWriting.close()

        Diagnostics.log(
            "corehid ownership helper launched generation=\(generation) "
                + "pid=\(child.processIdentifier)"
        )
    }

    func awaitPrepared(timeout: Duration = .seconds(3)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            let snapshot = snapshot()
            if snapshot.prepared {
                return
            }
            if let failure = snapshot.failure {
                throw StartError.helperFailure(failure)
            }
            if snapshot.exited {
                throw StartError.helperExited(snapshot.status)
            }
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(5))
        }

        let snapshot = snapshot()
        if snapshot.prepared { return }
        if let failure = snapshot.failure {
            throw StartError.helperFailure(failure)
        }
        if snapshot.exited {
            throw StartError.helperExited(snapshot.status)
        }
        throw StartError.preparedTimeout
    }

    /// Commits this generation to seizure. The state flips before the byte is
    /// written so any ambiguous pipe-write failure is treated conservatively:
    /// cleanup must then obtain independent deviceUnseized evidence.
    func activateSeizure() throws {
        let writer: FileHandle

        condition.lock()
        guard prepared,
              !activationCommitted,
              helperFailure == nil,
              !exited,
              !stopping,
              let controlWrite else {
            condition.unlock()
            throw StartError.activationFailed
        }
        activationCommitted = true
        writer = controlWrite
        condition.unlock()

        do {
            try writer.write(
                contentsOf: Data([CoreHIDPointerIPC.activateCommand])
            )
        } catch {
            condition.lock()
            if helperFailure == nil {
                helperFailure = .protocolViolation
            }
            condition.broadcast()
            condition.unlock()
            throw StartError.activationFailed
        }

        Diagnostics.log(
            "corehid ownership helper activation committed generation=\(generation)"
        )
    }

    func awaitReady(timeout: Duration = .seconds(3)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            let snapshot = snapshot()
            if snapshot.ready {
                return
            }
            if let failure = snapshot.failure {
                throw StartError.helperFailure(failure)
            }
            if snapshot.exited {
                throw StartError.helperExited(snapshot.status)
            }
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(5))
        }

        let snapshot = snapshot()
        if snapshot.ready { return }
        if let failure = snapshot.failure {
            throw StartError.helperFailure(failure)
        }
        if snapshot.exited {
            throw StartError.helperExited(snapshot.status)
        }
        throw StartError.readyTimeout
    }

    /// Called at the same lifecycle boundary as lease publication. Any helper
    /// failure that raced between acquire() and publication is delivered only
    /// after Control owns the release ordering.
    func markPublished() {
        var deliverFailure = false
        condition.lock()
        published = true
        deliverFailure = shouldDeliverFailureLocked()
        condition.unlock()

        if deliverFailure {
            onFailure(generation)
        }
    }

    /// Process lifetime is the seizure lifetime. Normal return requests EOF;
    /// a wedged helper is then forcibly killed. Success here proves only that
    /// the owning task is gone; the independent witness proves OS unseize.
    func stopAndWait(
        gracefulTimeout: TimeInterval = 0.25,
        forcedTimeout: TimeInterval = 1.0
    ) -> StopEvidence {
        var writer: FileHandle?
        var child: Process?

        condition.lock()
        if exited {
            let evidence = StopEvidence(
                processExited: true,
                forced: false,
                status: exitStatus
            )
            condition.unlock()
            retireParentHandles()
            return evidence
        }
        stopping = true
        writer = controlWrite
        controlWrite = nil
        child = process
        condition.unlock()

        try? writer?.close()

        if waitForExit(timeout: gracefulTimeout) {
            let status = currentExitStatus()
            retireParentHandles()
            Diagnostics.log(
                "corehid ownership helper exited generation=\(generation) "
                    + "forced=false status=\(status.map(String.init) ?? "none")"
            )
            return StopEvidence(
                processExited: true,
                forced: false,
                status: status
            )
        }

        var forced = false
        if let child, child.isRunning {
            forced = true
            let result = Darwin.kill(child.processIdentifier, SIGKILL)
            Diagnostics.log(
                "corehid ownership helper kill generation=\(generation) "
                    + "pid=\(child.processIdentifier) result=\(result)"
            )
        }

        let didExit = waitForExit(timeout: forcedTimeout)
        let status = currentExitStatus()
        if didExit {
            retireParentHandles()
        }
        Diagnostics.log(
            "corehid ownership helper exited generation=\(generation) "
                + "forced=\(forced) processExited=\(didExit) "
                + "status=\(status.map(String.init) ?? "none")"
        )
        return StopEvidence(
            processExited: didExit,
            forced: forced,
            status: status
        )
    }

    private func consume(_ data: Data) {
        var semanticEvents: [SemanticPointerEvent] = []
        var deliverFailure = false

        condition.lock()
        eventBuffer.append(data)
        do {
            let frames = try CoreHIDPointerIPC.decodeAvailable(
                from: &eventBuffer
            )
            for frame in frames {
                switch frame.kind {
                case .prepared:
                    if prepared || activationCommitted || ready {
                        helperFailure = .protocolViolation
                    } else {
                        prepared = true
                        condition.broadcast()
                        Diagnostics.log(
                            "corehid ownership helper prepared generation=\(generation)"
                        )
                    }

                case .ready:
                    if !prepared || !activationCommitted || ready {
                        helperFailure = .protocolViolation
                    } else {
                        ready = true
                        condition.broadcast()
                        Diagnostics.log(
                            "corehid ownership helper ready generation=\(generation)"
                        )
                    }

                case .failure:
                    helperFailure =
                        CoreHIDPointerIPC.Failure(rawValue: frame.a)
                        ?? .protocolViolation
                    condition.broadcast()

                case .move, .button, .scroll:
                    guard ready,
                          let event = CoreHIDPointerIPC.event(from: frame) else {
                        helperFailure = .protocolViolation
                        condition.broadcast()
                        continue
                    }
                    if published && !stopping {
                        semanticEvents.append(event)
                    }
                }
            }
        } catch {
            helperFailure = .protocolViolation
            condition.broadcast()
        }
        deliverFailure = shouldDeliverFailureLocked()
        condition.unlock()

        for event in semanticEvents {
            onEvent(event, generation)
        }
        if deliverFailure {
            onFailure(generation)
        }
    }

    private func recordEventStreamEnd() {
        var deliverFailure = false
        condition.lock()
        if !stopping && !exited && helperFailure == nil {
            helperFailure = .protocolViolation
        }
        deliverFailure = shouldDeliverFailureLocked()
        condition.broadcast()
        condition.unlock()

        if deliverFailure {
            onFailure(generation)
        }
    }

    private func recordExit(status: Int32) {
        var deliverFailure = false
        condition.lock()
        exited = true
        exitStatus = status
        deliverFailure = shouldDeliverFailureLocked()
        condition.broadcast()
        condition.unlock()

        if deliverFailure {
            onFailure(generation)
        }
    }

    private func shouldDeliverFailureLocked() -> Bool {
        guard published,
              !stopping,
              !failureDelivered,
              helperFailure != nil || exited else {
            return false
        }
        failureDelivered = true
        return true
    }

    private func snapshot() -> (
        prepared: Bool,
        ready: Bool,
        failure: CoreHIDPointerIPC.Failure?,
        exited: Bool,
        status: Int32?
    ) {
        condition.lock()
        let snapshot = (
            prepared,
            ready,
            helperFailure,
            exited,
            exitStatus
        )
        condition.unlock()
        return snapshot
    }

    private func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while !exited {
            if !condition.wait(until: deadline) {
                break
            }
        }
        let didExit = exited
        condition.unlock()
        return didExit
    }

    private func currentExitStatus() -> Int32? {
        condition.lock()
        let status = exitStatus
        condition.unlock()
        return status
    }

    private func retireParentHandles() {
        var reader: FileHandle?
        var writer: FileHandle?
        condition.lock()
        reader = eventRead
        writer = controlWrite
        eventRead = nil
        controlWrite = nil
        process = nil
        condition.unlock()

        reader?.readabilityHandler = nil
        try? reader?.close()
        try? writer?.close()
    }

    deinit {
        condition.lock()
        let child = process
        let writer = controlWrite
        stopping = true
        controlWrite = nil
        condition.unlock()

        try? writer?.close()
        if let child, child.isRunning {
            _ = Darwin.kill(child.processIdentifier, SIGKILL)
        }
        retireParentHandles()
    }
}
#endif
