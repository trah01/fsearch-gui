import SwiftUI

enum ResultLoadingMode: String, CaseIterable, Identifiable {
    case onDemand = "on-demand", full = "full"
    var id: String { rawValue }
    var title: String { self == .onDemand ? "按需模式" : "全量模式" }
}

final class SearchSettings: ObservableObject {
    static let shared = SearchSettings()
    private static let modeKey = "FSearch.resultLoadingMode"

    @Published var loadingMode: ResultLoadingMode {
        didSet { UserDefaults.standard.set(loadingMode.rawValue, forKey: Self.modeKey) }
    }

    private init() {
        loadingMode = ResultLoadingMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .onDemand
    }
}

struct SearchSettingsView: View {
    @ObservedObject private var settings = SearchSettings.shared
    var body: some View {
        Form {
            Section {
                HStack {
                    Text("加载模式")
                    Spacer()
                    Picker("加载模式", selection: $settings.loadingMode) {
                        ForEach(ResultLoadingMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            } footer: {
                Text(settings.loadingMode == .onDemand
                    ? "先显示最多 3000 项，滚动时继续加载，适合搜索大量文件，内存占用较低。筛选和排序对全部匹配结果生效。"
                    : "一次加载全部匹配结果，适合完整浏览；文件较多时，需要更长时间和更多内存。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(12)
    }
}
