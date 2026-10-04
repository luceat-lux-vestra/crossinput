import AppKit
import XCTest
@testable import App
import EdgeSwitch

private final class RemoteCursorHelperRecorder:
    RemoteCursorHelperControlling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var startsStorage: [ScreenEdge] = []
    private var stopsStorage = 0
    var startResult = true

    var starts: [ScreenEdge] {
        lock.withLock { startsStorage }
    }

    var stops: Int {
        lock.withLock { stopsStorage }
    }

    @discardableResult
    func start(
        edge: ScreenEdge,
        point: NSPoint,
        onFailure: @escaping @Sendable () -> Void
    ) async -> Bool {
        _ = point
        _ = onFailure
        return lock.withLock {
            startsStorage.append(edge)
            return startResult
        }
    }

    @discardableResult
    func stop() -> Bool {
        lock.withLock {
            stopsStorage += 1
        }
        return true
    }
}

final class RemoteCursorPresenterTests: XCTestCase {
    func testPresenterDelegatesRemoteEpochToDisposableHelper() async {
        let recorder = RemoteCursorHelperRecorder()
        let presenter = NativeRemoteCursorPresenter(controller: recorder)

        let presented = await presenter.presentRemote(
            edge: .right,
            onFailure: {}
        )
        XCTAssertTrue(presented)
        presenter.restoreLocal()

        XCTAssertEqual(recorder.starts, [.right])
        XCTAssertEqual(recorder.stops, 1)
    }

    func testPresenterPropagatesHelperReadinessFailure() async {
        let recorder = RemoteCursorHelperRecorder()
        recorder.startResult = false
        let presenter = NativeRemoteCursorPresenter(controller: recorder)

        let presented = await presenter.presentRemote(
            edge: .left,
            onFailure: {}
        )
        XCTAssertFalse(presented)
        XCTAssertEqual(recorder.starts, [.left])
    }

    func testProcessControllerRequiresReadyHandshake() async {
        let controller = RemoteCursorHelperProcessController(
            launchConfiguration: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exit 0"]
            )
        )

