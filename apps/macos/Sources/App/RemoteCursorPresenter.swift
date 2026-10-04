import AppKit
import EdgeSwitch
import Diagnostics

protocol RemoteCursorPresenting: AnyObject, Sendable {
    func presentRemote(edge: ScreenEdge)
    func restoreLocal()
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

/// Presents the host-side remote-ownership cursor at the frozen handoff
/// position without activating Ampersand or mutating the pointer position.
///
/// A one-shot NSCursor.set() is insufficient here: it changes Ampersand's
/// application cursor stack, but another active application may still own the
/// visible cursor. Instead, a tiny non-activating transparent AppKit panel is
/// placed under the already-frozen host cursor and owns a normal cursor rect.
/// AppKit/WindowServer therefore selects the native directional cursor using
/// the same mechanism as ordinary views.
///
/// Pointer isolation remains exclusively CoreHID's responsibility.
final class NativeRemoteCursorPresenter: RemoteCursorPresenting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var operationGeneration: UInt64 = 0

    // Main-queue owned.
    private var presentationPanel: NSPanel?

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
            panel.orderFrontRegardless()
            // This panel is intentionally non-activating and therefore may
            // never become key. Rebuild its cursor rectangles synchronously
            // instead of relying on key-window invalidation processing.
            panel.resetCursorRects()

            // CoreHID has already seized the trackpad, so there may be no
            // subsequent local mouse event to make WindowServer re-evaluate
            // the cursor rect immediately. The overlay establishes ownership;
            // this one-shot set publishes that already-owned native cursor
            // now. Unlike the rejected set-only approach, the panel remains
            // underneath the frozen pointer and keeps the cursor rect
            // authoritative for the whole remote epoch.
            cursor.set()

            self.presentationPanel = panel
            Diagnostics.log(
                "host cursor presentation remote mode=cursor-rect forced=true "
                    + "edge=\(edge.rawValue) "
                    + "appActive=\(NSApp.isActive) "
                    + "panelKey=\(panel.isKeyWindow) "
                    + "cursorRectsEnabled=\(panel.areCursorRectsEnabled)"
            )
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
                "host cursor presentation local mode=cursor-rect restored"
            )
        }
    }

    @MainActor
    private func removePanelIfPresent() {
        presentationPanel?.orderOut(nil)
        presentationPanel?.close()
        presentationPanel = nil
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

    private static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first {
            NSMouseInRect(point, $0.frame, false)
        } ?? NSScreen.main
    }

    private static func presentationFrame(
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
