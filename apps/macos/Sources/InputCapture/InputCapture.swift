import Foundation
import CoreGraphics
@preconcurrency import ApplicationServices
import AppKit
import Carbon.HIToolbox
import EdgeSwitch
import Diagnostics

/// A single pointer event captured from the system, ready to become a CXI message.
public struct PointerEvent: Sendable {
    public enum Kind: Sendable, Equatable {
        case move(dx: Int32, dy: Int32)
        case button(button: UInt32, down: Bool) // 0=left 1=right 2=middle
        case scroll(horizontal: Float, vertical: Float)
    }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
}

/// CGEventTap-based input capture.
///
/// Hard rules (AGENTS.md):
/// - Never trap the pointer: in `.listening` mode every event passes through untouched.
/// - Suppression requires timeout + fail-safe: in `.suppressed` mode events are consumed
///   and forwarded, but a watchdog automatically restores the pointer, and the emergency
///   shortcut (⇧⌘X) always returns control regardless of the Android connection.
public final class InputCapture: @unchecked Sendable {
    public enum Mode: Sendable {
        case listening   // observe only: pointer stays on macOS
        case suppressed  // consume pointer events and forward them to the device
    }

    public private(set) var mode: Mode = .listening

    /// Called on the capture thread for every pointer event while suppressed.
    public var onPointerEvent: (@Sendable (PointerEvent) -> Void)?
    /// Called when the pointer reaches a screen edge while listening.
    public var onScreenEdge: (@Sendable (ScreenEdge) -> Void)?
    /// Called when suppression is released by the fail-safe (timeout, disconnect, shortcut).
    public var onSuppressionReleased: (@Sendable () -> Void)?

    private let tapQueue = DispatchQueue(label: "crossinput.capturertap", qos: .userInteractive)
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var watchdog: DispatchSourceTimer?
    private let stateLock = NSLock()
    private var currentPosition: CGPoint = .zero
    private var screenFrame: CGRect = .zero
    private var currentScreen: NSScreen?
    private var isSuppressing = false
    /// Per-display configuration: which edge of that display leads to the
    /// Android target. Absence means that display never triggers a switch.
    private var androidEdgeByDisplay: [CGDirectDisplayID: ScreenEdge] = [:]
    private let edgeThreshold: CGFloat = 2
    private var emergencyHotKey: EventHotKeyRef?
    /// Prevents an immediate re-trigger after the pointer returns to macOS.
    private var edgeCooldownUntil: CFTimeInterval = 0

    public init() {}

    // MARK: - Lifecycle

    /// Installs the event tap and starts the capture run loop.
    /// Returns false if the app lacks Accessibility permission.
    /// When permission is missing, the system prompt is triggered once so the
    /// user can grant it (the app should retry start() afterwards).
    public func start() -> Bool {
        guard !AXIsProcessTrusted() else { return startTrusted() }
        Diagnostics.log("start(): accessibility not granted; prompting")
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        return false
    }

    public func startTrusted() -> Bool {
        guard tap == nil else { return true }
        var mask: CGEventMask = 0
        for eventType in Self.capturedEvents {
            mask |= CGEventMask(1 << eventType.rawValue)
        }
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let capture = Unmanaged<InputCapture>.fromOpaque(refcon).takeUnretainedValue()
            return capture.handle(proxy: proxy, type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapQueue.async { [weak self] in
            guard let self else { return }
            let runLoop = CFRunLoopGetCurrent()
            self.runLoop = runLoop
            CFRunLoopAddSource(runLoop, self.runLoopSource, .commonModes)
            self.installEmergencyHotKey()
            CFRunLoopRun()
        }
        return true
    }

    public func stop() {
        stateLock.withLock {
            if let tap {
                CFMachPortInvalidate(tap)
                self.tap = nil
            }
            if let runLoopSource, let runLoop {
                CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes)
            }
            runLoopSource = nil
            watchdog?.cancel()
            watchdog = nil
        }
        // Stop the run loop (must be scheduled on the tap thread).
        tapQueue.async { [weak self] in
            guard let self, let runLoop = self.runLoop else { return }
            CFRunLoopStop(runLoop)
            self.runLoop = nil
        }
    }

    // MARK: - Mode control

