import Foundation

/// Research semantic translator for the minimum proven Apple built-in trackpad
/// CoreHID surface.
///
/// Rules:
/// - Button1 is the physical click source.
/// - one contact + Button1 press -> primary button.
/// - two contacts + Button1 press -> secondary button.
/// - one contact + X/Y -> pointer move.
/// - two contacts + X/Y -> scroll.
/// - Button2/3 and three-or-more-contact gestures are rejected rather than
///   guessed.
///
/// Button identity is latched on press so contact-count changes cannot turn a
/// secondary press into a primary release. reset() emits a compensating
/// release to prevent a downstream stuck-button state on ownership loss.
public struct AppleTrackpadSemanticTranslator: Sendable {
    public enum Button: UInt32, Equatable, Sendable {
        case primary = 0
        case secondary = 1
    }

    public enum Event: Equatable, Sendable {
        case move(dx: Int32, dy: Int32)
        case scroll(horizontal: Int32, vertical: Int32)
        case button(Button, down: Bool)
    }

    public enum TranslationError: Error, Equatable, Sendable {
        case unsupportedContactCount(Int)
        case unsupportedButtonBits
        case invalidState
    }

    private var activeButton: Button?

    public init() {}

    public mutating func translate(
        _ report: AppleTrackpadRawReportDecoder.Report
    ) throws -> [Event] {
        guard !report.buttons.secondary, !report.buttons.other else {
            throw TranslationError.unsupportedButtonBits
        }

        let clicked = report.buttons.primary
        let wasClicked = activeButton != nil

        if clicked && !wasClicked {
            let button: Button
            switch report.contactCount {
            case 1:
                button = .primary
            case 2:
                button = .secondary
            default:
                throw TranslationError.unsupportedContactCount(report.contactCount)
            }

            activeButton = button
            return [.button(button, down: true)]
        }

        if !clicked && wasClicked {
            guard let button = activeButton else {
                throw TranslationError.invalidState
            }
            activeButton = nil
            return [.button(button, down: false)]
        }

        let dx = Int32(report.pointerX)
        let dy = Int32(report.pointerY)

        guard dx != 0 || dy != 0 else {
            return []
        }

        switch report.contactCount {
        case 1:
            return [.move(dx: dx, dy: dy)]
        case 2:
            return [.scroll(horizontal: dx, vertical: dy)]
        default:
            throw TranslationError.unsupportedContactCount(report.contactCount)
        }
    }

    public mutating func reset() -> [Event] {
        guard let button = activeButton else {
            return []
        }
        activeButton = nil
        return [.button(button, down: false)]
    }
}
