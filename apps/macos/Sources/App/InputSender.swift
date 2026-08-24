import Foundation
import Protocol
import InputCapture
import Diagnostics

/// Outcome of one admitted pointer batch that entered the delivery lifecycle
/// (ADR-0011). This type never reports queue-admission outcomes: an additive
/// event shed by a saturated local queue was never admitted, so it has no
/// delivery result.
enum PointerDeliveryResult: Sendable, Equatable {
    // Movement results carry both the requested batch delta (what was asked
    // of the helper, after coalescing) and the accepted delta. The state
    // machine needs the requested intent to credit return-direction movement
    // that a display-bound clamp fully absorbed (issue #45).
    case deliveredMovement(requestedDx: Int32, requestedDy: Int32,
                           deliveredDx: Int32, deliveredDy: Int32)
    case partiallyDeliveredMovement(requestedDx: Int32, requestedDy: Int32,
                                    deliveredDx: Int32, deliveredDy: Int32)
    /// A non-movement semantic batch was confirmed by the helper (scroll or
    /// button). Scroll deltas stay inside `InputSender`; they have no consumer
    /// past the watchdog/handoff boundary.
    case delivered
    /// Admitted work invalidated by lifecycle/generation cancellation (local
    /// return, session replacement, stale in-flight response).
    case cancelled
    /// Genuine delivery or safety failure requiring the fail-safe force-return.
    case failed
}

/// Sends semantic CXI v1 pointer and keyboard events. HID descriptors,
/// reports, button bitmasks, and backend choice are helper-owned details.
///
/// Architecture (ADR-0011): captured events pass through O(1) queue admission
/// into bounded `PendingPointerBatch` transport batches. Adjacent additive
/// events (move+move, scroll+scroll) merge into the tail batch, so one batch
/// yields one remote request, one delivery result, one completion, and at
/// most one handoff-accounting operation. Button transitions are state
/// changes, not samples: they never merge and are never dropped silently.
///
/// Two lifecycle domains are kept separate:
/// - *Admission* decides merge / append / local shed / safety rejection.
///   Local queue saturation of an additive event sheds that event with no
///   remote request, no delivery result, and no handoff accounting — local
///   backpressure is not remote failure, so it can never surface as
///   `remoteUnavailable`.
/// - *Delivery* produces a `PointerDeliveryResult` per admitted batch.
///   Genuine failures (request throw, timeout, malformed/unexpected response,
///   helper-reported failure, partial movement, unretainable button) remain
///   fail-safe.
final class InputSender: @unchecked Sendable {
    private let session: SessionReference
    private let pointerQueue = DispatchQueue(label: "crossinput.pointer-delivery",
                                              qos: .userInteractive)
    private let keyboardQueue = DispatchQueue(label: "crossinput.keyboard-delivery",
                                               qos: .userInteractive)
    private let stateLock = NSLock()
    private let maxPendingPointerItems: Int
    private let pointerRequestTimeout: TimeInterval
    private var pendingPointers: [PendingPointerBatch] = []
    private var pointerWorkerScheduled = false
    private var pointerGeneration: UInt64 = 0
    /// Aggregate metadata only — never input values or payloads. Mutated
    /// under stateLock; flushed to the log only after the lock is released.
    private var coalescedScrollBatchCount = 0
    private var locallyShedEventCount = 0
    /// Pointer buttons accepted by the helper for one session generation.
    /// Access is confined to pointerQueue so takeover cleanup can wait for an
    /// in-flight delivery and release exactly the state that reached Android.
    private var heldButtons: Set<UInt32> = []
    private var heldButtonsSessionGeneration: UInt64?

    /// One transport batch: possibly many merged raw capture events, but
    /// exactly one delivery acknowledgement obligation.
    private struct PendingPointerBatch {
        var event: PointerEvent
        let completion: @Sendable (PointerDeliveryResult) -> Void
        let pointerGeneration: UInt64
        let sessionGeneration: UInt64
    }

    /// Returns the accumulated kind when `newer` may merge into an adjacent
    /// `older` batch tail, else nil. Buttons never merge: dropping or
    /// reordering a down/up pair can leave remote button state inconsistent.
    private static func coalesced(_ older: PointerEvent.Kind,
                                  _ newer: PointerEvent.Kind) -> PointerEvent.Kind? {
        switch (older, newer) {
        case let (.move(dx, dy), .move(dx2, dy2)):
            return .move(dx: saturatingAdd(dx, dx2), dy: saturatingAdd(dy, dy2))
        case let (.scroll(h, v), .scroll(h2, v2)):
            return .scroll(horizontal: h + h2, vertical: v + v2)
        default:
            return nil
        }
    }

    init(session: SessionReference,
         maxPendingPointerItems: Int = 64,
         pointerRequestTimeout: TimeInterval = 0.75) {
        self.session = session
        self.maxPendingPointerItems = max(1, maxPendingPointerItems)
        self.pointerRequestTimeout = max(0.05, pointerRequestTimeout)
    }

