import AppKit
import Darwin
import EdgeSwitch
import Foundation
import Diagnostics

protocol RemoteCursorPresenting: AnyObject, Sendable {
    @discardableResult
    func presentRemote(
        edge: ScreenEdge,
        onFailure: @escaping @Sendable () -> Void
    ) async -> Bool
    @discardableResult
    func restoreLocal() -> Bool
    func proveLocalRestored() -> Bool
}

protocol RemoteCursorHelperControlling: AnyObject, Sendable {
    @discardableResult
    func start(
        edge: ScreenEdge,
        point: NSPoint,
        onFailure: @escaping @Sendable () -> Void
    ) async -> Bool
    @discardableResult
    func stop() -> Bool
}

final class RemoteCursorHelperProcessController:
    RemoteCursorHelperControlling,
    @unchecked Sendable
{
    struct LaunchConfiguration: Sendable {
        let executableURL: URL
        let arguments: [String]

        static func production(
            edge: ScreenEdge,
            point: NSPoint
        ) -> LaunchConfiguration {
            LaunchConfiguration(
                executableURL: URL(
                    fileURLWithPath: CommandLine.arguments[0]
                ),
                arguments: [
                    RemoteCursorHelperMode.flag,
                    edge.rawValue,
                    String(Double(point.x)),
                    String(Double(point.y)),
                ]
            )
        }
    }

    private struct RunningHelper {
        let operationGeneration: UInt64
        let process: Process
        let controlWrite: FileHandle
        let onFailure: @Sendable () -> Void
        var admitted: Bool
    }

    private enum LaunchOutcome {
        case installed
        case staleBeforeLaunch
        case launchedButStale
        case failed(String)
    }

    private static let readyByte: UInt8 = 0xa5
    private static let readyTimeoutMilliseconds: Int32 = 1_000
    private static let gracefulExitTimeout: TimeInterval = 0.35

    private let lock = NSLock()
    /// Serializes the tiny Process.run()/registration window against stop().
    /// Readiness waiting is deliberately outside this lock.
    private let launchLock = NSLock()
    private var operationGeneration: UInt64 = 0
    private var helper: RunningHelper?
    private let launchConfigurationOverride: LaunchConfiguration?

    init(
        launchConfiguration: LaunchConfiguration? = nil
    ) {
        launchConfigurationOverride = launchConfiguration
    }

    @discardableResult
    func start(
        edge: ScreenEdge,
        point: NSPoint,
        onFailure: @escaping @Sendable () -> Void
    ) async -> Bool {
        _ = stop()

        let operation = lock.withLock { () -> UInt64 in
            operationGeneration &+= 1
            if operationGeneration == 0 {
                operationGeneration = 1
            }
            return operationGeneration
        }

        let child = Process()
        let control = Pipe()
        let readiness = Pipe()
        let launch = launchConfigurationOverride
            ?? .production(edge: edge, point: point)
        child.executableURL = launch.executableURL
        child.arguments = launch.arguments
        child.standardInput = control.fileHandleForReading
        child.standardOutput = readiness.fileHandleForWriting
        child.standardError = FileHandle.nullDevice

        child.terminationHandler = { [weak self] process in
            self?.handleUnexpectedExit(process)
        }

        // stop() takes the same launch lock. The generation check,
        // Process.run(), and pending-slot publication form one synchronous
        // critical section. Swift concurrency forbids manual lock/unlock in
        // async functions, so scoped locking is also the mechanically safer
        // representation of this non-suspending boundary.
        let launchOutcome: LaunchOutcome = launchLock.withLock {
            let launchStillCurrent = lock.withLock {
                operationGeneration == operation && helper == nil
            }
            guard launchStillCurrent else {
                return .staleBeforeLaunch
            }

            do {
                try child.run()
            } catch {
                return .failed(error.localizedDescription)
            }

            // The parent owns only stdin-write and stdout-read. Parent death
            // closes the control write end automatically.
            try? control.fileHandleForReading.close()
            try? readiness.fileHandleForWriting.close()

            let installed = lock.withLock { () -> Bool in
                guard operationGeneration == operation,
                      helper == nil else {
                    return false
                }
                helper = RunningHelper(
                    operationGeneration: operation,
                    process: child,
                    controlWrite: control.fileHandleForWriting,
                    onFailure: onFailure,
                    admitted: false
                )
                return true
            }
            return installed ? .installed : .launchedButStale
        }

        switch launchOutcome {
        case .installed:
            break
        case .staleBeforeLaunch:
            closePipe(control)
            closePipe(readiness)
            return false
        case .launchedButStale:
            terminate(
                process: child,
                controlWrite: control.fileHandleForWriting,
                context: "stale-launch"
            )
            try? readiness.fileHandleForReading.close()
            return false
        case .failed(let reason):
            closePipe(control)
            closePipe(readiness)
            Diagnostics.log(
                "host cursor helper launch failed reason=\(reason)"
            )
            return false
        }

        let pid = child.processIdentifier
        Diagnostics.log(
            "host cursor helper launched pid=\(pid) edge=\(edge.rawValue)"
        )

        let ready = await Self.awaitReady(
            descriptor: readiness.fileHandleForReading.fileDescriptor,
            timeoutMilliseconds: Self.readyTimeoutMilliseconds
        )
        try? readiness.fileHandleForReading.close()

        guard ready, child.isRunning else {
            let failed = takeHelper(
                operationGeneration: operation,
                process: child
            )
            if let failed {
                terminate(
                    process: failed.process,
                    controlWrite: failed.controlWrite,
                    context: "admission-failed"
                )
            } else if child.isRunning {
                _ = Darwin.kill(pid, SIGKILL)
                child.waitUntilExit()
            }
            Diagnostics.log(
                "host cursor helper admission failed pid=\(pid) "
                    + "ready=\(ready) status=\(child.terminationStatus)"
            )
            return false
        }

        let admitted = lock.withLock { () -> Bool in
            guard operationGeneration == operation,
                  var current = helper,
                  current.operationGeneration == operation,
                  current.process === child else {
                return false
            }
            current.admitted = true
            helper = current
            return true
        }

        guard admitted, child.isRunning else {
            let failed = takeHelper(
                operationGeneration: operation,
                process: child
            )
            if let failed {
                terminate(
                    process: failed.process,
                    controlWrite: failed.controlWrite,
                    context: "stale-after-ready"
                )
            }
            Diagnostics.log(
                "host cursor helper admission failed pid=\(pid) "
                    + "reason=stale-or-exited-after-ready"
            )
            return false
        }

        Diagnostics.log(
            "host cursor helper ready-confirmed pid=\(pid) edge=\(edge.rawValue)"
        )
        return true
    }

    @discardableResult
    func stop() -> Bool {
        let running = launchLock.withLock {
            lock.withLock { () -> RunningHelper? in
                operationGeneration &+= 1
                if operationGeneration == 0 {
                    operationGeneration = 1
                }
                let running = helper
                helper = nil
                return running
            }
        }

        guard let running else { return true }
        return terminate(
            process: running.process,
            controlWrite: running.controlWrite,
            context: "return"
        )
    }

    deinit {
        _ = stop()
    }

    private func handleUnexpectedExit(_ process: Process) {
        let failure = lock.withLock { () -> (@Sendable () -> Void)? in
            guard let current = helper,
                  current.process === process else {
                return nil
            }
            helper = nil
            try? current.controlWrite.close()
            return current.admitted ? current.onFailure : nil
        }

        guard let failure else { return }
        Diagnostics.log(
            "host cursor helper unexpected-exit pid=\(process.processIdentifier) "
                + "status=\(process.terminationStatus)"
        )
        failure()
    }

    private func takeHelper(
        operationGeneration: UInt64,
        process: Process
    ) -> RunningHelper? {
        lock.withLock {
            guard let current = helper,
                  current.operationGeneration == operationGeneration,
                  current.process === process else {
                return nil
            }
            helper = nil
            return current
        }
    }

    @discardableResult
    private func terminate(
        process: Process,
        controlWrite: FileHandle,
        context: String
    ) -> Bool {
        let pid = process.processIdentifier

        // Closing stdin is the normal-return signal. Give the child a bounded
        // window to restore the pre-remote system cursor and exit cleanly.
        // SIGKILL remains only a containment fallback for a wedged child.
        try? controlWrite.close()

        let deadline = Date().addingTimeInterval(
            Self.gracefulExitTimeout
        )
        while process.isRunning, Date() < deadline {
            usleep(5_000)
        }

        var forced = false
        if process.isRunning {
            forced = true
            let result = Darwin.kill(pid, SIGKILL)
            Diagnostics.log(
                "host cursor helper kill pid=\(pid) "
                    + "context=\(context) result=\(result)"
            )
        }

        process.waitUntilExit()
        let status = process.terminationStatus
        Diagnostics.log(
            "host cursor helper exited pid=\(pid) "
                + "context=\(context) forced=\(forced) "
                + "status=\(status)"
        )
        let cleanupSucceeded = !forced && status == 0
        if context == "return" {
            Diagnostics.log(
                "host cursor helper return cleanup pid=\(pid) "
                    + "graceful=\(!forced) cleanupSucceeded=\(cleanupSucceeded)"
            )
        }
        return cleanupSucceeded
    }

    private static func awaitReady(
        descriptor: Int32,
        timeoutMilliseconds: Int32
    ) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let pollResult = withUnsafeMutablePointer(
                to: &pollDescriptor
            ) {
                Darwin.poll($0, 1, timeoutMilliseconds)
            }
            guard pollResult > 0,
                  pollDescriptor.revents & Int16(POLLIN) != 0 else {
                return false
            }

            var byte: UInt8 = 0
            let count = withUnsafeMutablePointer(to: &byte) {
                Darwin.read(descriptor, $0, 1)
            }
            return count == 1 && byte == readyByte
        }.value
    }

    private func closePipe(_ pipe: Pipe) {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}

