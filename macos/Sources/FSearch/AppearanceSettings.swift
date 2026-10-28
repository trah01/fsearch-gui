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

    @Published var compactRows: Bool {
        didSet { UserDefaults.standard.set(compactRows, forKey: "FSearch.compactRows") }
    }

    private init() {
        compactRows = UserDefaults.standard.bool(forKey: "FSearch.compactRows")
        mode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .system
        theme = Self.savedTheme
    }

    static var savedTheme: ThemeColor {
        ThemeColor(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .blue
    }
    func applyAppearance() { NSApp.appearance = mode.nativeAppearance }
    func reset() { mode = .system; theme = .blue; compactRows = false }
}

struct AppSettingsView: View {
    @ObservedObject var permissions: StoragePermissions
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            SearchSettingsView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            StorageSettingsView(permissions: permissions)
                .tabItem { Label("索引", systemImage: "externaldrive") }
            AppearanceSettingsView()
                .tabItem { Label("外观", systemImage: "paintpalette") }
        }
        .padding(.top, 8)
        .frame(width: 700, height: 560)
        .background(AppAppearance.background)
        .tint(AppAppearance.accent)
        .onAppear { appearance.applyAppearance() }
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @AppStorage("FSearch.showSidebar") private var showSidebar = true
    @AppStorage("FSearch.showInspector") private var showInspector = true

    var body: some View {
        SettingsPane {
            VStack(spacing: 12) {
                SettingsRow("外观") {
                    Picker("外观", selection: $appearance.mode) {
                        ForEach(AppearanceMode.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 280)
                }
                SettingsRow("强调色") {
                    HStack(spacing: 8) {
                        ForEach(ThemeColor.allCases) { themeSwatch($0) }
                    }
                }
            }
            Divider()
            VStack(spacing: 12) {
                SettingsRow("列表行距") {
                    Picker("列表行距", selection: $appearance.compactRows) {
                        Text("标准").tag(false)
                        Text("紧凑").tag(true)
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 180)
                }
                SettingsRow("显示左侧栏") {
                    Toggle("显示左侧栏", isOn: $showSidebar).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow("显示文件详情") {
                    Toggle("显示文件详情", isOn: $showInspector).labelsHidden().toggleStyle(.switch)
                }
            }
            HStack {
                Spacer()
                Button("恢复外观默认设置") { appearance.reset(); showSidebar = true; showInspector = true }
            }
        }
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
