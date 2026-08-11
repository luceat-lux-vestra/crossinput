import SwiftUI
import Protocol
import AndroidBridge
import InputCapture
import EdgeSwitch
import AppSettings
import Diagnostics

@main
struct Ampersand: App {
    @State private var model = AppModel()

    init() {
        // Menu bar app: do not show a Dock icon or an app-switcher entry.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            AppMenu(model: model)
        } label: {
            Image(nsImage: Ampersand.menuBarIcon)
                .foregroundStyle(model.statusColor)
        }
    }
}

extension Ampersand {
    /// Menu bar badge: a monochrome template "&" glyph rendered at runtime.
    /// Template mode keeps the icon adaptive (light/dark menu bar) while
    /// `.foregroundStyle(statusColor)` still tints it per connection state.
    /// Swappable for a designed glyph PNG once a resource bundle exists (Phase 8).
    static let menuBarIcon: NSImage = {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .heavy),
                .foregroundColor: NSColor.black,
            ]
            let glyph = NSAttributedString(string: "&", attributes: attrs)
            let bounds = glyph.boundingRect(with: rect.size)
            let origin = NSPoint(x: rect.midX - bounds.width / 2,
                                 y: rect.midY - bounds.height / 2)
            glyph.draw(at: origin)
            return true
        }
    }()
}

/// Menu bar icon color reflects state at a glance:
/// gray idle / orange connecting / red error / green macActive /
/// blue dexActive / yellow recovering.
extension AppModel {
    var statusColor: Color {
        if state == .dexActive { return .blue }
        if state == .recovering { return .yellow }
        switch phase {
        case .idle: return .gray
        case .connecting: return .orange
        case .ready: return .green
        case .error: return .red
        }
    }
}

enum AppPhase: Equatable {
    case idle
    case connecting
    case ready
    case error(String)
}

@MainActor
final class AppModel: ObservableObject {

    @Published var phase: AppPhase = .idle
    @Published var state: SwitchState = .disabled
    @Published var displays: [DisplayInfo] = []
    @Published var selectedDisplay: DisplayInfo?
    @Published var serial: String = ""

    /// Last successful serial, kept for auto-reconnect after wireless drops.
    @Published var lastSerial: String = ""
    @MainActor private var reconnectTask: Task<Void, Never>?

    /// Accessed from the capture thread and the reader queue; ConnectionManager
    /// is internally locked (@unchecked Sendable).
    nonisolated(unsafe) var connection: ConnectionManager?
    nonisolated let capture: InputCapture
    nonisolated let switchMachine: EdgeSwitchStateMachine
    nonisolated(unsafe) private var hidDeviceId: UInt32?
    nonisolated(unsafe) private var hidButtons: UInt8 = 0
    nonisolated(unsafe) private var moveCount: Int = 0

    /// Monotonic gate for transition side effects. Transitions with a lower
    /// or equal sequence are stale (their side effects already superseded by
    /// a newer transition) and must be discarded — an old `.dexActive`
    /// callback can never re-suppress the capture after a newer
    /// `.error`/`.recovering` (see TransitionSequenceGate).
    private var transitionGate = TransitionSequenceGate()
    /// Current suppression generation, set when suppression starts.
    /// Used to discard stale onSuppressionReleased callbacks.
    private var currentSuppressionGeneration: UInt64 = 0

