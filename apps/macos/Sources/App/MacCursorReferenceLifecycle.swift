import CoreGraphics
import Darwin
import Foundation
import Diagnostics

/// Issue #96 reference-convergence candidate.
///
/// Mirrors the cursor-presentation sequence retained by Deskflow/Synergy:
/// reassert background cursor authority, perform the balanced display
/// visibility transition, then re-associate the hardware mouse and cursor.
///
/// This is deliberately narrower than the full Deskflow capture model:
/// CrossInput keeps its existing suppression, event-tap, P0 cursor-writer,
/// warp, and generation semantics. In particular, this type does not
/// disassociate the mouse while remote; that standalone architecture was
/// already physically rejected by Issue #96 Candidate E.
final class MacCursorReferenceLifecycle: @unchecked Sendable {
    struct Operations: @unchecked Sendable {
        var liveDisplayID: @Sendable () -> CGDirectDisplayID?
        var setCursorInBackground: @Sendable () -> Int32?
        var hideCursor: @Sendable (CGDirectDisplayID) -> CGError
        var showCursor: @Sendable (CGDirectDisplayID) -> CGError
        var associateCursor: @Sendable () -> CGError

        static func production() -> Operations {
            let spi = PrivateCursorSPI()
            return Operations(
                liveDisplayID: Self.resolveLiveDisplayID,
                setCursorInBackground: { spi.setCursorInBackground() },
                hideCursor: { CGDisplayHideCursor($0) },
                showCursor: { CGDisplayShowCursor($0) },
                associateCursor: { CGAssociateMouseAndMouseCursorPosition(true) }
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

    private final class PrivateCursorSPI: @unchecked Sendable {
        private typealias ConnectionFn = @convention(c) () -> Int32
        private typealias SetConnectionPropertyFn = @convention(c) (
            Int32, Int32, CFString, CFTypeRef
        ) -> Int32

        private let handle: UnsafeMutableRawPointer?
        private let connection: ConnectionFn?
        private let setter: SetConnectionPropertyFn?
        private let connectionSymbol: String?

        init() {
            let handle = dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                RTLD_LAZY | RTLD_LOCAL
            )
            self.handle = handle

            guard let handle else {
                connection = nil
                setter = nil
                connectionSymbol = nil
                return
            }

            if let symbol = dlsym(handle, "_CGSDefaultConnection") {
                connection = unsafeBitCast(symbol, to: ConnectionFn.self)
                connectionSymbol = "_CGSDefaultConnection"
            } else if let symbol = dlsym(handle, "CGSMainConnectionID") {
                connection = unsafeBitCast(symbol, to: ConnectionFn.self)
                connectionSymbol = "CGSMainConnectionID"
            } else {
                connection = nil
                connectionSymbol = nil
            }

            if let symbol = dlsym(handle, "CGSSetConnectionProperty") {
                setter = unsafeBitCast(symbol, to: SetConnectionPropertyFn.self)
            } else {
                setter = nil
            }
        }

        deinit {
            if let handle { dlclose(handle) }
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
                "issue96 cursor-reference-spi result=\(result) connection=\(connectionSymbol ?? "unknown")"
            )
            return result
        }
    }

    private let lock = NSLock()
    private let operations: Operations
    private var hiddenDisplayID: CGDirectDisplayID?

    init(operations: Operations = .production()) {
        self.operations = operations
    }

    /// Runs immediately before CrossInput admits remote suppression.
    /// Duplicate remote transitions are idempotent so visibility counts cannot
    /// accumulate if an old/stale state callback is delivered twice.
    func enterRemote() {
        lock.lock()
        defer { lock.unlock() }
        guard hiddenDisplayID == nil else { return }
        guard let displayID = operations.liveDisplayID() else {
            Diagnostics.log("issue96 cursor-reference-lifecycle op=hide result=skipped reason=display")
            return
        }

        guard operations.setCursorInBackground() == 0 else {
            // Private authority is the compatibility precondition. If it is not
            // available, preserve the current public-only behavior instead of
            // risking an unbalanced hidden cursor on a future macOS release.
            Diagnostics.log("issue96 cursor-reference-lifecycle op=hide result=skipped reason=spi")
            return
        }

        let hideResult = operations.hideCursor(displayID)
        let associateResult = operations.associateCursor()
        if hideResult == .success {
            hiddenDisplayID = displayID
        }
        Diagnostics.log(
            "issue96 cursor-reference-lifecycle op=hide display=\(displayID) "
                + "cursor=\(hideResult.rawValue) associate=\(associateResult.rawValue)"
        )
    }

    /// Runs on the transition back toward local ownership, before the normal
    /// CrossInput release/restore path whenever the controller owns that
    /// transition. The display used for show is exactly the one whose hide
    /// succeeded; a later live-position change cannot unbalance another
    /// display's visibility count.
    func returnLocal() {
        lock.lock()
        defer { lock.unlock() }
        guard let displayID = hiddenDisplayID else { return }

        // Reassert on every show as Deskflow does. Even if the private setter
        // is no longer available, a previously successful hide must still be
        // balanced with the public show call.
        let backgroundResult = operations.setCursorInBackground()
        let showResult = operations.showCursor(displayID)
        let associateResult = operations.associateCursor()
        if showResult == .success {
            hiddenDisplayID = nil
        }
        Diagnostics.log(
            "issue96 cursor-reference-lifecycle op=show display=\(displayID) "
                + "background=\(backgroundResult.map(String.init) ?? "unavailable") "
                + "cursor=\(showResult.rawValue) associate=\(associateResult.rawValue)"
        )
    }

    var hasHiddenCursorForTesting: Bool {
        lock.withLock { hiddenDisplayID != nil }
    }
}