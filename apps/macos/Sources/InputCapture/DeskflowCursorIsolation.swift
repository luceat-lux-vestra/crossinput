import CoreGraphics
import Darwin
import Foundation
import Diagnostics

/// Issue #96 visible-cursor discriminator derived from Deskflow's macOS cursor
/// ownership path, with cursor visibility mutation deliberately removed.
///
/// Unlike the persistent Deskflow property, CrossInput balances the private
/// background-cursor authority per remote epoch. Historical CrossInput PR #16
/// used the same true-on-entry / false-on-return contract, and leaving the
/// property enabled can confound native cursor recovery observations.
internal final class DeskflowCursorIsolation: @unchecked Sendable {
    internal struct Operations: @unchecked Sendable {
        let setCursorInBackground: @Sendable (Bool) -> Int32?
        let associate: @Sendable (Bool) -> CGError
        let setSuppressionInterval: @Sendable (Double) -> Int32?

        static func production() -> Operations {
            let spi = CursorCompatibilitySPI()
            return Operations(
                setCursorInBackground: { spi.setCursorInBackground($0) },
                associate: { associated in
                    CGAssociateMouseAndMouseCursorPosition(associated ? 1 : 0)
                },
                setSuppressionInterval: { spi.setLocalEventsSuppressionInterval($0) }
            )
        }

        static func noOp() -> Operations {
            Operations(
                setCursorInBackground: { _ in 0 },
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

        func setCursorInBackground(_ enabled: Bool) -> Int32? {
            guard let connection, let setter else { return nil }
            let cid = connection()
            let value: CFBoolean = enabled ? kCFBooleanTrue : kCFBooleanFalse
            let result = setter(
                cid,
                cid,
                "SetsCursorInBackground" as CFString,
                value
            )
            Diagnostics.log(
                "issue96 deskflow-visible-cursor-spi enabled=\(enabled) result=\(result) "
                    + "connection=_CGSDefaultConnection"
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
    private var backgroundAuthorityEnabled = false

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

        guard activeGeneration == nil, !isDisassociated, !backgroundAuthorityEnabled else {
            Diagnostics.log("deskflow-visible-cursor begin rejected outstanding-debt")
            return false
        }
        guard operations.setCursorInBackground(true) == 0 else {
            Diagnostics.log("deskflow-visible-cursor begin rejected background-spi")
            return false
        }
        backgroundAuthorityEnabled = true

        let preDisassociateAssociate = operations.associate(true)
        guard preDisassociateAssociate == .success else {
            _ = resetBackgroundAuthorityLocked()
            Diagnostics.log(
                "deskflow-visible-cursor pre-disassociate-associate failed "
                    + "result=\(preDisassociateAssociate.rawValue)"
            )
            return false
        }

        guard operations.setSuppressionInterval(0.0001) == 0 else {
            _ = operations.setSuppressionInterval(0.0)
            _ = resetBackgroundAuthorityLocked()
            Diagnostics.log("deskflow-visible-cursor suppression-interval admission failed")
            return false
        }

        let disassociateResult = operations.associate(false)
        guard disassociateResult == .success else {
            _ = operations.associate(true)
            _ = operations.setSuppressionInterval(0.0)
            _ = resetBackgroundAuthorityLocked()
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

        let firstAssociateResult = operations.associate(true)
        let secondAssociateResult = operations.associate(true)
        if firstAssociateResult == .success || secondAssociateResult == .success {
            isDisassociated = false
        }
        let suppressionResetResult = operations.setSuppressionInterval(0.0)
        let backgroundResetResult = resetBackgroundAuthorityLocked()

        guard !isDisassociated,
              !backgroundAuthorityEnabled,
              firstAssociateResult == .success,
              secondAssociateResult == .success,
              suppressionResetResult == 0,
              backgroundResetResult == 0 else {
            Diagnostics.log(
                "deskflow-visible-cursor cleanup failed generation=\(generation) "
                    + "associate1=\(firstAssociateResult.rawValue) "
                    + "associate2=\(secondAssociateResult.rawValue) "
                    + "suppression=\(suppressionResetResult.map { String($0) } ?? "unavailable") "
                    + "background-reset=\(backgroundResetResult.map { String($0) } ?? "unavailable")"
            )
            return false
        }

        self.activeGeneration = nil
        Diagnostics.log("deskflow-visible-cursor ended generation=\(generation) background=false")
        return true
    }

    internal func forceReset() {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration != nil || isDisassociated || backgroundAuthorityEnabled else { return }

        var associateResult = CGError.success
        if isDisassociated {
            associateResult = operations.associate(true)
            if associateResult == .success {
                isDisassociated = false
            }
        }
        let suppressionResetResult = operations.setSuppressionInterval(0.0)
        let backgroundResetResult = resetBackgroundAuthorityLocked()

        if !isDisassociated,
           !backgroundAuthorityEnabled,
           suppressionResetResult == 0 {
            activeGeneration = nil
        }
        Diagnostics.log(
            "deskflow-visible-cursor force-reset "
                + "associate=\(associateResult.rawValue) "
                + "suppression=\(suppressionResetResult.map { String($0) } ?? "unavailable") "
                + "background-reset=\(backgroundResetResult.map { String($0) } ?? "unavailable")"
        )
    }

    private func resetBackgroundAuthorityLocked() -> Int32? {
        guard backgroundAuthorityEnabled else { return 0 }
        let result = operations.setCursorInBackground(false)
        if result == 0 {
            backgroundAuthorityEnabled = false
        }
        return result
    }

    internal var activeGenerationForTesting: UInt64? {
        lock.withLock { activeGeneration }
    }

    internal var isDisassociatedForTesting: Bool {
        lock.withLock { isDisassociated }
    }

    internal var backgroundAuthorityEnabledForTesting: Bool {
        lock.withLock { backgroundAuthorityEnabled }
    }
}
