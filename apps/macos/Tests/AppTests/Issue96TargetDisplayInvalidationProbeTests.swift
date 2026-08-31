import XCTest
import AppKit
@testable import App
import EdgeSwitch

@MainActor
final class Issue96TargetDisplayInvalidationProbeTests: XCTestCase {
    func testEachProbeCommandDispatchesExactlyOnePrimitive() {
        let operations = RecordingProbeOperations()
        let dispatcher = Issue96ProbeDispatcher(operations: operations)

        for command in Issue96ProbeCommand.probeKinds {
            operations.calls.removeAll()

            XCTAssertNotNil(dispatcher.dispatch(command))
            XCTAssertEqual(operations.calls, [command], "probe stacked an unrelated primitive: \(command.rawValue)")
        }

        operations.calls.removeAll()
        XCTAssertNil(dispatcher.dispatch(.status))
        XCTAssertTrue(operations.calls.isEmpty, "status must not invoke an AppKit primitive")
    }

    func testCommandParserAcceptsOnlyOneExactCommand() {
        XCTAssertEqual(Issue96ProbeCommand.parse("redraw\n"), .redraw)
        XCTAssertEqual(Issue96ProbeCommand.parse("cursor-rect"), .cursorRect)
        XCTAssertEqual(Issue96ProbeCommand.parse("mark-baseline-healthy"), .markBaselineHealthy)
        XCTAssertEqual(Issue96ProbeCommand.parse("dump-trace"), .dumpTrace)
        XCTAssertNil(Issue96ProbeCommand.parse("redraw extra"))
        XCTAssertNil(Issue96ProbeCommand.parse(""))
    }

    func testLifecycleTraceIsBoundedOrderedAndClearable() {
        let trace = Issue96LifecycleTrace(targetDisplayID: 11, capacity: 3)

        trace.record(event: .viewDraw)
        trace.record(event: .cursorUpdate, region: .resizeHorizontal)
        trace.record(event: .mouseMoved, region: .resizeVertical)
        trace.record(event: .markerBrokenConfirmed)

        XCTAssertEqual(trace.records.count, 3)
        XCTAssertEqual(trace.records.map(\.sequence), [2, 3, 4])
        XCTAssertEqual(trace.records.map(\.event), [.cursorUpdate, .mouseMoved, .markerBrokenConfirmed])

        trace.clear()
        XCTAssertTrue(trace.records.isEmpty)
        let next = trace.record(event: .markerRecovered)
        XCTAssertEqual(next.sequence, 5)
    }

    func testLifecycleTraceUsesStableEventsAndSymbolicRegionsOnly() {
        let trace = Issue96LifecycleTrace(targetDisplayID: 11)
        let record = trace.record(event: .cursorUpdate, region: .resizeDiagonal)

        XCTAssertEqual(record.event.rawValue, "cursor-update")
        XCTAssertEqual(record.region?.rawValue, "resize-diagonal")
        XCTAssertTrue(record.traceLine.contains("event=cursor-update"))
        XCTAssertTrue(record.traceLine.contains("region=resize-diagonal"))
        for forbidden in ["x=", "y=", "delta", "keyCode", "clipboard", "HID", "payload"] {
            XCTAssertFalse(record.traceLine.localizedCaseInsensitiveContains(forbidden),
                           "forbidden input data appeared in lifecycle trace: \(forbidden)")
        }
    }

    func testLifecycleEventVocabularyCoversRequiredCallbacksAndMarkers() {
        let required: Set<Issue96LifecycleEvent> = [
            .resetCursorRects,
            .cursorUpdate,
            .updateTrackingAreas,
            .mouseEntered,
            .mouseExited,
            .mouseMoved,
            .applicationDidBecomeActive,
            .applicationDidResignActive,
            .windowDidBecomeKey,
            .windowDidResignKey,
            .windowDidBecomeMain,
            .windowDidResignMain,
            .windowDidChangeOcclusionState,
            .windowDidMiniaturize,
            .windowDidDeminiaturize,
            .windowDidChangeScreen,
            .windowDidMove,
            .windowDidResize,
            .windowWillClose,
            .viewDidMoveToWindow,
            .viewDidMoveToSuperview,
            .viewLayout,
            .viewDraw,
            .markerBaselineHealthy,
            .markerBrokenConfirmed,
            .markerRecoveryAction,
            .markerRecovered,
            .markerStillBroken,
        ]

        XCTAssertEqual(Set(Issue96LifecycleEvent.allCases), required)
        XCTAssertTrue(Issue96ProbeWindowConfiguration.trackingAreaOptions.contains(.mouseMoved))
        XCTAssertEqual(
            Issue96CursorRegion.cursorRegions,
            [.resizeHorizontal, .resizeVertical, .resizeDiagonal])
    }

