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
            Picker("加载模式", selection: $settings.loadingMode) {
                ForEach(ResultLoadingMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .padding(24)
    }
}
