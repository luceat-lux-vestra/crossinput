import Foundation

/// Settings store (skeleton) — UserDefaults-backed
public enum Settings {
    public static var displayIdOverride: Int? {
        get { UserDefaults.standard.object(forKey: "displayIdOverride") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "displayIdOverride") }
    }
}
