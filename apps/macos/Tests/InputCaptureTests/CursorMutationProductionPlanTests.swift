import CoreGraphics
import XCTest
@testable import InputCapture

final class CursorMutationProductionPlanTests: XCTestCase {
    func testHoldConvertsNegativeOriginDisplayToLocalCoordinates() {
        let displayID = CGDirectDisplayID(42)
        let frame = CGRect(x: -1920, y: -120, width: 1920, height: 1080)
        let globalPoint = CGPoint(x: -2, y: 500)

        let mutation = CursorMutationExecutor.productionMutation(
            kind: .hold,
            globalPoint: globalPoint,
            displayResolver: { point in
                XCTAssertEqual(point, globalPoint)
                return (displayID, frame)
            }
        )

        XCTAssertEqual(
            mutation,
            .displayLocal(
                displayID: displayID,
                point: CGPoint(x: 1918, y: 620)
            )
        )
    }

    func testHoldConvertsPositiveOffsetDisplayToLocalCoordinates() {
        let displayID = CGDirectDisplayID(7)
        let frame = CGRect(x: 900, y: 2160, width: 2454, height: 1586)
        let globalPoint = CGPoint(x: 902, y: 2162)

        let mutation = CursorMutationExecutor.productionMutation(
            kind: .hold,
            globalPoint: globalPoint,
            displayResolver: { _ in (displayID, frame) }
        )

        XCTAssertEqual(
            mutation,
            .displayLocal(
                displayID: displayID,
                point: CGPoint(x: 2, y: 2)
            )
        )
    }

    func testRestoreRemainsGlobalWarpWithoutDisplayResolution() {
        let globalPoint = CGPoint(x: -50, y: 1200)
        var resolverCalled = false

        let mutation = CursorMutationExecutor.productionMutation(
            kind: .restore,
            globalPoint: globalPoint,
            displayResolver: { _ in
                resolverCalled = true
                return nil
            }
        )

        XCTAssertFalse(resolverCalled)
        XCTAssertEqual(mutation, .globalWarp(point: globalPoint))
    }

    func testUnresolvedHoldDoesNotFallbackToGlobalWarp() {
        let mutation = CursorMutationExecutor.productionMutation(
            kind: .hold,
            globalPoint: CGPoint(x: 1, y: 1),
            displayResolver: { _ in nil }
        )

        XCTAssertNil(mutation)
    }
}
