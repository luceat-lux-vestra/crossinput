import Testing
@testable import InputCapture
import InputDomain
import CoreGraphics

struct KeyCodeMapperTests {
    @Test func lettersMapToSemanticKeys() {
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x00) == .a)
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x06) == .z)
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x01) == .s)
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x0C) == .q)
    }

    @Test func digitsRowMaps() {
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x12) == .digit1)
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x1D) == .digit0)
    }

    @Test func navigationMaps() {
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x33) == .backspace)
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x35) == .escape)
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x31) == .space)
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x7E) == .arrowUp)
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x7B) == .arrowLeft)
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x73) == .home)
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x77) == .end)
    }

    @Test func functionKeysMap() {
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x7A) == .f1)
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x6F) == .f12)
    }

    @Test func nonAnsiKeysReturnNil() {
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x6C) == nil)
        #expect(KeyCodeMapper.semanticKey(ofVirtualKey: 0x3F) == nil)
    }

    @Test func modifiersStayPlatformNeutral() {
        #expect(KeyCodeMapper.semanticModifiers(ofFlags: [.maskShift]) == [.shift])
        #expect(KeyCodeMapper.semanticModifiers(ofFlags: [.maskAlternate]) == [.alt])
        #expect(KeyCodeMapper.semanticModifiers(ofFlags: [.maskControl]) == [.control])
        #expect(KeyCodeMapper.semanticModifiers(ofFlags: [.maskCommand]) == [.meta])
        #expect(KeyCodeMapper.semanticModifiers(ofFlags: [.maskShift, .maskCommand]) == [.shift, .meta])
        #expect(KeyCodeMapper.semanticModifiers(ofFlags: []) == [])
    }
}
