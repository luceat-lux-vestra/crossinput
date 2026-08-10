import Foundation
import Protocol
import InputCapture

enum PointerDeliveryResult: Sendable, Equatable {
    case deliveredMovement(dx: Int32, dy: Int32)
    case partiallyDeliveredMovement(dx: Int32, dy: Int32)
    case delivered
    case failed
}

/// Sends semantic CXI v1 pointer and keyboard events. HID descriptors,
/// reports, button bitmasks, and backend choice are helper-owned details.
/// Pointer events are serialized on one delivery queue and wait for the
/// helper's pointer-result response before reporting movement to handoff.
final class InputSender: @unchecked Sendable {
    private let session: SessionReference
    private let deliveryQueue = DispatchQueue(label: "crossinput.input-delivery",
                                               qos: .userInteractive)

    init(session: SessionReference) {
        self.session = session
    }

    func enqueuePointer(_ event: PointerEvent,
                        completion: @escaping @Sendable (PointerDeliveryResult) -> Void) {
        deliveryQueue.async { [weak self] in
            let result = self?.deliverPointer(event) ?? .failed
            completion(result)
        }
    }

    func enqueueKey(_ event: CapturedKeyEvent) {
        deliveryQueue.async { [weak self] in
            self?.deliverKey(event)
        }
    }

    /// Waits until capture events queued before this call have reached the
    /// helper. Used before transport teardown to preserve key/button cleanup.
    func waitForDrain() {
        deliveryQueue.sync {}
    }

    private func deliverPointer(_ event: PointerEvent) -> PointerDeliveryResult {
        guard let connection = session.current() else { return .failed }
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

            let response = try connection.requestBlocking(type, payload: payload)
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

    private func deliverKey(_ event: CapturedKeyEvent) {
        guard let connection = session.current() else { return }
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
}
