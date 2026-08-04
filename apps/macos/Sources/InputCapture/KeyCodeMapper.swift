import Foundation
import CoreGraphics

/// macOS → Android key translation (ADR-0007, KEY_EVENT semantics).
///
/// The wire format carries Android KeyEvent.KEYCODE_* values, so the Mac must
/// translate its HID virtual key codes (kVK_*) into Android key codes, and its
/// CGEventFlags into Android META_* bits. Pure functions — unit-testable.
public enum KeyCodeMapper {

    /// macOS virtual key code (kVK_*) → Android KeyEvent.KEYCODE_*.
    /// Returns nil for keys that cannot be translated (volume/media keys, etc.).
    public static func androidKeyCode(ofVirtualKey virtualKey: UInt16) -> Int? {
        switch virtualKey {
        // Letters (kVK_ANSI_A..Z)
        case 0x00: return 29 // A
        case 0x0B: return 30 // B
        case 0x08: return 31 // C
        case 0x02: return 32 // D
        case 0x0E: return 33 // E
        case 0x03: return 34 // F
        case 0x05: return 35 // G
        case 0x04: return 36 // H
        case 0x22: return 37 // I
        case 0x26: return 38 // J
        case 0x28: return 39 // K
        case 0x25: return 40 // L
        case 0x2E: return 41 // M
        case 0x2D: return 42 // N
        case 0x1F: return 43 // O
        case 0x23: return 44 // P
        case 0x0C: return 45 // Q
        case 0x0F: return 46 // R
        case 0x01: return 47 // S
        case 0x11: return 48 // T
        case 0x20: return 49 // U
        case 0x09: return 50 // V
        case 0x0D: return 51 // W
        case 0x07: return 52 // X
        case 0x10: return 53 // Y
        case 0x06: return 54 // Z
        // Digit row (kVK_ANSI_1..0)
        case 0x12: return 8  // 1
        case 0x13: return 9  // 2
        case 0x14: return 10 // 3
        case 0x15: return 11 // 4
        case 0x17: return 12 // 5
        case 0x16: return 13 // 6
        case 0x1A: return 14 // 7
        case 0x1C: return 15 // 8
        case 0x19: return 16 // 9
        case 0x1D: return 7  // 0
        // Punctuation
        case 0x1B: return 69  // minus
        case 0x18: return 70  // equals
        case 0x21: return 71  // [
        case 0x1E: return 72  // ]
        case 0x2A: return 73  // backslash
        case 0x29: return 74  // ;
        case 0x27: return 75  // '
        case 0x32: return 68  // `
        case 0x2B: return 55  // ,
        case 0x2F: return 56  // .
        case 0x2C: return 76  // /
        // Control / navigation
        case 0x24: return 66  // return
        case 0x30: return 61  // tab
        case 0x31: return 62  // space
        case 0x33: return 67  // delete (backspace)
        case 0x35: return 111 // escape
        case 0x39: return 115 // caps lock
        case 0x75: return 112 // forward delete
        case 0x72: return 124 // help (= insert)
        case 0x73: return 122 // home
        case 0x77: return 123 // end
        case 0x74: return 92  // page up
        case 0x79: return 93  // page down
        case 0x7B: return 21  // left arrow
        case 0x7C: return 22  // right arrow
        case 0x7D: return 20  // down arrow
        case 0x7E: return 19  // up arrow
        // Function keys
        case 0x7A: return 131 // F1
        case 0x78: return 132 // F2
        case 0x63: return 133 // F3
        case 0x76: return 134 // F4
        case 0x60: return 135 // F5
        case 0x61: return 136 // F6
        case 0x62: return 137 // F7
        case 0x64: return 138 // F8
        case 0x65: return 139 // F9
        case 0x6D: return 140 // F10
        case 0x67: return 141 // F11
        case 0x6F: return 142 // F12
        default: return nil
        }
    }

    /// CGEventFlags → Android KeyEvent.META_* bits (real Android constants:
    /// Shift=0x1, Alt=0x2, Ctrl=0x1000, Meta=0x10000).
    public static func androidMetaState(ofFlags flags: CGEventFlags) -> UInt32 {
        var meta: UInt32 = 0
        if flags.contains(.maskShift) { meta |= 0x1 }
        if flags.contains(.maskAlternate) { meta |= 0x2 }
        if flags.contains(.maskControl) { meta |= 0x1000 }
        if flags.contains(.maskCommand) { meta |= 0x10000 }
        return meta
    }
}
