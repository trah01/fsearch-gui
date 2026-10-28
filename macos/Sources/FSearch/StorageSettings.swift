import AppKit
import SwiftUI

extension Notification.Name {
    static let searchEngineReloaded = Notification.Name("FSearch.searchEngineReloaded")
    static let focusSearchField = Notification.Name("FSearch.focusSearchField")
}

struct StorageVolume: Identifiable {
    let name: String
    let path: String
    let readable: Bool?
    let included: Bool
    let building: Bool
    let entries: Int?
    let updated: Date?
    let error: String?
    var id: String { path }
    var status: String {
        if building { return L("正在重建索引…") }
        if readable == false { return L("无法读取") }
        if included { return entries.map { L("已建立索引 · \(String(describing: $0)) 项") } ?? L("已建立索引") }
        return readable == true ? L("未建立索引") : L("未授权，未建立索引")
    }
}

@MainActor
final class StoragePermissions: ObservableObject {
    @Published var fullAccess: Bool?
    @Published var activeAccess = false
    @Published var volumes: [StorageVolume] = []
    @Published var busy = false
    @Published var internalBuilding = false
    @Published var internalCompleted: Date?
    @Published var internalError: String?
    @Published var internalEntries: Int?
    @Published var internalUpdated: Date?
    @Published private(set) var automatic = true
    @Published private(set) var excludedFolders: [String] = []
    @Published private(set) var supportsSettings = false
    @Published var error: String?
    private let client: SearchClient
    private let bookmarkKey = "FSearch.storageAccessBookmarks"
    private var authorizedPaths = Set<String>()
    private var scopedURLs: [String: URL] = [:]
    var indexing: Bool { internalBuilding || volumes.contains { $0.building } }

