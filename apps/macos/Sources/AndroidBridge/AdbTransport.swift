import Foundation

/// ADB-specific discovery and reconnect operations. The application/session
/// layer asks this transport for endpoints; it does not construct ADB
/// subprocesses or parse ADB output itself.
public struct AdbTransport: Sendable {
    public let configuredPath: String?

    public init(path: String? = nil) {
        configuredPath = path
    }

    public static func locate() -> String? {
        let candidates = ["/usr/local/bin/adb", "/opt/homebrew/bin/adb", "/usr/bin/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func reconnect(serial: String) {
        guard serial.contains(":") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["connect", serial]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("[crossinput] adb connect failed: %@", error.localizedDescription)
        }
    }

    /// Returns the remembered endpoint first, followed by any mDNS endpoint.
    /// The endpoint is opaque to the session layer; ADB owns its syntax.
    public func discoverWirelessEndpoints(target: String) -> [String] {
        var endpoints: [String] = []
        if !target.isEmpty { endpoints.append(target) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["mdns", "services"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            for line in lines where line.contains("_adb-tls-connect._tcp") {
                guard let endpoint = line.split(whereSeparator: { $0.isWhitespace }).last else { continue }
                let value = String(endpoint)
                guard value.contains(":") else { continue }
                if !endpoints.contains(value) { endpoints.append(value) }
            }
        } catch {
            NSLog("[crossinput] adb mdns services failed: %@", error.localizedDescription)
        }
        return endpoints
    }

    public func firstConnectedSerial() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
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
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst() {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2, parts[1] == "device" {
                return String(parts[0])
            }
        }
        return ""
    }

    private var adbPath: String {
        configuredPath ?? Self.locate() ?? "/usr/local/bin/adb"
    }
}