enum RemoteCursorHelperMode {
    static let flag = "--crossinput-cursor-helper"
    static let readyByte: UInt8 = 0xa5

    @MainActor
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 5, arguments[1] == flag else {
            return
        }

        guard let edge = ScreenEdge(rawValue: arguments[2]),
              let x = Double(arguments[3]),
              let y = Double(arguments[4]) else {
            Darwin._exit(64)
        }

        let point = NSPoint(x: x, y: y)
        let returnCoordinator = RemoteCursorHelperReturnCoordinator()

        // stdin is a parent-lifetime lease. EOF requests cleanup rather than
        // terminating immediately: WindowServer can retain the last cursor
        // selected by a dead background client, so local cursor restoration is
        // part of the helper's release contract.
        FileHandle.standardInput.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                returnCoordinator.requestReturn()
            }
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        let preRemoteCursor = NativeRemoteCursorPresenter.snapshot(
            NSCursor.currentSystem ?? .arrow
        )

        if returnCoordinator.isReturnRequested {
            Darwin._exit(0)
        }

        let authority = HelperBackgroundCursorAuthority()
        guard authority.enable() else {
            Diagnostics.log(
                "host cursor helper failed reason=background-authority"
            )
            Diagnostics.flushSync()
            Darwin._exit(70)
        }

        let cursor = NativeRemoteCursorPresenter.cursor(for: edge)
        guard let screen = NativeRemoteCursorPresenter.screen(
            containing: point
        ) else {
            Diagnostics.log("host cursor helper failed reason=no-screen")
            Diagnostics.flushSync()
            Darwin._exit(71)
        }

        let frame = NativeRemoteCursorPresenter.presentationFrame(
            around: point,
            in: screen.frame
        )
        let view = RemoteCursorRectView(cursor: cursor)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.contentView = view

        let runtime = RemoteCursorHelperRuntime(
            authority: authority,
            panel: panel,
            preRemoteCursor: preRemoteCursor
        )
        if returnCoordinator.installReturnHandler({
            Task { @MainActor in
                runtime.restoreAndExit()
            }
        }) {
            runtime.restoreAndExit()
        }

        // Install cleanup ownership before the panel is made visible: once
        // cursor rects can affect WindowServer, every exit path must restore.
        panel.orderFrontRegardless()

        // CoreHID has frozen the host pointer, so no later local mouse movement
        // can be relied on to publish a fresh cursor rect. Rebuild and assert
        // the native cursor here, then require the system-visible cursor oracle
        // to agree before this helper is admitted as ready.
        var systemMatch = false
        for _ in 0..<25 {
            panel.resetCursorRects()
            cursor.set()
            if let currentSystem = NSCursor.currentSystem,
               NativeRemoteCursorPresenter.cursorAppearanceMatches(
                   currentSystem,
                   cursor
               ) {
                systemMatch = true
                break
            }
            RunLoop.main.run(
                mode: .default,
                before: Date().addingTimeInterval(0.02)
            )
        }

        if !systemMatch {
            Diagnostics.log(
                "host cursor helper failed reason=system-cursor-mismatch "
                    + "edge=\(edge.rawValue)"
            )
            Diagnostics.flushSync()
            runtime.restoreAndExit(requestedStatus: 72)
            return
        }

        let maintenance = RemoteCursorMaintenanceOwner(
            panel: panel,
            cursor: cursor,
            onPersistentFailure: { [weak runtime] in
                runtime?.restoreAndExit(requestedStatus: 74)
            }
        )
        let timer = Timer(
            timeInterval: 0.10,
            target: maintenance,
            selector: #selector(RemoteCursorMaintenanceOwner.tick),
            userInfo: nil,
            repeats: true
        )
        runtime.installMaintenanceTimer(timer)
        RunLoop.main.add(timer, forMode: .common)

        Diagnostics.log(
            "host cursor helper ready pid=\(getpid()) "
                + "edge=\(edge.rawValue) systemMatch=true"
        )
        Diagnostics.flushSync()

        do {
            try FileHandle.standardOutput.write(
                contentsOf: Data([readyByte])
            )
        } catch {
            runtime.restoreAndExit(requestedStatus: 73)
            return
        }

        NSApplication.shared.run()
        Darwin._exit(0)
    }
}

