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
        var displacementX: Int64 = 0
        var displacementY: Int64 = 0
        var tapEligible = true
    }

    /// Physical Button1 identity, latched from raw down until raw up.
    private var activeButton: UInt32?
    /// Remote primary-button state is independent from its source. A
    /// three-finger drag and raw Button1 may overlap on the real trackpad; both
    /// co-own one logical primary-down instead of generating duplicate edges.
    private var logicalPrimaryDown = false
    private var gesture: ContactGesture?
    private var suppressTapUntilLift = false
    /// CoreHID seizure bypasses macOS' three-finger-drag recognizer. Keep a
    /// dedicated sequence so 3-contact movement is one primary drag and the
    /// 3 -> 2 -> 1 partial lift cannot leak scroll/move semantics.
    private var threeFingerSequenceActive = false
    private var threeFingerDragActive = false
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
        guard (0...3).contains(report.contactCount) else {
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
            if threeFingerSequenceActive {
                threeFingerSequenceActive = false
                gesture = nil
                suppressTapUntilLift = false
                if threeFingerDragActive {
                    threeFingerDragActive = false
                    return [
                        SemanticPointerEvent(
                            .button(button: 0, down: false)
                        )
                    ]
                }
                return []
            }
            return try finishContact(nowNanos: nowNanos)
        }

        if clicked && !wasClicked {
            let button: UInt32
            if threeFingerSequenceActive || report.contactCount == 3 {
                // Physical evidence shows raw Button1 may transition during a
                // three-finger drag. Treat it as another owner of the same
                // primary drag; never fail or emit a duplicate primary-down.
                button = 0
            } else {
                switch report.contactCount {
                case 1: button = 0
                case 2: button = 1
                default:
                    throw TranslationError.unsupportedContactCount(
                        report.contactCount
                    )
                }
            }
            activeButton = button
            gesture = nil
            suppressTapUntilLift = true

            if button == 0 {
                guard !logicalPrimaryDown else { return [] }
                logicalPrimaryDown = true
            }
            return [
                SemanticPointerEvent(.button(button: button, down: true))
            ]
        }

        if !clicked && wasClicked {
            guard let button = activeButton else {
                throw TranslationError.invalidState
            }
            activeButton = nil

            if button == 0 {
                // Three-finger drag may still own the logical primary button.
                guard !threeFingerDragActive else { return [] }
                guard logicalPrimaryDown else { return [] }
                logicalPrimaryDown = false
            }
            return [
                SemanticPointerEvent(.button(button: button, down: false))
            ]
        }

        let dx = Int32(report.pointerX)
        let dy = Int32(report.pointerY)

        // Physical Button1 owns click identity from the down transition until
        // the matching up. Contact count may legitimately change while the
        // click is held (for example: one finger clicks/holds while a second
        // finger performs the drag). Never reinterpret that held button or
        // turn its movement into two-finger scroll.
        if activeButton != nil {
            guard dx != 0 || dy != 0 else { return [] }
            return [
                SemanticPointerEvent(.move(dx: dx, dy: dy))
            ]
        }

        // Three-finger drag is normally recognized above raw HID by macOS.
        // While seized, synthesize that semantic directly: the first non-zero
        // 3-contact movement presses primary, subsequent movement drags, and
        // leaving 3 contacts releases primary exactly once. Pure 3-finger
        // contact without movement never clicks.
        if report.contactCount == 3 {
            threeFingerSequenceActive = true
            gesture = nil
            suppressTapUntilLift = true
            guard dx != 0 || dy != 0 else { return [] }

            var events: [SemanticPointerEvent] = []
            if !threeFingerDragActive {
                threeFingerDragActive = true
                if !logicalPrimaryDown {
                    logicalPrimaryDown = true
                    events.append(
                        SemanticPointerEvent(.button(button: 0, down: true))
                    )
                }
            }
            events.append(
                SemanticPointerEvent(.move(dx: dx, dy: dy))
            )
            return events
        }

        if threeFingerSequenceActive {
            var events: [SemanticPointerEvent] = []
            if threeFingerDragActive {
                threeFingerDragActive = false
                // A concurrently held raw primary button keeps the remote
                // primary logically down across the 3 -> 2 -> 1 transition.
                if activeButton != 0, logicalPrimaryDown {
                    logicalPrimaryDown = false
                    events.append(
                        SemanticPointerEvent(.button(button: 0, down: false))
                    )
                }
            }
            // Keep suppressing partial-lift semantics until all contacts lift.
            return events
        }

        // After the physical button is released but contacts remain, suppress
        // tap synthesis for the remainder of that touch sequence. Ordinary
        // one-/two-contact movement semantics resume immediately.
        if suppressTapUntilLift {
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

        current.displacementX += Int64(dx)
        current.displacementY += Int64(dy)
        let excursionSquared =
            current.displacementX * current.displacementX
                + current.displacementY * current.displacementY
        let thresholdSquared =
            tapMovementThreshold * tapMovementThreshold
        if excursionSquared > thresholdSquared {
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

    mutating func finishContact(
        nowNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) throws -> [SemanticPointerEvent] {
        tapResolution = nil

        // The target trackpad does not emit a terminal zero-contact report.
        // Report silence is the proven end-of-contact oracle, so it must also
        // retire a three-finger sequence. Otherwise the partial-lift latch
        // remains set forever and all subsequent one/two-finger input is
        // swallowed until the entire CoreHID translator is reset.
        if threeFingerSequenceActive {
            threeFingerSequenceActive = false
            gesture = nil
            suppressTapUntilLift = false
            tapResolution = .suppressedByPhysicalClick
            if threeFingerDragActive {
                threeFingerDragActive = false
                if activeButton != 0, logicalPrimaryDown {
                    logicalPrimaryDown = false
                    return [
                        SemanticPointerEvent(
                            .button(button: 0, down: false)
                        )
                    ]
                }
            }
            return []
        }

        if let button = activeButton {
            activeButton = nil
            gesture = nil
            suppressTapUntilLift = false
            tapResolution = .suppressedByPhysicalClick
            if button == 0 {
                guard logicalPrimaryDown else { return [] }
                logicalPrimaryDown = false
            }
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
        threeFingerSequenceActive = false
        threeFingerDragActive = false

        let physicalButton = activeButton
        activeButton = nil

        if logicalPrimaryDown {
            logicalPrimaryDown = false
            return [
                SemanticPointerEvent(.button(button: 0, down: false))
            ]
        }

        guard let physicalButton, physicalButton != 0 else { return [] }
        return [
            SemanticPointerEvent(.button(button: physicalButton, down: false))
        ]
    }
}
