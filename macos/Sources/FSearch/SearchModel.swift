import AppKit
import SwiftUI
import Combine

enum FileCategory: String, CaseIterable, Identifiable {
    case all = "全部", audio = "音频", archive = "压缩文件", document = "文档"
    case application = "应用", other = "其他"
    case executable = "可执行文件", folder = "文件夹", image = "图片", video = "视频", custom = "自定义后缀"
    var id: String { rawValue }
    var filter: [String: Any] {
        switch self {
        case .all, .custom: return [:]
        case .application: return ["type": "app"]
        case .other: return ["type": "other"]
        case .audio: return ["type": "audio", "kind": "file"]
        case .archive: return ["type": "archive", "kind": "file"]
        case .document: return ["type": "doc", "kind": "file"]
        case .executable: return ["ext": "app,exe,com,bat,cmd,sh,command,run,bin"]
        case .folder: return ["kind": "dir"]
        case .image: return ["type": "image", "kind": "file"]
        case .video: return ["type": "video", "kind": "file"]
        }
    }
}

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = "" { didSet { schedule() } }
    @Published var scope = "" { didSet { saveFilterPreferences(); schedule() } }
    @Published var category: FileCategory = .all { didSet { if category != oldValue { saveFilterPreferences(); schedule(immediate: true) } } }
    @Published var extensions = "" { didSet { saveFilterPreferences(); schedule() } }
    @Published var timeFilter: TimeFilter = .any {
        didSet {
            if !applyingFilters { advancedFilters.modifiedDays = "" }
            saveFilterPreferences(); schedule()
        }
    }
    @Published var sizeFilter: SizeFilter = .any {
        didSet {
            if !applyingFilters { advancedFilters.minimumSize = ""; advancedFilters.maximumSize = "" }
            saveFilterPreferences(); schedule()
        }
    }
    @Published private(set) var advancedFilters = AdvancedSearchFilters()
    @Published private(set) var loadingMode: ResultLoadingMode
    @Published private(set) var loadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var totalResultCount: Int?
    @Published var hits = SearchRows()
    @Published var selected: String?
    @Published var busy = false
    @Published private(set) var sorting = false
    @Published private(set) var preparingSort = false
    @Published var error: String?
    @Published var searched = false
    @Published private var elapsedMilliseconds: Double?
    var elapsed: String {
        elapsedMilliseconds.map { String(format: L("%.1f 毫秒"), $0) } ?? ""
    }
    @Published private(set) var dataRevision = 0
    private(set) var displayGeneration = 0
    @Published private(set) var sort: ResultSort?
    @Published private(set) var directoriesFirst = false
    @Published private(set) var scrollToTopRevision = 0
    private var orderingRevision = 0
    private var scrollAfterOrdering = false
    private var positions = ResultRowLookup()
    private var resultsStore: SearchResultsStore?
    private var modeSubscription: AnyCancellable?
    private var defaultsSubscription: AnyCancellable?
    private var rememberSubscription: AnyCancellable?
    private var pageTask: Task<Void, Never>?
    private var pageRequest: [String: Any]?
    private var nextPage: Data?
    private var pageRows: [SearchHit] = []
    private var pagePositions: [String: Int] = [:]
    private var pageLoadFailed = false
    private var sortTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var preparationRevision = 0
    private var sortingPrepared = false
    private var snapshotRevision = -1
    private let client: SearchClient
    private var task: Task<Void, Never>?
    private var generation = 0
    private var queryIsComposing = false
    private var refreshCatalog = false
    private var applyingFilters = false

    init(client: SearchClient = SearchClient()) {
        self.client = client
        let settings = SearchSettings.shared
        loadingMode = settings.loadingMode
        scope = settings.defaultScope
        sort = settings.defaultSort.sort
        directoriesFirst = settings.directoriesFirst
        if settings.rememberFilters, let saved = UserDefaults.standard.dictionary(forKey: "FSearch.savedFilters") {
            scope = saved["scope"] as? String ?? scope
            category = FileCategory(rawValue: saved["category"] as? String ?? "") ?? .all
            extensions = saved["extensions"] as? String ?? ""
            timeFilter = TimeFilter(rawValue: saved["time"] as? String ?? "") ?? .any
            sizeFilter = SizeFilter(rawValue: saved["size"] as? String ?? "") ?? .any
            if let data = saved["advanced"] as? Data,
               let filters = try? JSONDecoder().decode(AdvancedSearchFilters.self, from: data),
               (try? filters.requestFields()) != nil {
                advancedFilters = filters
            }
            if let column = ResultColumn(rawValue: saved["sort"] as? String ?? "") {
                sort = ResultSort(column: column, ascending: saved["ascending"] as? Bool ?? true)
            } else { sort = nil }
            directoriesFirst = saved["directoriesFirst"] as? Bool ?? directoriesFirst
        }
        modeSubscription = SearchSettings.shared.$loadingMode.dropFirst().receive(on: RunLoop.main).sink { [weak self] mode in
            self?.changeLoadingMode(mode)
        }
        defaultsSubscription = NotificationCenter.default.publisher(for: .searchDefaultsChanged).sink { [weak self] _ in
            guard let self else { return }
            self.scope = settings.defaultScope
            self.sort = settings.defaultSort.sort
            self.directoriesFirst = settings.directoriesFirst
            self.saveFilterPreferences()
            self.schedule(immediate: true)
        }
        rememberSubscription = settings.$rememberFilters.dropFirst().receive(on: RunLoop.main).sink { [weak self] enabled in
            if enabled { self?.saveFilterPreferences() }
            else { UserDefaults.standard.removeObject(forKey: "FSearch.savedFilters") }
        }
    }

    private func saveFilterPreferences() {
        guard !applyingFilters, SearchSettings.shared.rememberFilters else { return }
        UserDefaults.standard.set([
            "scope": scope, "category": category.rawValue, "extensions": extensions,
            "time": timeFilter.rawValue, "size": sizeFilter.rawValue,
            "advanced": (try? JSONEncoder().encode(advancedFilters)) ?? Data(),
            "sort": sort?.column.rawValue ?? "", "ascending": sort?.ascending ?? true,
            "directoriesFirst": directoriesFirst
        ], forKey: "FSearch.savedFilters")
    }

    private func fullResultsStore() -> SearchResultsStore {
        if let resultsStore { return resultsStore }
        let store = SearchResultsStore()
        resultsStore = store
        return store
    }

    private func changeLoadingMode(_ mode: ResultLoadingMode) {
        guard mode != loadingMode else { return }
        loadingMode = mode
        resultsStore = nil
        snapshotRevision = -1
        hits = SearchRows()
        positions = ResultRowLookup()
        dataRevision += 1
        schedule(immediate: true)
    }

    var selectedHit: SearchHit? { selected.flatMap(hit) }
    var hasActiveFilters: Bool {
        advancedFilters.isActive || category != .all || timeFilter != .any || sizeFilter != .any || !scope.isEmpty
    }
    var timeFilterTitle: String {
        advancedFilters.hasTime ? L("过去 \(String(describing: advancedFilters.modifiedDays)) 天") : timeFilter.rawValue.localized
    }
    var sizeFilterTitle: String {
        if advancedFilters.hasSize { return advancedFilters.sizeTitle }
        return sizeFilter == .any ? L("大小") : sizeFilter == .large ? ">100 MB" : "<1 MB"
    }
    func hit(_ path: String) -> SearchHit? {
        guard let row = positions[path], hits.indices.contains(row) else { return nil }
        return hits[row]
    }
    func row(for path: String) -> Int? { positions[path] }

    func setSort(_ sort: ResultSort) {
        guard self.sort != sort else { return }
        self.sort = sort
        resort()
    }

    func setDirectoriesFirst(_ enabled: Bool) {
        guard directoriesFirst != enabled else { return }
        directoriesFirst = enabled
        resort()
    }

    private func resort() {
        saveFilterPreferences()
        orderingRevision += 1
        if loadingMode == .onDemand {
            schedule(immediate: true)
            return
        }
        let resultsStore = fullResultsStore()
        scrollAfterOrdering = true
        sortTask?.cancel()
        let current = generation
        let ordering = orderingRevision
        let sort = self.sort
        let directoriesFirst = self.directoriesFirst
        // Size/time changes can interrupt one-time name-index preparation.
        // A name request reuses it instead of discarding and starting it again.
        let preparation = sort?.column == .name ? preparationTask : nil
        if preparation == nil {
            preparationTask?.cancel()
            preparationRevision += 1
            preparingSort = false
        }
        sorting = true
        sortTask = Task {
            defer { if ordering == orderingRevision { sorting = false } }
            do {
                await preparation?.value
                try Task.checkCancellation()
                if let snapshot = try await resultsStore.sorted(by: sort, directoriesFirst: directoriesFirst,
                    orderingRevision: ordering, generation: current) {
                    guard !Task.isCancelled else { return }
                    publish(snapshot, scrollToTop: true)
                    if !preparingSort { prepareSorting(generation: current) }
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    func useRelevanceSort() {
        guard sort != nil else { return }
        sort = nil
        resort()
    }

    private func publish(_ snapshot: ResultsSnapshot, scrollToTop: Bool = false) {
        guard snapshot.generation == generation, snapshot.revision > snapshotRevision,
              snapshot.orderingRevision == orderingRevision else { return }
        snapshotRevision = snapshot.revision
        positions = snapshot.positions
        hits = snapshot.hits
        displayGeneration = snapshot.generation
        if scrollToTop || scrollAfterOrdering {
            scrollToTopRevision += 1
            scrollAfterOrdering = false
        }
        dataRevision += 1
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("选择文件夹")
        if panel.runModal() == .OK, let url = panel.url { scope = url.path }
    }

    private func schedule(immediate: Bool = false) {
        guard !applyingFilters, !queryIsComposing else { return }
        generation += 1
        task?.cancel()
        pageTask?.cancel()
        pageTask = nil
        loadingMore = false
        hasMore = false
        totalResultCount = nil
        pageRequest = nil
        nextPage = nil
        pageRows = []
        pagePositions = [:]
        pageLoadFailed = false
        sortTask?.cancel()
        preparationTask?.cancel()
        preparationRevision += 1
        preparingSort = false
        sortingPrepared = false
        sorting = false
        scrollAfterOrdering = false
        selected = nil
        error = nil
        elapsedMilliseconds = nil
        searched = false
        busy = true
        task = Task {
            if loadingMode == .onDemand { await client.releaseCatalog() }
            if !immediate { try? await Task.sleep(nanoseconds: 220_000_000) }
            guard !Task.isCancelled else { return }
            await perform()
        }
    }

    func search() {
        refreshCatalog = true
        schedule()
    }
    func setQueryComposition(_ composing: Bool) {
        queryIsComposing = composing
        if composing {
            generation += 1
            task?.cancel()
            pageTask?.cancel()
            loadingMore = false
            sortTask?.cancel()
            preparationTask?.cancel()
            preparationRevision += 1
            preparingSort = false
            sorting = false
            busy = false
        }
    }
    private func perform() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = category.filter
        if let value = timeFilter.value { request["mtime"] = value }
        if let value = sizeFilter.value {
            request["size"] = value
            if category != .folder && category != .application { request["kind"] = "file" }
        }
        request["op"] = "search-all"
        var path = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count >= 2, let quote = path.first, (quote == "\"" || quote == "'"), path.last == quote {
            path = String(path.dropFirst().dropLast())
        }
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL { path = url.path }
        path = (path as NSString).expandingTildeInPath
        if !path.isEmpty { request["in"] = (path as NSString).standardizingPath }
        if category == .custom {
            guard !extensions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                hits = SearchRows()
                positions = ResultRowLookup()
                displayGeneration = generation
                dataRevision += 1
                busy = false
                return
            }
            do { request["ext"] = try AdvancedSearchFilters.normalizedExtensions(extensions) }
            catch {
                self.error = error.localizedDescription
                busy = false
                return
            }
            request["kind"] = "file"
        }
        do {
            for (field, value) in try advancedFilters.requestFields() { request[field] = value }
            if advancedFilters.hasSize && category != .folder && category != .application { request["kind"] = "file" }
        } catch {
            self.error = error.localizedDescription
            busy = false
            return
        }
        request["q"] = text
        let current = generation
        busy = true
        error = nil
        let started = ProcessInfo.processInfo.systemUptime
        let refresh = refreshCatalog
        refreshCatalog = false
        let catalogKey = [text, request["in"] as? String ?? "", request["re"] as? String ?? "",
            advancedFilters.hasTime ? advancedFilters.modifiedDays : timeFilter.rawValue, request["size"] as? String ?? "",
            timeFilter == .today ? String(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) : ""]
        do {
            if loadingMode == .onDemand {
                request["sort"] = sort?.column.rawValue ?? "relevance"
                request["ascending"] = sort?.ascending ?? true
                request["directories_first"] = directoriesFirst
                let page = try await client.searchPage(request, cursor: nil)
                guard current == generation, !Task.isCancelled else { return }
                pageRequest = request
                applyPage(page, reset: true)
            } else {
                let batch = try await client.search(request, catalogKey: catalogKey, refresh: refresh)
                guard current == generation, !Task.isCancelled else { return }
                let snapshot = try await fullResultsStore().replace(batch, generation: current,
                    sort: sort, directoriesFirst: directoriesFirst, orderingRevision: orderingRevision)
                guard current == generation, !Task.isCancelled else { return }
                publish(snapshot)
                prepareSorting(generation: current)
            }
            elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            searched = true
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        if current == generation {
            busy = false
            if hits.isEmpty && hasMore { loadMore() }
        }
    }

    private func applyPage(_ page: SearchPageBatch, reset: Bool) {
        if reset {
            pageRows = []
            pagePositions = [:]
            scrollToTopRevision += 1
        }
        for hit in page.hits where pagePositions[hit.path] == nil {
            pagePositions[hit.path] = pageRows.count
            pageRows.append(hit)
        }
        nextPage = page.next
        hasMore = page.next != nil
        if let total = page.total { totalResultCount = max(total, pageRows.count) }
        else if !hasMore { totalResultCount = pageRows.count }
        hits = SearchRows(pageRows)
        positions = ResultRowLookup(base: pagePositions)
        displayGeneration = generation
        dataRevision += 1
    }

    func loadMoreIfNeeded(lastVisibleRow: Int) {
        guard lastVisibleRow >= max(0, hits.count - 100) else { return }
        loadMore()
    }

    private func loadMore(retry: Bool = false) {
        guard loadingMode == .onDemand, !busy, !loadingMore, hasMore,
              !pageLoadFailed || retry, let request = pageRequest, let cursor = nextPage else { return }
        let current = generation
        loadingMore = true
        pageLoadFailed = false
        error = nil
        pageTask = Task {
            do {
                let page = try await client.searchPage(request, cursor: cursor)
                guard current == generation, !Task.isCancelled else { return }
                applyPage(page, reset: false)
                loadingMore = false
                // A time-bounded index scan can cross an empty region before
                // reaching a sparse category. Advance that cursor automatically.
                if page.hits.isEmpty && hasMore { loadMore() }
            } catch {
                guard current == generation, !Task.isCancelled else { return }
                loadingMore = false
                pageLoadFailed = true
                self.error = error.localizedDescription
            }
        }
    }

    func retrySearch() {
        if loadingMode == .onDemand && pageLoadFailed { loadMore(retry: true) }
        else { search() }
    }

    private func prepareSorting(generation current: Int) {
        guard loadingMode == .full, !sortingPrepared, let resultsStore else { return }
        preparationTask?.cancel()
        preparationRevision += 1
        let preparation = preparationRevision
        preparingSort = true
        preparationTask = Task(priority: .utility) {
            defer { if current == generation && preparation == preparationRevision { preparingSort = false } }
            do {
                try await resultsStore.prepareSorting(generation: current)
                if current == generation && preparation == preparationRevision && !Task.isCancelled {
                    sortingPrepared = true
                }
            } catch { /* Interactive requests can cancel optional preparation. */ }
        }
    }

    func open(_ hit: SearchHit) {
        if !NSWorkspace.shared.open(URL(fileURLWithPath: hit.path)) { error = L("无法打开文件，请确认文件仍在原位置且有可用的打开方式。") }
    }
    func reveal(_ hit: SearchHit) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)]) }
    func copyPath(_ hit: SearchHit) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hit.path, forType: .string)
    }

    @discardableResult
    func copyFile(_ hit: SearchHit) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([hit.fileURL as NSURL]) else {
            error = L("无法复制文件，请重试。")
            return false
        }
        return true
    }

    func resetFilters() {
        applyAdvancedFilters(AdvancedSearchFilters(), category: .all, extensions: "", time: .any, scope: "")
    }

    func applyAdvancedFilters(_ filters: AdvancedSearchFilters, category: FileCategory, extensions: String,
                              time: TimeFilter, scope: String) {
        applyingFilters = true
        self.category = category
        self.extensions = extensions
        timeFilter = time
        sizeFilter = .any
        self.scope = scope
        advancedFilters = filters
        applyingFilters = false
        saveFilterPreferences()
        schedule(immediate: true)
    }

    func openTerminal(_ hit: SearchHit) {
        let url = URL(fileURLWithPath: hit.path)
        let directory = hit.isDirectory ? url : url.deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            error = L("未找到终端应用。")
            return
        }
        NSWorkspace.shared.open([directory], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if error != nil {
                Task { @MainActor in self?.error = L("无法在终端中打开此位置，请确认有访问权限。") }
            }
        }
    }
}
