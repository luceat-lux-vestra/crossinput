import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import Carbon.HIToolbox
import EdgeSwitch

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
    private var isSuppressing = false
    private let edgeThreshold: CGFloat = 2
    private var emergencyHotKey: EventHotKeyRef?

    public init() {}

    // MARK: - Lifecycle

    /// Installs the event tap and starts the capture run loop.
    /// Returns false if the app lacks Accessibility permission.
    public func start() -> Bool {
        guard !AXIsProcessTrusted() else { return startTrusted() }
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
            options: .listenOnly,
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
            updateTapOptions()
            startWatchdog()
        }
    }

    /// Returns to listening mode immediately (fail-safe path).
    public func release() {
        let wasSuppressing = stateLock.withLock {
            let was = isSuppressing
            isSuppressing = false
            watchdog?.cancel()
            watchdog = nil
            updateTapOptions()
            return was
        }
        if wasSuppressing {
            // Physically return the pointer to the user (into the screen).
            centerPointer()
            onSuppressionReleased?()
        }
    }

    public var isSuppressed: Bool {
        stateLock.withLock { isSuppressing }
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
                return nil // consume: pointer held at the edge
            }
            detectEdge()
            return Unmanaged.passRetained(event)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            if isSuppressing {
                let button = Self.buttonIndex(for: type)
                let down = type.rawValue % 2 == 0 // Down events are even
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
        }
    }

    private func detectEdge() {
        guard screenFrame != .zero else { return }
        let p = currentPosition
        let f = screenFrame
        if p.x <= f.minX + edgeThreshold { onScreenEdge?(.left) }
        else if p.x >= f.maxX - edgeThreshold { onScreenEdge?(.right) }
        else if p.y <= f.minY + edgeThreshold { onScreenEdge?(.bottom) }
        else if p.y >= f.maxY - edgeThreshold { onScreenEdge?(.top) }
    }

    private func centerPointer() {
        if let screen = NSScreen.main {
            CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
        }
    }

    // MARK: - Tap option updates

    private func updateTapOptions() {
        guard let tap else { return }
        tapQueue.async { [weak self] in
            guard let self, let tap = self.tap else { return }
            let options: CGEventTapOptions = self.isSuppressing ? .defaultTap : .listenOnly
            CGEvent.tapEnable(tap: tap, enable: false)
            // Options are only applied at creation; re-creating the tap with
            // the new options keeps the suppression contract exact.
            self.recreateTapIfNeeded(options: options)
        }
    }

    private func recreateTapIfNeeded(options: CGEventTapOptions) {
        guard let tap else { return }
        CFMachPortInvalidate(tap)
        self.tap = nil
        if let source = runLoopSource {
            CFRunLoopSourceInvalidate(source)
        }
        runLoopSource = nil
        var mask: CGEventMask = 0
        for eventType in Self.capturedEvents {
            mask |= CGEventMask(1 << eventType.rawValue)
        }
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let capture = Unmanaged<InputCapture>.fromOpaque(refcon).takeUnretainedValue()
            return capture.handle(proxy: proxy, type: type, event: event)
        }
        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        self.tap = newTap
        if let runLoop {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
            runLoopSource = source
            CFRunLoopAddSource(runLoop, source, .commonModes)
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
