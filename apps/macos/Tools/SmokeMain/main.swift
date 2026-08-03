import Foundation
import Protocol
import AndroidBridge

/// Dev smoke tool: connects to a real device and exercises the CXI session
/// (HELLO handshake -> LIST_DISPLAYS -> SELECT_DISPLAY -> pointer move -> SHUTDOWN).
/// Usage: swift run cxi-smoke [adbSerial]
@main
struct SmokeMain {
    static func main() async throws {
        let serial = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : await firstAdbSerial()
        guard !serial.isEmpty else {
            print("ERROR: no adb device connected")
            exit(1)
        }
        print("serial: \(serial)")

        var config = ConnectionManager.Configuration(serial: serial)
        config.adbPath = locateAdb() ?? "/opt/homebrew/bin/adb"
        let manager = ConnectionManager(configuration: config)

        try await manager.connect()
        print("HELLO handshake OK")

        let listFrame = try await manager.request(.listDisplays, payload: Data())
        let displays = try Messages.decodeDisplayList(listFrame.payload)
        print("displays: \(displays.count)")
        for d in displays {
            print("  id=\(d.displayId) type=\(d.type) state=\(d.state) " +
                  "\(d.width)x\(d.height) name='\(d.name)' uniqueId='\(d.uniqueId)' desktop=\(d.isDesktop)")
        }
        guard let target = displays.first(where: { $0.isDesktop }) ?? displays.first else {
            print("ERROR: no display to select")
            manager.shutdownAndWait()
            exit(1)
        }
        let selectFrame = try await manager.request(
            .selectDisplay, payload: Messages.selectDisplay(displayId: target.displayId))
        guard selectFrame.type == .displayChanged else {
            print("ERROR: expected DISPLAY_CHANGED, got \(selectFrame.type)")
            manager.shutdownAndWait()
            exit(1)
        }
        let selected = try Messages.decodeDisplay(selectFrame.payload)
        print("SELECT_DISPLAY(\(target.displayId)) -> \(selected.name)")

        // A couple of small relative moves; fire-and-forget frames.
        try manager.send(CxiFrame(type: .pointerMoveRel, requestId: 100,
                                  payload: Messages.pointerMoveRel(dx: 40, dy: 20)))
        try manager.send(CxiFrame(type: .pointerMoveRel, requestId: 101,
                                  payload: Messages.pointerMoveRel(dx: -40, dy: -20)))

        let pong = try await manager.request(.ping, payload: Data())
        print("PING -> \(pong.type)")

        print("SMOKE OK")
        manager.shutdownAndWait()
        exit(0)
    }

    static func firstAdbSerial() async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: locateAdb() ?? "/opt/homebrew/bin/adb")
        process.arguments = ["devices"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst() {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2, parts[1] == "device" { return String(parts[0]) }
        }
        return ""
    }

    static func locateAdb() -> String? {
        ["/usr/local/bin/adb", "/opt/homebrew/bin/adb", "/usr/bin/adb"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
