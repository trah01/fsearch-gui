import SwiftUI
import AppKit

struct SearchSidebar: View {
    @ObservedObject var model: SearchModel
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var volumes: [URL] = []
    private let cloud = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(FileCategory.sidebar) { category in
                    row(category.rawValue, symbol: category.symbol, selected: model.category == category) {
                        model.category = category
                    }
                }
                section("位置")
                row("这台 Mac", symbol: "desktopcomputer", selected: model.scope.isEmpty) { model.scope = "" }
                if FileManager.default.fileExists(atPath: cloud.path) {
                    row("iCloud 云盘", symbol: "icloud", selected: model.scope == cloud.path) { model.scope = cloud.path }
                }
                ForEach(volumes, id: \.path) { volume in
                    row(volume.lastPathComponent, symbol: "externaldrive", selected: model.scope == volume.path) {
                        model.scope = volume.path
                    }
                }
                row("选择文件夹…", symbol: "folder.badge.plus", selected: false, action: model.chooseFolder)
                if !model.scope.isEmpty {
                    HStack(spacing: 6) {
                        Text(model.scope).font(.system(size: 11)).lineLimit(2).truncationMode(.middle).help(model.scope)
                        Button { model.scope = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("清除位置限制")
                    }
                    .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6)
                }
                section("快捷筛选")
                row("最近修改", symbol: "clock", selected: model.timeFilter == .week && model.sort?.column == .modified) {
                    model.timeFilter = .week
                    model.setSort(ResultSort(column: .modified, ascending: false))
                }
                row("大文件（>100 MB）", symbol: "doc", selected: model.sizeFilter == .large) {
                    model.sizeFilter = model.sizeFilter == .large ? .any : .large
                }
                row("小文件（<1 MB）", symbol: "doc", selected: model.sizeFilter == .small) {
                    model.sizeFilter = model.sizeFilter == .small ? .any : .small
                }
                ForEach([TimeFilter.today, .week, .month]) { filter in
                    row(filter.rawValue, symbol: "calendar", selected: model.timeFilter == filter) {
                        model.timeFilter = model.timeFilter == filter ? .any : filter
                    }
                }
            }
            .padding(.leading, 12).padding(.trailing, 22).padding(.vertical, 4)
        }
        .padding(.vertical, 8)
        .padding(.bottom, 2)
        .onAppear(perform: refreshVolumes)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in refreshVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in refreshVolumes() }
    }

    private func section(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(AppAppearance.muted)
        }.padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 6)
    }

    private func row(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(iconColor(symbol))
                    .frame(width: 20)
                Text(title).font(.system(size: AppAppearance.sidebarFontSize, weight: selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: AppAppearance.sidebarRowHeight)
            .background(selected ? AppAppearance.sidebarSelection : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func iconColor(_ symbol: String) -> Color {
        if symbol == "music.note" { return Color(red: 0.94, green: 0.30, blue: 0.44) }
        return FileCategory.sidebar.contains(where: { $0.symbol == symbol }) ? AppAppearance.accent : AppAppearance.text.opacity(0.75)
    }

    private func refreshVolumes() {
        volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.path.hasPrefix("/Volumes/") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
