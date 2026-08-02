import Foundation
import Protocol

/// Android helper connection manager based on an adb subprocess (skeleton)
public final class ConnectionManager: Sendable {
    public init() {}

    public func connect(serial: String) async throws {
        // TODO: B-01: start adb server, spawn app_process, HELLO handshake
        // Implemented in the Phase 3 spike
        fatalError("ConnectionManager.connect not implemented — Phase 3")
    }
}
