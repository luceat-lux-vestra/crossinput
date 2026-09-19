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
                physicalClicked: false,
                contacts: [.init(relativeX: 12, relativeY: -7)]
            )
        )

        #expect(events == [.move(dx: 12, dy: -7)])
    }

    @Test("two contacts translate to averaged raw scroll delta")
    func twoContactsScroll() throws {
        var translator = AppleTrackpadSemanticTranslator()

        let events = try translator.translate(
            decode(
                physicalClicked: false,
                contacts: [
                    .init(relativeX: 10, relativeY: -4),
                    .init(relativeX: 6, relativeY: -8)
                ]
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
                contacts: [.init(relativeX: 3, relativeY: 2)]
            )
        )
        let up = try translator.translate(
            decode(
                physicalClicked: false,
                contacts: [.init(relativeX: 1, relativeY: 1)]
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
                    .init(relativeX: 0, relativeY: 0),
                    .init(relativeX: 0, relativeY: 0)
                ]
            )
        )
        let up = try translator.translate(
            decode(
                physicalClicked: false,
                contacts: [
                    .init(relativeX: 0, relativeY: 0),
                    .init(relativeX: 0, relativeY: 0)
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
                    .init(relativeX: 0, relativeY: 0),
                    .init(relativeX: 0, relativeY: 0)
                ]
            )
        )

        let held = try translator.translate(
            decode(
                physicalClicked: true,
                contacts: [.init(relativeX: 5, relativeY: 0)]
            )
        )
        let release = try translator.translate(
            decode(
                physicalClicked: false,
                contacts: [.init(relativeX: 0, relativeY: 0)]
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
                contacts: [.init(relativeX: 30, relativeY: -20)]
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
                contacts: [.init(relativeX: 0, relativeY: 0)]
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
                .init(relativeX: 1, relativeY: 0),
                .init(relativeX: 1, relativeY: 0),
                .init(relativeX: 1, relativeY: 0)
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
                    .init(relativeX: 0, relativeY: 0),
                    .init(relativeX: 0, relativeY: 0)
                ]
            )
        )

        let release = try translator.translate(
            decode(
                physicalClicked: false,
                contacts: [
                    .init(relativeX: 0, relativeY: 0),
                    .init(relativeX: 0, relativeY: 0),
                    .init(relativeX: 0, relativeY: 0)
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
                contacts: [.init(relativeX: 0, relativeY: 0)]
            )
        )

        #expect(events.isEmpty)
    }

    private struct ContactFixture {
        let relativeX: Int16
        let relativeY: Int16
    }

    private func decode(
        physicalClicked: Bool,
        contacts: [ContactFixture]
    ) throws -> AppleTrackpadRawReportDecoder.Report {
        precondition(!contacts.isEmpty)

        let length = 46 + (30 * contacts.count)
        var bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = 2
        bytes[30] = UInt8(contacts.count)
        bytes[31] = physicalClicked ? 1 : 0

        for (index, contact) in contacts.enumerated() {
            let base = 48 + (index * 30)
            putInt16LE(contact.relativeX, into: &bytes, at: base + 6)
            putInt16LE(contact.relativeY, into: &bytes, at: base + 8)
        }

        return try AppleTrackpadRawReportDecoder.decode(Data(bytes))
    }

    private func putInt16LE(
        _ value: Int16,
        into bytes: inout [UInt8],
        at offset: Int
    ) {
        let raw = UInt16(bitPattern: value)
        bytes[offset] = UInt8(truncatingIfNeeded: raw)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: raw >> 8)
    }
}
