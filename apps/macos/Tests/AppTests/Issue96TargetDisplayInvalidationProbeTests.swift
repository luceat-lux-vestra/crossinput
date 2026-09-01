import AppKit
import Darwin
import XCTest
@testable import App
import EdgeSwitch

@MainActor
final class Issue96TargetDisplayInvalidationProbeTests: XCTestCase {
    func testEachProbeCommandDispatchesExactlyOnePrimitive() {
        let operations = RecordingProbeOperations()
        let dispatcher = Issue96ProbeDispatcher(
            operations: operations,
            applicationActivationRecovery: operations,
            windowKeyRecovery: operations,
            windowResizeRecovery: operations)

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
        XCTAssertEqual(Issue96ProbeCommand.parse("recovery-app-activate\n"), .recoveryAppActivate)
        XCTAssertNil(Issue96ProbeCommand.parse("recovery-app-activate extra"))
        XCTAssertEqual(Issue96ProbeCommand.parse("recovery-window-key\n"), .recoveryWindowKey)
        XCTAssertNil(Issue96ProbeCommand.parse("recovery-window-key extra"))
        XCTAssertNil(Issue96ProbeCommand.parse("recovery-window-key recovery-app-activate"))
        XCTAssertEqual(Issue96ProbeCommand.parse("recovery-window-resize\n"), .recoveryWindowResize)
        XCTAssertNil(Issue96ProbeCommand.parse("recovery-window-resize extra"))
        XCTAssertNil(Issue96ProbeCommand.parse("recovery-window-resize recovery-window-key"))
    }

    func testApplicationActivationRecoveryDispatchesExactlyOneSeparateOperation() {
        let operations = RecordingProbeOperations()
        let dispatcher = Issue96ProbeDispatcher(
            operations: operations,
            applicationActivationRecovery: operations,
            windowKeyRecovery: operations,
            windowResizeRecovery: operations)

        XCTAssertNotNil(dispatcher.dispatch(.recoveryAppActivate))
        XCTAssertEqual(operations.calls, [.recoveryAppActivate])
        XCTAssertFalse(operations.calls.contains(.redraw))
        XCTAssertFalse(operations.calls.contains(.cursorRect))
        XCTAssertFalse(operations.calls.contains(.trackingArea))
        XCTAssertFalse(operations.calls.contains(.windowUpdate))
        XCTAssertFalse(operations.calls.contains(.activationControl))
    }

    func testWindowKeyRecoveryDispatchesExactlyOneDedicatedOperation() {
        let primitiveOperations = RecordingProbeOperations()
        let applicationActivationRecovery = RecordingApplicationActivationRecovery()
        let windowKeyRecovery = RecordingWindowKeyRecovery()
        let dispatcher = Issue96ProbeDispatcher(
            operations: primitiveOperations,
            applicationActivationRecovery: applicationActivationRecovery,
            windowKeyRecovery: windowKeyRecovery,
            windowResizeRecovery: RecordingWindowResizeRecovery())

        XCTAssertNotNil(dispatcher.dispatch(.recoveryWindowKey))
        XCTAssertEqual(windowKeyRecovery.calls, 1)
        XCTAssertTrue(primitiveOperations.calls.isEmpty)
        XCTAssertTrue(applicationActivationRecovery.calls.isEmpty)
    }

    func testWindowResizeRecoveryDispatchesExactlyOneDedicatedOperation() {
        let primitiveOperations = RecordingProbeOperations()
        let applicationActivationRecovery = RecordingApplicationActivationRecovery()
        let windowKeyRecovery = RecordingWindowKeyRecovery()
        let windowResizeRecovery = RecordingWindowResizeRecovery()
        let dispatcher = Issue96ProbeDispatcher(
            operations: primitiveOperations,
            applicationActivationRecovery: applicationActivationRecovery,
            windowKeyRecovery: windowKeyRecovery,
            windowResizeRecovery: windowResizeRecovery)

        XCTAssertEqual(
            dispatcher.dispatch(.recoveryWindowResize),
            .applied(api: "recording.window-resize-transition-only"))
        XCTAssertEqual(windowResizeRecovery.calls, 1)
        XCTAssertTrue(primitiveOperations.calls.isEmpty)
        XCTAssertTrue(applicationActivationRecovery.calls.isEmpty)
        XCTAssertEqual(windowKeyRecovery.calls, 0)
    }

