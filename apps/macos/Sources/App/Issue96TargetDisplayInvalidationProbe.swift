import AppKit
import Foundation
import Diagnostics

/// Opt-in controls for the Issue #96 diagnostic-only AppKit probe.
enum Issue96ProbeConfiguration {
    static let enabledEnvironmentKey = "CROSSINPUT_DIAG_TARGET_DISPLAY_INVALIDATION"
    static let socketEnvironmentKey = "CROSSINPUT_ISSUE96_PROBE_SOCKET"

    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[enabledEnvironmentKey] == "1"
    }

    static var socketPath: String {
        if let configured = ProcessInfo.processInfo.environment[socketEnvironmentKey],
           !configured.isEmpty {
            return configured
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ampersand/Diagnostics/issue-96-target-display.sock")
            .path
    }
}

enum Issue96ProbeCommand: String, CaseIterable, Sendable {
    case redraw
    case cursorRect = "cursor-rect"
    case trackingArea = "tracking-area"
    case windowUpdate = "window-update"
    case activationControl = "activation-control"
    case status
    case markBaselineHealthy = "mark-baseline-healthy"
    case markBrokenConfirmed = "mark-broken-confirmed"
    case markRecoveryAction = "mark-recovery-action"
    case markRecovered = "mark-recovered"
    case markStillBroken = "mark-still-broken"
    case clearTrace = "clear-trace"
    case dumpTrace = "dump-trace"

    static var probeKinds: [Issue96ProbeCommand] {
        [.redraw, .cursorRect, .trackingArea, .windowUpdate, .activationControl]
    }

    static var traceControlKinds: [Issue96ProbeCommand] {
        [
            .markBaselineHealthy,
            .markBrokenConfirmed,
            .markRecoveryAction,
            .markRecovered,
            .markStillBroken,
            .clearTrace,
            .dumpTrace,
        ]
    }

    var markerEvent: Issue96LifecycleEvent? {
        switch self {
        case .markBaselineHealthy:
            return .markerBaselineHealthy
        case .markBrokenConfirmed:
            return .markerBrokenConfirmed
        case .markRecoveryAction:
            return .markerRecoveryAction
        case .markRecovered:
            return .markerRecovered
        case .markStillBroken:
            return .markerStillBroken
        default:
            return nil
        }
    }

    static func parse(_ line: String) -> Issue96ProbeCommand? {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return Issue96ProbeCommand(rawValue: value)
    }
}

enum Issue96TargetDisplaySelection: Equatable {
    case selected(CGDirectDisplayID)
    case noneConfigured
    case ambiguous([CGDirectDisplayID])

    static func resolve(from displays: [HostDisplayEdgeOption]) -> Issue96TargetDisplaySelection {
        let configured = displays.filter { $0.edge != nil }.map(\.id)
        switch configured.count {
        case 0:
            return .noneConfigured
        case 1:
            return .selected(configured[0])
        default:
            return .ambiguous(configured)
        }
    }

    var failClosedReason: String? {
        switch self {
        case .selected:
            return nil
        case .noneConfigured:
            return "no-configured-target"
        case .ambiguous:
            return "multiple-configured-targets"
        }
    }
}

@MainActor
enum Issue96ProbeFactory {
    static func makeIfEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        targetDisplayID: CGDirectDisplayID,
        screens: [NSScreen] = NSScreen.screens) -> Issue96TargetDisplayInvalidationProbeHarness? {
        guard Issue96ProbeConfiguration.isEnabled(environment: environment) else { return nil }
        return Issue96TargetDisplayInvalidationProbeHarness(
            targetDisplayID: targetDisplayID,
            screens: screens)
    }
}

enum Issue96ProbeOperationResult: Equatable, Sendable {
    case applied(api: String)
    case failed(api: String, reason: String)

    var api: String {
        switch self {
        case let .applied(api), let .failed(api, _):
            return api
        }
    }

    var succeeded: Bool {
        if case .applied = self { return true }
        return false
    }

    var failureReason: String? {
        if case let .failed(_, reason) = self { return reason }
        return nil
    }
}

/// AppKit calls used by the five independently dispatched probe families.
/// Keeping this as one method per family makes accidental operation stacking
/// visible in tests and keeps the control endpoint from becoming an AppKit
/// command language.
@MainActor
protocol Issue96ProbePrimitiveOperations: AnyObject {
    func redrawOnly() -> Issue96ProbeOperationResult
    func cursorRectInvalidationOnly() -> Issue96ProbeOperationResult
    func trackingAreaRebuildOnly() -> Issue96ProbeOperationResult
    func nonActivatingWindowUpdateOnly() -> Issue96ProbeOperationResult
    func activationPositiveControl() -> Issue96ProbeOperationResult
}

@MainActor
struct Issue96ProbeDispatcher {
    private let operations: any Issue96ProbePrimitiveOperations

