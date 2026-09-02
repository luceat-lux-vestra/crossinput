import CoreGraphics
import Darwin
import Foundation
import Diagnostics

/// The only production owner of Quartz cursor-position mutations.
///
/// The event tap's CFRunLoop is the designated writer. Requests from other
/// threads are queued onto that run loop and waited on for a bounded interval;
/// they never execute the platform mutation on the caller thread.
internal final class CursorMutationExecutor: @unchecked Sendable {
    internal enum Kind: String, Sendable {
        case hold
        case restore
    }

    private final class Request: @unchecked Sendable {
        let kind: Kind
        let generation: UInt64
        let precondition: @Sendable () -> Bool
        let mutation: @Sendable () -> Void

        private let stateLock = NSLock()
        private let completion = DispatchSemaphore(value: 0)
        private var cancelled = false
        private var started = false
        private var result: Bool?

        init(
            kind: Kind,
            generation: UInt64,
            precondition: @escaping @Sendable () -> Bool,
            mutation: @escaping @Sendable () -> Void
        ) {
            self.kind = kind
            self.generation = generation
            self.precondition = precondition
            self.mutation = mutation
        }

        func run(on executor: CursorMutationExecutor) {
            guard precondition() else {
                Diagnostics.log("cursor-mutation stale-generation rejected")
                complete(false)
                return
            }
            executor.beforeCommitHook?()
            complete(executor.commit(self))
        }

        /// Cancels only a request that has not entered the serialized commit.
        /// A request already holding the commit gate is allowed to finish; its
        /// platform call began before the coordination timeout was observed.
        @discardableResult
        func cancelIfPending() -> Bool {
            guard stateLock.try() else { return false }
            defer { stateLock.unlock() }
            guard result == nil, !started else { return false }
            cancelled = true
            result = false
            completion.signal()
            return true
        }

        func wait(timeout: TimeInterval) -> Bool? {
            guard completion.wait(timeout: .now() + timeout) == .success else {
                return nil
            }
            return stateLock.withLock { result }
        }

        /// Atomically admits the request relative to cancellation and the
        /// executor's ownership gate. The executor's lock remains held while
        /// the platform mutation runs, so ownership invalidation cannot be
        /// observed as complete before an admitted mutation is finished.
        func beginCommit(using executor: CursorMutationExecutor) -> Bool {
            guard stateLock.lock(
                before: Date().addingTimeInterval(executor.coordinationTimeout)
            ) else {
                Diagnostics.log("cursor-mutation serialization timeout")
                return false
            }
            defer { stateLock.unlock() }
            guard result == nil, !cancelled else { return false }
            guard executor.ownershipLock.lock(
                before: Date().addingTimeInterval(executor.coordinationTimeout)
            ) else {
                return false
            }
            defer { executor.ownershipLock.unlock() }
            guard executor.isCurrent(kind: kind, generation: generation) else {
                Diagnostics.log("cursor-mutation stale-generation rejected")
                return false
            }
            started = true
            mutation()
            return true
        }

        private func complete(_ value: Bool) {
            stateLock.withLock {
                guard result == nil else { return }
                result = value
                completion.signal()
            }
        }
    }

    private let platformMutation: @Sendable (Kind, CGPoint) -> Void
    fileprivate let coordinationTimeout: TimeInterval
    fileprivate let beforeCommitHook: (@Sendable () -> Void)?
    fileprivate let requestEnqueuedHook: (@Sendable () -> Void)?
    fileprivate let ownershipLock = NSLock()

    private let pendingLock = NSLock()
    private var pending: [Request] = []
    private var ownerRunLoop: CFRunLoop?
    private var ownerThreadID: UInt32?
    private var source: CFRunLoopSource?
    private var activeGeneration: UInt64?
    private var latestGeneration: UInt64?

    /// Creates the production executor. `CGWarpMouseCursorPosition` is kept
    /// inside this abstraction so the call has one auditable writer.
    internal static func production() -> CursorMutationExecutor {
        CursorMutationExecutor { _, point in
            CGWarpMouseCursorPosition(point)
        }
    }

    /// Test construction injects the platform mutation and can pause just
    /// before the serialized ownership commit.
    internal init(
        coordinationTimeout: TimeInterval = 0.25,
        beforeCommitHook: (@Sendable () -> Void)? = nil,
        requestEnqueuedHook: (@Sendable () -> Void)? = nil,
        mutation: @escaping @Sendable (Kind, CGPoint) -> Void
    ) {
        self.coordinationTimeout = coordinationTimeout
        self.beforeCommitHook = beforeCommitHook
        self.requestEnqueuedHook = requestEnqueuedHook
        self.platformMutation = mutation
    }

