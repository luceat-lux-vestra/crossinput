import Foundation
import Protocol
import AndroidBridge

public enum RemoteBoundaryEdge: UInt8, Sendable, Equatable {
    case left = 0
    case right = 1
    case top = 2
    case bottom = 3
}

public enum RemoteBoundaryWatchMode: Sendable, Equatable {
    case deliveredCoordinates
    case compositor
}

public struct PreparedBoundaryWatch: Sendable, Equatable {
    public let controlToken: UInt64
    public let targetID: UInt32
    public let sessionGeneration: UInt64
    public let mode: RemoteBoundaryWatchMode
    public let layerStack: Int32

    public init(controlToken: UInt64,
                targetID: UInt32,
                sessionGeneration: UInt64,
                mode: RemoteBoundaryWatchMode,
                layerStack: Int32) {
        self.controlToken = controlToken
        self.targetID = targetID
        self.sessionGeneration = sessionGeneration
        self.mode = mode
        self.layerStack = layerStack
    }
}

public enum BoundaryWatchSignal: Sendable, Equatable {
    case reached(controlToken: UInt64, targetID: UInt32, edge: RemoteBoundaryEdge)
    case failed(controlToken: UInt64, code: BoundaryWatchErrorCode)
}

public enum BoundaryWatchClientError: Error, Sendable, Equatable {
    case noSession
    case staleSession
    case unexpectedResponse
    case malformedResponse
    case helperRejected(BoundaryWatchErrorCode)
}

public protocol BoundaryWatchServicing: Sendable {
    func start(controlToken: UInt64,
               targetID: UInt32,
               edge: RemoteBoundaryEdge,
               timeout: TimeInterval) async throws -> PreparedBoundaryWatch
    func stop(_ prepared: PreparedBoundaryWatch)
}

public extension BoundaryWatchServicing {
    func start(controlToken: UInt64,
               targetID: UInt32,
               edge: RemoteBoundaryEdge) async throws -> PreparedBoundaryWatch {
        try await start(controlToken: controlToken, targetID: targetID, edge: edge, timeout: 0.5)
    }
}

public struct UnavailableBoundaryWatchService: BoundaryWatchServicing {
    public init() {}

    public func start(controlToken: UInt64,
                      targetID: UInt32,
                      edge: RemoteBoundaryEdge,
                      timeout: TimeInterval) async throws -> PreparedBoundaryWatch {
        throw BoundaryWatchClientError.noSession
    }

    public func stop(_ prepared: PreparedBoundaryWatch) {}
}

public final class BoundaryWatchClient: BoundaryWatchServicing, @unchecked Sendable {
    private let session: SessionReference
    private let cleanupQueue = DispatchQueue(label: "crossinput.boundary-watch-cleanup")

    public init(session: SessionReference) {
        self.session = session
    }

    public func start(controlToken: UInt64,
                      targetID: UInt32,
                      edge: RemoteBoundaryEdge,
                      timeout: TimeInterval = 0.5) async throws -> PreparedBoundaryWatch {
        let snapshot = session.snapshot()
        guard let connection = snapshot.connection else {
            throw BoundaryWatchClientError.noSession
        }

        let response = try await connection.request(
            .boundaryWatchStart,
            payload: Messages.boundaryWatchStart(
                controlToken: controlToken,
                displayId: targetID,
                edge: BoundaryEdge(rawValue: edge.rawValue) ?? .left
            ),
            timeout: timeout
        )

        let current = session.snapshot()
        guard current.generation == snapshot.generation,
              current.connection === connection else {
            throw BoundaryWatchClientError.staleSession
        }

        switch response.type {
        case .boundaryWatchReady:
            let ready: BoundaryWatchReady
            do {
                ready = try Messages.decodeBoundaryWatchReady(response.payload)
            } catch {
                throw BoundaryWatchClientError.malformedResponse
            }
            guard ready.controlToken == controlToken,
                  ready.displayId == targetID else {
                throw BoundaryWatchClientError.unexpectedResponse
            }
            let mode: RemoteBoundaryWatchMode
            switch ready.mode {
            case .deliveredCoordinates:
                mode = .deliveredCoordinates
            case .compositor:
                mode = .compositor
            }
            return PreparedBoundaryWatch(
                controlToken: controlToken,
                targetID: targetID,
                sessionGeneration: snapshot.generation,
                mode: mode,
                layerStack: ready.layerStack
            )

        case .boundaryWatchError:
            let failure: BoundaryWatchError
            do {
                failure = try Messages.decodeBoundaryWatchError(response.payload)
            } catch {
                throw BoundaryWatchClientError.malformedResponse
            }
            guard failure.controlToken == controlToken else {
                throw BoundaryWatchClientError.unexpectedResponse
            }
            throw BoundaryWatchClientError.helperRejected(failure.code)

        default:
            throw BoundaryWatchClientError.unexpectedResponse
        }
    }

    /// Best-effort remote cleanup. Local return never waits for transport I/O.
    public func stop(_ prepared: PreparedBoundaryWatch) {
        cleanupQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.session.snapshot()
            guard snapshot.generation == prepared.sessionGeneration,
                  let connection = snapshot.connection else { return }
            _ = try? connection.send(CxiFrame(
                type: .boundaryWatchStop,
                requestId: 0,
                payload: Messages.boundaryWatchStop(controlToken: prepared.controlToken)
            ))
        }
    }

    public func decodeSignal(_ frame: CxiFrame) -> BoundaryWatchSignal? {
        switch frame.type {
        case .boundaryReached:
            guard let reached = try? Messages.decodeBoundaryReached(frame.payload),
                  let edge = RemoteBoundaryEdge(rawValue: reached.edge.rawValue) else {
                return nil
            }
            return .reached(
                controlToken: reached.controlToken,
                targetID: reached.displayId,
                edge: edge
            )

        case .boundaryWatchError:
            guard let failure = try? Messages.decodeBoundaryWatchError(frame.payload) else {
                return nil
            }
            return .failed(controlToken: failure.controlToken, code: failure.code)

        default:
            return nil
        }
    }
}