    init(operations: any Issue96ProbePrimitiveOperations) {
        self.operations = operations
    }

    func dispatch(_ command: Issue96ProbeCommand) -> Issue96ProbeOperationResult? {
        switch command {
        case .redraw:
            return operations.redrawOnly()
        case .cursorRect:
            return operations.cursorRectInvalidationOnly()
        case .trackingArea:
            return operations.trackingAreaRebuildOnly()
        case .windowUpdate:
            return operations.nonActivatingWindowUpdateOnly()
        case .activationControl:
            return operations.activationPositiveControl()
        case .status, .markBaselineHealthy, .markBrokenConfirmed, .markRecoveryAction,
             .markRecovered, .markStillBroken, .clearTrace, .dumpTrace:
            return nil
        }
    }
}

enum Issue96ProbeWindowConfiguration {
    static let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    static let trackingAreaOptions: NSTrackingArea.Options = [
        .activeAlways,
        .mouseEnteredAndExited,
        .mouseMoved,
        .cursorUpdate,
    ]
    static let becomesKeyOnlyIfNeeded = true
    static let initiallyMakesKeyWindow = false
    static let initiallyMakesMainWindow = false
    static let initiallyActivatesApplication = false
}

enum Issue96ProbeWindowFrame {
    /// NSWindow's initializer with an explicit screen interprets the initial
    /// content rect in that screen's local coordinate space. NSScreen frames
    /// are global, so normalize the visible frame before centering the panel;
    /// otherwise a non-primary screen origin is applied twice.
    static func centered(
        visibleFrame: NSRect,
        screenFrame: NSRect,
        size: NSSize) -> NSRect {
        let localVisibleFrame = NSRect(
            x: visibleFrame.minX - screenFrame.minX,
            y: visibleFrame.minY - screenFrame.minY,
            width: visibleFrame.width,
            height: visibleFrame.height)
        return NSRect(
            x: localVisibleFrame.midX - size.width / 2,
            y: localVisibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height)
    }
}

struct Issue96ProbeWindowState: Equatable, Sendable {
    let appIsActive: Bool
    let isKeyWindow: Bool
    let isMainWindow: Bool
}

struct Issue96ProbeRecord: Equatable, Sendable {
    let sequence: UInt64
    let monotonicNanoseconds: UInt64
    let kind: Issue96ProbeCommand
    let targetDisplayID: CGDirectDisplayID
    let panelDisplayID: CGDirectDisplayID?
    let before: Issue96ProbeWindowState
    let after: Issue96ProbeWindowState
    let result: Issue96ProbeOperationResult

    private static func displayID(_ value: CGDirectDisplayID?) -> String {
        value.map(String.init) ?? "none"
    }

    var logMessage: String {
        var message = "issue96-target-display-probe"
            + " sequence=\(sequence)"
            + " monotonic_ns=\(monotonicNanoseconds)"
            + " kind=\(kind.rawValue)"
            + " target_display_id=\(targetDisplayID)"
            + " panel_display_id=\(Self.displayID(panelDisplayID))"
            + " app_active_before=\(before.appIsActive)"
            + " app_active_after=\(after.appIsActive)"
            + " key_before=\(before.isKeyWindow)"
            + " key_after=\(after.isKeyWindow)"
            + " main_before=\(before.isMainWindow)"
            + " main_after=\(after.isMainWindow)"
            + " api=\(result.api)"
            + " api_success=\(result.succeeded)"
        if let failureReason = result.failureReason {
            message += " fail_closed_reason=\(failureReason)"
        }
        return message
    }

    var responseLine: String {
        "OK sequence=\(sequence) kind=\(kind.rawValue) api_success=\(result.succeeded)"
    }
}

@MainActor
final class Issue96ProbeView: NSView {
    private let lifecycleTrace: Issue96LifecycleTrace?
    private var ownedTrackingArea: NSTrackingArea?

    init(frame frameRect: NSRect, lifecycleTrace: Issue96LifecycleTrace? = nil) {
        self.lifecycleTrace = lifecycleTrace
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        lifecycleTrace = nil
        super.init(coder: coder)
    }

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    override func resetCursorRects() {
        lifecycleTrace?.record(event: .resetCursorRects)
        addCursorRect(rect(for: .resizeHorizontal), cursor: .resizeLeftRight)
        addCursorRect(rect(for: .resizeVertical), cursor: .resizeUpDown)
    }

