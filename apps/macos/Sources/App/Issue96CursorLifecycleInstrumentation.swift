import AppKit
import Foundation

enum Issue96CursorRegion: String, CaseIterable, Sendable {
    case background
    case resizeHorizontal = "resize-horizontal"
    case resizeVertical = "resize-vertical"
    case resizeDiagonal = "resize-diagonal"

    static let cursorRegions: [Issue96CursorRegion] = [
        .resizeHorizontal,
        .resizeVertical,
        .resizeDiagonal,
    ]
}

enum Issue96LifecycleEvent: String, CaseIterable, Sendable {
    case resetCursorRects = "reset-cursor-rects"
    case cursorUpdate = "cursor-update"
    case updateTrackingAreas = "update-tracking-areas"
    case mouseEntered = "mouse-entered"
    case mouseExited = "mouse-exited"
    case mouseMoved = "mouse-moved"

    case applicationDidBecomeActive = "application-did-become-active"
    case applicationDidResignActive = "application-did-resign-active"
    case windowDidBecomeKey = "window-did-become-key"
    case windowDidResignKey = "window-did-resign-key"
    case windowDidBecomeMain = "window-did-become-main"
    case windowDidResignMain = "window-did-resign-main"
    case windowDidChangeOcclusionState = "window-did-change-occlusion-state"
    case windowDidMiniaturize = "window-did-miniaturize"
    case windowDidDeminiaturize = "window-did-deminiaturize"
    case windowDidChangeScreen = "window-did-change-screen"
    case windowDidMove = "window-did-move"
    case windowDidResize = "window-did-resize"
    case windowWillClose = "window-will-close"

    case viewDidMoveToWindow = "view-did-move-to-window"
    case viewDidMoveToSuperview = "view-did-move-to-superview"
    case viewLayout = "view-layout"
    case viewDraw = "view-draw"

    case markerBaselineHealthy = "marker-baseline-healthy"
    case markerBrokenConfirmed = "marker-broken-confirmed"
    case markerRecoveryAction = "marker-recovery-action"
    case markerRecovered = "marker-recovered"
    case markerStillBroken = "marker-still-broken"
}

struct Issue96LifecycleTraceWindowState: Equatable, Sendable {
    let appIsActive: Bool
    let isKeyWindow: Bool
    let isMainWindow: Bool
    let isVisible: Bool
    let occlusionState: UInt64
    let isOccluded: Bool
}

struct Issue96LifecycleTraceRecord: Equatable, Sendable {
    let sequence: UInt64
    let monotonicNanoseconds: UInt64
    let event: Issue96LifecycleEvent
    let region: Issue96CursorRegion?
    let targetDisplayID: CGDirectDisplayID
    let windowDisplayID: CGDirectDisplayID?
    let windowState: Issue96LifecycleTraceWindowState

    private static func displayID(_ value: CGDirectDisplayID?) -> String {
        value.map(String.init) ?? "none"
    }

    private static func regionName(_ value: Issue96CursorRegion?) -> String {
        value?.rawValue ?? "none"
    }

    var traceLine: String {
        "TRACE sequence=\(sequence)"
            + " monotonic_ns=\(monotonicNanoseconds)"
            + " event=\(event.rawValue)"
            + " region=\(Self.regionName(region))"
            + " target_display_id=\(targetDisplayID)"
            + " window_display_id=\(Self.displayID(windowDisplayID))"
            + " app_active=\(windowState.appIsActive)"
            + " is_key_window=\(windowState.isKeyWindow)"
            + " is_main_window=\(windowState.isMainWindow)"
            + " visible=\(windowState.isVisible)"
            + " occlusion_state=\(windowState.occlusionState)"
            + " occluded=\(windowState.isOccluded)\n"
    }
}

@MainActor
final class Issue96LifecycleTrace {
    static let defaultCapacity = 1_000
    static let maximumDumpBytes = 64 * 1024

    let targetDisplayID: CGDirectDisplayID
    let capacity: Int
    weak var window: NSWindow?
    private(set) var records: [Issue96LifecycleTraceRecord] = []

    private var nextSequence: UInt64 = 0

    init(
        targetDisplayID: CGDirectDisplayID,
        window: NSWindow? = nil,
        capacity: Int = Issue96LifecycleTrace.defaultCapacity) {
        self.targetDisplayID = targetDisplayID
        self.window = window
        self.capacity = max(1, capacity)
    }

    var count: Int { records.count }

