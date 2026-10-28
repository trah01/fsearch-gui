import SwiftUI
import AppKit

/// A native single-line editor with composition-aware text synchronization.
/// Search and clear icons live outside this view so they cannot overlap its editor.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let focus: Int
    let compositionChanged: (Bool) -> Void
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.delegate = context.coordinator
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byClipping
        field.controlSize = .regular
        field.font = .systemFont(ofSize: AppAppearance.searchFontSize, weight: .regular)
        field.textColor = AppAppearance.nativeText
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("搜索")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !composing && field.stringValue != text { field.stringValue = text }
        field.placeholderString = "搜索文件或文件夹…"
        field.placeholderAttributedString = NSAttributedString(string: "搜索文件或文件夹…",
            attributes: [.foregroundColor: AppAppearance.nativeMuted, .font: NSFont.systemFont(ofSize: AppAppearance.searchFontSize)])
        field.toolTip = "空格：同时匹配；!：排除；'：精确匹配；* / ?：通配符；ext:pdf：后缀；size:>1GB：大小；mtime:<7d：最近修改"
        if context.coordinator.lastFocus != focus {
            context.coordinator.lastFocus = focus
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeSearchField
        var lastFocus = -1
        private var composing = false
        init(_ parent: NativeSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            sync(field)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            sync(field)
        }
        private func sync(_ field: NSTextField) {
            let wasComposing = composing
            composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
            if composing != wasComposing { parent.compositionChanged(composing) }
            guard !composing else { return }
            if wasComposing || parent.text != field.stringValue { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.submit()
                return true
            }
            return false
        }
    }
}