    init() {
        capture = InputCapture()
        // Opt-in diagnostic logging for edge-switch movement (metadata only:
        // entryEdge, raw dx/dy, axis delta, virtual position, state). Never
        // logs key codes, clipboard contents, or input payloads.
        let diagnosticsEnabled = ProcessInfo.processInfo.environment["AMPER_EDGE_DIAG"] == "1"
        switchMachine = EdgeSwitchStateMachine(isDiagnosticsEnabled: diagnosticsEnabled)
        switchMachine.onStateChange = { [weak self] transition in
            Task { @MainActor in
                guard let self else { return }
                // Stale-transition guard: an older transition callback that
                // arrives after a newer one must not overwrite newer side
                // effects (e.g. a past `.dexActive` re-suppressing capture
                // after a newer `.error` released it).
                guard self.transitionGate.shouldApply(transition) else { return }
                Diagnostics.log("edge transition \(transition.from.rawValue) -> \(transition.to.rawValue) reason=\(transition.reason.rawValue) sequence=\(transition.sequence)")
                self.state = transition.to
                self.apply(state: transition.to, reason: transition.reason)
            }
        }
        capture.onScreenEdge = { [weak self] edge in
            Diagnostics.log("screen edge hit: \(edge)")
            self?.switchMachine.pointerAtEdge(edge)
        }
        capture.onPointerEvent = { [weak self] event in
            self?.onCapturedEvent(event)
        }
        capture.onKeyEvent = { [weak self] keyEvent in
            self?.onCapturedKeyEvent(keyEvent)
        }
        capture.onPointerStateReset = { [weak self] in
            self?.resetCapturedPointerState()
        }
        capture.onSuppressionReleased = { [weak self] reason, generation in
            Task { @MainActor in
                // Suppression was lifted. The phase must reflect the actual
                // cause: a dead connection stays disconnected (idle/reconnect),
                // a fatal error stays error, and only live-connection releases
                // (normal return, watchdog, emergency hotkey) become ready.
                // This mapping is the pure, tested SuppressionPhasePolicy —
                // never collapse a real cause into a normal return (issue #37).
                // Stale suppression-release callbacks (older generation) are discarded.
                guard let self else { return }
                guard generation == self.currentSuppressionGeneration else {
                    Diagnostics.log("suppression released: discarding stale callback (gen \(generation), current \(self.currentSuppressionGeneration))")
                    return
                }
                let outcome = SuppressionPhasePolicy.nextPhase(after: reason,
                                                               isConnected: self.connection?.isConnected == true)
                switch outcome {
                case .idle: self.phase = .idle
                case .ready: self.phase = .ready
                case .error: self.phase = .error("helper fatal: suppression released after fatal error")
                }
                let machineReason: TransitionReason
                switch reason {
                case .watchdogTimeout: machineReason = .watchdogTimeout
                case .emergencyHotkey: machineReason = .emergencyReturn
                case .normalReturn: machineReason = .suppressionReleased
                case .connectionLost: machineReason = .connectionLost
                case .captureStopped: machineReason = .deactivated
                case .fatalError: machineReason = .fatalError
                case .externalControl: machineReason = .externalControlTakeover
                }
                self.switchMachine.emergencyReturn(reason: machineReason)
                Diagnostics.log("suppression released reason=\(reason.rawValue) phase=\(self.phase) gen=\(generation)")
            }
        }
    }

    // MARK: - Connection

    func connect(serial: String) async {
        self.serial = serial
        phase = .connecting
        // Start clean: any displays from a previous session must not survive.
        displays = []
        selectedDisplay = nil
        // Tear down any previous connection (repeated Connect clicks must not
        // leave orphaned helpers on the device).
        let old = connection
        connection = nil
        old?.shutdownAndWait()
        var config = ConnectionManager.Configuration(serial: serial)
        let adbPath = Self.locateAdb()
        if let adbPath { config.adbPath = adbPath }
        config.stderrHandler = { text in Diagnostics.log("helper: \(text)") }
        let manager = ConnectionManager(configuration: config)
        manager.onEvent = { [weak self] frame in
            self?.handleUnsolicited(frame)
        }
        manager.onDisconnect = { [weak self, weak manager] in
            Task { @MainActor in
                // Ignore callbacks from a stale manager: shutdownAndWait() on a
                // previous connection fires its termination handler, which must
                // not nil out the freshly installed one.
                guard let self, let manager, self.connection === manager else { return }
                self.hidDeviceId = nil
                self.connection = nil
                self.displays = []
                self.selectedDisplay = nil
                self.switchMachine.connectionLost()
                if self.phase == .connecting || self.phase == .ready {
                    self.phase = .idle
                }
                self.scheduleAutoReconnect()
            }
        }
        connection = manager
        // If the state machine is in a terminal .error state (from a prior fatal),
        // explicitly recover through the documented lifecycle: deactivate -> activate.
        if switchMachine.state == .error {
            switchMachine.deactivate()
            switchMachine.activate()
        } else {
            switchMachine.activate()
        }
        do {
            try await manager.connect()
            switchMachine.connectionBegan()
            let listFrame = try await manager.request(.listDisplays, payload: Data())
            let list = try Messages.decodeDisplayList(listFrame.payload)
            await MainActor.run {
                displays = list
                applyAutoSelection(list)
            }
            switchMachine.connectionReady()
            // phase is set via onStateChange callback when state reaches .macActive
            applyEdgeConfig()
            if enable() {
                await setupHidDevice()
            }
        } catch {
            Diagnostics.log("connect failed: \(error)")
            switchMachine.connectionLost()
            phase = .error("\(error)")
        }
    }

