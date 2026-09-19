import Foundation
import Testing
import InputDomain
@testable import InputCapture

@Suite("Apple trackpad semantic translator")
struct AppleTrackpadSemanticTranslatorTests {
    @Test("one contact translates to pointer movement")
    func oneContactMovesPointer() throws {
        var translator = AppleTrackpadSemanticTranslator()
        let events = try translator.translate(
            decode(pointerX: 12, pointerY: -7, contactCount: 1)
        )
        #expect(events == [SemanticPointerEvent(.move(dx: 12, dy: -7))])
    }

    @Test("two contacts translate standard HID axes to scroll")
    func twoContactsScroll() throws {
        var translator = AppleTrackpadSemanticTranslator()
        let events = try translator.translate(
            decode(pointerX: 8, pointerY: -6, contactCount: 2)
        )
        #expect(
            events == [
                SemanticPointerEvent(.scroll(horizontal: 8, vertical: -6))
            ]
        )
    }

    @Test("Button1 maps by contact count and latches release identity")
    func clickTransitions() throws {
        var translator = AppleTrackpadSemanticTranslator()

        #expect(
            try translator.translate(decode(buttons: 0b001, contactCount: 1))
                == [SemanticPointerEvent(.button(button: 0, down: true))]
        )
        #expect(
            try translator.translate(decode(buttons: 0, contactCount: 1))
                == [SemanticPointerEvent(.button(button: 0, down: false))]
        )

        #expect(
            try translator.translate(decode(buttons: 0b001, contactCount: 2))
                == [SemanticPointerEvent(.button(button: 1, down: true))]
        )
        #expect(
            try translator.translate(decode(buttons: 0, contactCount: 1))
                == [SemanticPointerEvent(.button(button: 1, down: false))]
        )
    }

    @Test("click transition suppresses incidental motion")
    func clickTransitionSuppressesJitter() throws {
        var translator = AppleTrackpadSemanticTranslator()
        let down = try translator.translate(
            decode(buttons: 0b001, pointerX: 30, pointerY: -20, contactCount: 1)
        )
        #expect(down == [SemanticPointerEvent(.button(button: 0, down: true))])
    }

    @Test("reset releases held button exactly once")
    func resetReleasesHeldButton() throws {
        var translator = AppleTrackpadSemanticTranslator()
        _ = try translator.translate(decode(buttons: 0b001, contactCount: 2))
        #expect(
            translator.reset()
                == [SemanticPointerEvent(.button(button: 1, down: false))]
        )
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

    @Test("Button2 or Button3 fail closed")
    func rejectsUnprovenButtonBits() throws {
        var translator = AppleTrackpadSemanticTranslator()
        #expect(
            throws: AppleTrackpadSemanticTranslator.TranslationError
                .unsupportedButtonBits
        ) {
            try translator.translate(decode(buttons: 0b010, contactCount: 1))
        }
        #expect(
            throws: AppleTrackpadSemanticTranslator.TranslationError
                .unsupportedButtonBits
        ) {
            try translator.translate(decode(buttons: 0b100, contactCount: 1))
        }
    }

    @Test("zero delta emits no movement")
    func zeroDeltaIsSilent() throws {
        var translator = AppleTrackpadSemanticTranslator()
        #expect(try translator.translate(decode(contactCount: 1)).isEmpty)
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
