import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation

enum ReproStage: Int, CaseIterable, Sendable {
    case a = 0
    case b
    case c
    case d
    case e
    case f
    case g

    var letter: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        case .d: return "D"
        case .e: return "E"
        case .f: return "F"
        case .g: return "G"
        }
    }

    var description: String {
        switch self {
        case .a:
            return "Pure AppKit probe only. No CoreGraphics event tap and no pointer mutation."
        case .b:
            return "Stage A + passive listen-only CoreGraphics mouse event tap."
        case .c:
            return "Stage B + active event tap; a bounded lease consumes mouse-move/drag events without warping."
        case .d:
            return "Stage C + one CGWarpMouseCursorPosition to the selected display edge at lease start."
        case .e:
            return "Stage D + repeated edge hold warp for each consumed movement during the bounded lease."
        case .f:
            return "Stage E + an explicit restore warp to the edge when the bounded lease ends."
        case .g:
            return "Stage F + one synthetic mouseMoved posted after the restore warp."
        }
    }

    var requiresEventTap: Bool { self != .a }
    var requiresAction: Bool { rawValue >= ReproStage.c.rawValue }
    var usesActiveEventTap: Bool { rawValue >= ReproStage.c.rawValue }
    var warpsAtLeaseStart: Bool { rawValue >= ReproStage.d.rawValue }
    var repeatsHoldWarp: Bool { rawValue >= ReproStage.e.rawValue }
    var restoresAtLeaseEnd: Bool { rawValue >= ReproStage.f.rawValue }
    var postsSyntheticMove: Bool { self == .g }

    static func parse(_ value: String) -> ReproStage? {
        switch value.uppercased() {
        case "A": return .a
        case "B": return .b
        case "C": return .c
        case "D": return .d
        case "E": return .e
        case "F": return .f
        case "G": return .g
        default: return nil
        }
    }
}

enum ReproEdge: String, CaseIterable, Sendable {
    case left, right, top, bottom
}

struct ReproOptions: Sendable {
    let stage: ReproStage
    let edge: ReproEdge
    let leaseMilliseconds: Int

    var leaseSeconds: TimeInterval { TimeInterval(leaseMilliseconds) / 1_000 }

    static func parse(arguments: [String]) throws -> ReproOptions {
        var stage: ReproStage = .a
        var edge: ReproEdge = .right
        var leaseMilliseconds = 1_500
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--stage":
                index += 1
                guard index < arguments.count,
                      let parsed = ReproStage.parse(arguments[index]) else {
                    throw ReproArgumentError.invalid("--stage requires A, B, C, D, E, F, or G")
                }
                stage = parsed
            case "--edge":
                index += 1
                guard index < arguments.count,
                      let parsed = ReproEdge(rawValue: arguments[index].lowercased()) else {
                    throw ReproArgumentError.invalid("--edge requires left, right, top, or bottom")
                }
                edge = parsed
            case "--lease-ms":
                index += 1
                guard index < arguments.count,
                      let parsed = Int(arguments[index]),
                      (250...5_000).contains(parsed) else {
                    throw ReproArgumentError.invalid("--lease-ms must be between 250 and 5000")
                }
                leaseMilliseconds = parsed
            case "--help", "-h":
                throw ReproArgumentError.help
            default:
                throw ReproArgumentError.invalid("unknown argument: \(argument)")
            }
            index += 1
        }

        return ReproOptions(stage: stage, edge: edge, leaseMilliseconds: leaseMilliseconds)
    }

    static let usage = """
    Usage:
      cursor-presentation-repro --stage A|B|C|D|E|F|G [--edge left|right|top|bottom] [--lease-ms 1500]

    Safety:
      - A/B never mutate pointer position.
      - C consumes movement only during a bounded lease.
      - D-G may visibly warp the pointer as part of the diagnostic action.
      - C-G auto-release after the lease and also release immediately on Shift-Command-X.
      - No stage synthesizes mouse clicks.
    """
}

enum ReproArgumentError: Error {
    case help
    case invalid(String)
}

final class ReproLogger: @unchecked Sendable {
    private let lock = NSLock()
    private let fileHandle: FileHandle?
    let logPath: String

