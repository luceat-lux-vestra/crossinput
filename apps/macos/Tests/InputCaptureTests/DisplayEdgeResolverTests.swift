import CoreGraphics
import XCTest
@testable import EdgeSwitch
@testable import InputCapture

final class DisplayEdgeResolverTests: XCTestCase {
    private let threshold: CGFloat = 2

    private let displayA = CGRect(x: 0, y: 0, width: 100, height: 100)
    private let displayB = CGRect(x: 100, y: 0, width: 100, height: 100)

    private func configuration(
        id: CGDirectDisplayID,
        frame: CGRect,
        edge: ScreenEdge?
    ) -> DisplayEdgeConfiguration {
        DisplayEdgeConfiguration(displayID: id, frame: frame, configuredEdge: edge)
    }

    func testConfiguredEdgeOnlyBelongsToTheConfiguredDisplay() {
        let displays = [
            configuration(id: 10, frame: displayA, edge: .left),
            configuration(id: 11, frame: displayB, edge: nil),
        ]

        XCTAssertEqual(
            DisplayEdgeResolver.candidate(at: CGPoint(x: 1, y: 50), displays: displays, threshold: threshold),
            DisplayEdgeCandidate(displayID: 10, edge: .left)
        )
        XCTAssertNil(DisplayEdgeResolver.candidate(
            at: CGPoint(x: 101, y: 50), displays: displays, threshold: threshold
        ))
        XCTAssertNil(DisplayEdgeResolver.candidate(
            at: CGPoint(x: 199, y: 50), displays: displays, threshold: threshold
        ))
    }

    func testGapAndOutOfFrameCoordinatesFailSafe() {
        let displays = [
            configuration(id: 10, frame: CGRect(x: 0, y: 0, width: 100, height: 100), edge: .left),
            configuration(id: 11, frame: CGRect(x: 100, y: 40, width: 100, height: 100), edge: .right),
        ]

        XCTAssertNil(DisplayEdgeResolver.candidate(
            at: CGPoint(x: 50, y: 120), displays: displays, threshold: threshold
        ))
        XCTAssertNil(DisplayEdgeResolver.candidate(
            at: CGPoint(x: -1, y: 50), displays: displays, threshold: threshold
        ))
    }

    func testTransitionToNonTargetDisplayCannotReusePreviousTargetState() {
        let displays = [
            configuration(id: 10, frame: displayA, edge: .left),
            configuration(id: 11, frame: displayB, edge: nil),
        ]

        let first = DisplayEdgeResolver.candidate(
            at: CGPoint(x: 1, y: 50), displays: displays, threshold: threshold
        )
        let second = DisplayEdgeResolver.candidate(
            at: CGPoint(x: 101, y: 50), displays: displays, threshold: threshold
        )

        XCTAssertEqual(first?.displayID, 10)
        XCTAssertNil(second)
    }

    func testConfiguredDisplayTransitionRetainsNormalHandoff() {
        let displays = [
            configuration(id: 10, frame: displayA, edge: .left),
            configuration(id: 11, frame: displayB, edge: .right),
        ]

        XCTAssertNil(DisplayEdgeResolver.candidate(
            at: CGPoint(x: 101, y: 50), displays: displays, threshold: threshold
        ))
        XCTAssertEqual(
            DisplayEdgeResolver.candidate(at: CGPoint(x: 1, y: 50), displays: displays, threshold: threshold),
            DisplayEdgeCandidate(displayID: 10, edge: .left)
        )
    }

    func testSingleDisplayEdgeRegression() {
        let displays = [configuration(id: 10, frame: displayA, edge: .left)]

        XCTAssertEqual(
            DisplayEdgeResolver.candidate(at: CGPoint(x: 1, y: 50), displays: displays, threshold: threshold),
            DisplayEdgeCandidate(displayID: 10, edge: .left)
        )
        XCTAssertNil(DisplayEdgeResolver.candidate(
            at: CGPoint(x: 50, y: 50), displays: displays, threshold: threshold
        ))
    }

