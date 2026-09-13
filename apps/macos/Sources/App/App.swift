import SwiftUI
import AppKit
import Protocol
import AndroidBridge
import InputCapture
import InputCapability
import EdgeSwitch
import AppSettings
import Diagnostics
import Delivery

@main
struct Ampersand: App {
    @State private var model = AppModel()

    init() {
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
    static let menuBarIcon: NSImage = {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .heavy),
                .foregroundColor: NSColor.black,
            ]
            let glyph = NSAttributedString(string: "&", attributes: attrs)
            let bounds = glyph.boundingRect(with: rect.size)
            glyph.draw(at: NSPoint(x: rect.midX - bounds.width / 2,
                                   y: rect.midY - bounds.height / 2))
            return true
        }
    }()
}

extension AppModel {
    var statusColor: Color {
        if controlState == .remote { return .blue }
        if case .returning = controlState { return .yellow }
        switch sessionState {
        case .disconnected: return .gray
        case .connecting, .reconnecting: return .orange
        case .ready: return .green
        case .failed: return .red
        }
    }
}

private enum InputControlIssue: Equatable {
    case missingAccessibility
    case missingInputMonitoring
    case captureUnavailable
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sessionState: SessionState = .disconnected
    @Published var controlState: ControlState = .disabled
    @Published var targetState: TargetState = .unavailable
    @Published var targets: [RemoteTarget] = []
    @Published var selectedTarget: RemoteTarget?
    @Published private(set) var hostDisplays: [HostDisplayEdgeOption] = []
    @Published var serial: String = ""
    @Published var lastSerial: String = ""
    @Published private(set) var inputCapabilities: InputCapabilitySnapshot
    /// Once tap creation has failed with listen access missing, this process
    /// has evidence that Input Monitoring is required on this Mac/runtime.
    /// Keep that fact after the user grants it so a later revoke is fail-safe.
    @Published private(set) var inputMonitoringRequired = false
    @Published private var inputControlIssue: InputControlIssue?

    /// Invalidates an in-flight connect/reconnect action when the user starts
    /// a newer action or intentionally disconnects.
    private var connectionIntentGeneration: UInt64 = 0

    let sessionController: SessionController
    let handoffController: ControlHandoffController
    let inputCapabilityController: InputCapabilityController
    private let targetController: TargetSelectionController

    var capture: InputCapture { handoffController.capture }

    init(inputCapabilityController: InputCapabilityController = InputCapabilityController(),
         captureStart: (@MainActor () -> Bool)? = nil) {
        self.inputCapabilityController = inputCapabilityController
        self.inputCapabilities = inputCapabilityController.snapshot

        let reference = SessionReference()
        sessionController = SessionController(reference: reference)
        let sender = InputSender(session: reference)
        // Forward InputSender semantic failures through the unified sink
        // (lock-protected; safe from the delivery queue).
        sender.onDeliveryObservation = { [weak sessionController] observation in
            sessionController?.forwardDeliveryObservation(observation)
        }
        handoffController = ControlHandoffController(
            sender: sender,
            capabilityController: inputCapabilityController,
            captureStart: captureStart
        )
        targetController = TargetSelectionController(session: reference)

        // Production telemetry sink (review round 3): a single lock-protected
        // sink receives transport request observations, InputSender semantic
        // delivery observations, and late responses. Only failure/late
        // metadata reaches diag.log — never successes, never input payloads.
        sessionController.setObservationSink { observation in
            AppModel.logFailureReason(observation)
        }

        sessionController.onStateChange = { [weak self] state in
            self?.sessionState = state
        }
        sessionController.onEvent = { [weak self] frame in
            self?.handleUnsolicited(frame)
        }
        sessionController.onUnavailable = { [weak self] reason in
            self?.handleSessionUnavailable(reason)
        }
        targetController.onChange = { [weak self] targets, selected, state in
            self?.targets = targets
            self?.selectedTarget = selected
            self?.targetState = state
        }
        handoffController.onStateChange = { [weak self] state in
            self?.controlState = state
        }
        inputCapabilityController.onChange = { [weak self] snapshot in
            self?.applyInputCapabilitySnapshot(snapshot)
        }
        inputCapabilityController.startMonitoring()
        refreshHostDisplays()
    }

    // MARK: - Session

    func connectDefault() async {
        let discovered = sessionController.firstConnectedSerial()
        if !discovered.isEmpty {
            await connect(serial: discovered)
            return
        }

        let remembered = serial.isEmpty ? lastSerial : serial
        guard remembered.contains(":") else {
            await connect(serial: remembered)
            return
        }

        // Reuse the established session-layer wireless discovery/retry model
        // when the remembered endpoint is not currently connected.
        connectionIntentGeneration &+= 1
        let intent = connectionIntentGeneration
        sessionController.scheduleAutoReconnect(serial: remembered) { [weak self] serial in
            guard let self, self.connectionIntentGeneration == intent else { return }
            await self.connect(serial: serial)
        }
    }