    init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Ampersand", isDirectory: true)
        let url = directory.appendingPathComponent("cursor-presentation-repro.log")
        logPath = url.path

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            fileHandle = handle
        } catch {
            fileHandle = nil
        }
    }

    deinit {
        try? fileHandle?.close()
    }

    func log(_ event: String, stage: ReproStage, fields: [String: String] = [:]) {
        let monotonic = DispatchTime.now().uptimeNanoseconds
        let stableFields = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.token($0.value))" }
            .joined(separator: " ")
        let suffix = stableFields.isEmpty ? "" : " " + stableFields
        let line = "REPRO monotonic_ns=\(monotonic) stage=\(stage.letter) event=\(event)\(suffix)\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        FileHandle.standardOutput.write(data)
        fileHandle?.write(data)
        lock.unlock()
    }

    private static func token(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\t", with: "_")
    }
}

struct ReproDisplay {
    static func displayID(at point: CGPoint) -> CGDirectDisplayID? {
        var displayID = CGDirectDisplayID()
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &displayID, &count) == .success,
              count == 1 else {
            return nil
        }
        return displayID
    }

    static func screenID(_ screen: NSScreen?) -> String {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber else {
            return "none"
        }
        return number.stringValue
    }

    static func anchor(for edge: ReproEdge, frame: CGRect, current: CGPoint) -> CGPoint {
        let inset: CGFloat = 2
        let safeX = min(max(current.x, frame.minX + inset), frame.maxX - inset)
        let safeY = min(max(current.y, frame.minY + inset), frame.maxY - inset)
        switch edge {
        case .left:
            return CGPoint(x: frame.minX + inset, y: safeY)
        case .right:
            return CGPoint(x: frame.maxX - inset, y: safeY)
        case .top:
            return CGPoint(x: safeX, y: frame.minY + inset)
        case .bottom:
            return CGPoint(x: safeX, y: frame.maxY - inset)
        }
    }
}

private struct ReproLease: Sendable {
    let generation: UInt64
    let displayID: CGDirectDisplayID
    let anchor: CGPoint
}

enum ReproLeaseStartResult {
    case started(generation: UInt64, displayID: CGDirectDisplayID)
    case rejected(String)
}

final class ReproEventHarness: @unchecked Sendable {
    private let options: ReproOptions
    private let logger: ReproLogger
    private let lock = NSLock()
    private let tapQueue = DispatchQueue(label: "crossinput.issue96.repro.tap", qos: .userInteractive)
    private let timerQueue = DispatchQueue(label: "crossinput.issue96.repro.timer", qos: .userInteractive)

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var lease: ReproLease?
    private var generation: UInt64 = 0
    private var lastObservedDisplayID: CGDirectDisplayID?
    private var tapReady = false

    init(options: ReproOptions, logger: ReproLogger) {
        self.options = options
        self.logger = logger
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return options.stage == .a || tapReady
    }

    func start() -> Bool {
        guard options.stage.requiresEventTap else {
            logger.log("event-tap-not-required", stage: options.stage)
            return true
        }

        let eventTapOptions: CGEventTapOptions = options.stage.usesActiveEventTap
            ? .defaultTap
            : .listenOnly
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let harness = Unmanaged<ReproEventHarness>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            return harness.handle(type: type, event: event)
        }

