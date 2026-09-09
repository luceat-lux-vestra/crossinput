import AppKit
import CoreGraphics
import Foundation

private enum Edge: String {
    case left, right, top, bottom
}

private struct Options {
    let edge: Edge
    let leaseMilliseconds: Int

    static func parse(_ arguments: [String]) -> Options {
        var edge: Edge = .right
        var leaseMilliseconds = 1500
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--edge" where index + 1 < arguments.count:
                if let parsed = Edge(rawValue: arguments[index + 1]) {
                    edge = parsed
                }
                index += 2
            case "--lease-ms" where index + 1 < arguments.count:
                if let parsed = Int(arguments[index + 1]) {
                    leaseMilliseconds = min(max(parsed, 250), 5000)
                }
                index += 2
            default:
                index += 1
            }
        }

        return Options(edge: edge, leaseMilliseconds: leaseMilliseconds)
    }
}

private final class ProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        let halfWidth = bounds.width / 2
        addCursorRect(
            NSRect(x: 0, y: 0, width: halfWidth, height: bounds.height),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            NSRect(x: halfWidth, y: 0, width: bounds.width - halfWidth, height: bounds.height),
            cursor: .resizeUpDown
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]

        let halfWidth = bounds.width / 2
        let horizontal = NSString(string: "resizeLeftRight probe")
        horizontal.draw(
            in: NSRect(x: 0, y: bounds.midY - 14, width: halfWidth, height: 28),
            withAttributes: attributes
        )

        let vertical = NSString(string: "resizeUpDown probe")
        vertical.draw(
            in: NSRect(x: halfWidth, y: bounds.midY - 14, width: bounds.width - halfWidth, height: 28),
            withAttributes: attributes
        )
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct Lease {
        let displayID: CGDirectDisplayID
        let anchorLocal: CGPoint
        let expiresAt: TimeInterval
        var moveCount: UInt64
        var mutationFailures: UInt64
    }

    private let options: Options
    private let stateLock = NSLock()
    private var lease: Lease?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var window: NSWindow!
    private var statusLabel: NSTextField!

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        guard installEventTap() else {
            setStatus("event tap unavailable — grant Accessibility/Input Monitoring and relaunch")
            return
        }
        setStatus("ready — move this window to the target display, verify both native cursors, then run")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 760, height: 420)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Issue #96 — display-local cursor hold repro"
        window.center()
        window.acceptsMouseMovedEvents = true

        let root = NSView(frame: contentRect)
        root.autoresizingMask = [.width, .height]

        let probe = ProbeView(frame: NSRect(x: 20, y: 90, width: 720, height: 300))
        probe.autoresizingMask = [.width, .height]
        root.addSubview(probe)

        let button = NSButton(
            title: "Run bounded display-local hold",
            target: self,
            action: #selector(runLease)
        )
        button.frame = NSRect(x: 20, y: 48, width: 260, height: 32)
        root.addSubview(button)

        statusLabel = NSTextField(labelWithString: "starting…")
        statusLabel.frame = NSRect(x: 300, y: 48, width: 440, height: 32)
        statusLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(statusLabel)

        let note = NSTextField(labelWithString: "Lease is bounded to 250–5000 ms. During the lease, physical move/drag events are consumed and every admitted movement uses CGDisplayMoveCursorToPoint on one target display. No CGWarpMouseCursorPosition is called.")
        note.frame = NSRect(x: 20, y: 10, width: 720, height: 32)
        note.maximumNumberOfLines = 2
        note.lineBreakMode = .byWordWrapping
        root.addSubview(note)

        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func runLease() {
        guard let screen = window.screen,
              let displayID = Self.displayID(for: screen),
              let event = CGEvent(source: nil) else {
            setStatus("cannot resolve target display")
            return
        }

        let bounds = CGDisplayBounds(displayID)
        let global = event.location
        var local = CGPoint(x: global.x - bounds.origin.x, y: global.y - bounds.origin.y)
        local.x = min(max(local.x, 1), max(bounds.width - 2, 1))
        local.y = min(max(local.y, 1), max(bounds.height - 2, 1))

        switch options.edge {
        case .left:
            local.x = 1
        case .right:
            local.x = max(bounds.width - 2, 1)
        case .top:
            local.y = 1
        case .bottom:
            local.y = max(bounds.height - 2, 1)
        }

        let duration = Double(options.leaseMilliseconds) / 1000.0
        stateLock.withLock {
            lease = Lease(
                displayID: displayID,
                anchorLocal: local,
                expiresAt: ProcessInfo.processInfo.systemUptime + duration,
                moveCount: 0,
                mutationFailures: 0
            )
        }

        let initialResult = CGDisplayMoveCursorToPoint(displayID, local)
        if initialResult != .success {
            stateLock.withLock {
                lease?.mutationFailures += 1
            }
        }

        print("event=lease-start primitive=CGDisplayMoveCursorToPoint display=\(displayID) edge=\(options.edge.rawValue) lease_ms=\(options.leaseMilliseconds) initial_result=\(initialResult.rawValue)")
        setStatus("lease active — move the physical mouse/trackpad continuously")

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.endLease(reason: "timeout")
        }
    }

    private func endLease(reason: String) {
        let ended: Lease? = stateLock.withLock {
            guard let current = lease else { return nil }
            lease = nil
            return current
        }
        guard let ended else { return }

        print("event=lease-end reason=\(reason) move_count=\(ended.moveCount) mutation_failures=\(ended.mutationFailures)")
        setStatus("lease ended — now perform the known cross-display activation trigger; do not click this target display before judging the probes")
    }

    private func installEventTap() -> Bool {
        var mask: CGEventMask = 0
        for type in [
            CGEventType.mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .keyDown
        ] {
            mask |= CGEventMask(1) << type.rawValue
        }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            return owner.handleTap(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        print("event=event-tap-installed location=cghid place=headInsert options=default")
        return true
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 7,
               event.flags.contains(.maskCommand),
               event.flags.contains(.maskShift) {
                endLease(reason: "emergency-hotkey")
            }
            return Unmanaged.passUnretained(event)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            break
        default:
            return Unmanaged.passUnretained(event)
        }

        let active: Lease? = stateLock.withLock {
            guard var current = lease else { return nil }
            if ProcessInfo.processInfo.systemUptime >= current.expiresAt {
                lease = nil
                return nil
            }
            current.moveCount &+= 1
            lease = current
            return current
        }

        guard let active else {
            return Unmanaged.passUnretained(event)
        }

        let result = CGDisplayMoveCursorToPoint(active.displayID, active.anchorLocal)
        if result != .success {
            stateLock.withLock {
                guard var current = lease else { return }
                current.mutationFailures &+= 1
                lease = current
            }
        }

        return nil
    }

    private func setStatus(_ text: String) {
        if Thread.isMainThread {
            statusLabel?.stringValue = text
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel?.stringValue = text
            }
        }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

let options = Options.parse(CommandLine.arguments)
let app = NSApplication.shared
let delegate = AppDelegate(options: options)
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
