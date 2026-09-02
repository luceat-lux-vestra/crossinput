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
    /// Generation-tagged pointer callback used by the lifecycle owner to
    /// reject an event that was already in flight when suppression ended.
    public var onPointerEventWithGeneration: (@Sendable (PointerEvent, UInt64) -> Void)?
    /// Called on the capture thread for every keyboard transition while suppressed.
    public var onKeyEvent: (@Sendable (CapturedKeyEvent) -> Void)?
    /// Generation-tagged keyboard callback with the same stale-event contract
    /// as `onPointerEventWithGeneration`.
    public var onKeyEventWithGeneration: (@Sendable (CapturedKeyEvent, UInt64) -> Void)?
    /// Called for synthesized key-up transitions during lifecycle cleanup.
    /// This is separate from ordinary capture so a control-disable gate can
    /// reject late user input while still releasing keys already held remotely.
    public var onCleanupKeyEvent: (@Sendable (CapturedKeyEvent) -> Void)?
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
    private let cursorMutationExecutor: CursorMutationExecutor
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
    /// Prevents duplicate releases while restore coordination is bounded. The
    /// local suppression state remains owned until the executor invalidates the
    /// corresponding cursor epoch or its timeout fails safe.
    private var releaseInProgressGeneration: UInt64?
    private let externalControlClassifier: ExternalControlEventClassifier
    private let sourceIdentityResolver: @Sendable (Int32) -> ExternalControlEventSource?
    private let sourceIdentityCache = ProcessIdentityCache()
    private let sourceDiagnostics: ExternalControlSourceDiagnostics
    private let pointerRestoreOverride: (() -> Void)?
    /// Test-only barrier used to deterministically exercise a lifecycle
    /// boundary after an event has been admitted as suppressed but before it
    /// is handed to the capture callback.
    private let beforeSuppressedEventEmission: (@Sendable () -> Void)?

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
    /// Android key codes currently down on the device; on release (fail-safe,
    /// timeout, disconnect) every stuck key is sent UP so the device never
    /// keeps a key pressed (AGENTS.md rule 5: suppression requires fail-safe).
    private var keysDown: Set<Int> = []
    /// The suppression generation that owns `keysDown`. Held-key bookkeeping
    /// must not let a delayed callback from an older remote epoch mutate the
    /// next epoch's cleanup state.
    private var keysDownGeneration: UInt64?

    public convenience init(
        externalControlClassifier: ExternalControlEventClassifier = ExternalControlEventClassifier(),
        sourceIdentityResolver: (@Sendable (Int32) -> ExternalControlEventSource?)? = nil
    ) {
        self.init(
            externalControlClassifier: externalControlClassifier,
            sourceIdentityResolver: sourceIdentityResolver,
            pointerRestoreOverride: nil,
            suppressionTimeoutOverride: nil
        )
    }

    /// Test-only injection point for pointer-restore and watchdog lifecycle tests.
    init(
        externalControlClassifier: ExternalControlEventClassifier = ExternalControlEventClassifier(),
        sourceIdentityResolver: (@Sendable (Int32) -> ExternalControlEventSource?)? = nil,
        pointerRestoreOverride: (() -> Void)? = nil,
        suppressionTimeoutOverride: TimeInterval? = nil,
        beforeSuppressedEventEmission: (@Sendable () -> Void)? = nil,
        cursorMutationExecutor: CursorMutationExecutor? = nil
    ) {
        self.externalControlClassifier = externalControlClassifier
        self.sourceIdentityResolver = sourceIdentityResolver ?? Self.resolveProcessIdentity
        self.sourceDiagnostics = ExternalControlSourceDiagnostics(
            enabled: ProcessInfo.processInfo.environment["CROSSINPUT_DIAG_EVENT_SOURCE"] == "1"
        )
        self.pointerRestoreOverride = pointerRestoreOverride
        self.suppressionTimeout = suppressionTimeoutOverride ?? Self.suppressionTimeout
        self.beforeSuppressedEventEmission = beforeSuppressedEventEmission
        self.cursorMutationExecutor = cursorMutationExecutor ?? .production()
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
            guard let runLoop = CFRunLoopGetCurrent() else { return }
            self.runLoop = runLoop
            CFRunLoopAddSource(runLoop, self.runLoopSource, .commonModes)
            _ = self.cursorMutationExecutor.bind(to: runLoop)
            self.installEmergencyHotKey()
            CFRunLoopRun()
        }
        return true
    }

    public func stop() {
        release(reason: .captureStopped)
        cursorMutationExecutor.unbind()
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
            guard !isSuppressing, releaseInProgressGeneration == nil else { return nil }
            isSuppressing = true
            suppressionGeneration &+= 1
            keysDown.removeAll()
            keysDownGeneration = suppressionGeneration
            // Keep the local transition and the executor's ownership epoch
            // together. A queued restore cannot slip between generation N+1
            // becoming local and its executor admission.
            _ = cursorMutationExecutor.beginOwnership(generation: suppressionGeneration)
            return suppressionGeneration
        }
        guard let generation else { return nil }
        startWatchdog(for: generation)
        Diagnostics.log("suppression started generation=\(generation)")
        return generation
    }

    /// Returns to listening mode immediately (fail-safe path).
    public func release(reason: SuppressionReleaseReason = .normalReturn) {
        release(reason: reason, expectedGeneration: nil)
    }

    /// Releases only the suppression session that admitted the callback. This
    /// prevents a stale watchdog, external-control probe, or emergency event
    /// from releasing a newer suppression generation after re-entry.
    private func release(reason: SuppressionReleaseReason, expectedGeneration: UInt64?) {
        let generation: UInt64? = stateLock.withLock {
            if let expectedGeneration,
               (!isSuppressing || suppressionGeneration != expectedGeneration) {
                return nil
            }
            guard isSuppressing, releaseInProgressGeneration == nil else { return nil }
            let gen = suppressionGeneration
            releaseInProgressGeneration = gen
            watchdog?.cancel()
            watchdog = nil
            return gen
        }
        guard let generation else { return }

        // Invalidate the cursor ownership epoch before local suppression is
        // released. An admitted mutation either finishes before this returns,
        // or a queued/stale mutation is rejected by the executor.
        _ = cursorMutationExecutor.endOwnership(generation: generation)
        stateLock.withLock {
            guard releaseInProgressGeneration == generation else { return }
            isSuppressing = false
            releaseInProgressGeneration = nil
        }

        Diagnostics.log(
            "suppression released generation=\(generation) reason=\(reason.rawValue)"
        )
        flushStuckKeys(for: generation)
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
                restorePointerAtEdge(generation: generation)
            }
        }
        onSuppressionReleased?(reason, generation)
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
        // Capture the ownership epoch once for this event. Reading
        // `isSuppressing` and then reading `suppressionGeneration` later lets
        // a callback that began in epoch A be relabelled as epoch B after a
        // return and re-entry. The controller would then forward stale input
        // to the new remote epoch.
        let suppressedGeneration = stateLock.withLock {
            isSuppressing ? suppressionGeneration : nil
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        default:
            // Source resolution is unnecessary on the hot path while local
            // control is active, unless the opt-in characterization probe is on.
            if suppressedGeneration != nil || sourceDiagnostics.isEnabled {
                let source = externalControlSource(for: event)
                sourceDiagnostics.record(eventType: type, source: source)
                if takeOverForExternalControlIfNeeded(
                    source: source,
                    suppressionGeneration: suppressedGeneration
                ) {
                    // Returning the original event is essential: the first remote
                    // move/click/key event must reach macOS, not just later events.
                    return Unmanaged.passUnretained(event)
                }
            }
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            updatePosition(event)
            if let suppressedGeneration {
                let dx = Int32(event.getIntegerValueField(.mouseEventDeltaX))
                let dy = Int32(event.getIntegerValueField(.mouseEventDeltaY))
                beforeSuppressedEventEmission?()
                emitPointerEvent(PointerEvent(.move(dx: dx, dy: dy)), generation: suppressedGeneration)
                holdPointerAtEdge(generation: suppressedGeneration)
                return nil // consume: pointer held at the edge
            }
            detectEdge()
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            if let suppressedGeneration {
                let button = Self.buttonIndex(for: type)
                let down: Bool
                switch type {
                case .leftMouseDown, .rightMouseDown, .otherMouseDown: down = true
                default: down = false
                }
                beforeSuppressedEventEmission?()
                emitPointerEvent(PointerEvent(.button(button: button, down: down)), generation: suppressedGeneration)
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            if let suppressedGeneration {
                let vertical = Float(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
                let horizontal = Float(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
                beforeSuppressedEventEmission?()
                emitPointerEvent(PointerEvent(.scroll(horizontal: horizontal, vertical: vertical)), generation: suppressedGeneration)
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp, .flagsChanged:
            return handleKeyboard(event: event, type: type, suppressionGeneration: suppressedGeneration)
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
    private func handleKeyboard(event: CGEvent, type: CGEventType,
                                suppressionGeneration: UInt64?) -> Unmanaged<CGEvent>? {
        guard let suppressionGeneration else { return Unmanaged.passUnretained(event) }
        let virtualKey = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown,
           virtualKey == Self.emergencyKeyCode,
           event.flags.intersection(Self.emergencyModifierMask) == Self.emergencyModifiers {
            Diagnostics.log("emergency shortcut detected")
            release(reason: .emergencyHotkey, expectedGeneration: suppressionGeneration)
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
                guard updateKeysDown(keyCode, action: 0, generation: suppressionGeneration) else {
                    return nil
                }
                beforeSuppressedEventEmission?()
                emitKeyEvent(CapturedKeyEvent(keyCode: keyCode, metaState: metaState,
                                              action: 0, repeatCount: isRepeat ? 1 : 0),
                             generation: suppressionGeneration)
            }
        case .keyUp:
            if let keyCode {
                guard updateKeysDown(keyCode, action: 1, generation: suppressionGeneration) else {
                    return nil
                }
                beforeSuppressedEventEmission?()
                emitKeyEvent(CapturedKeyEvent(keyCode: keyCode, metaState: metaState,
                                              action: 1, repeatCount: 0),
                             generation: suppressionGeneration)
            }
        default:
            break
        }
        return nil // consume: system shortcuts must not fire on macOS
    }

    private func emitPointerEvent(_ event: PointerEvent, generation: UInt64) {
        if let onPointerEventWithGeneration {
            onPointerEventWithGeneration(event, generation)
        } else {
            onPointerEvent?(event)
        }
    }

    private func emitKeyEvent(_ event: CapturedKeyEvent, generation: UInt64) {
        if let onKeyEventWithGeneration {
            onKeyEventWithGeneration(event, generation)
        } else {
            onKeyEvent?(event)
        }
    }

    /// Fail-safe: if suppression ends (timeout/disconnect/emergency ⌘⇧X) while
    /// keys were still held, release them on the device so it never gets stuck.
    private func flushStuckKeys(for generation: UInt64) {
        let held: Set<Int> = stateLock.withLock {
            guard keysDownGeneration == generation else { return [] }
            let held = keysDown
            keysDown.removeAll()
            keysDownGeneration = nil
            return held
        }
        for keyCode in held {
            let release = CapturedKeyEvent(keyCode: keyCode, metaState: 0, action: 1, repeatCount: 0)
            if let onCleanupKeyEvent {
                onCleanupKeyEvent(release)
            } else {
                onKeyEvent?(release)
            }
        }
        if !held.isEmpty {
            Diagnostics.log("flushed \(held.count) stuck key(s)")
        }
    }

    /// Updates held-key state only when the event still belongs to the active
    /// suppression generation. The check and mutation are one lock operation
    /// so a return/re-entry cannot let an old callback contaminate cleanup for
    /// the new remote epoch.
    private func updateKeysDown(_ keyCode: Int, action: UInt8, generation: UInt64) -> Bool {
        stateLock.withLock {
            guard isSuppressing, suppressionGeneration == generation else { return false }
            if keysDownGeneration != generation {
                keysDown.removeAll()
                keysDownGeneration = generation
            }
            if action == 0 {
                keysDown.insert(keyCode)
            } else {
                keysDown.remove(keyCode)
            }
            return true
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

    /// Pins the macOS pointer to the configured Android edge of the current
    /// display while suppressed (CGWarpMouseCursorPosition posts no events,
    /// so there is no feedback loop). Keeps the cursor visually at the edge
    /// instead of drifting with the deltas forwarded to Android.
    private func holdPointerAtEdge(generation: UInt64) {
        guard let display = currentEventDisplay, let displayID = currentDisplayID,
              let edge = stateLock.withLock({ androidEdgeByDisplay[displayID] }) else { return }
        let hold = DisplayEdgeResolver.pointerPosition(
            for: edge,
            in: display.frame,
            at: currentPosition,
            threshold: edgeThreshold)
        _ = cursorMutationExecutor.perform(
            kind: .hold,
            generation: generation,
            point: hold,
            precondition: { [weak self] in
                guard let self else { return false }
                return self.stateLock.withLock {
                    self.isSuppressing && self.suppressionGeneration == generation
                }
            }
        )
    }

    /// Physically returns the pointer to the crossing edge point the user
    /// pushed through, so Android→macOS continues seamlessly instead of
    /// jumping to the screen center.
    private func restorePointerAtEdge(generation: UInt64) {
        guard let display = currentEventDisplay, let displayID = currentDisplayID,
              let edge = stateLock.withLock({ androidEdgeByDisplay[displayID] }) else {
            let frame = CGDisplayBounds(CGMainDisplayID())
            _ = cursorMutationExecutor.perform(
                kind: .restore,
                generation: generation,
                point: CGPoint(x: frame.midX, y: frame.midY)
            )
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
        let restored = cursorMutationExecutor.perform(
            kind: .restore,
            generation: generation,
            point: hold
        )
        if restored {
            postSyntheticMove(at: hold)
        }
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
    }

    // MARK: - Fail-safe watchdog

    private func startWatchdog(for generation: UInt64) {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + suppressionTimeout, repeating: suppressionTimeout)
        timer.setEventHandler { [weak self] in
            // No pointer event for the timeout window: restore macOS control.
            self?.release(reason: .watchdogTimeout, expectedGeneration: generation)
        }
        let shouldStart = stateLock.withLock {
            guard isSuppressing, suppressionGeneration == generation else { return false }
            watchdog?.cancel()
            watchdog = timer
            return true
        }
        guard shouldStart else {
            timer.cancel()
            return
        }
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

    private func takeOverForExternalControlIfNeeded(
        source: ExternalControlEventSource,
        suppressionGeneration: UInt64?
    ) -> Bool {
        guard let suppressionGeneration,
              let provider = externalControlClassifier.provider(for: source) else {
            return false
        }
        guard stateLock.withLock({
            isSuppressing && self.suppressionGeneration == suppressionGeneration
        }) else {
            return false
        }
        Diagnostics.log("external-control takeover provider=\(provider)")
        release(reason: .externalControl, expectedGeneration: suppressionGeneration)
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