        let started = await controller.start(
            edge: .left,
            point: .zero,
            onFailure: {}
        )
        XCTAssertFalse(started)
    }

    func testProcessControllerAllowsBoundedColdStartBeforeReady() async {
        let controller = RemoteCursorHelperProcessController(
            launchConfiguration: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "sleep 1.2; printf '\\245'; cat >/dev/null",
                ]
            )
        )

        let started = await controller.start(
            edge: .left,
            point: .zero,
            onFailure: {}
        )
        XCTAssertTrue(
            started,
            "cursor helper startup may exceed one second on a cold AppKit/WindowServer path"
        )

        XCTAssertTrue(controller.stop())
    }

    func testProcessControllerEOFStopsReadyHelperWithoutFailureCallback() async {
        let unexpectedFailure = expectation(
            description: "unexpected cursor helper failure"
        )
        unexpectedFailure.isInverted = true

        let controller = RemoteCursorHelperProcessController(
            launchConfiguration: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf '\\245'; cat >/dev/null",
                ]
            )
        )

        let started = await controller.start(
            edge: .left,
            point: .zero,
            onFailure: {
                unexpectedFailure.fulfill()
            }
        )
        XCTAssertTrue(started)

        controller.stop()
        await fulfillment(
            of: [unexpectedFailure],
            timeout: 0.25
        )
    }

    func testProcessControllerGivesReadyHelperGracefulCleanupWindow() async throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "crossinput-cursor-cleanup-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let escapedPath = markerURL.path.replacingOccurrences(
            of: "'",
            with: "'\\''"
        )
        let controller = RemoteCursorHelperProcessController(
            launchConfiguration: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf '\\245'; cat >/dev/null; "
                        + "printf restored > '\(escapedPath)'",
                ]
            )
        )

        let started = await controller.start(
            edge: .left,
            point: .zero,
            onFailure: {}
        )
        XCTAssertTrue(started)

        controller.stop()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: markerURL.path),
            "normal return must give the helper time to run cleanup after EOF"
        )
        XCTAssertEqual(
            try String(contentsOf: markerURL, encoding: .utf8),
            "restored"
        )
    }

    func testProcessControllerReportsUnexpectedExitAfterReady() async {
        let failure = expectation(
            description: "cursor helper unexpected exit"
        )

        let controller = RemoteCursorHelperProcessController(
            launchConfiguration: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf '\\245'; sleep 0.05; exit 7",
                ]
            )
        )

        let started = await controller.start(
            edge: .left,
            point: .zero,
            onFailure: {
                failure.fulfill()
            }
        )
        XCTAssertTrue(started)

        await fulfillment(of: [failure], timeout: 1)
        controller.stop()
    }

    func testCursorHealthAllowsTransientMismatchButFailsBoundedPersistentLoss() {
        var health = RemoteCursorPresentationHealth(mismatchLimit: 3)

        XCTAssertTrue(health.observe(matches: false))
        XCTAssertEqual(health.consecutiveMismatches, 1)
        XCTAssertTrue(health.observe(matches: false))
        XCTAssertEqual(health.consecutiveMismatches, 2)
        XCTAssertFalse(health.observe(matches: false))
        XCTAssertEqual(health.consecutiveMismatches, 3)
    }

    func testCursorHealthRecoveryResetsMismatchBudget() {
        var health = RemoteCursorPresentationHealth(mismatchLimit: 3)

        XCTAssertTrue(health.observe(matches: false))
        XCTAssertTrue(health.observe(matches: true))
        XCTAssertEqual(health.consecutiveMismatches, 0)
        XCTAssertTrue(health.observe(matches: false))
        XCTAssertEqual(health.consecutiveMismatches, 1)
    }

    func testReturnCancelsPendingCursorHelperBeforeReady() async {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "crossinput-cursor-helper-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let escapedPath = markerURL.path.replacingOccurrences(
            of: "'",
            with: "'\\''"
        )
        let unexpectedFailure = expectation(
            description: "pending helper must not publish failure callback"
        )
        unexpectedFailure.isInverted = true

        let controller = RemoteCursorHelperProcessController(
            launchConfiguration: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf launched > '\(escapedPath)'; "
                        + "sleep 1; printf '\\245'; cat >/dev/null",
                ]
            )
        )

        let startTask = Task {
            await controller.start(
                edge: .left,
                point: .zero,
                onFailure: {
                    unexpectedFailure.fulfill()
                }
            )
        }

        var launched = false
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: markerURL.path) {
                launched = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(launched)

        controller.stop()
        let admitted = await startTask.value
        XCTAssertFalse(admitted)

        await fulfillment(
            of: [unexpectedFailure],
            timeout: 0.25
        )
    }

    func testHelperModeUsesDedicatedArgumentFlag() {
        XCTAssertEqual(
            RemoteCursorHelperMode.flag,
            "--crossinput-cursor-helper"
        )
    }

    func testCursorSnapshotPreservesAppearanceWithoutSharingIdentity() {
        let original = NSCursor.arrow
        let snapshot = NativeRemoteCursorPresenter.snapshot(original)

        XCTAssertFalse(snapshot === original)
        XCTAssertTrue(sameCursor(snapshot, original))
    }

    func testDirectionalCursorMappingUsesModernOneDirectionNativeCursor() {
        assertSameCursor(
            NativeRemoteCursorPresenter.cursor(for: .left),
            .columnResize(directions: .right)
        )
        assertSameCursor(
            NativeRemoteCursorPresenter.cursor(for: .right),
            .columnResize(directions: .left)
        )
        assertSameCursor(
            NativeRemoteCursorPresenter.cursor(for: .top),
            .rowResize(directions: .down)
        )
        assertSameCursor(
            NativeRemoteCursorPresenter.cursor(for: .bottom),
            .rowResize(directions: .up)
        )

        XCTAssertFalse(
            sameCursor(
                NativeRemoteCursorPresenter.cursor(for: .right),
                .columnResize
            ),
            "right-edge handoff must not regress to bidirectional column resize"
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

    private func assertSameCursor(
        _ actual: NSCursor,
        _ expected: NSCursor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            sameCursor(actual, expected),
            file: file,
            line: line
        )
    }

    private func sameCursor(
        _ lhs: NSCursor,
        _ rhs: NSCursor
    ) -> Bool {
        lhs.hotSpot == rhs.hotSpot
            && lhs.image.tiffRepresentation == rhs.image.tiffRepresentation
    }
}
