import SwiftUI
import AppKit

@main
struct FSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: SearchModel
    @StateObject private var permissions: StoragePermissions

    init() {
        let client = SearchClient()
        _model = StateObject(wrappedValue: SearchModel(client: client))
        _permissions = StateObject(wrappedValue: StoragePermissions(client: client))
    }

    var body: some Scene {
        Window("FSearch", id: "search") {
            SearchWindowRoot(model: model, delegate: appDelegate)
        }
        .defaultSize(width: 1440, height: 860)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("搜索") {
                Button("显示搜索窗口", action: appDelegate.showSearchWindow).keyboardShortcut("0")
                Divider()
                Button("选择搜索文件夹…", action: model.chooseFolder).keyboardShortcut("o")
                Button("清除文件夹限制") { model.scope = "" }.disabled(model.scope.isEmpty)
            }
        }
        Settings {
            AppSettingsView(permissions: permissions)
        }
    }
}