    func testAlreadyActiveApplicationActivationFailsClosedWithoutActivationCall() {
        var activationCallCount = 0
        let coordinator = Issue96ApplicationActivationCoordinator(
            applicationIsActive: { true },
            activateApplication: { activationCallCount += 1 })

        let result = coordinator.run()

        XCTAssertEqual(
            result,
            .failed(
                api: "NSApplication.activate(ignoringOtherApps: true)",
                reason: "application-already-active"))
        XCTAssertEqual(activationCallCount, 0)
    }

    func testInactiveApplicationActivationInvokesOnlyInjectedActivationCall() {
        var activationCallCount = 0
        let coordinator = Issue96ApplicationActivationCoordinator(
            applicationIsActive: { false },
            activateApplication: { activationCallCount += 1 })

        let result = coordinator.run()

        XCTAssertEqual(
            result,
            .applied(api: "NSApplication.activate(ignoringOtherApps: true)"))
        XCTAssertEqual(activationCallCount, 1)
    }

    func testWindowKeyRecoveryUnavailableWindowFailsClosed() {
        var makeKeyCallCount = 0
        let coordinator = Issue96WindowKeyRecoveryCoordinator(
            windowExists: { false },
            windowIsOnTargetDisplay: { true },
            applicationIsActive: { true },
            windowIsKey: { false },
            makeWindowKey: { makeKeyCallCount += 1 })

        XCTAssertEqual(
            coordinator.run(),
            .failed(api: "window.makeKey()", reason: "diagnostic-window-unavailable"))
        XCTAssertEqual(makeKeyCallCount, 0)
    }

    func testWindowKeyRecoveryAlreadyKeyFailsClosedWithoutMakeKeyCall() {
        var makeKeyCallCount = 0
        let coordinator = Issue96WindowKeyRecoveryCoordinator(
            windowExists: { true },
            windowIsOnTargetDisplay: { true },
            applicationIsActive: { true },
            windowIsKey: { true },
            makeWindowKey: { makeKeyCallCount += 1 })

        XCTAssertEqual(
            coordinator.run(),
            .failed(api: "window.makeKey()", reason: "diagnostic-window-already-key"))
        XCTAssertEqual(makeKeyCallCount, 0)
    }

    func testWindowKeyRecoveryInactiveApplicationFailsClosedWithoutMakeKeyCall() {
        var makeKeyCallCount = 0
        let coordinator = Issue96WindowKeyRecoveryCoordinator(
            windowExists: { true },
            windowIsOnTargetDisplay: { true },
            applicationIsActive: { false },
            windowIsKey: { false },
            makeWindowKey: { makeKeyCallCount += 1 })
        let applicationActivationRecovery = RecordingApplicationActivationRecovery()
        let windowKeyRecovery = RecordingWindowKeyRecovery(result: { coordinator.run() })
        let dispatcher = Issue96ProbeDispatcher(
            operations: RecordingProbeOperations(),
            applicationActivationRecovery: applicationActivationRecovery,
            windowKeyRecovery: windowKeyRecovery,
            windowResizeRecovery: RecordingWindowResizeRecovery())

        XCTAssertEqual(dispatcher.dispatch(.recoveryWindowKey),
                       .failed(api: "window.makeKey()", reason: "application-not-active"))
        XCTAssertEqual(makeKeyCallCount, 0)
        XCTAssertTrue(applicationActivationRecovery.calls.isEmpty)
    }

    func testWindowKeyRecoveryOffTargetWindowFailsClosedWithoutMakeKeyCall() {
        var makeKeyCallCount = 0
        let coordinator = Issue96WindowKeyRecoveryCoordinator(
            windowExists: { true },
            windowIsOnTargetDisplay: { false },
            applicationIsActive: { true },
            windowIsKey: { false },
            makeWindowKey: { makeKeyCallCount += 1 })

        XCTAssertEqual(
            coordinator.run(),
            .failed(api: "window.makeKey()", reason: "diagnostic-window-not-on-target-display"))
        XCTAssertEqual(makeKeyCallCount, 0)
    }

