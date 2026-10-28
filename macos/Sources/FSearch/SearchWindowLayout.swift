import Foundation

enum SearchWindowLayout {
    static func sidebarWidth(for width: CGFloat) -> CGFloat {
        width < 1100 ? 208 : min(260, width * 0.19)
    }

    static func inspectorWidth(for width: CGFloat) -> CGFloat {
        width < 1250 ? 264 : min(332, width * 0.23)
    }

    static func minimumWidth(showSidebar: Bool, showInspector: Bool) -> CGFloat {
        // Keep the results and search usable when either sidebar is opened.
        max(820, 600 + (showSidebar ? 209 : 0) + (showInspector ? 265 : 0))
    }
}
