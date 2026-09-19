import Testing
@testable import InputDomain

struct InputEventTests {
    @Test func semanticKeyEventHasNoPlatformEncoding() {
        let event = SemanticKeyEvent(
            key: .a,
            modifiers: [.shift, .meta],
            transition: .down,
            repeatCount: 1
        )

        #expect(event.key == .a)
        #expect(event.modifiers == [.shift, .meta])
        #expect(event.transition == .down)
        #expect(event.repeatCount == 1)
    }

    @Test func pointerSemanticsArePlatformNeutral() {
        #expect(SemanticPointerEvent(.move(dx: 3, dy: -2)).kind == .move(dx: 3, dy: -2))
        #expect(SemanticPointerEvent(.button(button: 1, down: true)).kind == .button(button: 1, down: true))
        #expect(SemanticPointerEvent(.scroll(horizontal: 1.5, vertical: -2.5)).kind == .scroll(horizontal: 1.5, vertical: -2.5))
    }
}
