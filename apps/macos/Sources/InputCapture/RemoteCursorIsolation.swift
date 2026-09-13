import CoreGraphics
import Foundation
import Diagnostics

/// Issue #96 experimental remote-pointer lifecycle.
///
/// This follows the public relative-input pattern used by mature Cocoa clients:
/// disassociate the hardware mouse from the system cursor for the lifetime of
/// remote ownership, hide the local cursor, then re-associate and show it before
/// local ownership is released. Geometry remains owned by CursorMutationExecutor.
///
/// The lifecycle is intentionally generation-scoped so a stale release cannot
/// balance a newer remote epoch. No private WindowServer/SkyLight API is used.
internal final class RemoteCursorIsolation: @unchecked Sendable {
    internal struct Operations: @unchecked Sendable {
        let associate: @Sendable (Bool) -> CGError
        let hide: @Sendable () -> CGError
        let show: @Sendable () -> CGError

        static func production() -> Operations {
            Operations(
                associate: { associated in
                    CGAssociateMouseAndMouseCursorPosition(associated ? 1 : 0)
                },
                // Keep the historical CrossInput public visibility primitive.
                // The display argument is accepted for API compatibility; the
                // cursor hide/show count is process-global.
                hide: { CGDisplayHideCursor(CGMainDisplayID()) },
                show: { CGDisplayShowCursor(CGMainDisplayID()) }
            )
        }

        static func noOp() -> Operations {
            Operations(
                associate: { _ in .success },
                hide: { .success },
                show: { .success }
            )
        }
    }

    private let lock = NSLock()
    private let operations: Operations
    private var activeGeneration: UInt64?

    internal static func production() -> RemoteCursorIsolation {
        RemoteCursorIsolation(operations: .production())
    }

    internal static func noOp() -> RemoteCursorIsolation {
        RemoteCursorIsolation(operations: .noOp())
    }

    internal init(operations: Operations) {
        self.operations = operations
    }

    /// Enters relative remote ownership. Association is changed before hiding,
    /// matching the canonical Cocoa relative-mode ordering. Any partial failure
    /// is rolled back before suppression admission can become visible.
    @discardableResult
    internal func begin(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard activeGeneration == nil else {
            Diagnostics.log("cursor-isolation begin rejected active-generation")
            return false
        }

        let disassociate = operations.associate(false)
        guard disassociate == .success else {
            Diagnostics.log("cursor-isolation disassociate failed result=\(disassociate.rawValue)")
            return false
        }

        let hide = operations.hide()
        guard hide == .success else {
            let rollback = operations.associate(true)
            Diagnostics.log(
                "cursor-isolation hide failed result=\(hide.rawValue) "
                    + "rollback-associate=\(rollback.rawValue)"
            )
            return false
        }

        activeGeneration = generation
        Diagnostics.log("cursor-isolation entered generation=\(generation)")
        return true
    }

    /// Balances the exact generation that owns isolation. Re-association occurs
    /// before show so local physical movement is restored before the cursor is
    /// presented again. On cleanup failure the generation remains active, which
    /// prevents a later suppression admission from stacking another hide/debt.
    @discardableResult
    internal func end(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let activeGeneration else { return true }
        guard activeGeneration == generation else {
            Diagnostics.log("cursor-isolation stale-generation end rejected")
            return false
        }

        let associate = operations.associate(true)
        let show = operations.show()
        guard associate == .success, show == .success else {
            Diagnostics.log(
                "cursor-isolation cleanup failed generation=\(generation) "
                    + "associate=\(associate.rawValue) show=\(show.rawValue)"
            )
            return false
        }

        self.activeGeneration = nil
        Diagnostics.log("cursor-isolation ended generation=\(generation)")
        return true
    }

    /// Last-resort balancing for executor teardown. This is best-effort and is
    /// never used as evidence that a failed release succeeded; it exists only
    /// to avoid intentionally carrying cursor isolation across capture teardown.
    internal func forceReset() {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration != nil else { return }

        let associate = operations.associate(true)
        let show = operations.show()
        if associate == .success, show == .success {
            activeGeneration = nil
        }
        Diagnostics.log(
            "cursor-isolation force-reset associate=\(associate.rawValue) show=\(show.rawValue)"
        )
    }

    internal var activeGenerationForTesting: UInt64? {
        lock.withLock { activeGeneration }
    }
}