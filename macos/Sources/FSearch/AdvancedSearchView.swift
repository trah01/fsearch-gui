import AppKit
import SwiftUI

private enum AdvancedTimeChoice: String, CaseIterable, Identifiable {
    case any = "任何时间", today = "今天", week = "过去 7 天", month = "过去 30 天", custom = "自定义天数"
    var id: String { rawValue }
    var filter: TimeFilter {
        switch self {
        case .any, .custom: return .any
        case .today: return .today
        case .week: return .week
        case .month: return .month
        }
    }
}

struct AdvancedSearchView: View {
    @ObservedObject private var language = LanguageSettings.shared
    @ObservedObject var model: SearchModel
    @ObservedObject private var appearance = AppearanceSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var filters: AdvancedSearchFilters
    @State private var category: FileCategory
    @State private var extensions: String
    @State private var time: AdvancedTimeChoice
    @State private var scope: String
    @State private var error: String?

    init(model: SearchModel) {
        self.model = model
        var filters = model.advancedFilters
        if !filters.hasSize {
            if model.sizeFilter == .large { filters.minimumSize = "100"; filters.sizeUnit = .mb }
            if model.sizeFilter == .small { filters.maximumSize = "1"; filters.sizeUnit = .mb }
        }
        _filters = State(initialValue: filters)
        _category = State(initialValue: model.category)
        _extensions = State(initialValue: model.extensions)
        _time = State(initialValue: filters.hasTime ? .custom : AdvancedTimeChoice(rawValue: model.timeFilter.rawValue) ?? .any)
        _scope = State(initialValue: model.scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L("高级筛选")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(L("重置"), action: reset)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    Text(L("文件名"))
                    HStack(spacing: 8) {
                        Picker(L("匹配方式"), selection: $filters.nameMatch) {
                            ForEach(FileNameMatch.allCases) { Text($0.rawValue.localized).tag($0) }
                        }.labelsHidden().frame(width: Localization.languageCode == "en" ? 148 : 112)
                        TextField(L("文件名"), text: $filters.name).textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    Text(L("文件类型"))
                    Picker(L("文件类型"), selection: $category) {
                        ForEach(FileCategory.allCases) { Text($0.rawValue.localized).tag($0) }
                    }.labelsHidden()
                }
                if category == .custom {
                    GridRow {
                        Text(L("文件后缀"))
                        TextField("pdf, docx, xlsx", text: $extensions).textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    Text(L("文件大小"))
                    HStack(spacing: 8) {
                        TextField(L("最小"), text: $filters.minimumSize).textFieldStyle(.roundedBorder)
                        Text(L("至")).foregroundStyle(.secondary)
                        TextField(L("最大"), text: $filters.maximumSize).textFieldStyle(.roundedBorder)
                        Picker(L("大小单位"), selection: $filters.sizeUnit) {
                            ForEach(FileSizeUnit.allCases) { Text($0.rawValue.localized).tag($0) }
                        }.labelsHidden().frame(width: 70)
                    }
                }
                GridRow {
                    Text(L("修改时间"))
                    HStack(spacing: 8) {
                        Picker(L("修改时间"), selection: $time) {
                            ForEach(AdvancedTimeChoice.allCases) { Text($0.rawValue.localized).tag($0) }
                        }.labelsHidden()
                        if time == .custom {
                            Text(L("过去"))
                            TextField(L("天数"), text: $filters.modifiedDays).textFieldStyle(.roundedBorder).frame(width: 60)
                            Text(L("天"))
                        }
                    }
                }
                GridRow {
                    Text(L("搜索位置"))
                    HStack(spacing: 8) {
                        TextField(L("这台 Mac"), text: $scope).textFieldStyle(.roundedBorder)
                        Button(L("选择…"), action: chooseFolder)
                    }
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Apply"), action: apply).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 13))
        .padding(20).frame(width: Localization.languageCode == "en" ? 580 : 520)
        .background(AppAppearance.background)
        .foregroundStyle(AppAppearance.text)
        .tint(AppAppearance.accent)
    }

    private func reset() {
        filters = AdvancedSearchFilters()
        category = .all
        extensions = ""
        time = .any
        scope = ""
        error = nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = L("选择搜索位置")
        panel.prompt = L("选择")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        if !scope.isEmpty { panel.directoryURL = URL(fileURLWithPath: (scope as NSString).expandingTildeInPath) }
        if panel.runModal() == .OK, let url = panel.url { scope = url.path }
    }

    private func apply() {
        do {
            var filters = filters
            if time != .custom { filters.modifiedDays = "" }
            _ = try filters.requestFields()
            let extensions = category == .custom ? try AdvancedSearchFilters.normalizedExtensions(extensions) : ""
            if category == .folder && filters.hasSize {
                throw ClientError.message(L("文件夹不支持文件大小筛选，请调整条件。"))
            }
            let scope = (scope.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            if !scope.isEmpty {
                var directory: ObjCBool = false
                guard scope.hasPrefix("/"), FileManager.default.fileExists(atPath: scope, isDirectory: &directory), directory.boolValue else {
                    throw ClientError.message(L("请选择有效的文件夹，或输入完整的文件夹路径。"))
                }
            }
            model.applyAdvancedFilters(filters, category: category, extensions: extensions, time: time.filter, scope: scope)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
