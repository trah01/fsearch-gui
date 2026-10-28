import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing

private struct FileMetadata: Sendable {
    let kind: String?
    let size: Int?
    let created: Date?
    let modified: Date?
    let accessed: Date?
    let tags: [String]
}

struct FileInspector: View {
    @ObservedObject private var language = LanguageSettings.shared
    let hit: SearchHit?
    @ObservedObject var model: SearchModel
    @ObservedObject private var appearance = AppearanceSettings.shared
    let preview: (SearchHit) -> Void
    @StateObject private var details = FileDetails()
    @State private var copied = false
    @State private var copiedFile = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 740
            if let hit {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: compact ? 14 : 20) {
                        summary(hit, compact: compact)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(L("信息")).font(.system(size: 13, weight: .semibold)).padding(.bottom, 8)
                            infoRow(L("种类"), details.kind)
                            infoRow(L("大小"), details.size ?? hit.sizeText)
                            infoRow(L("位置"), (hit.path as NSString).deletingLastPathComponent)
                            infoRow(L("创建时间"), details.created ?? hit.createdText)
                            infoRow(L("修改时间"), details.modified ?? hit.modifiedText)
                            infoRow(L("上次访问"), details.accessed ?? "—")
                            if !details.tags.isEmpty {
                                infoRow(L("标签"), details.tags.joined(separator: Localization.languageCode == "en" ? ", " : "、"))
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L("路径")).font(.system(size: 14, weight: .semibold))
                            HStack(spacing: 8) {
                                Image(systemName: hit.isDirectory ? "folder" : "doc").foregroundStyle(.secondary)
                                Text(hit.path).font(.system(size: 11)).lineLimit(3).truncationMode(.middle)
                                    .textSelection(.enabled).help(hit.path)
                                Spacer(minLength: 0)
                                Button { copy(hit) } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                                    .buttonStyle(.plain).accessibilityLabel(copied ? L("已复制路径") : L("复制路径"))
                            }
                            .padding(10).floatingSurface(radius: 12)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L("更多操作")).font(.system(size: 14, weight: .semibold))
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                action(L("在访达中显示"), symbol: "folder") { model.reveal(hit) }
                                action(copied ? L("已复制路径") : L("复制路径"), symbol: copied ? "checkmark" : "doc.on.doc") { copy(hit) }
                                action(L("快速查看"), symbol: "eye") { preview(hit) }
                                action(L("在终端中打开"), symbol: "terminal") { model.openTerminal(hit) }
                            }
                        }
                        if let error = details.error {
                            Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(compact ? 14 : 18)
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 40, weight: .ultraLight))
                    Text(L("选择文件查看详情")).font(.system(size: 13))
                }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.clear)
        .task(id: hit.map { "\($0.path):\($0.modified.timeIntervalSince1970):\(Localization.languageCode)" }) {
            copied = false
            copiedFile = false
            await details.load(hit)
        }
    }

    private func summary(_ hit: SearchHit, compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 10) {
            Group {
                if let image = details.image { Image(nsImage: image).resizable().scaledToFit() }
                else { Image(systemName: hit.isDirectory ? "folder.fill" : "doc.fill").resizable().scaledToFit().foregroundStyle(.secondary) }
            }
            .frame(width: compact ? 88 : 124, height: compact ? 88 : 124).padding(.top, 4).padding(.bottom, 2)
            .shadow(color: AppAppearance.shadow, radius: 12, x: 0, y: 6)
            Text(hit.name).font(.system(size: 17, weight: .semibold)).lineLimit(2).truncationMode(.middle)
                .multilineTextAlignment(.center).textSelection(.enabled)
            Text("\(details.kind) · \(details.size ?? hit.sizeText)")
                .font(.system(size: 12)).foregroundStyle(AppAppearance.muted).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button { model.open(hit) } label: {
                    Label(L("打开"), systemImage: "arrow.up.forward.square").font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 20)
                }.buttonStyle(FloatingButtonStyle(radius: 18, prominent: true))
                Button { copyFile(hit) } label: {
                    Text(copiedFile ? L("已复制") : L("复制")).font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 20)
                }
                .buttonStyle(FloatingButtonStyle(radius: 18))
                .help(L("复制文件，可粘贴到访达或其他支持文件的软件"))
                .accessibilityLabel(copiedFile ? L("已复制文件") : L("复制文件"))
                PopupButton(actions: [
                    PopupAction(L("快速查看")) { preview(hit) },
                    PopupAction(L("在访达中显示")) { model.reveal(hit) },
                    PopupAction(L("复制文件")) { copyFile(hit) },
                    PopupAction(L("复制路径")) { copy(hit) },
                    PopupAction(L("在终端中打开")) { model.openTerminal(hit) }
                ], chevron: false) {
                    Image(systemName: "ellipsis").frame(width: 18, height: 18)
                        .padding(10).floatingSurface(radius: 19)
                }.fixedSize().accessibilityLabel(L("文件操作"))
            }.padding(.top, 4)
        }.padding(compact ? 10 : 14).frame(maxWidth: .infinity)
            .background(AppAppearance.secondary.opacity(0.65), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(title).foregroundStyle(AppAppearance.muted).fixedSize()
                Spacer(minLength: 0)
                Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
            }.font(.system(size: 11)).padding(.top, 4)
            Rectangle().fill(AppAppearance.separator).frame(height: 0.5)
        }
    }

    private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol).font(.system(size: 12)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 16)
        }.buttonStyle(FloatingButtonStyle(radius: 11)).help(title)
    }

    private func copy(_ hit: SearchHit) { model.copyPath(hit); copied = true; copiedFile = false }
    private func copyFile(_ hit: SearchHit) {
        copiedFile = model.copyFile(hit)
        if copiedFile { copied = false }
    }
}