    func testWindowKeyRecoveryValidStateCallsInjectedMakeKeyExactlyOnce() {
        var makeKeyCallCount = 0
        let coordinator = Issue96WindowKeyRecoveryCoordinator(
            windowExists: { true },
            windowIsOnTargetDisplay: { true },
            applicationIsActive: { true },
            windowIsKey: { false },
            makeWindowKey: { makeKeyCallCount += 1 })

        XCTAssertEqual(coordinator.run(), .applied(api: "window.makeKey()"))
        XCTAssertEqual(makeKeyCallCount, 1)
    }

    func testWindowResizeRecoveryUnavailableWindowFailsClosedWithoutResizeCall() {
        var resizeCallCount = 0
        let coordinator = Issue96WindowResizeRecoveryCoordinator(
            windowExists: { false },
            windowIsOnTargetDisplay: { true },
            currentFrame: { XCTFail("frame must not be read for an unavailable window"); return nil },
            proposedFrame: Issue96WindowResizeRecoveryConfiguration.resizedFrame,
            frameIsWithinResizeLimits: { _ in true },
            resizeWindow: { _ in resizeCallCount += 1 })

        XCTAssertEqual(
            coordinator.run(),
            .failed(
                api: Issue96WindowResizeRecoveryConfiguration.api,
                reason: "diagnostic-window-unavailable"))
        XCTAssertEqual(resizeCallCount, 0)
    }

    func testWindowResizeRecoveryOffTargetWindowFailsClosedWithoutResizeCall() {
        var resizeCallCount = 0
        let coordinator = Issue96WindowResizeRecoveryCoordinator(
            windowExists: { true },
            windowIsOnTargetDisplay: { false },
            currentFrame: { XCTFail("frame must not be read for an off-target window"); return nil },
            proposedFrame: Issue96WindowResizeRecoveryConfiguration.resizedFrame,
            frameIsWithinResizeLimits: { _ in true },
            resizeWindow: { _ in resizeCallCount += 1 })

        XCTAssertEqual(
            coordinator.run(),
            .failed(
                api: Issue96WindowResizeRecoveryConfiguration.api,
                reason: "diagnostic-window-not-on-target-display"))
        XCTAssertEqual(resizeCallCount, 0)
    }

    func testWindowResizeRecoveryUnavailableFrameFailsClosedWithoutResizeCall() {
        var resizeCallCount = 0
        let coordinator = Issue96WindowResizeRecoveryCoordinator(
            windowExists: { true },
            windowIsOnTargetDisplay: { true },
            currentFrame: { nil },
            proposedFrame: Issue96WindowResizeRecoveryConfiguration.resizedFrame,
            frameIsWithinResizeLimits: { _ in true },
            resizeWindow: { _ in resizeCallCount += 1 })

        XCTAssertEqual(
            coordinator.run(),
            .failed(
                api: Issue96WindowResizeRecoveryConfiguration.api,
                reason: "diagnostic-window-frame-unavailable"))
        XCTAssertEqual(resizeCallCount, 0)
    }

    func testWindowResizeRecoveryInvalidFrameFailsClosedWithoutResizeCall() {
        var resizeCallCount = 0
        let coordinator = Issue96WindowResizeRecoveryCoordinator(
            windowExists: { true },
            windowIsOnTargetDisplay: { true },
            currentFrame: { NSRect(x: 0, y: 0, width: 0, height: 220) },
            proposedFrame: Issue96WindowResizeRecoveryConfiguration.resizedFrame,
            frameIsWithinResizeLimits: { _ in true },
            resizeWindow: { _ in resizeCallCount += 1 })

        XCTAssertEqual(
            coordinator.run(),
            .failed(
                api: Issue96WindowResizeRecoveryConfiguration.api,
                reason: "diagnostic-window-frame-invalid"))
        XCTAssertEqual(resizeCallCount, 0)
    }

    func testWindowResizeRecoveryNonResizableFrameFailsClosedWithoutResizeCall() {
        var resizeCallCount = 0
        let frame = NSRect(x: 12, y: 34, width: 420, height: 220)
        let coordinator = Issue96WindowResizeRecoveryCoordinator(
            windowExists: { true },
            windowIsOnTargetDisplay: { true },
            currentFrame: { frame },
            proposedFrame: Issue96WindowResizeRecoveryConfiguration.resizedFrame,
            frameIsWithinResizeLimits: { _ in false },
            resizeWindow: { _ in resizeCallCount += 1 })

        XCTAssertEqual(
            coordinator.run(),
            .failed(
                api: Issue96WindowResizeRecoveryConfiguration.api,
                reason: "diagnostic-window-frame-not-resizable"))
        XCTAssertEqual(resizeCallCount, 0)
    }

