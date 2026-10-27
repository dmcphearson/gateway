import SwiftUI
import Cocoa

struct LiquidGlassContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
    }
}

class WindowManager {
    static let shared = WindowManager()

    private var windows: [String: NSWindow] = [:]

    private init() {}

    func showWindow<Content: View>(
        id: String,
        title: String,
        size: NSSize,
        style: NSWindow.StyleMask = [.titled, .closable],
        content: Content
    ) {
        if let existingWindow = windows[id] {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: style,
            backing: .buffered,
            defer: false
        )

        window.title = title
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = true
        window.contentView = NSHostingView(rootView: LiquidGlassContainer { content })

        let delegate = WindowDelegate(id: id, manager: self)
        objc_setAssociatedObject(window, "delegateKey", delegate, .OBJC_ASSOCIATION_RETAIN)
        window.delegate = delegate

        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow(id: String) {
        windows[id]?.close()
        windows.removeValue(forKey: id)
    }

    fileprivate func windowClosed(id: String) {
        windows.removeValue(forKey: id)
    }

    func showSettingsWindow() {
        showWindow(
            id: "settings",
            title: "Gateway Settings",
            size: NSSize(width: 580, height: 450),
            style: [.titled, .closable, .resizable, .fullSizeContentView],
            content: SettingsView(onClose: { self.closeWindow(id: "settings") })
        )
    }
}

private class WindowDelegate: NSObject, NSWindowDelegate {
    let windowId: String
    unowned let manager: WindowManager

    init(id: String, manager: WindowManager) {
        self.windowId = id
        self.manager = manager
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        manager.windowClosed(id: windowId)
    }
}
