import Foundation
import CoreGraphics
import InputDomain

/// macOS host adapter for semantic keyboard input.
///
/// This mapper knows macOS virtual-key codes and CGEventFlags only. Android
/// KeyEvent constants and CXI wire values belong to the remote adapter.
public enum KeyCodeMapper {

    /// macOS virtual key code (kVK_*) -> platform-neutral semantic key.
    /// Returns nil for unsupported keys (volume/media keys, etc.).
    public static func semanticKey(ofVirtualKey virtualKey: UInt16) -> SemanticKey? {
        switch virtualKey {
        // Letters (kVK_ANSI_A..Z)
        case 0x00: return .a
        case 0x0B: return .b
        case 0x08: return .c
        case 0x02: return .d
        case 0x0E: return .e
        case 0x03: return .f
        case 0x05: return .g
        case 0x04: return .h
        case 0x22: return .i
        case 0x26: return .j
        case 0x28: return .k
        case 0x25: return .l
        case 0x2E: return .m
        case 0x2D: return .n
        case 0x1F: return .o
        case 0x23: return .p
        case 0x0C: return .q
        case 0x0F: return .r
        case 0x01: return .s
        case 0x11: return .t
        case 0x20: return .u
        case 0x09: return .v
        case 0x0D: return .w
        case 0x07: return .x
        case 0x10: return .y
        case 0x06: return .z
        // Digit row (kVK_ANSI_1..0)
        case 0x12: return .digit1
        case 0x13: return .digit2
        case 0x14: return .digit3
        case 0x15: return .digit4
        case 0x17: return .digit5
        case 0x16: return .digit6
        case 0x1A: return .digit7
        case 0x1C: return .digit8
        case 0x19: return .digit9
        case 0x1D: return .digit0
        // Punctuation
        case 0x1B: return .minus
        case 0x18: return .equal
        case 0x21: return .leftBracket
        case 0x1E: return .rightBracket
        case 0x2A: return .backslash
        case 0x29: return .semicolon
        case 0x27: return .apostrophe
        case 0x32: return .grave
        case 0x2B: return .comma
        case 0x2F: return .period
        case 0x2C: return .slash
        // Control / navigation
        case 0x24: return .enter
        case 0x30: return .tab
        case 0x31: return .space
        case 0x33: return .backspace
        case 0x35: return .escape
        case 0x39: return .capsLock
        case 0x75: return .deleteForward
        case 0x72: return .insert
        case 0x73: return .home
        case 0x77: return .end
        case 0x74: return .pageUp
        case 0x79: return .pageDown
        case 0x7B: return .arrowLeft
        case 0x7C: return .arrowRight
        case 0x7D: return .arrowDown
        case 0x7E: return .arrowUp
        // Function keys
        case 0x7A: return .f1
        case 0x78: return .f2
        case 0x63: return .f3
        case 0x76: return .f4
        case 0x60: return .f5
        case 0x61: return .f6
        case 0x62: return .f7
        case 0x64: return .f8
        case 0x65: return .f9
        case 0x6D: return .f10
        case 0x67: return .f11
        case 0x6F: return .f12
        default: return nil
        }
    }

    /// CGEventFlags -> platform-neutral modifier state.
    public static func semanticModifiers(ofFlags flags: CGEventFlags) -> InputModifiers {
        var modifiers: InputModifiers = []
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { modifiers.insert(.alt) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskCommand) { modifiers.insert(.meta) }
        return modifiers
    }
}
