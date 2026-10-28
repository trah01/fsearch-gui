import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @ObservedObject private var language = LanguageSettings.shared
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        SettingsPane {
            HStack(spacing: 14) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("FSearch").font(.system(size: 16, weight: .semibold))
                    Text(L("版本 \(String(describing: AppInformation.version))")).foregroundStyle(.secondary)
                }
                Spacer()
                Link(L("GitHub 项目"), destination: AppInformation.projectURL)
            }
            Divider()
            VStack(spacing: 12) {
                SettingsRow(L("软件更新")) {
                    if updater.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Button(L("检查更新…"), action: updater.checkForUpdates)
                        .disabled(!updater.canCheckForUpdates)
                }
                if let status = updater.status {
                    HStack {
                        SettingsNote(status)
                        Spacer()
                        if updater.hasUpdateAction {
                            Button(updater.actionTitle, action: updater.performUpdateAction)
                        }
                    }
                }
                SettingsRow(L("自动检查更新")) {
                    Toggle(L("自动检查更新"), isOn: $updater.automaticallyChecksForUpdates)
                        .labelsHidden().toggleStyle(.switch).disabled(!updater.isConfigured)
                }
                SettingsRow(L("自动下载更新")) {
                    Toggle(L("自动下载更新"), isOn: $updater.automaticallyDownloadsUpdates)
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!updater.isConfigured || !updater.automaticallyChecksForUpdates)
                }
            }
            if updater.isConfigured {
                SettingsNote(L("更新在应用内下载并校验，安装后重新启动即可使用新版本。"))
            } else {
                HStack {
                    SettingsNote(L("此构建暂不支持自动更新，可前往 GitHub 下载新版本。"))
                    Spacer()
                    Link(L("下载更新"), destination: AppInformation.releasesURL)
                }
            }
            Divider()
            SettingsRow(L("项目主页")) {
                Link("trah01/fsearch-gui", destination: AppInformation.projectURL)
            }
            SettingsRow(L("原项目")) {
                Link("noahdunnagan/fsearch", destination: AppInformation.upstreamURL)
            }
            SettingsRow(L("开源许可")) { Text("MIT").foregroundStyle(.secondary) }
            SettingsNote(L("基于 Noah Dunnagan 的 fsearch 开发，感谢原作者及贡献者。"))
        }
    }
}