    @discardableResult
    func record(
        event: Issue96LifecycleEvent,
        region: Issue96CursorRegion? = nil) -> Issue96LifecycleTraceRecord {
        nextSequence &+= 1
        let record = Issue96LifecycleTraceRecord(
            sequence: nextSequence,
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            event: event,
            region: region,
            targetDisplayID: targetDisplayID,
            windowDisplayID: Self.displayID(for: window?.screen),
            windowState: windowState())
        records.append(record)
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
        return record
    }

    func clear() {
        records.removeAll(keepingCapacity: true)
    }

    func dumpResponse() -> String {
        let completeHeader = "OK kind=dump-trace count=\(records.count) capacity=\(capacity) truncated=false\n"
        let completeBody = completeHeader + records.map(\.traceLine).joined()
        guard completeBody.utf8.count > Self.maximumDumpBytes else {
            return completeBody
        }

        let prefix = "OK kind=dump-trace count=\(records.count)"
        var includedLines: [String] = []
        for record in records {
            let candidateCount = includedLines.count + 1
            let candidateHeader = prefix
                + " included=\(candidateCount) capacity=\(capacity) truncated=true\n"
            let candidateBody = candidateHeader + (includedLines + [record.traceLine]).joined()
            guard candidateBody.utf8.count <= Self.maximumDumpBytes else { break }
            includedLines.append(record.traceLine)
        }

        let truncatedHeader = prefix
            + " included=\(includedLines.count) capacity=\(capacity) truncated=true\n"
        return truncatedHeader + includedLines.joined()
    }

    private func windowState() -> Issue96LifecycleTraceWindowState {
        let windowIsVisible = window?.isVisible ?? false
        let occlusionState = UInt64(window?.occlusionState.rawValue ?? 0)
        return Issue96LifecycleTraceWindowState(
            appIsActive: NSApplication.shared.isActive,
            isKeyWindow: window?.isKeyWindow ?? false,
            isMainWindow: window?.isMainWindow ?? false,
            isVisible: windowIsVisible,
            occlusionState: occlusionState,
            isOccluded: windowIsVisible && !(window?.occlusionState.contains(.visible) ?? false))
    }

    private static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let number = screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}

@MainActor
final class Issue96LifecycleObservers {
    private let center = NotificationCenter.default
    private let trace: Issue96LifecycleTrace
    private var tokens: [NSObjectProtocol] = []

    init(trace: Issue96LifecycleTrace, window: NSWindow) {
        self.trace = trace
        observe(NSApplication.didBecomeActiveNotification, object: NSApplication.shared, event: .applicationDidBecomeActive)
        observe(NSApplication.didResignActiveNotification, object: NSApplication.shared, event: .applicationDidResignActive)
        observe(NSWindow.didBecomeKeyNotification, object: window, event: .windowDidBecomeKey)
        observe(NSWindow.didResignKeyNotification, object: window, event: .windowDidResignKey)
        observe(NSWindow.didBecomeMainNotification, object: window, event: .windowDidBecomeMain)
        observe(NSWindow.didResignMainNotification, object: window, event: .windowDidResignMain)
        observe(NSWindow.didChangeOcclusionStateNotification, object: window, event: .windowDidChangeOcclusionState)
        observe(NSWindow.didMiniaturizeNotification, object: window, event: .windowDidMiniaturize)
        observe(NSWindow.didDeminiaturizeNotification, object: window, event: .windowDidDeminiaturize)
        observe(NSWindow.didChangeScreenNotification, object: window, event: .windowDidChangeScreen)
        observe(NSWindow.didMoveNotification, object: window, event: .windowDidMove)
        observe(NSWindow.didResizeNotification, object: window, event: .windowDidResize)
        observe(NSWindow.willCloseNotification, object: window, event: .windowWillClose)
    }

    func stop() {
        for token in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll(keepingCapacity: false)
    }

    private func observe(_ name: Notification.Name, object: Any, event: Issue96LifecycleEvent) {
        tokens.append(center.addObserver(forName: name, object: object, queue: .main) { [weak trace] _ in
            MainActor.assumeIsolated {
                _ = trace?.record(event: event)
            }
        })
    }
}

@MainActor
enum Issue96ProbeTraceControl {
    static func handle(
        _ command: Issue96ProbeCommand,
        trace: Issue96LifecycleTrace) -> String? {
        if let event = command.markerEvent {
            let record = trace.record(event: event)
            return "OK kind=\(command.rawValue) sequence=\(record.sequence)\n"
        }

        switch command {
        case .clearTrace:
            trace.clear()
            return "OK kind=clear-trace count=0\n"
        case .dumpTrace:
            return trace.dumpResponse()
        default:
            return nil
        }
    }
}
