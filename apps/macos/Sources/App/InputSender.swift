import Foundation
import Protocol
import InputCapture
import Diagnostics

enum PointerDeliveryResult: Sendable, Equatable {
    // Movement results carry both the requested batch delta (what was asked
    // of the helper, after coalescing) and the accepted delta. The state
    // machine needs the requested intent to credit return-direction movement
    // that a display-bound clamp fully absorbed (issue #45).
    case deliveredMovement(requestedDx: Int32, requestedDy: Int32,
                           deliveredDx: Int32, deliveredDy: Int32)
    case partiallyDeliveredMovement(requestedDx: Int32, requestedDy: Int32,
                                    deliveredDx: Int32, deliveredDy: Int32)
    case delivered
    case cancelled
    case failed
    /// Scroll results carry the requested batch deltas so handoff accounting
    /// and diagnostics can track coalesced scroll work without logging user
    /// input contents (issue #62).
    case deliveredScroll(requestedHorizontal: Float, requestedVertical: Float)
}

/// Sends semantic CXI v1 pointer and keyboard events. HID descriptors,
/// reports, button bitmasks, and backend choice are helper-owned details.
/// Adjacent movement events and adjacent scroll events are coalesced into a
/// bounded queue (issue #62); button transitions remain ordered boundaries
/// and are never merged or dropped silently. Keyboard delivery has its own
/// queue so a stalled pointer request cannot starve key-up or modifier
/// cleanup.
///
/// Bounded-queue overflow policy (issue #62):
/// - Movement/scroll rejected because the queue is saturated are *local
///   backpressure*: they are reported as `.cancelled` so the handoff
///   controller keeps control on Android instead of misclassifying ordinary
///   high-frequency scroll production as remote failure. The watchdog still
///   guards against genuine stalls.
/// - A button transition that cannot be enqueued losslessly remains a safety
///   failure (`.failed`) and keeps the fail-safe force-return path.
final class InputSender: @unchecked Sendable {
    private let session: SessionReference
    private let pointerQueue = DispatchQueue(label: "crossinput.pointer-delivery",
                                              qos: .userInteractive)
    private let keyboardQueue = DispatchQueue(label: "crossinput.keyboard-delivery",
                                               qos: .userInteractive)
    private let stateLock = NSLock()
    private let maxPendingPointerItems: Int
    private let pointerRequestTimeout: TimeInterval
    private var pendingPointers: [PendingPointer] = []
    private var pointerWorkerScheduled = false
    private var pointerGeneration: UInt64 = 0
    /// Aggregate metadata only — never scroll values or input contents.
    private var coalescedScrollCount = 0
    private var saturatedEnqueueCount = 0
    /// Pointer buttons accepted by the helper for one session generation.
    /// Access is confined to pointerQueue so takeover cleanup can wait for an
    /// in-flight delivery and release exactly the state that reached Android.
    private var heldButtons: Set<UInt32> = []
    private var heldButtonsSessionGeneration: UInt64?

    /// Fans the single batch result out to every completion contributed by
    /// coalesced events, so each enqueue is acknowledged exactly once (issue
    /// #62). Immutable after creation; appends copy-on-write under stateLock.
    private final class CompletionList: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [@Sendable (PointerDeliveryResult) -> Void] = []

        init(_ completion: @escaping @Sendable (PointerDeliveryResult) -> Void) {
            items.append(completion)
        }

        func appending(_ completion: @escaping @Sendable (PointerDeliveryResult) -> Void) -> CompletionList {
            let copy = CompletionList { _ in }
            lock.withLock { copy.items = items }
            copy.appendUnderLock(completion)
            return copy
        }

        private func appendUnderLock(_ completion: @escaping @Sendable (PointerDeliveryResult) -> Void) {
            lock.withLock { items.append(completion) }
        }

