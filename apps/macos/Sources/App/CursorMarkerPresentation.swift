import AppKit
import CoreGraphics
import Delivery
import EdgeSwitch

/// The presentation-only projection of remote ownership onto one host display.
///
/// `ControlHandoffController` and `EdgeSwitchStateMachine` remain the source of
/// truth for ownership and entry direction. This value only decides whether a
/// marker may be rendered and where it belongs; it does not participate in
/// handoff or input routing.
enum CursorMarkerPresentationState: Equatable, Sendable {
    case hidden
    case visible(displayID: CGDirectDisplayID, edge: ScreenEdge)

    static func derive(
        controlState: ControlState,
        sessionState: SessionState,
        entryEdge: ScreenEdge,
        hostDisplays: [HostDisplayEdgeOption]
    ) -> Self {
        guard sessionState == .ready else {
            return .hidden
        }

        let activeEdge: ScreenEdge
        switch controlState {
        case let .arming(edge):
            activeEdge = edge
        case .remote:
            activeEdge = entryEdge
        case .local, .returning:
            return .hidden
        }

        // A display is selected by its configured edge, never by the current
        // pointer display. Duplicate edge assignments are ambiguous because
        // the existing handoff state exposes direction but not display ID;
        // fail closed rather than showing a marker on the wrong display.
        let candidates = hostDisplays.filter { $0.edge == activeEdge }
        guard candidates.count == 1, let display = candidates.first else {
            return .hidden
        }
        return .visible(displayID: display.id, edge: activeEdge)
    }
}

/// A marker points into the host display from its configured edge. For
/// example, a remote target on the left is represented by a right-facing
/// chevron (`>`), matching the earlier entry cue.
enum CursorMarkerDirection: Equatable, Sendable {
    case left
    case right
    case up
    case down

    init(edge: ScreenEdge) {
        switch edge {
        case .left: self = .right
        case .right: self = .left
        case .top: self = .down
        case .bottom: self = .up
        }
    }
}

/// Window geometry is pure so edge placement can be checked without creating
/// a window or generating pointer input.
enum CursorMarkerWindowGeometry {
    static let width: CGFloat = 48
    static let height: CGFloat = 96

    static func frame(for edge: ScreenEdge, in screenFrame: CGRect) -> CGRect {
        switch edge {
        case .left:
            return CGRect(
                x: screenFrame.minX,
                y: screenFrame.midY - height / 2,
                width: width,
                height: height)
        case .right:
            return CGRect(
                x: screenFrame.maxX - width,
                y: screenFrame.midY - height / 2,
                width: width,
                height: height)
        case .top:
            return CGRect(
                x: screenFrame.midX - width / 2,
                y: screenFrame.maxY - height,
                width: width,
                height: height)
        case .bottom:
            return CGRect(
                x: screenFrame.midX - width / 2,
                y: screenFrame.minY,
                width: width,
                height: height)
        }
    }
}

@MainActor
protocol CursorMarkerRenderSink: AnyObject {
    func render(_ state: CursorMarkerPresentationState)
    func teardown()
}

/// Owns the presentation lifecycle and coalesces repeated state updates.
/// There is no state machine here: the caller supplies the current projection
/// derived from the authoritative application state.
@MainActor
final class CursorMarkerController {
    private let sink: CursorMarkerRenderSink
    private(set) var state: CursorMarkerPresentationState = .hidden

    init(sink: CursorMarkerRenderSink = CursorMarkerWindowRenderer()) {
        self.sink = sink
    }

    func update(
        controlState: ControlState,
        sessionState: SessionState,
        entryEdge: ScreenEdge,
        hostDisplays: [HostDisplayEdgeOption]
    ) {
        let next = CursorMarkerPresentationState.derive(
            controlState: controlState,
            sessionState: sessionState,
            entryEdge: entryEdge,
            hostDisplays: hostDisplays)
        guard next != state else { return }
        state = next
        sink.render(next)
    }

    func teardown() {
        guard state != .hidden else {
            sink.teardown()
            return
        }
        state = .hidden
        sink.teardown()
    }
}

@MainActor
private final class CursorMarkerWindowRenderer: NSObject, CursorMarkerRenderSink {
    private var windows: [CGDirectDisplayID: CursorMarkerWindow] = [:]

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: NSApplication.shared)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func render(_ state: CursorMarkerPresentationState) {
        switch state {
        case .hidden:
            closeAll()
        case let .visible(displayID, edge):
            guard let screen = Self.screen(withDisplayID: displayID) else {
                // Display removal/reconfiguration can race a state update.
                // Never fall back to another screen.
                closeAll()
                return
            }

            for (otherID, window) in windows where otherID != displayID {
                window.close()
                windows.removeValue(forKey: otherID)
            }

            let direction = CursorMarkerDirection(edge: edge)
            let frame = CursorMarkerWindowGeometry.frame(for: edge, in: screen.frame)
            let window: CursorMarkerWindow
            if let existing = windows[displayID], existing.direction == direction {
                window = existing
            } else {
                windows[displayID]?.close()
                let created = CursorMarkerWindow(frame: frame, direction: direction)
                windows[displayID] = created
                window = created
            }
            window.setFrame(frame, display: true)
            window.orderFrontRegardless()
        }
    }

    func teardown() {
        closeAll()
    }

    private func closeAll() {
        for window in windows.values {
            window.close()
        }
        windows.removeAll()
    }

    @objc private func handleApplicationWillTerminate() {
        closeAll()
    }

    private static func screen(withDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return false }
            return CGDirectDisplayID(number.uint32Value) == displayID
        }
    }
}

@MainActor
private final class CursorMarkerWindow: NSPanel {
    let direction: CursorMarkerDirection

    init(frame: NSRect, direction: CursorMarkerDirection) {
        self.direction = direction
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = CursorMarkerView(direction: direction)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CursorMarkerView: NSView {
    private let direction: CursorMarkerDirection

    init(direction: CursorMarkerDirection) {
        self.direction = direction
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let panel = bounds.insetBy(dx: 4, dy: 4)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12).fill()

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let halfLength: CGFloat = 18
        let halfWidth: CGFloat = 13
        let path = NSBezierPath()
        path.lineWidth = 5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch direction {
        case .left:
            path.move(to: CGPoint(x: center.x + halfLength, y: center.y + halfWidth))
            path.line(to: CGPoint(x: center.x - halfLength, y: center.y))
            path.line(to: CGPoint(x: center.x + halfLength, y: center.y - halfWidth))
        case .right:
            path.move(to: CGPoint(x: center.x - halfLength, y: center.y + halfWidth))
            path.line(to: CGPoint(x: center.x + halfLength, y: center.y))
            path.line(to: CGPoint(x: center.x - halfLength, y: center.y - halfWidth))
        case .up:
            path.move(to: CGPoint(x: center.x - halfWidth, y: center.y - halfLength))
            path.line(to: CGPoint(x: center.x, y: center.y + halfLength))
            path.line(to: CGPoint(x: center.x + halfWidth, y: center.y - halfLength))
        case .down:
            path.move(to: CGPoint(x: center.x - halfWidth, y: center.y + halfLength))
            path.line(to: CGPoint(x: center.x, y: center.y - halfLength))
            path.line(to: CGPoint(x: center.x + halfWidth, y: center.y + halfLength))
        }

        NSColor.white.setStroke()
        path.stroke()
    }
}
