import CoreGraphics
import Darwin
import Foundation
import Diagnostics

/// Issue #96 historical CrossInput cursor semantics, reconstructed from
/// `17e130b5f041dcb62a5ad447ac08f5515903c579`.
///
/// The historical implementation combined four behaviors:
/// - `CGSMainConnectionID` + `SetsCursorInBackground(true/false)` around remote ownership;
/// - display cursor hide/show on both the current display and main display;
/// - a best-effort re-hide after a hold warp;
/// - `CGAssociateMouseAndMouseCursorPosition(1)` immediately after a restore warp.
///
/// The old code called `CGDisplayHideCursor` on every suppressed mouse move.
/// On current macOS that API is observably reference-counted, so blindly
/// repeating it can strand the cursor hidden. This compatibility layer keeps
/// the historical re-hide intent but records every successful hide and balances
/// it with an exact show on return. No AppKit/private cursor recovery is added.
internal final class HistoricalCursorCompatibility: @unchecked Sendable {
    internal struct Operations: @unchecked Sendable {
        var liveDisplayID: @Sendable () -> CGDirectDisplayID?
        var displayIDAtPoint: @Sendable (CGPoint) -> CGDirectDisplayID?
        var mainDisplayID: @Sendable () -> CGDirectDisplayID
        var setCursorInBackground: @Sendable (Bool) -> Int32?
        var hideCursor: @Sendable (CGDirectDisplayID) -> CGError
        var showCursor: @Sendable (CGDirectDisplayID) -> CGError
        var cursorIsVisible: @Sendable () -> Bool
        var associateCursor: @Sendable () -> Void

        static func production() -> Operations {
            let spi = HistoricalPrivateCursorSPI()
            return Operations(
                liveDisplayID: Self.resolveLiveDisplayID,
                displayIDAtPoint: Self.resolveDisplayID(at:),
                mainDisplayID: { CGMainDisplayID() },
                setCursorInBackground: { spi.setCursorInBackground($0) },
                hideCursor: { CGDisplayHideCursor($0) },
                showCursor: { CGDisplayShowCursor($0) },
                cursorIsVisible: { CGCursorIsVisible() != 0 },
                associateCursor: { spi.associateCursor() }
            )
        }

        private static func resolveLiveDisplayID() -> CGDirectDisplayID? {
            guard let event = CGEvent(source: nil) else { return nil }
            return resolveDisplayID(at: event.location)
        }

        private static func resolveDisplayID(at point: CGPoint) -> CGDirectDisplayID? {
            var displayID = CGDirectDisplayID()
            var count: UInt32 = 0
            guard CGGetDisplaysWithPoint(point, 1, &displayID, &count) == .success,
                  count == 1 else {
                return nil
            }
            return displayID
        }
    }

    private final class HistoricalPrivateCursorSPI: @unchecked Sendable {
        private typealias MainConnectionIDFn = @convention(c) () -> UInt32
        private typealias SetConnectionPropertyFn = @convention(c) (
            UInt32, UInt32, CFString, CFTypeRef
        ) -> Int32
        private typealias AssociateFn = @convention(c) (Int32) -> Void

        private let handle: UnsafeMutableRawPointer?
        private let mainConnectionID: MainConnectionIDFn?
        private let setConnectionProperty: SetConnectionPropertyFn?
        private let associate: AssociateFn?

        init() {
            var loaded = dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                RTLD_LAZY | RTLD_LOCAL
            )
            if loaded == nil {
                loaded = dlopen(
                    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                    RTLD_LAZY | RTLD_LOCAL
                )
            }
            handle = loaded

            guard let loaded else {
                mainConnectionID = nil
                setConnectionProperty = nil
                associate = nil
                return
            }

            if let symbol = dlsym(loaded, "CGSMainConnectionID") {
                mainConnectionID = unsafeBitCast(symbol, to: MainConnectionIDFn.self)
            } else {
                mainConnectionID = nil
            }

            if let symbol = dlsym(loaded, "CGSSetConnectionProperty") {
                setConnectionProperty = unsafeBitCast(symbol, to: SetConnectionPropertyFn.self)
            } else {
                setConnectionProperty = nil
            }