private final class RemoteCursorHelperReturnCoordinator:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var returnRequested = false
    private var returnHandler: (@Sendable () -> Void)?

    var isReturnRequested: Bool {
        lock.withLock { returnRequested }
    }

    /// Returns true when EOF won before the runtime handler was installed.
    func installReturnHandler(
        _ handler: @escaping @Sendable () -> Void
    ) -> Bool {
        lock.withLock {
            if returnRequested {
                return true
            }
            returnHandler = handler
            return false
        }
    }

    func requestReturn() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            returnRequested = true
            return returnHandler
        }
        handler?()
    }
}

@MainActor
private final class RemoteCursorHelperRuntime {
    private let authority: HelperBackgroundCursorAuthority
    private let panel: NSPanel
    private let preRemoteCursor: NSCursor
    private var maintenanceTimer: Timer?
    private var restoring = false

    init(
        authority: HelperBackgroundCursorAuthority,
        panel: NSPanel,
        preRemoteCursor: NSCursor
    ) {
        self.authority = authority
        self.panel = panel
        self.preRemoteCursor = preRemoteCursor
    }

    func installMaintenanceTimer(_ timer: Timer) {
        maintenanceTimer = timer
    }

    func restoreAndExit(requestedStatus: Int32 = 0) {
        guard !restoring else { return }
        restoring = true

        FileHandle.standardInput.readabilityHandler = nil
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil

        panel.contentView?.discardCursorRects()
        panel.orderOut(nil)
        panel.contentView = nil

        // Issue the restore while this disposable child still owns the
        // background-cursor authority, but do not treat this pre-CoreHID
        // observation as the final visible-cursor oracle. The physical pointer
        // is deliberately still seized at this point.
        var prePhysicalSystemMatch = false
        for _ in 0..<12 {
            preRemoteCursor.set()
            if let current = NSCursor.currentSystem,
               NativeRemoteCursorPresenter.cursorAppearanceMatches(
                   current,
                   preRemoteCursor
               ) {
                prePhysicalSystemMatch = true
                break
            }
            RunLoop.main.run(
                mode: .default,
                before: Date().addingTimeInterval(0.005)
            )
        }

        // Cleanup proof belongs to the helper: cursor rect ownership is gone
        // and its private background authority must be disabled before exit.
        // The parent separately proves the actual pre-remote appearance after
        // CoreHID physical release, when WindowServer can converge normally.
        let authorityDisabled = authority.disable()
        RunLoop.main.run(
            mode: .default,
            before: Date().addingTimeInterval(0.005)
        )
        let postAuthoritySystemMatch =
            NSCursor.currentSystem.map {
                NativeRemoteCursorPresenter.cursorAppearanceMatches(
                    $0,
                    preRemoteCursor
                )
            } ?? false
        Diagnostics.log(
            "host cursor helper restore "
                + "prePhysicalSystemMatch=\(prePhysicalSystemMatch) "
                + "postAuthoritySystemMatch=\(postAuthoritySystemMatch) "
                + "backgroundAuthorityDisabled=\(authorityDisabled)"
        )
        Diagnostics.flushSync()

        let finalStatus: Int32
        if requestedStatus != 0 {
            finalStatus = requestedStatus
        } else {
            // Status 75 now means helper cleanup itself was not proven. A
            // merely delayed NSCursor.currentSystem convergence is adjudicated
            // by the parent after CoreHID release instead of becoming a false
            // helper failure.
            finalStatus = authorityDisabled ? 0 : 75
        }
        Darwin._exit(finalStatus)
    }
}

