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
/// Movement and scroll are never delayed for tap classification: every proven
/// non-zero HID delta is emitted immediately, while duration/travel are tracked
/// independently to decide whether lift may also synthesize a tap.
struct AppleTrackpadSemanticTranslator: Sendable {
    enum TapResolution: String, Equatable, Sendable {
        case emitted
        case rejectedTravel
        case rejectedDuration
        case suppressedByPhysicalClick
        case noCandidate
    }

    enum TranslationError: Error, Equatable, Sendable {
        case unsupportedContactCount(Int)
        case unsupportedButtonBits
        case invalidState
    }

    private struct ContactGesture: Sendable {
        let startedAtNanos: UInt64
        var maxContactCount: Int
        var travel: Int64 = 0
        var tapEligible = true
    }

    private var activeButton: UInt32?
    private var gesture: ContactGesture?
    private var suppressTapUntilLift = false
    private var tapResolution: TapResolution?

    private let tapMaxDurationNanos: UInt64
    private let tapMovementThreshold: Int64

    init(
        tapMaxDurationNanos: UInt64 = 250_000_000,
        tapMovementThreshold: Int64 = 12
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

        tapResolution = nil

        if report.contactCount == 0 {
            guard !clicked else {
                throw TranslationError.invalidState
            }

            if let button = activeButton {
                activeButton = nil
                gesture = nil
                suppressTapUntilLift = false
                tapResolution = .suppressedByPhysicalClick
                return [
                    SemanticPointerEvent(
                        .button(button: button, down: false)
                    )
                ]
            }

            if suppressTapUntilLift {
                suppressTapUntilLift = false
                gesture = nil
                tapResolution = .suppressedByPhysicalClick
                return []
            }

            defer { gesture = nil }
            guard let gesture else {
                tapResolution = .noCandidate
                return []
            }
            guard nowNanos >= gesture.startedAtNanos,
                  nowNanos - gesture.startedAtNanos <= tapMaxDurationNanos else {
                tapResolution = .rejectedDuration
                return []
            }
            guard gesture.tapEligible else {
                tapResolution = .rejectedTravel
                return []
            }

            let button: UInt32
            switch gesture.maxContactCount {
            case 1: button = 0
            case 2: button = 1
            default:
                throw TranslationError.invalidState
            }
            tapResolution = .emitted
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

        guard dx != 0 || dy != 0 else {
            gesture = current
            return []
        }

        current.travel += Int64(abs(dx)) + Int64(abs(dy))
        if current.travel > tapMovementThreshold {
            current.tapEligible = false
        }
        gesture = current

        // Pointer fidelity wins over deferred gesture classification. Holding
        // early deltas until touch-slop is crossed creates a deterministic
        // pause followed by a burst, which is visible as trackpad lag/jump.
        // Tap eligibility remains independent and is decided only on lift.
        return try movementEvents(
            contactCount: report.contactCount,
            dx: dx,
            dy: dy
        )
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

    mutating func takeTapResolution() -> TapResolution? {
        defer { tapResolution = nil }
        return tapResolution
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