            if let symbol = dlsym(loaded, "CGAssociateMouseAndMouseCursorPosition") {
                associate = unsafeBitCast(symbol, to: AssociateFn.self)
            } else {
                associate = nil
            }

            Diagnostics.log(
                "issue96 historical-cursor symbols conn=\(mainConnectionID != nil) "
                    + "setProp=\(setConnectionProperty != nil) associate=\(associate != nil)"
            )
        }

        deinit {
            if let handle { dlclose(handle) }
        }

        func setCursorInBackground(_ enabled: Bool) -> Int32? {
            guard let mainConnectionID, let setConnectionProperty else { return nil }
            let connectionID = mainConnectionID()
            return setConnectionProperty(
                connectionID,
                connectionID,
                "SetsCursorInBackground" as CFString,
                enabled ? kCFBooleanTrue : kCFBooleanFalse
            )
        }

        func associateCursor() {
            associate?(1)
        }
    }

    static let shared = HistoricalCursorCompatibility(operations: .production())

    private let lock = NSLock()
    private let operations: Operations
    private var ownsRemoteCursor = false
    /// Every successful hide is recorded so current macOS reference-counting
    /// can be unwound exactly on return. Failed show calls remain here and are
    /// retried by a later local/restore boundary instead of being forgotten.
    private var successfulHideCalls: [CGDirectDisplayID] = []

    init(operations: Operations) {
        self.operations = operations
    }

    func enterRemote() {
        lock.lock()
        defer { lock.unlock() }
        guard !ownsRemoteCursor else { return }
        ownsRemoteCursor = true

        let backgroundResult = operations.setCursorInBackground(true)
        if let displayID = operations.liveDisplayID() {
            hideAndRecord(displayID)
        }
        hideAndRecord(operations.mainDisplayID())

        Diagnostics.log(
            "issue96 historical-cursor enter background="
                + "\(backgroundResult.map { String($0) } ?? "unavailable") "
                + "hideDebt=\(successfulHideCalls.count)"
        )
    }

    /// Historical PR #16 re-issued hide after every hold warp because macOS
    /// could make the cursor visible again. Avoid increasing the hide count
    /// while the cursor is already hidden; if it is visible, preserve that
    /// historical re-hide behavior and record the resulting debt.
    func didHoldWarp(at point: CGPoint) {
        lock.lock()
        defer { lock.unlock() }
        guard ownsRemoteCursor, operations.cursorIsVisible(),
              let displayID = operations.displayIDAtPoint(point) else {
            return
        }
        hideAndRecord(displayID)
    }

    /// Called after a restore warp and before InputCapture posts its existing
    /// synthetic HID mouseMoved event, matching PR #16 ordering.
    func didRestoreWarp() {
        lock.withLock {
            operations.associateCursor()
            Diagnostics.log("issue96 historical-cursor associate-after-restore")
        }
    }

    func leaveRemote() {
        lock.lock()
        defer { lock.unlock() }
        guard ownsRemoteCursor || !successfulHideCalls.isEmpty else { return }

        let wasRemote = ownsRemoteCursor
        let backgroundResult = wasRemote ? operations.setCursorInBackground(false) : nil
        ownsRemoteCursor = false

        // Unwind in reverse order so every successful reference-counted hide
        // has exactly one matching show even when current and main are equal.
        // Keep only failed show debt; the production restore path calls this
        // again before warping, providing an immediate bounded retry.
        var failedShows: [CGDirectDisplayID] = []
        for displayID in successfulHideCalls.reversed() {
            if operations.showCursor(displayID) != .success {
                failedShows.append(displayID)
            }
        }
        successfulHideCalls = Array(failedShows.reversed())

        Diagnostics.log(
            "issue96 historical-cursor leave background="
                + "\(backgroundResult.map { String($0) } ?? (wasRemote ? "unavailable" : "unchanged")) "
                + "remainingShowDebt=\(successfulHideCalls.count)"
        )
    }

    private func hideAndRecord(_ displayID: CGDirectDisplayID) {
        if operations.hideCursor(displayID) == .success {
            successfulHideCalls.append(displayID)
        }
    }

    var successfulHideCountForTesting: Int {
        lock.withLock { successfulHideCalls.count }
    }

    var ownsRemoteCursorForTesting: Bool {
        lock.withLock { ownsRemoteCursor }
    }
}
