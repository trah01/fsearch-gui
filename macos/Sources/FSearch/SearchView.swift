import SwiftUI
import AppKit
import QuickLook

struct SearchView: View {
    @ObservedObject var model: SearchModel
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var searchFocus = 0
    @State private var previewURL: URL?
    @State private var showScopeEditor = false
    @State private var scopeDraft = ""
    @State private var sidebarToggleHovered = false
    @FocusState private var sidebarToggleFocused: Bool
    @FocusState private var extensionsFocused: Bool
    @AppStorage("FSearch.showSidebar") private var showSidebar = true
    @AppStorage("FSearch.showInspector") private var showInspector = true
    @AppStorage("FSearch.gridView") private var gridView = false

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            sidebarToggle
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 8).frame(height: AppAppearance.toolbarHeight)
                        if showSidebar { SearchSidebar(model: model) }
                        else { Spacer(minLength: 0) }
                }
                .frame(width: showSidebar ? (geometry.size.width < 1100 ? 208 : min(260, geometry.size.width * 0.19)) : 36)
                VStack(spacing: 0) {
                    Color.clear.frame(height: AppAppearance.toolbarHeight)
                    VStack(spacing: 0) {
                        searchBar.padding(.top, 12)
                        filterBar
                        results
                        statusBar
                    }
                    .background(AppAppearance.panel.opacity(0.45), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                if showInspector && geometry.size.width >= 1100 {
                    VStack(spacing: 0) {
                        windowActions.frame(height: AppAppearance.toolbarHeight)
                        FileInspector(hit: model.selectedHit, model: model, preview: preview)
                            .floatingSurface()
                            .padding(.bottom, 12)
                    }
                    .frame(width: geometry.size.width < 1250 ? 264 : min(332, geometry.size.width * 0.23))
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .padding(.bottom, 2)
            .overlay(alignment: .topTrailing) {
                if !showInspector || geometry.size.width < 1100 {
                    windowActions.padding(.trailing, 20).offset(y: 3)
                }
            }
        }
        .background(SearchBackdrop().ignoresSafeArea())
        .foregroundStyle(AppAppearance.text)
        .tint(AppAppearance.accent)
        .onAppear { model.search() }
        .onReceive(NotificationCenter.default.publisher(for: .searchEngineReloaded)) { _ in model.search() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in model.search() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in model.search() }
        .quickLookPreview($previewURL)
        .onChange(of: model.selected) { _ in
            if previewURL != nil { previewURL = model.selectedHit.map { URL(fileURLWithPath: $0.path) } }
        }
        .background(Button("") { searchFocus += 1 }.keyboardShortcut("f").hidden())
        .background(Button("") { if let hit = model.selectedHit { model.open(hit) } }
            .keyboardShortcut(.return, modifiers: []).hidden())
    }

    private func preview(_ hit: SearchHit) { previewURL = URL(fileURLWithPath: hit.path) }

    private var sidebarToggle: some View {
        Button { showSidebar.toggle() } label: {
            Image(systemName: "sidebar.left").font(.system(size: 14, weight: .regular))
        }
        .buttonStyle(SidebarToggleStyle(hovered: sidebarToggleHovered, focused: sidebarToggleFocused))
        .focused($sidebarToggleFocused)
        .onHover { sidebarToggleHovered = $0 }
        .help(showSidebar ? "隐藏侧边栏" : "显示侧边栏")
        .accessibilityLabel(showSidebar ? "隐藏侧边栏" : "显示侧边栏")
        .keyboardShortcut("s", modifiers: [.control, .command])
    }

    private var windowActions: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            PopupButton(actions: [
                PopupAction("选择搜索文件夹…", perform: model.chooseFolder),
                PopupAction("清除筛选", perform: model.resetFilters),
                .separator,
                PopupAction("刷新结果", perform: model.search),
                PopupAction("设置…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            ], chevron: false) {
                Image(systemName: "ellipsis").frame(width: 18, height: 18)
                    .padding(9).floatingSurface(radius: 14, shadow: false)
            }.fixedSize().help("更多操作")
            Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right").frame(width: 24, height: 18) }
                .help("显示或隐藏文件详情")
        }
        .buttonStyle(FloatingButtonStyle(radius: 16))
        .padding(.horizontal, 6)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .regular))
                .foregroundStyle(AppAppearance.text.opacity(0.85)).accessibilityHidden(true)
            NativeSearchField(text: $model.query, focus: searchFocus,
                compositionChanged: model.setQueryComposition, submit: model.search)
                .frame(maxWidth: .infinity).frame(height: 28)
        }
        .padding(.horizontal, 16)
        .frame(height: AppAppearance.searchHeight)
        .background(AppAppearance.panel, in: RoundedRectangle(cornerRadius: AppAppearance.searchCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppAppearance.searchCorner, style: .continuous)
            .strokeBorder(AppAppearance.border, lineWidth: 1.2))
        .shadow(color: AppAppearance.shadow.opacity(0.7), radius: 10, x: 0, y: 4)
        .padding(.horizontal, 18).padding(.bottom, 12)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    filterChoices.fixedSize()
                    Spacer(minLength: 0)
                    displayControls.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        filterChoices.padding(.vertical, 4)
                    }
                    HStack {
                        Spacer(minLength: 0)
                        displayControls.fixedSize()
                    }
                }
            }
            if model.category == .custom {
                HStack(spacing: 10) {
                    Text("后缀").font(.system(size: 12)).foregroundStyle(AppAppearance.muted)
                    TextField("pdf, docx, xlsx", text: $model.extensions)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .focused($extensionsFocused)
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(AppAppearance.secondary, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(extensionsFocused ? AppAppearance.accent : AppAppearance.separator, lineWidth: 1))
                        .frame(maxWidth: 360)
                        .accessibilityLabel("文件后缀，多个用逗号分隔")
                        .onSubmit(model.search)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 14)
        .onChange(of: model.category) { category in extensionsFocused = category == .custom }
    }

    private var filterChoices: some View {
        HStack(spacing: 8) {
            PopupButton(actions: FileCategory.allCases.map { category in
                PopupAction(category.rawValue, selected: model.category == category) { model.category = category }
            }) { Text(model.category == .all ? "所有类型" : model.category.rawValue) }
            .filterChip(active: true, emphasized: true)
            scopeButton
            PopupButton(actions: TimeFilter.allCases.map { filter in
                PopupAction(filter.rawValue, selected: model.timeFilter == filter) { model.timeFilter = filter }
            }) { Text(model.timeFilter.rawValue) }
            .filterChip(active: model.timeFilter != .any)
            PopupButton(actions: SizeFilter.allCases.map { filter in
                PopupAction(filter.rawValue, selected: model.sizeFilter == filter) { model.sizeFilter = filter }
            }) { Text(model.sizeFilter == .any ? "大小" : model.sizeFilter == .large ? ">100 MB" : "<1 MB") }
            .filterChip(active: model.sizeFilter != .any)
        }
    }

    private var scopeButton: some View {
        PopupButton(actions: [
            PopupAction("这台 Mac", selected: model.scope.isEmpty) { model.scope = "" },
            PopupAction("选择文件夹…", perform: model.chooseFolder),
            PopupAction("输入文件夹路径…") { scopeDraft = model.scope; showScopeEditor = true }
        ]) {
            Text(model.scope.isEmpty ? "这台 Mac" : (model.scope as NSString).lastPathComponent)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 95)
        }
            .filterChip(active: !model.scope.isEmpty)
            .help(model.scope.isEmpty ? "搜索所有已建立索引的位置" : model.scope)
            .popover(isPresented: $showScopeEditor) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("文件夹路径", text: $scopeDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.scope = scopeDraft; showScopeEditor = false }
                    HStack {
                        Button("选择文件夹…") { showScopeEditor = false; model.chooseFolder() }
                        Spacer()
                        Button("搜索") { model.scope = scopeDraft; showScopeEditor = false }.keyboardShortcut(.defaultAction)
                    }
                }.padding(16).frame(width: 360)
            }
    }

    private var displayControls: some View {
        HStack(spacing: 10) {
            Button { model.setDirectoriesFirst(!model.directoriesFirst) } label: {
                Text("目录优先").font(.system(size: 12))
                    .foregroundStyle(model.directoriesFirst ? AppAppearance.accent : AppAppearance.text)
                    .padding(.horizontal, 10).frame(height: 36)
                    .background(model.directoriesFirst ? AppAppearance.selection : AppAppearance.secondary, in: Capsule())
                    .overlay(Capsule().strokeBorder(AppAppearance.border.opacity(0.75), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityValue(model.directoriesFirst ? "开启" : "关闭")
            .help("将目录排在文件前面")
            PopupButton(actions: sortActions) { Text(model.sort?.column.title ?? "按相关性") }
                .filterChip(active: false)
                .help("对全部结果排序")
            HStack(spacing: 0) {
                displayButton("list.bullet", title: "列表视图", selected: !gridView) { gridView = false }
                displayButton("square.grid.2x2", title: "网格视图", selected: gridView) { gridView = true }
            }
            .padding(3).floatingSurface(radius: 18)
        }
    }

    private var sortActions: [PopupAction] {
        var actions = [PopupAction("相关性", selected: model.sort == nil, perform: model.useRelevanceSort), .separator]
        actions += [ResultColumn.name, .size, .modified].map { column in
            PopupAction(column.title, selected: model.sort?.column == column) {
                model.setSort(ResultSort(column: column, ascending: column == .name))
            }
        }
        if let sort = model.sort {
            actions += [.separator, PopupAction(sort.ascending ? "改为降序" : "改为升序") {
                model.setSort(ResultSort(column: sort.column, ascending: !sort.ascending))
            }]
        }
        return actions
    }

    private func displayButton(_ symbol: String, title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 30, height: 30)
                .background(selected ? AppAppearance.selection : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel(title).help(title)
    }

    private var results: some View {
        Group {
            if gridView { SearchResultsGrid(model: model, preview: preview) }
            else { SearchResultsTable(model: model, preview: preview) }
        }
        .padding(.horizontal, 10)
        .overlay {
            if model.hits.isEmpty {
                VStack(spacing: 14) {
                    if let error = model.error {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 26))
                        Text(error).multilineTextAlignment(.center).textSelection(.enabled)
                        Button("重试", action: model.search)
                    } else if model.busy {
                        ProgressView().controlSize(.small)
                        Text("正在搜索…")
                    } else {
                        Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .light))
                        Text(model.category == .custom && model.extensions.isEmpty ? "请输入文件后缀" : "没有找到匹配的文件")
                        Button("清除筛选", action: model.resetFilters)
                    }
                }
                .font(.system(size: 13)).foregroundStyle(.secondary).padding(30).frame(maxWidth: 420)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.busy { ProgressView().controlSize(.mini) }
            if !model.busy { Text("共 \(model.hits.count) 项") }
            if !model.elapsed.isEmpty { Text(model.elapsed).foregroundStyle(.tertiary) }
            if let error = model.error, !model.hits.isEmpty {
                Text(error).lineLimit(1).help(error)
                Button("重试", action: model.search)
            }
            Spacer(minLength: 0)
            if model.selectedHit != nil {
                Button("快速查看") { if let hit = model.selectedHit { preview(hit) } }
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.borderless)
        .padding(.horizontal, 18).frame(height: 36)
    }
}

private struct SidebarToggleStyle: ButtonStyle {
    let hovered: Bool
    let focused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AppAppearance.text.opacity(configuration.isPressed ? 1 : 0.75))
            .frame(width: 28, height: 28)
            .background(configuration.isPressed ? AppAppearance.sidebarSelection
                : hovered || focused ? AppAppearance.secondary : .clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(focused ? AppAppearance.accent.opacity(0.6) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
    }
}

private extension PopupButton {
    func filterChip(active: Bool, emphasized: Bool = false) -> some View {
        var button = self
        button.chipActive = active
        button.emphasized = emphasized
        return button
    }
}