    /// True while a live transport exists for the current session. Edge events
    /// must not arm handoff without it: entering remoteActive against a dead
    /// session traps local input until the watchdog fires (issue #50).
    var hasLiveConnection: Bool {
        session.snapshot().connection != nil
    }

    /// Admits one captured event into the bounded pointer-batch queue.
    ///
    /// Admission policy (O(1), tail-only):
    /// - compatible additive tail → merge into that batch (no new completion);
    /// - space available → append a new batch;
    /// - saturated queue + additive event (move/scroll) → locally shed. The
    ///   event was never admitted, so its completion is never invoked and no
    ///   delivery result exists;
    /// - saturated queue + button → safety failure: the completion receives
    ///   `.failed` and keeps the fail-safe force-return path.
    ///
    /// The completion is therefore invoked at most once per call, and only
    /// when the event joined a delivery batch. Callers must not rely on a
    /// callback for admission rejection.
    func enqueuePointer(_ event: PointerEvent,
                        completion: @escaping @Sendable (PointerDeliveryResult) -> Void) {
        let sessionSnapshot = session.snapshot()
        var safetyFailed = false
        var shouldSchedule = false
        var scrollMergedIntoTail = false
        var shedLocally = false
        var coalescedScrollTotal = 0
        var shedEventTotal = 0
        stateLock.withLock {
            if let last = pendingPointers.last,
               last.sessionGeneration == sessionSnapshot.generation,
               let mergedKind = Self.coalesced(last.event.kind, event.kind) {
                // Same-kind accumulation preserves ordering: merging only ever
                // rewrites the tail batch's payload. Its existing completion
                // stays the single acknowledgement for the whole batch.
                pendingPointers[pendingPointers.count - 1].event = PointerEvent(mergedKind)
                if case .scroll = event.kind { scrollMergedIntoTail = true }
            } else if pendingPointers.count < maxPendingPointerItems {
                pendingPointers.append(PendingPointerBatch(
                    event: event,
                    completion: completion,
                    pointerGeneration: pointerGeneration,
                    sessionGeneration: sessionSnapshot.generation))
            } else if Self.isSheddable(event.kind) {
                // Additive sample lost to local backpressure: later events of
                // the same kind recover the semantic delta, so shedding is
                // safe. No transport request, no delivery result, no handoff
                // accounting; the watchdog remains the stall guard.
                shedLocally = true
            } else {
                // Losing an ordered button boundary cannot be recovered
                // losslessly: safety failure keeps the fail-safe path.
                safetyFailed = true
            }
            if scrollMergedIntoTail {
                coalescedScrollBatchCount += 1
                coalescedScrollTotal = coalescedScrollBatchCount
            }
            if shedLocally {
                locallyShedEventCount += 1
                shedEventTotal = locallyShedEventCount
            }
            if !pointerWorkerScheduled, !pendingPointers.isEmpty {
                pointerWorkerScheduled = true
                shouldSchedule = true
            }
        }
        // Diagnostics run strictly outside stateLock and report aggregate
        // counts only (AGENTS.md rule 4).
        if scrollMergedIntoTail, coalescedScrollTotal % 200 == 0 {
            Diagnostics.log("pointer scroll batches coalesced count=\(coalescedScrollTotal)")
        }
        if shedLocally, shedEventTotal % 100 == 0 {
            Diagnostics.log("pointer queue saturation shed count=\(shedEventTotal)")
        }
        if safetyFailed {
            completion(.failed)
        }
        if shouldSchedule {
            pointerQueue.async { [weak self] in self?.drainPointerQueue() }
        }
    }

    /// Only move/scroll may be shed under pressure: their payload is additive.
    private static func isSheddable(_ kind: PointerEvent.Kind) -> Bool {
        switch kind {
        case .move, .scroll: return true
        case .button: return false
        }
    }

    func enqueueKey(_ event: CapturedKeyEvent) {
        let sessionSnapshot = session.snapshot()
        keyboardQueue.async { [weak self] in
            self?.deliverKey(event, snapshot: sessionSnapshot)
        }
    }

    /// Drops queued and in-flight semantic pointer work. A result from an
    /// invalidated in-flight request is reported as cancelled, never credited
    /// to the handoff position.
    func cancelPendingPointerEvents() {
        let dropped: [PendingPointerBatch] = stateLock.withLock {
            pointerGeneration &+= 1
            let value = pendingPointers
            pendingPointers.removeAll(keepingCapacity: true)
            return value
        }
        dropped.forEach { $0.completion(.cancelled) }
    }

    /// Waits until capture events queued before this call have reached the
    /// helper. Used before transport teardown to preserve key/button cleanup.
    func waitForDrain() {
        keyboardQueue.sync {}
        pointerQueue.sync {}
    }

