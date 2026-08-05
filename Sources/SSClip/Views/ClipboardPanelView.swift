import AppKit
import SwiftUI

struct ClipboardPanelView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ClipboardStore
    @EnvironmentObject private var settings: AppSettings
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            historyList
            Divider().opacity(0.55)
            footer
        }
        .frame(width: 690, height: 470)
        .background {
            ZStack {
                VisualEffectView(material: .popover, blendingMode: .behindWindow)
                Theme.panelTint
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.13), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
        .overlay(alignment: .top) { messageOverlay }
        .onChange(of: model.isSearching) { shouldFocus in
            if shouldFocus {
                DispatchQueue.main.async { searchFocused = true }
            } else {
                searchFocused = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SSClip 剪贴板历史")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.onControl.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(Theme.appBadge, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: Theme.accent.opacity(0.30), radius: 10, y: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("SSClip")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(model.isBatchMode
                    ? "队列 \(model.batchItemIDs.count) 条 · 复制入队，⌘V 依次粘贴"
                    : "\(model.filteredItems.count) 条 · \(settings.hotKey.displayName) 呼出")
                    .font(.system(size: 10.5))
                    .foregroundStyle(model.isBatchMode ? Theme.accentDeep : .secondary)
            }

            Spacer(minLength: 8)

            if model.isSearching {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索 · ↑↓ 选择 · ↩ 粘贴 · ⌘数字直接粘贴", text: $model.searchQuery)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { model.pasteSelected() }
                    Button {
                        model.closeSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("关闭搜索")
                }
                .padding(.horizontal, 10)
                .frame(width: 300, height: 30)
                .background(
                    Color(light: .white.opacity(0.55), dark: .white.opacity(0.07)),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Theme.accentDeep.opacity(0.42))
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                GhostButton(icon: "magnifyingglass", label: "搜索（\(settings.panelShortcuts.search.displayName)）") {
                    model.activateSearch()
                }
            }

            GhostButton(
                icon: model.isBatchMode ? "square.stack.3d.up.fill" : "square.stack.3d.up",
                label: model.isBatchMode ? "关闭批量模式" : "开启批量模式",
                isActive: model.isBatchMode
            ) {
                model.toggleBatchMode()
            }

            GhostButton(icon: "gearshape", label: "设置") {
                model.showSettings()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .animation(.easeOut(duration: 0.18), value: model.isSearching)
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            if model.pageItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: model.searchQuery.isEmpty ? "clipboard" : "magnifyingglass")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Theme.accentDeep)
                        .frame(width: 58, height: 58)
                        .background(Theme.emptyIcon, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text(model.searchQuery.isEmpty ? "还没有剪贴板记录" : "没有找到匹配内容")
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.searchQuery.isEmpty ? "复制文本、图片或文件后会自动出现在这里" : "试试文件名、路径或文本中的其他词")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(Array(model.pageItems.enumerated()), id: \.element.id) { index, item in
                    ClipboardRow(
                        item: item,
                        number: index == 9 ? "0" : "\(index + 1)",
                        isSelected: index == model.selectedIndex,
                        folderName: store.folders.first(where: { $0.id == item.folderID })?.name,
                        imagesDirectory: store.imagesDirectory,
                        showsBatchControls: model.isBatchMode,
                        batchPosition: model.batchPosition(of: item),
                        onSelect: {
                            model.selectedIndex = index
                            model.schedulePreview(for: item)
                        },
                        onPaste: { model.paste(item) },
                        onPastePlainText: { model.paste(item, mode: .plainText) },
                        onFavorite: { model.toggleFavorite(item) },
                        onMove: { folder in model.move(item, to: folder) },
                        onDelete: { model.delete(item) },
                        onToggleBatch: { model.toggleBatchMembership(item) },
                        onRevealInFinder: { model.revealInFinder(item) },
                        folders: store.folders
                    )
                }
                ForEach(model.pageItems.count..<model.pageSize, id: \.self) { _ in
                    Color.clear.frame(height: 36)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var footer: some View {
        let counts = sectionCounts

        return HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    sectionButton(.all, title: "全部", icon: "circle.grid.2x2.fill", count: counts.all)
                    sectionButton(.favorites, title: "收藏", icon: "star.fill", count: counts.favorites)
                    ForEach(store.folders) { folder in
                        sectionButton(
                            .folder(folder.id),
                            title: folder.name,
                            icon: "folder.fill",
                            count: counts.folders[folder.id, default: 0]
                        )
                    }
                }
            }

            Spacer(minLength: 4)

            Button { model.previousPage() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(model.currentPage == 0)
            .accessibilityLabel("上一页")

            Text("\(model.currentPage + 1) / \(model.pageCount)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 42)

            Button { model.nextPage() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(model.currentPage + 1 >= model.pageCount)
            .accessibilityLabel("下一页")

            HStack(spacing: 4) {
                if model.isBatchMode {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accentDeep)
                        Text(model.batchItemIDs.isEmpty
                            ? "队列为空 · 复制即入队"
                            : "队列 \(model.batchItemIDs.count) 条 · 目标应用 ⌘V 依次粘贴")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        model.clearBatch()
                    } label: {
                        Text("清空")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.batchItemIDs.isEmpty)
                    .opacity(model.batchItemIDs.isEmpty ? 0.45 : 1)
                    .accessibilityLabel("清空粘贴队列")
                } else {
                    Keycap("⌘←")
                    Keycap("⌘→")
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    @ViewBuilder
    private var messageOverlay: some View {
        if let message = store.storageErrorMessage ?? model.transientMessage {
            HStack(spacing: 7) {
                Circle()
                    .fill(store.storageErrorMessage == nil ? Theme.accent : Theme.danger)
                    .frame(width: 6, height: 6)
                Text(message)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 8)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func sectionButton(
        _ section: ClipboardSection,
        title: String,
        icon: String,
        count: Int
    ) -> some View {
        let isActive = model.activeSection == section
        let inactiveIcon = section == .favorites ? Theme.pinkDeep : Color.primary.opacity(0.62)

        return Button {
            model.selectSection(section)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .foregroundStyle(isActive ? Theme.onControl : inactiveIcon)
                Text(title)
                Text("\(count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .opacity(0.72)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(isActive ? Theme.onControl : Color.primary.opacity(0.62))
            .background(isActive ? Theme.controlFill : Theme.subtleSurface, in: Capsule())
            .shadow(color: isActive ? Theme.controlFill.opacity(0.28) : .clear, radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var sectionCounts: ClipboardSectionCounts {
        let query = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var counts = ClipboardSectionCounts()

        for item in store.items {
            if !query.isEmpty,
               !item.searchableText.localizedCaseInsensitiveContains(query) {
                continue
            }
            counts.all += 1
            if item.isFavorite {
                counts.favorites += 1
            }
            if let folderID = item.folderID {
                counts.folders[folderID, default: 0] += 1
            }
        }
        return counts
    }
}

private struct ClipboardSectionCounts {
    var all = 0
    var favorites = 0
    var folders: [UUID: Int] = [:]
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let number: String
    let isSelected: Bool
    let folderName: String?
    let imagesDirectory: URL
    let showsBatchControls: Bool
    let batchPosition: Int?
    let onSelect: () -> Void
    let onPaste: () -> Void
    let onPastePlainText: () -> Void
    let onFavorite: () -> Void
    let onMove: (FavoriteFolder?) -> Void
    let onDelete: () -> Void
    let onToggleBatch: () -> Void
    let onRevealInFinder: () -> Void
    let folders: [FavoriteFolder]

    private var numberFill: Color {
        if isSelected {
            return Color(light: .white.opacity(0.60), dark: .white.opacity(0.14))
        }
        return Color(light: .white.opacity(0.50), dark: .white.opacity(0.07))
    }

    private var numberText: Color {
        if isSelected {
            return Color(light: .black.opacity(0.45), dark: .white.opacity(0.75))
        }
        return Color(light: .black.opacity(0.45), dark: .white.opacity(0.45))
    }

    private var badgeFill: Color {
        if isSelected {
            return Color(light: .white.opacity(0.60), dark: .white.opacity(0.14))
        }
        return Color(
            light: Theme.kindColor(item.kind).opacity(0.12),
            dark: Theme.kindColor(item.kind).opacity(0.14)
        )
    }

    private var metadataColor: Color {
        isSelected ? Color.primary.opacity(0.62) : Color.secondary
    }

    private var inactiveStar: Color {
        Color(light: .black.opacity(0.20), dark: .white.opacity(0.22))
    }

    var body: some View {
        HStack(spacing: 9) {
            if showsBatchControls {
                Button(action: onToggleBatch) {
                    if let batchPosition {
                        Text("\(batchPosition)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.onControl)
                            .frame(width: 20, height: 20)
                            .background(Theme.controlFill, in: Circle())
                    } else {
                        Image(systemName: "circle")
                            .font(.system(size: 14))
                            .foregroundStyle(inactiveStar)
                            .frame(width: 20, height: 20)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    batchPosition.map { "队列第 \($0) 位，点击移出" } ?? "加入粘贴队列"
                )
            }

            Text(number)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(numberText)
                .frame(width: 20, height: 20)
                .background(numberFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))

            RowLeadingIcon(item: item, imagesDirectory: imagesDirectory, badgeFill: badgeFill)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.detail)
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let folderName {
                        Label(folderName, systemImage: "folder.fill")
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Color(
                                    light: .white.opacity(isSelected ? 0.55 : 0.50),
                                    dark: .white.opacity(isSelected ? 0.12 : 0.08)
                                ),
                                in: Capsule()
                            )
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(metadataColor)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onFavorite) {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(item.isFavorite ? Theme.pinkDeep : inactiveStar)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isFavorite ? "取消收藏" : "收藏")
        }
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .frame(height: 36)
        .background {
            if isSelected {
                Theme.rowSelection
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.rowSelectionStroke, lineWidth: 1)
                .opacity(isSelected ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPaste)
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            if hovering { onSelect() }
        }
        .contextMenu {
            Button("粘贴", action: onPaste)
            if item.kind == .text {
                Button("纯文本粘贴", action: onPastePlainText)
            }
            if item.kind == .files {
                Button("在 Finder 中显示", action: onRevealInFinder)
            }
            if showsBatchControls {
                Button(batchPosition == nil ? "加入粘贴队列" : "移出粘贴队列", action: onToggleBatch)
            }
            Button(item.isFavorite ? "取消收藏" : "收藏", action: onFavorite)
            Menu("收藏到") {
                Button("未分类收藏") { onMove(nil) }
                ForEach(folders) { folder in
                    Button(folder.name) { onMove(folder) }
                }
            }
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(number) 条，\(item.kind.localizedName)，\(item.title)")
        .accessibilityHint("按数字 \(number) 直接粘贴，空格预览")
    }
}

/// 行首图标：图片显示真缩略图，文件显示系统图标，文本保留类型徽章。
private struct RowLeadingIcon: View {
    let item: ClipboardItem
    let imagesDirectory: URL
    let badgeFill: Color
    @State private var thumbnail: NSImage?

    private var imageURL: URL? {
        guard item.kind == .image else { return nil }
        return item.previewURL(imagesDirectory: imagesDirectory)
    }

    var body: some View {
        Group {
            if item.kind == .image {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                        }
                } else {
                    fallbackBadge
                }
            } else if item.kind == .files, let path = item.filePaths.first {
                Image(nsImage: FileIconProvider.icon(forPath: path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            } else {
                fallbackBadge
            }
        }
        .task(id: imageURL) {
            guard let imageURL else { return }
            // 首帧同步命中缓存，避免翻页时缩略图闪烁。
            if let cached = ThumbnailCache.shared.cached(for: imageURL, maxPixelSize: 48) {
                thumbnail = cached
                return
            }
            thumbnail = await ThumbnailCache.shared.thumbnail(for: imageURL, maxPixelSize: 48)
        }
        .accessibilityHidden(true)
    }

    private var fallbackBadge: some View {
        Image(systemName: item.kind.systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.kindColor(item.kind))
            .frame(width: 24, height: 24)
            .background(badgeFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct GhostButton: View {
    let icon: String
    let label: String
    var isActive = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(isActive ? Theme.accentDeep : Color.primary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isActive
                ? Theme.accentDeep.opacity(0.14)
                : (isHovering ? Color.primary.opacity(0.07) : .clear),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct Keycap: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
            .padding(.horizontal, 5)
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
}
