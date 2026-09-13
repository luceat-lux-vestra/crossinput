import CoreGraphics
import Darwin
import Foundation
import Diagnostics

/// Issue #96 investigation primitive modeled on Deskflow's current macOS
/// primary-screen cursor ownership sequence.
///
/// Remote entry preserves the observed ordering:
///
///     SetsCursorInBackground(true)
///     CGDisplayHideCursor(liveDisplay)
///     CGAssociateMouseAndMouseCursorPosition(true)
///     CGSetLocalEventsSuppressionInterval(0.0001)
///     CGAssociateMouseAndMouseCursorPosition(false)
///
/// Local return mirrors Deskflow's primary enter path before P0 performs its
/// existing one-shot edge restore:
///
///     SetsCursorInBackground(true)
///     CGDisplayShowCursor(hiddenDisplay)
///     CGAssociateMouseAndMouseCursorPosition(true)
///     CGAssociateMouseAndMouseCursorPosition(true)
///     CGSetLocalEventsSuppressionInterval(0.0)
///
/// `CGSetLocalEventsSuppressionInterval` is unavailable to Swift in current
/// SDKs even though Deskflow still calls the legacy symbol from C++. The
/// investigation therefore resolves that exact CoreGraphics symbol via dlsym.
internal final class DeskflowCursorIsolation: @unchecked Sendable {
    internal struct Operations: @unchecked Sendable {
        let liveDisplayID: @Sendable () -> CGDirectDisplayID?
        let setCursorInBackground: @Sendable () -> Int32?
        let hide: @Sendable (CGDirectDisplayID) -> CGError
        let show: @Sendable (CGDirectDisplayID) -> CGError
        let associate: @Sendable (Bool) -> CGError
        let setSuppressionInterval: @Sendable (Double) -> Int32?

        static func production() -> Operations {
            let spi = CursorCompatibilitySPI()
            return Operations(
                liveDisplayID: Self.resolveLiveDisplayID,
                setCursorInBackground: { spi.setCursorInBackground() },
                hide: { CGDisplayHideCursor($0) },
                show: { CGDisplayShowCursor($0) },
                associate: { associated in
                    CGAssociateMouseAndMouseCursorPosition(associated ? 1 : 0)
                },
                setSuppressionInterval: { spi.setLocalEventsSuppressionInterval($0) }
            )
        }

        static func noOp() -> Operations {
            Operations(
                liveDisplayID: { CGMainDisplayID() },
                setCursorInBackground: { 0 },
                hide: { _ in .success },
                show: { _ in .success },
                associate: { _ in .success },
                setSuppressionInterval: { _ in 0 }
            )
        }

        private static func resolveLiveDisplayID() -> CGDirectDisplayID? {
            guard let event = CGEvent(source: nil) else { return nil }
            let point = event.location
            var displayID = CGDirectDisplayID()
            var count: UInt32 = 0
            guard CGGetDisplaysWithPoint(point, 1, &displayID, &count) == .success,
                  count == 1 else {
                return nil
            }
            return displayID
        }
    }

    private final class CursorCompatibilitySPI: @unchecked Sendable {
        private typealias ConnectionFn = @convention(c) () -> Int32
        private typealias SetConnectionPropertyFn = @convention(c) (
            Int32, Int32, CFString, CFTypeRef
        ) -> Int32
        private typealias SetLocalEventsSuppressionIntervalFn = @convention(c) (Double) -> Int32

        private let skyLightHandle: UnsafeMutableRawPointer?
        private let coreGraphicsHandle: UnsafeMutableRawPointer?
        private let connection: ConnectionFn?
        private let setter: SetConnectionPropertyFn?
        private let setSuppressionInterval: SetLocalEventsSuppressionIntervalFn?

        init() {
            let skyLightHandle = dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                RTLD_LAZY | RTLD_LOCAL
            )
            self.skyLightHandle = skyLightHandle