    /// Switches to suppressed mode: pointer events are consumed and forwarded.
    public func suppress() {
        stateLock.withLock {
            guard !isSuppressing else { return }
            isSuppressing = true
            startWatchdog()
        }
        Diagnostics.log("pointer suppressed; hiding macOS cursor")
        hideCursor()
    }

    /// Returns to listening mode immediately (fail-safe path).
    public func release() {
        let wasSuppressing = stateLock.withLock {
            let was = isSuppressing
            isSuppressing = false
            watchdog?.cancel()
            watchdog = nil
            return was
        }
        if wasSuppressing {
            showCursor()
            // Physically return the pointer to the crossing edge point the user
            // pushed through, so Android->macOS continues where control left off
            // instead of jumping to the screen center.
            restorePointerAtEdge()
            onSuppressionReleased?()
        }
    }

    public var isSuppressed: Bool {
        stateLock.withLock { isSuppressing }
    }

    /// Configures which edge of the given display leads to the Android target.
    /// Pass nil to disable edge switching on that display.
    public func setAndroidEdge(_ edge: ScreenEdge?, forDisplay displayID: CGDirectDisplayID) {
        stateLock.withLock {
            if let edge {
                androidEdgeByDisplay[displayID] = edge
            } else {
                androidEdgeByDisplay.removeValue(forKey: displayID)
            }
        }
    }

    // MARK: - Event handling (capture thread)

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enable is automatic when the tap is reset by the system; do not consume.
            return Unmanaged.passRetained(event)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            updatePosition(event)
            if isSuppressing {
                let dx = Int32(event.getIntegerValueField(.mouseEventDeltaX))
                let dy = Int32(event.getIntegerValueField(.mouseEventDeltaY))
                onPointerEvent?(PointerEvent(.move(dx: dx, dy: dy)))
                holdPointerAtEdge()
                return nil // consume: pointer held at the edge
            }
            detectEdge()
            return Unmanaged.passRetained(event)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            if isSuppressing {
                let button = Self.buttonIndex(for: type)
                let down: Bool
                switch type {
                case .leftMouseDown, .rightMouseDown, .otherMouseDown: down = true
                default: down = false
                }
                onPointerEvent?(PointerEvent(.button(button: button, down: down)))
                return nil
            }
            return Unmanaged.passRetained(event)
        case .scrollWheel:
            if isSuppressing {
                let vertical = Float(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
                let horizontal = Float(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
                onPointerEvent?(PointerEvent(.scroll(horizontal: horizontal, vertical: vertical)))
                return nil
            }
            return Unmanaged.passRetained(event)
        default:
            return Unmanaged.passRetained(event)
        }
    }