    init(client: SearchClient = SearchClient()) {
        self.client = client
        let bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkKey) as? [String: Data] ?? [:]
        for data in bookmarks.values {
            var stale = false
            let scoped = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
            let resolved = scoped ?? (try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale))
            if let url = resolved {
                authorizedPaths.insert(url.standardizedFileURL.path)
                if url.startAccessingSecurityScopedResource() { scopedURLs[url.path] = url }
            }
        }
    }

    func refresh(verifyAccess: Bool = true) async {
        guard !busy else { return }
        busy = true
        error = nil
        let wasIndexing = indexing
        defer { busy = false }
        await readStatus(verifyAccess: verifyAccess)
        if wasIndexing && !indexing {
            NotificationCenter.default.post(name: .searchEngineReloaded, object: nil)
        }
    }

    private func checked(_ request: [String: Any]) async throws -> [String: Any] {
        let response = try await client.request(request)
        guard response["ok"] as? Bool == true else {
            throw ClientError.message(response["error"] as? String ?? L("操作失败，请重试。"))
        }
        return response
    }

    private func readStatus(verifyAccess: Bool = false) async {
        do {
            let response = try await checked(["op": "storage"])
            fullAccess = response["full_disk_access"] as? Bool
            activeAccess = response["active_full_disk_access"] as? Bool ?? false
            let internalIndex = response["internal"] as? [String: Any] ?? [:]
            internalBuilding = internalIndex["building"] as? Bool ?? false
            internalError = internalIndex["error"] as? String
            internalEntries = internalIndex["entries"] as? Int
            internalUpdated = (internalIndex["updated_at"] as? NSNumber).flatMap { $0.doubleValue > 0 ? Date(timeIntervalSince1970: $0.doubleValue) : nil }
            internalCompleted = (internalIndex["indexed_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            if let settings = response["settings"] as? [String: Any] {
                supportsSettings = true
                automatic = settings["automatic"] as? Bool ?? true
                excludedFolders = settings["excluded"] as? [String] ?? []
            } else { supportsSettings = false }
            var rows: [StorageVolume] = []
            for value in response["volumes"] as? [[String: Any]] ?? [] {
                guard let path = value["path"] as? String, let name = value["name"] as? String else { continue }
                var readable = value["readable"] as? Bool
                if verifyAccess && authorizedPaths.contains(path) {
                    do {
                        _ = try await checked(["op": "storage-access", "path": path])
                        readable = true
                    } catch { readable = false }
                }
                rows.append(StorageVolume(name: name, path: path, readable: readable,
                    included: value["included"] as? Bool ?? false,
                    building: value["building"] as? Bool ?? false,
                    entries: value["entries"] as? Int,
                    updated: (value["indexed_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                    error: value["error"] as? String))
            }
            volumes = rows
        } catch { self.error = error.localizedDescription }
    }

    func reload() async {
        guard !busy, !indexing else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await client.restartEngine()
            await readStatus(verifyAccess: true)
            NotificationCenter.default.post(name: .searchEngineReloaded, object: nil)
        } catch { self.error = error.localizedDescription }
    }

    func requestVolumeAccess(_ volume: StorageVolume) {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = L("允许访问磁盘“\(String(describing: volume.name))”")
        panel.message = L("请选择此磁盘的根目录，以允许 FSearch 读取其中的文件。")
        panel.directoryURL = URL(fileURLWithPath: volume.path)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("允许访问")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL.path == volume.path else {
            error = L("请选择磁盘“\(String(describing: volume.name))”的根目录。")
            return
        }
        do {
            if scopedURLs[url.path] == nil, url.startAccessingSecurityScopedResource() { scopedURLs[url.path] = url }
            // Unsandboxed local builds may use ordinary bookmarks while the
            // open panel still records the user's explicit access permission.
            let scoped = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            let data: Data
            if let scoped { data = scoped }
            else { data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
            var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkKey) as? [String: Data] ?? [:]
            bookmarks[url.path] = data
            UserDefaults.standard.set(bookmarks, forKey: bookmarkKey)
            authorizedPaths.insert(url.path)
        } catch { self.error = error.localizedDescription; return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                _ = try await checked(["op": "storage-access", "path": volume.path])
                await readStatus()
            } catch { self.error = error.localizedDescription }
        }
    }

    func rebuild(_ volume: StorageVolume? = nil) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        var request: [String: Any] = ["op": "rebuild-index", "target": volume == nil ? "internal" : "external"]
        if let volume { request["path"] = volume.path }
        do {
            _ = try await checked(request)
            await readStatus()
            if !indexing { NotificationCenter.default.post(name: .searchEngineReloaded, object: nil) }
        } catch { self.error = error.localizedDescription }
    }

    func requestFullAccess() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    func showApplication() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }

    func setAutomatic(_ enabled: Bool) {
        updateSettings(automatic: enabled, excluded: excludedFolders)
    }

    func addExcludedFolders() {
        let panel = NSOpenPanel()
        panel.title = L("排除文件夹")
        panel.prompt = L("排除")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map { $0.standardizedFileURL.path }
        updateSettings(automatic: automatic, excluded: Array(Set(excludedFolders + paths)).sorted())
    }

    func removeExcludedFolder(_ path: String) {
        updateSettings(automatic: automatic, excluded: excludedFolders.filter { $0 != path })
    }

    private func updateSettings(automatic: Bool, excluded: [String]) {
        guard !busy, supportsSettings else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                _ = try await checked(["op": "index-settings", "settings": ["automatic": automatic, "excluded": excluded]])
                await readStatus()
                NotificationCenter.default.post(name: .searchEngineReloaded, object: nil)
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct StorageSettingsView: View {
    @ObservedObject private var language = LanguageSettings.shared
    @ObservedObject var permissions: StoragePermissions
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var selectedDisk = "/"
    @State private var selectedExclusion: String?

    private var selectedVolume: StorageVolume? { permissions.volumes.first { $0.path == selectedDisk } }

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 10) {
                SettingsRow(L("自动更新内置硬盘索引")) {
                    Toggle(L("自动更新内置硬盘索引"), isOn: Binding(get: { permissions.automatic }, set: permissions.setAutomatic))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(permissions.busy || !permissions.supportsSettings)
                }
                SettingsNote(L("内置硬盘随文件变化更新；外置磁盘和网络磁盘通过“更新索引”更新。"))
                if !permissions.supportsSettings && !permissions.busy && permissions.fullAccess != nil {
                    HStack {
                        SettingsNote(L("当前搜索引擎需要重新载入，才能使用新的索引设置。"))
                        Spacer()
                        Button(L("重新载入")) { Task { await permissions.reload() } }
                            .disabled(permissions.indexing)
                    }
                }
            }
            Divider()
            diskSection
            Divider()
            exclusionsSection
            Divider()
            permissionSection
            if let error = permissions.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .task {
            await permissions.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                await permissions.refresh(verifyAccess: false)
            }
        }
        .onChange(of: permissions.volumes.map(\.path)) { paths in
            if selectedDisk != "/" && !paths.contains(selectedDisk) { selectedDisk = "/" }
        }
    }

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("磁盘")).fontWeight(.medium)
                Spacer()
                if permissions.busy { ProgressView().controlSize(.small) }
                Button(L("刷新")) { Task { await permissions.refresh() } }.disabled(permissions.busy)
            }
            VStack(spacing: 0) {
                diskRow(L("内置硬盘"), path: "/", symbol: "internaldrive",
                    status: permissions.internalBuilding ? L("正在更新…") : permissions.internalUpdated == nil ? L("尚未就绪") : permissions.automatic ? L("实时更新") : L("已暂停自动更新"),
                    entries: permissions.internalEntries, updated: permissions.internalUpdated ?? permissions.internalCompleted)
                ForEach(permissions.volumes) { volume in
                    Divider()
                    diskRow(volume.name, path: volume.path, symbol: "externaldrive",
                        status: volume.status, entries: volume.entries, updated: volume.updated)
                }
            }
            HStack {
                if let volume = selectedVolume {
                    Text(volume.path).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(volume.path)
                }
                Spacer()
                if let volume = selectedVolume, volume.readable != true {
                    Button(L("允许访问")) { permissions.requestVolumeAccess(volume) }
                        .disabled(permissions.busy || volume.building)
                }
                Button(L("更新索引")) { Task { await permissions.rebuild(selectedVolume) } }
                    .disabled(permissions.busy || (selectedVolume.map { $0.building || $0.readable != true } ?? permissions.internalBuilding))
            }
            if let error = selectedVolume?.error ?? (selectedDisk == "/" ? permissions.internalError : nil) {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
        }
    }

    private func diskRow(_ title: String, path: String, symbol: String, status: String, entries: Int?, updated: Date?) -> some View {
        let selected = selectedDisk == path
        let secondary = selected ? AppAppearance.onAccent.opacity(0.85) : AppAppearance.muted
        return Button { selectedDisk = path } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(secondary)
                    .frame(width: 30).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).lineLimit(1)
                    HStack(spacing: 10) {
                        if let entries { Text(L("\(String(describing: entries.formatted())) 项")) }
                        if let updated { Text(updated.formatted(date: .numeric, time: .shortened)) }
                    }.font(.system(size: 11)).foregroundStyle(secondary)
                }
                Spacer(minLength: 12)
                Text(status).font(.system(size: 12)).foregroundStyle(secondary).lineLimit(2)
            }
            .foregroundStyle(selected ? AppAppearance.onAccent : AppAppearance.text)
            .padding(.horizontal, 10).frame(height: 65)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AppAppearance.selection : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedDisk == path ? .isSelected : [])
    }

    private var exclusionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("排除文件夹")).fontWeight(.medium)
                Spacer()
                Button(L("移除")) {
                    if let selectedExclusion { permissions.removeExcludedFolder(selectedExclusion); self.selectedExclusion = nil }
                }.disabled(selectedExclusion == nil || permissions.busy || !permissions.supportsSettings)
                Button(L("添加…"), action: permissions.addExcludedFolders)
                    .disabled(permissions.busy || !permissions.supportsSettings)
            }
            if permissions.excludedFolders.isEmpty {
                SettingsNote(L("未排除任何文件夹"))
            } else {
                VStack(spacing: 0) {
                    ForEach(permissions.excludedFolders, id: \.self) { path in
                        Button { selectedExclusion = path } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(selectedExclusion == path ? AppAppearance.onAccent.opacity(0.85) : AppAppearance.muted)
                                Text(path).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(selectedExclusion == path ? AppAppearance.onAccent : AppAppearance.text)
                            .padding(.horizontal, 10).frame(height: 32)
                            .background(selectedExclusion == path ? AppAppearance.selection : .clear)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(path)
                            .accessibilityAddTraits(selectedExclusion == path ? .isSelected : [])
                    }
                }
            }
            SettingsNote(L("排除后立即从搜索结果隐藏，并停止扫描文件夹内的内容。移除排除项后，请更新所在磁盘的索引。"))
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow(L("完全磁盘访问")) {
                Text(permissions.fullAccess == nil ? L("正在检查…") : permissions.fullAccess == true ? L("已允许") : L("未允许"))
                    .foregroundStyle(.secondary)
                if permissions.fullAccess == true && permissions.activeAccess {
                    Menu(L("权限选项")) {
                        Button(L("检查权限")) { Task { await permissions.refresh() } }
                        Button(L("显示应用位置"), action: permissions.showApplication)
                        Button(L("重新载入权限")) { Task { await permissions.reload() } }
                    }.fixedSize().disabled(permissions.busy || permissions.indexing)
                } else {
                    Button(L("打开系统设置"), action: permissions.requestFullAccess)
                }
            }
            if permissions.fullAccess != true || !permissions.activeAccess {
                HStack {
                    if permissions.fullAccess == true {
                        SettingsNote(L("权限已更新，请重新载入。"))
                    }
                    Spacer()
                    Button(L("显示应用位置"), action: permissions.showApplication)
                    Button(L("重新载入权限")) { Task { await permissions.reload() } }
                        .disabled(permissions.busy || permissions.indexing)
                }
            }
        }
    }
}