    /// Rebuilds only the tracking area owned by this diagnostic view.
    func rebuildOwnedTrackingArea() {
        if let ownedTrackingArea {
            removeTrackingArea(ownedTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: Issue96ProbeWindowConfiguration.trackingAreaOptions,
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        ownedTrackingArea = area
    }

    override func updateTrackingAreas() {
        lifecycleTrace?.record(event: .updateTrackingAreas)
        super.updateTrackingAreas()
        rebuildOwnedTrackingArea()
    }

    override func cursorUpdate(with event: NSEvent) {
        let region = region(at: event.locationInWindow)
        lifecycleTrace?.record(event: .cursorUpdate, region: region)
        cursor(for: region).set()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        lifecycleTrace?.record(event: .mouseEntered, region: region(at: event.locationInWindow))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        lifecycleTrace?.record(event: .mouseExited, region: region(at: event.locationInWindow))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        lifecycleTrace?.record(event: .mouseMoved, region: region(at: event.locationInWindow))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lifecycleTrace?.record(event: .viewDidMoveToWindow)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        lifecycleTrace?.record(event: .viewDidMoveToSuperview)
    }

    override func layout() {
        super.layout()
        lifecycleTrace?.record(event: .viewLayout)
    }

    override func draw(_ dirtyRect: NSRect) {
        lifecycleTrace?.record(event: .viewDraw)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        dirtyRect.fill()

        let title = NSAttributedString(
            string: "CrossInput Issue #96 cursor lifecycle",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])
        let titleRect = NSRect(x: 16, y: bounds.maxY - 30, width: bounds.width - 32, height: 18)
        title.draw(in: titleRect)

        let colors: [Issue96CursorRegion: NSColor] = [
            .resizeHorizontal: .systemBlue,
            .resizeVertical: .systemGreen,
            .resizeDiagonal: .systemOrange,
        ]
        for region in Issue96CursorRegion.cursorRegions {
            let regionRect = rect(for: region)
            colors[region]?.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: regionRect, xRadius: 8, yRadius: 8).fill()
            colors[region]?.setStroke()
            let border = NSBezierPath(roundedRect: regionRect, xRadius: 8, yRadius: 8)
            border.lineWidth = 1
            border.stroke()

            let label = NSAttributedString(
                string: region.rawValue,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.labelColor,
                ])
            label.draw(in: regionRect.insetBy(dx: 8, dy: regionRect.height / 2 - 8))
        }
    }

    private func rect(for region: Issue96CursorRegion) -> NSRect {
        let regions = Issue96CursorRegion.cursorRegions
        guard let index = regions.firstIndex(of: region) else { return .zero }
        let gap: CGFloat = 12
        let left: CGFloat = 16
        let width = (bounds.width - left * 2 - gap * CGFloat(regions.count - 1))
            / CGFloat(regions.count)
        return NSRect(
            x: left + CGFloat(index) * (width + gap),
            y: 32,
            width: width,
            height: bounds.height - 78)
    }

    private func region(at point: NSPoint) -> Issue96CursorRegion {
        for region in Issue96CursorRegion.cursorRegions where rect(for: region).contains(point) {
            return region
        }
        return .background
    }

    private func cursor(for region: Issue96CursorRegion) -> NSCursor {
        switch region {
        case .resizeHorizontal:
            return .resizeLeftRight
        case .resizeVertical:
            return .resizeUpDown
        case .resizeDiagonal, .background:
            // AppKit exposes built-in horizontal/vertical resize cursors but
            // no built-in diagonal resize cursor on this SDK. Keep the
            // diagonal tile as a symbolic lifecycle region without inventing
            // a custom cursor that would obscure native behavior.
            return .arrow
        }
    }
}

@MainActor
final class Issue96ProbeAppKitOperations: Issue96ProbePrimitiveOperations {
    weak var window: NSWindow?
    let view: Issue96ProbeView

    init(window: NSWindow, view: Issue96ProbeView) {
        self.window = window
        self.view = view
    }

    func redrawOnly() -> Issue96ProbeOperationResult {
        view.needsDisplay = true
        view.displayIfNeeded()
        return .applied(api: "view.needsDisplay+view.displayIfNeeded")
    }

    func cursorRectInvalidationOnly() -> Issue96ProbeOperationResult {
        guard let window else {
            return .failed(api: "window.invalidateCursorRects(for:diagnosticView)", reason: "diagnostic-window-unavailable")
        }
        window.invalidateCursorRects(for: view)
        return .applied(api: "window.invalidateCursorRects(for:diagnosticView)")
    }

    func trackingAreaRebuildOnly() -> Issue96ProbeOperationResult {
        view.rebuildOwnedTrackingArea()
        return .applied(api: "view.removeTrackingArea+view.addTrackingArea")
    }

    func nonActivatingWindowUpdateOnly() -> Issue96ProbeOperationResult {
        guard let window else {
            return .failed(api: "window.orderFront(nil)", reason: "diagnostic-window-unavailable")
        }
        window.orderFront(nil)
        return .applied(api: "window.orderFront(nil)")
    }