    func testWindowResizeRecoveryInvalidRequestedFrameFailsClosedWithoutResizeCall() {
        var resizeCallCount = 0
        let frame = NSRect(x: 12, y: 34, width: 420, height: 220)
        let coordinator = Issue96WindowResizeRecoveryCoordinator(
            windowExists: { true },
            windowIsOnTargetDisplay: { true },
            currentFrame: { frame },
            proposedFrame: { _ in
                NSRect(x: 12, y: 34, width: CGFloat.infinity, height: 220)
            },
            frameIsWithinResizeLimits: { _ in true },
            resizeWindow: { _ in resizeCallCount += 1 })

        XCTAssertEqual(
            coordinator.run(),
            .failed(
                api: Issue96WindowResizeRecoveryConfiguration.api,
                reason: "requested-resize-frame-invalid"))
        XCTAssertEqual(resizeCallCount, 0)
    }

    func testWindowResizeRecoveryNoSizeChangeFailsClosedWithoutResizeCall() {
        var resizeCallCount = 0
        let frame = NSRect(x: 12, y: 34, width: 420, height: 220)
        let coordinator = Issue96WindowResizeRecoveryCoordinator(
            windowExists: { true },
            windowIsOnTargetDisplay: { true },
            currentFrame: { frame },
            proposedFrame: { _ in frame },
            frameIsWithinResizeLimits: { _ in true },
            resizeWindow: { _ in resizeCallCount += 1 })

        XCTAssertEqual(
            coordinator.run(),
            .failed(
                api: Issue96WindowResizeRecoveryConfiguration.api,
                reason: "resize-would-not-change-size"))
        XCTAssertEqual(resizeCallCount, 0)
    }

    func testWindowResizeRecoveryRequestedFrameOutsideLimitsFailsClosedWithoutResizeCall() {
        var resizeCallCount = 0
        var validationCallCount = 0
        let frame = NSRect(x: 12, y: 34, width: 420, height: 220)
        let coordinator = Issue96WindowResizeRecoveryCoordinator(
            windowExists: { true },
            windowIsOnTargetDisplay: { true },
            currentFrame: { frame },
            proposedFrame: Issue96WindowResizeRecoveryConfiguration.resizedFrame,
            frameIsWithinResizeLimits: { _ in
                validationCallCount += 1
                return validationCallCount == 1
            },
            resizeWindow: { _ in resizeCallCount += 1 })

        XCTAssertEqual(
            coordinator.run(),
            .failed(
                api: Issue96WindowResizeRecoveryConfiguration.api,
                reason: "requested-resize-frame-not-resizable"))
        XCTAssertEqual(resizeCallCount, 0)
    }

    func testWindowResizeRecoveryValidStateRequestsOneDeterministicResizeWithoutRestore() {
        var resizeCallCount = 0
        var requestedFrame: NSRect?
        let frame = NSRect(x: 12, y: 34, width: 420, height: 220)
        let coordinator = Issue96WindowResizeRecoveryCoordinator(
            windowExists: { true },
            windowIsOnTargetDisplay: { true },
            currentFrame: { frame },
            proposedFrame: Issue96WindowResizeRecoveryConfiguration.resizedFrame,
            frameIsWithinResizeLimits: { _ in true },
            resizeWindow: {
                resizeCallCount += 1
                requestedFrame = $0
            })

        XCTAssertEqual(
            coordinator.run(),
            .applied(api: Issue96WindowResizeRecoveryConfiguration.api))
        XCTAssertEqual(resizeCallCount, 1)
        XCTAssertEqual(
            requestedFrame,
            NSRect(x: 12, y: 34, width: 436, height: 220))
    }