/// Presentation-only background cursor authority.
///
/// CoreHID owns confinement and semantic input. This SPI is isolated in a
/// disposable child and never participates in host-pointer ownership/release.
/// Process death is therefore the cleanup boundary for this WindowServer
/// connection, preventing cursor presentation state from contaminating the
/// long-lived Ampersand process.
private final class HelperBackgroundCursorAuthority {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SetConnectionPropertyFn = @convention(c) (
        Int32, Int32, CFString, CFTypeRef
    ) -> Int32

    private let handle: UnsafeMutableRawPointer?
    private let connection: ConnectionFn?
    private let setter: SetConnectionPropertyFn?

    init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        )
        self.handle = handle

        if let handle,
           let symbol = dlsym(handle, "_CGSDefaultConnection") {
            connection = unsafeBitCast(symbol, to: ConnectionFn.self)
        } else {
            connection = nil
        }

        if let handle,
           let symbol = dlsym(handle, "CGSSetConnectionProperty") {
            setter = unsafeBitCast(symbol, to: SetConnectionPropertyFn.self)
        } else {
            setter = nil
        }
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }

    func enable() -> Bool {
        setEnabled(true)
    }

    func disable() -> Bool {
        setEnabled(false)
    }

    private func setEnabled(_ enabled: Bool) -> Bool {
        guard let connection, let setter else { return false }
        let cid = connection()
        return setter(
            cid,
            cid,
            "SetsCursorInBackground" as CFString,
            enabled ? kCFBooleanTrue : kCFBooleanFalse
        ) == 0
    }
}