        guard let createdTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: eventTapOptions,
            eventsOfInterest: Self.eventMask(for: options.stage),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.log(
                "event-tap-unavailable",
                stage: options.stage,
                fields: [
                    "mode": options.stage.usesActiveEventTap ? "active" : "listen-only",
                    "accessibility_trusted": AXIsProcessTrusted() ? "true" : "false"
                ]
            )
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0)
        tap = createdTap
        runLoopSource = source

        let ready = DispatchSemaphore(value: 0)
        tapQueue.async { [weak self] in
            guard let self,
                  let source = self.runLoopSource,
                  let tap = self.tap,
                  let currentRunLoop = CFRunLoopGetCurrent() else {
                ready.signal()
                return
            }

            self.lock.lock()
            self.runLoop = currentRunLoop
            self.tapReady = true
            self.lock.unlock()

            CFRunLoopAddSource(currentRunLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.logger.log(
                "event-tap-installed",
                stage: self.options.stage,
                fields: ["mode": self.options.stage.usesActiveEventTap ? "active" : "listen-only"]
            )
            ready.signal()
            CFRunLoopRun()
        }

        guard ready.wait(timeout: .now() + 2) == .success else {
            logger.log("event-tap-start-timeout", stage: options.stage)
            stop()
            return false
        }
        return isReady
    }

    func stop() {
        finishLease(expectedGeneration: nil, reason: "harness-stop")

        lock.lock()
        let existingTap = tap
        let existingSource = runLoopSource
        let existingRunLoop = runLoop
        tap = nil
        runLoopSource = nil
        runLoop = nil
        tapReady = false
        lock.unlock()

        if let existingTap {
            CFMachPortInvalidate(existingTap)
        }
        if let existingSource, let existingRunLoop {
            CFRunLoopRemoveSource(existingRunLoop, existingSource, .commonModes)
            CFRunLoopStop(existingRunLoop)
        }
        logger.log("event-harness-stopped", stage: options.stage)
    }

    func beginLease() -> ReproLeaseStartResult {
        guard options.stage.requiresAction else {
            return .rejected("stage has no invasive action")
        }
        guard isReady else {
            return .rejected("event tap is unavailable")
        }
        guard let pointerEvent = CGEvent(source: nil),
              let displayID = ReproDisplay.displayID(at: pointerEvent.location) else {
            return .rejected("current pointer display could not be resolved")
        }

        let frame = CGDisplayBounds(displayID)
        guard !frame.isEmpty else {
            return .rejected("current pointer display has empty bounds")
        }
        let anchor = ReproDisplay.anchor(
            for: options.edge,
            frame: frame,
            current: pointerEvent.location
        )

        lock.lock()
        guard lease == nil else {
            lock.unlock()
            return .rejected("a lease is already active")
        }
        generation &+= 1
        let currentGeneration = generation
        lease = ReproLease(
            generation: currentGeneration,
            displayID: displayID,
            anchor: anchor
        )
        lock.unlock()

        logger.log(
            "lease-started",
            stage: options.stage,
            fields: [
                "generation": String(currentGeneration),
                "display": String(displayID),
                "edge": options.edge.rawValue,
                "lease_ms": String(options.leaseMilliseconds)
            ]
        )

        if options.stage.warpsAtLeaseStart {
            let result = CGWarpMouseCursorPosition(anchor)
            logger.log(
                "warp-start",
                stage: options.stage,
                fields: [
                    "generation": String(currentGeneration),
                    "result": String(result.rawValue)
                ]
            )
        }

        timerQueue.asyncAfter(deadline: .now() + options.leaseSeconds) { [weak self] in
            self?.finishLease(expectedGeneration: currentGeneration, reason: "timeout")
        }
        return .started(generation: currentGeneration, displayID: displayID)
    }

    func releaseLease(reason: String) {
        finishLease(expectedGeneration: nil, reason: reason)
    }

    private func finishLease(expectedGeneration: UInt64?, reason: String) {
        lock.lock()
        guard let currentLease = lease,
              expectedGeneration == nil || expectedGeneration == currentLease.generation else {
            lock.unlock()
            return
        }
        lease = nil
        lock.unlock()

        if options.stage.restoresAtLeaseEnd {
            let result = CGWarpMouseCursorPosition(currentLease.anchor)
            logger.log(
                "warp-restore",
                stage: options.stage,
                fields: [
                    "generation": String(currentLease.generation),
                    "result": String(result.rawValue)
                ]
            )
        }

        if options.stage.postsSyntheticMove {
            postSyntheticMove(at: currentLease.anchor, generation: currentLease.generation)
        }

        logger.log(
            "lease-ended",
            stage: options.stage,
            fields: [
                "generation": String(currentLease.generation),
                "reason": reason
            ]
        )
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            logger.log("event-tap-reenabled", stage: options.stage)
            return Unmanaged.passUnretained(event)
        case .keyDown:
            if Self.isEmergencyReturn(event) {
                finishLease(expectedGeneration: nil, reason: "emergency-hotkey")
                logger.log("emergency-hotkey", stage: options.stage)
            }
            return Unmanaged.passUnretained(event)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            recordDisplayTransition(for: event.location)
        default:
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let currentLease = lease
        lock.unlock()
        guard let currentLease else {
            return Unmanaged.passUnretained(event)
        }

        if options.stage.repeatsHoldWarp {
            _ = CGWarpMouseCursorPosition(currentLease.anchor)
        }
        return nil
    }

    private func recordDisplayTransition(for point: CGPoint) {
        guard let displayID = ReproDisplay.displayID(at: point) else { return }
        lock.lock()
        let changed = lastObservedDisplayID != displayID
        if changed {
            lastObservedDisplayID = displayID
        }
        lock.unlock()
        if changed {
            logger.log(
                "pointer-display-changed",
                stage: options.stage,
                fields: ["display": String(displayID)]
            )
        }
    }

    private func postSyntheticMove(at point: CGPoint, generation: UInt64) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left
              ) else {
            logger.log(
                "synthetic-move-create-failed",
                stage: options.stage,
                fields: ["generation": String(generation)]
            )
            return
        }
        event.post(tap: .cghidEventTap)
        logger.log(
            "synthetic-move-posted",
            stage: options.stage,
            fields: ["generation": String(generation)]
        )
    }

    private static func eventMask(for stage: ReproStage) -> CGEventMask {
        var mask: CGEventMask = 0
        var types: [CGEventType] = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]
        if stage.usesActiveEventTap {
            types.append(.keyDown)
        }
        for type in types {
            mask |= CGEventMask(1 << type.rawValue)
        }
        return mask
    }

    private static func isEmergencyReturn(_ event: CGEvent) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == UInt16(kVK_ANSI_X) else { return false }
        let relevant = event.flags.intersection([
            .maskCommand,
            .maskShift,
            .maskControl,
            .maskAlternate
        ])
        return relevant == [.maskCommand, .maskShift]
    }
}

