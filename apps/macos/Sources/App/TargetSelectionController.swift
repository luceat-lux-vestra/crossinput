import Foundation
import Protocol
import AndroidBridge
import AppSettings
import Diagnostics
import Delivery

/// Owns normalized target snapshots and confirms selection with the helper
/// before publishing selected state. A monotonically increasing token rejects
/// responses from an older A/B selection or an older connection.
@MainActor
final class TargetSelectionController {
    private let session: SessionReference
    private let listRequest: (@Sendable () async throws -> CxiFrame)?
    private let selectRequest: (@Sendable (RemoteTargetID) async throws -> CxiFrame)?
    private(set) var targets: [RemoteTarget] = []
    private(set) var selectedTarget: RemoteTarget?
    private(set) var state: TargetState = .unavailable
    private var selectionToken: UInt64 = 0
    private var pendingTarget: RemoteTargetID?

    var onChange: (([RemoteTarget], RemoteTarget?, TargetState) -> Void)?

    init(session: SessionReference,
         listRequest: (@Sendable () async throws -> CxiFrame)? = nil,
         selectRequest: (@Sendable (RemoteTargetID) async throws -> CxiFrame)? = nil) {
        self.session = session
        self.listRequest = listRequest
        self.selectRequest = selectRequest
    }

    /// Refreshes the normalized target snapshot from the current session.
    /// The session identity is checked again after the asynchronous response so
    /// an old connection cannot publish a target list after replacement.
    func refresh(autoSelectPreferred: Bool = true) async throws {
        let frame: CxiFrame
        if let listRequest {
            frame = try await listRequest()
        } else {
            guard let current = session.current() else { throw ConnectionError.streamClosed }
            frame = try await current.request(.listDisplays, payload: Data())
            guard session.current() === current else { throw ConnectionError.streamClosed }
        }
        guard frame.type == .displayList else { throw RefreshError.rejected }
        let list = try Messages.decodeDisplayList(frame.payload)
        applySnapshot(RemoteTargetCatalog.normalize(list))
        if autoSelectPreferred,
           selectedTarget == nil,
           let preferred = RemoteTargetCatalog.preferredTarget(
            in: targets,
            override: AppSettings.Settings.displayIdOverride) {
            try await select(preferred)
        }
    }

    func reset() {
        selectionToken &+= 1
        pendingTarget = nil
        targets = []
        selectedTarget = nil
        state = .unavailable
        publish()
    }

    func applySnapshot(_ newTargets: [RemoteTarget]) {
        targets = newTargets
        if let selected = selectedTarget {
            selectedTarget = newTargets.first(where: { $0.id == selected.id })
            if selectedTarget == nil {
                selectionToken &+= 1
                pendingTarget = nil
            }
        }

        if let pendingTarget,
           !newTargets.contains(where: { $0.id == pendingTarget }) {
            selectionToken &+= 1
            self.pendingTarget = nil
        }

        if let pendingTarget,
           newTargets.contains(where: { $0.id == pendingTarget }) {
            state = .selecting(pendingTarget)
        } else if let selectedTarget {
            state = .selected(selectedTarget.id)
        } else {
            state = newTargets.isEmpty ? .unavailable : .available
        }
        publish()
    }

    /// Applies one unsolicited display update. Returning a target requests an
    /// asynchronous selection by the application layer; this method never
    /// hides a network request behind a synchronous state mutation.
    func handleDisplayChanged(_ info: DisplayInfo) -> RemoteTarget? {
        let target = RemoteTargetCatalog.normalize(info)
        if let index = targets.firstIndex(where: { $0.id == target.id }) {
            targets[index] = target
        } else {
            targets.append(target)
        }
        if selectedTarget == nil, target.kind == .external {
            publish()
            return target
        } else {
            publish()
            return nil
        }
    }

    /// Confirms target selection with the helper before publishing selected
    /// state. Callers can therefore wait for routing readiness before enabling
    /// input capture or reporting a successful connection.
    func select(_ target: RemoteTarget) async throws {
        guard targets.contains(where: { $0.id == target.id }) else {
            Diagnostics.log("selection ignored: target is no longer present")
            throw SelectionError.targetUnavailable
        }
        let sessionSnapshot = session.snapshot()
        guard selectRequest != nil || sessionSnapshot.connection != nil else {
            Diagnostics.log("selection failed: no active session")
            state = selectedTarget.map { .selected($0.id) } ?? (targets.isEmpty ? .unavailable : .available)
            publish()
            throw ConnectionError.streamClosed
        }

        selectionToken &+= 1
        let token = selectionToken
        pendingTarget = target.id
        state = .selecting(target.id)
        publish()
        do {
            let frame: CxiFrame
            if let selectRequest {
                frame = try await selectRequest(target.id)
            } else {
                guard let connection = sessionSnapshot.connection else {
                    throw ConnectionError.streamClosed
                }
                frame = try await connection.request(
                    .selectDisplay,
                    payload: Messages.selectDisplay(displayId: target.id.rawValue))
                guard session.snapshot().generation == sessionSnapshot.generation else {
                    throw SelectionError.stale
                }
            }
            guard frame.type == .displayChanged else {
                throw SelectionError.rejected
            }
            let confirmed = RemoteTargetCatalog.normalize(
                try Messages.decodeDisplayChanged(frame.payload))
            guard confirmed.id == target.id else {
                throw SelectionError.rejected
            }
            guard completeSelection(token: token, target: confirmed) else {
                throw SelectionError.stale
            }
        } catch {
            failSelection(token: token, target: target.id, error: error)
            throw error
        }
    }

    @discardableResult
    private func completeSelection(token: UInt64, target: RemoteTarget) -> Bool {
        guard token == selectionToken, pendingTarget == target.id,
              targets.contains(where: { $0.id == target.id }) else { return false }
        pendingTarget = nil
        if let index = targets.firstIndex(where: { $0.id == target.id }) {
            targets[index] = target
        }
        selectedTarget = target
        state = .selected(target.id)
        publish()
        return true
    }

    private func failSelection(token: UInt64, target: RemoteTargetID, error: Error) {
        guard token == selectionToken, pendingTarget == target else { return }
        pendingTarget = nil
        state = selectedTarget.map { .selected($0.id) } ?? (targets.isEmpty ? .unavailable : .available)
        Diagnostics.log("selection rejected id=\(target.rawValue) reason=\(error.localizedDescription)")
        publish()
    }

    private func publish() {
        onChange?(targets, selectedTarget, state)
    }

    private enum SelectionError: Error {
        case rejected
        case stale
        case targetUnavailable
    }

    private enum RefreshError: Error {
        case rejected
    }
}
