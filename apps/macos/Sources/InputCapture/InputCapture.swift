import Foundation
import CoreGraphics
@preconcurrency import ApplicationServices
import AppKit
import Carbon.HIToolbox
import InputDomain
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
    /// The CGEventTap was disabled at runtime. Remote ownership can no longer
    /// prove keyboard suppression, so the active suppression epoch fails local.
    case tapDisabled
    /// An external controller took ownership of the macOS pointer. This path
    /// must not restore the pointer by warping it to the configured edge.
    case externalControl
}

/// Local CG input observed while the external pointer backend is acquiring or
/// owns the built-in trackpad. Edge-pinned pointer motion may continue during
/// acquisition; every other input shape is incompatible with an atomic handoff.
public enum ExternalPointerOwnerActivity: Sendable, Equatable {
    case edgePinnedPointerMove
    case incompatibleLocalInput
}

/// Compatibility names for the host-facing capture API. Their underlying
/// definitions live in the platform-neutral InputDomain target.
public typealias PointerEvent = SemanticPointerEvent
public typealias CapturedKeyEvent = SemanticKeyEvent

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
    public enum Mode: Sendable, Equatable {
        case listening   // observe only: pointer stays on macOS
        case suppressed  // keyboard + pointer-local-leak suppression is active
    }

    private enum PointerSuppressionStrategy: Sendable {
        /// Legacy event-tap pointer forwarding with edge-hold Quartz warps.
        case eventTapWarp
        /// Another backend owns pointer semantics and physical pointer seizure.
        /// Event-tap pointer events are consumed only as a no-leak guard.
        case externalOwner
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
    /// Called when local CG input appears while an external backend is
    /// acquiring or owns pointer semantics. The triggering event is passed
    /// through when ownership is not yet active or must fail local.
    public var onExternalPointerOwnerActivity:
        (@Sendable (UInt64, ExternalPointerOwnerActivity) -> Void)?
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
    /// Invalidates queued run-loop installation work across stop/restart.
    /// Without this generation, stop() can win before the tapQueue block runs
    /// and that stale block can reattach an invalidated source afterwards.
    private var tapLifecycleGeneration: UInt64 = 0
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
    private var pointerSuppressionStrategy: PointerSuppressionStrategy = .eventTapWarp
    /// External-owner epochs reserve a generation before CoreHID acquisition,
    /// but keyboard suppression/forwarding starts only after the exact
    /// generation has a published and validated host-pointer lease.
    private var externalPointerOwnerReadyGeneration: UInt64?
    private let externalControlClassifier: ExternalControlEventClassifier
    private let sourceIdentityResolver: @Sendable (Int32) -> ExternalControlEventSource?
    private let sourceIdentityCache = ProcessIdentityCache()
    private let sourceDiagnostics: ExternalControlSourceDiagnostics
    private let pointerRestoreOverride: (() -> Void)?
    /// Physical host input must be neutral before ownership can cross to a
    /// different machine. Injected only by tests; production reads the HID
    /// system state table directly.
    private let hostInputNeutralProvider: @Sendable () -> Bool
    /// Test-only barrier used to deterministically exercise a lifecycle
    /// boundary after an event has been admitted as suppressed but before it
    /// is handed to the capture callback.
    private let beforeSuppressedEventEmission: (@Sendable () -> Void)?
    /// Test-only barrier before generation-scoped keyboard admission.
    private let beforeSuppressedKeyboardAdmission: (@Sendable () -> Void)?
    /// Test-only barrier after isSuppressing becomes false but before cleanup
    /// and onSuppressionReleased run. This exposes the exact local-return
    /// linearization boundary without relying on held-key side effects.
    private let afterSuppressionDeactivatedBeforeCallbacks:
        (@Sendable () -> Void)?

    /// Monotonically increasing counter identifying the current suppression session.
    /// Incremented on each suppress() call. Passed to onSuppressionReleased so
    /// stale release callbacks can be discarded.
    private var suppressionGeneration: UInt64 = 0

    /// Android target. Absence means that display never triggers a switch.
    private var androidEdgeByDisplay: [CGDirectDisplayID: ScreenEdge] = [:]
    private let edgeThreshold: CGFloat = 2
    private var emergencyHotKey: EventHotKeyRef?
    private var emergencyHotKeyHandler: EventHandlerRef?
    /// Prevents an immediate re-trigger after the pointer returns to macOS.
    /// Guarded by stateLock (written from release paths on other threads).
    private var edgeCooldownUntil: CFTimeInterval = 0
    /// Set when a return restores the pointer onto the configured edge zone.
    /// Edge detection stays gated until an event shows the pointer physically
    /// outside the zone — a time cooldown alone lets a pointer parked on the
    /// crossing point re-trap into a dead remote session (issue #50).
    /// Guarded by stateLock.
    private var requireEdgeExit = false
    /// Semantic keys currently down for this suppression ownership period. On
    /// release every held key is emitted as semantic UP so the remote adapter
    /// can perform terminal cleanup without host-side Android constants.
    private var keysDown: Set<SemanticKey> = []
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
        beforeSuppressedKeyboardAdmission: (@Sendable () -> Void)? = nil,
        afterSuppressionDeactivatedBeforeCallbacks:
            (@Sendable () -> Void)? = nil,
        hostInputNeutralProvider: (@Sendable () -> Bool)? = nil
    ) {
        self.externalControlClassifier = externalControlClassifier
        self.sourceIdentityResolver = sourceIdentityResolver ?? Self.resolveProcessIdentity
        self.sourceDiagnostics = ExternalControlSourceDiagnostics(
            enabled: ProcessInfo.processInfo.environment["CROSSINPUT_DIAG_EVENT_SOURCE"] == "1"
        )
        self.pointerRestoreOverride = pointerRestoreOverride
        self.hostInputNeutralProvider =
            hostInputNeutralProvider ?? Self.isPhysicalHostInputNeutral
        self.suppressionTimeout = suppressionTimeoutOverride ?? Self.suppressionTimeout
        self.beforeSuppressedEventEmission = beforeSuppressedEventEmission
        self.beforeSuppressedKeyboardAdmission =
            beforeSuppressedKeyboardAdmission
        self.afterSuppressionDeactivatedBeforeCallbacks =
            afterSuppressionDeactivatedBeforeCallbacks
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
        if let existingTap = stateLock.withLock({ tap }) {
            if CGEvent.tapIsEnabled(tap: existingTap) {
                return true
            }
            // A timed-out/user-disabled tap can remain non-nil even when
            // re-enabling failed. Never report that stale tap as a successful
            // fresh capture path.
            Diagnostics.log("startTrusted(): stale disabled tap; recreating")
            stop()
        }

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
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            newTap,
            0
        ) else {
            CFMachPortInvalidate(newTap)
            return false
        }

        let generation: UInt64? = stateLock.withLock {
            // Concurrent starts are not expected in production, but fail
            // locally instead of publishing a second modifying tap.
            guard tap == nil else { return nil }
            tapLifecycleGeneration &+= 1
            if tapLifecycleGeneration == 0 {
                tapLifecycleGeneration = 1
            }
            tap = newTap
            runLoopSource = source
            return tapLifecycleGeneration
        }
        guard let generation else {
            CFMachPortInvalidate(newTap)
            return true
        }

        tapQueue.async { [weak self] in
            guard let self else { return }
            let runLoop = CFRunLoopGetCurrent()

            // Do not capture CFRunLoopSource across the Sendable queue
            // boundary. Publish it under stateLock, then retrieve the exact
            // current source from inside the tap queue.
            let sourceToInstall: CFRunLoopSource? =
                self.stateLock.withLock {
                    guard self.tapLifecycleGeneration == generation,
                          self.tap != nil,
                          let currentSource = self.runLoopSource else {
                        return nil
                    }
                    self.runLoop = runLoop
                    return currentSource
                }
            guard let sourceToInstall else { return }

            CFRunLoopAddSource(runLoop, sourceToInstall, .commonModes)

            // stop() can race between publishing runLoop above and adding the
            // source. Recheck the lifecycle generation before entering the
            // blocking run loop; stale work removes its own source and exits.
            let stillCurrent = self.stateLock.withLock {
                self.tapLifecycleGeneration == generation
                    && self.tap != nil
                    && self.runLoopSource === sourceToInstall
            }
            guard stillCurrent else {
                CFRunLoopRemoveSource(
                    runLoop,
                    sourceToInstall,
                    .commonModes
                )
                return
            }

            self.installEmergencyHotKey(generation: generation)
            CFRunLoopRun()

            self.stateLock.withLock {
                if self.tapLifecycleGeneration == generation {
                    self.runLoop = nil
                }
            }
        }
        return true
    }

    public func stop() {
        release(reason: .captureStopped)

        let runLoopToStop: CFRunLoop? = stateLock.withLock {
            tapLifecycleGeneration &+= 1
            if tapLifecycleGeneration == 0 {
                tapLifecycleGeneration = 1
            }

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

            let activeRunLoop = runLoop
            runLoop = nil
            return activeRunLoop
        }

        // CFRunLoopStop is documented thread-safe; call it directly instead of
        // enqueueing on tapQueue, whose thread may be parked inside
        // CFRunLoopRun() and could never service the block (issue #50).
        if let runLoopToStop {
            CFRunLoopStop(runLoopToStop)
        }
        uninstallEmergencyHotKey()
    }

    // MARK: - Mode control

    /// Legacy suppression path retained while the Architecture Leap is staged.
    /// Pointer semantics come from CGEventTap and movement is edge-held by Quartz.
    public func suppress() -> UInt64? {
        suppress(pointerStrategy: .eventTapWarp)
    }

    /// Suppression path used when another backend owns host pointer seizure and
    /// semantic pointer capture (CoreHID for the built-in trackpad).
    ///
    /// CGEventTap remains installed for keyboard handling and local-input
    /// anomaly detection. Pointer CGEvents are never silently deleted by this
    /// mode; CoreHID is the only pointer-ownership mechanism.
    ///
    /// The returned generation is initially acquisition-only. Keyboard input
    /// stays local until activateExternalPointerOwner(generation:) succeeds.
    public func suppressWithExternalPointerOwner() -> UInt64? {
        suppress(pointerStrategy: .externalOwner)
    }

    /// Activates keyboard suppression/forwarding for exactly one external-owner
    /// generation after its CoreHID lease has been published and validated.
    /// Stale or already-released generations fail closed.
    public func activateExternalPointerOwner(generation: UInt64) -> Bool {
        stateLock.withLock {
            guard isSuppressing,
                  pointerSuppressionStrategy == .externalOwner,
                  suppressionGeneration == generation else {
                return false
            }
            externalPointerOwnerReadyGeneration = generation
            return true
        }
    }

    /// Withdraws remote keyboard ownership for exactly one external-owner
    /// generation without ending the suppression epoch yet. Controller-originated
    /// return uses this before dropping the CoreHID lease so any keyboard event
    /// that starts after native pointer ownership is restored is already local.
    @discardableResult
    public func deactivateExternalPointerOwner(generation: UInt64) -> Bool {
        stateLock.withLock {
            guard isSuppressing,
                  pointerSuppressionStrategy == .externalOwner,
                  suppressionGeneration == generation else {
                return false
            }
            externalPointerOwnerReadyGeneration = nil
            return true
        }
    }

    public func isExternalPointerOwnerActive(generation: UInt64) -> Bool {
        stateLock.withLock {
            isSuppressing
                && pointerSuppressionStrategy == .externalOwner
                && suppressionGeneration == generation
                && externalPointerOwnerReadyGeneration == generation
        }
    }

    private func suppress(pointerStrategy: PointerSuppressionStrategy) -> UInt64? {
        let generation: UInt64? = stateLock.withLock {
            guard !isSuppressing else { return nil }

            if case .externalOwner = pointerStrategy {
                // Do not split an input transition across machines. A key,
                // modifier, or mouse button that went down on macOS must also
                // come up on macOS before remote ownership can begin.
                guard hostInputNeutralProvider() else {
                    Diagnostics.log(
                        "external-owner suppression blocked reason=host-input-active"
                    )
                    return nil
                }
            }

            isSuppressing = true
            pointerSuppressionStrategy = pointerStrategy
            suppressionGeneration &+= 1
            externalPointerOwnerReadyGeneration = nil
            keysDown.removeAll()
            keysDownGeneration = suppressionGeneration
            return suppressionGeneration
        }
        guard let generation else { return nil }
        startWatchdog(for: generation)
        Diagnostics.log(
            "suppression started generation=\(generation) pointerStrategy="
                + "\(pointerStrategy)"
        )
        return generation
    }

    /// Returns to listening mode immediately (fail-safe path).
    public func release(reason: SuppressionReleaseReason = .normalReturn) {
        release(reason: reason, expectedGeneration: nil)
    }

    /// Releases exactly one known suppression generation. Stale lifecycle
    /// work must use this overload so it can never release a newer epoch.
    public func release(
        reason: SuppressionReleaseReason,
        generation: UInt64
    ) {
        release(reason: reason, expectedGeneration: generation)
    }

    /// Releases only the suppression session that admitted the callback. This
    /// prevents a stale watchdog, external-control probe, or emergency event
    /// from releasing a newer suppression generation after re-entry.
    private func release(reason: SuppressionReleaseReason, expectedGeneration: UInt64?) {
        let (wasSuppressing, generation, pointerStrategy) = stateLock.withLock {
            if let expectedGeneration,
               (!isSuppressing || suppressionGeneration != expectedGeneration) {
                return (false, suppressionGeneration, pointerSuppressionStrategy)
            }
            let was = isSuppressing
            let gen = suppressionGeneration
            let strategy = pointerSuppressionStrategy
            isSuppressing = false
            pointerSuppressionStrategy = .eventTapWarp
            externalPointerOwnerReadyGeneration = nil
            watchdog?.cancel()
            watchdog = nil
            return (was, gen, strategy)
        }
        if wasSuppressing {
            Diagnostics.log(
                "suppression released generation=\(generation) reason=\(reason.rawValue)"
            )
            afterSuppressionDeactivatedBeforeCallbacks?()
            flushStuckKeys(for: generation)
            if reason == .externalControl {
                // External control owns the pointer position. Do not warp it.
                // The triggering event is returned to macOS after cleanup.
                onPointerStateReset?()
                armEdgeExitGate()
            } else if pointerStrategy == .externalOwner {
                // CoreHID release restores native pointer ownership in place.
                // Any Quartz warp/synthetic move here would reintroduce the
                // cursor-corruption trigger proven by issue #96.
                armEdgeExitGate()
            } else {
                // Legacy path only: restore the crossing point while the old
                // event-tap ownership implementation remains staged.
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

    /// Reads only boolean hardware state; no key codes or button identities
    /// are logged or persisted. The HID-system table excludes synthetic app
    /// sources and represents the physical input state that must remain owned
    /// by macOS until every down transition has its local up transition.
    private static func isPhysicalHostInputNeutral() -> Bool {
        for rawKeyCode in UInt16(0)...UInt16(127) {
            if CGEventSource.keyState(
                .hidSystemState,
                key: CGKeyCode(rawKeyCode)
            ) {
                return false
            }
        }

        for rawButton in UInt32(0)...UInt32(31) {
            guard let button = CGMouseButton(rawValue: rawButton) else {
                continue
            }
            if CGEventSource.buttonState(
                .hidSystemState,
                button: button
            ) {
                return false
            }
        }
        return true
    }

    // MARK: - Event handling (capture thread)

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Capture the ownership epoch once for this event. Reading
        // `isSuppressing` and then reading `suppressionGeneration` later lets
        // a callback that began in epoch A be relabelled as epoch B after a
        // return and re-entry. The controller would then forward stale input
        // to the new remote epoch.
        let suppressionSnapshot: (
            generation: UInt64,
            pointerStrategy: PointerSuppressionStrategy,
            externalOwnerReady: Bool
        )? = stateLock.withLock {
            guard isSuppressing else { return nil }
            return (
                suppressionGeneration,
                pointerSuppressionStrategy,
                pointerSuppressionStrategy != .externalOwner
                    || externalPointerOwnerReadyGeneration == suppressionGeneration
            )
        }
        let suppressedGeneration = suppressionSnapshot?.generation
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // A disabled modifying tap cannot prove keyboard suppression.
            // If a remote epoch is active, fail local synchronously before
            // attempting to re-enable the tap. This also triggers the Control
            // owner to drop any published CoreHID lease.
            if let generation = suppressedGeneration {
                Diagnostics.log(
                    "event tap disabled during suppression action=local-return"
                )
                release(
                    reason: .tapDisabled,
                    expectedGeneration: generation
                )
            }
            if let currentTap = stateLock.withLock({ tap }) {
                CGEvent.tapEnable(tap: currentTap, enable: true)
            }
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
            if let snapshot = suppressionSnapshot {
                if snapshot.pointerStrategy == .externalOwner {
                    // CoreHID owns built-in-trackpad semantics. A CG pointer
                    // event during this mode is never silently deleted.
                    beforeSuppressedEventEmission?()

                    let currentExternalGeneration: UInt64? =
                        stateLock.withLock {
                            guard isSuppressing,
                                  pointerSuppressionStrategy
                                      == .externalOwner else {
                                return nil
                            }
                            return suppressionGeneration
                        }

                    guard let currentExternalGeneration else {
                        // Local return won the race. This is now a local event.
                        return Unmanaged.passUnretained(event)
                    }

                    if currentExternalGeneration != snapshot.generation {
                        // A replacement external-owner epoch won the race.
                        // Never leak this old callback into the replacement:
                        // fail the current acquisition/ownership local and pass
                        // the triggering event to macOS.
                        onExternalPointerOwnerActivity?(
                            currentExternalGeneration,
                            .incompatibleLocalInput
                        )
                        return Unmanaged.passUnretained(event)
                    }

                    // Before seizure, outward motion may legitimately remain
                    // on the configured edge; after seizure, any CG pointer
                    // event is an ownership anomaly.
                    let remainsAtConfiguredEdge =
                        type == .mouseMoved
                        && currentConfiguredEdgeCandidate() != nil
                    onExternalPointerOwnerActivity?(
                        currentExternalGeneration,
                        remainsAtConfiguredEdge
                            ? .edgePinnedPointerMove
                            : .incompatibleLocalInput
                    )
                    return Unmanaged.passUnretained(event)
                }
                let dx = Int32(event.getIntegerValueField(.mouseEventDeltaX))
                let dy = Int32(event.getIntegerValueField(.mouseEventDeltaY))
                beforeSuppressedEventEmission?()
                emitPointerEvent(
                    PointerEvent(.move(dx: dx, dy: dy)),
                    generation: snapshot.generation
                )
                holdPointerAtEdge(generation: snapshot.generation)
                return nil
            }
            detectEdge()
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            if let snapshot = suppressionSnapshot {
                if snapshot.pointerStrategy == .externalOwner {
                    onExternalPointerOwnerActivity?(
                        snapshot.generation,
                        .incompatibleLocalInput
                    )
                    return Unmanaged.passUnretained(event)
                }
                let button = Self.buttonIndex(for: type)
                let down: Bool
                switch type {
                case .leftMouseDown, .rightMouseDown, .otherMouseDown: down = true
                default: down = false
                }
                beforeSuppressedEventEmission?()
                emitPointerEvent(
                    PointerEvent(.button(button: button, down: down)),
                    generation: snapshot.generation
                )
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            if let snapshot = suppressionSnapshot {
                if snapshot.pointerStrategy == .externalOwner {
                    onExternalPointerOwnerActivity?(
                        snapshot.generation,
                        .incompatibleLocalInput
                    )
                    return Unmanaged.passUnretained(event)
                }
                let vertical = Float(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
                let horizontal = Float(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
                beforeSuppressedEventEmission?()
                emitPointerEvent(
                    PointerEvent(.scroll(horizontal: horizontal, vertical: vertical)),
                    generation: snapshot.generation
                )
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp, .flagsChanged:
            return handleKeyboard(
                event: event,
                type: type,
                suppressionGeneration: suppressedGeneration,
                remoteAdmissionReady: suppressionSnapshot?.externalOwnerReady ?? true
            )
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
    /// side. The host adapter emits platform-neutral semantic key transitions;
    /// Delivery owns conversion to Android/CXI values. Unsupported keys are
    /// consumed but not forwarded. Current modifier state is preserved so the
    /// remote IME can compose exactly as before.
    ///
    /// Emergency fail-safe: ⌘⇧X is detected here inside the tap, because this
    /// tap consumes every keyboard event before the window server can match
    /// registered Carbon hot keys — the shortcut must not depend on events we
    /// swallow (issue #53). The Carbon registration remains a secondary path
    /// for windows where the tap itself is disabled or unsuppressed.
    private func handleKeyboard(
        event: CGEvent,
        type: CGEventType,
        suppressionGeneration: UInt64?,
        remoteAdmissionReady: Bool
    ) -> Unmanaged<CGEvent>? {
        guard let suppressionGeneration else {
            return Unmanaged.passUnretained(event)
        }
        let virtualKey = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown,
           virtualKey == Self.emergencyKeyCode,
           event.flags.intersection(Self.emergencyModifierMask) == Self.emergencyModifiers {
            Diagnostics.log("emergency shortcut detected")
            release(reason: .emergencyHotkey, expectedGeneration: suppressionGeneration)
            return nil
        }

        // During CoreHID acquisition keyboard ownership is still local. Pass
        // the triggering event through and cancel acquisition so a transition
        // cannot split across local and remote owners.
        guard remoteAdmissionReady else {
            onExternalPointerOwnerActivity?(
                suppressionGeneration,
                .incompatibleLocalInput
            )
            return Unmanaged.passUnretained(event)
        }

        let modifiers = KeyCodeMapper.semanticModifiers(ofFlags: event.flags)
        let key = KeyCodeMapper.semanticKey(ofVirtualKey: virtualKey)
        beforeSuppressedKeyboardAdmission?()
        switch type {
        case .flagsChanged:
            // Modifier-only transitions remain represented in modifier state;
            // current production behavior does not emit standalone modifier keys.
            break
        case .keyDown:
            // Auto-repeat arrives as further .keyDown with the autorepeat bit set.
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if let key {
                guard updateKeysDown(
                    key,
                    transition: .down,
                    generation: suppressionGeneration
                ) else {
                    return dispositionAfterStaleKeyboardAdmission(event)
                }
                beforeSuppressedEventEmission?()
                emitKeyEvent(CapturedKeyEvent(
                    key: key,
                    modifiers: modifiers,
                    transition: .down,
                    repeatCount: isRepeat ? 1 : 0
                ), generation: suppressionGeneration)
            }
        case .keyUp:
            if let key {
                guard updateKeysDown(
                    key,
                    transition: .up,
                    generation: suppressionGeneration
                ) else {
                    return dispositionAfterStaleKeyboardAdmission(event)
                }
                beforeSuppressedEventEmission?()
                emitKeyEvent(CapturedKeyEvent(
                    key: key,
                    modifiers: modifiers,
                    transition: .up,
                    repeatCount: 0
                ), generation: suppressionGeneration)
            }
        default:
            break
        }
        return nil // consume: system shortcuts must not fire on macOS
    }

    /// A keyboard callback can lose its generation while it is executing.
    /// If ownership is local now, the triggering event belongs to macOS.
    /// If a replacement external-owner epoch is still acquiring, pass the
    /// event locally and abort that epoch so the transition cannot split.
    /// A replacement fully-remote epoch consumes the stale callback instead
    /// of leaking input to macOS or relabelling it as the new generation.
    private func dispositionAfterStaleKeyboardAdmission(
        _ event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let current: (
            generation: UInt64,
            strategy: PointerSuppressionStrategy,
            externalOwnerReady: Bool
        )? = stateLock.withLock {
            guard isSuppressing else { return nil }
            return (
                suppressionGeneration,
                pointerSuppressionStrategy,
                pointerSuppressionStrategy != .externalOwner
                    || externalPointerOwnerReadyGeneration
                        == suppressionGeneration
            )
        }

        guard let current else {
            return Unmanaged.passUnretained(event)
        }

        if current.strategy == .externalOwner,
           !current.externalOwnerReady {
            onExternalPointerOwnerActivity?(
                current.generation,
                .incompatibleLocalInput
            )
            return Unmanaged.passUnretained(event)
        }

        return nil
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
    /// keys were still held, emit semantic key-up transitions so remote cleanup
    /// never depends on host-side Android constants.
    private func flushStuckKeys(for generation: UInt64) {
        let held: Set<SemanticKey> = stateLock.withLock {
            guard keysDownGeneration == generation else { return [] }
            let held = keysDown
            keysDown.removeAll()
            keysDownGeneration = nil
            return held
        }
        for key in held {
            let release = CapturedKeyEvent(
                key: key,
                modifiers: [],
                transition: .up,
                repeatCount: 0
            )
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
    private func updateKeysDown(
        _ key: SemanticKey,
        transition: KeyTransition,
        generation: UInt64
    ) -> Bool {
        stateLock.withLock {
            guard isSuppressing, suppressionGeneration == generation else { return false }
            if keysDownGeneration != generation {
                keysDown.removeAll()
                keysDownGeneration = generation
            }
            switch transition {
            case .down:
                keysDown.insert(key)
            case .up:
                keysDown.remove(key)
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

    private func currentConfiguredEdgeCandidate() -> DisplayEdgeCandidate? {
        guard let display = currentEventDisplay,
              let configuredEdge = stateLock.withLock({
                  androidEdgeByDisplay[display.displayID]
              }) else {
            return nil
        }
        let currentDisplay = DisplayEdgeConfiguration(
            displayID: display.displayID,
            frame: display.frame,
            configuredEdge: configuredEdge
        )
        return DisplayEdgeResolver.candidate(
            at: currentPosition,
            displays: [currentDisplay],
            threshold: edgeThreshold
        )
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

        // Only the configured Android edge of the display containing this
        // event triggers a switch. An unresolved gap/out-of-frame event has no
        // candidate and therefore remains ordinary macOS navigation.
        guard let candidate = currentConfiguredEdgeCandidate() else {
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

    private func armEdgeExitGate() {
        stateLock.withLock {
            edgeCooldownUntil = CFAbsoluteTimeGetCurrent() + 0.5
            requireEdgeExit = true
        }
    }

    /// Test-only state probe for the no-retrap invariant after local return.
    internal var isAwaitingEdgeExitForTesting: Bool {
        stateLock.withLock { requireEdgeExit }
    }

    private func centerPointer() {
        let frame = CGDisplayBounds(CGMainDisplayID())
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Pins the macOS pointer to the configured Android edge of the current
    /// display while suppressed (CGWarpMouseCursorPosition posts no events,
    /// so there is no feedback loop). Keeps the cursor visually at the edge
    /// instead of drifting with the deltas forwarded to Android.
    private func holdPointerAtEdge(generation: UInt64) {
        // A return may complete while the capture callback is between
        // forwarding and the pointer warp. Do not re-hold the pointer after
        // local ownership has already been restored.
        guard stateLock.withLock({ isSuppressing && suppressionGeneration == generation }) else { return }
        guard let display = currentEventDisplay, let displayID = currentDisplayID,
              let edge = stateLock.withLock({ androidEdgeByDisplay[displayID] }) else { return }
        let hold = DisplayEdgeResolver.pointerPosition(
            for: edge,
            in: display.frame,
            at: currentPosition,
            threshold: edgeThreshold)
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
            // Arm the gates even on the unresolved-display path: without them
            // a subsequent event near any configured edge can instantly
            // re-arm handoff after a fail-safe return (issue #50).
            armEdgeExitGate()
            return
        }
        let hold = DisplayEdgeResolver.pointerPosition(
            for: edge,
            in: display.frame,
            at: currentPosition,
            threshold: edgeThreshold)
        CGWarpMouseCursorPosition(hold)
        postSyntheticMove(at: hold)
        // Don't re-trigger the edge switch from the pointer sitting on the
        // edge: park detection behind both the short cooldown and the
        // leave-zone gate. The synthetic move posted above arrives through
        // the tap with the pointer still inside the zone, so only physical
        // movement away from the edge may re-arm handoff (issue #50).
        armEdgeExitGate()
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

    private func installEmergencyHotKey(generation: UInt64) {
        let alreadyInstalled = stateLock.withLock {
            emergencyHotKey != nil || emergencyHotKeyHandler != nil
        }
        guard !alreadyInstalled else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handlerRef: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let capture = Unmanaged<InputCapture>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                capture.release(reason: .emergencyHotkey)
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard handlerStatus == noErr, let handlerRef else {
            Diagnostics.log(
                "emergency hotkey handler install failed status=\(handlerStatus)"
            )
            return
        }

        var hotKeyRef: EventHotKeyRef?
        let keyCode = UInt32(kVK_ANSI_X)
        let modifiers = UInt32(cmdKey | shiftKey)
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x414D5058),
            id: 1
        ) // "AMPX"
        let hotKeyStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        guard hotKeyStatus == noErr, let hotKeyRef else {
            _ = RemoveEventHandler(handlerRef)
            Diagnostics.log(
                "emergency hotkey registration failed status=\(hotKeyStatus)"
            )
            return
        }

        let accepted = stateLock.withLock {
            guard tapLifecycleGeneration == generation,
                  emergencyHotKey == nil,
                  emergencyHotKeyHandler == nil else {
                return false
            }
            emergencyHotKey = hotKeyRef
            emergencyHotKeyHandler = handlerRef
            return true
        }

        if !accepted {
            _ = UnregisterEventHotKey(hotKeyRef)
            _ = RemoveEventHandler(handlerRef)
        }
    }

    private func uninstallEmergencyHotKey() {
        let registrations: (EventHotKeyRef?, EventHandlerRef?) =
            stateLock.withLock {
                let registrations = (
                    emergencyHotKey,
                    emergencyHotKeyHandler
                )
                emergencyHotKey = nil
                emergencyHotKeyHandler = nil
                return registrations
            }

        if let hotKey = registrations.0 {
            let status = UnregisterEventHotKey(hotKey)
            if status != noErr {
                Diagnostics.log(
                    "emergency hotkey unregister failed status=\(status)"
                )
            }
        }
        if let handler = registrations.1 {
            let status = RemoveEventHandler(handler)
            if status != noErr {
                Diagnostics.log(
                    "emergency hotkey handler removal failed status=\(status)"
                )
            }
        }
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