    func connect(serial: String) async {
        connectionIntentGeneration &+= 1
        let intent = connectionIntentGeneration
        self.serial = serial
        targetController.reset()
        do {
            _ = try await sessionController.connect(serial: serial)
            guard intent == connectionIntentGeneration else { return }
            try await targetController.refresh()
            guard intent == connectionIntentGeneration else { return }
            guard targetController.selectedTarget != nil else {
                throw AppConnectionError.noAvailableTarget
            }
            applyEdgeConfig()
            // Input capability belongs to local Control, not Session. A
            // blocked/failed capture attempt leaves the healthy Android
            // Session and selected Target intact for an explicit retry.
            _ = enable()
        } catch {
            guard intent == connectionIntentGeneration else { return }
            Diagnostics.log("connect failed: \(error)")
            // A post-handshake remote failure (for example LIST_DISPLAYS or
            // target refresh rejection) is still a Session failure.
            sessionController.fail(error.localizedDescription)
            handoffController.remoteUnavailable()
        }
    }

    func disconnect() {
        connectionIntentGeneration &+= 1
        if !serial.isEmpty { lastSerial = serial }
        targetController.reset()
        // Release capture while the session reference is still valid so held
        // keys/buttons can be flushed to the helper before teardown.
        handoffController.disable()
        sessionController.disconnect()
    }

    func refreshDisplays() {
        guard sessionController.isConnected else {
            Diagnostics.log("refreshDisplays ignored: not connected")
            return
        }
        Task { [weak self] in
            do {
                guard let self else { return }
                try await self.targetController.refresh()
                self.applyEdgeConfig()
            } catch {
                Diagnostics.log("refreshDisplays failed: \(error)")
            }
        }
    }

    func select(_ target: RemoteTarget) {
        Task { [weak self] in
            do {
                guard let self else { return }
                try await self.targetController.select(target)
            } catch {
                Diagnostics.log("selection failed id=\(target.id.rawValue) reason=\(error.localizedDescription)")
            }
        }
    }

    private func handleDisplayChanged(_ info: DisplayInfo) {
        let suggested = targetController.handleDisplayChanged(info)
        applyEdgeConfig()
        if let suggested {
            select(suggested)
        }
    }

    private func handleSessionUnavailable(_ reason: String) {
        targetController.reset()
        handoffController.remoteUnavailable()
        Diagnostics.log("remote unavailable: \(reason)")
        lastSerial = serial
        let intent = connectionIntentGeneration
        sessionController.scheduleAutoReconnect(serial: serial) { [weak self] serial in
            guard let self, self.connectionIntentGeneration == intent else { return }
            await self.connect(serial: serial)
        }
    }

    // MARK: - Input capability / control handoff

    @discardableResult
    func refreshInputCapabilities() -> InputCapabilitySnapshot {
        let snapshot = inputCapabilityController.refresh()
        // `onChange` only fires on a real transition, so keep the presentation
        // projection synchronized even when this is an explicit no-op refresh.
        inputCapabilities = snapshot
        if snapshot.inputMonitoringGranted,
           inputControlIssue == .missingInputMonitoring {
            inputControlIssue = nil
        }
        if snapshot.accessibilityGranted, inputControlIssue == .missingAccessibility {
            inputControlIssue = nil
        }
        return snapshot
    }

    func requestAccessibility() {
        let snapshot = inputCapabilityController.requestAccessibility()
        applyInputCapabilitySnapshot(snapshot)
    }

    func requestInputMonitoring() {
        let snapshot = inputCapabilityController.requestInputMonitoring()
        applyInputCapabilitySnapshot(snapshot)
        if !snapshot.inputMonitoringGranted {
            openInputMonitoringSettings()
        }
    }

    private func applyInputCapabilitySnapshot(_ snapshot: InputCapabilitySnapshot) {
        let previous = inputCapabilities
        let lostAccessibility = previous.accessibilityGranted && !snapshot.accessibilityGranted
        let lostRequiredInputMonitoring = inputMonitoringRequired
            && previous.inputMonitoringGranted
            && !snapshot.inputMonitoringGranted
        inputCapabilities = snapshot

        if snapshot.inputMonitoringGranted,
           inputControlIssue == .missingInputMonitoring {
            inputControlIssue = nil
        }
        if snapshot.accessibilityGranted, inputControlIssue == .missingAccessibility {
            inputControlIssue = nil
        }

        if lostAccessibility {
            Diagnostics.log("input capability lost capability=accessibility action=local-return")
            inputControlIssue = .missingAccessibility
            handoffController.inputCapabilityLost()
            return
        }
        if lostRequiredInputMonitoring {
            Diagnostics.log("input capability lost capability=input-monitoring action=local-return")
            inputControlIssue = .missingInputMonitoring
            handoffController.inputCapabilityLost()
        }
    }

