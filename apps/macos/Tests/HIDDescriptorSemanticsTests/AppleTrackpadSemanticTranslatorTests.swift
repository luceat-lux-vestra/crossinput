import Foundation
import Testing
@testable import HIDDescriptorSemantics

@Suite("Apple trackpad semantic translator")
struct AppleTrackpadSemanticTranslatorTests {
    @Test("one contact translates to relative pointer movement")
    func oneContactMovesPointer() throws {
        var translator = AppleTrackpadSemanticTranslator()

        let events = try translator.translate(
            decode(
                pointerX: 12,
                pointerY: -7,
                physicalClicked: false,
                contacts: [.init()]
            )
        )

        #expect(events == [.move(dx: 12, dy: -7)])
    }

    @Test("two contacts translate to averaged raw scroll delta")
    func twoContactsScroll() throws {
        var translator = AppleTrackpadSemanticTranslator()

        let events = try translator.translate(
            decode(
                pointerX: 8,
                pointerY: -6,
                physicalClicked: false,
                contacts: [.init(), .init()]
            )
        )

        #expect(events == [.scroll(horizontal: 8, vertical: -6)])
    }

    @Test("single-contact physical click maps to primary down and up")
    func primaryClickTransitions() throws {
        var translator = AppleTrackpadSemanticTranslator()

        let down = try translator.translate(
            decode(
                physicalClicked: true,
                pointerX: 3,
                pointerY: 2,
                contacts: [.init()]
            )
        )
        let up = try translator.translate(
            decode(
                physicalClicked: false,
                pointerX: 1,
                pointerY: 1,
                contacts: [.init()]
            )
        )

        #expect(down == [.button(.primary, down: true)])
        #expect(up == [.button(.primary, down: false)])
    }

    @Test("two-contact physical click maps to secondary down and up")
    func secondaryClickTransitions() throws {
        var translator = AppleTrackpadSemanticTranslator()

        let down = try translator.translate(
            decode(
                physicalClicked: true,
                contacts: [
                    .init(),
                    .init()
                ]
            )
        )
        let up = try translator.translate(
            decode(
                physicalClicked: false,
                contacts: [
                    .init(),
                    .init()
                ]
            )
        )

        #expect(down == [.button(.secondary, down: true)])
        #expect(up == [.button(.secondary, down: false)])
    }

    @Test("button identity remains latched if contact count changes before release")
    func buttonIdentityIsLatched() throws {
        var translator = AppleTrackpadSemanticTranslator()

        _ = try translator.translate(
            decode(
                physicalClicked: true,
                contacts: [
                    .init(),
                    .init()
                ]
            )
        )

        let held = try translator.translate(
            decode(
                physicalClicked: true,
                pointerX: 5,
                contacts: [.init()]
            )
        )
        let release = try translator.translate(
            decode(
                physicalClicked: false,
                contacts: [.init()]
            )
        )

        #expect(held == [.move(dx: 5, dy: 0)])
        #expect(release == [.button(.secondary, down: false)])
    }

    @Test("click transition suppresses incidental motion")
    func clickTransitionSuppressesJitter() throws {
        var translator = AppleTrackpadSemanticTranslator()

        let down = try translator.translate(
            decode(
                physicalClicked: true,
                pointerX: 30,
                pointerY: -20,
                contacts: [.init()]
            )
        )

        #expect(down == [.button(.primary, down: true)])
    }

    @Test("reset releases a held button exactly once")
    func resetReleasesHeldButton() throws {
        var translator = AppleTrackpadSemanticTranslator()

        _ = try translator.translate(
            decode(
                physicalClicked: true,
                contacts: [.init()]
            )
        )

        #expect(translator.reset() == [.button(.primary, down: false)])
        #expect(translator.reset().isEmpty)
    }

    @Test("three-contact gestures fail closed")
    func rejectsThreeContactGesture() throws {
        var translator = AppleTrackpadSemanticTranslator()
        let report = decode(
            physicalClicked: false,
            contacts: [
                .init(),
                .init(),
                .init()
            ]
        )

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
            decode(
                physicalClicked: true,
                contacts: [
                    .init(),
                    .init()
                ]
            )
        )

        let release = try translator.translate(
            decode(
                physicalClicked: false,
                contacts: [
                    .init(),
                    .init(),
                    .init()
                ]
            )
        )

        #expect(release == [.button(.secondary, down: false)])
    }

    @Test("zero delta does not emit movement")
    func zeroDeltaIsSilent() throws {
        var translator = AppleTrackpadSemanticTranslator()

        let events = try translator.translate(
            decode(
                physicalClicked: false,
                contacts: [.init()]
            )
        )

        #expect(events.isEmpty)
    }

    private struct ContactFixture {
        init() {}
    }

    private func decode(
        pointerX: Int8 = 0,
        pointerY: Int8 = 0,
        physicalClicked: Bool,
        contacts: [ContactFixture]
    ) throws -> AppleTrackpadRawReportDecoder.Report {
        precondition(!contacts.isEmpty)

        let length = 46 + (30 * contacts.count)
        var bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = 2
        bytes[2] = UInt8(bitPattern: pointerX)
        bytes[3] = UInt8(bitPattern: pointerY)
        bytes[30] = UInt8(contacts.count)
        bytes[31] = physicalClicked ? 1 : 0

        return try AppleTrackpadRawReportDecoder.decode(Data(bytes))
    }
}
