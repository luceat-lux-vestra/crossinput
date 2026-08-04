import Testing
@testable import InputCapture
import CoreGraphics

struct KeyCodeMapperTests {
    @Test func lettersMapToAndroidKeyCodes() {
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x00) == 29) // A
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x06) == 54) // Z
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x01) == 47) // S
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x0C) == 45) // Q
    }

    @Test func digitsRowMaps() {
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x12) == 8)  // 1
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x1D) == 7)  // 0
    }

    @Test func navigationMaps() {
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x33) == 67)  // delete/backspace
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x35) == 111) // escape
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x31) == 62)  // space
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x7E) == 19)  // up arrow
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x7B) == 21)  // left arrow
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x73) == 122) // home
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x77) == 123) // end
    }

    @Test func functionKeysMap() {
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x7A) == 131) // F1
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x6F) == 142) // F12
    }

    @Test func nonAnsiKeysReturnNil() {
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x6C) == nil) // volume up
        #expect(KeyCodeMapper.androidKeyCode(ofVirtualKey: 0x3F) == nil) // fn
    }

    @Test func metaStateMapsRealAndroidConstants() {
        #expect(KeyCodeMapper.androidMetaState(ofFlags: [.maskShift]) == 0x1)
        #expect(KeyCodeMapper.androidMetaState(ofFlags: [.maskAlternate]) == 0x2)
        #expect(KeyCodeMapper.androidMetaState(ofFlags: [.maskControl]) == 0x1000)
        #expect(KeyCodeMapper.androidMetaState(ofFlags: [.maskCommand]) == 0x10000)
        #expect(KeyCodeMapper.androidMetaState(ofFlags: [.maskShift, .maskCommand]) == 0x10001)
        #expect(KeyCodeMapper.androidMetaState(ofFlags: []) == 0)
    }
}