import Foundation

/// ADB-specific process and endpoint transport. The application/session layer
/// asks this type to launch a binary helper channel or discover endpoints; it
/// does not construct ADB subprocesses or own their byte streams.
public struct AdbTransport: Sendable {
    public let configuredPath: String?

    public struct LaunchConfiguration: Sendable {
        public let serial: String
        public let apkPath: String
        public let helperClass: String
        public let stderrHandler: (@Sendable (String) -> Void)?
        public let terminationHandler: (@Sendable () -> Void)?

        public init(serial: String,
                    apkPath: String,
                    helperClass: String,
                    stderrHandler: (@Sendable (String) -> Void)? = nil,
                    terminationHandler: (@Sendable () -> Void)? = nil) {
            self.serial = serial
            self.apkPath = apkPath
            self.helperClass = helperClass
            self.stderrHandler = stderrHandler
            self.terminationHandler = terminationHandler
        }
    }

    /// The binary-safe stdin/stdout/stderr channel owned by ADB transport.
    /// RemoteSession only consumes the handles and closes the channel; it does
    /// not spawn or terminate the ADB process itself.
    public final class Channel: @unchecked Sendable {
        public let process: Process
        public let input: FileHandle
        public let output: FileHandle
        public let error: FileHandle
        private let lock = NSLock()

        init(process: Process, input: FileHandle, output: FileHandle, error: FileHandle) {
            self.process = process
            self.input = input
            self.output = output
            self.error = error
        }

        public var isRunning: Bool { process.isRunning }

        public func close() {
            lock.withLock {
                if process.isRunning { process.terminate() }
            }
        }
    }

    public init(path: String? = nil) {
        configuredPath = path
    }

    public static func locate() -> String? {
        let candidates = ["/usr/local/bin/adb", "/opt/homebrew/bin/adb", "/usr/bin/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Starts the app_process helper and returns its binary stream channel.
    /// Cleanup of stale helper instances and ADB process ownership stay here.
    public func launch(_ configuration: LaunchConfiguration) throws -> Channel {
        let adb = configuredPath ?? Self.locate() ?? "/usr/local/bin/adb"
        guard FileManager.default.isExecutableFile(atPath: adb) else {
            throw AdbTransportError.adbMissing
        }

        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: adb)
        cleanup.arguments = ["-s", configuration.serial, "shell",
                             "pkill -f 'crossinput-[h]elper.apk' 2>/dev/null || true"]
        try? cleanup.run()
        cleanup.waitUntilExit()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["-s", configuration.serial, "shell", "-T",
                             "app_process", "-cp", configuration.apkPath, configuration.helperClass]
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw AdbTransportError.processSpawnFailed(error.localizedDescription)
        }
        let channel = Channel(process: process,
                               input: inputPipe.fileHandleForWriting,
                               output: outputPipe.fileHandleForReading,
                               error: errorPipe.fileHandleForReading)
        process.terminationHandler = { _ in configuration.terminationHandler?() }
        channel.error.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            configuration.stderrHandler?(String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return channel
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

public enum AdbTransportError: Error, Sendable {
    case adbMissing
    case processSpawnFailed(String)
}
