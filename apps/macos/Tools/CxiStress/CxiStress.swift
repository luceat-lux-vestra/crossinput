import Foundation
import Protocol
import AndroidBridge
@preconcurrency import InputCapture
import Delivery
import Diagnostics

/// Headless production-path stress runner for issue #62.
///
/// Exercises the REAL delivery pipeline — SessionController/SessionReference,
/// InputSender queue admission + batch delivery, RemoteSession request
/// correlation, AdbTransport wireless ADB channel, and the on-device helper —
/// without launching the GUI app. Workloads enqueue PointerEvents through
/// `InputSender.enqueuePointer`, exactly as the capture path does.
///
/// Usage: cxi-stress --profile <name> [--serial <adb-serial>] [--iterations N]
///                   [--burst-count N] [--idle-ms N] [--rate-hz N] [--out DIR]
///
/// Profiles: baseline | scroll-burst | move-burst | mixed | burst-idle
///
/// Output: metadata-only JSON (latency samples, outcome taxonomy, late
/// responses, admission counters). No input payloads are ever emitted.
@main
@MainActor
struct CxiStress {
    static func main() async throws {
        let config = parseArgs()
        Diagnostics.logURL = tempLogURL()

        let transport = AdbTransport()
        let serial: String
        if let explicitSerial = config.serial {
            serial = explicitSerial
        } else {
            serial = transport.firstConnectedSerial()
        }
        guard !serial.isEmpty else {
            fputs("ERROR: no adb device connected\n", stderr)
            exit(3)
        }
        // Wireless evidence (work order section 9): classify the selected
        // serial FORM. mDNS/TLS wireless serials contain
        // "._adb-tls-connect._tcp"; host:port pairs are manual wireless;
        // anything else is USB or hub-relay. The raw identifier is never
        // printed.
        print("serial_class=\(classifySerial(serial))")

        let reference = SessionReference()
        let controller = SessionController(adbTransport: transport, reference: reference)
        controller.onUnavailable = { reason in
            print("session_unavailable reason=\(reason)")
        }

        print("connecting...")
        try await controller.connect(serial: serial)
        guard let session = reference.snapshot().connection as? RemoteSession else {
            fputs("ERROR: connected session is not a RemoteSession\n", stderr)
            exit(1)
        }
        print("handshake_ok capabilities=\(session.helperCapabilities.rawValue)")

        // Select a desktop display when one exists; pointer routing must be
        // valid before bursts start. DeX being ACTIVE remains the caller's
        // precondition (fail-closed below).
        let listFrame = try await session.request(.listDisplays, payload: Data())
        let displays = try Messages.decodeDisplayList(listFrame.payload)
        for display in displays {
            print("display id=\(display.displayId) type=\(display.type) desktop=\(display.isDesktop)")
        }
        // Review round 3: fail-closed on the DeX/desktop target. Falling
        // back to any display would let a non-DeX run pass as #62 evidence.
        guard let desktop = displays.first(where: { $0.isDesktop }) else {
            fputs("ERROR: no DeX desktop display found; refusing to run " +
                  "(exit 3, precondition unavailable)\n", stderr)
            session.shutdownAndWait()
            exit(3)
        }
        _ = try await session.request(.selectDisplay,
                                      payload: Messages.selectDisplay(displayId: desktop.displayId))
        print("display_selected id=\(desktop.displayId) desktop=true")

        let sender = InputSender(session: reference)

        let counterBox = CounterBox()
        sender.onDeliveryObservation = { observation in
            counterBox.append(observation, layer: .delivery)
        }
        session.onObservation = { observation in
            counterBox.append(observation, layer: .session)
        }
        let started = iso8601Now()
        let admissionBox = AdmissionBox()
        switch config.profile {
        case "baseline":
            await runBaseline(sender: sender, config: config, admissionBox: admissionBox)
        case "scroll-burst":
            await runBursts(sender: sender, config: config,
                            kind: .scroll(horizontal: 0, vertical: 4), admissionBox: admissionBox)
        case "move-burst":
            await runBursts(sender: sender, config: config, kind: .move(dx: 6, dy: 0), admissionBox: admissionBox)
        case "mixed":
            await runMixed(sender: sender, config: config, admissionBox: admissionBox)
        case "burst-idle":
            await runBurstIdleCycles(sender: sender, config: config, admissionBox: admissionBox)
        case "queue-pressure":
            await runQueuePressure(sender: sender, config: config, admissionBox: admissionBox)
        default:
            fputs("unknown profile: \(config.profile)\n", stderr)
            exit(2)
        }
        sender.waitForDrain()
        // Review round 2: if any timeout fired, a helper response may still
        // be in flight past the deadline. Wait a bounded grace window before
        // snapshotting late responses so the core question — "timeout, or
        // valid POINTER_RESULT after the deadline?" — is answered from data,
        // not lost to immediate teardown.
        let record0 = counterBox.counter.record
        if record0.timeouts > 0 {
            print("late_response_grace_window seconds=\(graceWindowSeconds)")
            try? await Task.sleep(nanoseconds: UInt64(CxiStress.graceWindowSeconds * 1_000_000_000))
            sender.waitForDrain()
        }
        print("admission \(admissionBox.description)")
        print("delivery_results deliveredMovement=\(admissionBox.deliveredMovement) partial=\(admissionBox.partiallyDeliveredMovement) delivered=\(admissionBox.delivered) cancelled=\(admissionBox.cancelled) failed=\(admissionBox.failed)")
        let ended = iso8601Now()

        let record = counterBox.finalize(profile: config.profile,
                                         started: started,
                                         ended: ended,
                                         lateResponses: session.snapshotLateResponses(),
                                         capabilities: session.helperCapabilities.rawValue,
                                         admission: admissionBox.snapshot(),
                                         deliveryResults: admissionBox.deliverySnapshot())

        for line in counterBox.counter.summaryLines() {
            print(line)
        }
        if record.timeouts > 0 || record.lateResponses > 0 {
            print("TIMEOUT_DETAIL budget=\(record.timeoutBudgets) late_delays=\(record.lateDelaySeconds)")
        }

        let json = try encode(record)
        if let outDir = config.outDir {
            let url = URL(fileURLWithPath: outDir, isDirectory: true)
                .appendingPathComponent("stress-result-\(started.replacingOccurrences(of: ":", with: "")).json")
            try json.write(to: url)
            print("result_written \(url.path)")
        } else {
            FileHandle.standardOutput.write(json)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }

        session.shutdownAndWait()
        exit(Int32(exitCode(record: record, admissionBox: admissionBox)))
    }

