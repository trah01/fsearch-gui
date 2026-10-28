import AppKit
import Combine

enum AppInformation {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("开发构建")
    }
    static let projectURL = URL(string: Bundle.main.object(forInfoDictionaryKey: "FSearchProjectURL") as? String
        ?? "https://github.com/trah01/fsearch-gui")!
    static let repository = Bundle.main.object(forInfoDictionaryKey: "FSearchUpdateRepository") as? String
        ?? "trah01/fsearch-gui"
    static let upstreamURL = URL(string: "https://github.com/noahdunnagan/fsearch")!
    static var releasesURL: URL { projectURL.appendingPathComponent("releases") }
}

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private enum State {
        case idle, checking, downloading, preparing
        case available(String), ready(String), failed
    }

    @Published private var state = State.idle
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: "FSearch.automaticallyChecksForUpdates") }
    }
    @Published var automaticallyDownloadsUpdates: Bool {
        didSet { UserDefaults.standard.set(automaticallyDownloadsUpdates, forKey: "FSearch.automaticallyDownloadsUpdates") }
    }

    let isConfigured: Bool
    private var started = false
    private var timer: Timer?
    private var availableRelease: GitHubUpdateRelease?
    private var downloadedArchive: URL?

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .preparing: return true
        default: return false
        }
    }
    var canCheckForUpdates: Bool { isConfigured && !isBusy }
    var hasUpdateAction: Bool {
        switch state {
        case .available, .ready: return true
        default: return false
        }
    }
    var actionTitle: String {
        if case .ready = state { return L("安装并重新启动") }
        return L("下载更新")
    }
    var status: String? {
        switch state {
        case .idle: return nil
        case .checking: return L("正在检查更新…")
        case .downloading: return L("正在下载更新…")
        case .preparing: return L("正在准备安装…")
        case .available(let version): return L("发现新版本 \(String(describing: version))")
        case .ready(let version): return L("版本 \(String(describing: version)) 已下载，重新启动即可安装。")
        case .failed: return L("更新未完成，请重试或前往 GitHub 下载。")
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["FSearch.automaticallyChecksForUpdates": true,
                                     "FSearch.automaticallyDownloadsUpdates": true])
        automaticallyChecksForUpdates = defaults.bool(forKey: "FSearch.automaticallyChecksForUpdates")
        automaticallyDownloadsUpdates = defaults.bool(forKey: "FSearch.automaticallyDownloadsUpdates")
        isConfigured = Bundle.main.bundleURL.pathExtension == "app" && UpdateVersion(AppInformation.version) != nil
    }

    func start() {
        guard isConfigured, !started else { return }
        started = true
        if !UpdateInstaller.finishPreviousInstallation() {
            showError(UpdateError(L("更新安装未完成，已保留原版本。请重试或前往 GitHub 下载。")))
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkAutomaticallyIfNeeded() }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            await self?.checkAutomaticallyIfNeeded()
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        if downloadedArchive != nil { performUpdateAction(); return }
        Task { await check(userInitiated: true) }
    }

    func performUpdateAction() {
        guard canCheckForUpdates, let release = availableRelease else { return }
        if let archive = downloadedArchive {
            let alert = NSAlert()
            alert.messageText = L("安装并重新启动")
            alert.informativeText = L("FSearch 将退出并安装版本 \(String(describing: release.version))，完成后自动重新打开。")
            alert.addButton(withTitle: L("安装并重新启动"))
            alert.addButton(withTitle: L("稍后"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            state = .preparing
            let target = Bundle.main.bundleURL
            Task {
                do {
                    let prepared = try await Task.detached(priority: .utility) {
                        try UpdateInstaller.prepare(archive: archive, version: release.version, target: target)
                    }.value
                    try UpdateInstaller.installAndRelaunch(prepared)
                } catch {
                    state = .ready(release.version)
                    showError(error)
                }
            }
        } else {
            Task { await download(release, userInitiated: true) }
        }
    }

    private func checkAutomaticallyIfNeeded() async {
        guard automaticallyChecksForUpdates, canCheckForUpdates, downloadedArchive == nil else { return }
        let last = UserDefaults.standard.object(forKey: "FSearch.lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 86_400 else { return }
        await check(userInitiated: false)
    }

    private func check(userInitiated: Bool) async {
        guard canCheckForUpdates else { return }
        state = .checking
        do {
            let release = try await GitHubUpdateRelease.latest()
            UserDefaults.standard.set(Date(), forKey: "FSearch.lastUpdateCheck")
            guard let release else {
                availableRelease = nil
                state = .idle
                if userInitiated {
                    let alert = NSAlert()
                    alert.messageText = L("当前已是最新版本")
                    alert.informativeText = L("当前版本：\(String(describing: AppInformation.version))")
                    alert.addButton(withTitle: L("好"))
                    alert.runModal()
                }
                return
            }
            availableRelease = release
            state = .available(release.version)
            if userInitiated {
                let alert = NSAlert()
                alert.messageText = L("发现新版本 \(String(describing: release.version))")
                alert.informativeText = L("下载完成后可安装并重新启动，搜索设置和索引会保留。")
                alert.addButton(withTitle: L("下载更新"))
                alert.addButton(withTitle: L("稍后"))
                if alert.runModal() == .alertFirstButtonReturn { await download(release, userInitiated: true) }
            } else if automaticallyDownloadsUpdates {
                await download(release, userInitiated: false)
            }
        } catch {
            state = .failed
            if userInitiated { showError(error) }
        }
    }

    private func download(_ release: GitHubUpdateRelease, userInitiated: Bool) async {
        guard !isBusy else { return }
        state = .downloading
        do {
            downloadedArchive = try await release.download()
            state = .ready(release.version)
            if userInitiated { performUpdateAction() }
        } catch {
            state = .available(release.version)
            if userInitiated { showError(error) }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("无法完成更新")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L("好"))
        alert.addButton(withTitle: L("前往 GitHub"))
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(AppInformation.releasesURL) }
    }
}