    /// Schedules cleanup after key-up events already queued by InputCapture.
    /// Local pointer recovery and the triggering external-control event never
    /// wait for a remote request or transport write.
    func resetCapturedInputState() {
        cancelPendingPointerEvents()
        keyboardQueue.async { [weak self] in
            guard let self else { return }
            pointerQueue.async { [weak self] in
                self?.releaseHeldButtonsAfterExternalTakeover()
            }
        }
    }

    private func releaseHeldButtonsAfterExternalTakeover() {
        let snapshot = session.snapshot()
        let buttons = heldButtons.sorted()
        let buttonGeneration = heldButtonsSessionGeneration
        heldButtons.removeAll()
        heldButtonsSessionGeneration = nil

        guard buttonGeneration == snapshot.generation,
              let connection = snapshot.connection,
              !buttons.isEmpty else { return }

        for button in buttons {
            // Cleanup is best effort. Zero marks an uncorrelated response, so
            // it cannot satisfy an unrelated in-flight request.
            try? connection.send(CxiFrame(
                type: .pointerButton,
                requestId: 0,
                payload: Messages.pointerButton(button: button, down: false)))
        }
        Diagnostics.log("external-control input state reset buttons=\(buttons.count)")
    }

    private func drainPointerQueue() {
        while true {
            let item: PendingPointerBatch? = stateLock.withLock {
                guard !pendingPointers.isEmpty else {
                    pointerWorkerScheduled = false
                    return nil
                }
                return pendingPointers.removeFirst()
            }
            guard let item else { return }
            let result = deliverPointer(item)
            let stillCurrent = stateLock.withLock { pointerGeneration == item.pointerGeneration }
            item.completion(stillCurrent ? result : .cancelled)
        }
    }

    private func deliverPointer(_ item: PendingPointerBatch) -> PointerDeliveryResult {
        let snapshot = session.snapshot()
        guard snapshot.generation == item.sessionGeneration,
              let connection = snapshot.connection else { return .cancelled }
        let event = item.event
        do {
            let type: MessageType
            let payload: Data
            let isMovement: Bool
            switch event.kind {
            case let .move(dx, dy):
                type = .pointerMoveRel
                payload = Messages.pointerMoveRel(dx: dx, dy: dy)
                isMovement = true
            case let .button(button, down):
                type = .pointerButton
                payload = Messages.pointerButton(button: button, down: down)
                isMovement = false
            case let .scroll(horizontal, vertical):
                type = .pointerScroll
                payload = Messages.pointerScroll(horizontal: horizontal, vertical: vertical)
                isMovement = false
            }

            let response = try connection.requestBlocking(type,
                                                           payload: payload,
                                                           timeout: pointerRequestTimeout)
            // The response may belong to a connection that was replaced
            // while the request was in flight. Never credit that response to
            // the current handoff position.
            guard session.snapshot().generation == item.sessionGeneration else {
                return .cancelled
            }
            guard response.type == .pointerResult else { return .failed }
            let result = try Messages.decodePointerResult(response.payload)
            switch result.status {
            case .delivered:
                if case let .button(button, down) = event.kind {
                    if heldButtonsSessionGeneration != item.sessionGeneration {
                        heldButtons.removeAll()
                        heldButtonsSessionGeneration = item.sessionGeneration
                    }
                    if down {
                        heldButtons.insert(button)
                    } else {
                        heldButtons.remove(button)
                    }
                }
                guard isMovement,
                      case let .move(requestedDx, requestedDy) = event.kind else { return .delivered }
                return .deliveredMovement(requestedDx: requestedDx,
                                          requestedDy: requestedDy,
                                          deliveredDx: result.deliveredDx,
                                          deliveredDy: result.deliveredDy)
            case .partiallyDelivered:
                guard isMovement,
                      case let .move(requestedDx, requestedDy) = event.kind else { return .failed }
                return .partiallyDeliveredMovement(requestedDx: requestedDx,
                                                   requestedDy: requestedDy,
                                                   deliveredDx: result.deliveredDx,
                                                   deliveredDy: result.deliveredDy)
            case .failed:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    private func deliverKey(_ event: CapturedKeyEvent, snapshot: SessionSnapshot) {
        guard snapshot.generation == session.snapshot().generation,
              let connection = snapshot.connection else { return }
        do {
            try connection.send(CxiFrame(type: .keyEvent,
                                          requestId: 1,
                                          payload: Messages.keyEvent(keyCode: UInt16(event.keyCode),
                                                                     metaState: event.metaState,
                                                                     action: event.action,
                                                                     repeatCount: event.repeatCount)))
        } catch {
            // Key delivery failures are converted into the same control
            // fail-safe by the session/helper termination path. Do not log
            // key codes or payload contents here.
        }
    }

    private static func saturatingAdd(_ lhs: Int32, _ rhs: Int32) -> Int32 {
        Int32(clamping: Int64(lhs) + Int64(rhs))
    }
}
