import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var searchWindow: NSWindow?
    var reopenSearch: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppearanceSettings.shared.applyAppearance()
        AppUpdater.shared.start()
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: icon)
        }
        NSApp.activate(ignoringOtherApps: true)
        GeneralSettings.shared.activate { [weak self] in
            self?.showSearchWindow()
            NotificationCenter.default.post(name: .focusSearchField, object: nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        GeneralSettings.shared.quitWhenClosed
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSearchWindow()
        return false
    }

    func showSearchWindow() {
        if let window = searchWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
        } else {
            reopenSearch?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SearchWindowRoot: View {
    @ObservedObject var model: SearchModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage("FSearch.showSidebar") private var showSidebar = true
    @AppStorage("FSearch.showInspector") private var showInspector = true

    var body: some View {
        let minimumWidth = SearchWindowLayout.minimumWidth(showSidebar: showSidebar, showInspector: showInspector)
        SearchView(model: model)
            .frame(minWidth: minimumWidth, minHeight: 560)
            .background(WindowRegistration(minimumWidth: minimumWidth) { delegate.searchWindow = $0 })
            .onAppear { delegate.reopenSearch = { openWindow(id: "search") } }
    }
}

private struct WindowRegistration: NSViewRepresentable {
    let minimumWidth: CGFloat
    let register: (NSWindow) -> Void
    func makeNSView(context: Context) -> RegistrationView {
        RegistrationView(minimumWidth: minimumWidth, register: register)
    }
    func updateNSView(_ view: RegistrationView, context: Context) {
        guard view.minimumWidth != minimumWidth else { return }
        view.minimumWidth = minimumWidth
        view.scheduleResize()
    }

    final class RegistrationView: NSView {
        var minimumWidth: CGFloat
        let register: (NSWindow) -> Void
        private var resizeScheduled = false

        init(minimumWidth: CGFloat, register: @escaping (NSWindow) -> Void) {
            self.minimumWidth = minimumWidth
            self.register = register
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = true
                window.isMovableByWindowBackground = true
                register(window)
                scheduleResize()
            }
        }

        func scheduleResize() {
            guard !resizeScheduled else { return }
            resizeScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.resizeScheduled = false
                guard let window = self.window else { return }
                window.contentMinSize = NSSize(width: self.minimumWidth, height: 560)
                let width = window.contentRect(forFrameRect: window.frame).width
                guard width < self.minimumWidth else { return }
                var frame = window.frame
                frame.size.width += self.minimumWidth - width
                if let screen = window.screen {
                    let visible = screen.visibleFrame
                    frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
                }
                window.setFrame(frame, display: true, animate: false)
            }
        }
    }
}
