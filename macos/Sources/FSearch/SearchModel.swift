import AppKit
import SwiftUI

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
    @Published var scope = "" { didSet { schedule() } }
    @Published var category: FileCategory = .all { didSet { schedule() } }
    @Published var extensions = "" { didSet { schedule() } }
    @Published var timeFilter: TimeFilter = .any { didSet { schedule() } }
    @Published var sizeFilter: SizeFilter = .any { didSet { schedule() } }
    @Published var hits: [SearchHit] = []
    @Published var selected: String?
    @Published var busy = false
    @Published var error: String?
    @Published var searched = false
    @Published var elapsed = ""
    @Published private(set) var dataRevision = 0
    private(set) var displayGeneration = 0
    @Published private(set) var sort: ResultSort?
    @Published private(set) var directoriesFirst = false
    @Published private(set) var scrollToTopRevision = 0
    private var orderingRevision = 0
    private var scrollAfterOrdering = false
    private var positions: [String: Int] = [:]
    private let resultsStore = SearchResultsStore()
    private var sortTask: Task<Void, Never>?
    private var snapshotRevision = -1
    private let client: SearchClient
    private var task: Task<Void, Never>?
    private var generation = 0
    private var queryIsComposing = false
    private var refreshCatalog = false

    init(client: SearchClient = SearchClient()) { self.client = client }

    var selectedHit: SearchHit? { selected.flatMap(hit) }
    func hit(_ path: String) -> SearchHit? {
        guard let row = positions[path], hits.indices.contains(row) else { return nil }
        return hits[row]
    }
    func row(for path: String) -> Int? { positions[path] }

    func setSort(_ sort: ResultSort) {
        self.sort = sort
        resort()
    }

    func setDirectoriesFirst(_ enabled: Bool) {
        directoriesFirst = enabled
        resort()
    }

    private func resort() {
        orderingRevision += 1
        scrollAfterOrdering = true
        sortTask?.cancel()
        let current = generation
        let ordering = orderingRevision
        let sort = self.sort
        let directoriesFirst = self.directoriesFirst
        sortTask = Task {
            do {
                if let snapshot = try await resultsStore.sorted(by: sort, directoriesFirst: directoriesFirst,
                    orderingRevision: ordering, generation: current) {
                    guard !Task.isCancelled else { return }
                    publish(snapshot, scrollToTop: true)
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    func useRelevanceSort() {
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
        panel.prompt = "选择文件夹"
        if panel.runModal() == .OK, let url = panel.url { scope = url.path }
    }

    private func schedule() {
        guard !queryIsComposing else { return }
        generation += 1
        task?.cancel()
        sortTask?.cancel()
        hits = []
        positions = [:]
        displayGeneration = generation
        scrollToTopRevision += 1
        scrollAfterOrdering = false
        dataRevision += 1
        selected = nil
        error = nil
        elapsed = ""
        searched = false
        busy = false
        task = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
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
            let parts = extensions.lowercased().components(separatedBy: CharacterSet(charactersIn: ",，;； ").union(.newlines))
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty }
            guard !parts.isEmpty else { return }
            guard parts.allSatisfy({ $0.range(of: "^[a-z0-9_+-]+$", options: .regularExpression) != nil }) else {
                error = "请输入有效后缀，多个后缀用逗号分隔，例如 pdf, docx。"
                return
            }
            request["ext"] = parts.joined(separator: ",")
            request["kind"] = "file"
        }
        request["q"] = text
        let current = generation
        busy = true
        error = nil
        let started = ProcessInfo.processInfo.systemUptime
        let refresh = refreshCatalog
        refreshCatalog = false
        let catalogKey = [text, request["in"] as? String ?? "", timeFilter.rawValue, sizeFilter.rawValue,
            timeFilter == .today ? String(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) : ""]
        do {
            let hits = try await client.search(request, catalogKey: catalogKey, refresh: refresh)
            guard current == generation, !Task.isCancelled else { return }
            let snapshot = try await resultsStore.replace(hits, generation: current,
                sort: sort, directoriesFirst: directoriesFirst, orderingRevision: orderingRevision)
            guard current == generation, !Task.isCancelled else { return }
            publish(snapshot)
            elapsed = String(format: "%.1f 毫秒", (ProcessInfo.processInfo.systemUptime - started) * 1000)
            searched = true
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        if current == generation { busy = false }
    }

    func open(_ hit: SearchHit) {
        if !NSWorkspace.shared.open(URL(fileURLWithPath: hit.path)) { error = "无法打开文件，请确认文件仍在原位置且有可用的打开方式。" }
    }
    func reveal(_ hit: SearchHit) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)]) }
    func copyPath(_ hit: SearchHit) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hit.path, forType: .string)
    }

    func resetFilters() {
        category = .all
        timeFilter = .any
        sizeFilter = .any
        extensions = ""
        scope = ""
    }

    func openTerminal(_ hit: SearchHit) {
        let url = URL(fileURLWithPath: hit.path)
        let directory = hit.isDirectory ? url : url.deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            error = "未找到终端应用。"
            return
        }
        NSWorkspace.shared.open([directory], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if error != nil {
                Task { @MainActor in self?.error = "无法在终端中打开此位置，请确认有访问权限。" }
            }
        }
    }
}
