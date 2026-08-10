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

/// Menu bar icon color reflects session and control state at a glance.
extension AppModel {
    var statusColor: Color {
        if case .remote = controlState { return .blue }
        if case .returning = controlState { return .yellow }
        switch sessionState {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .ready: return .green
        case .reconnecting: return .orange
        case .failed: return .red
        }
    }
}

@MainActor
final class AppModel: ObservableObject {

    @Published var sessionState: SessionState = .disconnected
    @Published var controlState: ControlState = .local
    @Published var targetState: TargetState = .unavailable
    @Published var targets: [RemoteTarget] = []
    @Published var selectedTarget: RemoteTarget?
    @Published var serial: String = ""

    /// Last successful serial, kept for auto-reconnect after wireless drops.
    @Published var lastSerial: String = ""
    @MainActor private var reconnectTask: Task<Void, Never>?

    /// Accessed from the capture thread and the reader queue; RemoteSession
    /// is internally locked (@unchecked Sendable).
    nonisolated(unsafe) var connection: RemoteSession?
    nonisolated let adbTransport: AdbTransport
    nonisolated let capture: InputCapture
    nonisolated let switchMachine: EdgeSwitchStateMachine
    nonisolated(unsafe) private var hidDeviceId: UInt32?
    nonisolated(unsafe) private var hidButtons: UInt8 = 0
    nonisolated(unsafe) private var moveCount: Int = 0

    /// Monotonic gate for transition side effects. Transitions with a lower
    /// or equal sequence are stale (their side effects already superseded by
    /// a newer transition) and must be discarded — an old remote callback
    /// can never re-suppress the capture after a newer failure/return
    /// (see TransitionSequenceGate).
    private var transitionGate = TransitionSequenceGate()
    /// Current suppression generation, set when suppression starts.
    /// Used to discard stale onSuppressionReleased callbacks.
    private var currentSuppressionGeneration: UInt64 = 0

