import AppKit
import Foundation

// Public NSWorkspace notifications only. This observer never installs an
// input monitor, synthesizes events, changes focus, or reads event payloads.

let outputLock = NSLock()

func timestamp() -> (String, Int64, Int64) {
    let epoch = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
    let date = Date(timeIntervalSince1970: TimeInterval(epoch) / 1_000_000_000)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return (formatter.string(from: date), epoch, Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
}

func frontmostMetadata() -> [String: Any] {
    guard let app = NSWorkspace.shared.frontmostApplication else { return [:] }
    return [
        "pid": app.processIdentifier,
        "bundle_id": app.bundleIdentifier ?? "unknown",
        "name": app.localizedName ?? "unknown",
        "is_active": app.isActive,
    ]
}

func emit(_ event: String, note: Notification? = nil) {
    let (stamp, epoch, monotonic) = timestamp()
    var value: [String: Any] = [
        "schema": 1,
        "timestamp_utc": stamp,
        "epoch_ns": epoch,
        "monotonic_ns": monotonic,
        "event": event,
        "frontmost": frontmostMetadata(),
    ]
    if let app = note?.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        value["application"] = [
            "pid": app.processIdentifier,
            "bundle_id": app.bundleIdentifier ?? "unknown",
            "name": app.localizedName ?? "unknown",
        ]
    }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    outputLock.lock()
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
    outputLock.unlock()
}

let workspaceCenter = NSWorkspace.shared.notificationCenter
let notifications: [(Notification.Name, String)] = [
    (NSWorkspace.didActivateApplicationNotification, "application_activated"),
    (NSWorkspace.didDeactivateApplicationNotification, "application_deactivated"),
    (NSWorkspace.didLaunchApplicationNotification, "application_launched"),
    (NSWorkspace.didTerminateApplicationNotification, "application_terminated"),
    (NSWorkspace.activeSpaceDidChangeNotification, "active_space_changed"),
]
var observerTokens: [NSObjectProtocol] = []
for (name, label) in notifications {
    observerTokens.append(workspaceCenter.addObserver(forName: name, object: nil, queue: OperationQueue.main) { note in
        emit(label, note: note)
    })
}

emit("observer_started")
RunLoop.main.run()

for token in observerTokens {
    workspaceCenter.removeObserver(token)
}
