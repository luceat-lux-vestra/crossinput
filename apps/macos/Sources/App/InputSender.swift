import Foundation
import Protocol
import InputCapture

enum PointerDeliveryResult: Sendable, Equatable {
    case deliveredMovement(dx: Int32, dy: Int32)
    case partiallyDeliveredMovement(dx: Int32, dy: Int32)
    case delivered
    case cancelled
    case failed
}

/// Sends semantic CXI v1 pointer and keyboard events. HID descriptors,
/// reports, button bitmasks, and backend choice are helper-owned details.
/// Pointer movement is coalesced into a bounded queue, while button/scroll
/// boundaries remain ordered. Keyboard delivery has its own queue so a stalled
/// pointer request cannot starve key-up or modifier cleanup.
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

    private struct PendingPointer {
        let event: PointerEvent
        let completion: @Sendable (PointerDeliveryResult) -> Void
        let pointerGeneration: UInt64
        let sessionGeneration: UInt64
    }

    init(session: SessionReference,
         maxPendingPointerItems: Int = 64,
         pointerRequestTimeout: TimeInterval = 0.75) {
        self.session = session
        self.maxPendingPointerItems = max(1, maxPendingPointerItems)
        self.pointerRequestTimeout = max(0.05, pointerRequestTimeout)
    }

    func enqueuePointer(_ event: PointerEvent,
                        completion: @escaping @Sendable (PointerDeliveryResult) -> Void) {
        let sessionSnapshot = session.snapshot()
        var dropped: [(@Sendable (PointerDeliveryResult) -> Void, PointerDeliveryResult)] = []
        var shouldSchedule = false
        stateLock.withLock {
            if let last = pendingPointers.last,
               last.sessionGeneration == sessionSnapshot.generation,
               case let .move(lastDX, lastDY) = last.event.kind,
               case let .move(dx, dy) = event.kind {
                let merged = PointerEvent(.move(dx: saturatingAdd(lastDX, dx),
                                                  dy: saturatingAdd(lastDY, dy)))
                pendingPointers[pendingPointers.count - 1] = PendingPointer(
                    event: merged,
                    completion: last.completion,
                    pointerGeneration: last.pointerGeneration,
                    sessionGeneration: last.sessionGeneration)
            } else if pendingPointers.count < maxPendingPointerItems {
                pendingPointers.append(PendingPointer(event: event,
                                                       completion: completion,
                                                       pointerGeneration: pointerGeneration,
                                                       sessionGeneration: sessionSnapshot.generation))
            } else {
                // A move cannot displace an ordered button/scroll boundary.
                // Rejecting it is safer than growing an unbounded backlog.
                let result: PointerDeliveryResult
                if case .move = event.kind {
                    result = .cancelled
                } else {
                    // Losing a button or scroll boundary is a safety failure,
                    // not a harmless coalescing decision.
                    result = .failed
                }
                dropped.append((completion, result))
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
        dropped.forEach { $0.completion(.cancelled) }
    }

    /// Waits until capture events queued before this call have reached the
    /// helper. Used before transport teardown to preserve key/button cleanup.
    func waitForDrain() {
        pointerQueue.sync {}
        keyboardQueue.sync {}
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
            item.completion(stillCurrent ? result : .cancelled)
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
                return isMovement
                    ? .deliveredMovement(dx: result.deliveredDx, dy: result.deliveredDy)
                    : .delivered
            case .partiallyDelivered:
                return isMovement
                    ? .partiallyDeliveredMovement(dx: result.deliveredDx, dy: result.deliveredDy)
                    : .failed
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
}