    init() {
        adbTransport = AdbTransport()
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
                // effects (e.g. a past remote callback re-suppressing capture
                // after a newer failure released it).
                guard self.transitionGate.shouldApply(transition) else { return }
                Diagnostics.log("edge transition \(transition.from.rawValue) -> \(transition.to.rawValue) reason=\(transition.reason.rawValue) sequence=\(transition.sequence)")
                self.updateControlState(for: transition.to)
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
                // Suppression was lifted. The session state must reflect the actual
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
                case .idle: self.sessionState = .disconnected
                case .ready: self.sessionState = .ready
                case .error: self.sessionState = .failed("helper fatal: suppression released after fatal error")
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
                Diagnostics.log("suppression released reason=\(reason.rawValue) session=\(self.sessionState) gen=\(generation)")
            }
        }
    }

    // MARK: - Connection

    func connect(serial: String) async {
        self.serial = serial
        sessionState = .connecting
        // Start clean: targets from a previous session must not survive.
        targets = []
        selectedTarget = nil
        targetState = .unavailable
        // Tear down any previous connection (repeated Connect clicks must not
        // leave orphaned helpers on the device).
        let old = connection
        connection = nil
        old?.shutdownAndWait()
        var config = RemoteSession.Configuration(serial: serial)
        let adbPath = adbTransport.configuredPath ?? AdbTransport.locate()
        if let adbPath { config.adbPath = adbPath }
        config.stderrHandler = { text in Diagnostics.log("helper: \(text)") }
        let manager = RemoteSession(configuration: config)
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
                self.targets = []
                self.selectedTarget = nil
                self.targetState = .unavailable
                self.switchMachine.connectionLost()
                if self.sessionState == .connecting || self.sessionState == .ready {
                    self.sessionState = .disconnected
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
                let normalized = RemoteTargetCatalog.normalize(list)
                targets = normalized
                targetState = normalized.isEmpty ? .unavailable : .available
                applyAutoSelection(normalized)
            }
            switchMachine.connectionReady()
            sessionState = .ready
            // sessionState is set via the successful connection path.
            applyEdgeConfig()
            if enable() {
                await setupHidDevice()
            }
        } catch {
            Diagnostics.log("connect failed: \(error)")
            switchMachine.connectionLost()
            sessionState = .failed("\(error)")
        }
    }

    func select(_ target: RemoteTarget) {
        selectedTarget = target
        targetState = .selected(target.id)
        Task {
            guard let connection else { return }
            _ = try? await connection.request(.selectDisplay,
                                              payload: Messages.selectDisplay(displayId: target.id.rawValue))
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        targets = []
        selectedTarget = nil
        targetState = .unavailable
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
        sessionState = .disconnected
    }

    @MainActor
    func handleDisplayChanged(_ info: DisplayInfo) {
        let target = RemoteTargetCatalog.normalize(info)
        if let idx = targets.firstIndex(where: { $0.id == target.id }) {
            targets[idx] = target
            Diagnostics.log("target updated id=\(target.id.rawValue) name=\(target.name)")
        } else {
            targets.append(target)
            Diagnostics.log("target added id=\(target.id.rawValue) name=\(target.name)")
        }
        targetState = selectedTarget == nil ? .available : targetState
        // If we were on this target and it changed, refresh edge config.
        if selectedTarget?.id == target.id {
            applyEdgeConfig()
        }
        // If the new/updated target is external and we have no selection, auto-select.
        if target.kind == .external && selectedTarget == nil {
            select(target)
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
                    let normalized = RemoteTargetCatalog.normalize(list)
                    targets = normalized
                    if let currentTarget = selectedTarget,
                       normalized.contains(where: { $0.id == currentTarget.id }) {
                        targetState = .selected(currentTarget.id)
                    } else {
                        targetState = normalized.isEmpty ? .unavailable : .available
                    }
                    Diagnostics.log("refreshDisplays: \(list.count) display(s)")
                    applyEdgeConfig()
                    if let currentTarget = selectedTarget,
                       !normalized.contains(where: { $0.id == currentTarget.id }) {
                        // Previously selected target disappeared; fall back by policy.
                        selectedTarget = nil
                        applyAutoSelection(normalized)
                    }
                }
            } catch {
                Diagnostics.log("refreshDisplays failed: \(error)")
            }
        }
    }

    @MainActor
    private func applyAutoSelection(_ targets: [RemoteTarget]) {
        guard let target = RemoteTargetCatalog.preferredTarget(
            in: targets,
            override: AppSettings.Settings.displayIdOverride
        ) else {
            targetState = .unavailable
            return
        }
        select(target)
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
        sessionState = .reconnecting
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
                let endpoints = self.adbTransport.discoverWirelessEndpoints(target: target)
                Diagnostics.log("auto-reconnect attempt \(attempt): endpoints \(endpoints.count)")
                for endpoint in endpoints {
                    self.adbTransport.reconnect(serial: endpoint)
                }
                let found = self.adbTransport.firstConnectedSerial()
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
    private func isPhaseReady() -> Bool { sessionState == .ready }

    func enable() -> Bool {
        guard capture.start() else {
            Diagnostics.log("capture start failed: accessibility not granted")
            sessionState = .failed("Accessibility permission required (System Settings → Privacy & Security → Accessibility)")
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
        switch sessionState {
        case .disconnected, .failed: return true
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

    private func apply(state: HandoffState, reason: TransitionReason) {
        switch state {
        case .remoteActive:
            if let gen = capture.suppress() {
                currentSuppressionGeneration = gen
            }
        case .localActive, .returning, .disabled, .error:
            capture.release(reason: Self.releaseReason(for: reason))
        default:
            break
        }
    }

    /// Projects the legacy edge-safety machine into the application control
    /// lifecycle. Session and target state are updated by their own paths.
    private func updateControlState(for state: HandoffState) {
        switch state {
        case .edgeArmed:
            controlState = .arming(switchMachine.entryEdge)
        case .remoteActive:
            controlState = .remote(selectedTarget?.id)
        case .returning:
            controlState = .returning
        case .localActive:
            controlState = .local
        case .disabled, .disconnected, .connecting, .error:
            controlState = .local
        }
    }

    /// Creates the UHID mouse on the helper and remembers its device id.
    /// If creation fails, pointer events fall back to the SDK injection path
    /// (InputManagerPointerInjector) which still routes hover/click but cannot move the
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

    /// Forward a captured event while the pointer is suppressed for a remote target.
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
                    sessionState = .failed("helper fatal \(fatal.code): \(fatal.message)")
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

}

private struct AppMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text("Ampersand")
        Text(statusText).foregroundStyle(.secondary)

        if model.isDisconnected {
            Button("Connect") {
                Task {
                    await model.connect(serial: model.adbTransport.firstConnectedSerial())
                }
            }
            Button("Grant Accessibility…") {
                model.openAccessibilitySettings()
            }
            Button("Enable Edge Switch") {
                _ = model.enable()
            }
        }

        if !model.targets.isEmpty {
            Divider()
            ForEach(model.targets) { target in
                Button {
                    model.select(target)
                } label: {
                    HStack {
                        Image(systemName: model.selectedTarget?.id == target.id
                              ? "checkmark.circle.fill" : "circle")
                        Text("\(target.name) (\(target.width)×\(target.height))")
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

        if case .remote = model.controlState {
            Divider()
            Button("Return to Mac (⇧⌘X)") { model.emergencyReturn() }
        }

        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }

    @MainActor
    private var statusText: String {
        switch model.sessionState {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .ready:
            switch model.controlState {
            case .local: return "Local"
            case let .arming(edge): return "Arming (\(edge.rawValue))"
            case .remote: return "Remote"
            case .returning: return "Returning"
            }
        case .reconnecting: return "Reconnecting…"
        case let .failed(message): return "Error: \(message)"
        }
    }
}
