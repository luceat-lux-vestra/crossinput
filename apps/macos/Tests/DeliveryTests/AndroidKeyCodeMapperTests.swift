import Testing
@testable import Delivery
import InputDomain

struct AndroidKeyCodeMapperTests {
    @Test func preservesEveryExistingCxiV1KeyCode() {
        let expected: [SemanticKey: UInt16] = [
            .a: 29, .b: 30, .c: 31, .d: 32, .e: 33, .f: 34, .g: 35,
            .h: 36, .i: 37, .j: 38, .k: 39, .l: 40, .m: 41, .n: 42,
            .o: 43, .p: 44, .q: 45, .r: 46, .s: 47, .t: 48, .u: 49,
            .v: 50, .w: 51, .x: 52, .y: 53, .z: 54,
            .digit0: 7, .digit1: 8, .digit2: 9, .digit3: 10, .digit4: 11,
            .digit5: 12, .digit6: 13, .digit7: 14, .digit8: 15, .digit9: 16,
            .comma: 55, .period: 56,
            .tab: 61, .space: 62, .enter: 66, .backspace: 67, .grave: 68,
            .minus: 69, .equal: 70, .leftBracket: 71, .rightBracket: 72,
            .backslash: 73, .semicolon: 74, .apostrophe: 75, .slash: 76,
            .arrowUp: 19, .arrowDown: 20, .arrowLeft: 21, .arrowRight: 22,
            .pageUp: 92, .pageDown: 93, .escape: 111, .deleteForward: 112,
            .capsLock: 115, .home: 122, .end: 123, .insert: 124,
            .f1: 131, .f2: 132, .f3: 133, .f4: 134, .f5: 135, .f6: 136,
            .f7: 137, .f8: 138, .f9: 139, .f10: 140, .f11: 141, .f12: 142,
        ]

        #expect(expected.count == SemanticKey.allCases.count)
        for key in SemanticKey.allCases {
            #expect(expected[key] != nil)
            #expect(AndroidKeyCodeMapper.keyCode(for: key) == expected[key])
        }
    }

    @Test func preservesExistingAndroidMetaBits() {
        #expect(AndroidKeyCodeMapper.metaState(for: [.shift]) == 0x1)
        #expect(AndroidKeyCodeMapper.metaState(for: [.alt]) == 0x2)
        #expect(AndroidKeyCodeMapper.metaState(for: [.control]) == 0x1000)
        #expect(AndroidKeyCodeMapper.metaState(for: [.meta]) == 0x10000)
        #expect(AndroidKeyCodeMapper.metaState(for: [.shift, .meta]) == 0x10001)
        #expect(AndroidKeyCodeMapper.metaState(for: []) == 0)
    }

    @Test func preservesExistingWireActions() {
        #expect(AndroidKeyCodeMapper.action(for: .down) == 0)
        #expect(AndroidKeyCodeMapper.action(for: .up) == 1)
    }
}
