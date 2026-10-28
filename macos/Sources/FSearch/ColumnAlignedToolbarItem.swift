import AppKit
import SwiftUI

/// Align toolbar content with both edges of the results column.
/// Measure in window coordinates so traffic-light spacing stays system-owned.
struct ColumnAlignedToolbarItem<Content: View>: NSViewRepresentable {
    let leadingEdge: CGFloat
    let trailingEdge: CGFloat
    let height: CGFloat
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> ColumnToolbarContainer<Content> {
        ColumnToolbarContainer(content: content, leadingEdge: leadingEdge, trailingEdge: trailingEdge, height: height)
    }

    func updateNSView(_ view: ColumnToolbarContainer<Content>, context: Context) {
        view.host.rootView = content
        view.leadingEdge = leadingEdge
        view.trailingEdge = trailingEdge
        view.contentHeight = height
        view.needsLayout = true
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ColumnToolbarContainer<Content>, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

final class ColumnToolbarContainer<Content: View>: NSView {
    let host: NSHostingView<Content>
    var leadingEdge: CGFloat
    var trailingEdge: CGFloat
    var contentHeight: CGFloat
    private var measuredOrigin: CGFloat?

    private var origin: CGFloat { measuredOrigin ?? leadingEdge }
    private var leadingSpace: CGFloat { max(0, leadingEdge - origin) }
    private var contentWidth: CGFloat { max(0, trailingEdge - max(leadingEdge, origin)) }

    init(content: Content, leadingEdge: CGFloat, trailingEdge: CGFloat, height: CGFloat) {
        host = NSHostingView(rootView: content)
        self.leadingEdge = leadingEdge
        self.trailingEdge = trailingEdge
        contentHeight = height
        super.init(frame: .zero)
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: leadingSpace + contentWidth, height: contentHeight)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let currentOrigin = window == nil ? leadingEdge : convert(.zero, to: nil).x
        if measuredOrigin == nil || abs(currentOrigin - origin) > 0.5 {
            measuredOrigin = currentOrigin
            invalidateIntrinsicContentSize()
        }
        host.frame = NSRect(x: leadingSpace, y: max(0, (bounds.height - contentHeight) / 2), width: contentWidth, height: contentHeight)
    }
}