struct RemoteCursorPresentationHealth: Equatable, Sendable {
    let mismatchLimit: Int
    private(set) var consecutiveMismatches = 0

    init(mismatchLimit: Int = 3) {
        precondition(mismatchLimit > 0)
        self.mismatchLimit = mismatchLimit
    }

    /// Returns whether the presentation remains admissible. A transient
    /// mismatch may be repaired by the helper, but a bounded run of observed
    /// system-cursor mismatches terminates the presentation epoch fail-closed.
    mutating func observe(matches: Bool) -> Bool {
        if matches {
            consecutiveMismatches = 0
            return true
        }
        consecutiveMismatches += 1
        return consecutiveMismatches < mismatchLimit
    }
}

@MainActor
private final class RemoteCursorMaintenanceOwner: NSObject {
    private let panel: NSPanel
    private let cursor: NSCursor
    private let onPersistentFailure: @MainActor () -> Void
    private var lastMatch = true
    private var health = RemoteCursorPresentationHealth()

    init(
        panel: NSPanel,
        cursor: NSCursor,
        onPersistentFailure: @escaping @MainActor () -> Void
    ) {
        self.panel = panel
        self.cursor = cursor
        self.onPersistentFailure = onPersistentFailure
    }

    @objc
    func tick() {
        panel.resetCursorRects()

        var matches = systemCursorMatchesExpected()
        if !matches {
            // The helper owns the only admitted background cursor authority.
            // Reassert locally, then validate the *actual system cursor* again
            // rather than assuming NSCursor.set() succeeded.
            cursor.set()
            panel.resetCursorRects()
            matches = systemCursorMatchesExpected()
        }

        if matches != lastMatch {
            lastMatch = matches
            Diagnostics.log(
                "host cursor helper system-match changed value=\(matches)"
            )
        }

        guard health.observe(matches: matches) else {
            Diagnostics.log(
                "host cursor helper failed reason=persistent-system-cursor-mismatch "
                    + "count=\(health.consecutiveMismatches)"
            )
            Diagnostics.flushSync()
            onPersistentFailure()
            return
        }
    }

    private func systemCursorMatchesExpected() -> Bool {
        guard let currentSystem = NSCursor.currentSystem else {
            return false
        }
        return NativeRemoteCursorPresenter.cursorAppearanceMatches(
            currentSystem,
            cursor
        )
    }
}

private final class RemoteCursorRectView: NSView {
    let remoteCursor: NSCursor

    init(cursor: NSCursor) {
        self.remoteCursor = cursor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: remoteCursor)
    }
}

