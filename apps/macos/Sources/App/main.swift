import SwiftUI
import Protocol
import AndroidBridge
import InputCapture
import EdgeSwitch
import AppSettings

@main
struct AmpersandApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Ampersand", systemImage: "cursorarrow.motionlines") {
            AppMenu(model: model)
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

    /// Accessed from the capture thread and the reader queue; ConnectionManager
    /// is internally locked (@unchecked Sendable).
    nonisolated(unsafe) var connection: ConnectionManager?
    nonisolated let capture: InputCapture
    nonisolated let switchMachine: EdgeSwitchStateMachine

    init() {
        capture = InputCapture()
        switchMachine = EdgeSwitchStateMachine()
        switchMachine.onStateChange = { [weak self] newState in
            Task { @MainActor in
                self?.state = newState
                self?.apply(state: newState)
            }
        }
        capture.onScreenEdge = { [weak self] edge in
            self?.switchMachine.pointerAtEdge(edge)
        }
        capture.onPointerEvent = { [weak self] event in
            self?.onCapturedEvent(event)
        }
        capture.onSuppressionReleased = { [weak self] in
            Task { @MainActor in
                self?.phase = .ready
            }
        }
    }

    // MARK: - Connection

    func connect(serial: String) async {
        self.serial = serial
        phase = .connecting
        var config = ConnectionManager.Configuration(serial: serial)
        let adbPath = Self.locateAdb()
        if let adbPath { config.adbPath = adbPath }
        let manager = ConnectionManager(configuration: config)
        manager.onEvent = { [weak self] frame in
            self?.handleUnsolicited(frame)
        }
        manager.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.switchMachine.connectionLost()
                if self?.phase == .connecting || self?.phase == .ready {
                    self?.phase = .idle
                }
            }
        }
        connection = manager
        do {
            try await manager.connect()
            switchMachine.connectionBegan()
            let listFrame = try await manager.request(.listDisplays, payload: Data())
            let list = try Messages.decodeDisplayList(listFrame.payload)
            await MainActor.run {
                displays = list
                if let override = AppSettings.Settings.displayIdOverride,
                   let match = list.first(where: { $0.displayId == UInt32(override) }) {
                    select(match)
                } else if let desktop = list.first(where: { $0.isDesktop }) {
                    select(desktop)
                } else if let first = list.first {
                    select(first)
                }
            }
            switchMachine.connectionReady()
            phase = .ready
        } catch {
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
        connection?.shutdownAndWait()
        connection = nil
        switchMachine.deactivate()
        phase = .idle
    }

    func enable() {
        _ = capture.start()
        switchMachine.activate()
    }

    func emergencyReturn() {
        switchMachine.emergencyReturn()
    }

    var isDisconnected: Bool {
        switch phase {
        case .idle, .error: return true
        default: return false
        }
    }

    // MARK: - Pointer plumbing

    private     func apply(state: SwitchState) {
        switch state {
        case .dexActive:
            capture.suppress()
        case .macActive, .recovering, .disabled, .error:
            capture.release()
        default:
            break
        }
    }

    /// Runs on the capture thread (nonisolated): forward pointer events to the helper.
    nonisolated func onCapturedEvent(_ event: PointerEvent) {
        if case let .move(dx, dy) = event.kind {
            switchMachine.pointerMoved(dx: CGFloat(dx), dy: CGFloat(dy))
        }
        send(event: event)
    }

    nonisolated func send(event: PointerEvent) {
        guard let connection else { return }
        switch event.kind {
        case let .move(dx, dy):
            try? connection.send(CxiFrame(type: .pointerMoveRel,
                                          requestId: 1,
                                          payload: Messages.pointerMoveRel(dx: dx, dy: dy)))
        case let .button(button, down):
            try? connection.send(CxiFrame(type: .pointerButton,
                                          requestId: 1,
                                          payload: Messages.pointerButton(button: button, down: down)))
        case let .scroll(horizontal, vertical):
            try? connection.send(CxiFrame(type: .pointerScroll,
                                          requestId: 1,
                                          payload: Messages.pointerScroll(horizontal: horizontal,
                                                                          vertical: vertical)))
        }
    }

    nonisolated func handleUnsolicited(_ frame: CxiFrame) {
        switch frame.type {
        case .logEvent:
            if let log = try? Messages.decodeLogEvent(frame.payload) {
                NSLog("[crossinput:helper] %@", log.message)
            }
        case .fatalError:
            if let fatal = try? Messages.decodeFatalError(frame.payload) {
                Task { @MainActor in
                    phase = .error("helper fatal \(fatal.code): \(fatal.message)")
                    switchMachine.connectionLost()
                }
            }
        default:
            break
        }
    }

    private static func locateAdb() -> String? {
        let candidates = ["/usr/local/bin/adb", "/opt/homebrew/bin/adb", "/usr/bin/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
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
