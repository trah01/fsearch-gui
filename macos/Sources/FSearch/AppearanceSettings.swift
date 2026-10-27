import SwiftUI
import AppKit

enum ThemeColor: String, CaseIterable, Identifiable {
    case blue = "蓝色", purple = "紫色", cyan = "青色", orange = "橙色", rose = "玫红", graphite = "石墨", white = "白色"
    var id: String { rawValue }
    var light: UInt32 {
        switch self {
        case .blue: return 0x286BFA
        case .purple: return 0x7851C8
        case .cyan: return 0x087D95
        case .orange: return 0xAC5A12
        case .rose: return 0xBB3B70
        case .graphite: return 0x586278
        case .white: return 0x454545
        }
    }
    var dark: UInt32 {
        switch self {
        case .blue: return 0x0A84FF
        case .purple: return 0xB49AF5
        case .cyan: return 0x64CADF
        case .orange: return 0xEDAC70
        case .rose: return 0xEF91B7
        case .graphite: return 0xA7B2CA
        case .white: return 0xFFFFFF
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "跟随系统", light = "浅色", dark = "深色"
    var id: String { rawValue }
    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()
    private static let modeKey = "FSearch.appearanceMode"
    static let themeKey = "FSearch.themeColor"

    @Published var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            applyAppearance()
        }
    }
    @Published var theme: ThemeColor {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }

    private init() {
        mode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .system
        theme = Self.savedTheme
    }

    static var savedTheme: ThemeColor {
        ThemeColor(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .blue
    }
    func applyAppearance() { NSApp.appearance = mode.nativeAppearance }
    func reset() { mode = .system; theme = .blue }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case search = "搜索", appearance = "外观", storage = "存储与索引"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .search: return "magnifyingglass"
        case .appearance: return "paintpalette"
        case .storage: return "externaldrive"
        }
    }
}

struct AppSettingsView: View {
    @ObservedObject var permissions: StoragePermissions
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var page: SettingsPage? = .search

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $page) {
                ForEach(SettingsPage.allCases) { page in
                    Label(page.rawValue, systemImage: page.symbol)
                        .padding(.vertical, 5)
                        .tag(page)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.top, 12)
            .frame(width: 148)
            .background(.regularMaterial)
            .accessibilityLabel("设置分类")
            Divider()
            Group {
                switch page {
                case .search, .none: SearchSettingsView()
                case .appearance: AppearanceSettingsView()
                case .storage: StorageSettingsView(permissions: permissions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 540)
        .background(AppAppearance.background)
        .tint(AppAppearance.accent)
        .onAppear { appearance.applyAppearance() }
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("外观")
                    Spacer()
                    Picker("外观", selection: $appearance.mode) {
                        ForEach(AppearanceMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }
            }
            Section {
                HStack {
                    Text("主题色")
                    Spacer()
                    HStack(spacing: 10) {
                        ForEach(ThemeColor.allCases) { theme in
                            themeSwatch(theme)
                        }
                    }
                }.padding(.vertical, 4)

            }
            HStack {
                Spacer()
                Button("恢复默认", action: appearance.reset)
            }.listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(12)
    }

    private func themeSwatch(_ theme: ThemeColor) -> some View {
        let selected = appearance.theme == theme
        return Button { appearance.theme = theme } label: {
            Circle()
                .fill(theme == .white ? Color.white : Color(nsColor: AppAppearance.native(theme.light, theme.dark)))
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 1))
                .padding(4)
                .overlay(Circle().strokeBorder(selected ? Color.primary.opacity(0.85) : .clear, lineWidth: 1.5))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(theme.rawValue)
        .accessibilityLabel(theme.rawValue)
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
