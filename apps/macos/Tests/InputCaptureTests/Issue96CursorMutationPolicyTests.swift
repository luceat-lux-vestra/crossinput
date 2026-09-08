import CoreGraphics
import XCTest
@testable import InputCapture

private final class Issue96MutationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedKinds: [CursorMutationExecutor.Kind] = []
    private var recordedPoints: [CGPoint] = []

    func record(kind: CursorMutationExecutor.Kind, point: CGPoint) {
        lock.withLock {
            recordedKinds.append(kind)
            recordedPoints.append(point)
        }
    }

    var kinds: [CursorMutationExecutor.Kind] {
        lock.withLock { recordedKinds }
    }

    var points: [CGPoint] {
        lock.withLock { recordedPoints }
    }
}

private final class Issue96ForwardedMovementObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [UInt64] = []
    private var deltas: [(Int32, Int32)] = []

    func record(event: PointerEvent, generation: UInt64) {
        guard case let .move(dx, dy) = event.kind else { return }
        lock.withLock {
            generations.append(generation)
            deltas.append((dx, dy))
        }
    }

    var generationValues: [UInt64] {
        lock.withLock { generations }
    }

    var deltaValues: [(Int32, Int32)] {
        lock.withLock { deltas }
    }
}

private func issue96MoveEvent(at point: CGPoint, dx: Int64, dy: Int64) -> CGEvent {
    let event = CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
    )!
    event.setIntegerValueField(.mouseEventDeltaX, value: dx)
    event.setIntegerValueField(.mouseEventDeltaY, value: dy)
    return event
}

/// Issue #96 proof obligations for the no-repeated-warp architecture.
///
/// These tests deliberately inject the platform mutation so they verify the
/// number and coordinates of physical cursor mutations without moving the real
/// test runner's pointer.
final class Issue96CursorMutationPolicyTests: XCTestCase {
    private var owners: [InputCaptureTestOwner] = []
    private var captures: [InputCapture] = []

    override func tearDown() {
        captures.forEach { $0.release(reason: .externalControl) }
        owners.forEach { $0.stop() }
        captures.removeAll()
        owners.removeAll()
        super.tearDown()
    }

    private func makeExecutor(
        observation: Issue96MutationObservation
    ) -> CursorMutationExecutor {
        CursorMutationExecutor { kind, point in
            observation.record(kind: kind, point: point)
        }
    }

    private func own(_ executor: CursorMutationExecutor) {
        owners.append(InputCaptureTestOwner(executor: executor))
    }

    func testRepeatedHoldRequestsPhysicallyParkOnceAndRestoreToFirstAnchor() {
        let observation = Issue96MutationObservation()
        let executor = makeExecutor(observation: observation)
        own(executor)

        let first = CGPoint(x: 100, y: 200)
        let second = CGPoint(x: 100, y: 260)
        let third = CGPoint(x: 100, y: 320)
        let mutableLastEventRestoreRequest = CGPoint(x: 100, y: 999)

        XCTAssertTrue(executor.beginOwnership(generation: 1))
        XCTAssertTrue(executor.perform(kind: .hold, generation: 1, point: first))
        XCTAssertTrue(executor.perform(kind: .hold, generation: 1, point: second))
        XCTAssertTrue(executor.perform(kind: .hold, generation: 1, point: third))

        XCTAssertEqual(observation.kinds, [.hold],
                       "steady remote movement must not create repeated Quartz warps")
        XCTAssertEqual(observation.points, [first])

        XCTAssertTrue(executor.endOwnership(generation: 1))
        XCTAssertTrue(executor.perform(
            kind: .restore,
            generation: 1,
            point: mutableLastEventRestoreRequest
        ))

        XCTAssertEqual(observation.kinds, [.hold, .restore])
        XCTAssertEqual(observation.points, [first, first],
                       "return must use the first generation-owned park point, not mutable last-event position")
    }

