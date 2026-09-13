import CoreGraphics
import Darwin
import XCTest
@testable import InputCapture

private final class DeskflowExecutorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var backgroundResults: [Int32?]
    private var associateResults: [CGError]
    private var suppressionResults: [Int32?]
    private var eventsStorage: [String] = []
    private var mutationsStorage: [CursorMutationExecutor.Kind] = []

    init(
        backgroundResults: [Int32?] = [0, 0],
        associateResults: [CGError] = [.success, .success, .success, .success],
        suppressionResults: [Int32?] = [0, 0]
    ) {
        self.backgroundResults = backgroundResults
        self.associateResults = associateResults
        self.suppressionResults = suppressionResults
    }

    var events: [String] { lock.withLock { eventsStorage } }
    var mutations: [CursorMutationExecutor.Kind] { lock.withLock { mutationsStorage } }

    func background() -> Int32? {
        lock.withLock {
            eventsStorage.append("background")
            return backgroundResults.isEmpty ? 0 : backgroundResults.removeFirst()
        }
    }

    func associate(_ value: Bool) -> CGError {
        lock.withLock {
            eventsStorage.append("associate:\(value)")
            return associateResults.isEmpty ? .success : associateResults.removeFirst()
        }
    }

    func suppression(_ value: Double) -> Int32? {
        lock.withLock {
            eventsStorage.append(value == 0 ? "suppression:0" : "suppression:0.0001")
            return suppressionResults.isEmpty ? 0 : suppressionResults.removeFirst()
        }
    }

    func mutate(_ kind: CursorMutationExecutor.Kind) {
        lock.withLock { mutationsStorage.append(kind) }
    }
}

private final class DeskflowExecutorOwner: @unchecked Sendable {
    let executor: CursorMutationExecutor

    private let queue = DispatchQueue(label: "crossinput.deskflow-visible-cursor-owner")
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

final class DeskflowCursorExecutorIntegrationTests: XCTestCase {
    private func makeIsolation(_ recorder: DeskflowExecutorRecorder) -> DeskflowCursorIsolation {
        DeskflowCursorIsolation(
            operations: .init(
                setCursorInBackground: { recorder.background() },
                associate: { recorder.associate($0) },
                setSuppressionInterval: { recorder.suppression($0) }
            )
        )
    }

    func testSPIAdmissionFailureRejectsOwnershipAndMutation() {
        let recorder = DeskflowExecutorRecorder(backgroundResults: [nil])
        let executor = CursorMutationExecutor(
            deskflowCursorIsolation: makeIsolation(recorder),
            mutation: { kind, _ in recorder.mutate(kind) }
        )
        let owner = DeskflowExecutorOwner(executor: executor)
        defer { owner.stop() }

        XCTAssertFalse(executor.beginOwnership(generation: 1))
        XCTAssertFalse(executor.perform(kind: .hold, generation: 1, point: .zero))
        XCTAssertEqual(recorder.events, ["background"])
        XCTAssertTrue(recorder.mutations.isEmpty)
    }

    func testVisibleCursorLifecycleBalancesBeforeGenerationMatchedRestore() {
        let recorder = DeskflowExecutorRecorder()
        let executor = CursorMutationExecutor(
            deskflowCursorIsolation: makeIsolation(recorder),
            mutation: { kind, _ in recorder.mutate(kind) }
        )
        let owner = DeskflowExecutorOwner(executor: executor)
        defer { owner.stop() }

        XCTAssertTrue(executor.beginOwnership(generation: 2))
        XCTAssertTrue(executor.perform(kind: .hold, generation: 2, point: .zero))
        XCTAssertTrue(executor.endOwnership(generation: 2))
        XCTAssertTrue(executor.perform(kind: .restore, generation: 2, point: .zero))

        XCTAssertEqual(
            recorder.events,
            [
                "background", "associate:true", "suppression:0.0001", "associate:false",
                "background", "associate:true", "associate:true", "suppression:0"
            ]
        )
        XCTAssertFalse(recorder.events.contains { $0.contains("hide") || $0.contains("show") })
        XCTAssertEqual(recorder.mutations, [.hold, .restore],
                       "injected executor semantics remain unchanged")
    }

    func testCleanupDebtBlocksNextGenerationUntilTeardownRetry() {
        let recorder = DeskflowExecutorRecorder(
            associateResults: [.success, .success, .failure, .success],
            suppressionResults: [0, 0, 0]
        )
        let isolation = makeIsolation(recorder)
        let executor = CursorMutationExecutor(
            deskflowCursorIsolation: isolation,
            mutation: { kind, _ in recorder.mutate(kind) }
        )
        let owner = DeskflowExecutorOwner(executor: executor)

        XCTAssertTrue(executor.beginOwnership(generation: 3))
        XCTAssertFalse(executor.endOwnership(generation: 3))
        XCTAssertFalse(executor.beginOwnership(generation: 4))
        XCTAssertEqual(isolation.activeGenerationForTesting, 3)

        owner.stop()
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertFalse(isolation.isDisassociatedForTesting)
    }
}
