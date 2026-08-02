import Foundation
import Protocol

/// adb subprocess 기반 Android helper 연결 관리자 (스켈레톤)
public final class ConnectionManager: Sendable {
    public init() {}

    public func connect(serial: String) async throws {
        // TODO: B-01: adb 서버 실행, app_process spawn, HELLO 핸드셰이크
        // Phase 3 스파이크에서 구현
        fatalError("ConnectionManager.connect 미구현 — Phase 3")
    }
}
