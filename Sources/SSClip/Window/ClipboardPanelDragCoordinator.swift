import AppKit
import SwiftUI

/// SwiftUI 行内拖拽锚点：自身不拦截点击、悬停和右键菜单，只向协调器报告行区域与条目。
struct DragAnchorView: NSViewRepresentable {
    let item: ClipboardItem
    let imagesDirectory: URL
    let coordinator: ClipboardPanelDragCoordinator?

    func makeNSView(context: Context) -> DragAnchorNSView {
        DragAnchorNSView(
            item: item,
            imagesDirectory: imagesDirectory,
            coordinator: coordinator
        )
    }

    func updateNSView(_ nsView: DragAnchorNSView, context: Context) {
        nsView.item = item
        nsView.imagesDirectory = imagesDirectory
        if nsView.coordinator !== coordinator {
            nsView.coordinator?.unregister(nsView)
            nsView.coordinator = coordinator
        }
        if nsView.window != nil {
            coordinator?.register(nsView)
        }
    }
}

@MainActor
final class DragAnchorNSView: NSView {
    var item: ClipboardItem
    var imagesDirectory: URL
    weak var coordinator: ClipboardPanelDragCoordinator?

    init(
        item: ClipboardItem,
        imagesDirectory: URL,
        coordinator: ClipboardPanelDragCoordinator?
    ) {
        self.item = item
        self.imagesDirectory = imagesDirectory
        self.coordinator = coordinator
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            coordinator?.register(self)
        } else {
            coordinator?.unregister(self)
        }
    }

    /// 完全穿透命中测试，避免干扰 SwiftUI 的单击选择、双击粘贴、悬停和右键菜单。
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// 协调快捷列表面板的 AppKit 文件拖出：
/// - 面板内保留点击/双击/右键/快捷键；拖拽超过阈值后以 `NSURL` 开启系统 `NSDraggingSession`
/// - 只允许 `.copy` 操作，避免 Finder 移动原文件或历史图片
/// - 拖拽期间锁定面板不因失焦隐藏，拖拽成功后再收起面板
@MainActor
final class ClipboardPanelDragCoordinator {
    private static let dragThreshold: CGFloat = 5.0

    var onDragWillBegin: (() -> Void)?
    var onDragDidEnd: ((_ succeeded: Bool, _ shouldHidePanel: Bool) -> Void)?
    var onExportFailed: (() -> Void)?

    private(set) var isDragging = false

    private let exporter: ClipboardFileExporter
    private let anchors = NSHashTable<DragAnchorNSView>.weakObjects()
    private weak var monitoredPanel: NSPanel?
    private var mouseMonitor: Any?
    private weak var pendingAnchor: DragAnchorNSView?
    private var mouseDownPointInWindow: NSPoint?
    private var activeDragSource: ActiveDragSource?

    init(exporter: ClipboardFileExporter? = nil) {
        self.exporter = exporter ?? ClipboardFileExporter()
    }

    func register(_ anchor: DragAnchorNSView) {
        anchors.add(anchor)
    }

    func unregister(_ anchor: DragAnchorNSView) {
        anchors.remove(anchor)
        if pendingAnchor === anchor {
            clearPendingDrag()
        }
    }