@MainActor
private enum ReproWindowMetadata {
    static func fields(window: NSWindow?) -> [String: String] {
        [
            "app_active": NSApp.isActive ? "true" : "false",
            "frontmost_bundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none",
            "window_display": ReproDisplay.screenID(window?.screen),
            "window_key": window?.isKeyWindow == true ? "true" : "false",
            "window_main": window?.isMainWindow == true ? "true" : "false",
            "window_visible": window?.isVisible == true ? "true" : "false"
        ]
    }
}

@MainActor
final class ReproProbeView: NSView {
    private let stage: ReproStage
    private let logger: ReproLogger
    private var mouseTrackingArea: NSTrackingArea?
    private var cursorTrackingArea: NSTrackingArea?
    private var lastMouseMoveLogNS: UInt64 = 0

    init(frame: NSRect, stage: ReproStage, logger: ReproLogger) {
        self.stage = stage
        self.logger = logger
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(horizontalProbeRect, cursor: .resizeLeftRight)
        addCursorRect(verticalProbeRect, cursor: .resizeUpDown)
        logger.log(
            "reset-cursor-rects",
            stage: stage,
            fields: ReproWindowMetadata.fields(window: window)
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }

        let mouseArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        let cursorArea = NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(mouseArea)
        addTrackingArea(cursorArea)
        mouseTrackingArea = mouseArea
        cursorTrackingArea = cursorArea

        logger.log(
            "update-tracking-areas",
            stage: stage,
            fields: ReproWindowMetadata.fields(window: window)
        )
    }

    override func cursorUpdate(with event: NSEvent) {
        logger.log("cursor-update", stage: stage, fields: eventFields(event))
        super.cursorUpdate(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        logger.log("mouse-entered", stage: stage, fields: eventFields(event))
    }

    override func mouseExited(with event: NSEvent) {
        logger.log("mouse-exited", stage: stage, fields: eventFields(event))
    }

    override func mouseMoved(with event: NSEvent) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastMouseMoveLogNS >= 250_000_000 else { return }
        lastMouseMoveLogNS = now
        logger.log("mouse-moved", stage: stage, fields: eventFields(event))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: dirtyRect).fill()