    func testTraceControlCommandsDoNotDispatchAppKitPrimitives() {
        let operations = RecordingProbeOperations()
        let dispatcher = Issue96ProbeDispatcher(operations: operations)
        let commands: [Issue96ProbeCommand] = [.status] + Issue96ProbeCommand.traceControlKinds

        for command in commands {
            XCTAssertNil(dispatcher.dispatch(command), "trace control dispatched a primitive: \(command.rawValue)")
        }
        XCTAssertTrue(operations.calls.isEmpty)
    }

    func testOneMarkerCommandAddsExactlyOneMarker() {
        let trace = Issue96LifecycleTrace(targetDisplayID: 11)

        let response = Issue96ProbeTraceControl.handle(.markBaselineHealthy, trace: trace)

        XCTAssertEqual(response, "OK kind=mark-baseline-healthy sequence=1\n")
        XCTAssertEqual(trace.records.count, 1)
        XCTAssertEqual(trace.records[0].event, .markerBaselineHealthy)
    }

    func testClearAndDumpTraceDoNotMutateAppKitOrTraceDuringDump() {
        let trace = Issue96LifecycleTrace(targetDisplayID: 11)
        trace.record(event: .viewDraw)
        let beforeDump = trace.records

        let dump = Issue96ProbeTraceControl.handle(.dumpTrace, trace: trace)
        XCTAssertNotNil(dump)
        XCTAssertEqual(trace.records, beforeDump)
        XCTAssertTrue(dump?.contains("event=view-draw") == true)

        let clear = Issue96ProbeTraceControl.handle(.clearTrace, trace: trace)
        XCTAssertEqual(clear, "OK kind=clear-trace count=0\n")
        XCTAssertTrue(trace.records.isEmpty)
    }

    func testTraceDumpIsBounded() {
        let trace = Issue96LifecycleTrace(targetDisplayID: 11, capacity: 1_000)
        for _ in 0..<1_000 {
            trace.record(event: .mouseMoved, region: .background)
        }

        let dump = trace.dumpResponse()
        XCTAssertLessThanOrEqual(dump.utf8.count, Issue96LifecycleTrace.maximumDumpBytes)
        XCTAssertTrue(dump.contains("count=1000"))
    }

    func testEndpointExecutionInvokesOneValidHandlerExactlyOnce() async {
        let invocations = InvocationCounter()
        let response = await Issue96ProbeEndpointExecution.execute(line: "redraw\n") { line in
            await invocations.record(line)
            return "OK sequence=1 kind=redraw api_success=true\n"
        }

        XCTAssertEqual(response, "OK sequence=1 kind=redraw api_success=true\n")
        let count = await invocations.count
        let lines = await invocations.lines
        XCTAssertEqual(count, 1)
        XCTAssertEqual(lines, ["redraw\n"])
    }

    func testEndpointExecutionRejectsUnsupportedOrEmptyInputBeforeHandler() async {
        let invocations = InvocationCounter()

        for line in ["", "\n", "unsupported", "redraw extra"] {
            let response = await Issue96ProbeEndpointExecution.execute(line: line) { value in
                await invocations.record(value)
                return "UNEXPECTED\n"
            }

            XCTAssertEqual(response, "ERROR reason=unsupported-command\n")
        }

        let count = await invocations.count
        let lines = await invocations.lines
        XCTAssertEqual(count, 0)
        XCTAssertTrue(lines.isEmpty)
    }

    func testEndpointExecutionWaitsForDefinitiveResultWithoutExecutionTimeout() async {
        let invocations = InvocationCounter()
        let response = await Issue96ProbeEndpointExecution.execute(line: "tracking-area") { line in
            await invocations.record(line)
            try? await Task.sleep(nanoseconds: 50_000_000)
            return "OK sequence=2 kind=tracking-area api_success=true\n"
        }

        XCTAssertFalse(response.contains("command-timeout"))
        XCTAssertEqual(response, "OK sequence=2 kind=tracking-area api_success=true\n")
        let count = await invocations.count
        XCTAssertEqual(count, 1)
    }

    func testEndpointInputBoundsRemainExplicitAndIndependentFromExecution() {
        XCTAssertEqual(Issue96ProbeControlEndpoint.maximumInputBytes, 512)
        XCTAssertEqual(Issue96ProbeControlEndpoint.inputReadTimeoutSeconds, 2)
    }

    func testEndpointStopRemovesOwnedSocketAndIsIdempotent() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("i96-\(UUID().uuidString).sock").path
        let endpoint = Issue96ProbeControlEndpoint(path: path)
        defer {
            endpoint.stop()
            try? FileManager.default.removeItem(atPath: path)
        }

