import InputDomain

/// Converts the minimum proven built-in-trackpad surface into platform-neutral
/// pointer semantics.
///
/// Button1 + one contact = primary click.
/// Button1 + two contacts = secondary click.
/// One-contact X/Y = movement; two-contact X/Y = scroll.
/// Unproven buttons and 3+ contact gestures fail closed.
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
        guard !report.buttons.secondary, !report.buttons.other else {
            throw TranslationError.unsupportedButtonBits
        }

        let clicked = report.buttons.primary
        let wasClicked = activeButton != nil

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

        let dx = Int32(report.pointerX)
        let dy = Int32(report.pointerY)
        guard dx != 0 || dy != 0 else { return [] }

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
