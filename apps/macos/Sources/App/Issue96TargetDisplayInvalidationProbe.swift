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

    static var probeKinds: [Issue96ProbeCommand] {
        allCases.filter { $0 != .status }
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
        case .status:
            return nil
        }
    }
}

enum Issue96ProbeWindowConfiguration {
    static let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
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
    private var ownedTrackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    /// Rebuilds only the tracking area owned by this diagnostic view.
    func rebuildOwnedTrackingArea() {
        if let ownedTrackingArea {
            removeTrackingArea(ownedTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        ownedTrackingArea = area
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildOwnedTrackingArea()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        dirtyRect.fill()

        let title = NSAttributedString(
            string: "CrossInput Issue #96 probe",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])
        let titleRect = NSRect(x: 12, y: bounds.midY - 7, width: bounds.width - 24, height: 18)
        title.draw(in: titleRect)
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

    private let dispatcher: Issue96ProbeDispatcher
    private let endpoint: Issue96ProbeControlEndpoint
    private var probeSequence: UInt64 = 0

    init?(targetDisplayID selectedDisplayID: CGDirectDisplayID, screens: [NSScreen] = NSScreen.screens) {
        guard let targetScreen = screens.first(where: {
            Self.displayID(for: $0) == selectedDisplayID
        }) else {
            Diagnostics.log(
                "issue96-target-display-probe startup result=fail-closed reason=target-display-unavailable target_display_id=\(selectedDisplayID)")
            return nil
        }

        let size = NSSize(width: 220, height: 64)
        let frame = Issue96ProbeWindowFrame.centered(
            visibleFrame: targetScreen.visibleFrame,
            screenFrame: targetScreen.frame,
            size: size)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: Issue96ProbeWindowConfiguration.styleMask,
            backing: .buffered,
            defer: false,
            screen: targetScreen)
        let view = Issue96ProbeView(frame: NSRect(origin: .zero, size: size))

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
        panel.orderFrontRegardless()
        view.rebuildOwnedTrackingArea()

        let operations = Issue96ProbeAppKitOperations(window: panel, view: view)
        let endpoint = Issue96ProbeControlEndpoint(path: Issue96ProbeConfiguration.socketPath)

        self.targetDisplayID = selectedDisplayID
        self.panel = panel
        self.view = view
        self.dispatcher = Issue96ProbeDispatcher(operations: operations)
        self.endpoint = endpoint

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
        endpoint.stop()
        panel.orderOut(nil)
    }

    private func handle(line: String) -> String {
        guard let command = Issue96ProbeCommand.parse(line) else {
            return "ERROR reason=unsupported-command\n"
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
            + " app_active=\(state.appIsActive) key=\(state.isKeyWindow) main=\(state.isMainWindow)\n"
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