    func testQuartzCoordinatesForDisplayBelowPrimaryRetainConfiguredEdge() {
        // Quartz places this non-primary display at a larger positive Y.
        // AppKit represents the same display with a different global frame,
        // so passing an NSScreen frame to this event-coordinate resolver cannot
        // match.
        let displayBelowPrimary = CGRect(x: 900, y: 2160, width: 2454, height: 1586)
        let displays = [configuration(id: 1, frame: displayBelowPrimary, edge: .left)]

        XCTAssertEqual(
            DisplayEdgeResolver.candidate(
                at: CGPoint(x: 901, y: 2800),
                displays: displays,
                threshold: threshold),
            DisplayEdgeCandidate(displayID: 1, edge: .left)
        )

        XCTAssertEqual(
            DisplayEdgeResolver.candidate(
                at: CGPoint(x: 2100, y: displayBelowPrimary.minY + 1),
                displays: [configuration(id: 1, frame: displayBelowPrimary, edge: .top)],
                threshold: threshold),
            DisplayEdgeCandidate(displayID: 1, edge: .top)
        )
        XCTAssertEqual(
            DisplayEdgeResolver.candidate(
                at: CGPoint(x: 2100, y: displayBelowPrimary.maxY - 1),
                displays: [configuration(id: 1, frame: displayBelowPrimary, edge: .bottom)],
                threshold: threshold),
            DisplayEdgeCandidate(displayID: 1, edge: .bottom)
        )
        XCTAssertNil(DisplayEdgeResolver.candidate(
            at: CGPoint(x: 2100, y: displayBelowPrimary.midY),
            displays: [configuration(id: 1, frame: displayBelowPrimary, edge: .top)],
            threshold: threshold))
    }

    func testQuartzTopAndBottomSemantics() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)

        XCTAssertEqual(
            DisplayEdgeResolver.candidate(
                at: CGPoint(x: 50, y: 1),
                displays: [configuration(id: 10, frame: frame, edge: .top)],
                threshold: threshold),
            DisplayEdgeCandidate(displayID: 10, edge: .top))
        XCTAssertNil(DisplayEdgeResolver.candidate(
            at: CGPoint(x: 50, y: 1),
            displays: [configuration(id: 10, frame: frame, edge: .bottom)],
            threshold: threshold))

        XCTAssertEqual(
            DisplayEdgeResolver.candidate(
                at: CGPoint(x: 50, y: 99),
                displays: [configuration(id: 10, frame: frame, edge: .bottom)],
                threshold: threshold),
            DisplayEdgeCandidate(displayID: 10, edge: .bottom))
        XCTAssertNil(DisplayEdgeResolver.candidate(
            at: CGPoint(x: 50, y: 99),
            displays: [configuration(id: 10, frame: frame, edge: .top)],
            threshold: threshold))
    }

    func testPointerPositionUsesQuartzVerticalSemantics() {
        let frame = CGRect(x: 900, y: 2160, width: 2454, height: 1586)
        let location = CGPoint(x: 2100, y: frame.midY)

        XCTAssertEqual(
            DisplayEdgeResolver.pointerPosition(
                for: .top, in: frame, at: location, threshold: threshold),
            CGPoint(x: 2100, y: frame.minY + threshold))
        XCTAssertEqual(
            DisplayEdgeResolver.pointerPosition(
                for: .bottom, in: frame, at: location, threshold: threshold),
            CGPoint(x: 2100, y: frame.maxY - threshold))
        XCTAssertEqual(
            DisplayEdgeResolver.pointerPosition(
                for: .left, in: frame, at: location, threshold: threshold),
            CGPoint(x: frame.minX + threshold, y: frame.midY))
        XCTAssertEqual(
            DisplayEdgeResolver.pointerPosition(
                for: .right, in: frame, at: location, threshold: threshold),
            CGPoint(x: frame.maxX - threshold, y: frame.midY))
    }
}