    @discardableResult
    func bind(to runLoop: CFRunLoop) -> Bool {
        let threadID = Self.currentThreadID()
        var context = CFRunLoopSourceContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil,
            equal: nil,
            hash: nil,
            schedule: nil,
            cancel: nil,
            perform: { info in
                guard let info else { return }
                Unmanaged<CursorMutationExecutor>.fromOpaque(info)
                    .takeUnretainedValue()
                    .drainPending()
            }
        )
        guard let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context) else {
            return false
        }

        let installed = pendingLock.withLock {
            guard ownerRunLoop == nil else { return false }
            ownerRunLoop = runLoop
            ownerThreadID = threadID
            self.source = source
            return true
        }
        guard installed else {
            CFRunLoopSourceInvalidate(source)
            return false
        }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        return true
    }

    /// Detaches the event-tap run loop and fails queued requests. The current
    /// platform mutation, if any, is never replaced with a caller-thread
    /// fallback.
    func unbind() {
        let (runLoop, source, queued) = pendingLock.withLock {
            let runLoop = ownerRunLoop
            let source = self.source
            ownerRunLoop = nil
            ownerThreadID = nil
            self.source = nil
            let queued = pending
            pending.removeAll()
            return (runLoop, source, queued)
        }
        queued.forEach { _ = $0.cancelIfPending() }
        if ownershipLock.lock(before: Date().addingTimeInterval(coordinationTimeout)) {
            activeGeneration = nil
            ownershipLock.unlock()
        } else {
            Diagnostics.log("cursor-mutation serialization timeout")
        }
        if let runLoop, let source {
            CFRunLoopSourceInvalidate(source)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
    }

    @discardableResult
    func beginOwnership(generation: UInt64) -> Bool {
        guard ownershipLock.lock(
            before: Date().addingTimeInterval(coordinationTimeout)
        ) else {
            Diagnostics.log("cursor-mutation serialization timeout")
            return false
        }
        defer { ownershipLock.unlock() }
        latestGeneration = generation
        activeGeneration = generation
        return true
    }

    /// Invalidates an ownership epoch before `InputCapture` releases local
    /// suppression. If an already-admitted platform call is in progress, the
    /// bounded wait lets it finish; the caller then fails safe without a
    /// caller-thread warp.
    @discardableResult
    func endOwnership(generation: UInt64) -> Bool {
        guard ownershipLock.lock(
            before: Date().addingTimeInterval(coordinationTimeout)
        ) else {
            Diagnostics.log("cursor-mutation serialization timeout")
            return false
        }
        defer { ownershipLock.unlock() }
        guard activeGeneration == generation else { return true }
        activeGeneration = nil
        return true
    }

    @discardableResult
    func perform(
        kind: Kind,
        generation: UInt64,
        point: CGPoint,
        precondition: @escaping @Sendable () -> Bool = { true }
    ) -> Bool {
        let request = Request(
            kind: kind,
            generation: generation,
            precondition: precondition,
            mutation: { [platformMutation] in
                platformMutation(kind, point)
            }
        )
        let isOwner = pendingLock.withLock {
            ownerThreadID == Self.currentThreadID()
        }
        if isOwner {
            request.run(on: self)
            return request.wait(timeout: 0) ?? false
        }

        guard let (runLoop, source) = enqueue(request) else {
            Diagnostics.log("cursor-mutation serialization timeout")
            return false
        }
        CFRunLoopSourceSignal(source)
        CFRunLoopWakeUp(runLoop)

        guard let result = request.wait(timeout: coordinationTimeout) else {
            _ = request.cancelIfPending()
            Diagnostics.log("cursor-mutation serialization timeout")
            return false
        }
        return result
    }

    /// Test-only visibility for proving that injected platform mutations run
    /// on the designated event-tap thread.
    var isOnOwningThreadForTesting: Bool {
        pendingLock.withLock { ownerThreadID == Self.currentThreadID() }
    }

    private func enqueue(_ request: Request) -> (CFRunLoop, CFRunLoopSource)? {
        guard pendingLock.lock(
            before: Date().addingTimeInterval(coordinationTimeout)
        ) else {
            return nil
        }
        guard let runLoop = ownerRunLoop, let source else {
            pendingLock.unlock()
            return nil
        }
        pending.append(request)
        pendingLock.unlock()
        requestEnqueuedHook?()
        return (runLoop, source)
    }

    private func drainPending() {
        while true {
            let request: Request? = pendingLock.withLock {
                guard !pending.isEmpty else { return nil }
                return pending.removeFirst()
            }
            guard let request else { return }
            request.run(on: self)
        }
    }

    private func commit(_ request: Request) -> Bool {
        request.beginCommit(using: self)
    }

    private func isCurrent(kind: Kind, generation: UInt64) -> Bool {
        switch kind {
        case .hold:
            return activeGeneration == generation
        case .restore:
            return activeGeneration == nil && latestGeneration == generation
        }
    }

    private static func currentThreadID() -> UInt32 {
        pthread_mach_thread_np(pthread_self())
    }
}
