import AppKit
import Darwin
import EdgeSwitch
import Diagnostics

protocol RemoteCursorPresenting: AnyObject, Sendable {
    func presentRemote(edge: ScreenEdge)
    func restoreLocal()
}

/// Thin runtime bridge to Carbon Appearance's public (deprecated)
/// SetThemeCursor API. Unlike NSCursor.set(), this API is not scoped to the
/// owning application's AppKit cursor stack.
///
/// Resolve dynamically so the modern Swift SDK does not need to expose legacy
/// Carbon declarations at compile time. Failure to resolve is explicit and
/// fail-closed for #96 presentation.
final class CarbonThemeCursorBridge: @unchecked Sendable {
    typealias SetThemeCursorFunction = @convention(c) (UInt32) -> Int32

    static let shared = CarbonThemeCursorBridge()

    private let handle: UnsafeMutableRawPointer?
    private let setThemeCursorFunction: SetThemeCursorFunction?

    private init() {
        let candidates = [
            "/System/Library/Frameworks/Carbon.framework/Carbon",
            "/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox",
        ]

        var resolvedHandle: UnsafeMutableRawPointer?
        var resolvedFunction: SetThemeCursorFunction?

        for path in candidates {
            guard let candidate = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
                continue
            }
            guard let symbol = dlsym(candidate, "SetThemeCursor") else {
                dlclose(candidate)
                continue
            }
            resolvedHandle = candidate
            resolvedFunction = unsafeBitCast(
                symbol,
                to: SetThemeCursorFunction.self
            )
            break
        }

        handle = resolvedHandle
        setThemeCursorFunction = resolvedFunction
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }

    var isAvailable: Bool {
        setThemeCursorFunction != nil
    }

    func set(_ cursor: UInt32) -> Int32? {
        setThemeCursorFunction?(cursor)
    }
}

/// Presents the host-side remote-ownership cursor without activating Ampersand
/// and without mutating pointer position.
///
/// AppKit cursor APIs are application-scoped: Apple explicitly documents that
/// NSCursor.current may differ from the actually visible cursor when another
/// app is active. The previous NSCursor/cursor-rect candidates therefore could
/// not own the global glyph in CrossInput's non-activating status-app model.
///
/// Carbon Appearance's SetThemeCursor is a separate system-theme cursor API.
/// It is deprecated but public, requires no private CGS/SkyLight SPI, and does
/// not require pointer warping, synthetic mouse events, or app activation.
final class NativeRemoteCursorPresenter: RemoteCursorPresenting,
    @unchecked Sendable
{
    // Appearance.h ThemeCursor constants.
    static let themeArrowCursor: UInt32 = 0
    static let themeResizeLeftRightCursor: UInt32 = 17
    static let themeResizeUpDownCursor: UInt32 = 21

    private let lock = NSLock()
    private var operationGeneration: UInt64 = 0
    private let bridge: CarbonThemeCursorBridge

    init(bridge: CarbonThemeCursorBridge = .shared) {
        self.bridge = bridge
    }

    func presentRemote(edge: ScreenEdge) {
        let generation = nextGeneration()
        let themeCursor = Self.themeCursor(for: edge)

        Task { @MainActor [weak self] in
            guard let self,
                  self.isCurrent(generation) else {
                return
            }

            guard self.bridge.isAvailable else {
                Diagnostics.log(
                    "host cursor presentation failed mode=carbon-theme "
                        + "reason=SetThemeCursor-unavailable"
                )
                return
            }

            let appWasActive = NSApp?.isActive ?? false
            let frontmostPIDBefore =
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            let status = self.bridge.set(themeCursor)
            let frontmostPIDAfter =
                NSWorkspace.shared.frontmostApplication?.processIdentifier

            Diagnostics.log(
                "host cursor presentation remote mode=carbon-theme "
                    + "generation=\(generation) "
                    + "edge=\(edge.rawValue) "
                    + "status=\(status.map(String.init) ?? "nil") "
                    + "appWasActive=\(appWasActive) "
                    + "appActive=\(NSApp?.isActive ?? false) "\n                    + "frontmostUnchanged=\(frontmostPIDBefore == frontmostPIDAfter)"
            )

            self.logSystemCursorVerdict(
                edge: edge,
                generation: generation,
                phase: "immediate"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                [weak self] in
                guard let self,
                      self.isCurrent(generation) else {
                    return
                }
                self.logSystemCursorVerdict(
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
            guard self.bridge.isAvailable else { return }

            let status = self.bridge.set(Self.themeArrowCursor)
            Diagnostics.log(
                "host cursor presentation local mode=carbon-theme "
                    + "status=\(status.map(String.init) ?? "nil")"
            )
        }
    }

    @MainActor
    private func logSystemCursorVerdict(
        edge: ScreenEdge,
        generation: UInt64,
        phase: String
    ) {
        let expected = Self.cursor(for: edge)
        let currentSystem = NSCursor.currentSystem
        let matches = currentSystem.map {
            Self.cursorAppearanceMatches($0, expected)
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

    static func themeCursor(for edge: ScreenEdge) -> UInt32 {
        switch edge {
        case .left, .right:
            return themeResizeLeftRightCursor
        case .top, .bottom:
            return themeResizeUpDownCursor
        }
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
}
