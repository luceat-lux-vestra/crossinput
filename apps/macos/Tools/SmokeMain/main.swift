import Foundation
import Protocol
import AndroidBridge

/// Dev smoke tool: connects to a real device and exercises the CXI session
/// (HELLO handshake -> LIST_DISPLAYS -> SELECT_DISPLAY -> pointer move -> SHUTDOWN).
/// Usage: swift run cxi-smoke [adbSerial]
@main
struct SmokeMain {
    static func main() async throws {
        let args = CommandLine.arguments.dropFirst()
        let serialArg = args.first { !$0.hasPrefix("--") }
        let uhidMode = args.contains("--uhid")
        let serial: String
        if let serialArg {
            serial = serialArg
        } else {
            serial = await firstAdbSerial()
        }
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

        if uhidMode {
            try await runUhidTest(manager: manager, serial: serial)
        }

        print("SMOKE OK")
        manager.shutdownAndWait()
        exit(0)
    }

    /// UHID end-to-end test: create the virtual mouse, then drive a rectangle
    /// path + a click through HID_REPORT frames (same wire format the app
    /// uses). The cursor sprite should visibly move on the target display.
    static func runUhidTest(manager: ConnectionManager, serial: String) async throws {
        let descriptor = Data([
            0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x01, 0xa1, 0x00, 0x05, 0x09,
            0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01,
            0x81, 0x02, 0x95, 0x01, 0x75, 0x05, 0x81, 0x01, 0x05, 0x01, 0x09, 0x30,
            0x09, 0x31, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x02, 0x81, 0x06,
            0x09, 0x38, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
            0xc0, 0xc0])
        let created = try await manager.request(
            .createHidDevice, payload: Messages.createHidDevice(descriptor: descriptor))
        guard created.type == .hidCreated else {
            print("UHID ERROR: expected HID_CREATED, got \(created.type)")
            return
        }
        let deviceId = try Messages.decodeHidCreated(created.payload)
        print("UHID device created id=\(deviceId)")

        func report(_ buttons: UInt8, _ dx: Int32, _ dy: Int32, _ wheel: UInt8, reqId: UInt32) throws {
            var r = Data()
            r.append(buttons)
            r.append(UInt8(bitPattern: Int8(clamping: dx)))
            r.append(UInt8(bitPattern: Int8(clamping: dy)))
            r.append(wheel)
            try manager.send(CxiFrame(type: .hidReport, requestId: reqId,
                                      payload: Messages.hidReport(deviceId: deviceId, report: r)))
        }

        // Rectangle: right 300, down 200, left 300, up 200 (visible on screen).
        try report(0, 100, 0, 0, reqId: 200); try await Task.sleep(for: .milliseconds(300))
        try report(0, 100, 0, 0, reqId: 201); try await Task.sleep(for: .milliseconds(300))
        try report(0, 100, 0, 0, reqId: 202); try await Task.sleep(for: .milliseconds(300))
        try report(0, 0, 100, 0, reqId: 203); try await Task.sleep(for: .milliseconds(300))
        try report(0, 0, 100, 0, reqId: 204); try await Task.sleep(for: .milliseconds(300))
        try report(0, -100, 0, 0, reqId: 205); try await Task.sleep(for: .milliseconds(300))
        try report(0, -100, 0, 0, reqId: 206); try await Task.sleep(for: .milliseconds(300))
        try report(0, -100, 0, 0, reqId: 207); try await Task.sleep(for: .milliseconds(300))
        try report(0, 0, -100, 0, reqId: 208); try await Task.sleep(for: .milliseconds(300))
        try report(0, 0, -100, 0, reqId: 209); try await Task.sleep(for: .milliseconds(300))
        print("UHID: rectangle path sent")

        // Click: press left button, nudge, release.
        try report(0x01, 0, 0, 0, reqId: 210); try await Task.sleep(for: .milliseconds(200))
        try report(0x01, 20, 10, 0, reqId: 211); try await Task.sleep(for: .milliseconds(200))
        try report(0x00, 0, 0, 0, reqId: 212)
        print("UHID: click sent")

        try await Task.sleep(for: .seconds(1))
        let destroyed = try await manager.request(
            .destroyHidDevice, payload: Messages.destroyHidDevice(deviceId: deviceId))
        print("UHID destroy -> \(destroyed.type)")
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
