import Testing
@testable import Delivery
import InputDomain

struct AndroidKeyCodeMapperTests {
    @Test func preservesExistingCxiV1KeyCodes() {
        #expect(AndroidKeyCodeMapper.keyCode(for: .a) == 29)
        #expect(AndroidKeyCodeMapper.keyCode(for: .z) == 54)
        #expect(AndroidKeyCodeMapper.keyCode(for: .digit1) == 8)
        #expect(AndroidKeyCodeMapper.keyCode(for: .digit0) == 7)
        #expect(AndroidKeyCodeMapper.keyCode(for: .backspace) == 67)
        #expect(AndroidKeyCodeMapper.keyCode(for: .escape) == 111)
        #expect(AndroidKeyCodeMapper.keyCode(for: .arrowUp) == 19)
        #expect(AndroidKeyCodeMapper.keyCode(for: .f1) == 131)
        #expect(AndroidKeyCodeMapper.keyCode(for: .f12) == 142)
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

    @Test func everySemanticKeyHasAnAndroidEncoding() {
        for key in SemanticKey.allCases {
            #expect(AndroidKeyCodeMapper.keyCode(for: key) > 0)
        }
    }
}