    func testInputCaptureStillConsumesAndForwardsEveryMoveWhileWarpCountStaysOne() {
        let mutationObservation = Issue96MutationObservation()
        let forwarded = Issue96ForwardedMovementObservation()
        let executor = makeExecutor(observation: mutationObservation)
        own(executor)

        let capture = InputCapture(cursorMutationExecutor: executor)
        captures.append(capture)
        capture.onPointerEventWithGeneration = { event, generation in
            forwarded.record(event: event, generation: generation)
        }

        let displayID = CGMainDisplayID()
        let frame = CGDisplayBounds(displayID)
        capture.setAndroidEdge(.left, forDisplay: displayID)
        XCTAssertEqual(capture.suppress(), 1)

        let points = [
            CGPoint(x: frame.midX, y: frame.midY - 40),
            CGPoint(x: frame.midX, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.midY + 40),
        ]
        let deltas: [(Int64, Int64)] = [(4, 1), (6, -2), (-3, 5)]

        for (point, delta) in zip(points, deltas) {
            let event = issue96MoveEvent(at: point, dx: delta.0, dy: delta.1)
            XCTAssertNil(capture.handleForTesting(type: .mouseMoved, event: event),
                         "suppressed movement must remain consumed")
        }

        XCTAssertEqual(forwarded.generationValues, [1, 1, 1],
                       "all physical movement must remain generation-tagged and forwarded")
        XCTAssertEqual(forwarded.deltaValues.map { $0.0 }, [4, 6, -3])
        XCTAssertEqual(forwarded.deltaValues.map { $0.1 }, [1, -2, 5])
        XCTAssertEqual(mutationObservation.kinds, [.hold],
                       "three suppressed moves must produce exactly one physical edge park")

        let expectedFirstAnchor = DisplayEdgeResolver.pointerPosition(
            for: .left,
            in: frame,
            at: points[0],
            threshold: 2
        )
        XCTAssertEqual(mutationObservation.points, [expectedFirstAnchor])
    }

    func testNewGenerationGetsIndependentSingleParkAnchor() {
        let observation = Issue96MutationObservation()
        let executor = makeExecutor(observation: observation)
        own(executor)

        let firstGenerationAnchor = CGPoint(x: 10, y: 20)
        let secondGenerationAnchor = CGPoint(x: 30, y: 40)

        XCTAssertTrue(executor.beginOwnership(generation: 1))
        XCTAssertTrue(executor.perform(kind: .hold, generation: 1, point: firstGenerationAnchor))
        XCTAssertTrue(executor.perform(kind: .hold, generation: 1, point: CGPoint(x: 11, y: 21)))
        XCTAssertTrue(executor.endOwnership(generation: 1))
        XCTAssertTrue(executor.perform(kind: .restore, generation: 1, point: .zero))

        XCTAssertTrue(executor.beginOwnership(generation: 2))
        XCTAssertTrue(executor.perform(kind: .hold, generation: 2, point: secondGenerationAnchor))
        XCTAssertTrue(executor.perform(kind: .hold, generation: 2, point: CGPoint(x: 31, y: 41)))
        XCTAssertTrue(executor.endOwnership(generation: 2))
        XCTAssertTrue(executor.perform(kind: .restore, generation: 2, point: .zero))

        XCTAssertEqual(observation.kinds, [.hold, .restore, .hold, .restore])
        XCTAssertEqual(
            observation.points,
            [firstGenerationAnchor, firstGenerationAnchor,
             secondGenerationAnchor, secondGenerationAnchor]
        )
    }

    func testRestoreWithoutAnyParkPreservesExistingFallbackPoint() {
        let observation = Issue96MutationObservation()
        let executor = makeExecutor(observation: observation)
        own(executor)

        let fallback = CGPoint(x: 777, y: 555)
        XCTAssertTrue(executor.beginOwnership(generation: 7))
        XCTAssertTrue(executor.endOwnership(generation: 7))
        XCTAssertTrue(executor.perform(kind: .restore, generation: 7, point: fallback))

        XCTAssertEqual(observation.kinds, [.restore])
        XCTAssertEqual(observation.points, [fallback])
    }

    func testDuplicateRestoreCannotMutatePointerTwice() {
        let observation = Issue96MutationObservation()
        let executor = makeExecutor(observation: observation)
        own(executor)

        let anchor = CGPoint(x: 50, y: 60)
        XCTAssertTrue(executor.beginOwnership(generation: 9))
        XCTAssertTrue(executor.perform(kind: .hold, generation: 9, point: anchor))
        XCTAssertTrue(executor.endOwnership(generation: 9))
        XCTAssertTrue(executor.perform(kind: .restore, generation: 9, point: .zero))
        XCTAssertFalse(executor.perform(kind: .restore, generation: 9, point: CGPoint(x: 1, y: 1)))

        XCTAssertEqual(observation.kinds, [.hold, .restore])
        XCTAssertEqual(observation.points, [anchor, anchor])
    }
}
