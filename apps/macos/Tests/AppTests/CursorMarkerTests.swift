import CoreGraphics
import XCTest
@testable import App
import Delivery
import EdgeSwitch

@MainActor
final class CursorMarkerTests: XCTestCase {
    func testMarkerAbsentOutsideActiveOwnershipAndVisibleWhileArming() {
        let displays = [display(1, .left)]

        XCTAssertEqual(
            CursorMarkerPresentationState.derive(
                controlState: .local,
                sessionState: .ready,
                entryEdge: .left,
                hostDisplays: displays),
            .hidden)
        XCTAssertEqual(
            CursorMarkerPresentationState.derive(
                controlState: .arming(.left),
                sessionState: .ready,
                entryEdge: .left,
                hostDisplays: displays),
            .visible(displayID: 1, edge: .left))
        XCTAssertEqual(
            CursorMarkerPresentationState.derive(
                controlState: .returning,
                sessionState: .ready,
                entryEdge: .left,
                hostDisplays: displays),
            .hidden)
        XCTAssertEqual(
            CursorMarkerPresentationState.derive(
                controlState: .remote,
                sessionState: .reconnecting,
                entryEdge: .left,
                hostDisplays: displays),
            .hidden)
    }

    func testRemoteOwnershipSelectsConfiguredHostDisplayForEveryEdge() {
        let displays = [
            display(11, .left),
            display(22, .right),
            display(33, .top),
            display(44, .bottom),
        ]

        for edge in ScreenEdge.allCases {
            XCTAssertEqual(
                CursorMarkerPresentationState.derive(
                    controlState: .remote,
                    sessionState: .ready,
                    entryEdge: edge,
                    hostDisplays: displays),
                .visible(displayID: displayID(for: edge), edge: edge))
        }
    }

    func testConfiguredDisplaySelectionDoesNotUseCurrentPointerDisplay() {
        let displays = [display(1, .left), display(5, nil)]

        XCTAssertEqual(
            CursorMarkerPresentationState.derive(
                controlState: .remote,
                sessionState: .ready,
                entryEdge: .left,
                hostDisplays: displays),
            .visible(displayID: 1, edge: .left))
    }

    func testAmbiguousDuplicateEdgeFailsClosedInsteadOfChoosingWrongDisplay() {
        let displays = [display(1, .left), display(5, .left)]

        XCTAssertEqual(
            CursorMarkerPresentationState.derive(
                controlState: .remote,
                sessionState: .ready,
                entryEdge: .left,
                hostDisplays: displays),
            .hidden)
    }

    func testUnavailableFailureAndEmergencyReturnAreHidden() {
        let displays = [display(1, .left)]

        for sessionState in [SessionState.disconnected, .failed("helper ended")] {
            XCTAssertEqual(
                CursorMarkerPresentationState.derive(
                    controlState: .remote,
                    sessionState: sessionState,
                    entryEdge: .left,
                    hostDisplays: displays),
                .hidden)
        }

        XCTAssertEqual(
            CursorMarkerPresentationState.derive(
                controlState: .returning,
                sessionState: .ready,
                entryEdge: .left,
                hostDisplays: displays),
            .hidden)
    }

    func testRemoteUnavailableRemovesMarkerAndReconnectStartsFresh() {
        let sink = RecordingSink()
        let controller = CursorMarkerController(sink: sink)
        let displays = [display(1, .left)]

        controller.update(
            controlState: .remote,
            sessionState: .ready,
            entryEdge: .left,
            hostDisplays: displays)
        controller.update(
            controlState: .remote,
            sessionState: .failed("helper ended"),
            entryEdge: .left,
            hostDisplays: displays)
        controller.update(
            controlState: .remote,
            sessionState: .reconnecting,
            entryEdge: .left,
            hostDisplays: displays)
        controller.update(
            controlState: .remote,
            sessionState: .ready,
            entryEdge: .left,
            hostDisplays: displays)

        XCTAssertEqual(sink.rendered, [
            .visible(displayID: 1, edge: .left),
            .hidden,
            .visible(displayID: 1, edge: .left),
        ])
    }

