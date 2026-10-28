import SwiftUI
import AppKit
import QuickLook

struct SearchView: View {
    @ObservedObject var model: SearchModel
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var searchFocus = 0
    @State private var previewURL: URL?
    @State private var showScopeEditor = false
    @State private var showAdvancedFilters = false
    @State private var scopeDraft = ""
    @FocusState private var extensionsFocused: Bool
    @AppStorage("FSearch.showSidebar") private var showSidebar = true
    @AppStorage("FSearch.showInspector") private var showInspector = true
    @AppStorage("FSearch.gridView") private var gridView = false

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = geometry.size.width < 1100 ? 208 : min(260, geometry.size.width * 0.19)
            let inspectorWidth: CGFloat = showInspector && geometry.size.width >= 1100
                ? (geometry.size.width < 1250 ? 264 : min(332, geometry.size.width * 0.23)) : 0
            let contentLeadingEdge = showSidebar ? sidebarWidth + 1 : 0
            let contentTrailingEdge = geometry.size.width - (inspectorWidth > 0 ? inspectorWidth + 1 : 0) - 16
            HStack(alignment: .top, spacing: 0) {
                if showSidebar {
                    SearchSidebar(model: model)
                        .frame(width: sidebarWidth)
                    Divider()
                }
                VStack(spacing: 0) {
                    filterBar
                    Divider()
                    results
                    Divider()
                    statusBar
                }
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                .background(AppAppearance.panel)
                if inspectorWidth > 0 {
                    Divider()
                    FileInspector(hit: model.selectedHit, model: model, preview: preview)
                        .frame(width: inspectorWidth)
                        .frame(maxHeight: .infinity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 4) {
                        sidebarToggle
                        windowActions
                    }
                }
                ToolbarItem(placement: .navigation) {
                    ColumnAlignedToolbarItem(leadingEdge: contentLeadingEdge, trailingEdge: contentTrailingEdge,
                                             height: AppAppearance.searchHeight) {
                        HStack(spacing: 8) {
                            searchBar.frame(maxWidth: .infinity)
                            displayControls.fixedSize()
                        }
                    }
                }
            }
        }
        .background(SearchBackdrop().ignoresSafeArea())
        .foregroundStyle(AppAppearance.text)
        .tint(AppAppearance.accent)
        .onAppear { model.search() }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in searchFocus += 1 }
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
        .buttonStyle(WindowToolbarButtonStyle(active: showSidebar))
        .help(showSidebar ? "隐藏侧边栏" : "显示侧边栏")
        .accessibilityLabel(showSidebar ? "隐藏侧边栏" : "显示侧边栏")
        .keyboardShortcut("s", modifiers: [.control, .command])
    }

    private var windowActions: some View {
        HStack(spacing: 4) {
            PopupButton(actions: [
                PopupAction("选择搜索文件夹…", perform: model.chooseFolder),
                PopupAction("清除筛选", perform: model.resetFilters),
                .separator,
                PopupAction("刷新结果", perform: model.search),
                PopupAction("设置…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            ], chevron: false, toolbarControl: true) {
                Image(systemName: "ellipsis")
            }
            .fixedSize()
            .help("更多操作")
            .accessibilityLabel("更多操作")
            Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(WindowToolbarButtonStyle(active: showInspector))
                .help(showInspector ? "隐藏文件详情" : "显示文件详情")
                .accessibilityLabel(showInspector ? "隐藏文件详情" : "显示文件详情")
                .keyboardShortcut("i", modifiers: [.control, .command])
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15)).foregroundStyle(AppAppearance.muted)
                .frame(width: 18).accessibilityHidden(true)
            NativeSearchField(text: $model.query, focus: searchFocus,
                compositionChanged: model.setQueryComposition, submit: model.search)
                .frame(maxWidth: .infinity).frame(height: 22)
            if !model.query.isEmpty {
                Button { model.query = ""; searchFocus += 1 } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppAppearance.muted).frame(width: 20, height: 24)
                }
                .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索")
            }
            Divider().frame(height: 16).padding(.horizontal, 2)
            Button { showAdvancedFilters.toggle() } label: {
                Text("高级筛选")
            }
            .buttonStyle(AdvancedSearchButtonStyle(active: model.hasActiveFilters || showAdvancedFilters))
            .fixedSize()
            .help("设置文件名、类型、大小、修改时间和搜索位置")
            .accessibilityValue(model.hasActiveFilters ? "已启用筛选" : "未启用筛选")
            .popover(isPresented: $showAdvancedFilters, arrowEdge: .bottom) {
                AdvancedSearchView(model: model)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: AppAppearance.searchHeight)
        .background(AppAppearance.panel, in: RoundedRectangle(cornerRadius: AppAppearance.searchCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppAppearance.searchCorner, style: .continuous)
            .strokeBorder(AppAppearance.border, lineWidth: 1.2)
            .allowsHitTesting(false))
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    filterChoices.padding(.vertical, 4)
                }
                .onChange(of: model.category) { category in
                    extensionsFocused = category == .custom
                    if category == .custom { proxy.scrollTo("extensions", anchor: .trailing) }
                }
            }
            directoriesFirstButton.fixedSize()
            PopupButton(actions: sortActions) { Text(model.sort?.column.title ?? "按相关性") }
                .filterChip(active: false)
                .fixedSize()
                .help("对全部结果排序")
                .accessibilityLabel("排序")
        }
        .frame(height: 44)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var filterChoices: some View {
        HStack(spacing: 8) {
            scopeButton
            PopupButton(actions: TimeFilter.allCases.map { filter in
                PopupAction(filter.rawValue, selected: !model.advancedFilters.hasTime && model.timeFilter == filter) { model.timeFilter = filter }
            }) { Text(model.timeFilterTitle) }
            .filterChip(active: model.timeFilter != .any || model.advancedFilters.hasTime)
            PopupButton(actions: SizeFilter.allCases.map { filter in
                PopupAction(filter.rawValue, selected: !model.advancedFilters.hasSize && model.sizeFilter == filter) { model.sizeFilter = filter }
            }) { Text(model.sizeFilterTitle) }
            .filterChip(active: model.sizeFilter != .any || model.advancedFilters.hasSize)
            PopupButton(actions: FileCategory.allCases.map { category in
                PopupAction(category.rawValue, selected: model.category == category) { model.category = category }
            }) { Text(model.category == .all ? "所有类型" : model.category.rawValue) }
            .filterChip(active: true, emphasized: true)
            if model.category == .custom {
                TextField("pdf, docx, xlsx", text: $model.extensions)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .focused($extensionsFocused)
                    .padding(.horizontal, 12).frame(width: 190, height: 36)
                    .background(AppAppearance.secondary, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(extensionsFocused ? AppAppearance.accent : AppAppearance.separator, lineWidth: 1)
                        .allowsHitTesting(false))
                    .accessibilityLabel("文件后缀，多个用逗号分隔")
                    .onSubmit(model.search)
                    .id("extensions")
            }
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

    private var directoriesFirstButton: some View {
        Button { model.setDirectoriesFirst(!model.directoriesFirst) } label: {
            Text("目录优先").font(.system(size: 12))
                .foregroundStyle(model.directoriesFirst ? AppAppearance.onAccent : AppAppearance.text)
                .padding(.horizontal, 10).frame(height: 36)
                .background(model.directoriesFirst ? AppAppearance.selection : AppAppearance.secondary, in: Capsule())
                .overlay(Capsule().strokeBorder(AppAppearance.border.opacity(0.75), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(model.directoriesFirst ? "开启" : "关闭")
        .help("将目录排在文件前面")
    }

    private var displayControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                displayButton("list.bullet", title: "列表视图", selected: !gridView) { gridView = false }
                displayButton("square.grid.2x2", title: "网格视图", selected: gridView) { gridView = true }
            }
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
            Image(systemName: symbol)
        }.buttonStyle(WindowToolbarButtonStyle(active: selected, selected: selected))
            .accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : []).help(title)
    }

    private var results: some View {
        Group {
            if gridView { SearchResultsGrid(model: model, preview: preview) }
            else { SearchResultsTable(model: model, preview: preview) }
        }
        .overlay {
            if model.hits.isEmpty {
                VStack(spacing: 14) {
                    if let error = model.error {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 26))
                        Text(error).multilineTextAlignment(.center).textSelection(.enabled)
                        Button("重试", action: model.retrySearch)
                    } else if model.busy || model.loadingMore {
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
            if model.busy || model.sorting || model.preparingSort || model.loadingMore { ProgressView().controlSize(.mini) }
            if model.preparingSort { Text("正在准备排序索引…") }
            else if model.sorting { Text("正在排序…") }
            if !model.busy {
                if model.loadingMode == .onDemand && model.hasMore {
                    Text("已加载 \(model.hits.count) 项")
                } else { Text("共 \(model.hits.count) 项") }
            }
            if model.loadingMore { Text("正在加载更多…") }
            if !model.elapsed.isEmpty { Text(model.elapsed).foregroundStyle(.tertiary) }
            if let error = model.error, !model.hits.isEmpty {
                Text(error).lineLimit(1).help(error)
                Button("重试", action: model.retrySearch)
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

private struct AdvancedSearchButtonStyle: ButtonStyle {
    let active: Bool
    @State private var hovered = false
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? AppAppearance.onAccent : AppAppearance.text)
            .padding(.horizontal, 8).frame(height: 26)
            .background(active ? AppAppearance.selection : Color.primary.opacity(configuration.isPressed ? 0.14 : hovered ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(focused ? AppAppearance.accent : .clear, lineWidth: 1))
            .opacity(enabled ? (active && configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
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