    func select(_ display: DisplayInfo) {
        selectedDisplay = display
        Task {
            guard let connection else { return }
            _ = try? await connection.request(.selectDisplay,
                                              payload: Messages.selectDisplay(displayId: display.displayId))
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        displays = []
        selectedDisplay = nil
        if let deviceId = hidDeviceId {
            hidDeviceId = nil
            let destroyPayload = Messages.destroyHidDevice(deviceId: deviceId)
            Task { [weak self] in
                guard let connection = self?.connection else { return }
                _ = try? await connection.request(.destroyHidDevice, payload: destroyPayload)
            }
        }
        connection?.shutdownAndWait()
        connection = nil
        switchMachine.deactivate()
        phase = .idle
    }

    @MainActor
    func handleDisplayChanged(_ info: DisplayInfo) {
        if let idx = displays.firstIndex(where: { $0.displayId == info.displayId }) {
            displays[idx] = info
            Diagnostics.log("display updated id=\(info.displayId) name=\(info.name)")
        } else {
            displays.append(info)
            Diagnostics.log("display added id=\(info.displayId) name=\(info.name)")
        }
        // If we were on this display and it changed, refresh edge config
        if selectedDisplay?.displayId == info.displayId {
            applyEdgeConfig()
        }
        // If the new/updated display is a desktop and we have no selection, auto-select
        if info.isDesktop && selectedDisplay == nil {
            select(info)
        }
    }

    /// Re-issues LIST_DISPLAYS so a display connected while the app is running
    /// shows up even if DISPLAY_CHANGED was missed by the transport.
    func refreshDisplays() {
        guard connection?.isConnected == true else {
            Diagnostics.log("refreshDisplays ignored: not connected")
            return
        }
        Task {
            do {
                let listFrame = try await connection?.request(.listDisplays, payload: Data())
                guard let list = listFrame.flatMap({ try? Messages.decodeDisplayList($0.payload) }) else {
                    Diagnostics.log("refreshDisplays: decode failed")
                    return
                }
                await MainActor.run {
                    displays = list
                    Diagnostics.log("refreshDisplays: \(list.count) display(s)")
                    applyEdgeConfig()
                    if selectedDisplay.flatMap({ sel in list.contains(where: { $0.displayId == sel.displayId }) }) == false {
                        // Previously selected display disappeared; fall back to desktop.
                        applyAutoSelection(list)
                    }
                }
            } catch {
                Diagnostics.log("refreshDisplays failed: \(error)")
            }
        }
    }

    @MainActor
    private func applyAutoSelection(_ list: [DisplayInfo]) {
        if let override = AppSettings.Settings.displayIdOverride,
           let match = list.first(where: { $0.displayId == UInt32(override) }) {
            select(match)
        } else if let desktop = list.first(where: { $0.isDesktop }) {
            select(desktop)
        } else if let hdmi = list.first(where: { $0.type == 2 }) { // HDMI
            select(hdmi)
        } else if let first = list.first {
            select(first)
        }
    }

    /// Wireless debugging on Samsung automatically disables on Wi-Fi drop /
    /// sleep, so a dropped session is often recoverable by re-issuing
    /// `adb connect` and reconnecting. Bounded retries; no-op for USB.
    ///
    /// Note: the debug port (the `:NNNNN` part) changes whenever the phone
    /// restarts its wireless-debugging service, so we also rediscover via
    /// `adb mdns services` and retry on the fresh endpoint.
    @MainActor
    private func scheduleAutoReconnect() {
        lastSerial = serial
        guard !serial.isEmpty, serial.contains(":") else {
            Diagnostics.log("auto-reconnect skipped (serial: \(serial.isEmpty ? "none" : "usb"))")
            return
        }
        phase = .idle
        Diagnostics.log("auto-reconnect scheduled for \(serial)")
        reconnectTask?.cancel()
        let target = serial
        reconnectTask = Task.detached { [weak self] in
            for attempt in 1...5 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                guard await self.isConnectionNil() else { return }
                // Re-issue adb connect on the remembered endpoint and on any
                // freshly discovered mDNS endpoint (port may have changed).
                let endpoints = await Self.discoverWirelessEndpoints(target: target)
                Diagnostics.log("auto-reconnect attempt \(attempt): endpoints \(endpoints.count)")
                for endpoint in endpoints {
                    Self.reconnectAdb(serial: endpoint)
                }
                let found = await Self.firstAdbSerial()
                if !found.isEmpty {
                    Diagnostics.log("auto-reconnect attempt \(attempt): device \(found)")
                    await self.connect(serial: found)
                    if await self.isPhaseReady() { return }
                } else {
                    Diagnostics.log("auto-reconnect attempt \(attempt): device still offline")
                }
            }
        }
    }