    @discardableResult
    func enable() -> ControlEnableResult {
        let result = handoffController.enable()
        switch result {
        case .enabled, .alreadyEnabled:
            inputControlIssue = nil
            // Do not clear `inputMonitoringRequired`: if a prior failed tap
            // proved that this environment requires it, the requirement must
            // survive the subsequent grant so revocation can be detected.
        case .missingAccessibility:
            inputControlIssue = .missingAccessibility
        case .missingInputMonitoring:
            inputMonitoringRequired = true
            inputControlIssue = .missingInputMonitoring
        case .captureUnavailable:
            inputControlIssue = .captureUnavailable
        }
        return result
    }

    func disableEdgeSwitch() {
        handoffController.disableEdgeSwitch()
    }

    func toggleEdgeSwitch() {
        if handoffController.isEdgeSwitchEnabled {
            disableEdgeSwitch()
        } else {
            _ = enable()
        }
    }

    /// Menu action derived from the published session/control projections. It
    /// is absent until a ready session has a confirmed target selection.
    var edgeSwitchActionTitle: String? {
        guard sessionState == .ready,
              case .selected = targetState else { return nil }
        return controlState == .disabled ? "Enable Edge Switch" : "Disable Edge Switch"
    }

    var shouldShowDisconnect: Bool {
        sessionState == .ready
    }

    var accessibilityStatusText: String {
        inputCapabilities.accessibilityGranted ? "Granted" : "Required"
    }

    var inputMonitoringStatusText: String {
        if inputCapabilities.inputMonitoringGranted { return "Granted" }
        return inputMonitoringRequired ? "Required" : "Not separately granted"
    }

    var inputControlStatusText: String? {
        switch inputControlIssue {
        case .missingAccessibility:
            return "Accessibility is required for Edge Switch"
        case .missingInputMonitoring:
            return "Input Monitoring is required on this Mac configuration"
        case .captureUnavailable:
            return "Input capture could not be created"
        case nil:
            return nil
        }
    }

    func emergencyReturn() {
        handoffController.emergencyReturn()
    }

    func openAccessibilitySettings() {
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        openPrivacySettings(anchor: "Privacy_ListenEvent")
    }

    private func openPrivacySettings(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"),
           NSWorkspace.shared.open(url) {
            return
        }
        if let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            _ = NSWorkspace.shared.open(fallback)
        }
    }

    var isDisconnected: Bool {
        switch sessionState {
        case .disconnected, .failed: return true
        default: return false
        }
    }

    private func handleUnsolicited(_ frame: CxiFrame) {
        switch frame.type {
        case .logEvent:
            if let log = try? Messages.decodeLogEvent(frame.payload) {
                Diagnostics.log("helper log: \(log.message)")
            }
        case .fatalError:
            if let fatal = try? Messages.decodeFatalError(frame.payload) {
                sessionController.fail("helper fatal \(fatal.code): \(fatal.message)")
                handoffController.remoteUnavailable()
            }
        case .displayChanged:
            if let info = try? Messages.decodeDisplayChanged(frame.payload) {
                handleDisplayChanged(info)
            }
        default:
            break
        }
    }

    // MARK: - Per-display edge configuration

    func applyEdgeConfig() {
        refreshHostDisplays()
        for display in hostDisplays {
            capture.setAndroidEdge(display.edge, forDisplay: display.id)
        }
    }

    func refreshHostDisplays() {
        let snapshots = NSScreen.screens.compactMap(Self.hostDisplaySnapshot)
        hostDisplays = HostDisplayEdgeCatalog.options(from: snapshots) { displayID in
            AppSettings.Settings.androidEdge(displayID: displayID)
        }
    }

    func setAndroidEdge(_ edge: ScreenEdge?, for displayID: CGDirectDisplayID) {
        AppSettings.Settings.setAndroidEdge(edge?.rawValue, displayID: displayID)
        capture.setAndroidEdge(edge, forDisplay: displayID)
        if let index = hostDisplays.firstIndex(where: { $0.id == displayID }) {
            hostDisplays[index].edge = edge
        }
        Diagnostics.log("remote edge for host display \(displayID) = \(edge?.rawValue ?? "none")")
    }

    private static func hostDisplaySnapshot(_ screen: NSScreen) -> HostDisplaySnapshot? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return HostDisplaySnapshot(
            id: CGDirectDisplayID(number.uint32Value),
            name: screen.localizedName,
            width: Int(screen.frame.width.rounded()),
            height: Int(screen.frame.height.rounded()))
    }
}

