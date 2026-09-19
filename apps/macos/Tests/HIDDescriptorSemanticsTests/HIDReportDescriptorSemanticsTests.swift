import Foundation
import Testing
@testable import HIDDescriptorSemantics

@Suite("HID report descriptor pointer semantics")
struct HIDReportDescriptorSemanticsTests {
    @Test("canonical HID mouse X/Y are Data Variable Relative")
    func canonicalMouseRelativeXY() throws {
        let descriptor = Data([
            0x05, 0x01,       // Usage Page (Generic Desktop)
            0x09, 0x02,       // Usage (Mouse)
            0xA1, 0x01,       // Collection (Application)
            0x09, 0x01,       // Usage (Pointer)
            0xA1, 0x00,       // Collection (Physical)
            0x05, 0x09,       // Usage Page (Button)
            0x19, 0x01,       // Usage Minimum (1)
            0x29, 0x03,       // Usage Maximum (3)
            0x15, 0x00,       // Logical Minimum (0)
            0x25, 0x01,       // Logical Maximum (1)
            0x95, 0x03,       // Report Count (3)
            0x75, 0x01,       // Report Size (1)
            0x81, 0x02,       // Input (Data, Variable, Absolute)
            0x95, 0x01,       // Report Count (1)
            0x75, 0x05,       // Report Size (5)
            0x81, 0x01,       // Input (Constant)
            0x05, 0x01,       // Usage Page (Generic Desktop)
            0x09, 0x30,       // Usage (X)
            0x09, 0x31,       // Usage (Y)
            0x15, 0x81,       // Logical Minimum (-127)
            0x25, 0x7F,       // Logical Maximum (127)
            0x75, 0x08,       // Report Size (8)
            0x95, 0x02,       // Report Count (2)
            0x81, 0x06,       // Input (Data, Variable, Relative)
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

    @Test("absolute X/Y do not satisfy relative proof")
    func absoluteXYRejected() throws {
        let descriptor = Data([
            0x05, 0x01,
            0x09, 0x30,
            0x09, 0x31,
            0x75, 0x08,
            0x95, 0x02,
            0x81, 0x02        // Data, Variable, Absolute
        ])

        let result = try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)

        #expect(!result.provesUnambiguousRelativeXY)
        #expect(result.xDataVariableDeclarations.count == 1)
        #expect(result.yDataVariableDeclarations.count == 1)
        #expect(!result.xDataVariableDeclarations[0].isRelative)
        #expect(!result.yDataVariableDeclarations[0].isRelative)
    }

    @Test("usage range X through Y is recognized")
    func usageRangeRelativeXY() throws {
        let descriptor = Data([
            0x05, 0x01,       // Generic Desktop
            0x19, 0x30,       // Usage Minimum X
            0x29, 0x31,       // Usage Maximum Y
            0x75, 0x10,
            0x95, 0x02,
            0x81, 0x06        // Data, Variable, Relative
        ])

        let result = try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)

        #expect(result.provesUnambiguousRelativeXY)
    }

    @Test("local usages reset after every Main item")
    func localUsageDoesNotLeakAcrossMainItems() throws {
        let descriptor = Data([
            0x05, 0x01,
            0x09, 0x30,       // X applies to this Collection only
            0xA1, 0x00,       // Collection resets local items
            0x75, 0x08,
            0x95, 0x01,
            0x81, 0x06,       // no local X/Y usage applies here
            0xC0
        ])

        let result = try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)

        #expect(result.xDeclarations.isEmpty)
        #expect(result.yDeclarations.isEmpty)
        #expect(!result.provesUnambiguousRelativeXY)
    }

    @Test("mixed relative and absolute declarations are rejected as ambiguous")
    func mixedSemanticsRejected() throws {
        let descriptor = Data([
            0x05, 0x01,
            0x09, 0x30,
            0x75, 0x08,
            0x95, 0x01,
            0x81, 0x06,       // X relative
            0x09, 0x31,
            0x81, 0x02        // Y absolute
        ])

        let result = try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)

        #expect(!result.provesUnambiguousRelativeXY)
        #expect(result.xDataVariableDeclarations[0].isRelative)
        #expect(!result.yDataVariableDeclarations[0].isRelative)
    }

    @Test("X and Y from different report IDs do not satisfy strict proof")
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

    @Test("extended usage carries an explicit usage page")
    func extendedUsageRelativeXY() throws {
        let descriptor = Data([
            0x0B, 0x30, 0x00, 0x01, 0x00, // Usage 0x0001:0x0030 (X)
            0x0B, 0x31, 0x00, 0x01, 0x00, // Usage 0x0001:0x0031 (Y)
            0x75, 0x08,
            0x95, 0x02,
            0x81, 0x06
        ])

        let result = try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)

        #expect(result.provesUnambiguousRelativeXY)
    }

    @Test("truncated short item fails closed")
    func truncatedDescriptorRejected() {
        let descriptor = Data([0x06, 0x01]) // Usage Page declares 2-byte payload, only one byte follows

        #expect(throws: HIDReportDescriptorSemanticsError.self) {
            try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)
        }
    }

    @Test("global Pop without Push fails closed")
    func unmatchedPopRejected() {
        let descriptor = Data([0xB4]) // Global Pop, zero-byte payload

        #expect(throws: HIDReportDescriptorSemanticsError.self) {
            try HIDReportDescriptorSemantics.analyzePointerXY(descriptor: descriptor)
        }
    }
}
