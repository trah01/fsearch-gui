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
                Text("高级筛选").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("重置", action: reset)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    Text("文件名")
                    HStack(spacing: 8) {
                        Picker("匹配方式", selection: $filters.nameMatch) {
                            ForEach(FileNameMatch.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 112)
                        TextField("文件名", text: $filters.name).textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    Text("文件类型")
                    Picker("文件类型", selection: $category) {
                        ForEach(FileCategory.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden()
                }
                if category == .custom {
                    GridRow {
                        Text("文件后缀")
                        TextField("pdf, docx, xlsx", text: $extensions).textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    Text("文件大小")
                    HStack(spacing: 8) {
                        TextField("最小", text: $filters.minimumSize).textFieldStyle(.roundedBorder)
                        Text("至").foregroundStyle(.secondary)
                        TextField("最大", text: $filters.maximumSize).textFieldStyle(.roundedBorder)
                        Picker("大小单位", selection: $filters.sizeUnit) {
                            ForEach(FileSizeUnit.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 70)
                    }
                }
                GridRow {
                    Text("修改时间")
                    HStack(spacing: 8) {
                        Picker("修改时间", selection: $time) {
                            ForEach(AdvancedTimeChoice.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden()
                        if time == .custom {
                            Text("过去")
                            TextField("天数", text: $filters.modifiedDays).textFieldStyle(.roundedBorder).frame(width: 60)
                            Text("天")
                        }
                    }
                }
                GridRow {
                    Text("搜索位置")
                    HStack(spacing: 8) {
                        TextField("这台 Mac", text: $scope).textFieldStyle(.roundedBorder)
                        Button("选择…", action: chooseFolder)
                    }
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用", action: apply).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 13))
        .padding(20).frame(width: 520)
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
        panel.title = "选择搜索位置"
        panel.prompt = "选择"
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
                throw ClientError.message("文件夹不支持文件大小筛选，请调整条件。")
            }
            let scope = (scope.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            if !scope.isEmpty {
                var directory: ObjCBool = false
                guard scope.hasPrefix("/"), FileManager.default.fileExists(atPath: scope, isDirectory: &directory), directory.boolValue else {
                    throw ClientError.message("请选择有效的文件夹，或输入完整的文件夹路径。")
                }
            }
            model.applyAdvancedFilters(filters, category: category, extensions: extensions, time: time.filter, scope: scope)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
