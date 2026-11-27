import Foundation
import CoreGraphics
@preconcurrency import ApplicationServices

public enum InputCapabilityBlocker: Sendable, Equatable {
    case accessibility
    case inputMonitoring
}

public enum InputCaptureFailureClassification: Sendable, Equatable {
    case missingAccessibility
    case missingInputMonitoring
    case captureUnavailable
}

public struct InputCapabilitySnapshot: Sendable, Equatable {
    public let accessibilityGranted: Bool
    public let inputMonitoringGranted: Bool

    /// Separate Input Monitoring is capability-driven rather than a universal
    /// prerequisite. It becomes required only after a real capture attempt
    /// fails while listen-event access is missing on this runtime.
    public let inputMonitoringRequired: Bool

    public init(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        inputMonitoringRequired: Bool = false
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.inputMonitoringGranted = inputMonitoringGranted
        self.inputMonitoringRequired = inputMonitoringRequired
    }

    public var controlBlocker: InputCapabilityBlocker? {
        if !accessibilityGranted {
            return .accessibility
        }
        if inputMonitoringRequired && !inputMonitoringGranted {
            return .inputMonitoring
        }
        return nil
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
///
/// Input Monitoring is not hard-coded as a universal prerequisite. A successful
/// modifying event tap proves that Accessibility is sufficient for the current
/// runtime. If tap creation fails while listen access is absent, this owner
/// remembers that separate Input Monitoring is required for the process lifetime
/// so a later revoke can fail local deterministically.
@MainActor
public final class InputCapabilityController {
    public var onChange: ((InputCapabilitySnapshot) -> Void)?

    public private(set) var snapshot: InputCapabilitySnapshot

    private let system: any InputCapabilitySystem
    private var inputMonitoringRequired = false
    private var monitorTask: Task<Void, Never>?

    public convenience init() {
        self.init(system: SystemInputCapabilitySystem())
    }

    public init(system: any InputCapabilitySystem) {
        self.system = system
        self.snapshot = InputCapabilitySnapshot(
            accessibilityGranted: system.accessibilityTrusted(),
            inputMonitoringGranted: system.listenEventAccessGranted(),
            inputMonitoringRequired: false
        )
    }

    @discardableResult
    public func refresh() -> InputCapabilitySnapshot {
        publishSnapshot(
            InputCapabilitySnapshot(
                accessibilityGranted: system.accessibilityTrusted(),
                inputMonitoringGranted: system.listenEventAccessGranted(),
                inputMonitoringRequired: inputMonitoringRequired
            )
        )
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

    /// Classifies a failed event-tap creation without guessing from one TCC
    /// signal. Accessibility is checked first. If it remains present but listen
    /// access is absent, the failed real capture attempt is the evidence that
    /// this runtime needs separate Input Monitoring.
    @discardableResult
    public func classifyCaptureFailure() -> InputCaptureFailureClassification {
        let current = refresh()
        guard current.accessibilityGranted else {
            return .missingAccessibility
        }

        guard current.inputMonitoringGranted else {
            if !inputMonitoringRequired {
                inputMonitoringRequired = true
                _ = refresh()
            }
            return .missingInputMonitoring
        }

        return .captureUnavailable
    }

    /// Polling is intentionally outside the event-tap callback. Accessibility
    /// loss is a hard invalidation for Ampersand's modifying `.defaultTap`.
    /// A listen-preflight change is published too, but callers must not treat
    /// `inputMonitoringGranted == false` alone as fatal until this owner has
    /// learned `inputMonitoringRequired == true`.
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

    @discardableResult
    private func publishSnapshot(_ updated: InputCapabilitySnapshot) -> InputCapabilitySnapshot {
        guard updated != snapshot else { return snapshot }
        snapshot = updated
        onChange?(updated)
        return snapshot
    }
}