        drawProbe(
            rect: horizontalProbeRect,
            title: "Horizontal native resize cursor",
            subtitle: "Expected: ↔",
            accent: .systemBlue
        )
        drawProbe(
            rect: verticalProbeRect,
            title: "Vertical native resize cursor",
            subtitle: "Expected: ↕",
            accent: .systemGreen
        )
    }

    private var horizontalProbeRect: NSRect {
        let inset = bounds.insetBy(dx: 24, dy: 24)
        let gap: CGFloat = 20
        let width = max(80, (inset.width - gap) / 2)
        return NSRect(x: inset.minX, y: inset.minY, width: width, height: inset.height)
    }

    private var verticalProbeRect: NSRect {
        let inset = bounds.insetBy(dx: 24, dy: 24)
        let gap: CGFloat = 20
        let width = max(80, (inset.width - gap) / 2)
        return NSRect(
            x: inset.minX + width + gap,
            y: inset.minY,
            width: width,
            height: inset.height
        )
    }

    private func region(at point: NSPoint) -> String {
        if horizontalProbeRect.contains(point) { return "horizontal" }
        if verticalProbeRect.contains(point) { return "vertical" }
        return "background"
    }

    private func eventFields(_ event: NSEvent) -> [String: String] {
        var fields = ReproWindowMetadata.fields(window: window)
        let localPoint = convert(event.locationInWindow, from: nil)
        fields["region"] = region(at: localPoint)
        return fields
    }

    private func drawProbe(rect: NSRect, title: String, subtitle: String, accent: NSColor) {
        accent.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        (title as NSString).draw(
            at: NSPoint(x: rect.minX + 14, y: rect.midY + 8),
            withAttributes: titleAttributes
        )
        (subtitle as NSString).draw(
            at: NSPoint(x: rect.minX + 14, y: rect.midY - 18),
            withAttributes: subtitleAttributes
        )
    }
}

@MainActor
final class ReproAppDelegate: NSObject, NSApplicationDelegate {
    private let options: ReproOptions
    private let logger: ReproLogger
    private let harness: ReproEventHarness
    private var window: NSWindow?
    private var statusLabel: NSTextField?

    init(options: ReproOptions, logger: ReproLogger) {
        self.options = options
        self.logger = logger
        self.harness = ReproEventHarness(options: options, logger: logger)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentRect = NSRect(x: 0, y: 0, width: 760, height: 520)
        let createdWindow = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        createdWindow.title = "Issue #96 Cursor Presentation Repro — Stage \(options.stage.letter)"
        createdWindow.minSize = NSSize(width: 680, height: 470)
        createdWindow.acceptsMouseMovedEvents = true

        let content = NSView(frame: contentRect)
        content.autoresizesSubviews = true

        let title = NSTextField(labelWithString: "Stage \(options.stage.letter): \(options.stage.description)")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 24, y: 470, width: 712, height: 24)
        title.autoresizingMask = [.width]
        title.lineBreakMode = .byTruncatingTail

        let instructions = NSTextField(wrappingLabelWithString: Self.instructions(for: options.stage))
        instructions.frame = NSRect(x: 24, y: 402, width: 712, height: 60)
        instructions.autoresizingMask = [.width]
        instructions.textColor = .secondaryLabelColor

        let run = NSButton(
            title: options.stage.requiresAction
                ? "Run bounded stage action (\(options.leaseMilliseconds) ms)"
                : "No stage action required",
            target: self,
            action: #selector(runStageAction)
        )
        run.frame = NSRect(x: 24, y: 358, width: 280, height: 32)
        run.bezelStyle = .rounded
        run.isEnabled = options.stage.requiresAction

        let release = NSButton(
            title: "Release now",
            target: self,
            action: #selector(releaseNow)
        )
        release.frame = NSRect(x: 316, y: 358, width: 120, height: 32)
        release.bezelStyle = .rounded

        let status = NSTextField(labelWithString: "Starting harness…")
        status.frame = NSRect(x: 448, y: 364, width: 288, height: 20)
        status.autoresizingMask = [.width]
        status.alignment = .right
        status.textColor = .secondaryLabelColor

        let probe = ReproProbeView(
            frame: NSRect(x: 24, y: 24, width: 712, height: 318),
            stage: options.stage,
            logger: logger
        )
        probe.autoresizingMask = [.width, .height]

        content.addSubview(title)
        content.addSubview(instructions)
        content.addSubview(run)
        content.addSubview(release)
        content.addSubview(status)
        content.addSubview(probe)
        createdWindow.contentView = content

