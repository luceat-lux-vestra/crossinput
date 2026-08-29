import Foundation
import CoreGraphics
@preconcurrency import ApplicationServices
import AppKit
import Carbon.HIToolbox
import EdgeSwitch
import Diagnostics

/// Why input suppression ended. These are control-safety causes; session and
/// transport layers translate their failures to `remoteUnavailable`.
public enum SuppressionReleaseReason: String, Sendable {
    case normalReturn
    case watchdogTimeout
    case emergencyHotkey
    case remoteUnavailable
    case captureStopped
    /// An external controller took ownership of the macOS pointer. This path
    /// must not restore the pointer by warping it to the configured edge.
    case externalControl
}

/// Investigation-only seam for observing the pre-#87 host cursor lifecycle
/// without changing pointer geometry or handoff semantics.
protocol CursorVisibilityAPI {
    func hideCursor() -> CGError
    func showCursor() -> CGError
}

private struct CoreGraphicsCursorVisibility: CursorVisibilityAPI {
    func hideCursor() -> CGError {
        // The display argument is accepted for API compatibility but has no
        // effect. Keep the pre-#87 call shape for an exact A/B candidate.
        CGDisplayHideCursor(CGMainDisplayID())
    }

    func showCursor() -> CGError {
        CGDisplayShowCursor(CGMainDisplayID())
    }
}

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

/// A single keyboard transition captured while suppressed (ADR-0007).
/// Fields carry Android KeyEvent semantics so the app can build KEY_EVENT directly.
public struct CapturedKeyEvent: Sendable {
    /// Android KeyEvent.KEYCODE_* (translated from the macOS virtual key code).
    public let keyCode: Int
    /// Android KeyEvent.META_* bits.
    public let metaState: UInt32
    /// 0=KEY_ACTION_DOWN, 1=KEY_ACTION_UP.
    public let action: UInt8
    /// Repeat count (0 = first press).
    public let repeatCount: UInt8
    public init(keyCode: Int, metaState: UInt32, action: UInt8, repeatCount: UInt8) {
        self.keyCode = keyCode
        self.metaState = metaState
        self.action = action
        self.repeatCount = repeatCount
    }
}

private final class ProcessIdentityCache: @unchecked Sendable {
    private struct Entry {
        let source: ExternalControlEventSource?
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var entries: [Int32: Entry] = [:]
    private let ttl: TimeInterval = 2
    private let maximumEntries = 128

    func resolve(_ processID: Int32,
                 using resolver: @Sendable (Int32) -> ExternalControlEventSource?)
        -> ExternalControlEventSource? {
        let now = Date()
        lock.lock()
        if let entry = entries[processID], entry.expiresAt > now {
            lock.unlock()
            return entry.source
        }
        lock.unlock()

        // Resolve outside the lock: NSRunningApplication can consult process
        // services and must never block another event-tap callback.
        let source = resolver(processID)
        lock.lock()
        entries[processID] = Entry(source: source, expiresAt: now.addingTimeInterval(ttl))
        if entries.count > maximumEntries {
            let expired = entries.compactMap { key, entry in
                entry.expiresAt <= now ? key : nil
            }
            for key in expired { entries.removeValue(forKey: key) }
            while entries.count > maximumEntries {
                guard let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key else { break }
                entries.removeValue(forKey: oldest)
            }
        }
        lock.unlock()
        return source
    }
}

private final class ExternalControlSourceDiagnostics: @unchecked Sendable {
    private struct Key: Hashable {
        let eventType: UInt32
        let source: ExternalControlEventSource
    }

    private let enabled: Bool
    private let lock = NSLock()
    private var lastLogged: [Key: Date] = [:]
    private let interval: TimeInterval = 1

    init(enabled: Bool) {
        self.enabled = enabled
    }

    var isEnabled: Bool { enabled }

