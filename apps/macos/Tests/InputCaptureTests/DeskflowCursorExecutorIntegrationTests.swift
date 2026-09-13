import CoreGraphics
import Darwin
import XCTest
@testable import InputCapture

private final class DeskflowExecutorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var backgroundResults: [Int32?]
    private var showResults: [CGError]
    private var suppressionResults: [Int32?]
    private var eventsStorage: [String] = []
    private var mutationsStorage: [CursorMutationExecutor.Kind] = []

    init(
        backgroundResults: [Int32?] = [0, 0],
        showResults: [CGError] = [.success],
        suppressionResults: [Int32?] = [0, 0]
    ) {
        self.backgroundResults = backgroundResults
        self.showResults = showResults
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

    func hide(_ display: CGDirectDisplayID) -> CGError {
        lock.withLock {
            eventsStorage.append("hide:\(display)")
            return .success
        }
    }

    func show(_ display: CGDirectDisplayID) -> CGError {
        lock.withLock {
            eventsStorage.append("show:\(display)")
            return showResults.isEmpty ? .success : showResults.removeFirst()
        }
    }

    func associate(_ value: Bool) -> CGError {
        lock.withLock {
            eventsStorage.append("associate:\(value)")
            return .success
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

    private let queue = DispatchQueue(label: "crossinput.deskflow-cursor-owner")
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
                liveDisplayID: { 9 },
                setCursorInBackground: { recorder.background() },
                hide: { recorder.hide($0) },
                show: { recorder.show($0) },
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

    func testDeskflowLifecycleBalancesBeforeGenerationMatchedRestore() {
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
                "background", "hide:9", "associate:true", "suppression:0.0001", "associate:false",
                "background", "show:9", "associate:true", "associate:true", "suppression:0"
            ]
        )
        XCTAssertEqual(recorder.mutations, [.hold, .restore],
                       "injected executor semantics remain unchanged")
    }

    func testCleanupDebtBlocksNextGenerationUntilTeardownRetry() {
        let recorder = DeskflowExecutorRecorder(showResults: [.failure, .success])
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
        XCTAssertEqual(isolation.hiddenDisplayIDForTesting, 9)

        owner.stop()
        XCTAssertNil(isolation.activeGenerationForTesting)
        XCTAssertNil(isolation.hiddenDisplayIDForTesting)
        XCTAssertFalse(isolation.isDisassociatedForTesting)
    }
}
