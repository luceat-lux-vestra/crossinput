import Darwin
import Foundation
import Diagnostics

/// Issue #96 compatibility probe reconstructed from CrossInput PR #16 while
/// preserving the explicit cursor-visibility removal made by #87.
///
/// Historical behaviors retained here are limited to state side effects that
/// do not hide or show the macOS cursor:
/// - `CGSMainConnectionID` + `SetsCursorInBackground(true/false)` around remote ownership;
/// - `CGAssociateMouseAndMouseCursorPosition(1)` immediately after a restore warp.
///
/// Invariant: this type must never call `CGDisplayHideCursor`,
/// `CGDisplayShowCursor`, or otherwise manage cursor visibility. macOS owns
/// native cursor presentation, matching commit 406e6bdd / issue #87.
internal final class HistoricalCursorCompatibility: @unchecked Sendable {
    internal struct Operations: @unchecked Sendable {
        var setCursorInBackground: @Sendable (Bool) -> Int32?
        var associateCursor: @Sendable () -> Void

        static func production() -> Operations {
            let spi = HistoricalPrivateCursorSPI()
            return Operations(
                setCursorInBackground: { spi.setCursorInBackground($0) },
                associateCursor: { spi.associateCursor() }
            )
        }
    }

    private final class HistoricalPrivateCursorSPI: @unchecked Sendable {
        private typealias MainConnectionIDFn = @convention(c) () -> UInt32
        private typealias SetConnectionPropertyFn = @convention(c) (
            UInt32, UInt32, CFString, CFTypeRef
        ) -> Int32
        private typealias AssociateFn = @convention(c) (Int32) -> Void

        private let skyLightHandle: UnsafeMutableRawPointer?
        private let coreGraphicsHandle: UnsafeMutableRawPointer?
        private let mainConnectionID: MainConnectionIDFn?
        private let setConnectionProperty: SetConnectionPropertyFn?
        private let associate: AssociateFn?

        init() {
            var skyLight = dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                RTLD_LAZY | RTLD_LOCAL
            )
            if skyLight == nil {
                skyLight = dlopen(
                    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                    RTLD_LAZY | RTLD_LOCAL
                )
            }
            skyLightHandle = skyLight

            if let skyLight,
               let symbol = dlsym(skyLight, "CGSMainConnectionID") {
                mainConnectionID = unsafeBitCast(symbol, to: MainConnectionIDFn.self)
            } else {
                mainConnectionID = nil
            }

            if let skyLight,
               let symbol = dlsym(skyLight, "CGSSetConnectionProperty") {
                setConnectionProperty = unsafeBitCast(symbol, to: SetConnectionPropertyFn.self)
            } else {
                setConnectionProperty = nil
            }

            let coreGraphics = dlopen(
                "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                RTLD_LAZY | RTLD_LOCAL
            )
            coreGraphicsHandle = coreGraphics
            if let coreGraphics,
               let symbol = dlsym(coreGraphics, "CGAssociateMouseAndMouseCursorPosition") {
                associate = unsafeBitCast(symbol, to: AssociateFn.self)
            } else if let skyLight,
                      let symbol = dlsym(skyLight, "CGAssociateMouseAndMouseCursorPosition") {
                associate = unsafeBitCast(symbol, to: AssociateFn.self)
            } else {
                associate = nil
            }

            Diagnostics.log(
                "issue96 historical-state symbols conn=\(mainConnectionID != nil) "
                    + "setProp=\(setConnectionProperty != nil) associate=\(associate != nil)"
            )
        }

        deinit {
            if let coreGraphicsHandle { dlclose(coreGraphicsHandle) }
            if let skyLightHandle { dlclose(skyLightHandle) }
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
    private var ownsRemoteCursorState = false

    init(operations: Operations) {
        self.operations = operations
    }

    func enterRemote() {
        lock.lock()
        defer { lock.unlock() }
        guard !ownsRemoteCursorState else { return }
        ownsRemoteCursorState = true
        let result = operations.setCursorInBackground(true)
        Diagnostics.log(
            "issue96 historical-state enter background="
                + "\(result.map { String($0) } ?? \"unavailable\")"
        )
    }

    func leaveRemote() {
        lock.lock()
        defer { lock.unlock() }
        guard ownsRemoteCursorState else { return }
        ownsRemoteCursorState = false
        let result = operations.setCursorInBackground(false)
        Diagnostics.log(
            "issue96 historical-state leave background="
                + "\(result.map { String($0) } ?? \"unavailable\")"
        )
    }

    /// Called after a restore warp and before InputCapture posts its existing
    /// synthetic HID mouseMoved event, matching PR #16 ordering without any
    /// cursor hide/show side effect.
    func didRestoreWarp() {
        lock.withLock {
            operations.associateCursor()
            Diagnostics.log("issue96 historical-state associate-after-restore")
        }
    }

    var ownsRemoteCursorStateForTesting: Bool {
        lock.withLock { ownsRemoteCursorState }
    }
}