    func testEdgeChangesUpdateDirectionAndDisplay() {
        let controller = CursorMarkerController(sink: RecordingSink())
        let displays = [display(1, .left), display(2, .right)]

        controller.update(
            controlState: .remote,
            sessionState: .ready,
            entryEdge: .left,
            hostDisplays: displays)
        XCTAssertEqual(controller.state, .visible(displayID: 1, edge: .left))

        controller.update(
            controlState: .remote,
            sessionState: .ready,
            entryEdge: .right,
            hostDisplays: displays)
        XCTAssertEqual(controller.state, .visible(displayID: 2, edge: .right))
    }

    func testReconcileRendersSameDisplayAndEdgeAfterScreenGeometryRefresh() {
        let sink = RecordingSink()
        let controller = CursorMarkerController(sink: sink)
        let initialDisplays = [display(1, .left)]
        let refreshedDisplays = [
            HostDisplayEdgeOption(
                id: 1,
                name: "Display 1",
                width: 2560,
                height: 1440,
                edge: .left),
        ]

        controller.update(
            controlState: .remote,
            sessionState: .ready,
            entryEdge: .left,
            hostDisplays: initialDisplays)
        controller.reconcile(
            controlState: .remote,
            sessionState: .ready,
            entryEdge: .left,
            hostDisplays: refreshedDisplays)

        XCTAssertEqual(controller.state, .visible(displayID: 1, edge: .left))
        XCTAssertEqual(sink.rendered, [
            .visible(displayID: 1, edge: .left),
            .visible(displayID: 1, edge: .left),
        ])
    }

    func testRepeatedCyclesDoNotCreateDuplicatePresentationStates() {
        let sink = RecordingSink()
        let controller = CursorMarkerController(sink: sink)
        let displays = [display(1, .left)]

        for _ in 0..<3 {
            controller.update(
                controlState: .remote,
                sessionState: .ready,
                entryEdge: .left,
                hostDisplays: displays)
            controller.update(
                controlState: .local,
                sessionState: .ready,
                entryEdge: .left,
                hostDisplays: displays)
        }

        XCTAssertEqual(sink.rendered, [
            .visible(displayID: 1, edge: .left),
            .hidden,
            .visible(displayID: 1, edge: .left),
            .hidden,
            .visible(displayID: 1, edge: .left),
            .hidden,
        ])
    }

    func testTeardownIsIdempotentAndRemovesVisibleMarker() {
        let sink = RecordingSink()
        let controller = CursorMarkerController(sink: sink)
        let displays = [display(1, .left)]
        controller.update(
            controlState: .remote,
            sessionState: .ready,
            entryEdge: .left,
            hostDisplays: displays)

        controller.teardown()
        controller.teardown()

        XCTAssertEqual(controller.state, .hidden)
        XCTAssertEqual(sink.teardownCount, 2)
    }

    func testMarkerWindowGeometryStaysOnTheConfiguredDisplay() {
        let screen = CGRect(x: 100, y: 200, width: 1920, height: 1080)

        for edge in ScreenEdge.allCases {
            let marker = CursorMarkerWindowGeometry.frame(for: edge, in: screen)
            XCTAssertTrue(screen.contains(marker), "marker escaped \(edge) display")
        }
    }

    func testMarkerDirectionPointsIntoTheHostDisplay() {
        XCTAssertEqual(CursorMarkerDirection(edge: .left), .right)
        XCTAssertEqual(CursorMarkerDirection(edge: .right), .left)
        XCTAssertEqual(CursorMarkerDirection(edge: .top), .down)
        XCTAssertEqual(CursorMarkerDirection(edge: .bottom), .up)
    }

    private func display(_ id: CGDirectDisplayID, _ edge: ScreenEdge?) -> HostDisplayEdgeOption {
        HostDisplayEdgeOption(id: id, name: "Display \(id)", width: 1920, height: 1080, edge: edge)
    }

    private func displayID(for edge: ScreenEdge) -> CGDirectDisplayID {
        switch edge {
        case .left: return 11
        case .right: return 22
        case .top: return 33
        case .bottom: return 44
        }
    }

    private final class RecordingSink: CursorMarkerRenderSink {
        var rendered: [CursorMarkerPresentationState] = []
        var teardownCount = 0

        func render(_ state: CursorMarkerPresentationState) {
            rendered.append(state)
        }

        func teardown() {
            teardownCount += 1
        }
    }
}
