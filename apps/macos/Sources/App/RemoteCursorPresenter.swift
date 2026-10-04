import AppKit
import EdgeSwitch
import Diagnostics

protocol RemoteCursorPresenting: AnyObject, Sendable {
    func presentRemote(edge: ScreenEdge)
    func restoreLocal()
}

/// A borderless non-activating panel is not key-capable by default because it
/// has neither a title bar nor a resize bar. Cursor rectangles are a key-window
/// facility in AppKit, so the remote cursor owner must explicitly be eligible
/// to become key while retaining the non-activating panel style.
final class RemoteCursorAuthorityPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class RemoteCursorRectView: NSView {
    let remoteCursor: NSCursor

    init(cursor: NSCursor) {
        self.remoteCursor = cursor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: remoteCursor)
    }
}

/// Presents the host-side remote-ownership cursor at the frozen handoff
/// position without activating Ampersand or mutating the pointer position.
///
/// A one-shot NSCursor.set() is insufficient here: it changes Ampersand's
/// application cursor stack, but another active application may still own the
/// visible cursor. The presenter therefore installs a tiny non-activating,
/// key-capable AppKit panel under the already-frozen host cursor. Making this
/// panel key gives its cursor rect real AppKit cursor authority without
/// activating Ampersand.
///
/// Pointer isolation remains exclusively CoreHID's responsibility.
final class NativeRemoteCursorPresenter: RemoteCursorPresenting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var operationGeneration: UInt64 = 0

    // Main-queue owned.
    private var presentationPanel: RemoteCursorAuthorityPanel?

    func presentRemote(edge: ScreenEdge) {
        let generation = nextGeneration()
        Task { @MainActor [weak self] in
            guard let self,
                  self.isCurrent(generation) else {
                return
            }

            self.removePanelIfPresent()

            let cursor = Self.cursor(for: edge)
            let mouse = NSEvent.mouseLocation
            guard let screen = Self.screen(containing: mouse) else {
                Diagnostics.log(
                    "host cursor presentation failed reason=no-screen"
                )
                return
            }

            let frame = Self.presentationFrame(
                around: mouse,
                in: screen.frame
            )
            let view = RemoteCursorRectView(cursor: cursor)
            let panel = RemoteCursorAuthorityPanel(
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
            panel.becomesKeyOnlyIfNeeded = false
            panel.acceptsMouseMovedEvents = true
            // Do not ignore mouse hit-testing: WindowServer must consider this
            // view's cursor rect. CoreHID has already seized the built-in
            // trackpad, and the panel is removed before ownership is released.
            panel.ignoresMouseEvents = false
            panel.level = .screenSaver
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle,
            ]
            panel.contentView = view

            let appWasActive = NSApp.isActive
            let frontmostPIDBefore =
                NSWorkspace.shared.frontmostApplication?.processIdentifier

            // A non-activating panel may become key without activating its
            // owning application. This is the material difference from the
            // previous orderFrontRegardless-only candidate, whose cursor rect
            // existed but never obtained key-window cursor authority.
            panel.makeKeyAndOrderFront(nil)
            panel.resetCursorRects()

            // CoreHID has seized the trackpad, so there may be no subsequent
            // local mouse event to publish the newly authoritative cursor rect.
            // Set the same native cursor once after key-window ownership exists.
            cursor.set()

            self.presentationPanel = panel

            let frontmostPIDAfter =
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            Diagnostics.log(
                "host cursor presentation remote mode=key-cursor-rect "
                    + "edge=\(edge.rawValue) "
                    + "appWasActive=\(appWasActive) "
                    + "appActive=\(NSApp.isActive) "
                    + "panelKey=\(panel.isKeyWindow) "
                    + "frontmostUnchanged=\(frontmostPIDBefore == frontmostPIDAfter) "
                    + "cursorRectsEnabled=\(panel.areCursorRectsEnabled)"
            )

            self.logSystemCursorVerdict(
                cursor: cursor,
                edge: edge,
                generation: generation,
                phase: "immediate"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                [weak self, weak panel] in
                guard let self,
                      let panel,
                      self.isCurrent(generation),
                      self.presentationPanel === panel else {
                    return
                }
                self.logSystemCursorVerdict(
                    cursor: cursor,
                    edge: edge,
                    generation: generation,
                    phase: "settled"
                )
            }
        }
    }

    func restoreLocal() {
        let generation = nextGeneration()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isCurrent(generation) else {
                return
            }
            guard self.presentationPanel != nil else { return }

            self.removePanelIfPresent()
            Diagnostics.log(
                "host cursor presentation local mode=key-cursor-rect restored"
            )
        }
    }

    @MainActor
    private func removePanelIfPresent() {
        presentationPanel?.orderOut(nil)
        presentationPanel?.close()
        presentationPanel = nil
    }

    @MainActor
    private func logSystemCursorVerdict(
        cursor: NSCursor,
        edge: ScreenEdge,
        generation: UInt64,
        phase: String
    ) {
        // currentSystem is deprecated for product logic, but Apple documents
        // it as the cursor actually displayed system-wide. Use it only as a
        // bounded diagnostic oracle so physical #96 runs no longer depend on
        // an operator visually classifying the glyph.
        let currentSystem = NSCursor.currentSystem
        let matches = currentSystem.map {
            Self.cursorAppearanceMatches($0, cursor)
        } ?? false
        Diagnostics.log(
            "host cursor presentation verdict "
                + "generation=\(generation) "
                + "phase=\(phase) "
                + "edge=\(edge.rawValue) "
                + "systemCursorAvailable=\(currentSystem != nil) "
                + "systemMatch=\(matches)"
        )
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

    static func cursor(for edge: ScreenEdge) -> NSCursor {
        switch edge {
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        }
    }

    static func cursorAppearanceMatches(
        _ lhs: NSCursor,
        _ rhs: NSCursor
    ) -> Bool {
        lhs.hotSpot == rhs.hotSpot
            && lhs.image.tiffRepresentation == rhs.image.tiffRepresentation
    }

    private static func screen(containing point: NSPoint) -> NSScreen? {
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
