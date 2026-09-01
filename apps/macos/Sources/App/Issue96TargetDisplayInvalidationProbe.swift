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
    case recoveryAppActivate = "recovery-app-activate"
    case recoveryWindowKey = "recovery-window-key"
    case recoveryWindowResize = "recovery-window-resize"
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

    static var recoveryKinds: [Issue96ProbeCommand] {
        [.recoveryAppActivate, .recoveryWindowKey, .recoveryWindowResize]
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

/// The affected-window recovery experiment is intentionally separate from the
/// historical primitive operations. This keeps the new command from being
/// silently routed through the old activation positive control.
@MainActor
protocol Issue96ApplicationActivationRecoveryOperations: AnyObject {
    func applicationActivationOnly() -> Issue96ProbeOperationResult
}

/// The affected-window key transition is a separate recovery experiment. It
/// intentionally has no application-activation operation available to it.
@MainActor
protocol Issue96WindowKeyRecoveryOperations: AnyObject {
    func windowKeyTransitionOnly() -> Issue96ProbeOperationResult
}

/// The affected-window resize is a separate recovery experiment. It exposes
/// only the one public frame mutation required by that experiment.
@MainActor
protocol Issue96WindowResizeRecoveryOperations: AnyObject {
    func windowResizeTransitionOnly() -> Issue96ProbeOperationResult
}

/// The state transition itself is kept injectable so the already-active
/// fail-closed branch can be tested without activating the test runner.
@MainActor
struct Issue96ApplicationActivationCoordinator {
    let applicationIsActive: () -> Bool
    let activateApplication: () -> Void

    func run() -> Issue96ProbeOperationResult {
        let api = "NSApplication.activate(ignoringOtherApps: true)"
        guard !applicationIsActive() else {
            return .failed(api: api, reason: "application-already-active")
        }

        activateApplication()
        return .applied(api: api)
    }
}

/// Preconditions and the one requested key-window operation are injectable so
/// tests can exercise the exact state machine without changing XCTest window
/// or application state.
@MainActor
struct Issue96WindowKeyRecoveryCoordinator {
    let windowExists: () -> Bool
    let windowIsOnTargetDisplay: () -> Bool
    let applicationIsActive: () -> Bool
    let windowIsKey: () -> Bool
    let makeWindowKey: () -> Void

    func run() -> Issue96ProbeOperationResult {
        let api = "window.makeKey()"
        guard windowExists() else {
            return .failed(api: api, reason: "diagnostic-window-unavailable")
        }
        guard windowIsOnTargetDisplay() else {
            return .failed(api: api, reason: "diagnostic-window-not-on-target-display")
        }
        guard applicationIsActive() else {
            return .failed(api: api, reason: "application-not-active")
        }
        guard !windowIsKey() else {
            return .failed(api: api, reason: "diagnostic-window-already-key")
        }

        makeWindowKey()
        return .applied(api: api)
    }
}

enum Issue96WindowResizeRecoveryConfiguration {
    static let widthDelta: CGFloat = 16
    static let api = "window.setFrame(_:display: false, animate: false)"

    static func resizedFrame(from frame: NSRect) -> NSRect {
        NSRect(
            origin: frame.origin,
            size: NSSize(width: frame.width + widthDelta, height: frame.height))
    }

    static func isValidFrame(_ frame: NSRect) -> Bool {
        guard !frame.isNull, !frame.isInfinite else { return false }
        return frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }

    static func isSizeWithinLimits(
        _ size: NSSize,
        minimum: NSSize,
        maximum: NSSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite,
              minimum.width.isFinite, minimum.height.isFinite,
              maximum.width.isFinite, maximum.height.isFinite,
              minimum.width >= 0, minimum.height >= 0,
              maximum.width >= minimum.width, maximum.height >= minimum.height else {
            return false
        }
        return size.width >= minimum.width
            && size.height >= minimum.height
            && size.width <= maximum.width
            && size.height <= maximum.height
    }
}

/// Preconditions and the one requested resize operation are injectable so
/// tests can prove that every invalid state fails before mutation.
@MainActor
struct Issue96WindowResizeRecoveryCoordinator {
    let windowExists: () -> Bool
    let windowIsOnTargetDisplay: () -> Bool
    let currentFrame: () -> NSRect?
    let proposedFrame: (NSRect) -> NSRect
    let frameIsWithinResizeLimits: (NSRect) -> Bool
    let resizeWindow: (NSRect) -> Void

    func run() -> Issue96ProbeOperationResult {
        let api = Issue96WindowResizeRecoveryConfiguration.api
        guard windowExists() else {
            return .failed(api: api, reason: "diagnostic-window-unavailable")
        }
        guard windowIsOnTargetDisplay() else {
            return .failed(api: api, reason: "diagnostic-window-not-on-target-display")
        }
        guard let currentFrame = currentFrame() else {
            return .failed(api: api, reason: "diagnostic-window-frame-unavailable")
        }
        guard Issue96WindowResizeRecoveryConfiguration.isValidFrame(currentFrame) else {
            return .failed(api: api, reason: "diagnostic-window-frame-invalid")
        }
        guard frameIsWithinResizeLimits(currentFrame) else {
            return .failed(api: api, reason: "diagnostic-window-frame-not-resizable")
        }

        let requestedFrame = proposedFrame(currentFrame)
        guard Issue96WindowResizeRecoveryConfiguration.isValidFrame(requestedFrame) else {
            return .failed(api: api, reason: "requested-resize-frame-invalid")
        }
        guard requestedFrame.width != currentFrame.width
                || requestedFrame.height != currentFrame.height else {
            return .failed(api: api, reason: "resize-would-not-change-size")
        }
        guard frameIsWithinResizeLimits(requestedFrame) else {
            return .failed(api: api, reason: "requested-resize-frame-not-resizable")
        }

        resizeWindow(requestedFrame)
        return .applied(api: api)
    }
}

/// Diagnostic-only panel capability required by the non-key -> key trial.
/// This does not make the panel key during baseline setup.
@MainActor
final class Issue96ProbePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
struct Issue96ProbeDispatcher {
    private let primitiveOperations: any Issue96ProbePrimitiveOperations
    private let applicationActivationRecovery: any Issue96ApplicationActivationRecoveryOperations
    private let windowKeyRecovery: any Issue96WindowKeyRecoveryOperations
    private let windowResizeRecovery: any Issue96WindowResizeRecoveryOperations

    init(
        operations: any Issue96ProbePrimitiveOperations,
        applicationActivationRecovery: any Issue96ApplicationActivationRecoveryOperations,
        windowKeyRecovery: any Issue96WindowKeyRecoveryOperations,
        windowResizeRecovery: any Issue96WindowResizeRecoveryOperations) {
        primitiveOperations = operations
        self.applicationActivationRecovery = applicationActivationRecovery
        self.windowKeyRecovery = windowKeyRecovery
        self.windowResizeRecovery = windowResizeRecovery
    }

    func dispatch(_ command: Issue96ProbeCommand) -> Issue96ProbeOperationResult? {
        switch command {
        case .redraw:
            return primitiveOperations.redrawOnly()
        case .cursorRect:
            return primitiveOperations.cursorRectInvalidationOnly()
        case .trackingArea:
            return primitiveOperations.trackingAreaRebuildOnly()
        case .windowUpdate:
            return primitiveOperations.nonActivatingWindowUpdateOnly()
        case .activationControl:
            return primitiveOperations.activationPositiveControl()
        case .recoveryAppActivate:
            return applicationActivationRecovery.applicationActivationOnly()
        case .recoveryWindowKey:
            return windowKeyRecovery.windowKeyTransitionOnly()
        case .recoveryWindowResize:
            return windowResizeRecovery.windowResizeTransitionOnly()
        case .status, .markBaselineHealthy, .markBrokenConfirmed, .markRecoveryAction,
             .markRecovered, .markStillBroken, .clearTrace, .dumpTrace:
            return nil
        }
    }
}

enum Issue96ProbeWindowConfiguration {
    static let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    // AppKit documents that .activeAlways and .cursorUpdate must not be
    // combined: that combination suppresses cursorUpdate(with:). Keep the
    // always-active mouse lifecycle area separate from the cursor-update
    // area so each callback has an unambiguous tracking configuration.
    static let mouseTrackingAreaOptions: NSTrackingArea.Options = [
        .activeAlways,
        .mouseEnteredAndExited,
        .mouseMoved,
    ]
    static let cursorUpdateTrackingAreaOptions: NSTrackingArea.Options = [
        .activeInActiveApp,
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

struct Issue96ProbeWindowSize: Equatable, Sendable {
    let width: Double
    let height: Double

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    init(size: NSSize) {
        width = Double(size.width)
        height = Double(size.height)
    }

    var logValue: String { "\(width)x\(height)" }
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
    let beforePanelSize: Issue96ProbeWindowSize?
    let afterPanelSize: Issue96ProbeWindowSize?

    init(
        sequence: UInt64,
        monotonicNanoseconds: UInt64,
        kind: Issue96ProbeCommand,
        targetDisplayID: CGDirectDisplayID,
        panelDisplayID: CGDirectDisplayID?,
        before: Issue96ProbeWindowState,
        after: Issue96ProbeWindowState,
        result: Issue96ProbeOperationResult,
        beforePanelSize: Issue96ProbeWindowSize? = nil,
        afterPanelSize: Issue96ProbeWindowSize? = nil) {
        self.sequence = sequence
        self.monotonicNanoseconds = monotonicNanoseconds
        self.kind = kind
        self.targetDisplayID = targetDisplayID
        self.panelDisplayID = panelDisplayID
        self.before = before
        self.after = after
        self.result = result
        self.beforePanelSize = beforePanelSize
        self.afterPanelSize = afterPanelSize
    }

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
        if kind == .recoveryWindowResize {
            message += " panel_size_before=\(beforePanelSize?.logValue ?? "none")"
                + " panel_size_after=\(afterPanelSize?.logValue ?? "none")"
        }
        return message
    }

    var responseLine: String {
        if Issue96ProbeCommand.recoveryKinds.contains(kind),
           let failureReason = result.failureReason {
            return "ERROR sequence=\(sequence) kind=\(kind.rawValue) reason=\(failureReason)"
        }
        return "OK sequence=\(sequence) kind=\(kind.rawValue) api_success=\(result.succeeded)"
    }
}

@MainActor
final class Issue96ProbeView: NSView {
    private let lifecycleTrace: Issue96LifecycleTrace?
    private var ownedTrackingAreas: [NSTrackingArea] = []

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

    /// Rebuilds only the tracking areas owned by this diagnostic view.
    func rebuildOwnedTrackingAreas() {
        for trackingArea in ownedTrackingAreas {
            removeTrackingArea(trackingArea)
        }
        ownedTrackingAreas = [
            NSTrackingArea(
                rect: bounds,
                options: Issue96ProbeWindowConfiguration.mouseTrackingAreaOptions,
                owner: self,
                userInfo: nil),
            NSTrackingArea(
                rect: bounds,
                options: Issue96ProbeWindowConfiguration.cursorUpdateTrackingAreaOptions,
                owner: self,
                userInfo: nil),
        ]
        for trackingArea in ownedTrackingAreas {
            addTrackingArea(trackingArea)
        }
    }

    override func updateTrackingAreas() {
        lifecycleTrace?.record(event: .updateTrackingAreas)
        super.updateTrackingAreas()
        rebuildOwnedTrackingAreas()
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
        view.rebuildOwnedTrackingAreas()
        return .applied(api: "view.removeTrackingArea+view.addTrackingArea (owned areas)")
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

/// AppKit implementation of the affected-window application activation
/// recovery operation. It validates the owned panel's current display and
/// active state, then requests only application activation. It does not order,
/// key, main, redraw, invalidate, rebuild, or move anything.
@MainActor
final class Issue96ApplicationActivationAppKitOperation: Issue96ApplicationActivationRecoveryOperations {
    weak var window: NSWindow?
    let targetDisplayID: CGDirectDisplayID
    private let coordinator: Issue96ApplicationActivationCoordinator

    init(
        window: NSWindow,
        targetDisplayID: CGDirectDisplayID,
        applicationIsActive: @escaping () -> Bool = { NSApplication.shared.isActive },
        activateApplication: @escaping () -> Void = {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }) {
        self.window = window
        self.targetDisplayID = targetDisplayID
        coordinator = Issue96ApplicationActivationCoordinator(
            applicationIsActive: applicationIsActive,
            activateApplication: activateApplication)
    }

    func applicationActivationOnly() -> Issue96ProbeOperationResult {
        let api = "NSApplication.activate(ignoringOtherApps: true)"
        guard let window else {
            return .failed(api: api, reason: "diagnostic-window-unavailable")
        }
        guard Self.displayID(for: window.screen) == targetDisplayID else {
            return .failed(api: api, reason: "diagnostic-window-not-on-target-display")
        }
        return coordinator.run()
    }

    private static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let number = screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}

/// AppKit implementation of the affected-window non-key -> key recovery
/// experiment. The only requested AppKit mutation is `window.makeKey()`;
/// lifecycle notifications and the resulting key state remain evidence.
@MainActor
final class Issue96WindowKeyRecoveryAppKitOperation: Issue96WindowKeyRecoveryOperations {
    weak var window: NSWindow?
    private let applicationIsActive: () -> Bool
    private let windowIsOnTargetDisplay: () -> Bool
    private let windowIsKey: () -> Bool
    private let makeWindowKey: () -> Void

    init(
        window: NSWindow,
        targetDisplayID: CGDirectDisplayID,
        applicationIsActive: @escaping () -> Bool = { NSApplication.shared.isActive },
        windowIsOnTargetDisplay: (() -> Bool)? = nil,
        windowIsKey: (() -> Bool)? = nil,
        makeWindowKey: (() -> Void)? = nil) {
        self.window = window
        self.applicationIsActive = applicationIsActive
        self.windowIsOnTargetDisplay = windowIsOnTargetDisplay ?? { [weak window] in
            Self.displayID(for: window?.screen) == targetDisplayID
        }
        self.windowIsKey = windowIsKey ?? { [weak window] in
            window?.isKeyWindow ?? false
        }
        self.makeWindowKey = makeWindowKey ?? { [weak window] in
            window?.makeKey()
        }
    }

    func windowKeyTransitionOnly() -> Issue96ProbeOperationResult {
        Issue96WindowKeyRecoveryCoordinator(
            windowExists: { [weak self] in self?.window != nil },
            windowIsOnTargetDisplay: windowIsOnTargetDisplay,
            applicationIsActive: applicationIsActive,
            windowIsKey: windowIsKey,
            makeWindowKey: makeWindowKey)
            .run()
    }

    private static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let number = screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}

/// AppKit implementation of the affected-window resize recovery experiment.
/// The only requested AppKit mutation is one setFrame call with the current
/// origin and a fixed width increase. It does not activate, key, order,
/// redraw, invalidate, rebuild, move, or set a cursor.
@MainActor
final class Issue96WindowResizeRecoveryAppKitOperation: Issue96WindowResizeRecoveryOperations {
    weak var window: NSWindow?
    private let targetDisplayID: CGDirectDisplayID

    init(window: NSWindow, targetDisplayID: CGDirectDisplayID) {
        self.window = window
        self.targetDisplayID = targetDisplayID
    }

    func windowResizeTransitionOnly() -> Issue96ProbeOperationResult {
        let window = self.window
        return Issue96WindowResizeRecoveryCoordinator(
            windowExists: { window != nil },
            windowIsOnTargetDisplay: {
                Self.displayID(for: window?.screen) == self.targetDisplayID
            },
            currentFrame: { window?.frame },
            proposedFrame: Issue96WindowResizeRecoveryConfiguration.resizedFrame,
            frameIsWithinResizeLimits: { frame in
                guard let window else { return false }
                return Issue96WindowResizeRecoveryConfiguration.isSizeWithinLimits(
                    frame.size,
                    minimum: window.minSize,
                    maximum: window.maxSize)
            },
            resizeWindow: { frame in
                window?.setFrame(frame, display: false, animate: false)
            })
            .run()
    }

    private static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let number = screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}

@MainActor
final class Issue96TargetDisplayInvalidationProbeHarness {
    let targetDisplayID: CGDirectDisplayID
    let panel: Issue96ProbePanel
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
        let panel = Issue96ProbePanel(
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
        view.rebuildOwnedTrackingAreas()

        let operations = Issue96ProbeAppKitOperations(window: panel, view: view)
        let applicationActivationRecovery = Issue96ApplicationActivationAppKitOperation(
            window: panel,
            targetDisplayID: selectedDisplayID)
        let windowKeyRecovery = Issue96WindowKeyRecoveryAppKitOperation(
            window: panel,
            targetDisplayID: selectedDisplayID)
        let windowResizeRecovery = Issue96WindowResizeRecoveryAppKitOperation(
            window: panel,
            targetDisplayID: selectedDisplayID)
        let endpoint = Issue96ProbeControlEndpoint(path: Issue96ProbeConfiguration.socketPath)

        self.targetDisplayID = selectedDisplayID
        self.panel = panel
        self.view = view
        self.lifecycleTrace = lifecycleTrace
        self.dispatcher = Issue96ProbeDispatcher(
            operations: operations,
            applicationActivationRecovery: applicationActivationRecovery,
            windowKeyRecovery: windowKeyRecovery,
            windowResizeRecovery: windowResizeRecovery)
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
        let beforePanelSize = command == .recoveryWindowResize ? panelSize() : nil
        probeSequence &+= 1
        let result = dispatcher.dispatch(command)
            ?? .failed(api: "dispatcher", reason: "unsupported-command")
        let after = windowState()
        let afterPanelSize = command == .recoveryWindowResize ? panelSize() : nil
        let record = Issue96ProbeRecord(
            sequence: probeSequence,
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            kind: command,
            targetDisplayID: targetDisplayID,
            panelDisplayID: Self.displayID(for: panel.screen),
            before: before,
            after: after,
            result: result,
            beforePanelSize: beforePanelSize,
            afterPanelSize: afterPanelSize)
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

    private func panelSize() -> Issue96ProbeWindowSize? {
        let size = panel.frame.size
        guard size.width.isFinite, size.height.isFinite else { return nil }
        return Issue96ProbeWindowSize(size: size)
    }

    private static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let number = screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}
