import AppKit
import QuickLookUI
import SwiftUI

@MainActor
final class PreviewController {
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 480),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
    }

    func show(_ item: ClipboardItem, imagesDirectory: URL, beside parentFrame: NSRect?) {
        switch item.kind {
        case .text:
            panel.contentView = NSHostingView(rootView: TextPreview(item: item))
            panel.setContentSize(NSSize(width: 470, height: 480))
        case .image:
            guard let url = item.previewURL(imagesDirectory: imagesDirectory) else { return }
            panel.contentView = NSHostingView(rootView: ImagePreview(item: item, url: url))
            panel.setContentSize(NSSize(width: 520, height: 480))
        case .files:
            guard let url = item.previewURL(imagesDirectory: imagesDirectory) else { return }
            let preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 520, height: 480), style: .normal)
            preview?.previewItem = url as NSURL
            preview?.autostarts = true
            panel.contentView = preview
            panel.setContentSize(NSSize(width: 520, height: 480))
        }
        position(beside: parentFrame)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func position(beside parentFrame: NSRect?) {
        guard let parentFrame,
              let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(parentFrame) }) ?? NSScreen.main
        else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        let gap: CGFloat = 12
        let availableWidth = max(160, visible.maxX - parentFrame.maxX - gap)
        if panel.frame.width > availableWidth {
            let contentHeight = panel.contentView?.bounds.height ?? 480
            panel.setContentSize(NSSize(width: availableWidth, height: contentHeight))
        }
        var origin = NSPoint(x: parentFrame.maxX + gap, y: parentFrame.maxY - panel.frame.height)
        origin.y = max(visible.minY, min(origin.y, visible.maxY - panel.frame.height))
        panel.setFrameOrigin(origin)
    }
}

private struct PreviewHeader: View {
    let item: ClipboardItem
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.kindColor(item.kind))
                .frame(width: 28, height: 28)
                .background(
                    Theme.kindColor(item.kind).opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text("Space")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(
                    Color(light: .white.opacity(0.75), dark: .white.opacity(0.09)),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                }
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 15)
        .frame(height: 52)
    }
}

private struct PreviewBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            ZStack {
                VisualEffectView(material: .popover, blendingMode: .behindWindow)
                Theme.panelTint
            }
        }
    }
}

private struct TextPreview: View {
    let item: ClipboardItem

    private var metadata: String {
        var parts = [
            item.detail,
            item.createdAt.formatted(date: .abbreviated, time: .shortened)
        ]
        if item.isFavorite {
            parts.append(item.folderID == nil ? "未分类收藏" : "收藏夹")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            PreviewHeader(item: item, subtitle: metadata)

            ScrollView {
                Text(item.text ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(9)
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(
                Color(light: .white.opacity(0.55), dark: .black.opacity(0.30)),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .padding(.horizontal, 13)
            .padding(.bottom, 13)
        }
        .modifier(PreviewBackground())
        .accessibilityLabel("剪贴板文本完整预览")
    }
}

private struct ImagePreview: View {
    let item: ClipboardItem
    let url: URL
    @State private var image: NSImage?
    @State private var metadata: ImageMetadata?

    var body: some View {
        VStack(spacing: 0) {
            PreviewHeader(
                item: item,
                subtitle: item.createdAt.formatted(date: .abbreviated, time: .shortened)
            )

            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(10)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background {
                // 棋盘格底能看出透明区域，也让浅色图片有边界。
                CheckerboardBackground()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.horizontal, 13)

            metadataGrid
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
        }
        .modifier(PreviewBackground())
        .task(id: url) {
            metadata = await Task.detached(priority: .userInitiated) {
                ImageMetadata.read(from: url)
            }.value
            image = await ThumbnailCache.shared.thumbnail(for: url, maxPixelSize: 1200)
        }
        .accessibilityLabel("剪贴板图片预览，含尺寸与格式信息")
    }

    private var metadataGrid: some View {
        let byteText = ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file)
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                metadataCell(label: "尺寸", value: metadata?.dimensionsText ?? "读取中…")
                metadataCell(label: "大小", value: byteText)
            }
            GridRow {
                metadataCell(label: "格式", value: metadata?.formatDisplayName ?? "—")
                metadataCell(label: "色彩", value: metadata?.colorSummary ?? "—")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Color(light: .white.opacity(0.55), dark: .white.opacity(0.055)),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func metadataCell(label: String, value: String) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
        }
        .gridColumnAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 透明图片底部的棋盘格背景。
private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) where (row + column).isMultiple(of: 2) {
                    context.fill(
                        Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                        with: .color(.primary.opacity(0.045))
                    )
                }
            }
        }
        .background(Color(light: .white.opacity(0.55), dark: .black.opacity(0.30)))
    }
}
