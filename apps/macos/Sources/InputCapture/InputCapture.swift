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

    /// Monotonically increasing counter identifying the current suppression session.
    /// Incremented on each suppress() call. Passed to onSuppressionReleased so
    /// stale release callbacks can be discarded.
    private var suppressionGeneration: UInt64 = 0

    /// Android target. Absence means that display never triggers a switch.
    private var androidEdgeByDisplay: [CGDirectDisplayID: ScreenEdge] = [:]
    private let edgeThreshold: CGFloat = 2
    private var emergencyHotKey: EventHotKeyRef?
    /// Prevents an immediate re-trigger after the pointer returns to macOS.
    private var edgeCooldownUntil: CFTimeInterval = 0
    /// Tracks whether cursor is currently hidden to prevent unbalanced hide/show.
    private var isCursorHidden = false
    /// Android key codes currently down on the device; on release (fail-safe,
    /// timeout, disconnect) every stuck key is sent UP so the device never
    /// keeps a key pressed (AGENTS.md rule 5: suppression requires fail-safe).
    private var keysDown: Set<Int> = []

    public init(
        externalControlClassifier: ExternalControlEventClassifier = ExternalControlEventClassifier(),
        sourceIdentityResolver: (@Sendable (Int32) -> ExternalControlEventSource?)? = nil
    ) {
        self.externalControlClassifier = externalControlClassifier
        self.sourceIdentityResolver = sourceIdentityResolver ?? Self.resolveProcessIdentity
        self.sourceDiagnostics = ExternalControlSourceDiagnostics(
            enabled: ProcessInfo.processInfo.environment["CROSSINPUT_DIAG_EVENT_SOURCE"] == "1"
        )
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
    public func suppress() -> UInt64? {
        let generation: UInt64? = stateLock.withLock {
            guard !isSuppressing else { return nil }
            isSuppressing = true
            suppressionGeneration &+= 1
            return suppressionGeneration
        }
        guard let generation else { return nil }
        startWatchdog()
        hideCursor()
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
            return (was, gen)
        }
        if wasSuppressing {
            showCursor()
            flushStuckKeys()
            if reason == .externalControl {
                // External control owns the pointer position. Do not warp it
                // back to the edge or center; the triggering event is returned
                // to macOS immediately after this synchronous cleanup.
                onPointerStateReset?()
                edgeCooldownUntil = CFAbsoluteTimeGetCurrent() + 0.5
            } else {
                // Physically return the pointer to the crossing edge point the user
                // pushed through, so Android->macOS continues seamlessly instead of
                // jumping to the screen center.
                restorePointerAtEdge()
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
    /// Emergency fail-safe: ⌘⇧X (RegisterEventHotKey) keeps working because hot
    /// keys are read by the Carbon event dispatcher before/independent of the tap.
    private func handleKeyboard(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        guard suppressionIsActive else { return Unmanaged.passUnretained(event) }
        let virtualKey = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
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
        // After a return-to-macOS warp, briefly ignore the edge so the pointer
        // sitting on the crossing point does not instantly switch back.
        guard CFAbsoluteTimeGetCurrent() >= edgeCooldownUntil else { return }
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
        ) else { return }
        onScreenEdge?(candidate.edge)
    }

    private func centerPointer() {
        let frame = CGDisplayBounds(CGMainDisplayID())
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Pins the macOS pointer to the configured Android edge of the current
    /// display while suppressed (CGWarpMouseCursorPosition posts no events,
    /// so there is no feedback loop). Keeps the cursor visually at the edge
    /// instead of drifting with the deltas forwarded to Android.
    private func holdPointerAtEdge() {
        guard let display = currentEventDisplay, let displayID = currentDisplayID,
              let edge = stateLock.withLock({ androidEdgeByDisplay[displayID] }) else { return }
        let f = display.frame
        let p = currentPosition
        let hold: CGPoint
        switch edge {
        case .left:   hold = CGPoint(x: f.minX + edgeThreshold, y: p.y)
        case .right:  hold = CGPoint(x: f.maxX - edgeThreshold, y: p.y)
        case .top:    hold = CGPoint(x: p.x, y: f.maxY - edgeThreshold)
        case .bottom: hold = CGPoint(x: p.x, y: f.minY + edgeThreshold)
        }
        CGWarpMouseCursorPosition(hold)
    }

    /// Physically returns the pointer to the crossing edge point the user
    /// pushed through, so Android→macOS continues seamlessly instead of
    /// jumping to the screen center.
    private func restorePointerAtEdge() {
        guard let display = currentEventDisplay, let displayID = currentDisplayID,
              let edge = stateLock.withLock({ androidEdgeByDisplay[displayID] }) else {
            let frame = CGDisplayBounds(CGMainDisplayID())
            CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
            return
        }
        let f = display.frame
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
        guard !isCursorHidden else { return }
        isCursorHidden = true
        CGDisplayHideCursor(CGMainDisplayID())
        Diagnostics.log("cursor hidden (balanced)")
    }

    private func showCursor() {
        guard isCursorHidden else { return }
        isCursorHidden = false
        CGDisplayShowCursor(CGMainDisplayID())
        Diagnostics.log("cursor shown (balanced)")
    }

    // MARK: - Fail-safe watchdog

    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: tapQueue)
        timer.schedule(deadline: .now() + Self.suppressionTimeout, repeating: Self.suppressionTimeout)
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
            watchdog.schedule(deadline: .now() + Self.suppressionTimeout, repeating: Self.suppressionTimeout)
        }
    }

    public static let suppressionTimeout: TimeInterval = 30

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
