import CoreGraphics
import Darwin
import Foundation
import Diagnostics

/// Issue #96 visible-cursor discriminator derived from Deskflow's macOS cursor
/// ownership path, with cursor visibility mutation deliberately removed.
///
/// Remote entry keeps the private/background and relative-input ownership steps:
///
///     SetsCursorInBackground(true)
///     CGAssociateMouseAndMouseCursorPosition(true)
///     CGSetLocalEventsSuppressionInterval(0.0001)
///     CGAssociateMouseAndMouseCursorPosition(false)
///
/// Local return keeps the matching ownership reset before P0 performs its
/// existing one-shot edge restore:
///
///     SetsCursorInBackground(true)
///     CGAssociateMouseAndMouseCursorPosition(true)
///     CGAssociateMouseAndMouseCursorPosition(true)
///     CGSetLocalEventsSuppressionInterval(0.0)
///
/// No hide/show API is called. The native cursor remains observable so Issue
/// #96 directional/resize presentation can be classified directly.
///
/// `CGSetLocalEventsSuppressionInterval` is unavailable to Swift in current
/// SDKs even though Deskflow still calls the legacy symbol from C++. The
/// investigation therefore resolves that exact CoreGraphics symbol via dlsym.
internal final class DeskflowCursorIsolation: @unchecked Sendable {
    internal struct Operations: @unchecked Sendable {
        let setCursorInBackground: @Sendable () -> Int32?
        let associate: @Sendable (Bool) -> CGError
        let setSuppressionInterval: @Sendable (Double) -> Int32?

        static func production() -> Operations {
            let spi = CursorCompatibilitySPI()
            return Operations(
                setCursorInBackground: { spi.setCursorInBackground() },
                associate: { associated in
                    CGAssociateMouseAndMouseCursorPosition(associated ? 1 : 0)
                },
                setSuppressionInterval: { spi.setLocalEventsSuppressionInterval($0) }
            )
        }

        static func noOp() -> Operations {
            Operations(
                setCursorInBackground: { 0 },
                associate: { _ in .success },
                setSuppressionInterval: { _ in 0 }
            )
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
                "issue96 deskflow-visible-cursor-spi result=\(result) connection=_CGSDefaultConnection"
            )
            return result
        }

        func setLocalEventsSuppressionInterval(_ interval: Double) -> Int32? {
            guard let setSuppressionInterval else { return nil }
            let result = setSuppressionInterval(interval)
            Diagnostics.log(
                "issue96 deskflow-visible-suppression-interval value=\(interval) result=\(result)"
            )
            return result
        }
    }

    private let lock = NSLock()
    private let operations: Operations
    private var activeGeneration: UInt64?
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

        guard activeGeneration == nil, !isDisassociated else {
            Diagnostics.log("deskflow-visible-cursor begin rejected outstanding-debt")
            return false
        }
        guard operations.setCursorInBackground() == 0 else {
            Diagnostics.log("deskflow-visible-cursor begin rejected background-spi")
            return false
        }

        let preDisassociateAssociate = operations.associate(true)
        guard preDisassociateAssociate == .success else {
            Diagnostics.log(
                "deskflow-visible-cursor pre-disassociate-associate failed "
                    + "result=\(preDisassociateAssociate.rawValue)"
            )
            return false
        }

        guard operations.setSuppressionInterval(0.0001) == 0 else {
            _ = operations.setSuppressionInterval(0.0)
            Diagnostics.log("deskflow-visible-cursor suppression-interval admission failed")
            return false
        }

        let disassociateResult = operations.associate(false)
        guard disassociateResult == .success else {
            _ = operations.associate(true)
            _ = operations.setSuppressionInterval(0.0)
            Diagnostics.log(
                "deskflow-visible-cursor disassociate failed result=\(disassociateResult.rawValue)"
            )
            return false
        }

        isDisassociated = true
        activeGeneration = generation
        Diagnostics.log("deskflow-visible-cursor entered generation=\(generation)")
        return true
    }

    @discardableResult
    internal func end(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let activeGeneration else { return true }
        guard activeGeneration == generation else {
            Diagnostics.log("deskflow-visible-cursor stale-generation end rejected")
            return false
        }

        let backgroundResult = operations.setCursorInBackground()
        let showAssociateResult = operations.associate(true)
        if showAssociateResult == .success {
            isDisassociated = false
        }
        let enterAssociateResult = operations.associate(true)
        let suppressionResetResult = operations.setSuppressionInterval(0.0)

        guard !isDisassociated,
              showAssociateResult == .success,
              enterAssociateResult == .success,
              suppressionResetResult == 0 else {
            Diagnostics.log(
                "deskflow-visible-cursor cleanup failed generation=\(generation) "
                    + "background=\(backgroundResult.map { String($0) } ?? "unavailable") "
                    + "show-associate=\(showAssociateResult.rawValue) "
                    + "enter-associate=\(enterAssociateResult.rawValue) "
                    + "suppression=\(suppressionResetResult.map { String($0) } ?? "unavailable")"
            )
            return false
        }

        self.activeGeneration = nil
        Diagnostics.log(
            "deskflow-visible-cursor ended generation=\(generation) "
                + "background=\(backgroundResult.map { String($0) } ?? "unavailable")"
        )
        return true
    }

    internal func forceReset() {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration != nil || isDisassociated else { return }

        let backgroundResult = operations.setCursorInBackground()
        var associateResult = CGError.success
        if isDisassociated {
            associateResult = operations.associate(true)
            if associateResult == .success {
                isDisassociated = false
            }
        }
        let suppressionResetResult = operations.setSuppressionInterval(0.0)

        if !isDisassociated, suppressionResetResult == 0 {
            activeGeneration = nil
        }
        Diagnostics.log(
            "deskflow-visible-cursor force-reset "
                + "background=\(backgroundResult.map { String($0) } ?? "unavailable") "
                + "associate=\(associateResult.rawValue) "
                + "suppression=\(suppressionResetResult.map { String($0) } ?? "unavailable")"
        )
    }

    internal var activeGenerationForTesting: UInt64? {
        lock.withLock { activeGeneration }
    }

    internal var isDisassociatedForTesting: Bool {
        lock.withLock { isDisassociated }
    }
}