    func record(eventType: CGEventType, source: ExternalControlEventSource) {
        guard enabled else { return }
        let key = Key(eventType: eventType.rawValue, source: source)
        let now = Date()
        lock.lock()
        let shouldLog = lastLogged[key].map { now.timeIntervalSince($0) >= interval } ?? true
        if shouldLog { lastLogged[key] = now }
        lock.unlock()
        guard shouldLog else { return }

        Diagnostics.log(
            "event-source type=\(eventType.rawValue) pid=\(source.processID) "
                + "bundle=\(source.bundleIdentifier ?? "unknown") "
                + "executable=\(source.executablePath ?? "unknown") "
                + "process=\(source.processName ?? "unknown")"
        )
    }
}

/// Why suppression ended. Logged (metadata only) so traces distinguish the
/// intended boundary-crossing return from fail-safe paths — the root-cause
/// question for the left-edge instant-return bug (issue #37).
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

    public var mode: Mode {
        stateLock.withLock { isSuppressing ? .suppressed : .listening }
    }

    /// Called on the capture thread for every pointer event while suppressed.
    public var onPointerEvent: (@Sendable (PointerEvent) -> Void)?
    /// Called on the capture thread for every keyboard transition while suppressed.
    public var onKeyEvent: (@Sendable (CapturedKeyEvent) -> Void)?
    /// Called synchronously during an external-control takeover so the helper
    /// can release any captured pointer buttons before the triggering event is
    /// passed through to macOS.
    public var onPointerStateReset: (@Sendable () -> Void)?
    /// Called when the pointer reaches a screen edge while listening.
    /// 0=left 1=right 2=top 3=bottom (ScreenEdge rawValue).
    public var onScreenEdge: (@Sendable (ScreenEdge) -> Void)?
    /// Called when suppression is released by the fail-safe (timeout, disconnect, shortcut).
    /// The second parameter is the suppression generation that was active when suppress() was called.
    /// Stale callbacks (older generation) must be discarded by the caller.
    public var onSuppressionReleased: (@Sendable (SuppressionReleaseReason, UInt64) -> Void)?

    private let tapQueue = DispatchQueue(label: "crossinput.capturertap", qos: .userInteractive)
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var watchdog: DispatchSourceTimer?
    /// Dedicated queue for the fail-safe watchdog. The tap queue's only thread
    /// is parked inside CFRunLoopRun() and can never service timer events, so
    /// the watchdog must never target tapQueue (issue #50).
    private let watchdogQueue = DispatchQueue(label: "crossinput.watchdog", qos: .userInteractive)
    /// Fail-safe window. Instance property so tests can shorten it; defaults
    /// to `Self.suppressionTimeout`.
    private let suppressionTimeout: TimeInterval
    private let stateLock = NSLock()
    private var currentPosition: CGPoint = .zero
    /// The display containing the most recently handled pointer event. This is
    /// cleared before every resolution attempt; it is never carried forward
    /// across a gap or out-of-frame event.
    private var currentEventDisplay: DisplayEdgeConfiguration?
    private var isSuppressing = false
    private let externalControlClassifier: ExternalControlEventClassifier
    private let sourceIdentityResolver: @Sendable (Int32) -> ExternalControlEventSource?
    private let sourceIdentityCache = ProcessIdentityCache()
    private let sourceDiagnostics: ExternalControlSourceDiagnostics
    private let cursorVisibility: any CursorVisibilityAPI
    private let cursorVisibilityDiagnosticsEnabled: Bool
    private let pointerRestoreOverride: (() -> Void)?

    /// Monotonically increasing counter identifying the current suppression session.
    /// Incremented on each suppress() call. Passed to onSuppressionReleased so
    /// stale release callbacks can be discarded.
    private var suppressionGeneration: UInt64 = 0