    func testWindowKeyRecoveryFailureResponseIsExplicitAndNonRecoveryClaiming() {
        let state = Issue96ProbeWindowState(appIsActive: true, isKeyWindow: true, isMainWindow: false)
        let record = Issue96ProbeRecord(
            sequence: 9,
            monotonicNanoseconds: 789,
            kind: .recoveryWindowKey,
            targetDisplayID: 11,
            panelDisplayID: 11,
            before: state,
            after: state,
            result: .failed(api: "window.makeKey()", reason: "diagnostic-window-already-key"))

        XCTAssertEqual(
            record.responseLine,
            "ERROR sequence=9 kind=recovery-window-key reason=diagnostic-window-already-key")
        XCTAssertFalse(record.responseLine.contains("recovered"))
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
        XCTAssertTrue(Issue96ProbeWindowConfiguration.mouseTrackingAreaOptions.contains(.activeAlways))
        XCTAssertTrue(Issue96ProbeWindowConfiguration.mouseTrackingAreaOptions.contains(.mouseMoved))
        XCTAssertFalse(Issue96ProbeWindowConfiguration.mouseTrackingAreaOptions.contains(.cursorUpdate))
        XCTAssertTrue(Issue96ProbeWindowConfiguration.cursorUpdateTrackingAreaOptions.contains(.activeInActiveApp))
        XCTAssertTrue(Issue96ProbeWindowConfiguration.cursorUpdateTrackingAreaOptions.contains(.cursorUpdate))
        XCTAssertFalse(Issue96ProbeWindowConfiguration.cursorUpdateTrackingAreaOptions.contains(.activeAlways))
        XCTAssertEqual(
            Issue96CursorRegion.cursorRegions,
            [.resizeHorizontal, .resizeVertical, .resizeDiagonal])
    }