    func activationPositiveControl() -> Issue96ProbeOperationResult {
        guard let window else {
            return .failed(
                api: "NSApp.activate+window.makeKeyAndOrderFront",
                reason: "diagnostic-window-unavailable")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return .applied(api: "NSApp.activate+window.makeKeyAndOrderFront")
    }
}

@MainActor
final class Issue96TargetDisplayInvalidationProbeHarness {
    let targetDisplayID: CGDirectDisplayID
    let panel: NSPanel
    let view: Issue96ProbeView
    let lifecycleTrace: Issue96LifecycleTrace

    private let dispatcher: Issue96ProbeDispatcher
    private let endpoint: Issue96ProbeControlEndpoint
    private let lifecycleObservers: Issue96LifecycleObservers
    private var probeSequence: UInt64 = 0

    init?(targetDisplayID selectedDisplayID: CGDirectDisplayID, screens: [NSScreen] = NSScreen.screens) {
        guard let targetScreen = screens.first(where: {
            Self.displayID(for: $0) == selectedDisplayID
        }) else {
            Diagnostics.log(
                "issue96-target-display-probe startup result=fail-closed reason=target-display-unavailable target_display_id=\(selectedDisplayID)")
            return nil
        }

        let size = NSSize(width: 420, height: 220)
        let frame = Issue96ProbeWindowFrame.centered(
            visibleFrame: targetScreen.visibleFrame,
            screenFrame: targetScreen.frame,
            size: size)
        let lifecycleTrace = Issue96LifecycleTrace(targetDisplayID: selectedDisplayID)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: Issue96ProbeWindowConfiguration.styleMask,
            backing: .buffered,
            defer: false,
            screen: targetScreen)
        lifecycleTrace.window = panel
        let view = Issue96ProbeView(
            frame: NSRect(origin: .zero, size: size),
            lifecycleTrace: lifecycleTrace)

        panel.contentView = view
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = Issue96ProbeWindowConfiguration.becomesKeyOnlyIfNeeded
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level.floating
        panel.collectionBehavior = NSWindow.CollectionBehavior(
            arrayLiteral: .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle)
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        let lifecycleObservers = Issue96LifecycleObservers(trace: lifecycleTrace, window: panel)
        panel.orderFrontRegardless()
        view.rebuildOwnedTrackingArea()

        let operations = Issue96ProbeAppKitOperations(window: panel, view: view)
        let endpoint = Issue96ProbeControlEndpoint(path: Issue96ProbeConfiguration.socketPath)

        self.targetDisplayID = selectedDisplayID
        self.panel = panel
        self.view = view
        self.lifecycleTrace = lifecycleTrace
        self.dispatcher = Issue96ProbeDispatcher(operations: operations)
        self.endpoint = endpoint
        self.lifecycleObservers = lifecycleObservers

        do {
            try endpoint.start { [weak self] line in
                await self?.handle(line: line) ?? "ERROR reason=harness-unavailable\n"
            }
        } catch {
            panel.orderOut(nil)
            Diagnostics.log(
                "issue96-target-display-probe startup result=fail-closed reason=control-endpoint-unavailable")
            return nil
        }

        Diagnostics.log(
            "issue96-target-display-probe startup result=ready target_display_id=\(selectedDisplayID) endpoint=unix")
    }

    func stop() {
        lifecycleObservers.stop()
        endpoint.stop()
        panel.orderOut(nil)
    }

    private func handle(line: String) -> String {
        guard let command = Issue96ProbeCommand.parse(line) else {
            return "ERROR reason=unsupported-command\n"
        }
        if let traceResponse = Issue96ProbeTraceControl.handle(command, trace: lifecycleTrace) {
            return traceResponse
        }
        if command == .status {
            return statusLine()
        }

        let before = windowState()
        probeSequence &+= 1
        let result = dispatcher.dispatch(command)
            ?? .failed(api: "dispatcher", reason: "unsupported-command")
        let after = windowState()
        let record = Issue96ProbeRecord(
            sequence: probeSequence,
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            kind: command,
            targetDisplayID: targetDisplayID,
            panelDisplayID: Self.displayID(for: panel.screen),
            before: before,
            after: after,
            result: result)
        Diagnostics.log(record.logMessage)
        return record.responseLine + "\n"
    }

    private func statusLine() -> String {
        let state = windowState()
        let panelDisplayID = Self.displayID(for: panel.screen).map(String.init) ?? "none"
        return "OK kind=status target_display_id=\(targetDisplayID) panel_display_id=\(panelDisplayID)"
            + " app_active=\(state.appIsActive) key=\(state.isKeyWindow) main=\(state.isMainWindow)"
            + " trace_count=\(lifecycleTrace.count)\n"
    }

    private func windowState() -> Issue96ProbeWindowState {
        Issue96ProbeWindowState(
            appIsActive: NSApplication.shared.isActive,
            isKeyWindow: panel.isKeyWindow,
            isMainWindow: panel.isMainWindow)
    }

    private static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let number = screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}