        window = createdWindow
        statusLabel = status
        installLifecycleObservers(window: createdWindow)

        createdWindow.center()
        createdWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let ready = harness.start()
        status.stringValue = ready ? "Harness ready" : "Event tap unavailable"
        if options.stage.requiresAction {
            run.isEnabled = ready
        }

        var fields = ReproWindowMetadata.fields(window: createdWindow)
        fields["edge"] = options.edge.rawValue
        fields["lease_ms"] = String(options.leaseMilliseconds)
        fields["log"] = logger.logPath
        logger.log("session-start", stage: options.stage, fields: fields)
    }

    func applicationWillTerminate(_ notification: Notification) {
        harness.stop()
        logger.log(
            "session-end",
            stage: options.stage,
            fields: ReproWindowMetadata.fields(window: window)
        )
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func runStageAction() {
        switch harness.beginLease() {
        case let .started(generation, displayID):
            statusLabel?.stringValue = "Lease \(generation) active on display \(displayID); auto-release armed"
        case let .rejected(reason):
            statusLabel?.stringValue = "Rejected: \(reason)"
            logger.log("lease-rejected", stage: options.stage, fields: ["reason": reason])
        }
    }

    @objc private func releaseNow() {
        harness.releaseLease(reason: "manual-button")
        statusLabel?.stringValue = "Release requested"
    }

    private func installLifecycleObservers(window: NSWindow) {
        let center = NotificationCenter.default
        let definitions: [(Notification.Name, Any?)] = [
            (NSApplication.didBecomeActiveNotification, NSApp),
            (NSApplication.didResignActiveNotification, NSApp),
            (NSWindow.didBecomeKeyNotification, window),
            (NSWindow.didResignKeyNotification, window),
            (NSWindow.didBecomeMainNotification, window),
            (NSWindow.didResignMainNotification, window),
            (NSWindow.didChangeScreenNotification, window),
            (NSWindow.didMoveNotification, window),
            (NSWindow.didResizeNotification, window)
        ]
        for (name, object) in definitions {
            center.addObserver(
                self,
                selector: #selector(lifecycleNotification(_:)),
                name: name,
                object: object
            )
        }
    }

    @objc private func lifecycleNotification(_ notification: Notification) {
        guard let event = Self.lifecycleEventName(for: notification.name) else { return }
        logger.log(
            event,
            stage: options.stage,
            fields: ReproWindowMetadata.fields(window: window)
        )
    }

    private static func lifecycleEventName(for name: Notification.Name) -> String? {
        switch name {
        case NSApplication.didBecomeActiveNotification: return "app-did-become-active"
        case NSApplication.didResignActiveNotification: return "app-did-resign-active"
        case NSWindow.didBecomeKeyNotification: return "window-did-become-key"
        case NSWindow.didResignKeyNotification: return "window-did-resign-key"
        case NSWindow.didBecomeMainNotification: return "window-did-become-main"
        case NSWindow.didResignMainNotification: return "window-did-resign-main"
        case NSWindow.didChangeScreenNotification: return "window-did-change-screen"
        case NSWindow.didMoveNotification: return "window-did-move"
        case NSWindow.didResizeNotification: return "window-did-resize"
        default: return nil
        }
    }

    private static func instructions(for stage: ReproStage) -> String {
        if stage.requiresAction {
            return "Move this window to the target display. Establish an observable baseline over both probe regions, run the bounded stage action once, then activate a real app on another display and return without clicking this display. Shift-Command-X releases an active lease immediately."
        }
        return "Move this window to the target display. Establish an observable baseline over both probe regions, then activate a real app on another display and return without clicking this display. This stage performs no pointer mutation."
    }
}

@main
struct CursorPresentationReproMain {
    @MainActor
    static func main() {
        let options: ReproOptions
        do {
            options = try ReproOptions.parse(arguments: CommandLine.arguments)
        } catch ReproArgumentError.help {
            print(ReproOptions.usage)
            return
        } catch ReproArgumentError.invalid(let message) {
            fputs("error: \(message)\n\n\(ReproOptions.usage)\n", stderr)
            exit(2)
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(2)
        }

        let logger = ReproLogger()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = ReproAppDelegate(options: options, logger: logger)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
