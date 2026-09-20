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
    /// Before this point a backend may have to release itself if monitoring
    /// fails before publication. After this point only the lifecycle owner may
    /// unseize, because it must withdraw keyboard admission first.
    func transferReleaseResponsibilityToLifecycleOwner()

    /// Must restore local host pointer ownership synchronously.
    func release()
}

public extension HostPointerOwnershipLease {
    /// Backends without an independent self-release path need no extra state.
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
