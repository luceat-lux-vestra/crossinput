import CoreGraphics
import Darwin
import XCTest
@testable import InputCapture

private final class CursorIsolationIntegrationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var associateResults: [CGError]
    private var hideResults: [CGError]
    private var showResults: [CGError]
    private var eventsStorage: [String] = []
    private var mutationsStorage: [CursorMutationExecutor.Kind] = []

    init(
        associateResults: [CGError],
        hideResults: [CGError] = [.success],
        showResults: [CGError] = [.success]
    ) {
        self.associateResults = associateResults
        self.hideResults = hideResults
        self.showResults = showResults
    }

    var events: [String] { lock.withLock { eventsStorage } }
    var mutations: [CursorMutationExecutor.Kind] { lock.withLock { mutationsStorage } }

    func associate(_ value: Bool) -> CGError {
        lock.withLock {
            eventsStorage.append("associate:\(value)")
            return associateResults.isEmpty ? .success : associateResults.removeFirst()
        }
    }

    func hide() -> CGError {
        lock.withLock {
            eventsStorage.append("hide")
            return hideResults.isEmpty ? .success : hideResults.removeFirst()
        }
    }

    func show() -> CGError {
        lock.withLock {
            eventsStorage.append("show")
            return showResults.isEmpty ? .success : showResults.removeFirst()
        }
    }

    func mutate(_ kind: CursorMutationExecutor.Kind) {
        lock.withLock { mutationsStorage.append(kind) }
    }
}

private final class CursorIsolationExecutorOwner: @unchecked Sendable {
    let executor: CursorMutationExecutor

    private let queue = DispatchQueue(label: "crossinput.cursor-isolation-owner")
    private let ready = DispatchSemaphore(value: 0)
    private let running = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var runLoop: CFRunLoop?
    private var stopped = false

    init(executor: CursorMutationExecutor) {
        self.executor = executor
        queue.async { [weak self] in
            guard let self, let runLoop = CFRunLoopGetCurrent() else { return }
            guard executor.bind(to: runLoop) else { return }
            self.stateLock.withLock { self.runLoop = runLoop }
            self.ready.signal()
            self.running.signal()
            CFRunLoopRun()
            self.finished.signal()
        }
        XCTAssertEqual(ready.wait(timeout: .now() + 1), .success)
    }

    func stop() {
        let shouldStop = stateLock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }
        guard running.wait(timeout: .now() + 1) == .success else { return }
        guard let runLoop = stateLock.withLock({ self.runLoop }) else { return }
        executor.unbind()
        CFRunLoopStop(runLoop)
        CFRunLoopWakeUp(runLoop)
        _ = finished.wait(timeout: .now() + 1)
    }

    deinit { stop() }
}

final class CursorIsolationExecutorIntegrationTests: XCTestCase {
    private func makeIsolation(_ recorder: CursorIsolationIntegrationRecorder) -> RemoteCursorIsolation {
        RemoteCursorIsolation(
            operations: .init(
                associate: { recorder.associate($0) },
                hide: { recorder.hide() },
                show: { recorder.show() }
            )
        )
    }

    func testIsolationAdmissionFailureRejectsOwnershipAndMutation() {
        let recorder = CursorIsolationIntegrationRecorder(associateResults: [.failure])
        let executor = CursorMutationExecutor(
            remoteCursorIsolation: makeIsolation(recorder),
            mutation: { kind, _ in recorder.mutate(kind) }
        )
        let owner = CursorIsolationExecutorOwner(executor: executor)
        defer { owner.stop() }

        XCTAssertFalse(executor.beginOwnership(generation: 1))
        XCTAssertFalse(executor.perform(kind: .hold, generation: 1, point: .zero))
        XCTAssertEqual(recorder.events, ["associate:false"])
        XCTAssertTrue(recorder.mutations.isEmpty)
    }

    func testBalancedIsolationAllowsRestoreOnlyAfterOwnershipEnds() {
        let recorder = CursorIsolationIntegrationRecorder(
            associateResults: [.success, .success]
        )
        let executor = CursorMutationExecutor(
            remoteCursorIsolation: makeIsolation(recorder),
            mutation: { kind, _ in recorder.mutate(kind) }
        )
        let owner = CursorIsolationExecutorOwner(executor: executor)
        defer { owner.stop() }

        XCTAssertTrue(executor.beginOwnership(generation: 2))
        XCTAssertTrue(executor.perform(kind: .hold, generation: 2, point: .zero))
        XCTAssertTrue(executor.endOwnership(generation: 2))
        XCTAssertTrue(executor.perform(kind: .restore, generation: 2, point: .zero))

        XCTAssertEqual(
            recorder.events,
            ["associate:false", "hide", "associate:true", "show"]
        )
        XCTAssertEqual(recorder.mutations, [.hold, .restore],
                       "injected executor semantics remain unchanged")
    }

    func testCleanupFailureKeepsEpochActiveAndRejectsNextGeneration() {
        let recorder = CursorIsolationIntegrationRecorder(
            associateResults: [.success, .failure, .success],
            showResults: [.failure, .success]
        )
        let isolation = makeIsolation(recorder)
        let executor = CursorMutationExecutor(
            remoteCursorIsolation: isolation,
            mutation: { kind, _ in recorder.mutate(kind) }
        )
        let owner = CursorIsolationExecutorOwner(executor: executor)

        XCTAssertTrue(executor.beginOwnership(generation: 3))
        XCTAssertFalse(executor.endOwnership(generation: 3))
        XCTAssertFalse(executor.beginOwnership(generation: 4),
                       "cleanup debt must block a new suppression epoch")
        XCTAssertEqual(isolation.activeGenerationForTesting, 3)

        owner.stop()
        XCTAssertNil(isolation.activeGenerationForTesting,
                     "executor teardown must retry best-effort balancing")
    }
}