import CoreGraphics
import Darwin
import XCTest
@testable import InputCapture

private final class MutationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedKinds: [CursorMutationExecutor.Kind] = []
    private var recordedPoints: [CGPoint] = []
    private var recordedThreadIDs: [UInt32] = []

    func record(
        kind: CursorMutationExecutor.Kind,
        point: CGPoint,
        threadID: UInt32
    ) {
        lock.withLock {
            recordedKinds.append(kind)
            recordedPoints.append(point)
            recordedThreadIDs.append(threadID)
        }
    }

    var kinds: [CursorMutationExecutor.Kind] {
        lock.withLock { recordedKinds }
    }

    var points: [CGPoint] {
        lock.withLock { recordedPoints }
    }

    var threadIDs: [UInt32] {
        lock.withLock { recordedThreadIDs }
    }
}

private final class BoolObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool?

    func set(_ value: Bool) {
        lock.withLock { storage = value }
    }

    var value: Bool? {
        lock.withLock { storage }
    }
}

private final class BoolFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func takeFirst() -> Bool {
        lock.withLock {
            guard !value else { return false }
            value = true
            return true
        }
    }
}

private func makeMoveEvent(at point: CGPoint) -> CGEvent {
    CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
    )!
}

private func currentThreadID() -> UInt32 {
    pthread_mach_thread_np(pthread_self())
}

/// Runs a real CFRunLoopSource-backed executor owner, without installing a
/// system event tap. This keeps executor tests deterministic while preserving
/// the same scheduling and wakeup path used by production.
private final class ExecutorOwnerRunLoop: @unchecked Sendable {
    let executor: CursorMutationExecutor

    private let queue = DispatchQueue(label: "crossinput.cursor-mutation-test-owner")
    private let ready = DispatchSemaphore(value: 0)
    private let start = DispatchSemaphore(value: 0)
    private let running = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var runLoop: CFRunLoop?
    private var threadID: UInt32?
    private var stopped = false

    init(executor: CursorMutationExecutor, startImmediately: Bool) {
        self.executor = executor
        queue.async { [weak self] in
            guard let self, let runLoop = CFRunLoopGetCurrent() else { return }
            guard executor.bind(to: runLoop) else { return }
            self.stateLock.withLock {
                self.runLoop = runLoop
                self.threadID = currentThreadID()
            }
            self.ready.signal()
            if startImmediately { self.start.signal() }
            _ = self.start.wait(timeout: .distantFuture)
            self.running.signal()
            CFRunLoopRun()
            self.finished.signal()
        }
        XCTAssertEqual(
            ready.wait(timeout: .now() + 1),
            .success,
            "executor owner run loop must bind"
        )
    }

    var ownerThreadID: UInt32? {
        stateLock.withLock { threadID }
    }

    func startRunLoop() {
        start.signal()
    }

    func stop() {
        let shouldStop = stateLock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }
        start.signal()
        guard running.wait(timeout: .now() + 1) == .success else { return }
        guard let runLoop = stateLock.withLock({ self.runLoop }) else { return }
        executor.unbind()
        CFRunLoopStop(runLoop)
        CFRunLoopWakeUp(runLoop)
        _ = finished.wait(timeout: .now() + 1)
    }

    deinit {
        stop()
    }
}

final class CursorMutationExecutorTests: XCTestCase {
    func testStaleHoldAfterReleaseCannotMutateAfterOwnershipEnds() {
        let admitted = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let pauseGate = BoolFlagBox()
        let observation = MutationObservation()
        let executor = CursorMutationExecutor(
            coordinationTimeout: 0.05,
            beforeCommitHook: {
                let shouldPause = pauseGate.takeFirst()
                guard shouldPause else { return }
                admitted.signal()
                _ = resume.wait(timeout: .now() + 1)
            },
            mutation: { kind, point in
                observation.record(kind: kind, point: point, threadID: currentThreadID())
            }
        )
        let owner = ExecutorOwnerRunLoop(executor: executor, startImmediately: true)
        let capture = InputCapture(cursorMutationExecutor: executor)
        defer {
            resume.signal()
            capture.stop()
            owner.stop()
        }

        let displayID = CGMainDisplayID()
        let frame = CGDisplayBounds(displayID)
        capture.setAndroidEdge(.left, forDisplay: displayID)
        XCTAssertEqual(capture.suppress(), 1)

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = capture.handleForTesting(type: .mouseMoved, event: makeMoveEvent(at: CGPoint(x: frame.midX, y: frame.midY)))
            finished.signal()
        }

