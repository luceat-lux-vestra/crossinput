/// Platform-neutral input semantics shared by host capture and remote delivery.
///
/// This module intentionally knows nothing about CoreGraphics/AppKit, Android
/// KeyEvent constants, CXI framing, UHID, or InputManager.
public struct SemanticPointerEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case move(dx: Int32, dy: Int32)
        case button(button: UInt32, down: Bool)
        case scroll(horizontal: Float, vertical: Float)
    }

    public let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }
}

public enum SemanticKey: Sendable, Hashable, CaseIterable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    case digit0, digit1, digit2, digit3, digit4
    case digit5, digit6, digit7, digit8, digit9
    case minus, equal
    case leftBracket, rightBracket, backslash
    case semicolon, apostrophe, grave
    case comma, period, slash
    case enter, tab, space, backspace, escape, capsLock
    case deleteForward, insert, home, end, pageUp, pageDown
    case arrowLeft, arrowRight, arrowDown, arrowUp
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
}

public struct InputModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift = InputModifiers(rawValue: 1 << 0)
    public static let alt = InputModifiers(rawValue: 1 << 1)
    public static let control = InputModifiers(rawValue: 1 << 2)
    public static let meta = InputModifiers(rawValue: 1 << 3)
}

public enum KeyTransition: Sendable, Equatable {
    case down
    case up
}

public struct SemanticKeyEvent: Sendable, Equatable {
    public let key: SemanticKey
    public let modifiers: InputModifiers
    public let transition: KeyTransition
    public let repeatCount: UInt8

    public init(
        key: SemanticKey,
        modifiers: InputModifiers,
        transition: KeyTransition,
        repeatCount: UInt8 = 0
    ) {
        self.key = key
        self.modifiers = modifiers
        self.transition = transition
        self.repeatCount = repeatCount
    }
}