@MainActor
private final class FileDetails: ObservableObject {
    @Published var image: NSImage?
    @Published var kind = L("文件")
    @Published var size: String?
    @Published var created: String?
    @Published var modified: String?
    @Published var accessed: String?
    @Published var tags: [String] = []
    @Published var error: String?

    func load(_ hit: SearchHit?) async {
        image = nil; size = nil; created = nil; modified = nil; accessed = nil; tags = []; error = nil
        guard let hit else { return }
        let url = URL(fileURLWithPath: hit.path)
        kind = hit.kindText
        let values: FileMetadata? = await Task.detached(priority: .userInitiated) {
            guard let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .creationDateKey,
                .contentModificationDateKey, .contentAccessDateKey, .tagNamesKey]) else { return nil }
            return FileMetadata(kind: values.localizedTypeDescription, size: values.fileSize,
                created: values.creationDate, modified: values.contentModificationDate,
                accessed: values.contentAccessDate, tags: values.tagNames ?? [])
        }.value
        guard !Task.isCancelled else { return }
        image = NSWorkspace.shared.icon(forFile: hit.path)
        if let values {
            kind = values.kind ?? hit.kindText
            size = hit.isDirectory ? "—" : values.size.map { SearchFormatting.size(Int64($0)) }
            created = values.created?.formatted(SearchFormatting.date)
            modified = values.modified?.formatted(SearchFormatting.date)
            accessed = values.accessed?.formatted(SearchFormatting.date)
            tags = values.tags
        } else { error = L("无法读取文件信息，文件可能已移动或没有访问权限。") }
        guard !hit.isDirectory else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 200, height: 200), scale: 2, representationTypes: .thumbnail)
        await withTaskCancellationHandler {
            let thumbnail: NSImage? = await withCheckedContinuation { continuation in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                    continuation.resume(returning: representation?.nsImage)
                }
            }
            if !Task.isCancelled, let thumbnail { image = thumbnail }
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request)
        }
    }
}
