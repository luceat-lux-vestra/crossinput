import InputDomain

/// The Android/CXI boundary for semantic keyboard input.
///
/// Android KeyEvent numeric values stay here rather than leaking into host
/// capture or the semantic domain. These values intentionally preserve the
/// existing CXI v1 wire contract.
enum AndroidKeyCodeMapper {
    static func keyCode(for key: SemanticKey) -> UInt16 {
        switch key {
        case .a: return 29
        case .b: return 30
        case .c: return 31
        case .d: return 32
        case .e: return 33
        case .f: return 34
        case .g: return 35
        case .h: return 36
        case .i: return 37
        case .j: return 38
        case .k: return 39
        case .l: return 40
        case .m: return 41
        case .n: return 42
        case .o: return 43
        case .p: return 44
        case .q: return 45
        case .r: return 46
        case .s: return 47
        case .t: return 48
        case .u: return 49
        case .v: return 50
        case .w: return 51
        case .x: return 52
        case .y: return 53
        case .z: return 54
        case .digit0: return 7
        case .digit1: return 8
        case .digit2: return 9
        case .digit3: return 10
        case .digit4: return 11
        case .digit5: return 12
        case .digit6: return 13
        case .digit7: return 14
        case .digit8: return 15
        case .digit9: return 16
        case .comma: return 55
        case .period: return 56
        case .tab: return 61
        case .space: return 62
        case .enter: return 66
        case .backspace: return 67
        case .grave: return 68
        case .minus: return 69
        case .equal: return 70
        case .leftBracket: return 71
        case .rightBracket: return 72
        case .backslash: return 73
        case .semicolon: return 74
        case .apostrophe: return 75
        case .slash: return 76
        case .arrowUp: return 19
        case .arrowDown: return 20
        case .arrowLeft: return 21
        case .arrowRight: return 22
        case .pageUp: return 92
        case .pageDown: return 93
        case .escape: return 111
        case .deleteForward: return 112
        case .capsLock: return 115
        case .home: return 122
        case .end: return 123
        case .insert: return 124
        case .f1: return 131
        case .f2: return 132
        case .f3: return 133
        case .f4: return 134
        case .f5: return 135
        case .f6: return 136
        case .f7: return 137
        case .f8: return 138
        case .f9: return 139
        case .f10: return 140
        case .f11: return 141
        case .f12: return 142
        }
    }

    static func metaState(for modifiers: InputModifiers) -> UInt32 {
        var state: UInt32 = 0
        if modifiers.contains(.shift) { state |= 0x1 }
        if modifiers.contains(.alt) { state |= 0x2 }
        if modifiers.contains(.control) { state |= 0x1000 }
        if modifiers.contains(.meta) { state |= 0x10000 }
        return state
    }

    static func action(for transition: KeyTransition) -> UInt8 {
        switch transition {
        case .down: return 0
        case .up: return 1
        }
    }
}
