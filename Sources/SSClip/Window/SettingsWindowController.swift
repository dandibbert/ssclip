import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(store: ClipboardStore, settings: AppSettings) {
        let contentView = SettingsView()
            .environmentObject(store)
            .environmentObject(settings)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 446),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SSClip 设置"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: contentView)
        window.setContentSize(NSSize(width: 580, height: 446))
        window.contentMinSize = NSSize(width: 580, height: 446)
        window.contentMaxSize = NSSize(width: 580, height: 446)
        window.center()
        window.setFrameAutosaveName("SSClipSettingsWindow")
        self.window = window
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
