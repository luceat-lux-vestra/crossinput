import Foundation

/// Research semantic translator for decoded Apple built-in trackpad reports.
///
/// This intentionally implements only the pointer surface currently required
/// by Ampersand:
/// - exactly one contact -> relative pointer movement
/// - exactly two contacts -> raw two-finger scroll delta
/// - click transition with one contact -> primary button
/// - click transition with two contacts -> secondary button
///
/// Three-or-more-contact gestures are rejected rather than guessed.
/// Scroll sign/scaling is preserved from the raw relative axes and must be
/// calibrated at the production bridge, not hidden in this decoder.
///
/// Button identity is latched on press so a contact-count change cannot turn a
/// secondary press into a primary release. reset() emits a compensating
/// release to prevent a remote button from remaining stuck when ownership ends.
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
        case invalidState
    }

    private var activeButton: Button?

    public init() {}

    public mutating func translate(
        _ report: AppleTrackpadRawReportDecoder.Report
    ) throws -> [Event] {
        guard report.contactCount == report.contacts.count else {
            throw TranslationError.invalidState
        }

        var events: [Event] = []
        let wasClicked = activeButton != nil

        if report.clicked && !wasClicked {
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
            events.append(.button(button, down: true))
            // Do not translate movement from the transition packet. Mechanical
            // click-down frequently carries incidental contact jitter.
            return events
        }

        if !report.clicked && wasClicked {
            guard let button = activeButton else {
                throw TranslationError.invalidState
            }
            activeButton = nil
            events.append(.button(button, down: false))
            // Same rule on release: avoid turning release jitter into motion.
            return events
        }

        let dx = average(report.contacts.map(\.relativeX))
        let dy = average(report.contacts.map(\.relativeY))

        guard dx != 0 || dy != 0 else {
            return events
        }

        switch report.contactCount {
        case 1:
            events.append(.move(dx: dx, dy: dy))
        case 2:
            events.append(.scroll(horizontal: dx, vertical: dy))
        default:
            throw TranslationError.unsupportedContactCount(report.contactCount)
        }

        return events
    }

    /// Ends translator ownership. If a button is logically held, emit its
    /// matching release so the downstream target cannot retain a stuck button.
    public mutating func reset() -> [Event] {
        guard let button = activeButton else {
            return []
        }
        activeButton = nil
        return [.button(button, down: false)]
    }

    private func average(_ values: [Int16]) -> Int32 {
        guard !values.isEmpty else { return 0 }
        let sum = values.reduce(Int64(0)) { $0 + Int64($1) }
        return Int32(sum / Int64(values.count))
    }
}