    // MARK: - Workload profiles

    /// A: serial low-rate baseline for ordinary wireless RTT.
    static func runBaseline(sender: InputSender, config: Config, admissionBox: AdmissionBox) async {
        let interval = UInt64(1_000_000_000 / max(1, config.rateHz))
        for _ in 0..<max(1, config.iterations) {
            enqueueBurst(sender: sender, count: 1, kind: .move(dx: 2, dy: 0),
                         admissionBox: admissionBox)
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    /// B/C: repeated short intense bursts of one coalescible event kind.
    ///
    /// Real burst semantics (review fix): ALL events of a burst are enqueued
    /// back-to-back WITHOUT waiting for remote delivery, so the production
    /// queue/coalescing/backpressure machinery actually engages. Accepted
    /// batch completions are tracked on a DispatchGroup and awaited after the
    /// burst; coalesced/shed events carry no acknowledgement by contract.
    static func runBursts(sender: InputSender, config: Config,
                          kind: PointerEvent.Kind, admissionBox: AdmissionBox) async {
        let bursts = max(1, config.iterations / max(1, config.burstCount))
        for _ in 0..<bursts {
            enqueueBurst(sender: sender, count: config.burstCount, kind: kind,
                         admissionBox: admissionBox)
            try? await Task.sleep(nanoseconds: UInt64(config.idleMs) * 1_000_000)
        }
    }

    /// F (review round 2): REAL queue saturation. Adjacent same-kind events
    /// tail-coalesce into one batch, so a single-kind dump compresses to
    /// in-flight + tail and never fills the 64-slot queue (observed:
    /// 3,200 events -> 48 requests, 0 shed). Alternating scroll/move kinds
    /// are both sheddable additive samples but cannot merge with each other,
    /// so each enqueue occupies a queue slot until capacity is exhausted —
    /// exercising genuine `shedLocally` backpressure without touching button
    /// safety.
    static func runQueuePressure(sender: InputSender, config: Config,
                                 admissionBox: AdmissionBox) async {
        let cycles = max(1, config.iterations / max(1, config.burstCount))
        for _ in 0..<cycles {
            saturationCycle(sender: sender, count: max(config.burstCount, 128),
                            admissionBox: admissionBox)
            try? await Task.sleep(nanoseconds: UInt64(config.idleMs) * 1_000_000)
        }
    }

    /// Synchronous single saturation cycle (DispatchGroup.wait must not run
    /// in an async context).
    static func saturationCycle(sender: InputSender, count: Int,
                                admissionBox: AdmissionBox) {
        let group = DispatchGroup()
        for i in 0..<count {
            let kind: PointerEvent.Kind = i % 2 == 0
                ? .scroll(horizontal: 0, vertical: 1)
                : .move(dx: 2, dy: 0)
            group.enter()
            let outcome = sender.enqueuePointer(PointerEvent(kind)) { result in
                admissionBox.record(result)
                group.leave()
            }
            admissionBox.record(outcome)
            if outcome != .acceptedAsNewBatch {
                group.leave() // no acknowledgement obligation
            }
        }
        _ = group.wait(timeout: .now() + .seconds(30))
    }

    /// Enqueues `count` events back-to-back with no waiting between them,
    /// then waits (bounded) for all accepted batches to be acknowledged.
    static func enqueueBurst(sender: InputSender, count: Int,
                             kind: PointerEvent.Kind, admissionBox: AdmissionBox) {
        let group = DispatchGroup()
        for _ in 0..<count {
            // Enter BEFORE enqueueing so the group can never reach zero
            // between acceptance and completion delivery.
            group.enter()
            let outcome = sender.enqueuePointer(PointerEvent(kind)) { result in
                admissionBox.record(result)
                group.leave()
            }
            admissionBox.record(outcome)
            switch outcome {
            case .acceptedAsNewBatch:
                break // completion owns the ticket; leave() fires on ack
            case .coalescedIntoExistingBatch, .shedLocally, .safetyRejected:
                // No acknowledgement obligation by contract — release now.
                group.leave()
            }
        }
        // Bound the wait so a stalled transport cannot hang the harness;
        // 5 s per queued batch is far above any observed latency.
        _ = group.wait(timeout: .now() + .seconds(5 * max(1, count)))
    }

    /// D: interleaved movement + scroll to exercise tail batching transitions.
    static func runMixed(sender: InputSender, config: Config, admissionBox: AdmissionBox) async {
        let interval = UInt64(1_000_000_000 / max(1, config.rateHz))
        for i in 0..<max(1, config.iterations) {
            let kind: PointerEvent.Kind = i % 3 == 0
                ? .scroll(horizontal: 0, vertical: 2)
                : .move(dx: 3, dy: i % 2 == 0 ? 2 : -2)
            enqueueBurst(sender: sender, count: 1, kind: kind,
                         admissionBox: admissionBox)
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    /// E: burst -> idle -> burst cycles for idle-dependent transport behavior.
    static func runBurstIdleCycles(sender: InputSender, config: Config, admissionBox: AdmissionBox) async {
        let cycles = max(1, config.iterations / max(1, config.burstCount * 2))
        for _ in 0..<cycles {
            enqueueBurst(sender: sender, count: config.burstCount,
                         kind: .scroll(horizontal: 0, vertical: 3), admissionBox: admissionBox)
            try? await Task.sleep(nanoseconds: UInt64(config.idleMs) * 1_000_000)
            enqueueBurst(sender: sender, count: config.burstCount,
                         kind: .move(dx: -4, dy: 0), admissionBox: admissionBox)
            try? await Task.sleep(nanoseconds: UInt64(config.idleMs) * 1_000_000)
        }
    }

    /// Thread-safe admission outcome accumulator (work order section 8:
    /// queue-pressure outcomes must be observable separately from transport
    /// delivery outcomes).
    final class AdmissionBox: @unchecked Sendable {
        private let lock = NSLock()
        var accepted = 0
        var coalesced = 0
        var shed = 0
        var rejected = 0
        // Product-facing delivery results (P0-3): the harness must apply the
        // SAME fail-safe semantics as ControlHandoffController — a partial
        // movement or failure is a product failure, not a silent pass.
        var deliveredMovement = 0
        var partiallyDeliveredMovement = 0
        var delivered = 0
        var cancelled = 0
        var failed = 0

        func record(_ result: PointerDeliveryResult) {
            lock.withLock {
                switch result {
                case .deliveredMovement, .partiallyDeliveredMovement:
                    if case .deliveredMovement = result { deliveredMovement += 1 }
                    else { partiallyDeliveredMovement += 1 }
                case .delivered: delivered += 1
                case .cancelled: cancelled += 1
                case .failed: failed += 1
                }
            }
        }

        func record(_ outcome: PointerAdmissionOutcome) {
            lock.withLock {
                switch outcome {
                case .acceptedAsNewBatch: accepted += 1
                case .coalescedIntoExistingBatch: coalesced += 1
                case .shedLocally: shed += 1
                case .safetyRejected: rejected += 1
                }
            }
        }

        var description: String {
            lock.withLock { "accepted=\(accepted) coalesced=\(coalesced) shed=\(shed) safety_rejected=\(rejected)" }
        }

        func snapshot() -> (Int, Int, Int, Int) {
            lock.withLock { (accepted, coalesced, shed, rejected) }
        }

        func deliverySnapshot() -> (deliveredMovement: Int, partial: Int,
                                    delivered: Int, cancelled: Int, failed: Int) {
            lock.withLock { (deliveredMovement, partiallyDeliveredMovement,
                             delivered, cancelled, failed) }
        }
    }

    // MARK: - Plumbing

    /// Bounded post-timeout grace window (seconds) for late responses.
    static let graceWindowSeconds: TimeInterval = 5

    struct Config {
        var profile = "baseline"
        var serial: String?
        var iterations = 500
        var burstCount = 20          // events per burst (burst profiles)
        var idleMs = 500             // burst -> idle gap
        var rateHz = 60              // baseline inter-request pacing
        var outDir: String?
    }

    static func classifySerial(_ serial: String) -> String {
        if serial.contains("_adb-tls-connect._tcp") { return "wireless-mdns-tls" }
        if serial.contains(":") && serial.contains(".") { return "wireless-hostport" }
        return "usb-or-other"
    }

    static func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    static func tempLogURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cxi-stress-diag.log")
    }

    static func parseArgs() -> Config {
        var config = Config()
        var arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            index += 1
            guard index < arguments.count || arg == "--help" else { break }
            switch arg {
            case "--profile": config.profile = arguments[index]; index += 1
            case "--serial": config.serial = arguments[index]; index += 1
            case "--iterations": config.iterations = Int(arguments[index]) ?? config.iterations; index += 1
            case "--burst-count": config.burstCount = Int(arguments[index]) ?? config.burstCount; index += 1
            case "--idle-ms": config.idleMs = Int(arguments[index]) ?? config.idleMs; index += 1
            case "--rate-hz": config.rateHz = Int(arguments[index]) ?? config.rateHz; index += 1
            case "--out": config.outDir = arguments[index]; index += 1
            default: break
            }
        }
        return config
    }

    /// Exit semantics (work order section 17):
    /// 0 = automated pass; 1 = product assertion failure (timeout or genuine
    /// delivery failure observed); environment/precondition errors exit
    /// earlier with 3/2.
    static func exitCode(record: OutcomeCounter.Record,
                         admissionBox: AdmissionBox) -> Int {
        let transportFailures = record.timeouts + record.streamClosed + record.writeFailed
            + record.unexpectedResponse + record.malformedResponse
            + record.helperReportedFailure + record.otherFailure
        // P0-3: apply PRODUCT semantics. ControlHandoffController treats a
        // partial movement or a failed batch as remoteUnavailable — the
        // harness must not pass where the app would force-return.
        let productFailSafe = admissionBox.partiallyDeliveredMovement
            + admissionBox.failed
        return (transportFailures + productFailSafe) > 0 ? 1 : 0
    }

    static func encode(_ record: OutcomeCounter.Record) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(record)
    }
}
