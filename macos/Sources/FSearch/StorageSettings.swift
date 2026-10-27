import AppKit
import SwiftUI

extension Notification.Name {
    static let searchEngineReloaded = Notification.Name("FSearch.searchEngineReloaded")
}

struct StorageVolume: Identifiable {
    let name: String
    let path: String
    let readable: Bool?
    let included: Bool
    let building: Bool
    let entries: Int?
    let error: String?
    var id: String { path }
    var status: String {
        if building { return "正在重建索引…" }
        if readable == false { return "无法读取" }
        if included { return entries.map { "已建立索引 · \($0) 项" } ?? "已建立索引" }
        return readable == true ? "未建立索引" : "未授权，未建立索引"
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
            throw ClientError.message(response["error"] as? String ?? "操作失败，请重试。")
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
            internalCompleted = (internalIndex["indexed_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
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
        panel.title = "允许访问磁盘“\(volume.name)”"
        panel.message = "请选择此磁盘的根目录，以允许 FSearch 读取其中的文件。"
        panel.directoryURL = URL(fileURLWithPath: volume.path)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "允许访问"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL.path == volume.path else {
            error = "请选择磁盘“\(volume.name)”的根目录。"
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
}

struct StorageSettingsView: View {
    @ObservedObject var permissions: StoragePermissions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("存储与索引").font(.headline)
                Spacer()
                if permissions.busy { ProgressView().controlSize(.small) }
                Button("检查权限") { Task { await permissions.refresh() } }.disabled(permissions.busy)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("完全磁盘访问")
                    Spacer()
                    Text(permissions.fullAccess == nil ? "尚未检查" : permissions.fullAccess == true ? "已授权" : "未授权").foregroundStyle(.secondary)
                    Button("申请权限", action: permissions.requestFullAccess)
                }
                HStack {
                    Text("用于读取内置硬盘中的受保护文件夹。").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("显示应用位置", action: permissions.showApplication)
                    Button("重新载入权限") { Task { await permissions.reload() } }
                        .disabled(permissions.busy || permissions.indexing)
                }
                if permissions.fullAccess == true && !permissions.activeAccess {
                    Text("权限已更新，请重新载入权限。").font(.callout).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text("内置硬盘").font(.headline)
                Spacer()
                if permissions.internalBuilding {
                    ProgressView().controlSize(.small)
                    Text("正在重建索引…").foregroundStyle(.secondary)
                } else if let date = permissions.internalCompleted {
                    Text(date.formatted(date: .numeric, time: .shortened)).font(.callout).foregroundStyle(.secondary)
                }
                Button("重建索引") { Task { await permissions.rebuild() } }
                    .disabled(permissions.busy || permissions.internalBuilding)
            }
            if let error = permissions.internalError { Text(error).font(.callout).foregroundStyle(.red) }
            Divider()
            HStack {
                Text("已挂载的磁盘").font(.headline)
                Spacer()
                Text("\(permissions.volumes.count) 个").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if permissions.volumes.isEmpty {
                        Text("未发现已挂载的外置磁盘").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(permissions.volumes) { volume in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                Image(systemName: "externaldrive").foregroundStyle(.secondary).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(volume.name).lineLimit(1)
                                    Text(volume.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(volume.status).font(.callout).foregroundStyle(.secondary)
                                    .frame(width: 160, alignment: .trailing).lineLimit(2)
                                Button(volume.readable == true ? "已允许访问" : "申请权限") { permissions.requestVolumeAccess(volume) }
                                    .disabled(permissions.busy || volume.readable == true)
                                Button("重建索引") { Task { await permissions.rebuild(volume) } }
                                    .disabled(permissions.busy || volume.building || volume.readable != true)
                            }
                            if let error = volume.error { Text(error).font(.callout).foregroundStyle(.red) }
                        }
                    }
                }
            }
            if let error = permissions.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(24).frame(width: 760, height: 520)
        .background(AppAppearance.background)
        .task {
            await permissions.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                if permissions.indexing { await permissions.refresh(verifyAccess: false) }
            }
        }
    }
}