    func installMonitor(on panel: NSPanel) {
        removeMonitor()
        monitoredPanel = panel
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleMouseEvent(event)
        }
    }

    func removeMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
        monitoredPanel = nil
        clearPendingDrag()
    }

    private func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
        guard let panel = monitoredPanel,
              panel.isVisible,
              event.window === panel
        else {
            if event.type == .leftMouseUp { clearPendingDrag() }
            return event
        }

        switch event.type {
        case .leftMouseDown:
            guard event.clickCount == 1,
                  !event.modifierFlags.contains(.control),
                  !isDragging,
                  let anchor = anchor(atWindowPoint: event.locationInWindow, in: panel)
            else {
                clearPendingDrag()
                return event
            }
            pendingAnchor = anchor
            mouseDownPointInWindow = event.locationInWindow
            return event

        case .leftMouseDragged:
            guard !isDragging,
                  let anchor = pendingAnchor,
                  let start = mouseDownPointInWindow,
                  anchor.window === panel,
                  !anchor.isHiddenOrHasHiddenAncestor
            else {
                return event
            }
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            guard hypot(dx, dy) >= Self.dragThreshold else {
                return event
            }

            clearPendingDrag()
            guard startDragSession(from: anchor, event: event, in: panel) else {
                return event
            }
            return nil

        case .leftMouseUp:
            clearPendingDrag()
            return event

        default:
            return event
        }
    }

    private func anchor(atWindowPoint pointInWindow: NSPoint, in panel: NSPanel) -> DragAnchorNSView? {
        for anchor in anchors.allObjects {
            guard anchor.window === panel,
                  !anchor.isHiddenOrHasHiddenAncestor,
                  anchor.bounds.width > 0,
                  anchor.bounds.height > 0
            else { continue }
            let localPoint = anchor.convert(pointInWindow, from: nil)
            if anchor.bounds.contains(localPoint) {
                return anchor
            }
        }
        return nil
    }

    private func startDragSession(from anchor: DragAnchorNSView, event: NSEvent, in panel: NSPanel) -> Bool {
        let item = anchor.item
        let imagesDirectory = anchor.imagesDirectory
        guard let exported = exporter.export(item, imagesDirectory: imagesDirectory) else {
            onExportFailed?()
            return false
        }

        let localCursor = anchor.convert(event.locationInWindow, from: nil)
        let draggingItems = Self.makeDraggingItems(
            for: exported,
            item: item,
            cursorPoint: localCursor,
            imagesDirectory: imagesDirectory
        )
        guard !draggingItems.isEmpty else {
            exporter.cleanUp(exported)
            onExportFailed?()
            return false
        }

        let exporter = self.exporter
        let source = ActiveDragSource { [weak self, weak panel] operation in
            if operation.isEmpty {
                exporter.cleanUp(exported)
            } else {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 120_000_000_000)
                    exporter.cleanUp(exported)
                }
            }
            guard let self else { return }
            self.activeDragSource = nil
            self.isDragging = false
            let succeeded = !operation.isEmpty
            let lostFocus = !(panel?.isKeyWindow ?? false)
            self.onDragDidEnd?(succeeded, succeeded || lostFocus)
        }

        activeDragSource = source
        isDragging = true
        onDragWillBegin?()
        anchor.beginDraggingSession(with: draggingItems, event: event, source: source)
        return true
    }

    private func clearPendingDrag() {
        pendingAnchor = nil
        mouseDownPointInWindow = nil
    }

    static func makeDraggingItems(
        for exported: ExportedClipboardFiles,
        item: ClipboardItem,
        cursorPoint: NSPoint,
        imagesDirectory: URL
    ) -> [NSDraggingItem] {
        exported.urls.enumerated().map { index, url in
            let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
            let offset = CGFloat(min(index, 4)) * 4
            let center = NSPoint(x: cursorPoint.x + offset, y: cursorPoint.y - offset)

            if index < 5 {
                let preview = previewImageAndSize(
                    for: url,
                    exportedKind: exported.kind,
                    item: item,
                    imagesDirectory: imagesDirectory
                )
                let frame = NSRect(
                    x: center.x - preview.size.width / 2,
                    y: center.y - preview.size.height / 2,
                    width: preview.size.width,
                    height: preview.size.height
                )
                draggingItem.setDraggingFrame(frame, contents: preview.image)
            } else {
                let frame = NSRect(x: center.x - 24, y: center.y - 24, width: 48, height: 48)
                draggingItem.setDraggingFrame(frame, contents: nil)
            }
            return draggingItem
        }
    }

    private static func previewImageAndSize(
        for url: URL,
        exportedKind: ExportedFileKind,
        item: ClipboardItem,
        imagesDirectory: URL
    ) -> (image: NSImage, size: NSSize) {
        if exportedKind == .image {
            let sourceURL = ClipboardItem.safeImageURL(
                filename: item.imageFilename,
                imagesDirectory: imagesDirectory
            )
            let image = sourceURL.flatMap { ThumbnailCache.shared.cached(for: $0, maxPixelSize: 128) }
                ?? NSImage(contentsOf: url)
                ?? NSWorkspace.shared.icon(forFile: url.path)
            let size = aspectFitSize(for: image.size, maxDimension: 64)
            return (image, size)
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return (icon, NSSize(width: 48, height: 48))
    }

    private static func aspectFitSize(for original: NSSize, maxDimension: CGFloat) -> NSSize {
        guard original.width > 0, original.height > 0 else {
            return NSSize(width: 48, height: 48)
        }
        let scale = min(maxDimension / original.width, maxDimension / original.height)
        return NSSize(
            width: max(24, round(original.width * scale)),
            height: max(24, round(original.height * scale))
        )
    }
}

private final class ActiveDragSource: NSObject, NSDraggingSource {
    private let onEnded: @MainActor @Sendable (NSDragOperation) -> Void

    init(onEnded: @escaping @MainActor @Sendable (NSDragOperation) -> Void) {
        self.onEnded = onEnded
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let onEnded = self.onEnded
        Task { @MainActor in
            onEnded(operation)
        }
    }
}
