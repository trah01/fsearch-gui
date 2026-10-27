import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var searchWindow: NSWindow?
    var reopenSearch: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: icon)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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

    var body: some View {
        SearchView(model: model)
            .frame(minWidth: 820, minHeight: 560)
            .background(WindowRegistration { delegate.searchWindow = $0 })
            .onAppear { delegate.reopenSearch = { openWindow(id: "search") } }
    }
}

private struct WindowRegistration: NSViewRepresentable {
    let register: (NSWindow) -> Void
    func makeNSView(context: Context) -> RegistrationView { RegistrationView(register: register) }
    func updateNSView(_ view: RegistrationView, context: Context) {}

    final class RegistrationView: NSView {
        let register: (NSWindow) -> Void
        init(register: @escaping (NSWindow) -> Void) {
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
            }
        }
    }
}
