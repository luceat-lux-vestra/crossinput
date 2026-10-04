import AppKit
import XCTest
@testable import App
import EdgeSwitch

final class RemoteCursorPresenterTests: XCTestCase {
    @MainActor
    func testRemoteCursorAuthorityPanelCanBecomeKeyWithoutActivationStyle() {
        let panel = RemoteCursorAuthorityPanel(
            contentRect: NSRect(x: 0, y: 0, width: 48, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }

    @MainActor
    func testRemoteCursorViewRequestsPanelKeyAuthority() {
        let view = RemoteCursorRectView(cursor: .resizeLeftRight)
        XCTAssertTrue(view.acceptsFirstResponder)
        XCTAssertTrue(view.needsPanelToBecomeKey)
    }

    func testDirectionalCursorMappingUsesNativeAxisCursor() {
        XCTAssertTrue(
            NativeRemoteCursorPresenter.cursorAppearanceMatches(
                NativeRemoteCursorPresenter.cursor(for: .left),
                .resizeLeftRight
            )
        )
        XCTAssertTrue(
            NativeRemoteCursorPresenter.cursorAppearanceMatches(
                NativeRemoteCursorPresenter.cursor(for: .right),
                .resizeLeftRight
            )
        )
        XCTAssertTrue(
            NativeRemoteCursorPresenter.cursorAppearanceMatches(
                NativeRemoteCursorPresenter.cursor(for: .top),
                .resizeUpDown
            )
        )
        XCTAssertTrue(
            NativeRemoteCursorPresenter.cursorAppearanceMatches(
                NativeRemoteCursorPresenter.cursor(for: .bottom),
                .resizeUpDown
            )
        )
    }

    func testCursorAppearanceMatcherRejectsDifferentNativeCursor() {
        XCTAssertFalse(
            NativeRemoteCursorPresenter.cursorAppearanceMatches(
                .arrow,
                .resizeLeftRight
            )
        )
    }

    func testPresentationFrameClampsAroundScreenEdges() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)

        XCTAssertEqual(
            NativeRemoteCursorPresenter.presentationFrame(
                around: NSPoint(x: 0, y: 400),
                in: screen
            ),
            NSRect(x: 0, y: 376, width: 48, height: 48)
        )
        XCTAssertEqual(
            NativeRemoteCursorPresenter.presentationFrame(
                around: NSPoint(x: 1000, y: 400),
                in: screen
            ),
            NSRect(x: 952, y: 376, width: 48, height: 48)
        )
    }
}
