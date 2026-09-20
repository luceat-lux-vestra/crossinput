import Foundation
import Testing
@testable import InputCapture

@Suite("HID report descriptor pointer semantics")
struct HIDReportDescriptorSemanticsTests {
    @Test("canonical mouse X/Y are Data Variable Relative")
    func canonicalMouseRelativeXY() throws {
        let descriptor = Data([
            0x05, 0x01,
            0x09, 0x02,
            0xA1, 0x01,
            0x09, 0x01,
            0xA1, 0x00,
            0x05, 0x09,
            0x19, 0x01,
            0x29, 0x03,
            0x15, 0x00,
            0x25, 0x01,
            0x95, 0x03,
            0x75, 0x01,
            0x81, 0x02,
            0x95, 0x01,
            0x75, 0x05,
            0x81, 0x01,
            0x05, 0x01,
            0x09, 0x30,
            0x09, 0x31,
            0x15, 0x81,
            0x25, 0x7F,
            0x75, 0x08,
            0x95, 0x02,
            0x81, 0x06,
            0xC0,
            0xC0
        ])

        let result = try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)

        #expect(result.provesUnambiguousRelativeXY)
        #expect(result.xDataVariableDeclarations.count == 1)
        #expect(result.yDataVariableDeclarations.count == 1)
        #expect(result.xDataVariableDeclarations[0].isRelative)
        #expect(result.yDataVariableDeclarations[0].isRelative)
    }

    @Test("absolute X/Y fail the relative proof")
    func absoluteXYRejected() throws {
        let descriptor = Data([
            0x05, 0x01,
            0x09, 0x30,
            0x09, 0x31,
            0x75, 0x08,
            0x95, 0x02,
            0x81, 0x02
        ])

        let result = try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)

        #expect(!result.provesUnambiguousRelativeXY)
    }

    @Test("usage range X through Y is recognized")
    func usageRangeRelativeXY() throws {
        let descriptor = Data([
            0x05, 0x01,
            0x19, 0x30,
            0x29, 0x31,
            0x75, 0x10,
            0x95, 0x02,
            0x81, 0x06
        ])

        let result = try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)

        #expect(result.provesUnambiguousRelativeXY)
    }

    @Test("local usages reset after every Main item")
    func localUsageDoesNotLeakAcrossMainItems() throws {
        let descriptor = Data([
            0x05, 0x01,
            0x09, 0x30,
            0xA1, 0x00,
            0x75, 0x08,
            0x95, 0x01,
            0x81, 0x06,
            0xC0
        ])

        let result = try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)

        #expect(result.xDeclarations.isEmpty)
        #expect(result.yDeclarations.isEmpty)
        #expect(!result.provesUnambiguousRelativeXY)
    }

    @Test("mixed relative and absolute declarations fail closed")
    func mixedSemanticsRejected() throws {
        let descriptor = Data([
            0x05, 0x01,
            0x09, 0x30,
            0x75, 0x08,
            0x95, 0x01,
            0x81, 0x06,
            0x09, 0x31,
            0x81, 0x02
        ])

        let result = try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)

        #expect(!result.provesUnambiguousRelativeXY)
    }

    @Test("different report IDs fail the strict proof")
    func differentReportIDsRejected() throws {
        let descriptor = Data([
            0x05, 0x01,
            0x85, 0x01,
            0x09, 0x30,
            0x75, 0x08,
            0x95, 0x01,
            0x81, 0x06,
            0x85, 0x02,
            0x09, 0x31,
            0x81, 0x06
        ])

        let result = try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)

        #expect(!result.provesUnambiguousRelativeXY)
        #expect(result.xDataVariableDeclarations[0].reportID == 1)
        #expect(result.yDataVariableDeclarations[0].reportID == 2)
    }

    @Test("extended usages preserve explicit usage page")
    func extendedUsageRelativeXY() throws {
        let descriptor = Data([
            0x0B, 0x30, 0x00, 0x01, 0x00,
            0x0B, 0x31, 0x00, 0x01, 0x00,
            0x75, 0x08,
            0x95, 0x02,
            0x81, 0x06
        ])

        let result = try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)

        #expect(result.provesUnambiguousRelativeXY)
    }

    @Test("truncated short item fails closed")
    func truncatedDescriptorRejected() {
        let descriptor = Data([0x06, 0x01])

        #expect(throws: HIDReportDescriptorSemanticsError.self) {
            try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)
        }
    }

    @Test("global Pop without Push fails closed")
    func unmatchedPopRejected() {
        let descriptor = Data([0xB4])

        #expect(throws: HIDReportDescriptorSemanticsError.self) {
            try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)
        }
    }
}
