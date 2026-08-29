import AppKit
import CoreGraphics
import Diagnostics

/// Opt-in, metadata-only diagnostics for Issue #96.
///
/// This observer intentionally lives in the App layer. It does not participate
/// in InputCapture, suppression, pointer warping, or cursor ownership. Its only
/// purpose is to correlate a recovery-producing menu-bar click with public
/// AppKit/workspace state before and after that click.
///
/// Enable with `CROSSINPUT_DIAG_CURSOR_RECOVERY=1` on a diagnostic build.
@MainActor
final class CursorRecoveryDiagnostics {
    static let shared = CursorRecoveryDiagnostics()

    private struct Snapshot {
        let capturedAt: CFTimeInterval
        let appActive: Bool
        let frontmostPID: pid_t?
        let frontmostBundleID: String
        let currentCursor: String
        let currentSystemCursor: String
        let displayID: CGDirectDisplayID?
        let locationCategory: String

        var logValue: String {
            let pid = frontmostPID.map(String.init) ?? "none"
            let display = displayID.map(String.init) ?? "none"
            return "app_active=\(appActive) frontmost_pid=\(pid) "
                + "frontmost_bundle=\(frontmostBundleID) "
                + "cursor_current=\(currentCursor) "
                + "cursor_system=\(currentSystemCursor) "
                + "display=\(display) location=\(locationCategory)"
        }
    }

    private let enabled = ProcessInfo.processInfo.environment[
        "CROSSINPUT_DIAG_CURSOR_RECOVERY"
    ] == "1"

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var latestPointerSnapshot: Snapshot?
    private var clickSequence: UInt64 = 0

    private init() {}

    func start() {
        guard enabled, localMonitor == nil, globalMonitor == nil else { return }

        Diagnostics.log("cursor-recovery diagnostics enabled")
        installApplicationObservers()
        installWorkspaceObservers()
        installMenuObservers()
        installEventMonitors()

        latestPointerSnapshot = captureSnapshot()
        logSnapshot(reason: "startup")
    }

    private func installApplicationObservers() {
        let center = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ] {
            notificationObservers.append(
                center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] note in
                    Task { @MainActor [weak self] in
                        self?.recordNotification("app", name: note.name.rawValue)
                    }
                }
            )
        }
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
        ] {
            notificationObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    Task { @MainActor [weak self] in
                        self?.recordNotification("workspace", name: note.name.rawValue)
                    }
                }
            )
        }
    }

    private func installMenuObservers() {
        let center = NotificationCenter.default
        for name in [
            NSMenu.didBeginTrackingNotification,
            NSMenu.didEndTrackingNotification,
            NSMenu.willSendActionNotification,
            NSMenu.didSendActionNotification,
        ] {
            notificationObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    Task { @MainActor [weak self] in
                        self?.recordNotification("menu", name: note.name.rawValue)
                    }
                }
            )
        }
    }

    private func installEventMonitors() {
        // Local and global monitors are complementary: a global monitor sees
        // events delivered to other applications but not events delivered to
        // this app, while the local monitor observes this app's own events.
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.record(event: event, source: "local")
            }
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.record(event: event, source: "global")
            }
        }
    }

    private func record(event: NSEvent, source: String) {
        switch event.type {
        case .mouseMoved:
            // Keep a rolling in-memory snapshot only. Logging every move would
            // create noise and would violate the bounded metadata objective.
            latestPointerSnapshot = captureSnapshot()

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            recordMouseDown(source: source, button: mouseButtonName(event.type))

        default:
            break
        }
    }

    private func recordMouseDown(source: String, button: String) {
        clickSequence &+= 1
        let sequence = clickSequence
        let pre = latestPointerSnapshot
        let down = captureSnapshot()
        latestPointerSnapshot = down

        let preValue: String
        if let pre {
            let ageMS = max(0, (down.capturedAt - pre.capturedAt) * 1_000)
            preValue = "pre_age_ms=\(Int(ageMS.rounded())) pre=[\(pre.logValue)]"
        } else {
            preValue = "pre_age_ms=none pre=[none]"
        }

        Diagnostics.log(
            "cursor-recovery mouseDown seq=\(sequence) source=\(source) button=\(button) "
                + "\(preValue) down=[\(down.logValue)]"
        )

        // The post sample is deliberately delayed by a small bounded interval
        // so the system menu click can complete its normal tracking/activation
        // work before public AppKit state is sampled again.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            let post = self.captureSnapshot()
            self.latestPointerSnapshot = post
            Diagnostics.log(
                "cursor-recovery postClick seq=\(sequence) delay_ms=150 post=[\(post.logValue)]"
            )
        }
    }

    private func recordNotification(_ domain: String, name: String) {
        let snapshot = captureSnapshot()
        latestPointerSnapshot = snapshot
        Diagnostics.log(
            "cursor-recovery notification domain=\(domain) name=\(name) "
                + "state=[\(snapshot.logValue)]"
        )
    }

    private func logSnapshot(reason: String) {
        let snapshot = captureSnapshot()
        latestPointerSnapshot = snapshot
        Diagnostics.log("cursor-recovery snapshot reason=\(reason) state=[\(snapshot.logValue)]")
    }

    private func captureSnapshot() -> Snapshot {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
        let runningApplication = NSWorkspace.shared.frontmostApplication

        return Snapshot(
            capturedAt: CFAbsoluteTimeGetCurrent(),
            appActive: NSApp.isActive,
            frontmostPID: runningApplication?.processIdentifier,
            frontmostBundleID: runningApplication?.bundleIdentifier ?? "none",
            currentCursor: cursorFingerprint(NSCursor.current),
            currentSystemCursor: NSCursor.currentSystem.map(cursorFingerprint) ?? "none",
            displayID: screen.flatMap(displayID),
            locationCategory: locationCategory(point: point, screen: screen)
        )
    }

    private func cursorFingerprint(_ cursor: NSCursor) -> String {
        let size = cursor.image.size
        let hotSpot = cursor.hotSpot
        return "\(ObjectIdentifier(cursor))"
            + "@\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
            + ":\(Int(hotSpot.x.rounded())),\(Int(hotSpot.y.rounded()))"
    }

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func locationCategory(point: NSPoint, screen: NSScreen?) -> String {
        guard let screen else { return "outsideScreens" }

        // Do not log coordinates. The only distinction needed for #96 is
        // whether the pointer is in the menu-bar strip or ordinary screen area.
        let menuBarFloor = screen.visibleFrame.maxY
        if point.y >= menuBarFloor && point.y <= screen.frame.maxY {
            return "menuBarRegion"
        }
        return "screenBody"
    }

    private func mouseButtonName(_ type: NSEvent.EventType) -> String {
        switch type {
        case .leftMouseDown: return "left"
        case .rightMouseDown: return "right"
        case .otherMouseDown: return "other"
        default: return "unknown"
        }
    }
}