        XCTAssertEqual(admitted.wait(timeout: .now() + 1), .success)
        capture.release(reason: .normalReturn)
        XCTAssertFalse(capture.isSuppressed)
        resume.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(observation.kinds, [], "the stale hold must be rejected")
    }

    func testOldRestoreCannotMutateAfterNewGenerationStarts() {
        let enqueued = DispatchSemaphore(value: 0)
        let observation = MutationObservation()
        let executor = CursorMutationExecutor(
            coordinationTimeout: 0.25,
            requestEnqueuedHook: { enqueued.signal() },
            mutation: { kind, point in
                observation.record(kind: kind, point: point, threadID: currentThreadID())
            }
        )
        let owner = ExecutorOwnerRunLoop(executor: executor, startImmediately: false)
        defer { owner.stop() }

        XCTAssertTrue(executor.beginOwnership(generation: 1))
        XCTAssertTrue(executor.endOwnership(generation: 1))

        let result = BoolObservation()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result.set(executor.perform(
                kind: .restore,
                generation: 1,
                point: .zero
            ))
            finished.signal()
        }
        XCTAssertEqual(enqueued.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(executor.beginOwnership(generation: 2))
        owner.startRunLoop()

        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.value, false, "generation 1 restore must be stale")
        XCTAssertEqual(observation.kinds, [])

        let newGenerationResult = BoolObservation()
        let newGenerationFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            newGenerationResult.set(executor.perform(
                kind: .hold,
                generation: 2,
                point: .zero
            ))
            newGenerationFinished.signal()
        }
        XCTAssertEqual(newGenerationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(newGenerationResult.value, true)
        XCTAssertEqual(observation.kinds, [.hold])
        XCTAssertTrue(executor.endOwnership(generation: 2))
    }

    func testNonOwnerRequestsMutateOnlyOnTheDesignatedExecutorThread() {
        let observation = MutationObservation()
        let executor = CursorMutationExecutor { kind, point in
            observation.record(kind: kind, point: point, threadID: currentThreadID())
        }
        let owner = ExecutorOwnerRunLoop(executor: executor, startImmediately: true)
        defer {
            _ = executor.endOwnership(generation: 1)
            owner.stop()
        }

        XCTAssertTrue(executor.beginOwnership(generation: 1))
        XCTAssertFalse(executor.isOnOwningThreadForTesting)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = executor.perform(kind: .hold, generation: 1, point: .zero)
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(observation.kinds, [.hold])
        XCTAssertEqual(observation.threadIDs, [owner.ownerThreadID].compactMap { $0 })
    }

    func testOrdinarySuppressedTapMovePreservesEdgeHoldMutation() {
        let observation = MutationObservation()
        let executor = CursorMutationExecutor { kind, point in
            observation.record(kind: kind, point: point, threadID: currentThreadID())
        }
        let owner = ExecutorOwnerRunLoop(executor: executor, startImmediately: true)
        let capture = InputCapture(cursorMutationExecutor: executor)
        defer {
            capture.release(reason: .externalControl)
            owner.stop()
        }

        let displayID = CGMainDisplayID()
        let frame = CGDisplayBounds(displayID)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        capture.setAndroidEdge(.left, forDisplay: displayID)
        XCTAssertEqual(capture.suppress(), 1)

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertNil(capture.handleForTesting(type: .mouseMoved, event: makeMoveEvent(at: point)))
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)

        let expected = DisplayEdgeResolver.pointerPosition(
            for: .left,
            in: frame,
            at: point,
            threshold: 2
        )
        XCTAssertEqual(observation.kinds, [.hold])
        XCTAssertEqual(observation.points, [expected])
        XCTAssertEqual(observation.threadIDs, [owner.ownerThreadID].compactMap { $0 })
    }

    func testRestoreTimeoutReleasesSuppressionWithoutCallerThreadWarp() {
        let observation = MutationObservation()
        let executor = CursorMutationExecutor(
            coordinationTimeout: 0.05,
            mutation: { kind, point in
                observation.record(kind: kind, point: point, threadID: currentThreadID())
            }
        )
        let owner = ExecutorOwnerRunLoop(executor: executor, startImmediately: false)
        let capture = InputCapture(cursorMutationExecutor: executor)
        defer {
            capture.stop()
            owner.stop()
        }

        XCTAssertEqual(capture.suppress(), 1)
        let started = DispatchTime.now()
        capture.release(reason: .watchdogTimeout)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000

        XCTAssertFalse(capture.isSuppressed)
        XCTAssertLessThan(elapsed, 0.5, "restore coordination must remain bounded")
        XCTAssertEqual(observation.kinds, [], "timeout must not fall back to a caller-thread warp")
    }
}
