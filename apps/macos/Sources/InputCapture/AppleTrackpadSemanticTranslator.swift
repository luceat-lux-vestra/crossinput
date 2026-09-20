import InputDomain

/// Converts the minimum proven built-in-trackpad surface into platform-neutral
/// pointer semantics.
///
/// Button1 + one contact = primary click.
/// Button1 + two contacts = secondary click.
/// One-contact X/Y = movement; two-contact X/Y = scroll.
/// Zero contacts is idle/lift only. Unproven buttons and 3+ contacts fail closed.
struct AppleTrackpadSemanticTranslator: Sendable {
    enum TranslationError: Error, Equatable, Sendable {
        case unsupportedContactCount(Int)
        case unsupportedButtonBits
        case invalidState
    }

    private var activeButton: UInt32?

    mutating func translate(
        _ report: AppleTrackpadRawReportDecoder.Report
    ) throws -> [SemanticPointerEvent] {
        // Contact cardinality is part of the proven semantic surface, not
        // merely a condition on non-zero movement. Zero contacts is the normal
        // idle/lift state of the upstream structure; 3+ contacts remain an
        // unproven gesture and fail the stream closed.
        guard (0...2).contains(report.contactCount) else {
            throw TranslationError.unsupportedContactCount(report.contactCount)
        }
        guard !report.buttons.secondary, !report.buttons.other else {
            throw TranslationError.unsupportedButtonBits
        }

        let clicked = report.buttons.primary
        let wasClicked = activeButton != nil

        if report.contactCount == 0 {
            // A physical click cannot be classified without a proven contact
            // identity. A zero-contact report may only be idle or the release
            // edge of a previously latched button.
            guard !clicked else {
                throw TranslationError.invalidState
            }
            guard let button = activeButton else {
                return []
            }
            activeButton = nil
            return [SemanticPointerEvent(.button(button: button, down: false))]
        }

        if clicked && !wasClicked {
            let button: UInt32
            switch report.contactCount {
            case 1: button = 0
            case 2: button = 1
            default:
                throw TranslationError.unsupportedContactCount(report.contactCount)
            }
            activeButton = button
            return [SemanticPointerEvent(.button(button: button, down: true))]
        }

        if !clicked && wasClicked {
            guard let button = activeButton else {
                throw TranslationError.invalidState
            }
            activeButton = nil
            return [SemanticPointerEvent(.button(button: button, down: false))]
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
        guard dx != 0 || dy != 0 else { return [] }

        // Two-contact motion is proven as scrolling only when no click is
        // latched. Motion while a secondary click is held could represent a
        // different gesture (for example secondary drag); that combination
        // has no physical proof and must not be reinterpreted as scroll.
        if activeButton == 1 {
            throw TranslationError.invalidState
        }

        switch report.contactCount {
        case 1:
            return [SemanticPointerEvent(.move(dx: dx, dy: dy))]
        case 2:
            return [
                SemanticPointerEvent(
                    .scroll(horizontal: Float(dx), vertical: Float(dy))
                )
            ]
        default:
            throw TranslationError.unsupportedContactCount(report.contactCount)
        }
    }

    mutating func reset() -> [SemanticPointerEvent] {
        guard let button = activeButton else { return [] }
        activeButton = nil
        return [SemanticPointerEvent(.button(button: button, down: false))]
    }
}