    private func updatePosition(_ event: CGEvent) {
        currentPosition = event.location
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(currentPosition) }) {
            screenFrame = screen.frame
            currentScreen = screen
        }
    }

    private var currentDisplayID: CGDirectDisplayID? {
        guard let num = currentScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return CGDirectDisplayID(num.uint32Value)
    }

    private func detectEdge() {
        // After a return-to-macOS warp, briefly ignore the edge so the pointer
        // sitting on the crossing point does not instantly switch back.
        guard CFAbsoluteTimeGetCurrent() >= edgeCooldownUntil else { return }
        guard screenFrame != .zero, let displayID = currentDisplayID else { return }
        let p = currentPosition
        let f = screenFrame
        let edge: ScreenEdge
        if p.x <= f.minX + edgeThreshold { edge = .left }
        else if p.x >= f.maxX - edgeThreshold { edge = .right }
        else if p.y <= f.minY + edgeThreshold { edge = .bottom }
        else if p.y >= f.maxY - edgeThreshold { edge = .top }
        else { return }
        // Only the configured Android edge of this display triggers a switch;
        // other screens/edges are ordinary macOS multi-monitor navigation.
        guard stateLock.withLock({ androidEdgeByDisplay[displayID] }) == edge else { return }
        onScreenEdge?(edge)
    }

    private func restorePointerAtEdge() {
        guard screenFrame != .zero, let displayID = currentDisplayID,
              let edge = stateLock.withLock({ androidEdgeByDisplay[displayID] }) else {
            if let screen = NSScreen.main {
                CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
            }
            return
        }
        let f = screenFrame
        let p = currentPosition
        let hold: CGPoint
        switch edge {
        case .left:   hold = CGPoint(x: f.minX + edgeThreshold, y: p.y)
        case .right:  hold = CGPoint(x: f.maxX - edgeThreshold, y: p.y)
        case .top:    hold = CGPoint(x: p.x, y: f.maxY - edgeThreshold)
        case .bottom: hold = CGPoint(x: p.x, y: f.minY + edgeThreshold)
        }
        CGWarpMouseCursorPosition(hold)
        postSyntheticMove(at: hold)
        // Don't re-trigger the edge switch from the pointer sitting on the edge.
        edgeCooldownUntil = CFAbsoluteTimeGetCurrent() + 0.5
    }

    /// macOS drops the first real movement deltas after a warp (the pointer
    /// "needs a lift and another move" to respond). Posting a synthetic move
    /// event at the target position re-syncs the input stream.
    private func postSyntheticMove(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(mouseEventSource: source,
                                  mouseType: .mouseMoved,
                                  mouseCursorPosition: point,
                                  mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func hideCursor() {
        if let displayID = currentDisplayID {
            CGDisplayHideCursor(displayID)
        }
        CGDisplayHideCursor(CGMainDisplayID())
    }

    private func showCursor() {
        if let displayID = currentDisplayID {
            CGDisplayShowCursor(displayID)
        }
        CGDisplayShowCursor(CGMainDisplayID())
    }

    /// Pins the macOS pointer to the configured Android edge of the current
    /// display while suppressed (CGWarpMouseCursorPosition posts no events,
    /// so there is no feedback loop). Keeps the cursor visually at the edge
    /// instead of drifting with the deltas forwarded to Android.
    private func holdPointerAtEdge() {
        guard screenFrame != .zero, let displayID = currentDisplayID,
              let edge = stateLock.withLock({ androidEdgeByDisplay[displayID] }) else { return }
        let f = screenFrame
        let p = currentPosition
        let hold: CGPoint
        switch edge {
        case .left:   hold = CGPoint(x: f.minX + edgeThreshold, y: p.y)
        case .right:  hold = CGPoint(x: f.maxX - edgeThreshold, y: p.y)
        case .top:    hold = CGPoint(x: p.x, y: f.maxY - edgeThreshold)
        case .bottom: hold = CGPoint(x: p.x, y: f.minY + edgeThreshold)
        }
        CGWarpMouseCursorPosition(hold)
        // A warp does not re-display the cursor, but keep hiding it in case
        // macOS re-shows it across displays while we re-pin each move.
        if let displayID = currentDisplayID {
            CGDisplayHideCursor(displayID)
        }
    }

    // MARK: - Fail-safe watchdog

    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: tapQueue)
        timer.schedule(deadline: .now() + Self.suppressionTimeout, repeating: Self.suppressionTimeout)
        timer.setEventHandler { [weak self] in
            // No pointer event for the timeout window: restore macOS control.
            self?.release()
        }
        watchdog = timer
        timer.resume()
    }

    /// Resets the fail-safe watchdog. Called on any forwarded event or connection heartbeat.
    public func pokeWatchdog() {
        stateLock.withLock {
            guard isSuppressing, let watchdog else { return }
            watchdog.schedule(deadline: .now() + Self.suppressionTimeout, repeating: Self.suppressionTimeout)
        }
    }

    public static let suppressionTimeout: TimeInterval = 30

    // MARK: - Emergency shortcut (⇧⌘X) — always works, independent of the Android link

    private func installEmergencyHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let capture = Unmanaged<InputCapture>.fromOpaque(userData).takeUnretainedValue()
            capture.release()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        var hotKeyRef: EventHotKeyRef?
        let keyCode = UInt32(kVK_ANSI_X)
        let modifiers = UInt32(cmdKey | shiftKey)
        var hotKeyID = EventHotKeyID(signature: OSType(0x414D5058), id: 1) // "AMPX"
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        emergencyHotKey = hotKeyRef
    }

    // MARK: - Mapping

    private static let capturedEvents: [CGEventType] = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp,
        .scrollWheel,
    ]

    private static func buttonIndex(for type: CGEventType) -> UInt32 {
        switch type {
        case .rightMouseDown, .rightMouseUp: return 1
        case .otherMouseDown, .otherMouseUp: return 2
        default: return 0
        }
    }
}