private struct AppMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            Text("Ampersand")
            Text(statusText).foregroundStyle(.secondary)

            if model.isDisconnected {
                Button("Connect") { Task { await model.connectDefault() } }
            }

            if let edgeSwitchAction = model.edgeSwitchActionTitle {
                Button(edgeSwitchAction) { model.toggleEdgeSwitch() }
            }
            if model.shouldShowDisconnect {
                Button("Disconnect") { model.disconnect() }
            }

            Divider()
            Text("Input Permissions")
            Text("Accessibility — \(model.accessibilityStatusText)")
            if !model.inputCapabilities.accessibilityGranted {
                Button("Grant Accessibility…") { model.requestAccessibility() }
                Button("Open Accessibility Settings…") { model.openAccessibilitySettings() }
            }
            Text("Input Monitoring — \(model.inputMonitoringStatusText)")
            if model.inputMonitoringRequired && !model.inputCapabilities.inputMonitoringGranted {
                Button("Grant Input Monitoring…") { model.requestInputMonitoring() }
            }
            if let inputControlStatus = model.inputControlStatusText {
                Text(inputControlStatus).foregroundStyle(.secondary)
            }
            Button("Refresh Input Permissions") { model.refreshInputCapabilities() }

            if !model.targets.isEmpty {
                Divider()
                ForEach(model.targets) { target in
                    Button { model.select(target) } label: {
                        HStack {
                            Image(systemName: model.selectedTarget?.id == target.id
                                  ? "checkmark.circle.fill" : "circle")
                            Text("\(target.name) (\(target.width)×\(target.height))")
                        }
                    }
                }
                Divider()
                Button("Refresh Displays") { model.refreshDisplays() }
            }

            if !model.hostDisplays.isEmpty {
                Divider()
                Text("Remote target is at…")
                ForEach(model.hostDisplays) { display in
                    Picker(
                        display.label,
                        selection: Binding<ScreenEdge?>(
                            get: {
                                model.hostDisplays.first(where: { $0.id == display.id })?.edge
                            },
                            set: { model.setAndroidEdge($0, for: display.id) })) {
                        Text("None").tag(ScreenEdge?.none)
                        ForEach(ScreenEdge.allCases, id: \.self) { edge in
                            Text(edge.rawValue.capitalized).tag(ScreenEdge?.some(edge))
                        }
                    }
                }
            }

            if model.controlState == .remote {
                Divider()
                Button("Return to Mac (⇧⌘X)") { model.emergencyReturn() }
            }

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .onAppear {
            model.refreshHostDisplays()
            model.refreshInputCapabilities()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshInputCapabilities()
        }
    }

    @MainActor
    private var statusText: String {
        switch model.sessionState {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .ready:
            if let inputStatus = model.inputControlStatusText,
               model.controlState == .disabled {
                return inputStatus
            }
            switch model.controlState {
            case .disabled: return "Edge Switch disabled"
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

private enum AppConnectionError: LocalizedError {
    case noAvailableTarget

    var errorDescription: String? {
        "No available Android target was discovered"
    }
}

/// Failure/late-only diagnostics logging for production telemetry.
extension AppModel {
    nonisolated static func logFailureReason(_ observation: RequestObservation) {
        switch observation.outcome {
        case .success:
            return // successes are noise; never logged
        case .timedOut(let requestType, let budget):
            Diagnostics.log("request timeout type=\(requestType.rawValue) budget=\(budget)s")
        case .streamClosed(let requestType):
            Diagnostics.log("request stream-closed type=\(requestType.rawValue)")
        case .writeFailed(let requestType):
            Diagnostics.log("request write-failed type=\(requestType.rawValue)")
        case .unexpectedResponse(let requestType):
            Diagnostics.log("request unexpected-response type=\(requestType.rawValue)")
        case .malformedResponse(let requestType):
            Diagnostics.log("request malformed-response type=\(requestType.rawValue)")
        case .helperReportedFailure(let requestType):
            Diagnostics.log("request helper-failure type=\(requestType.rawValue)")
        case .lateResponse(let requestKind, let delay):
            Diagnostics.log("late response after timeout type=\(requestKind.rawValue) delayBeyondDeadline=\(delay)s")
        case .partialDelivery(let requestType):
            Diagnostics.log("pointer partial-delivery type=\(requestType.rawValue) (product fail-safe)")
        case .otherFailure(let requestType, _):
            Diagnostics.log("request other-failure type=\(requestType.rawValue)")
        }
    }
}