final class NativeRemoteCursorPresenter: RemoteCursorPresenting,
    @unchecked Sendable
{
    private struct CursorAppearanceSnapshot: Equatable, Sendable {
        let hotSpotX: Double
        let hotSpotY: Double
        let imageTIFF: Data?
    }

    private let controller: RemoteCursorHelperControlling
    private let appearanceLock = NSLock()
    private var preRemoteAppearance: CursorAppearanceSnapshot?

    init(
        controller: RemoteCursorHelperControlling =
            RemoteCursorHelperProcessController()
    ) {
        self.controller = controller
    }

    @discardableResult
    func presentRemote(
        edge: ScreenEdge,
        onFailure: @escaping @Sendable () -> Void
    ) async -> Bool {
        // Keep a parent-side appearance proof independent of the disposable
        // helper. The child can request/clean up restoration while CoreHID is
        // still seized; this snapshot is checked only after physical release.
        let localAppearance = Self.capturePreRemoteAppearance()
        appearanceLock.withLock {
            preRemoteAppearance = localAppearance
        }

        let point = NSEvent.mouseLocation
        let ready = await controller.start(
            edge: edge,
            point: point,
            onFailure: onFailure
        )
        Diagnostics.log(
            "host cursor presentation remote mode=isolated-background-helper "
                + "edge=\(edge.rawValue) ready=\(ready)"
        )
        return ready
    }

    @discardableResult
    func restoreLocal() -> Bool {
        let cleanupSucceeded = controller.stop()
        Diagnostics.log(
            "host cursor presentation local mode=isolated-background-helper "
                + "stopped=true cleanupSucceeded=\(cleanupSucceeded)"
        )
        return cleanupSucceeded
    }

    func proveLocalRestored() -> Bool {
        guard let expected = appearanceLock.withLock({
            preRemoteAppearance
        }) else {
            return true
        }

        var restored = false
        for _ in 0..<20 {
            if Self.currentSystemAppearance() == expected {
                restored = true
                break
            }
            usleep(5_000)
        }

        if restored {
            appearanceLock.withLock {
                if preRemoteAppearance == expected {
                    preRemoteAppearance = nil
                }
            }
        }
        Diagnostics.log(
            "host cursor parent restore proof restored=\(restored) "
                + "phase=post-corehid-release"
        )
        return restored
    }

    private static func capturePreRemoteAppearance()
        -> CursorAppearanceSnapshot {
        let capture = {
            appearanceSnapshot(NSCursor.currentSystem ?? .arrow)
        }
        if Thread.isMainThread {
            return capture()
        }
        return DispatchQueue.main.sync(execute: capture)
    }

    private static func currentSystemAppearance()
        -> CursorAppearanceSnapshot? {
        let capture = {
            NSCursor.currentSystem.map(appearanceSnapshot)
        }
        if Thread.isMainThread {
            return capture()
        }
        return DispatchQueue.main.sync(execute: capture)
    }

    private static func appearanceSnapshot(
        _ cursor: NSCursor
    ) -> CursorAppearanceSnapshot {
        CursorAppearanceSnapshot(
            hotSpotX: Double(cursor.hotSpot.x),
            hotSpotY: Double(cursor.hotSpot.y),
            imageTIFF: cursor.image.tiffRepresentation
        )
    }

    static func snapshot(_ cursor: NSCursor) -> NSCursor {
        NSCursor(
            image: cursor.image.copy() as? NSImage ?? cursor.image,
            hotSpot: cursor.hotSpot
        )
    }

    static func cursor(for edge: ScreenEdge) -> NSCursor {
        switch edge {
        case .left:
            return .columnResize(directions: .right)
        case .right:
            return .columnResize(directions: .left)
        case .top:
            return .rowResize(directions: .down)
        case .bottom:
            return .rowResize(directions: .up)
        }
    }

    static func cursorAppearanceMatches(
        _ lhs: NSCursor,
        _ rhs: NSCursor
    ) -> Bool {
        lhs.hotSpot == rhs.hotSpot
            && lhs.image.tiffRepresentation == rhs.image.tiffRepresentation
    }

    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first {
            NSMouseInRect(point, $0.frame, false)
        } ?? NSScreen.main
    }

    static func presentationFrame(
        around point: NSPoint,
        in screenFrame: NSRect
    ) -> NSRect {
        let side: CGFloat = 48
        let half = side / 2

        let minX = screenFrame.minX
        let maxX = max(minX, screenFrame.maxX - side)
        let minY = screenFrame.minY
        let maxY = max(minY, screenFrame.maxY - side)

        let x = min(max(point.x - half, minX), maxX)
        let y = min(max(point.y - half, minY), maxY)
        return NSRect(x: x, y: y, width: side, height: side)
    }
}