    /// Android target. Absence means that display never triggers a switch.
    private var androidEdgeByDisplay: [CGDirectDisplayID: ScreenEdge] = [:]
    private let edgeThreshold: CGFloat = 2
    private var emergencyHotKey: EventHotKeyRef?
    /// Prevents an immediate re-trigger after the pointer returns to macOS.
    /// Guarded by stateLock (written from release paths on other threads).
    private var edgeCooldownUntil: CFTimeInterval = 0
    /// Set when a return restores the pointer onto the configured edge zone.
    /// Edge detection stays gated until an event shows the pointer physically
    /// outside the zone — a time cooldown alone lets a pointer parked on the
    /// crossing point re-trap into a dead remote session (issue #50).
    /// Guarded by stateLock.
    private var requireEdgeExit = false
    /// Investigation-only balance guard. This is intentionally restored here
    /// so the candidate exercises the same hide/show lifecycle as pre-#87.
    private var isCursorHidden = false
    /// Android key codes currently down on the device; on release (fail-safe,
    /// timeout, disconnect) every stuck key is sent UP so the device never
    /// keeps a key pressed (AGENTS.md rule 5: suppression requires fail-safe).
    private var keysDown: Set<Int> = []

    public convenience init(
        externalControlClassifier: ExternalControlEventClassifier = ExternalControlEventClassifier(),
        sourceIdentityResolver: (@Sendable (Int32) -> ExternalControlEventSource?)? = nil
    ) {
        self.init(
            externalControlClassifier: externalControlClassifier,
            sourceIdentityResolver: sourceIdentityResolver,
            cursorVisibility: CoreGraphicsCursorVisibility(),
            pointerRestoreOverride: nil,
            suppressionTimeoutOverride: nil
        )
    }