    func testTraceControlCommandsDoNotDispatchAppKitPrimitives() {
        let operations = RecordingProbeOperations()
        let dispatcher = Issue96ProbeDispatcher(
            operations: operations,
            applicationActivationRecovery: operations,
            windowKeyRecovery: operations,
            windowResizeRecovery: operations)
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

    func testTruncatedTraceDumpPreservesNewestChronologicalSuffixAndMarker() {
        let trace = Issue96LifecycleTrace(targetDisplayID: 11, capacity: 1_000)
        for _ in 0..<999 {
            trace.record(event: .mouseMoved, region: .background)
        }
        let marker = trace.record(event: .markerBrokenConfirmed)

        let dump = trace.dumpResponse()
        let lines = dump.split(separator: "\n").map(String.init)
        let sequenceLines = lines.filter { $0.hasPrefix("TRACE sequence=") }
        let sequences = sequenceLines.compactMap { line -> UInt64? in
            let fields = line.split(separator: " ")
            guard let sequence = fields.first(where: { $0.hasPrefix("sequence=") }) else { return nil }
            return UInt64(sequence.dropFirst("sequence=".count))
        }

        XCTAssertTrue(dump.contains("truncated=true"))
        XCTAssertTrue(dump.contains("event=marker-broken-confirmed"))
        XCTAssertTrue(dump.contains("sequence=\(marker.sequence)"))
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(sequences.last, marker.sequence)
        XCTAssertLessThanOrEqual(dump.utf8.count, Issue96LifecycleTrace.maximumDumpBytes)
    }

    func testSocketWriterCompletesLargePayloadAcrossShortWritesAndEINTR() {
        let payload = Data((0..<(Issue96LifecycleTrace.maximumDumpBytes + 123)).map { UInt8($0 % 251) })
        var received = Data()
        var callCount = 0
        var shouldInterrupt = true

        let success = Issue96ProbeSocketWriter.writeAll(payload, to: 99) { _, pointer, count in
            callCount += 1
            if shouldInterrupt {
                shouldInterrupt = false
                errno = EINTR
                return -1
            }
            guard let pointer else { return -1 }
            let amount = min(count, 17)
            received.append(Data(bytes: pointer, count: amount))
            return amount
        }

        XCTAssertTrue(success)
        XCTAssertEqual(received, payload)
        XCTAssertGreaterThan(callCount, 2)
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

    func testDiagnosticPanelSubclassIsKeyCapableWithoutChangingBaselineState() {
        let panel = Issue96ProbePanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: Issue96ProbeWindowConfiguration.styleMask,
            backing: .buffered,
            defer: true)
        panel.becomesKeyOnlyIfNeeded = Issue96ProbeWindowConfiguration.becomesKeyOnlyIfNeeded

        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isMainWindow)
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
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

    func testApplicationActivationFailureResponseIsExplicitAndNonRecoveryClaiming() {
        let state = Issue96ProbeWindowState(appIsActive: true, isKeyWindow: false, isMainWindow: false)
        let record = Issue96ProbeRecord(
            sequence: 8,
            monotonicNanoseconds: 456,
            kind: .recoveryAppActivate,
            targetDisplayID: 11,
            panelDisplayID: 11,
            before: state,
            after: state,
            result: .failed(
                api: "NSApplication.activate(ignoringOtherApps: true)",
                reason: "application-already-active"))

        XCTAssertEqual(
            record.responseLine,
            "ERROR sequence=8 kind=recovery-app-activate reason=application-already-active")
        XCTAssertFalse(record.responseLine.contains("recovered"))
    }

    func testWindowResizeFailureResponseIsExplicitAndNonRecoveryClaiming() {
        let state = Issue96ProbeWindowState(appIsActive: false, isKeyWindow: false, isMainWindow: false)
        let record = Issue96ProbeRecord(
            sequence: 10,
            monotonicNanoseconds: 800,
            kind: .recoveryWindowResize,
            targetDisplayID: 11,
            panelDisplayID: 11,
            before: state,
            after: state,
            result: .failed(
                api: Issue96WindowResizeRecoveryConfiguration.api,
                reason: "diagnostic-window-frame-invalid"),
            beforePanelSize: Issue96ProbeWindowSize(width: 420, height: 220),
            afterPanelSize: Issue96ProbeWindowSize(width: 420, height: 220))

        XCTAssertEqual(
            record.responseLine,
            "ERROR sequence=10 kind=recovery-window-resize reason=diagnostic-window-frame-invalid")
        XCTAssertTrue(record.logMessage.contains("api=window.setFrame(_:display: false, animate: false)"))
        XCTAssertTrue(record.logMessage.contains("panel_size_before=420.0x220.0"))
        XCTAssertTrue(record.logMessage.contains("panel_size_after=420.0x220.0"))
        XCTAssertFalse(record.responseLine.contains("recovered"))
    }

    private func display(_ id: CGDirectDisplayID, edge: ScreenEdge? = nil) -> HostDisplayEdgeOption {
        HostDisplayEdgeOption(id: id, name: "Display \(id)", width: 1920, height: 1080, edge: edge)
    }
}

@MainActor
private final class RecordingProbeOperations: Issue96ProbePrimitiveOperations,
    Issue96ApplicationActivationRecoveryOperations,
    Issue96WindowKeyRecoveryOperations,
    Issue96WindowResizeRecoveryOperations {
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

    func applicationActivationOnly() -> Issue96ProbeOperationResult {
        calls.append(.recoveryAppActivate)
        return .applied(api: "recording.application-activation-only")
    }

    func windowKeyTransitionOnly() -> Issue96ProbeOperationResult {
        calls.append(.recoveryWindowKey)
        return .applied(api: "recording.window-key-transition-only")
    }

    func windowResizeTransitionOnly() -> Issue96ProbeOperationResult {
        calls.append(.recoveryWindowResize)
        return .applied(api: "recording.window-resize-transition-only")
    }
}

@MainActor
private final class RecordingApplicationActivationRecovery: Issue96ApplicationActivationRecoveryOperations {
    var calls: [Issue96ProbeCommand] = []

    func applicationActivationOnly() -> Issue96ProbeOperationResult {
        calls.append(.recoveryAppActivate)
        return .applied(api: "recording.application-activation-only")
    }
}

@MainActor
private final class RecordingWindowKeyRecovery: Issue96WindowKeyRecoveryOperations {
    var calls = 0
    private let result: () -> Issue96ProbeOperationResult

    init(result: @escaping () -> Issue96ProbeOperationResult = {
        .applied(api: "recording.window-key-transition-only")
    }) {
        self.result = result
    }

    func windowKeyTransitionOnly() -> Issue96ProbeOperationResult {
        calls += 1
        return result()
    }
}

@MainActor
private final class RecordingWindowResizeRecovery: Issue96WindowResizeRecoveryOperations {
    var calls = 0

    func windowResizeTransitionOnly() -> Issue96ProbeOperationResult {
        calls += 1
        return .applied(api: "recording.window-resize-transition-only")
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
