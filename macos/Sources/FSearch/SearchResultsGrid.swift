import SwiftUI
import AppKit

struct SearchResultsGrid: View {
    @ObservedObject var model: SearchModel
    @ObservedObject private var appearance = AppearanceSettings.shared
    @FocusState private var focused: Bool
    let preview: (SearchHit) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(GridAnchor.top)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 12)], spacing: 12) {
                        ForEach(model.hits) { hit in
                            FileGridItem(hit: hit, selected: model.selected == hit.path)
                                .onAppear { model.loadMoreIfNeeded(lastVisibleRow: model.row(for: hit.path) ?? -1) }
                                .onTapGesture(count: 2) { model.selected = hit.path; model.open(hit) }
                                .onTapGesture { model.selected = hit.path; focused = true }
                                .onDrag {
                                    model.selected = hit.path
                                    focused = true
                                    return NSItemProvider(object: hit.fileURL as NSURL)
                                }
                                .contextMenu {
                                    Button("打开") { model.open(hit) }
                                    Button("快速查看") { preview(hit) }
                                    Button("在访达中显示") { model.reveal(hit) }
                                    Button("复制文件") { model.copyFile(hit) }
                                    Button("复制路径") { model.copyPath(hit) }
                                    Button("在终端中打开") { model.openTerminal(hit) }
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(hit.name)，\(hit.kindText)，\(hit.sizeText)")
                                .accessibilityAddTraits(model.selected == hit.path ? [.isButton, .isSelected] : .isButton)
                                .accessibilityAction { model.selected = hit.path }
                                .accessibilityAction(named: Text("打开")) { model.open(hit) }
                        }
                    }.padding(4).padding(.trailing, 16)
                }
            }
            .onChange(of: model.scrollToTopRevision) { _ in
                proxy.scrollTo(GridAnchor.top, anchor: .top)
            }
        }
        .focusable()
        .focused($focused)
        .onCopyCommand {
            guard let hit = model.selectedHit else { return [] }
            return [NSItemProvider(object: hit.fileURL as NSURL)]
        }
        .onMoveCommand { direction in
            guard !model.hits.isEmpty else { return }
            let current = model.selected.flatMap { model.row(for: $0) } ?? -1
            let step = direction == .left || direction == .up ? -1 : 1
            let next = min(model.hits.count - 1, max(0, current + step))
            model.selected = model.hits[next].path
        }
        .background(Button("") { if let hit = model.selectedHit { preview(hit) } }
            .keyboardShortcut(.space, modifiers: []).hidden())
    }
}

private enum GridAnchor: Hashable { case top }

private struct FileGridItem: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let hit: SearchHit
    let selected: Bool
    @State private var icon: NSImage?
    @State private var operation: Operation?

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let icon { Image(nsImage: icon).resizable().scaledToFit() }
                else { Image(systemName: hit.isDirectory ? "folder" : "doc").resizable().scaledToFit().foregroundStyle(.secondary) }
            }.frame(width: 58, height: 58).padding(.top, 12)
            Text(hit.name).font(.system(size: 12, weight: .medium)).lineLimit(2).truncationMode(.middle)
                .multilineTextAlignment(.center).frame(height: 32)
                .foregroundStyle(selected ? AppAppearance.onResultSelection : AppAppearance.text)
            Text(hit.sizeText).font(.system(size: 10))
                .foregroundStyle(selected ? AppAppearance.onResultSelection.opacity(0.85) : AppAppearance.muted)
        }
        .padding(10).frame(maxWidth: .infinity).frame(height: 146)
        .background(selected ? AppAppearance.resultSelection : AppAppearance.panel, in: RoundedRectangle(cornerRadius: AppAppearance.corner))
        .overlay(RoundedRectangle(cornerRadius: AppAppearance.corner).strokeBorder(selected ? AppAppearance.accent.opacity(0.4) : AppAppearance.separator))
        .shadow(color: AppAppearance.shadow.opacity(0.5), radius: 8, x: 0, y: 3)
        .contentShape(Rectangle()).help(hit.path)
        .onAppear {
            if let value = FilePresentationLoader.shared.cached(hit) { icon = value.icon }
            else { operation = FilePresentationLoader.shared.load(hit) { icon = $0.icon } }
        }
        .onDisappear { operation?.cancel(); operation = nil }
    }
}
