import AppKit
import SwiftUI

private final class RelayFeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Non-activating, mouse-transparent local feedback. No notification permission.
@MainActor
final class RelayFeedbackController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    func show(_ message: String) {
        let window = panel ?? RelayFeedbackPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 92),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel = window
        window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = true; window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = NSHostingView(rootView:
            HStack(spacing: 12) {
                Image(systemName: "paperplane").font(.title2)
                Text(message).font(.system(size: 13, weight: .medium)).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18).frame(width: 400, height: 92)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)))
        if let frame = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: frame.midX - 200, y: frame.maxY - 112))
        }
        window.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }
}
