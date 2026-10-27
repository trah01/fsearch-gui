import SwiftUI
import AppKit

enum ThemeColor: String, CaseIterable, Identifiable {
    case blue = "蓝色", purple = "紫色", cyan = "青色", orange = "橙色", rose = "玫红", graphite = "石墨"
    var id: String { rawValue }
    var light: UInt32 {
        switch self {
        case .blue: return 0x286BFA
        case .purple: return 0x7851C8
        case .cyan: return 0x087D95
        case .orange: return 0xAC5A12
        case .rose: return 0xBB3B70
        case .graphite: return 0x586278
        }
    }
    var dark: UInt32 {
        switch self {
        case .blue: return 0x6E9EFF
        case .purple: return 0xB49AF5
        case .cyan: return 0x64CADF
        case .orange: return 0xEDAC70
        case .rose: return 0xEF91B7
        case .graphite: return 0xA7B2CA
        }
    }
}

final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()
    static let themeKey = "FSearch.themeColor"
    static let transparencyKey = "FSearch.transparency"
    static let defaultTransparency = 0.42

    @Published var theme: ThemeColor {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }
    @Published var transparency: Double {
        didSet { UserDefaults.standard.set(transparency, forKey: Self.transparencyKey) }
    }

    private init() {
        theme = Self.savedTheme
        transparency = Self.savedTransparency
    }

    static var savedTheme: ThemeColor {
        ThemeColor(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .blue
    }
    static var savedTransparency: Double {
        let value = UserDefaults.standard.object(forKey: transparencyKey) as? Double ?? defaultTransparency
        return value.isFinite ? min(0.8, max(0, value)) : defaultTransparency
    }
    func reset() { theme = .blue; transparency = Self.defaultTransparency }
}

struct AppSettingsView: View {
    @ObservedObject var permissions: StoragePermissions
    @ObservedObject private var appearance = AppearanceSettings.shared
    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("外观", systemImage: "paintpalette") }
            StorageSettingsView(permissions: permissions)
                .tabItem { Label("存储与索引", systemImage: "externaldrive") }
        }.frame(width: 808, height: 600).tint(AppAppearance.accent)
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    var body: some View {
        Form {
            Picker("主题色", selection: $appearance.theme) {
                ForEach(ThemeColor.allCases) { theme in Text(theme.rawValue).tag(theme) }
            }
            HStack(spacing: 12) {
                Slider(value: $appearance.transparency, in: 0...0.8, step: 0.01) {
                    Text("透明度")
                }.accessibilityValue(appearance.transparency.formatted(.percent.precision(.fractionLength(0))))
                Text(appearance.transparency.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
            HStack {
                Spacer()
                Button("恢复默认", action: appearance.reset)
            }
        }
        .formStyle(.grouped)
        .tint(AppAppearance.accent)
        .padding(24)
    }
}