    @MainActor
    private func isConnectionNil() -> Bool { connection == nil }
    @MainActor
    private func isPhaseReady() -> Bool { phase == .ready }

    nonisolated private static func reconnectAdb(serial: String) {
        guard serial.contains(":") else { return }
        let adb = locateAdb() ?? "/usr/local/bin/adb"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["connect", serial]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Diagnostics.log("adb connect failed: \(error)")
        }
    }

    /// Returns `[ip:port]` candidates: the remembered endpoint first, then any
    /// `_adb-tls-connect._tcp` mDNS advertisement with a matching IP.
    nonisolated private static func discoverWirelessEndpoints(target: String) async -> [String] {
        let adb = locateAdb() ?? "/usr/local/bin/adb"
        var endpoints: [String] = []
        if !target.isEmpty { endpoints.append(target) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["mdns", "services"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            for line in lines {
                guard line.contains("_adb-tls-connect._tcp") else { continue }
                // e.g. "SM-G977N_XXXX._adb-tls-connect._tcp 192.168.0.10:37327"
                guard let endpoint = line.split(whereSeparator: { $0.isWhitespace }).last else { continue }
                let s = String(endpoint)
                guard s.contains(":") else { continue }
                if s != target, endpoints.contains(s) == false { endpoints.append(s) }
            }
        } catch {
            Diagnostics.log("adb mdns services failed: \(error)")
        }
        return endpoints
    }

    func enable() -> Bool {
        guard capture.start() else {
            Diagnostics.log("capture start failed: accessibility not granted")
            phase = .error("Accessibility permission required (System Settings → Privacy & Security → Accessibility)")
            return false
        }
        Diagnostics.log("capture started; edge switch activated")
        switchMachine.activate()
        return true
    }

    func emergencyReturn() {
        switchMachine.emergencyReturn()
    }

    func openAccessibilitySettings() {
        Diagnostics.log("opening Accessibility settings pane")
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    var isDisconnected: Bool {
        switch phase {
        case .idle, .error: return true
        default: return false
        }
    }

    // MARK: - Pointer plumbing

    /// Maps a state-machine transition reason to a suppression release reason so
    /// the pointer-release path never collapses a real cause into `.normalReturn`.
    private static func releaseReason(for reason: TransitionReason) -> SuppressionReleaseReason {
        switch reason {
        case .connectionLost: return .connectionLost
        case .watchdogTimeout: return .watchdogTimeout
        case .fatalError: return .fatalError
        case .deactivated: return .captureStopped
        case .emergencyReturn: return .emergencyHotkey
        case .externalControlTakeover: return .externalControl
        case .boundaryCrossed, .suppressionReleased, .edgeEntered,
             .activation, .connectionBegan, .connectionReady:
            return .normalReturn
        }
    }

    private func apply(state: SwitchState, reason: TransitionReason) {
        switch state {
        case .dexActive:
            if let gen = capture.suppress() {
                currentSuppressionGeneration = gen
            }
        case .macActive, .recovering, .disabled, .error:
            capture.release(reason: Self.releaseReason(for: reason))
        default:
            break
        }
    }

    /// Creates the UHID mouse on the helper and remembers its device id.
    /// If creation fails, pointer events fall back to the SDK injection path
    /// (SdkPointerBackend) which still routes hover/click but cannot move the
    /// DeX cursor sprite — UHID is the verified channel (issue #6 verdict).
    func setupHidDevice() async {
        guard let connection else { return }
        do {
            let frame = try await connection.request(.createHidDevice,
                                                      payload: Messages.createHidDevice(descriptor: Self.mouseDescriptor))
            switch frame.type {
            case .hidCreated:
                hidDeviceId = try Messages.decodeHidCreated(frame.payload)
                Diagnostics.log("UHID mouse created id=\(hidDeviceId ?? 0)")
            case .hidError:
                if let err = try? Messages.decodeHidError(frame.payload) {
                    Diagnostics.log("UHID create failed (code \(err.code)): \(err.message)")
                }
                Diagnostics.log("falling back to SDK pointer injection")
            default:
                Diagnostics.log("unexpected response \(frame.type) to createHidDevice; falling back to SDK injection")
            }
        } catch {
            Diagnostics.log("createHidDevice failed: \(error); falling back to SDK injection")
        }
    }

    /// Runs on the capture thread (nonisolated): forward pointer events to the helper.
    /// The state machine is fed inside send(event:) so its virtual position
    /// always tracks the movement actually delivered to Android (UHID splitting
    /// must not desync the two — issue #37 root cause analysis).
    nonisolated func onCapturedEvent(_ event: PointerEvent) {
        switch event.kind {
        case .move:
            moveCount &+= 1
            if moveCount.isMultiple(of: 200) {
                Diagnostics.log("captured moves: \(moveCount)")
            }
        case let .button(button, down):
            Diagnostics.log("captured button \(button) \(down ? "down" : "up")")
        case .scroll:
            Diagnostics.log("captured scroll")
        }
        send(event: event)
    }

    /// Forward a captured event while the pointer is suppressed (dexActive).
    /// Uses the UHID mouse when available, else falls back to SDK injection.
    nonisolated func onCapturedKeyEvent(_ keyEvent: CapturedKeyEvent) {
        // Dispatched straight to the helper as KEY_EVENT. The Android side
        // backs it with UHID keyboard or virtual injection (ADR-0007).
        guard let connection else { return }
        try? connection.send(CxiFrame(type: .keyEvent, requestId: 1,
                                      payload: Messages.keyEvent(keyCode: UInt16(keyEvent.keyCode),
                                                                 metaState: keyEvent.metaState,
                                                                 action: keyEvent.action,
                                                                 repeatCount: keyEvent.repeatCount)))
    }

    nonisolated func send(event: PointerEvent) {
        guard let connection else { return }
        if let deviceId = hidDeviceId {
            switch event.kind {
            case let .move(dx, dy):
                // Split into HID-range reports so large deltas are never lost
                // to Int8 clamping (HIDReportSplitter). The state machine must
                // see exactly the movement delivered to Android — and only
                // movement that was actually written to the helper: if a send
                // throws (stream closed, broken pipe), the failed reports are
                // skipped and only the delivered part is credited, so the
                // virtual position never outruns the device (issue #37).
                let movement = HIDReportSplitter.normalizeForHID(dx: dx, dy: dy)
                var sentDx: Int32 = 0
                var sentDy: Int32 = 0
                for report in movement.reports {
                    let payload = Self.hidReport(buttons: hidButtons,
                                                 dx: Int32(report.dx), dy: Int32(report.dy), wheel: 0)
                    do {
                        try connection.send(CxiFrame(type: .hidReport, requestId: 1,
                                                     payload: Messages.hidReport(deviceId: deviceId, report: payload)))
                        sentDx += Int32(report.dx)
                        sentDy += Int32(report.dy)
                    } catch {
                        Diagnostics.log("hid report send failed, crediting \(sentDx),\(sentDy): \(error)")
                        break
                    }
                }
                // A zero-zero delivered movement (no reports were generated,
                // or every send failed) is not a real delivery: the state
                // machine is not called at all, so the first-movement
                // exemption and the virtual position stay untouched.
                if sentDx != 0 || sentDy != 0 {
                    switchMachine.pointerMoved(dx: CGFloat(sentDx), dy: CGFloat(sentDy))
                }
            case let .button(button, down):
                let bit = Self.hidButtonBit(for: button)
                if down { hidButtons |= bit } else { hidButtons &= ~bit }
                let report = Self.hidReport(buttons: hidButtons, dx: 0, dy: 0, wheel: 0)
                try? connection.send(CxiFrame(type: .hidReport, requestId: 1,
                                              payload: Messages.hidReport(deviceId: deviceId, report: report)))
            case let .scroll(_, vertical):
                let wheel: UInt8 = vertical > 0 ? 1 : (vertical < 0 ? 255 : 0)
                let report = Self.hidReport(buttons: hidButtons, dx: 0, dy: 0, wheel: wheel)
                try? connection.send(CxiFrame(type: .hidReport, requestId: 1,
                                              payload: Messages.hidReport(deviceId: deviceId, report: report)))
            }
        } else {
            switch event.kind {
            case let .move(dx, dy):
                // SDK fallback: full Int32 deltas, delivered unchanged. The
                // state machine is credited only when the frame was actually
                // written to the helper.
                do {
                    try connection.send(CxiFrame(type: .pointerMoveRel, requestId: 1,
                                                 payload: Messages.pointerMoveRel(dx: dx, dy: dy)))
                    switchMachine.pointerMoved(dx: CGFloat(dx), dy: CGFloat(dy))
                } catch {
                    Diagnostics.log("pointerMoveRel send failed, movement not credited: \(error)")
                }
            case let .button(button, down):
                let bit = Self.hidButtonBit(for: button)
                if down { hidButtons |= bit } else { hidButtons &= ~bit }
                try? connection.send(CxiFrame(type: .pointerButton, requestId: 1,
                                              payload: Messages.pointerButton(button: button, down: down)))
            case let .scroll(horizontal, vertical):
                try? connection.send(CxiFrame(type: .pointerScroll, requestId: 1,
                                              payload: Messages.pointerScroll(horizontal: horizontal, vertical: vertical)))
            }
        }
    }

    /// Releases any button state that was held on Android when an external
    /// controller takes ownership. This runs synchronously before the
    /// triggering CGEvent is returned to macOS.
    nonisolated func resetCapturedPointerState() {
        let heldButtons = hidButtons
        hidButtons = 0
        guard heldButtons != 0, let connection else { return }

        if let deviceId = hidDeviceId {
            let report = Self.hidReport(buttons: 0, dx: 0, dy: 0, wheel: 0)
            try? connection.send(CxiFrame(type: .hidReport, requestId: 1,
                                          payload: Messages.hidReport(deviceId: deviceId, report: report)))
        } else {
            for (bit, button) in [(UInt8(0x01), UInt32(0)),
                                   (UInt8(0x02), UInt32(1)),
                                   (UInt8(0x04), UInt32(2))]
            where heldButtons & bit != 0 {
                try? connection.send(CxiFrame(type: .pointerButton, requestId: 1,
                                              payload: Messages.pointerButton(button: button, down: false)))
            }
        }
        Diagnostics.log("external-control pointer state reset buttons=\(heldButtons.nonzeroBitCount)")
    }

    nonisolated func handleUnsolicited(_ frame: CxiFrame) {
        switch frame.type {
        case .logEvent:
            if let log = try? Messages.decodeLogEvent(frame.payload) {
                Diagnostics.log("helper log: \(log.message)")
            }
        case .fatalError:
            if let fatal = try? Messages.decodeFatalError(frame.payload) {
                Task { @MainActor in
                    phase = .error("helper fatal \(fatal.code): \(fatal.message)")
                    // fatal() (not connectionLost()) keeps the machine in .error,
                    // so the subsequent suppression release cannot collapse the
                    // fatal cause into an idle/ready phase (SuppressionPhasePolicy).
                    switchMachine.fatal()
                }
            }
        case .displayChanged:
            Diagnostics.log("received DISPLAY_CHANGED payload=\(frame.payload.count)B")
            if let info = try? Messages.decodeDisplayChanged(frame.payload) {
                Task { @MainActor in
                    self.handleDisplayChanged(info)
                }
            } else {
                Diagnostics.log("DISPLAY_CHANGED decode failed")
            }
        default:
            break
        }
    }

    nonisolated private static func locateAdb() -> String? {
        let candidates = ["/usr/local/bin/adb", "/opt/homebrew/bin/adb", "/usr/bin/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Per-display edge configuration

    /// Applies the persisted per-display Android-edge settings to the capture.
    func applyEdgeConfig() {
        for screen in NSScreen.screens {
            let id = Self.displayID(of: screen)
            let stored = AppSettings.Settings.androidEdge(displayID: id)
            capture.setAndroidEdge(Self.screenEdge(from: stored), forDisplay: id)
        }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return 0 }
        return CGDirectDisplayID(num.uint32Value)
    }

    static func screenEdge(from string: String?) -> ScreenEdge? {
        switch string {
        case "left": return .left
        case "right": return .right
        case "top": return .top
        case "bottom": return .bottom
        default: return nil
        }
    }

    static func edgeName(_ edge: ScreenEdge?) -> String {
        switch edge {
        case .left: return "left"
        case .right: return "right"
        case .top: return "top"
        case .bottom: return "bottom"
        case nil: return "none"
        }
    }

    // MARK: - UHID mouse (verified channel for the DeX cursor sprite)

    /// 62-byte mouse descriptor — byte-identical to protocol/fixtures/create-hid.bin.
    nonisolated static let mouseDescriptor: Data = Data([
        0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x01, 0xa1, 0x00, 0x05, 0x09,
        0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01,
        0x81, 0x02, 0x95, 0x01, 0x75, 0x05, 0x81, 0x01, 0x05, 0x01, 0x09, 0x30,
        0x09, 0x31, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x02, 0x81, 0x06,
        0x09, 0x38, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
        0xc0, 0xc0])

    /// HID report payload: buttons u8, dx i8, dy i8, wheel u8 (wheel 1=up, 255=down).
    nonisolated static func hidReport(buttons: UInt8, dx: Int32, dy: Int32, wheel: UInt8) -> Data {
        var report = Data()
        report.append(buttons)
        report.append(UInt8(bitPattern: Int8(clamping: dx)))
        report.append(UInt8(bitPattern: Int8(clamping: dy)))
        report.append(wheel)
        return report
    }

    /// Protocol button (0=left 1=right 2=middle) -> HID button bit.
    nonisolated static func hidButtonBit(for button: UInt32) -> UInt8 {
        switch button {
        case 0: return 0x01
        case 1: return 0x02
        default: return 0x04
        }
    }

    /// Returns the first connected adb device serial, if any.
    static func firstAdbSerial() async -> String {
        let adb = locateAdb() ?? "/usr/local/bin/adb"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["devices"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        for line in lines.dropFirst() {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2, parts[1] == "device" {
                return String(parts[0])
            }
        }
        return ""
    }
}

private struct AppMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text("Ampersand")
        Text(statusText).foregroundStyle(.secondary)

        if model.isDisconnected {
            Button("Connect") {
                Task {
                    await model.connect(serial: await AppModel.firstAdbSerial())
                }
            }
            Button("Grant Accessibility…") {
                model.openAccessibilitySettings()
            }
            Button("Enable Edge Switch") {
                _ = model.enable()
            }
        }

        if !model.displays.isEmpty {
            Divider()
            ForEach(model.displays, id: \.uniqueId) { display in
                Button {
                    model.select(display)
                } label: {
                    HStack {
                        Image(systemName: model.selectedDisplay?.displayId == display.displayId
                              ? "checkmark.circle.fill" : "circle")
                        Text("\(display.name) (\(display.width)×\(display.height))")
                    }
                }
            }
            Divider()
            Button("Refresh Displays") {
                model.refreshDisplays()
            }
        }

        if !NSScreen.screens.isEmpty {
            Divider()
            Text("Android is at…")
            ForEach(NSScreen.screens, id: \.hashValue) { screen in
                let displayID = AppModel.displayID(of: screen)
                let stored = AppSettings.Settings.androidEdge(displayID: displayID)
                Picker("\(screen.localizedName) (\(Int(screen.frame.width))×\(Int(screen.frame.height)))",
                       selection: Binding<String>(
                        get: { stored ?? "none" },
                        set: { newValue in
                            let edge = AppModel.screenEdge(from: newValue)
                            AppSettings.Settings.setAndroidEdge(newValue, displayID: displayID)
                            model.capture.setAndroidEdge(edge, forDisplay: displayID)
                            Diagnostics.log("android edge for display \(displayID) = \(newValue)")
                        }
                       )) {
                    Text("None").tag("none")
                    Text("Left").tag("left")
                    Text("Right").tag("right")
                    Text("Top").tag("top")
                    Text("Bottom").tag("bottom")
                }
            }
        }

        if model.state == .dexActive {
            Divider()
            Button("Return to Mac (⇧⌘X)") { model.emergencyReturn() }
        }

        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }

    @MainActor
    private var statusText: String {
        switch model.phase {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .ready: return model.state.rawValue
        case let .error(message): return "Error: \(message)"
        }
    }
}
