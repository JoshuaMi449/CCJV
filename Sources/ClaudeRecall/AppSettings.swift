import SwiftUI
import Combine

enum AccentTheme: String, CaseIterable, Identifiable {
    case orange
    case blue
    case green
    case purple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .orange: return "橙色"
        case .blue: return "蓝色"
        case .green: return "绿色"
        case .purple: return "紫色"
        }
    }

    var primary: Color {
        switch self {
        case .orange: return Color(hex: 0xFF8F45)
        case .blue: return Color(hex: 0x6EA8FF)
        case .green: return Color(hex: 0x45D6A0)
        case .purple: return Color(hex: 0xB68CFF)
        }
    }

    var deep: Color {
        switch self {
        case .orange: return Color(hex: 0xF25A1C)
        case .blue: return Color(hex: 0x2F6BDA)
        case .green: return Color(hex: 0x159F74)
        case .purple: return Color(hex: 0x7B4DDF)
        }
    }

    var light: Color {
        switch self {
        case .orange: return Color(hex: 0xFFC46B)
        case .blue: return Color(hex: 0xA8C9FF)
        case .green: return Color(hex: 0x9AF0D1)
        case .purple: return Color(hex: 0xD8C2FF)
        }
    }
}

final class AppSettings: ObservableObject {
    static let darkKey = "claudeRecall.darkMode"
    static let accentKey = "claudeRecall.accent"
    static let archiveLimitKey = "claudeRecall.archiveLimitBytes"
    static let defaultArchiveLimit: Int64 = 1_073_741_824 // 1 GB; 0 = 不限
    private static let legacyBundleIdentifier = "com.local.ClaudeRecall"

    private static var legacyDefaults: UserDefaults? {
        UserDefaults(suiteName: legacyBundleIdentifier)
    }

    private static func migrateLegacyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let legacy = legacyDefaults
        for key in [darkKey, accentKey, archiveLimitKey] {
            if defaults.object(forKey: key) == nil,
               let value = legacy?.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
    }

    static var archiveLimitBytes: Int64 {
        migrateLegacyDefaultsIfNeeded()
        let value = UserDefaults.standard.object(forKey: archiveLimitKey) as? NSNumber
        return value?.int64Value ?? defaultArchiveLimit
    }

    static func setArchiveLimit(_ bytes: Int64) {
        UserDefaults.standard.set(NSNumber(value: max(0, bytes)), forKey: archiveLimitKey)
    }

    @Published private(set) var darkMode: Bool
    @Published private(set) var accent: AccentTheme
    @Published private(set) var revision = 0

    init() {
        Self.migrateLegacyDefaultsIfNeeded()
        let defaults = UserDefaults.standard
        darkMode = defaults.object(forKey: Self.darkKey) as? Bool ?? false
        accent = AccentTheme(rawValue: defaults.string(forKey: Self.accentKey) ?? "") ?? .blue
    }

    func setDark(_ value: Bool) {
        guard value != darkMode else { return }
        darkMode = value
        UserDefaults.standard.set(value, forKey: Self.darkKey)
        revision += 1
    }

    func setAccent(_ value: AccentTheme) {
        guard value != accent else { return }
        accent = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.accentKey)
        revision += 1
    }
}
