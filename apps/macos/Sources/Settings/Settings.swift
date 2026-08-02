import Foundation

/// 설정 저장소 (스켈레톤) — UserDefaults 기반
public enum Settings {
    public static var displayIdOverride: Int? {
        get { UserDefaults.standard.object(forKey: "displayIdOverride") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "displayIdOverride") }
    }
}