            if let skyLightHandle,
               let symbol = dlsym(skyLightHandle, "_CGSDefaultConnection") {
                connection = unsafeBitCast(symbol, to: ConnectionFn.self)
            } else {
                connection = nil
            }

            if let skyLightHandle,
               let symbol = dlsym(skyLightHandle, "CGSSetConnectionProperty") {
                setter = unsafeBitCast(symbol, to: SetConnectionPropertyFn.self)
            } else {
                setter = nil
            }

            let coreGraphicsHandle = dlopen(
                "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                RTLD_LAZY | RTLD_LOCAL
            )
            self.coreGraphicsHandle = coreGraphicsHandle
            if let coreGraphicsHandle,
               let symbol = dlsym(coreGraphicsHandle, "CGSetLocalEventsSuppressionInterval") {
                setSuppressionInterval = unsafeBitCast(
                    symbol,
                    to: SetLocalEventsSuppressionIntervalFn.self
                )
            } else {
                setSuppressionInterval = nil
            }
        }

        deinit {
            if let skyLightHandle { dlclose(skyLightHandle) }
            if let coreGraphicsHandle { dlclose(coreGraphicsHandle) }
        }

        func setCursorInBackground() -> Int32? {
            guard let connection, let setter else { return nil }
            let cid = connection()
            let result = setter(
                cid,
                cid,
                "SetsCursorInBackground" as CFString,
                kCFBooleanTrue
            )
            Diagnostics.log(
                "issue96 deskflow-cursor-spi result=\(result) connection=_CGSDefaultConnection"
            )
            return result
        }

