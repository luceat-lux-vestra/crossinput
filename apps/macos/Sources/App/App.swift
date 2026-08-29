import SwiftUI
import AppKit
import Protocol
import AndroidBridge
import InputCapture
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
    /// Invalidates an in-flight connect/reconnect action when the user starts
    /// a newer action or intentionally disconnects.
    private var connectionIntentGeneration: UInt64 = 0

    let sessionController: SessionController
    let handoffController: ControlHandoffController
    private let targetController: TargetSelectionController

    var capture: InputCapture { handoffController.capture }

    init() {
        let reference = SessionReference()
        sessionController = SessionController(reference: reference)
        let sender = InputSender(session: reference)
        // Forward InputSender semantic failures through the unified sink
        // (lock-protected; safe from the delivery queue).
        sender.onDeliveryObservation = { [weak sessionController] observation in
            sessionController?.forwardDeliveryObservation(observation)
        }
        handoffController = ControlHandoffController(sender: sender)
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
            guard enable() else {
                sessionController.fail("Accessibility permission required (System Settings → Privacy & Security → Accessibility)")
                handoffController.remoteUnavailable()
                return
            }
        } catch {
            guard intent == connectionIntentGeneration else { return }
            Diagnostics.log("connect failed: \(error)")
            // A post-handshake failure (for example LIST_DISPLAYS or target
            // refresh rejection) must not leave a live helper behind while
            // the presentation state says the session failed.
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

    // MARK: - Control handoff

    func enable() -> Bool {
        guard handoffController.enable() else {
            Diagnostics.log("capture start failed: accessibility not granted")
            return false
        }
        return true
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

    func emergencyReturn() {
        handoffController.emergencyReturn()
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
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
                Button("Grant Accessibility…") { model.openAccessibilitySettings() }
            }

            if let edgeSwitchAction = model.edgeSwitchActionTitle {
                Button(edgeSwitchAction) { model.toggleEdgeSwitch() }
            }
            if model.shouldShowDisconnect {
                Button("Disconnect") { model.disconnect() }
            }

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
        .onAppear { model.refreshHostDisplays() }
    }

    @MainActor
    private var statusText: String {
        switch model.sessionState {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .ready:
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