        do {
            try endpoint.start { _ in "OK\n" }
        } catch {
            XCTFail("endpoint start failed: \(error)")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        endpoint.stop()
        endpoint.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testProbePanelFrameNormalizesNonPrimaryScreenOriginOnce() {
        let screenFrame = NSRect(x: 909, y: -1586, width: 2454, height: 1586)
        let visibleFrame = NSRect(x: 909, y: -1586, width: 2454, height: 1540)
        let frame = Issue96ProbeWindowFrame.centered(
            visibleFrame: visibleFrame,
            screenFrame: screenFrame,
            size: NSSize(width: 220, height: 64))

        XCTAssertEqual(frame, NSRect(x: 1117, y: 738, width: 220, height: 64))
    }

    func testTargetSelectionRequiresExactlyOneConfiguredEdgeDisplay() {
        let none = Issue96TargetDisplaySelection.resolve(from: [display(11), display(42)])
        XCTAssertEqual(none, .noneConfigured)

        let one = Issue96TargetDisplaySelection.resolve(from: [display(11, edge: .right), display(42)])
        XCTAssertEqual(one, .selected(11))

        let many = Issue96TargetDisplaySelection.resolve(
            from: [display(11, edge: .right), display(42, edge: .left)])
        XCTAssertEqual(many, .ambiguous([11, 42]))
    }

    func testDiagnosticWindowConfigurationIsNonActivatingByDefault() {
        XCTAssertTrue(Issue96ProbeWindowConfiguration.styleMask.contains(.borderless))
        XCTAssertTrue(Issue96ProbeWindowConfiguration.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(Issue96ProbeWindowConfiguration.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(Issue96ProbeWindowConfiguration.initiallyMakesKeyWindow)
        XCTAssertFalse(Issue96ProbeWindowConfiguration.initiallyMakesMainWindow)
        XCTAssertFalse(Issue96ProbeWindowConfiguration.initiallyActivatesApplication)
    }

    func testIssue96DiagnosticsAreDisabledUnlessExplicitlyEnabled() {
        XCTAssertFalse(Issue96ProbeConfiguration.isEnabled(environment: [:]))
        XCTAssertFalse(Issue96ProbeConfiguration.isEnabled(
            environment: [Issue96ProbeConfiguration.enabledEnvironmentKey: "0"]))
        XCTAssertTrue(Issue96ProbeConfiguration.isEnabled(
            environment: [Issue96ProbeConfiguration.enabledEnvironmentKey: "1"]))
    }

    func testDisabledFactoryCreatesNoSurfaceOrControlEndpoint() {
        let hostDisplay = display(11, edge: .right)
        let harness = Issue96ProbeFactory.makeIfEnabled(
            environment: [:],
            targetDisplayID: hostDisplay.id,
            screens: [])

        XCTAssertNil(harness)
    }

    func testProbeRecordContainsBoundedMetadataOnly() {
        let state = Issue96ProbeWindowState(appIsActive: false, isKeyWindow: false, isMainWindow: false)
        let record = Issue96ProbeRecord(
            sequence: 7,
            monotonicNanoseconds: 123,
            kind: .cursorRect,
            targetDisplayID: 11,
            panelDisplayID: 11,
            before: state,
            after: state,
            result: .applied(api: "window.invalidateCursorRects(for:diagnosticView)"))

        XCTAssertTrue(record.logMessage.contains("sequence=7"))
        XCTAssertTrue(record.logMessage.contains("monotonic_ns=123"))
        XCTAssertTrue(record.logMessage.contains("target_display_id=11"))
        XCTAssertTrue(record.logMessage.contains("panel_display_id=11"))
        XCTAssertTrue(record.logMessage.contains("api_success=true"))
        for forbidden in ["x=", "y=", "delta", "keyCode", "clipboard", "HID", "payload"] {
            XCTAssertFalse(record.logMessage.localizedCaseInsensitiveContains(forbidden),
                           "forbidden input data appeared in probe metadata: \(forbidden)")
        }
    }

    private func display(_ id: CGDirectDisplayID, edge: ScreenEdge? = nil) -> HostDisplayEdgeOption {
        HostDisplayEdgeOption(id: id, name: "Display \(id)", width: 1920, height: 1080, edge: edge)
    }
}

@MainActor
private final class RecordingProbeOperations: Issue96ProbePrimitiveOperations {
    var calls: [Issue96ProbeCommand] = []

    func redrawOnly() -> Issue96ProbeOperationResult {
        calls.append(.redraw)
        return .applied(api: "recording.redraw")
    }

    func cursorRectInvalidationOnly() -> Issue96ProbeOperationResult {
        calls.append(.cursorRect)
        return .applied(api: "recording.cursor-rect")
    }

    func trackingAreaRebuildOnly() -> Issue96ProbeOperationResult {
        calls.append(.trackingArea)
        return .applied(api: "recording.tracking-area")
    }

    func nonActivatingWindowUpdateOnly() -> Issue96ProbeOperationResult {
        calls.append(.windowUpdate)
        return .applied(api: "recording.window-update")
    }

    func activationPositiveControl() -> Issue96ProbeOperationResult {
        calls.append(.activationControl)
        return .applied(api: "recording.activation-control")
    }
}

private actor InvocationCounter {
    private(set) var count = 0
    private(set) var lines: [String] = []

    func record(_ line: String) {
        count += 1
        lines.append(line)
    }
}
