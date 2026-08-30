import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func utcStamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

func displayMetadata() -> [[String: Any]] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.map { id in
        let bounds = CGDisplayBounds(id)
        let mode = CGDisplayCopyDisplayMode(id)
        return [
            "display_id": id,
            "main": id == CGMainDisplayID(),
            "online": CGDisplayIsOnline(id) != 0,
            "builtin": CGDisplayIsBuiltin(id) != 0,
            "bounds": [
                "x": Int(bounds.origin.x),
                "y": Int(bounds.origin.y),
                "width": Int(bounds.size.width),
                "height": Int(bounds.size.height),
            ],
            "pixel_width": mode.map { $0.pixelWidth } ?? Int(CGDisplayPixelsWide(id)),
            "pixel_height": mode.map { $0.pixelHeight } ?? Int(CGDisplayPixelsHigh(id)),
        ] as [String: Any]
    }
}

func workspaceMetadata() -> [String: Any] {
    guard let app = NSWorkspace.shared.frontmostApplication else { return [:] }
    return [
        "frontmost": [
            "pid": app.processIdentifier,
            "bundle_id": app.bundleIdentifier ?? "unknown",
            "name": app.localizedName ?? "unknown",
            "is_active": app.isActive,
        ],
    ]
}

let value: [String: Any] = [
    "schema": 1,
    "captured_at_utc": utcStamp(),
    "displays": displayMetadata(),
    "workspace": workspaceMetadata(),
    "accessibility": ["trusted": AXIsProcessTrusted()],
]
guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
      let output = String(data: data, encoding: .utf8) else {
    exit(3)
}
print(output)
