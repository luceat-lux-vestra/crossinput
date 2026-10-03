import Dispatch
import InputDomain

/// Converts the physically proven built-in-trackpad report surface into
/// platform-neutral pointer semantics.
///
/// CoreHID seizure bypasses macOS' higher-level trackpad gesture processing, so
/// this translator must preserve the user-facing distinction between a tap and
/// deliberate movement/scroll without depending on unproven vendor offsets.
///
/// Proven inputs only:
/// - standard Button1;
/// - relative X/Y;
/// - contact count at full-report byte 30.
///
/// A short, low-travel one-contact sequence becomes a primary tap. A short,
/// low-travel sequence that reaches two contacts becomes a secondary tap.
/// Deliberate movement crosses a small touch-slop first; pending movement is
/// then emitted in order so the threshold does not permanently lose distance.
struct AppleTrackpadSemanticTranslator: Sendable {
    enum TranslationError: Error, Equatable, Sendable {
        case unsupportedContactCount(Int)
        case unsupportedButtonBits
        case invalidState
    }

    private struct ContactGesture: Sendable {
        let startedAtNanos: UInt64
        var maxContactCount: Int
        var travel: Int32 = 0
        var pending: [SemanticPointerEvent] = []
        var movementCommitted = false
        var tapEligible = true
    }

    private var activeButton: UInt32?
    private var gesture: ContactGesture?
    private var suppressTapUntilLift = false

    private let tapMaxDurationNanos: UInt64
    private let tapMovementThreshold: Int32

    init(
        tapMaxDurationNanos: UInt64 = 250_000_000,
        tapMovementThreshold: Int32 = 12
    ) {
        self.tapMaxDurationNanos = tapMaxDurationNanos
        self.tapMovementThreshold = tapMovementThreshold
    }

    mutating func translate(
        _ report: AppleTrackpadRawReportDecoder.Report
    ) throws -> [SemanticPointerEvent] {
        try translate(
            report,
            nowNanos: DispatchTime.now().uptimeNanoseconds
        )
    }

    mutating func translate(
        _ report: AppleTrackpadRawReportDecoder.Report,
        nowNanos: UInt64
    ) throws -> [SemanticPointerEvent] {
        guard (0...2).contains(report.contactCount) else {
            throw TranslationError.unsupportedContactCount(report.contactCount)
        }
        guard !report.buttons.secondary, !report.buttons.other else {
            throw TranslationError.unsupportedButtonBits
        }

        let clicked = report.buttons.primary
        let wasClicked = activeButton != nil

        if report.contactCount == 0 {
            guard !clicked else {
                throw TranslationError.invalidState
            }

            if let button = activeButton {
                activeButton = nil
                gesture = nil
                suppressTapUntilLift = false
                return [
                    SemanticPointerEvent(
                        .button(button: button, down: false)
                    )
                ]
            }

            if suppressTapUntilLift {
                suppressTapUntilLift = false
                gesture = nil
                return []
            }

            defer { gesture = nil }
            guard let gesture,
                  gesture.tapEligible,
                  !gesture.movementCommitted,
                  nowNanos >= gesture.startedAtNanos,
                  nowNanos - gesture.startedAtNanos <= tapMaxDurationNanos else {
                return []
            }

            let button: UInt32
            switch gesture.maxContactCount {
            case 1: button = 0
            case 2: button = 1
            default:
                throw TranslationError.invalidState
            }
            return [
                SemanticPointerEvent(.button(button: button, down: true)),
                SemanticPointerEvent(.button(button: button, down: false)),
            ]
        }

        if clicked && !wasClicked {
            let button: UInt32
            switch report.contactCount {
            case 1: button = 0
            case 2: button = 1
            default:
                throw TranslationError.unsupportedContactCount(
                    report.contactCount
                )
            }
            activeButton = button
            gesture = nil
            suppressTapUntilLift = true
            return [
                SemanticPointerEvent(.button(button: button, down: true))
            ]
        }

        if !clicked && wasClicked {
            guard let button = activeButton else {
                throw TranslationError.invalidState
            }
            activeButton = nil
            return [
                SemanticPointerEvent(.button(button: button, down: false))
            ]
        }

        if clicked, let button = activeButton {
            let expectedContactCount: Int
            switch button {
            case 0: expectedContactCount = 1
            case 1: expectedContactCount = 2
            default:
                throw TranslationError.invalidState
            }
            guard report.contactCount == expectedContactCount else {
                throw TranslationError.invalidState
            }
        }

        let dx = Int32(report.pointerX)
        let dy = Int32(report.pointerY)

        // Physical Button1 already owns click identity. Never allow the same
        // touch sequence to synthesize an additional tap on lift.
        if activeButton != nil || suppressTapUntilLift {
            if activeButton == 1, dx != 0 || dy != 0 {
                throw TranslationError.invalidState
            }
            guard dx != 0 || dy != 0 else { return [] }
            return try movementEvents(
                contactCount: report.contactCount,
                dx: dx,
                dy: dy
            )
        }

        if gesture == nil {
            gesture = ContactGesture(
                startedAtNanos: nowNanos,
                maxContactCount: report.contactCount
            )
        }

        guard var current = gesture else {
            throw TranslationError.invalidState
        }
        current.maxContactCount = max(
            current.maxContactCount,
            report.contactCount
        )

        if nowNanos < current.startedAtNanos ||
            nowNanos - current.startedAtNanos > tapMaxDurationNanos {
            current.tapEligible = false
        }

        if dx != 0 || dy != 0 {
            current.travel += abs(dx) + abs(dy)
            current.pending.append(
                contentsOf: try movementEvents(
                    contactCount: report.contactCount,
                    dx: dx,
                    dy: dy
                )
            )
            if current.travel > tapMovementThreshold {
                current.tapEligible = false
            }
        }

        if current.movementCommitted {
            let events = current.pending
            current.pending.removeAll(keepingCapacity: true)
            gesture = current
            return events
        }

        if !current.tapEligible {
            current.movementCommitted = true
            let events = current.pending
            current.pending.removeAll(keepingCapacity: true)
            gesture = current
            return events
        }

        gesture = current
        return []
    }

    private func movementEvents(
        contactCount: Int,
        dx: Int32,
        dy: Int32
    ) throws -> [SemanticPointerEvent] {
        guard dx != 0 || dy != 0 else { return [] }
        switch contactCount {
        case 1:
            return [
                SemanticPointerEvent(.move(dx: dx, dy: dy))
            ]
        case 2:
            return [
                SemanticPointerEvent(
                    .scroll(
                        horizontal: Float(dx),
                        vertical: Float(dy)
                    )
                )
            ]
        default:
            throw TranslationError.unsupportedContactCount(contactCount)
        }
    }

    mutating func reset() -> [SemanticPointerEvent] {
        gesture = nil
        suppressTapUntilLift = false
        guard let button = activeButton else { return [] }
        activeButton = nil
        return [
            SemanticPointerEvent(.button(button: button, down: false))
        ]
    }
}
