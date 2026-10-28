import AppKit
import SwiftUI
import ServiceManagement
import Carbon

enum SearchHotKey: String, CaseIterable, Identifiable {
    case disabled, optionSpace, controlOptionSpace, commandShiftSpace
    var id: String { rawValue }
    var title: String {
        switch self {
        case .disabled: return "关闭"
        case .optionSpace: return "⌥ 空格"
        case .controlOptionSpace: return "⌃ ⌥ 空格"
        case .commandShiftSpace: return "⇧ ⌘ 空格"
        }
    }
    var modifiers: UInt32 {
        switch self {
        case .disabled: return 0
        case .optionSpace: return UInt32(optionKey)
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
        }
    }
}

/// Carbon hot keys work across apps without monitoring keyboard input or
/// requiring Accessibility permission. Registration failures keep the old key.
@MainActor
private final class GlobalSearchHotKey {
    static let shared = GlobalSearchHotKey()
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    var action: (() -> Void)?

    func register(_ choice: SearchHotKey) throws {
        if choice == .disabled {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            return
        }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in GlobalSearchHotKey.shared.action?() }
                return noErr
            }, 1, &event, nil, &handler)
            guard status == noErr else { throw ClientError.message("无法启用全局快捷键，请重新打开应用后重试。") }
        }
        var registered: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x46535243, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_Space), choice.modifiers, identifier, GetApplicationEventTarget(), 0, &registered)
        guard status == noErr else { throw ClientError.message("此快捷键已被占用，请选择其他组合。") }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = registered
    }
}

@MainActor
final class GeneralSettings: ObservableObject {
    static let shared = GeneralSettings()
    @Published private(set) var hotKey: SearchHotKey
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published var error: String?
    @Published var quitWhenClosed: Bool {
        didSet { UserDefaults.standard.set(quitWhenClosed, forKey: "FSearch.quitWhenClosed") }
    }

    private init() {
        hotKey = SearchHotKey(rawValue: UserDefaults.standard.string(forKey: "FSearch.globalHotKey") ?? "") ?? .disabled
        quitWhenClosed = UserDefaults.standard.bool(forKey: "FSearch.quitWhenClosed")
    }

    func activate(action: @escaping () -> Void) {
        GlobalSearchHotKey.shared.action = action
        do { try GlobalSearchHotKey.shared.register(hotKey) }
        catch { self.error = error.localizedDescription }
    }

    func setHotKey(_ value: SearchHotKey) {
        guard value != hotKey else { return }
        do {
            try GlobalSearchHotKey.shared.register(value)
            hotKey = value
            UserDefaults.standard.set(value.rawValue, forKey: "FSearch.globalHotKey")
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled || status == .requiresApproval
        loginNeedsApproval = status == .requiresApproval
    }

    func setLoginEnabled(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch { self.error = "无法修改登录启动设置：\(error.localizedDescription)" }
        refreshLoginStatus()
    }
}

struct GeneralSettingsView: View {
    @ObservedObject private var settings = GeneralSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SettingsPane {
            VStack(spacing: 12) {
                SettingsRow("全局搜索快捷键") {
                    Picker("全局搜索快捷键", selection: Binding(get: { settings.hotKey }, set: settings.setHotKey)) {
                        ForEach(SearchHotKey.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 180)
                }
                SettingsRow("登录时启动") {
                    Toggle("登录时启动", isOn: Binding(get: { settings.loginEnabled }, set: settings.setLoginEnabled))
                        .labelsHidden().toggleStyle(.switch)
                }
                if settings.loginNeedsApproval {
                    HStack {
                        SettingsNote("请在系统设置中允许 FSearch 登录时启动。")
                        Spacer()
                        Button("打开系统设置") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
            Divider()
            SettingsRow("关闭窗口后") {
                Picker("关闭窗口后", selection: $settings.quitWhenClosed) {
                    Text("保持后台运行").tag(false)
                    Text("退出应用").tag(true)
                }.labelsHidden().frame(width: 180)
            }
            if let error = settings.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
        }
        .onAppear { settings.refreshLoginStatus() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { settings.refreshLoginStatus() }
        }
    }
}
