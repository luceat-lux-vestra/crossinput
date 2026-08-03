import Foundation

/// Settings store (skeleton) — UserDefaults-backed
public enum Settings {
    public static var displayIdOverride: Int? {
        get { UserDefaults.standard.object(forKey: "displayIdOverride") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "displayIdOverride") }
    }

    /// Per-display Android edge, e.g. displayID "3" -> "left".
    private static let edgeKey = "androidEdgeByDisplay"

    public static func androidEdge(displayID: UInt32) -> String? {
        guard let dict = UserDefaults.standard.dictionary(forKey: edgeKey) as? [String: String] else { return nil }
        return dict[String(displayID)]
    }

    public static func setAndroidEdge(_ edge: String?, displayID: UInt32) {
        var dict = (UserDefaults.standard.dictionary(forKey: edgeKey) as? [String: String]) ?? [:]
        if let edge {
            dict[String(displayID)] = edge
        } else {
            dict.removeValue(forKey: String(displayID))
        }
        UserDefaults.standard.set(dict, forKey: edgeKey)
    }
}
