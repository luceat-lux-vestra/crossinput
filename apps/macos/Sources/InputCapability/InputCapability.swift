import Foundation
import CoreGraphics
@preconcurrency import ApplicationServices

public struct InputCapabilitySnapshot: Sendable, Equatable {
    public let accessibilityGranted: Bool
    public let inputMonitoringGranted: Bool

    public init(accessibilityGranted: Bool, inputMonitoringGranted: Bool) {
        self.accessibilityGranted = accessibilityGranted
        self.inputMonitoringGranted = inputMonitoringGranted
    }
}

public protocol InputCapabilitySystem: Sendable {
    func accessibilityTrusted() -> Bool
    func requestAccessibility()
    func listenEventAccessGranted() -> Bool
    func requestListenEventAccess()
}

public struct SystemInputCapabilitySystem: InputCapabilitySystem {
    public init() {}

    public func accessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    public func listenEventAccessGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    public func requestListenEventAccess() {
        _ = CGRequestListenEventAccess()
    }
}

/// Single owner for macOS input-capability state.
///
/// Preflight is always silent. TCC requests only happen through the explicit
/// request methods, so Connect/Enable/retry paths never spam prompts.
@MainActor
public final class InputCapabilityController {
    public var onChange: ((InputCapabilitySnapshot) -> Void)?

    public private(set) var snapshot: InputCapabilitySnapshot

    private let system: any InputCapabilitySystem
    private var monitorTask: Task<Void, Never>?

    public convenience init() {
        self.init(system: SystemInputCapabilitySystem())
    }

    public init(system: any InputCapabilitySystem) {
        self.system = system
        self.snapshot = InputCapabilitySnapshot(
            accessibilityGranted: system.accessibilityTrusted(),
            inputMonitoringGranted: system.listenEventAccessGranted()
        )
    }

    @discardableResult
    public func refresh() -> InputCapabilitySnapshot {
        let updated = InputCapabilitySnapshot(
            accessibilityGranted: system.accessibilityTrusted(),
            inputMonitoringGranted: system.listenEventAccessGranted()
        )
        guard updated != snapshot else { return snapshot }
        snapshot = updated
        onChange?(updated)
        return updated
    }

    @discardableResult
    public func requestAccessibility() -> InputCapabilitySnapshot {
        let current = refresh()
        guard !current.accessibilityGranted else { return current }
        system.requestAccessibility()
        return refresh()
    }

    @discardableResult
    public func requestInputMonitoring() -> InputCapabilitySnapshot {
        let current = refresh()
        guard !current.inputMonitoringGranted else { return current }
        system.requestListenEventAccess()
        return refresh()
    }

    /// Polling is intentionally outside the event-tap callback. Accessibility
    /// loss is a hard invalidation for Ampersand's modifying `.defaultTap`.
    /// A listen-preflight change is published too, but callers must not treat
    /// `inputMonitoringGranted == false` alone as fatal to an already-proven
    /// working modifying tap on systems where Accessibility covers capture.
    public func startMonitoring(interval: TimeInterval = 1.0) {
        guard monitorTask == nil else { return }
        let nanoseconds = UInt64(max(0.1, interval) * 1_000_000_000)
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard let self, !Task.isCancelled else { return }
                _ = self.refresh()
            }
        }
    }

    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }
}
