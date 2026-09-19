import Foundation
import Testing
@testable import HIDDescriptorSemantics

@Suite("Apple trackpad semantic translator")
struct AppleTrackpadSemanticTranslatorTests {
    @Test("one contact translates to relative pointer movement")
    func oneContactMovesPointer() throws {
        var translator = AppleTrackpadSemanticTranslator()

        let events = try translator.translate(
            decode(pointerX: 12, pointerY: -7, contactCount: 1)
        )

        #expect(events == [.move(dx: 12, dy: -7)])
    }

    @Test("two contacts translate standard HID axes to scroll")
    func twoContactsScroll() throws {
        var translator = AppleTrackpadSemanticTranslator()

        let events = try translator.translate(
            decode(pointerX: 8, pointerY: -6, contactCount: 2)
        )

        #expect(events == [.scroll(horizontal: 8, vertical: -6)])
    }

    @Test("one-contact Button1 maps to primary down and up")
    func primaryClickTransitions() throws {
        var translator = AppleTrackpadSemanticTranslator()

        let down = try translator.translate(
            decode(buttons: 0b001, contactCount: 1)
        )
        let up = try translator.translate(
            decode(buttons: 0, contactCount: 1)
        )

        #expect(down == [.button(.primary, down: true)])
        #expect(up == [.button(.primary, down: false)])
    }

    @Test("two-contact Button1 maps to secondary down and up")
    func secondaryClickTransitions() throws {
        var translator = AppleTrackpadSemanticTranslator()

        let down = try translator.translate(
            decode(buttons: 0b001, contactCount: 2)
        )
        let up = try translator.translate(
            decode(buttons: 0, contactCount: 2)
        )

        #expect(down == [.button(.secondary, down: true)])
        #expect(up == [.button(.secondary, down: false)])
    }

    @Test("button identity remains latched if contact count changes before release")
    func buttonIdentityIsLatched() throws {
        var translator = AppleTrackpadSemanticTranslator()

        _ = try translator.translate(
            decode(buttons: 0b001, contactCount: 2)
        )

        let held = try translator.translate(
            decode(buttons: 0b001, pointerX: 5, contactCount: 1)
        )
        let release = try translator.translate(
            decode(buttons: 0, contactCount: 1)
        )

        #expect(held == [.move(dx: 5, dy: 0)])
        #expect(release == [.button(.secondary, down: false)])
    }

    @Test("click transition suppresses incidental motion")
    func clickTransitionSuppressesJitter() throws {
        var translator = AppleTrackpadSemanticTranslator()

        let down = try translator.translate(
            decode(buttons: 0b001, pointerX: 30, pointerY: -20, contactCount: 1)
        )

        #expect(down == [.button(.primary, down: true)])
    }

    @Test("reset releases a held button exactly once")
    func resetReleasesHeldButton() throws {
        var translator = AppleTrackpadSemanticTranslator()

        _ = try translator.translate(
            decode(buttons: 0b001, contactCount: 1)
        )

        #expect(translator.reset() == [.button(.primary, down: false)])
        #expect(translator.reset().isEmpty)
    }

    @Test("three-contact gestures fail closed")
    func rejectsThreeContactGesture() throws {
        var translator = AppleTrackpadSemanticTranslator()
        let report = try decode(pointerX: 1, contactCount: 3)

        #expect(
            throws: AppleTrackpadSemanticTranslator.TranslationError
                .unsupportedContactCount(3)
        ) {
            try translator.translate(report)
        }
    }

    @Test("release uses latched button even if release packet has unsupported contact count")
    func releaseIgnoresChangedContactCountForButtonIdentity() throws {
        var translator = AppleTrackpadSemanticTranslator()

        _ = try translator.translate(
            decode(buttons: 0b001, contactCount: 2)
        )

        let release = try translator.translate(
            decode(buttons: 0, contactCount: 3)
        )

        #expect(release == [.button(.secondary, down: false)])
    }

    @Test("Button2 or Button3 fail closed")
    func rejectsUnprovenButtonBits() throws {
        var translator = AppleTrackpadSemanticTranslator()

        #expect(
            throws: AppleTrackpadSemanticTranslator.TranslationError
                .unsupportedButtonBits
        ) {
            try translator.translate(
                decode(buttons: 0b010, contactCount: 1)
            )
        }

        #expect(
            throws: AppleTrackpadSemanticTranslator.TranslationError
                .unsupportedButtonBits
        ) {
            try translator.translate(
                decode(buttons: 0b100, contactCount: 1)
            )
        }
    }

    @Test("zero delta does not emit movement")
    func zeroDeltaIsSilent() throws {
        var translator = AppleTrackpadSemanticTranslator()

        let events = try translator.translate(
            decode(contactCount: 1)
        )

        #expect(events.isEmpty)
    }

    private func decode(
        buttons: UInt8 = 0,
        pointerX: Int8 = 0,
        pointerY: Int8 = 0,
        contactCount: Int
    ) throws -> AppleTrackpadRawReportDecoder.Report {
        let length = 46 + (30 * contactCount)
        var bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = 2
        bytes[1] = buttons
        bytes[2] = UInt8(bitPattern: pointerX)
        bytes[3] = UInt8(bitPattern: pointerY)
        bytes[30] = UInt8(contactCount)
        return try AppleTrackpadRawReportDecoder.decode(Data(bytes))
    }
}