        func deliver(_ result: PointerDeliveryResult) {
            lock.withLock { let snapshot = items; return snapshot }.forEach { $0(result) }
        }
    }

    private struct PendingPointer {
        let event: PointerEvent
        let completions: CompletionList
        let pointerGeneration: UInt64
        let sessionGeneration: UInt64
    }

    /// Which event kinds may merge with an adjacent pending item of the same
    /// kind, and what the accumulated kind is. Button transitions never merge:
    /// dropping or reordering a down/up pair can leave remote button state
    /// inconsistent (issue #62).
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

    /// Enqueues one semantic delivery batch. Adjacent movement events and
    /// adjacent scroll events for the same session may be coalesced into one
    /// pending item whose accumulated delta is semantically equivalent to the
    /// original sequence (issue #62). The completion is for that delivered
    /// batch, not a per-original-event acknowledgement. The aggregate result
    /// is therefore credited to handoff accounting exactly once.
    func enqueuePointer(_ event: PointerEvent,
                        completion: @escaping @Sendable (PointerDeliveryResult) -> Void) {
        let sessionSnapshot = session.snapshot()
        var dropped: [(@Sendable (PointerDeliveryResult) -> Void, PointerDeliveryResult)] = []
        var shouldSchedule = false
        stateLock.withLock {
            if let last = pendingPointers.last,
               last.sessionGeneration == sessionSnapshot.generation,
               let mergedKind = Self.coalesced(last.event.kind, event.kind) {
                // Same-kind accumulation preserves ordering: merging only ever
                // rewrites the tail item of the same kind, so move/scroll
                // boundaries in front of it stay untouched.
                let merged = PointerEvent(mergedKind)
                pendingPointers[pendingPointers.count - 1] = PendingPointer(
                    event: merged,
                    completions: last.completions.appending(completion),
                    pointerGeneration: last.pointerGeneration,
                    sessionGeneration: last.sessionGeneration)
                if case .scroll = event.kind {
                    coalescedScrollCount += 1
                    if coalescedScrollCount % 200 == 0 {
                        // Rate-limited aggregate metadata only.
                        Diagnostics.log("pointer scroll coalesced count=\(coalescedScrollCount)")
                    }
                }
            } else if pendingPointers.count < maxPendingPointerItems {
                pendingPointers.append(PendingPointer(event: event,
                                                       completions: CompletionList(completion),
                                                       pointerGeneration: pointerGeneration,
                                                       sessionGeneration: sessionSnapshot.generation))
            } else if event.kind.isCoalescible {
                // Local queue saturation for movement/scroll is backpressure,
                // not remote failure (issue #62): report cancelled so control
                // stays on Android. The watchdog still guards genuine stalls.
                saturatedEnqueueCount += 1
                if saturatedEnqueueCount % 100 == 0 {
                    // Rate-limited aggregate metadata only.
                    Diagnostics.log("pointer enqueue saturation count=\(saturatedEnqueueCount)")
                }
                dropped.append((completion, .cancelled))
            } else {
                // Losing an ordered button boundary is a safety failure, not
                // a harmless coalescing decision; it keeps the fail-safe path.
                dropped.append((completion, .failed))
            }
            if !pointerWorkerScheduled, !pendingPointers.isEmpty {
                pointerWorkerScheduled = true
                shouldSchedule = true
            }
        }
        dropped.forEach { $0.0($0.1) }
        if shouldSchedule {
            pointerQueue.async { [weak self] in self?.drainPointerQueue() }
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
        let dropped: [PendingPointer] = stateLock.withLock {
            pointerGeneration &+= 1
            let value = pendingPointers
            pendingPointers.removeAll(keepingCapacity: true)
            return value
        }
        dropped.forEach { $0.completions.deliver(.cancelled) }
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
            let item: PendingPointer? = stateLock.withLock {
                guard !pendingPointers.isEmpty else {
                    pointerWorkerScheduled = false
                    return nil
                }
                return pendingPointers.removeFirst()
            }
            guard let item else { return }
            let result = deliverPointer(item)
            let stillCurrent = stateLock.withLock { pointerGeneration == item.pointerGeneration }
            item.completions.deliver(stillCurrent ? result : .cancelled)
        }
    }

    private func deliverPointer(_ item: PendingPointer) -> PointerDeliveryResult {
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
                if case let .scroll(h, v) = event.kind {
                    return .deliveredScroll(requestedHorizontal: h, requestedVertical: v)
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

    private func saturatingAdd(_ lhs: Int32, _ rhs: Int32) -> Int32 {
        Int32(clamping: Int64(lhs) + Int64(rhs))
    }

    fileprivate static func saturatingAdd(_ lhs: Int32, _ rhs: Int32) -> Int32 {
        Int32(clamping: Int64(lhs) + Int64(rhs))
    }
}

private extension PointerEvent.Kind {
    /// Kinds whose semantic payload is additive, so losing one instance to
    /// local backpressure is recoverable by later events of the same kind.
    /// Button transitions are state-changing and never lossy.
    var isCoalescible: Bool {
        switch self {
        case .move, .scroll: return true
        case .button: return false
        }
    }
}
