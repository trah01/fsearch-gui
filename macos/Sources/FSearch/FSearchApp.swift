import SwiftUI
import AppKit

@main
struct FSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: SearchModel
    @StateObject private var permissions: StoragePermissions
    @StateObject private var updater = AppUpdater.shared
    @StateObject private var language = LanguageSettings.shared

    init() {
        let client = SearchClient()
        _model = StateObject(wrappedValue: SearchModel(client: client))
        _permissions = StateObject(wrappedValue: StoragePermissions(client: client))
    }

    var body: some Scene {
        Window("FSearch", id: "search") {
            SearchWindowRoot(model: model, delegate: appDelegate)
                .environment(\.locale, language.locale)
        }
        .defaultSize(width: 1440, height: 860)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(L("检查更新…"), action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandMenu(L("搜索")) {
                Button(L("显示搜索窗口"), action: appDelegate.showSearchWindow).keyboardShortcut("0")
                Divider()
                Button(L("选择搜索文件夹…"), action: model.chooseFolder).keyboardShortcut("o")
                Button(L("清除文件夹限制")) { model.scope = "" }.disabled(model.scope.isEmpty)
            }
        }
        Settings {
            AppSettingsView(permissions: permissions)
                .environment(\.locale, language.locale)
        }
    }
}
