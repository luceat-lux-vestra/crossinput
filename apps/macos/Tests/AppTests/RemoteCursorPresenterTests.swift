import AppKit
import XCTest
@testable import App
import EdgeSwitch

final class RemoteCursorPresenterTests: XCTestCase {
    func testCarbonThemeCursorBridgeIsAvailableOnSupportedMacOS() {
        XCTAssertTrue(
            CarbonThemeCursorBridge.shared.isAvailable,
            "SetThemeCursor must resolve before Carbon cursor presentation can ship"
        )
    }

    func testThemeCursorMappingUsesNativeAxisThemeCursor() {
        XCTAssertEqual(
            NativeRemoteCursorPresenter.themeCursor(for: .left),
            NativeRemoteCursorPresenter.themeResizeLeftRightCursor
        )
        XCTAssertEqual(
            NativeRemoteCursorPresenter.themeCursor(for: .right),
            NativeRemoteCursorPresenter.themeResizeLeftRightCursor
        )
        XCTAssertEqual(
            NativeRemoteCursorPresenter.themeCursor(for: .top),
            NativeRemoteCursorPresenter.themeResizeUpDownCursor
        )
        XCTAssertEqual(
            NativeRemoteCursorPresenter.themeCursor(for: .bottom),
            NativeRemoteCursorPresenter.themeResizeUpDownCursor
        )
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
}
