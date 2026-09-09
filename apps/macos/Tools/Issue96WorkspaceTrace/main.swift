import AppKit
import Foundation

@MainActor
final class WorkspaceTraceLogger {
    private let fileHandle: FileHandle?
    let logPath: String

    init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Ampersand", isDirectory: true)
        let url = directory.appendingPathComponent("issue96-workspace-trace.log")
        logPath = url.path

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            fileHandle = handle
        } catch {
            fileHandle = nil
        }
    }

    func log(_ event: String, application: NSRunningApplication? = nil) {
        let monotonic = DispatchTime.now().uptimeNanoseconds
        let frontmost = NSWorkspace.shared.frontmostApplication

        var fields: [String: String] = [:]
        fields["observer_pid"] = String(ProcessInfo.processInfo.processIdentifier)

        if let application {
            fields["observed_pid"] = String(application.processIdentifier)
            fields["observed_bundle"] = application.bundleIdentifier ?? "none"
            fields["observed_name"] = application.localizedName ?? "none"
            fields["observed_active"] = application.isActive ? "true" : "false"
        } else {
            fields["observed_pid"] = "none"
            fields["observed_bundle"] = "none"
            fields["observed_name"] = "none"
            fields["observed_active"] = "none"
        }

        if let frontmost {
            fields["frontmost_pid"] = String(frontmost.processIdentifier)
            fields["frontmost_bundle"] = frontmost.bundleIdentifier ?? "none"
            fields["frontmost_name"] = frontmost.localizedName ?? "none"
        } else {
            fields["frontmost_pid"] = "none"
            fields["frontmost_bundle"] = "none"
            fields["frontmost_name"] = "none"
        }

        let stableFields = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.token($0.value))" }
            .joined(separator: " ")
        let line = "ISSUE96_WORKSPACE monotonic_ns=\(monotonic) event=\(event) \(stableFields)\n"
        guard let data = line.data(using: String.Encoding.utf8) else { return }
        fileHandle?.write(data)
    }

    private static func token(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\t", with: "_")
    }
}

@MainActor
final class WorkspaceTraceObserver: NSObject {
    private let logger: WorkspaceTraceLogger
    private let center = NSWorkspace.shared.notificationCenter

    init(logger: WorkspaceTraceLogger) {
        self.logger = logger
        super.init()
    }

    func start() {
        center.addObserver(
            self,
            selector: #selector(workspaceNotification(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared
        )
        center.addObserver(
            self,
            selector: #selector(workspaceNotification(_:)),
            name: NSWorkspace.didDeactivateApplicationNotification,
            object: NSWorkspace.shared
        )
        logger.log("trace-started")
    }

    @objc private func workspaceNotification(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication

        switch notification.name {
        case NSWorkspace.didActivateApplicationNotification:
            logger.log("workspace-did-activate-application", application: application)
        case NSWorkspace.didDeactivateApplicationNotification:
            logger.log("workspace-did-deactivate-application", application: application)
        default:
            logger.log("workspace-unexpected-notification", application: application)
        }
    }
}

@main
struct Issue96WorkspaceTraceMain {
    @MainActor
    static func main() {
        let logger = WorkspaceTraceLogger()
        let observer = WorkspaceTraceObserver(logger: logger)
        observer.start()

        print("ISSUE96_WORKSPACE_TRACE_READY path=\(logger.logPath)")
        RunLoop.main.run()
        withExtendedLifetime(observer) {}
    }
}