    /// Test-only injection point for pointer-restore and watchdog lifecycle tests.
    init(
        externalControlClassifier: ExternalControlEventClassifier = ExternalControlEventClassifier(),
        sourceIdentityResolver: (@Sendable (Int32) -> ExternalControlEventSource?)? = nil,
        cursorVisibility: any CursorVisibilityAPI = CoreGraphicsCursorVisibility(),
        pointerRestoreOverride: (() -> Void)? = nil,
        cursorVisibilityDiagnosticsEnabled: Bool? = nil,
        suppressionTimeoutOverride: TimeInterval? = nil
    ) {
        self.externalControlClassifier = externalControlClassifier
        self.sourceIdentityResolver = sourceIdentityResolver ?? Self.resolveProcessIdentity
        self.sourceDiagnostics = ExternalControlSourceDiagnostics(
            enabled: ProcessInfo.processInfo.environment["CROSSINPUT_DIAG_EVENT_SOURCE"] == "1"
        )
        self.cursorVisibility = cursorVisibility
        self.cursorVisibilityDiagnosticsEnabled = cursorVisibilityDiagnosticsEnabled
            ?? (ProcessInfo.processInfo.environment["CROSSINPUT_DIAG_CURSOR_VISIBILITY"] == "1")
        self.pointerRestoreOverride = pointerRestoreOverride
        self.suppressionTimeout = suppressionTimeoutOverride ?? Self.suppressionTimeout
    }

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
        logInvestigationEnvironment()
        return true
    }

    public func stop() {
        release(reason: .captureStopped)
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
        // CFRunLoopStop is documented thread-safe; call it directly instead of
        // enqueueing on tapQueue, whose thread may be parked inside
        // CFRunLoopRun() and could never service the block (issue #50).
        stateLock.withLock {
            if let runLoop {
                CFRunLoopStop(runLoop)
                self.runLoop = nil
            }
        }
    }

    // MARK: - Mode control

    /// Switches to suppressed mode: pointer events are consumed and forwarded.
    public func suppress() -> UInt64? {
        let generation: UInt64? = stateLock.withLock {
            guard !isSuppressing else { return nil }
            isSuppressing = true
            suppressionGeneration &+= 1
            hideCursor()
            return suppressionGeneration
        }
        guard let generation else { return nil }
        startWatchdog()
        Diagnostics.log("suppression started generation=\(generation)")
        return generation
    }

    /// Returns to listening mode immediately (fail-safe path).
    public func release(reason: SuppressionReleaseReason = .normalReturn) {
        let (wasSuppressing, generation) = stateLock.withLock {
            let was = isSuppressing
            let gen = suppressionGeneration
            isSuppressing = false
            watchdog?.cancel()
            watchdog = nil
            if was {
                showCursor()
            }
            return (was, gen)
        }
        if wasSuppressing {
            Diagnostics.log(
                "suppression released generation=\(generation) reason=\(reason.rawValue)"
            )
            flushStuckKeys()
            if reason == .externalControl {
                // External control owns the pointer position. Do not warp it
                // back to the edge or center; the triggering event is returned
                // to macOS immediately after this synchronous cleanup.
                onPointerStateReset?()
                stateLock.withLock {
                    edgeCooldownUntil = CFAbsoluteTimeGetCurrent() + 0.5
                }
            } else {
                // Physically return the pointer to the crossing edge point the user
                // pushed through, so Android->macOS continues seamlessly instead of
                // jumping to the screen center.
                if let pointerRestoreOverride {
                    pointerRestoreOverride()
                } else {
                    restorePointerAtEdge()
                }
            }
            onSuppressionReleased?(reason, generation)
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
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        default:
            // Source resolution is unnecessary on the hot path while local
            // control is active, unless the opt-in characterization probe is on.
            if suppressionIsActive || sourceDiagnostics.isEnabled {
                let source = externalControlSource(for: event)
                sourceDiagnostics.record(eventType: type, source: source)
                if takeOverForExternalControlIfNeeded(source: source) {
                    // Returning the original event is essential: the first remote
                    // move/click/key event must reach macOS, not just later events.
                    return Unmanaged.passUnretained(event)
                }
            }
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            updatePosition(event)
            if suppressionIsActive {
                let dx = Int32(event.getIntegerValueField(.mouseEventDeltaX))
                let dy = Int32(event.getIntegerValueField(.mouseEventDeltaY))
                onPointerEvent?(PointerEvent(.move(dx: dx, dy: dy)))
                holdPointerAtEdge()
                return nil // consume: pointer held at the edge
            }
            detectEdge()
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            if suppressionIsActive {
                let button = Self.buttonIndex(for: type)
                let down: Bool
                switch type {
                case .leftMouseDown, .rightMouseDown, .otherMouseDown: down = true
                default: down = false
                }
                onPointerEvent?(PointerEvent(.button(button: button, down: down)))
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            if suppressionIsActive {
                let vertical = Float(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
                let horizontal = Float(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
                onPointerEvent?(PointerEvent(.scroll(horizontal: horizontal, vertical: vertical)))
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp, .flagsChanged:
            return handleKeyboard(event: event, type: type)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Exercises the event-tap decision path without installing a system tap.
    /// This is internal so the macOS regression tests can verify synchronous
    /// takeover and same-event pass-through without generating user input.
    internal func handleForTesting(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        handle(proxy: OpaquePointer(bitPattern: 1)!, type: type, event: event)
    }

    /// Handles keyboard events while suppressed. When suppressed, key events are
    /// consumed (never reach the macOS system) — this is what blocks Cmd+Tab,
    /// Spotlight, Mission Control, etc. while the user is typing on the Android
    /// side. The events are forwarded as Android key CODE transitions.
    /// Non-ANSI keys (media, brightness, etc.) are consumed but not forwarded.
    /// The event is forwarded with the current modifier state so the Android IME
    /// can compose (e.g. Korean 2-set does its own mod mapping).
    ///
    /// Emergency fail-safe: ⌘⇧X is detected here inside the tap, because this
    /// tap consumes every keyboard event before the window server can match
    /// registered Carbon hot keys — the shortcut must not depend on events we
    /// swallow (issue #53). The Carbon registration remains a secondary path
    /// for windows where the tap itself is disabled or unsuppressed.
    private func handleKeyboard(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        guard suppressionIsActive else { return Unmanaged.passUnretained(event) }
        let virtualKey = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown,
           virtualKey == Self.emergencyKeyCode,
           event.flags.intersection(Self.emergencyModifierMask) == Self.emergencyModifiers {
            Diagnostics.log("emergency shortcut detected")
            release(reason: .emergencyHotkey)
            return nil
        }
        let metaState = KeyCodeMapper.androidMetaState(ofFlags: event.flags)
        let keyCode = KeyCodeMapper.androidKeyCode(ofVirtualKey: virtualKey)
        switch type {
        case .flagsChanged:
            // Modifier-only change. Track it in the repeat/down state via its
            // translated key code if known; otherwise ignore (consume anyway).
            break
        case .keyDown:
            // Auto-repeat arrives as further .keyDown with the autorepeat bit set.
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if let keyCode {
                keysDown.insert(keyCode)
                onKeyEvent?(CapturedKeyEvent(keyCode: keyCode, metaState: metaState,
                                             action: 0, repeatCount: isRepeat ? 1 : 0))
            }
        case .keyUp:
            if let keyCode {
                keysDown.remove(keyCode)
                onKeyEvent?(CapturedKeyEvent(keyCode: keyCode, metaState: metaState,
                                             action: 1, repeatCount: 0))
            }
        default:
            break
        }
        return nil // consume: system shortcuts must not fire on macOS
    }

    /// Fail-safe: if suppression ends (timeout/disconnect/emergency ⌘⇧X) while
    /// keys were still held, release them on the device so it never gets stuck.
    private func flushStuckKeys() {
        let held = keysDown
        keysDown.removeAll()
        for keyCode in held {
            onKeyEvent?(CapturedKeyEvent(keyCode: keyCode, metaState: 0, action: 1, repeatCount: 0))
        }
        if !held.isEmpty {
            Diagnostics.log("flushed \(held.count) stuck key(s)")
        }
    }

    private func updatePosition(_ event: CGEvent) {
        currentPosition = event.location
        currentEventDisplay = nil
        var displayID = CGDirectDisplayID()
        var displayCount: UInt32 = 0
        guard CGGetDisplaysWithPoint(currentPosition, 1, &displayID, &displayCount) == .success,
              displayCount == 1 else {
            return
        }
        currentEventDisplay = DisplayEdgeConfiguration(
            displayID: displayID,
            // CGEvent.location and CGDisplayBounds use the same global Quartz
            // coordinate space. NSScreen.frame uses AppKit coordinates and
            // diverges for displays above or below the primary display.
            frame: CGDisplayBounds(displayID),
            configuredEdge: nil
        )
    }

    private var currentDisplayID: CGDirectDisplayID? {
        currentEventDisplay?.displayID
    }

    private func detectEdge() {
        // After a return-to-macOS warp, ignore the edge until the pointer has
        // physically left the configured edge zone. The pointer is restored
        // onto the crossing point, so a plain time cooldown re-traps the user
        // the moment it expires (or races with in-flight events, issue #50).
        stateLock.lock()
        if CFAbsoluteTimeGetCurrent() < edgeCooldownUntil {
            stateLock.unlock()
            return
        }
        let exitGated = requireEdgeExit
        stateLock.unlock()
        guard let display = currentEventDisplay,
              let configuredEdge = stateLock.withLock({ androidEdgeByDisplay[display.displayID] }) else {
            return
        }
        let currentDisplay = DisplayEdgeConfiguration(
            displayID: display.displayID,
            frame: display.frame,
            configuredEdge: configuredEdge
        )
        // Only the configured Android edge of the display containing this
        // event triggers a switch. An unresolved gap/out-of-frame event has no
        // candidate and therefore remains ordinary macOS navigation.
        guard let candidate = DisplayEdgeResolver.candidate(
            at: currentPosition,
            displays: [currentDisplay],
            threshold: edgeThreshold
        ) else {
            if exitGated {
                // First event outside the zone releases the gate; that event
                // itself cannot arm (it points away from the edge).
                stateLock.withLock { requireEdgeExit = false }
            }
            return
        }
        if exitGated { return }
        onScreenEdge?(candidate.edge)
    }

    private func centerPointer() {
        let frame = CGDisplayBounds(CGMainDisplayID())
        let target = CGPoint(x: frame.midX, y: frame.midY)
        let result = CGWarpMouseCursorPosition(target)
        logPointerWarp(operation: "center", target: target, result: result)
    }

    /// Pins the macOS pointer to the configured Android edge of the current
    /// display while suppressed (CGWarpMouseCursorPosition posts no events,
    /// so there is no feedback loop). Keeps the cursor visually at the edge
    /// instead of drifting with the deltas forwarded to Android.
    private func holdPointerAtEdge() {
        guard let display = currentEventDisplay, let displayID = currentDisplayID,
              let edge = stateLock.withLock({ androidEdgeByDisplay[displayID] }) else { return }
        let hold = DisplayEdgeResolver.pointerPosition(
            for: edge,
            in: display.frame,
            at: currentPosition,
            threshold: edgeThreshold)
        let result = CGWarpMouseCursorPosition(hold)
        logPointerWarp(operation: "hold", target: hold, result: result)
    }

    /// Physically returns the pointer to the crossing edge point the user
    /// pushed through, so Android→macOS continues seamlessly instead of
    /// jumping to the screen center.
    private func restorePointerAtEdge() {
        guard let display = currentEventDisplay, let displayID = currentDisplayID,
              let edge = stateLock.withLock({ androidEdgeByDisplay[displayID] }) else {
            let frame = CGDisplayBounds(CGMainDisplayID())
            let target = CGPoint(x: frame.midX, y: frame.midY)
            let result = CGWarpMouseCursorPosition(target)
            logPointerWarp(operation: "restore-center-fallback", target: target, result: result)
            // Arm the gates even on the unresolved-display path: without them
            // a subsequent event near any configured edge can instantly
            // re-arm handoff after a fail-safe return (issue #50).
            stateLock.withLock {
                edgeCooldownUntil = CFAbsoluteTimeGetCurrent() + 0.5
                requireEdgeExit = true
            }
            return
        }
        let hold = DisplayEdgeResolver.pointerPosition(
            for: edge,
            in: display.frame,
            at: currentPosition,
            threshold: edgeThreshold)
        let result = CGWarpMouseCursorPosition(hold)
        logPointerWarp(operation: "restore", target: hold, result: result)
        postSyntheticMove(at: hold)
        // Don't re-trigger the edge switch from the pointer sitting on the
        // edge: park detection behind both the short cooldown and the
        // leave-zone gate. The synthetic move posted above arrives through
        // the tap with the pointer still inside the zone, so only physical
        // movement away from the edge may re-arm handoff (issue #50).
        stateLock.withLock {
            edgeCooldownUntil = CFAbsoluteTimeGetCurrent() + 0.5
            requireEdgeExit = true
        }
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
        if cursorVisibilityDiagnosticsEnabled {
            Diagnostics.log("pointer synthetic-move target=\(Self.format(point)) \(cursorDiagnosticContext())")
        }
    }

    // MARK: - Native cursor investigation diagnostics

    private func hideCursor() {
        guard !isCursorHidden else {
            if cursorVisibilityDiagnosticsEnabled {
                Diagnostics.log("cursor hide skipped already-hidden \(cursorDiagnosticContextLocked())")
            }
            return
        }
        let previous = isCursorHidden
        isCursorHidden = true
        let context = cursorDiagnosticContextLocked()
        if cursorVisibilityDiagnosticsEnabled {
            Diagnostics.log("cursor hide call from=\(previous) to=\(isCursorHidden) \(context)")
        }
        let result = cursorVisibility.hideCursor()
        if cursorVisibilityDiagnosticsEnabled {
            Diagnostics.log("cursor hide return result=CGError(\(result.rawValue)) from=\(previous) to=\(isCursorHidden) \(context)")
            logCurrentSystemCursor(operation: "after-hide", context: context)
        }
    }

    private func showCursor() {
        guard isCursorHidden else {
            if cursorVisibilityDiagnosticsEnabled {
                Diagnostics.log("cursor show skipped already-visible \(cursorDiagnosticContextLocked())")
            }
            return
        }
        let previous = isCursorHidden
        isCursorHidden = false
        let context = cursorDiagnosticContextLocked()
        if cursorVisibilityDiagnosticsEnabled {
            Diagnostics.log("cursor show call from=\(previous) to=\(isCursorHidden) \(context)")
        }
        let result = cursorVisibility.showCursor()
        if cursorVisibilityDiagnosticsEnabled {
            Diagnostics.log("cursor show return result=CGError(\(result.rawValue)) from=\(previous) to=\(isCursorHidden) \(context)")
            logCurrentSystemCursor(operation: "after-show", context: context)
        }
    }

    private func logPointerWarp(operation: String, target: CGPoint, result: CGError) {
        guard cursorVisibilityDiagnosticsEnabled else { return }
        Diagnostics.log(
            "pointer warp operation=\(operation) target=\(Self.format(target)) "
                + "result=CGError(\(result.rawValue)) \(cursorDiagnosticContext())"
        )
    }

    private func cursorDiagnosticContext() -> String {
        stateLock.withLock { cursorDiagnosticContextLocked() }
    }

    /// Called while stateLock is held by suppression entry/release.
    private func cursorDiagnosticContextLocked() -> String {
        let hostDisplayID = currentEventDisplay.map { String($0.displayID) } ?? "none"
        let configuredDisplayIDs = androidEdgeByDisplay.keys.sorted().map(String.init).joined(separator: ",")
        let configuredEdge = currentEventDisplay
            .flatMap { androidEdgeByDisplay[$0.displayID] }
            .map(\.rawValue) ?? "none"
        return "pointer=\(Self.format(currentPosition)) hostDisplayID=\(hostDisplayID) "
            + "configuredDisplayIDs=[\(configuredDisplayIDs)] configuredEdge=\(configuredEdge)"
    }

    private func logInvestigationEnvironment() {
        guard cursorVisibilityDiagnosticsEnabled else { return }
        let displays = NSScreen.screens.compactMap { screen -> String? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let frame = screen.frame
            return "id=\(number.uint32Value),frame=\(Self.format(frame)),scale=\(screen.backingScaleFactor)"
        }.joined(separator: ";")
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        Diagnostics.log(
            "cursor investigation environment os=\(ProcessInfo.processInfo.operatingSystemVersionString) "
                + "accessibility=\(AXIsProcessTrusted()) displays=\(displays) "
                + "frontmostBundle=\(frontmost) ampersandActive=\(NSRunningApplication.current.isActive)"
        )
        logCurrentSystemCursor(operation: "environment", context: cursorDiagnosticContext())
    }

    private func logCurrentSystemCursor(operation: String, context: String) {
        guard cursorVisibilityDiagnosticsEnabled else { return }
        if Thread.isMainThread {
            Self.logCursorIdentityOnMain(operation: operation, context: context)
        } else {
            DispatchQueue.main.async {
                Self.logCursorIdentityOnMain(operation: operation, context: context)
            }
        }
    }

    private static func logCursorIdentityOnMain(operation: String, context: String) {
        let appCursor = NSCursor.current
        let systemCursor = NSCursor.currentSystem
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        Diagnostics.log(
            "cursor identity operation=\(operation) \(context) "
                + "appCurrent={\(cursorSignature(appCursor))} "
                + "systemCurrent={\(cursorSignature(systemCursor))} "
                + "frontmostBundle=\(frontmost) ampersandActive=\(NSRunningApplication.current.isActive)"
        )
    }

    private static func cursorSignature(_ cursor: NSCursor?) -> String {
        guard let cursor else { return "none" }
        let image = cursor.image
        let bytes = image.tiffRepresentation ?? Data()
        var hash: UInt64 = 14695981039346656037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return "size=\(Int(image.size.width))x\(Int(image.size.height)) "
            + "hotspot=\(Int(cursor.hotSpot.x)),\(Int(cursor.hotSpot.y)) "
            + "tiffBytes=\(bytes.count) fnv1a=\(String(hash, radix: 16))"
    }

    private static func format(_ point: CGPoint) -> String {
        "(\(String(format: "%.1f", Double(point.x))),\(String(format: "%.1f", Double(point.y))))"
    }

    private static func format(_ rect: CGRect) -> String {
        "(x=\(String(format: "%.1f", Double(rect.origin.x))),"
            + "y=\(String(format: "%.1f", Double(rect.origin.y))),"
            + "w=\(String(format: "%.1f", Double(rect.size.width))),"
            + "h=\(String(format: "%.1f", Double(rect.size.height))))"
    }

    // MARK: - Fail-safe watchdog

    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + suppressionTimeout, repeating: suppressionTimeout)
        timer.setEventHandler { [weak self] in
            // No pointer event for the timeout window: restore macOS control.
            self?.release(reason: .watchdogTimeout)
        }
        watchdog = timer
        timer.resume()
    }

    /// Resets the fail-safe watchdog. Called on any forwarded event or connection heartbeat.
    public func pokeWatchdog() {
        stateLock.withLock {
            guard isSuppressing, let watchdog else { return }
            watchdog.schedule(deadline: .now() + suppressionTimeout, repeating: suppressionTimeout)
        }
    }

    public static let suppressionTimeout: TimeInterval = 30

    /// Emergency return shortcut (⇧⌘X). Matched inside the tap because the tap
    /// consumes keyboard events upstream of the window server's hot-key
    /// matching (issue #53).
    private static let emergencyKeyCode = UInt16(kVK_ANSI_X)
    /// Lock-style flags (caps/num/function) are ignored; any other modifier
    /// (control/option) must be absent so a held ⌃⌘X never triggers.
    private static let emergencyModifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
    private static let emergencyModifiers: CGEventFlags = [.maskCommand, .maskShift]

    // MARK: - External-control source resolution

    private var suppressionIsActive: Bool {
        stateLock.withLock { isSuppressing }
    }

    private func externalControlSource(for event: CGEvent) -> ExternalControlEventSource {
        let rawProcessID = event.getIntegerValueField(.eventSourceUnixProcessID)
        guard rawProcessID > 0, rawProcessID <= Int64(Int32.max) else {
            return ExternalControlEventSource(processID: Int32(clamping: rawProcessID))
        }
        let processID = Int32(rawProcessID)
        let resolved = sourceIdentityCache.resolve(processID, using: sourceIdentityResolver)
        return ExternalControlEventSource(
            processID: processID,
            bundleIdentifier: resolved?.bundleIdentifier,
            executablePath: resolved?.executablePath,
            processName: resolved?.processName
        )
    }

    private func takeOverForExternalControlIfNeeded(source: ExternalControlEventSource) -> Bool {
        guard suppressionIsActive,
              let provider = externalControlClassifier.provider(for: source) else {
            return false
        }
        Diagnostics.log("external-control takeover provider=\(provider)")
        release(reason: .externalControl)
        return true
    }

    private static func resolveProcessIdentity(_ processID: Int32) -> ExternalControlEventSource? {
        guard processID > 0,
              let application = NSRunningApplication(processIdentifier: pid_t(processID)) else {
            return nil
        }
        return ExternalControlEventSource(
            processID: processID,
            bundleIdentifier: application.bundleIdentifier,
            executablePath: application.executableURL?.path,
            processName: application.localizedName
        )
    }

    // MARK: - Emergency shortcut (⇧⌘X) — always works, independent of the Android link

    private func installEmergencyHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let capture = Unmanaged<InputCapture>.fromOpaque(userData).takeUnretainedValue()
            capture.release(reason: .emergencyHotkey)
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        var hotKeyRef: EventHotKeyRef?
        let keyCode = UInt32(kVK_ANSI_X)
        let modifiers = UInt32(cmdKey | shiftKey)
        let hotKeyID = EventHotKeyID(signature: OSType(0x414D5058), id: 1) // "AMPX"
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
        .keyDown, .keyUp, .flagsChanged,
    ]

    private static func buttonIndex(for type: CGEventType) -> UInt32 {
        switch type {
        case .rightMouseDown, .rightMouseUp: return 1
        case .otherMouseDown, .otherMouseUp: return 2
        default: return 0
        }
    }
}
