import InputDomain

public typealias HostPointerEventHandler =
    @Sendable (SemanticPointerEvent, UInt64) -> Void

public typealias HostPointerFailureHandler =
    @Sendable (UInt64) -> Void

public protocol HostPointerOwnershipLease: AnyObject, Sendable {
    var generation: UInt64 { get }
    var isActive: Bool { get }

    /// Transfers fail-safe release responsibility to the Control lifecycle.
    ///
    /// Before this point acquisition cleanup remains backend-owned. After
    /// publication, Control owns the release ordering barrier and backend
    /// failure callbacks must converge on that same lifecycle release path.
    func transferReleaseResponsibilityToLifecycleOwner()

    /// Returns true only after local host pointer ownership is physically
    /// restored. A false result means the caller must retain the lease and
    /// must not publish localActive yet.
    @discardableResult
    func release() -> Bool
}

public extension HostPointerOwnershipLease {
    /// Backends without a publication-sensitive release path need no state.
    func transferReleaseResponsibilityToLifecycleOwner() {}
}

public protocol HostPointerOwnershipBackend: Sendable {
    func acquire(
        onEvent: @escaping HostPointerEventHandler,
        onFailure: @escaping HostPointerFailureHandler
    ) async throws -> any HostPointerOwnershipLease
}

private struct UnavailableHostPointerOwnershipBackend:
    HostPointerOwnershipBackend {
    private enum UnavailableError: Error {
        case unsupportedPlatform
    }

    func acquire(
        onEvent: @escaping HostPointerEventHandler,
        onFailure: @escaping HostPointerFailureHandler
    ) async throws -> any HostPointerOwnershipLease {
        _ = onEvent
        _ = onFailure
        throw UnavailableError.unsupportedPlatform
    }
}

public enum HostPointerOwnershipBackends {
    /// Production factory. It never falls back to the legacy Quartz-warp
    /// suppression path: unsupported platforms fail acquisition closed.
    public static func makeDefault() -> any HostPointerOwnershipBackend {
        #if canImport(CoreHID)
        if #available(macOS 15.0, *) {
            return CoreHIDBuiltInPointerBackend()
        }
        #endif
        return UnavailableHostPointerOwnershipBackend()
    }
}
