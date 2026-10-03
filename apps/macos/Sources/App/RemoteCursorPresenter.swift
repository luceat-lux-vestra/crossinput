import AppKit
import EdgeSwitch
import Diagnostics

protocol RemoteCursorPresenting: AnyObject, Sendable {
    func presentRemote(edge: ScreenEdge)
    func restoreLocal()
}

/// Owns only the user-facing cursor shape while CoreHID owns the built-in
/// trackpad. Pointer isolation remains CoreHID's responsibility.
///
/// The cursor shown at the Mac handoff edge is a native directional resize
/// cursor: horizontal for left/right handoff and vertical for top/bottom.
/// This is explicit remote-control presentation, not a workaround for pointer
/// ownership or a synthetic movement/focus mutation.
final class NativeRemoteCursorPresenter: RemoteCursorPresenting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var operationGeneration: UInt64 = 0

    // Accessed only by blocks dispatched to the main queue.
    private var isPresented = false
    private var previousCursor: NSCursor?

    func presentRemote(edge: ScreenEdge) {
        let generation = nextGeneration()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isCurrent(generation) else {
                return
            }

            if !self.isPresented {
                self.previousCursor = NSCursor.current
                self.isPresented = true
            }

            Self.cursor(for: edge).set()
            Diagnostics.log(
                "host cursor presentation remote edge=\(edge.rawValue)"
            )
        }
    }

    func restoreLocal() {
        let generation = nextGeneration()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isCurrent(generation),
                  self.isPresented else {
                return
            }

            let cursor = self.previousCursor ?? NSCursor.arrow
            self.previousCursor = nil
            self.isPresented = false
            cursor.set()
            Diagnostics.log("host cursor presentation local restored")
        }
    }

    private func nextGeneration() -> UInt64 {
        lock.withLock {
            operationGeneration &+= 1
            if operationGeneration == 0 {
                operationGeneration = 1
            }
            return operationGeneration
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { operationGeneration == generation }
    }

    private static func cursor(for edge: ScreenEdge) -> NSCursor {
        switch edge {
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        }
    }
}
