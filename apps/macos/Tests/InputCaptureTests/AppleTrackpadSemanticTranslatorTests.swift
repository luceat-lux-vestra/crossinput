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

    @Test("short one-contact touch emits primary tap-to-click on lift")
    func oneContactTapToClick() throws {
        var translator = AppleTrackpadSemanticTranslator()

        #expect(
            try translator.translate(
                decode(contactCount: 1),
                nowNanos: 1_000_000_000
            ).isEmpty
        )
        #expect(
            try translator.translate(
                decode(pointerX: 2, pointerY: -1, contactCount: 1),
                nowNanos: 1_050_000_000
            ) == [
                SemanticPointerEvent(.move(dx: 2, dy: -1))
            ]
        )
        #expect(
            try translator.translate(
                decode(contactCount: 0),
                nowNanos: 1_120_000_000
            ) == [
                SemanticPointerEvent(.button(button: 0, down: true)),
                SemanticPointerEvent(.button(button: 0, down: false)),
            ]
        )
        #expect(translator.takeTapResolution() == .emitted)
    }

    @Test("bounded report silence can finalize one-contact tap without zero-contact report")
    func reportSilenceFinalizesTap() throws {
        var translator = AppleTrackpadSemanticTranslator()

        #expect(
            try translator.translate(
                decode(contactCount: 1),
                nowNanos: 1_500_000_000
            ).isEmpty
        )
        #expect(
            try translator.finishContact(
                nowNanos: 1_540_000_000
            ) == [
                SemanticPointerEvent(.button(button: 0, down: true)),
                SemanticPointerEvent(.button(button: 0, down: false)),
            ]
        )
        #expect(translator.takeTapResolution() == .emitted)
    }

    @Test("short two-contact touch emits secondary tap-to-click")
    func twoContactTapToClick() throws {
        var translator = AppleTrackpadSemanticTranslator()

        #expect(
            try translator.translate(
                decode(contactCount: 1),
                nowNanos: 2_000_000_000
            ).isEmpty
        )
        #expect(
            try translator.translate(
                decode(contactCount: 2),
                nowNanos: 2_030_000_000
            ).isEmpty
        )
        #expect(
            try translator.translate(
                decode(contactCount: 1),
                nowNanos: 2_080_000_000
            ).isEmpty
        )
        #expect(
            try translator.translate(
                decode(contactCount: 0),
                nowNanos: 2_120_000_000
            ) == [
                SemanticPointerEvent(.button(button: 1, down: true)),
                SemanticPointerEvent(.button(button: 1, down: false)),
            ]
        )
    }

    @Test("movement is immediate and beyond touch slop cancels tap")
    func movementCancelsTap() throws {
        var translator = AppleTrackpadSemanticTranslator(
            tapMovementThreshold: 10
        )

        #expect(
            try translator.translate(
                decode(pointerX: 4, pointerY: 0, contactCount: 1),
                nowNanos: 3_000_000_000
            ) == [
                SemanticPointerEvent(.move(dx: 4, dy: 0))
            ]
        )
        #expect(
            try translator.translate(
                decode(pointerX: 7, pointerY: 0, contactCount: 1),
                nowNanos: 3_020_000_000
            ) == [
                SemanticPointerEvent(.move(dx: 7, dy: 0))
            ]
        )
        #expect(
            try translator.translate(
                decode(contactCount: 0),
                nowNanos: 3_040_000_000
            ).isEmpty
        )
        #expect(translator.takeTapResolution() == .rejectedTravel)
    }

    @Test("two-contact motion beyond slop becomes scroll, never secondary tap")
    func scrollCancelsSecondaryTap() throws {
        var translator = AppleTrackpadSemanticTranslator(
            tapMovementThreshold: 10
        )

        #expect(
            try translator.translate(
                decode(pointerX: 3, pointerY: -2, contactCount: 2),
                nowNanos: 4_000_000_000
            ) == [
                SemanticPointerEvent(.scroll(horizontal: 3, vertical: -2))
            ]
        )
        #expect(
            try translator.translate(
                decode(pointerX: 8, pointerY: -6, contactCount: 2),
                nowNanos: 4_020_000_000
            ) == [
                SemanticPointerEvent(.scroll(horizontal: 8, vertical: -6))
            ]
        )
        #expect(
            try translator.translate(
                decode(contactCount: 0),
                nowNanos: 4_040_000_000
            ).isEmpty
        )
    }

    @Test("sub-slop motion is never buffered behind tap classification")
    func subSlopMotionIsImmediate() throws {
        var translator = AppleTrackpadSemanticTranslator(
            tapMovementThreshold: 12
        )

        #expect(
            try translator.translate(
                decode(pointerX: 1, pointerY: 1, contactCount: 1),
                nowNanos: 4_500_000_000
            ) == [
                SemanticPointerEvent(.move(dx: 1, dy: 1))
            ]
        )
        #expect(
            try translator.translate(
                decode(pointerX: 2, pointerY: -1, contactCount: 1),
                nowNanos: 4_510_000_000
            ) == [
                SemanticPointerEvent(.move(dx: 2, dy: -1))
            ]
        )
    }

    @Test("sub-slop jitter does not accumulate into a false tap rejection")
    func jitterUsesExcursionNotPathLength() throws {
        var translator = AppleTrackpadSemanticTranslator(
            tapMovementThreshold: 10
        )

        #expect(
            try translator.translate(
                decode(pointerX: 6, pointerY: 0, contactCount: 1),
                nowNanos: 4_700_000_000
            ) == [SemanticPointerEvent(.move(dx: 6, dy: 0))]
        )
        #expect(
            try translator.translate(
                decode(pointerX: -6, pointerY: 0, contactCount: 1),
                nowNanos: 4_720_000_000
            ) == [SemanticPointerEvent(.move(dx: -6, dy: 0))]
        )
        #expect(
            try translator.translate(
                decode(pointerX: 6, pointerY: 0, contactCount: 1),
                nowNanos: 4_740_000_000
            ) == [SemanticPointerEvent(.move(dx: 6, dy: 0))]
        )
        #expect(
            try translator.translate(
                decode(pointerX: -6, pointerY: 0, contactCount: 1),
                nowNanos: 4_760_000_000
            ) == [SemanticPointerEvent(.move(dx: -6, dy: 0))]
        )
        #expect(
            try translator.translate(
                decode(contactCount: 0),
                nowNanos: 4_800_000_000
            ) == [
                SemanticPointerEvent(.button(button: 0, down: true)),
                SemanticPointerEvent(.button(button: 0, down: false)),
            ]
        )
        #expect(translator.takeTapResolution() == .emitted)
    }

    @Test("long touch does not synthesize tap")
    func longTouchIsNotTap() throws {
        var translator = AppleTrackpadSemanticTranslator(
            tapMaxDurationNanos: 200_000_000
        )

        #expect(
            try translator.translate(
                decode(contactCount: 1),
                nowNanos: 5_000_000_000
            ).isEmpty
        )
        #expect(
            try translator.translate(
                decode(contactCount: 0),
                nowNanos: 5_250_000_001
            ).isEmpty
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

    @Test("primary click stays latched while a second contact performs drag")
    func primaryHeldClickAllowsSecondContactDrag() throws {
        var translator = AppleTrackpadSemanticTranslator()

        #expect(
            try translator.translate(
                decode(buttons: 0b001, contactCount: 1)
            ) == [SemanticPointerEvent(.button(button: 0, down: true))]
        )
        #expect(
            try translator.translate(
                decode(
                    buttons: 0b001,
                    pointerX: 3,
                    pointerY: -2,
                    contactCount: 2
                )
            ) == [SemanticPointerEvent(.move(dx: 3, dy: -2))]
        )
        #expect(
            try translator.translate(
                decode(
                    buttons: 0b001,
                    pointerX: 2,
                    pointerY: 1,
                    contactCount: 1
                )
            ) == [SemanticPointerEvent(.move(dx: 2, dy: 1))]
        )
        #expect(
            try translator.translate(
                decode(buttons: 0, contactCount: 1)
            ) == [SemanticPointerEvent(.button(button: 0, down: false))]
        )
    }

    @Test("secondary click stays latched while contact count changes during drag")
    func secondaryHeldClickAllowsContactChangeDrag() throws {
        var translator = AppleTrackpadSemanticTranslator()

        #expect(
            try translator.translate(
                decode(buttons: 0b001, contactCount: 2)
            ) == [SemanticPointerEvent(.button(button: 1, down: true))]
        )
        #expect(
            try translator.translate(
                decode(
                    buttons: 0b001,
                    pointerX: -4,
                    pointerY: 2,
                    contactCount: 1
                )
            ) == [SemanticPointerEvent(.move(dx: -4, dy: 2))]
        )
        #expect(
            try translator.translate(
                decode(buttons: 0, contactCount: 1)
            ) == [SemanticPointerEvent(.button(button: 1, down: false))]
        )
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

    @Test("zero contacts is an idle report and ignores stale deltas")
    func zeroContactsIsIdle() throws {
        var translator = AppleTrackpadSemanticTranslator()
        let events = try translator.translate(
            decode(pointerX: 17, pointerY: -9, contactCount: 0)
        )
        #expect(events.isEmpty)
    }

    @Test("zero-contact lift releases the latched button identity")
    func zeroContactLiftReleasesLatchedButton() throws {
        var translator = AppleTrackpadSemanticTranslator()

        #expect(
            try translator.translate(decode(buttons: 0b001, contactCount: 2))
                == [SemanticPointerEvent(.button(button: 1, down: true))]
        )
        #expect(
            try translator.translate(decode(contactCount: 0))
                == [SemanticPointerEvent(.button(button: 1, down: false))]
        )
        #expect(try translator.translate(decode(contactCount: 0)).isEmpty)
    }

    @Test("Button1 with zero contacts fails closed")
    func zeroContactClickIsInvalid() throws {
        var translator = AppleTrackpadSemanticTranslator()
        #expect(
            throws: AppleTrackpadSemanticTranslator.TranslationError.invalidState
        ) {
            try translator.translate(
                decode(buttons: 0b001, contactCount: 0)
            )
        }
    }

    @Test("three-contact movement synthesizes one primary drag")
    func threeFingerMovementDragsPrimary() throws {
        var translator = AppleTrackpadSemanticTranslator()

        #expect(
            try translator.translate(
                decode(contactCount: 3)
            ).isEmpty
        )
        #expect(
            try translator.translate(
                decode(pointerX: 3, pointerY: -2, contactCount: 3)
            ) == [
                SemanticPointerEvent(.button(button: 0, down: true)),
                SemanticPointerEvent(.move(dx: 3, dy: -2)),
            ]
        )
        #expect(
            try translator.translate(
                decode(pointerX: 4, pointerY: 1, contactCount: 3)
            ) == [
                SemanticPointerEvent(.move(dx: 4, dy: 1))
            ]
        )
        #expect(
            try translator.translate(
                decode(contactCount: 2)
            ) == [
                SemanticPointerEvent(.button(button: 0, down: false))
            ]
        )
        #expect(
            try translator.translate(
                decode(pointerX: 5, contactCount: 1)
            ).isEmpty
        )
        #expect(
            try translator.translate(
                decode(contactCount: 0)
            ).isEmpty
        )
    }

    @Test("report silence retires three-finger drag and restores later input")
    func reportSilenceRetiresThreeFingerDrag() throws {
        var translator = AppleTrackpadSemanticTranslator()

        #expect(
            try translator.translate(
                decode(pointerX: 3, pointerY: -2, contactCount: 3),
                nowNanos: 6_000_000_000
            ) == [
                SemanticPointerEvent(.button(button: 0, down: true)),
                SemanticPointerEvent(.move(dx: 3, dy: -2)),
            ]
        )
        #expect(
            try translator.translate(
                decode(contactCount: 2),
                nowNanos: 6_010_000_000
            ) == [
                SemanticPointerEvent(.button(button: 0, down: false))
            ]
        )

        // Physical evidence shows no terminal zero-contact report. Silence is
        // the real end-of-contact signal and must clear the sequence latch.
        #expect(
            try translator.finishContact(
                nowNanos: 6_070_000_000
            ).isEmpty
        )

        #expect(
            try translator.translate(
                decode(pointerX: 5, pointerY: 1, contactCount: 1),
                nowNanos: 6_100_000_000
            ) == [
                SemanticPointerEvent(.move(dx: 5, dy: 1))
            ]
        )
    }

    @Test("raw primary transition can overlap an active three-finger drag")
    func rawPrimaryOverlapsThreeFingerDrag() throws {
        var translator = AppleTrackpadSemanticTranslator()

        #expect(
            try translator.translate(
                decode(pointerX: 3, pointerY: -2, contactCount: 3)
            ) == [
                SemanticPointerEvent(.button(button: 0, down: true)),
                SemanticPointerEvent(.move(dx: 3, dy: -2)),
            ]
        )

        // Real hardware can assert raw Button1 while the three-finger gesture
        // already owns primary. It must co-own the same logical button, not
        // throw or duplicate button-down.
        #expect(
            try translator.translate(
                decode(buttons: 0b001, contactCount: 3)
            ).isEmpty
        )
        #expect(
            try translator.translate(
                decode(
                    buttons: 0b001,
                    pointerX: 2,
                    pointerY: 1,
                    contactCount: 3
                )
            ) == [
                SemanticPointerEvent(.move(dx: 2, dy: 1))
            ]
        )

        // Partial lift ends the three-finger owner, but raw Button1 still owns
        // primary, so no button-up is emitted yet.
        #expect(
            try translator.translate(
                decode(buttons: 0b001, contactCount: 2)
            ).isEmpty
        )
        #expect(
            try translator.translate(
                decode(buttons: 0, contactCount: 2)
            ) == [
                SemanticPointerEvent(.button(button: 0, down: false))
            ]
        )
    }

    @Test("raw primary down during three-finger partial lift remains primary")
    func rawPrimaryDuringThreeFingerPartialLiftDoesNotBecomeSecondary() throws {
        var translator = AppleTrackpadSemanticTranslator()

        _ = try translator.translate(
            decode(pointerX: 2, contactCount: 3)
        )
        #expect(
            try translator.translate(
                decode(contactCount: 2)
            ) == [
                SemanticPointerEvent(.button(button: 0, down: false))
            ]
        )

        // The sequence is still active until silence/all-lift. A raw Button1
        // transition during this 3 -> 2 phase belongs to the drag and must not
        // be reclassified as a two-finger secondary click.
        #expect(
            try translator.translate(
                decode(buttons: 0b001, contactCount: 2)
            ) == [
                SemanticPointerEvent(.button(button: 0, down: true))
            ]
        )
        #expect(
            try translator.translate(
                decode(buttons: 0, contactCount: 1)
            ) == [
                SemanticPointerEvent(.button(button: 0, down: false))
            ]
        )
    }

    @Test("three-contact touch without movement never clicks")
    func threeFingerTouchWithoutMovementIsSilent() throws {
        var translator = AppleTrackpadSemanticTranslator()

        #expect(
            try translator.translate(
                decode(contactCount: 3)
            ).isEmpty
        )
        #expect(
            try translator.translate(
                decode(contactCount: 2)
            ).isEmpty
        )
        #expect(
            try translator.translate(
                decode(contactCount: 1)
            ).isEmpty
        )
        #expect(
            try translator.translate(
                decode(contactCount: 0)
            ).isEmpty
        )
    }

    @Test("reset releases active three-finger drag exactly once")
    func resetReleasesThreeFingerDrag() throws {
        var translator = AppleTrackpadSemanticTranslator()

        _ = try translator.translate(
            decode(pointerX: 2, contactCount: 3)
        )
        #expect(
            translator.reset()
                == [SemanticPointerEvent(.button(button: 0, down: false))]
        )
        #expect(translator.reset().isEmpty)
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
        // The production decoder deliberately accepts only the physically
        // proven common report prefix (>= 76 bytes). Zero contacts is encoded
        // inside that prefix; it does not imply a shorter report shape.
        let length = max(76, 46 + (30 * contactCount))
        var bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = 2
        bytes[1] = buttons
        bytes[2] = UInt8(bitPattern: pointerX)
        bytes[3] = UInt8(bitPattern: pointerY)
        bytes[30] = UInt8(contactCount)
        return try AppleTrackpadRawReportDecoder.decode(Data(bytes))
    }
}