        func setLocalEventsSuppressionInterval(_ interval: Double) -> Int32? {
            guard let setSuppressionInterval else { return nil }
            let result = setSuppressionInterval(interval)
            Diagnostics.log(
                "issue96 deskflow-suppression-interval value=\(interval) result=\(result)"
            )
            return result
        }
    }

    private let lock = NSLock()
    private let operations: Operations
    private var activeGeneration: UInt64?
    /// Non-nil means one successful hide still requires exactly one show.
    private var hiddenDisplayID: CGDirectDisplayID?
    /// True means a successful associate(false) still requires associate(true).
    private var isDisassociated = false

    internal static func production() -> DeskflowCursorIsolation {
        DeskflowCursorIsolation(operations: .production())
    }

    internal static func noOp() -> DeskflowCursorIsolation {
        DeskflowCursorIsolation(operations: .noOp())
    }

    internal init(operations: Operations) {
        self.operations = operations
    }

    @discardableResult
    internal func begin(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard activeGeneration == nil, hiddenDisplayID == nil, !isDisassociated else {
            Diagnostics.log("deskflow-cursor-isolation begin rejected outstanding-debt")
            return false
        }
        guard let displayID = operations.liveDisplayID() else {
            Diagnostics.log("deskflow-cursor-isolation begin rejected display-unavailable")
            return false
        }
        guard operations.setCursorInBackground() == 0 else {
            Diagnostics.log("deskflow-cursor-isolation begin rejected background-spi")
            return false
        }

        let hideResult = operations.hide(displayID)
        guard hideResult == .success else {
            Diagnostics.log(
                "deskflow-cursor-isolation hide failed result=\(hideResult.rawValue)"
            )
            return false
        }
        hiddenDisplayID = displayID

        let preDisassociateAssociate = operations.associate(true)
        guard preDisassociateAssociate == .success else {
            rollbackVisibilityLocked()
            Diagnostics.log(
                "deskflow-cursor-isolation pre-disassociate-associate failed "
                    + "result=\(preDisassociateAssociate.rawValue)"
            )
            return false
        }

        guard operations.setSuppressionInterval(0.0001) == 0 else {
            rollbackVisibilityLocked()
            Diagnostics.log("deskflow-cursor-isolation suppression-interval admission failed")
            return false
        }

        let disassociateResult = operations.associate(false)
        guard disassociateResult == .success else {
            _ = operations.associate(true)
            rollbackVisibilityLocked()
            _ = operations.setSuppressionInterval(0.0)
            Diagnostics.log(
                "deskflow-cursor-isolation disassociate failed result=\(disassociateResult.rawValue)"
            )
            return false
        }

        isDisassociated = true
        activeGeneration = generation
        Diagnostics.log(
            "deskflow-cursor-isolation entered generation=\(generation) display=\(displayID)"
        )
        return true
    }

    @discardableResult
    internal func end(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let activeGeneration else { return true }
        guard activeGeneration == generation else {
            Diagnostics.log("deskflow-cursor-isolation stale-generation end rejected")
            return false
        }

        let backgroundResult = operations.setCursorInBackground()
        let showResult: CGError
        if let displayID = hiddenDisplayID {
            showResult = operations.show(displayID)
            if showResult == .success {
                hiddenDisplayID = nil
            }
        } else {
            showResult = .success
        }

        let showAssociateResult = operations.associate(true)
        if showAssociateResult == .success {
            isDisassociated = false
        }
        let enterAssociateResult = operations.associate(true)
        let suppressionResetResult = operations.setSuppressionInterval(0.0)

        guard hiddenDisplayID == nil,
              !isDisassociated,
              showAssociateResult == .success,
              enterAssociateResult == .success,
              suppressionResetResult == 0 else {
            Diagnostics.log(
                "deskflow-cursor-isolation cleanup failed generation=\(generation) "
                    + "background=\(backgroundResult.map { String($0) } ?? "unavailable") "
                    + "show=\(showResult.rawValue) "
                    + "show-associate=\(showAssociateResult.rawValue) "
                    + "enter-associate=\(enterAssociateResult.rawValue) "
                    + "suppression=\(suppressionResetResult.map { String($0) } ?? "unavailable")"
            )
            return false
        }

        self.activeGeneration = nil
        Diagnostics.log(
            "deskflow-cursor-isolation ended generation=\(generation) "
                + "background=\(backgroundResult.map { String($0) } ?? "unavailable")"
        )
        return true
    }

    /// Best-effort teardown retries only outstanding cursor debt. A show that
    /// already succeeded is never repeated, so visibility counts cannot be
    /// over-balanced by teardown.
    internal func forceReset() {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration != nil || hiddenDisplayID != nil || isDisassociated else { return }

        let backgroundResult = operations.setCursorInBackground()
        var showResult = CGError.success
        if let displayID = hiddenDisplayID {
            showResult = operations.show(displayID)
            if showResult == .success {
                hiddenDisplayID = nil
            }
        }

        var associateResult = CGError.success
        if isDisassociated {
            associateResult = operations.associate(true)
            if associateResult == .success {
                isDisassociated = false
            }
        }
        let suppressionResetResult = operations.setSuppressionInterval(0.0)

        if hiddenDisplayID == nil,
           !isDisassociated,
           suppressionResetResult == 0 {
            activeGeneration = nil
        }
        Diagnostics.log(
            "deskflow-cursor-isolation force-reset "
                + "background=\(backgroundResult.map { String($0) } ?? "unavailable") "
                + "show=\(showResult.rawValue) associate=\(associateResult.rawValue) "
                + "suppression=\(suppressionResetResult.map { String($0) } ?? "unavailable")"
        )
    }

    private func rollbackVisibilityLocked() {
        guard let displayID = hiddenDisplayID else { return }
        _ = operations.setCursorInBackground()
        if operations.show(displayID) == .success {
            hiddenDisplayID = nil
        }
    }

    internal var activeGenerationForTesting: UInt64? {
        lock.withLock { activeGeneration }
    }

    internal var hiddenDisplayIDForTesting: CGDirectDisplayID? {
        lock.withLock { hiddenDisplayID }
    }

    internal var isDisassociatedForTesting: Bool {
        lock.withLock { isDisassociated }
    }
}
