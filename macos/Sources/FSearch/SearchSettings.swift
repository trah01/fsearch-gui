import AppKit
import SwiftUI

extension Notification.Name {
    static let searchDefaultsChanged = Notification.Name("FSearch.searchDefaultsChanged")
}

enum ResultLoadingMode: String, CaseIterable, Identifiable {
    case onDemand = "on-demand", full = "full"
    var id: String { rawValue }
    var title: String { self == .onDemand ? "滚动时继续加载" : "一次加载全部" }
}

enum DefaultSearchSort: String, CaseIterable, Identifiable {
    case relevance, name, modified, size
    var id: String { rawValue }
    var title: String {
        switch self {
        case .relevance: return "相关性"
        case .name: return "文件名"
        case .modified: return "最近修改"
        case .size: return "文件从大到小"
        }
    }
    var sort: ResultSort? {
        switch self {
        case .relevance: return nil
        case .name: return ResultSort(column: .name, ascending: true)
        case .modified: return ResultSort(column: .modified, ascending: false)
        case .size: return ResultSort(column: .size, ascending: false)
        }
    }
}

final class SearchSettings: ObservableObject {
    static let shared = SearchSettings()
    private static let modeKey = "FSearch.resultLoadingMode"
    @Published var loadingMode: ResultLoadingMode {
        didSet { UserDefaults.standard.set(loadingMode.rawValue, forKey: Self.modeKey) }
    }
    @Published var defaultScope: String {
        didSet { saveDefault(defaultScope, key: "scope") }
    }
    @Published var defaultSort: DefaultSearchSort {
        didSet { saveDefault(defaultSort.rawValue, key: "sort") }
    }
    @Published var directoriesFirst: Bool {
        didSet { saveDefault(directoriesFirst, key: "directoriesFirst") }
    }
    @Published var rememberFilters: Bool {
        didSet { UserDefaults.standard.set(rememberFilters, forKey: "FSearch.rememberFilters") }
    }

    private init() {
        let defaults = UserDefaults.standard
        loadingMode = ResultLoadingMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .onDemand
        defaultScope = defaults.string(forKey: "FSearch.default.scope") ?? ""
        defaultSort = DefaultSearchSort(rawValue: defaults.string(forKey: "FSearch.default.sort") ?? "") ?? .relevance
        directoriesFirst = defaults.bool(forKey: "FSearch.default.directoriesFirst")
        rememberFilters = defaults.bool(forKey: "FSearch.rememberFilters")
    }

    private func saveDefault(_ value: Any, key: String) {
        UserDefaults.standard.set(value, forKey: "FSearch.default.\(key)")
        NotificationCenter.default.post(name: .searchDefaultsChanged, object: nil)
    }

    func chooseDefaultFolder() {
        let panel = NSOpenPanel()
        panel.title = "默认搜索位置"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url { defaultScope = url.path }
    }
}

struct SearchSettingsView: View {
    @ObservedObject private var settings = SearchSettings.shared

    var body: some View {
        SettingsPane {
            VStack(spacing: 12) {
                SettingsRow("默认搜索位置") {
                    Text(settings.defaultScope.isEmpty ? "这台 Mac" : (settings.defaultScope as NSString).lastPathComponent)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(settings.defaultScope)
                    Menu("更改…") {
                        Button("这台 Mac") { settings.defaultScope = "" }
                        Button("选择文件夹…", action: settings.chooseDefaultFolder)
                    }.fixedSize()
                }
                SettingsRow("默认排序") {
                    Picker("默认排序", selection: $settings.defaultSort) {
                        ForEach(DefaultSearchSort.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 180)
                }
                SettingsRow("文件夹优先") {
                    Toggle("文件夹优先", isOn: $settings.directoriesFirst).labelsHidden().toggleStyle(.switch)
                }
            }
            Divider()
            SettingsRow("记住上次筛选") {
                Toggle("记住上次筛选", isOn: $settings.rememberFilters).labelsHidden().toggleStyle(.switch)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                SettingsRow("搜索结果加载") {
                    Picker("搜索结果加载", selection: $settings.loadingMode) {
                        ForEach(ResultLoadingMode.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 180)
                }
                SettingsNote(settings.loadingMode == .onDemand
                    ? "先显示 3000 项，滚动时继续加载。筛选和排序对全部匹配结果生效。"
                    : "一次显示全部匹配结果，内存占用可能超过 1 GB，不推荐开启。建议选择“滚动时继续加载”。")
            }
        }
    }
}
