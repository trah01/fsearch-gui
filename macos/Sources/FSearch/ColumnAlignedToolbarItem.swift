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
        view.updateGeometry(leadingEdge: leadingEdge, trailingEdge: trailingEdge, height: height)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ColumnToolbarContainer<Content>, context: Context) -> CGSize? {
        let preferred = nsView.intrinsicContentSize
        let width = proposal.width.map { min(preferred.width, max(ColumnToolbarContainer<Content>.minimumWidth, $0)) }
            ?? preferred.width
        return CGSize(width: width, height: height)
    }
}

final class ColumnToolbarContainer<Content: View>: NSView {
    static var minimumWidth: CGFloat { 300 }
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
        // This host is framed manually; its SwiftUI content must not change
        // the outer toolbar item's intrinsic size on every search update.
        host.sizingOptions = []
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateGeometry(leadingEdge: CGFloat, trailingEdge: CGFloat, height: CGFloat) {
        guard abs(self.leadingEdge - leadingEdge) > 0.5 || abs(self.trailingEdge - trailingEdge) > 0.5
                || self.contentHeight != height else { return }
        let previousSize = intrinsicContentSize
        self.leadingEdge = leadingEdge
        self.trailingEdge = trailingEdge
        contentHeight = height
        needsLayout = true
        if intrinsicContentSize != previousSize { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize {
        // Before attachment the toolbar origin is unknown. Asking for the
        // entire window here can overflow the item before it is ever laid out.
        NSSize(width: measuredOrigin == nil ? Self.minimumWidth : max(Self.minimumWidth, leadingSpace + contentWidth),
               height: contentHeight)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let currentOrigin = convert(.zero, to: nil).x
        if window != nil && (measuredOrigin == nil || abs(currentOrigin - origin) > 0.5) {
            measuredOrigin = currentOrigin
            invalidateIntrinsicContentSize()
        }
        let inset = min(leadingSpace, max(0, bounds.width - Self.minimumWidth))
        let width = max(0, min(contentWidth, bounds.width - inset))
        let frame = NSRect(x: inset, y: max(0, (bounds.height - contentHeight) / 2), width: width, height: contentHeight)
        if host.frame != frame { host.frame = frame }
    }
}
