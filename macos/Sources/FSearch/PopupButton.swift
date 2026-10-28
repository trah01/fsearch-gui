import SwiftUI
import AppKit

struct PopupAction {
    let title: String?
    var selected = false
    var enabled = true
    let perform: () -> Void

    init(_ title: String, selected: Bool = false, enabled: Bool = true, perform: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.enabled = enabled
        self.perform = perform
    }
    private init() { title = nil; perform = {} }
    static var separator: PopupAction { PopupAction() }
}

/// SwiftUI draws the complete control; AppKit supplies the accessible popup.
/// Native Menu styling otherwise replaces custom labels on newer macOS releases.
struct PopupButton<Label: View>: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let actions: [PopupAction]
    var chevron = true
    var chipActive: Bool?
    var emphasized = false
    var toolbarControl = false
    @ViewBuilder let label: () -> Label
    @StateObject private var anchor = PopupAnchor()

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            let menu = NSMenu()
            for action in actions {
                guard let title = action.title else { menu.addItem(.separator()); continue }
                let item = ClosureMenuItem(title: title, perform: action.perform)
                item.state = action.selected ? .on : .off
                item.isEnabled = action.enabled
                menu.addItem(item)
            }
            menu.autoenablesItems = false
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
        } label: {
            if let active = chipActive {
                content
                    .font(.system(size: 12))
                    .foregroundStyle(emphasized || active ? AppAppearance.onAccent : AppAppearance.text)
                    .padding(.horizontal, 11).frame(height: 36)
                    .background {
                        Capsule().fill(emphasized || active ? AppAppearance.selection : AppAppearance.secondary)
                    }
                    .overlay(Capsule().strokeBorder(emphasized || active ? AppAppearance.onAccent.opacity(0.25) : AppAppearance.border.opacity(0.75), lineWidth: 1))
                    .shadow(color: AppAppearance.shadow.opacity(0.5), radius: 6, x: 0, y: 3)
                    .contentShape(Capsule())
            } else { content }
        }
        .buttonStyle(WindowToolbarButtonStyle(compact: toolbarControl))
        .background(PopupAnchorView(anchor: anchor))
    }
    private var content: some View {
        HStack(spacing: 7) {
            label()
            if chevron { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
        }.fixedSize().contentShape(Rectangle())
    }

}

private final class PopupAnchor: ObservableObject { weak var view: NSView? }

private struct PopupAnchorView: NSViewRepresentable {
    let anchor: PopupAnchor
    func makeNSView(context: Context) -> NSView {
        let view = FlippedAnchorView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

private final class FlippedAnchorView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class ClosureMenuItem: NSMenuItem {
    private let perform: () -> Void
    init(title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { perform() }
}
