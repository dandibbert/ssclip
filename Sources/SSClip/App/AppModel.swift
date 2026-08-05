import AppKit
import ApplicationServices
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var activeSection: ClipboardSection = .all
    @Published var searchQuery = ""
    @Published var isSearching = false
    @Published var currentPage = 0
    @Published var selectedIndex = 0
    @Published var transientMessage: String?
    @Published private(set) var isBatchMode = false
    @Published private(set) var batchItemIDs: [UUID] = []

    let settings: AppSettings
    let store: ClipboardStore
    let monitor: ClipboardMonitor

    weak var panelController: ClipboardPanelController?
    var panelProvider: (() -> ClipboardPanelController?)?
    var settingsPresenter: (() -> Void)?
    private let hotKey = GlobalHotKey()
    private let pasteService: PasteService
    private let pasteKeyObserver = PasteKeyObserver()
    private var previewController: PreviewController?
    private var previousApplication: NSRunningApplication?
    private var previewTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var acceptedHotKey: HotKeyConfiguration

    let pageSize = 10

    convenience init() {
        self.init(settings: AppSettings(), store: ClipboardStore())
    }

    convenience init(settings: AppSettings, store: ClipboardStore) {
        self.init(settings: settings, store: store, pasteService: PasteService())
    }

    init(settings: AppSettings, store: ClipboardStore, pasteService: PasteService) {
        self.settings = settings
        self.store = store
        self.pasteService = pasteService
        acceptedHotKey = settings.hotKey
        monitor = ClipboardMonitor(settings: settings)

        monitor.onCapture = { [weak self] capture in
            self?.handleCapture(capture)
        }
        pasteService.beforePasteboardWrite = { [weak monitor] in monitor?.suppressNextChange() }
        pasteKeyObserver.onPaste = { [weak self] in self?.advanceQueue() }
        hotKey.onPressed = { [weak self] in self?.togglePanel() }
        hotKey.register(settings.hotKey)

        settings.$hotKey
            .dropFirst()
            .sink { [weak self] configuration in
                guard let self else { return }
                if self.hotKey.register(configuration) {
                    if configuration != self.acceptedHotKey {
                        self.acceptedHotKey = configuration
                        self.settings.hotKeyValidationMessage = nil
                    }
                } else {
                    self.settings.hotKeyValidationMessage = "快捷键已被其他应用占用，已恢复上一组快捷键。"
                    if configuration != self.acceptedHotKey {
                        self.settings.hotKey = self.acceptedHotKey
                    }
                    self.showMessage("快捷键已被其他应用占用")
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4(
            settings.$limitByAge,
            settings.$retentionDays,
            settings.$limitByCount,
            settings.$maximumItems
        )
        .dropFirst()
        .sink { [weak self] _, _, _, _ in
            guard let self else { return }
            self.store.applyRetention(cutoff: self.settings.retentionCutoff, maximumItems: self.settings.itemLimit)
        }
        .store(in: &cancellables)

        Publishers.CombineLatest3(store.$items, $activeSection, $searchQuery)
            .map { items, section, query in
                Self.filterItems(items, section: section, query: query)
            }
            .sink { [weak self] value in self?.filteredItems = value }
            .store(in: &cancellables)

        $searchQuery
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.currentPage = 0
                self.selectedIndex = 0
                self.schedulePreview(for: self.selectedItem)
            }
            .store(in: &cancellables)

        // 删除或自动清理后，批量队列同步剔除已不存在的记录；队首变化时重写剪贴板。
        store.$items
            .sink { [weak self] items in
                guard let self, !self.batchItemIDs.isEmpty else { return }
                let existing = Set(items.map(\.id))
                let filtered = self.batchItemIDs.filter { existing.contains($0) }
                guard filtered != self.batchItemIDs else { return }
                let headChanged = filtered.first != self.batchItemIDs.first
                self.batchItemIDs = filtered
                if headChanged { self.writeQueueHead() }
            }
            .store(in: &cancellables)
    }

    func handleCapture(_ capture: CapturedClipboard) {
        let added = store.add(capture)
        if isBatchMode, let added {
            batchItemIDs.append(added.id)
            // 刚复制的内容占着剪贴板；若它不是队首，立即把队首写回去，
            // 保证下一次 ⌘V 仍按顺序粘出队首。
            if nextBatchItem?.id != added.id {
                writeQueueHead()
            }
        }
        store.applyRetention(cutoff: settings.retentionCutoff, maximumItems: settings.itemLimit)
    }

    @Published private(set) var filteredItems: [ClipboardItem] = []

    private static func filterItems(
        _ items: [ClipboardItem],
        section: ClipboardSection,
        query rawQuery: String
    ) -> [ClipboardItem] {
        let sectionItems: [ClipboardItem]
        switch section {
        case .all:
            sectionItems = items
        case .favorites:
            sectionItems = items.filter(\.isFavorite)
        case let .folder(folderID):
            sectionItems = items.filter { $0.folderID == folderID }
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sectionItems }
        return sectionItems.filter {
            $0.searchableText.localizedCaseInsensitiveContains(query)
        }
    }

    var pageCount: Int {
        max(1, Int(ceil(Double(filteredItems.count) / Double(pageSize))))
    }

    var pageItems: [ClipboardItem] {
        let safePage = min(max(0, currentPage), pageCount - 1)
        let start = safePage * pageSize
        guard start < filteredItems.count else { return [] }
        return Array(filteredItems[start..<min(start + pageSize, filteredItems.count)])
    }

    var selectedItem: ClipboardItem? {
        let values = pageItems
        guard values.indices.contains(selectedIndex) else { return nil }
        return values[selectedIndex]
    }

    func start() {
        store.applyRetention(cutoff: settings.retentionCutoff, maximumItems: settings.itemLimit)
        monitor.start()
    }

    func togglePanel() {
        guard let panelController = panelController ?? panelProvider?() else { return }
        if panelController.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    static func pasteTarget(
        frontmost: NSRunningApplication?,
        ownBundleIdentifier: String?
    ) -> NSRunningApplication? {
        guard let frontmost,
              !frontmost.isTerminated,
              frontmost.bundleIdentifier != ownBundleIdentifier
        else { return nil }
        return frontmost
    }

    func showPanel() {
        guard let panelController = panelController ?? panelProvider?() else { return }
        previousApplication = Self.pasteTarget(
            frontmost: NSWorkspace.shared.frontmostApplication,
            ownBundleIdentifier: Bundle.main.bundleIdentifier
        )
        normalizeNavigation()
        panelController.show()
    }

    func hidePanel() {
        previewTask?.cancel()
        previewController?.hide()
        panelController?.hide()
    }

    func activateSearch() {
        isSearching = true
    }

    func closeSearch() {
        isSearching = false
        searchQuery = ""
        currentPage = 0
        selectedIndex = 0
    }

    func showSettings() {
        if panelController?.isVisible == true {
            hidePanel()
        }
        settingsPresenter?()
    }

    func selectSection(_ section: ClipboardSection) {
        activeSection = section
        currentPage = 0
        selectedIndex = 0
        schedulePreview(for: selectedItem)
    }

    func togglePrimarySection() {
        selectSection(activeSection == .all ? .favorites : .all)
    }

    func nextPage() {
        guard currentPage + 1 < pageCount else { return }
        currentPage += 1
        selectedIndex = 0
        schedulePreview(for: selectedItem)
    }

    func previousPage() {
        guard currentPage > 0 else { return }
        currentPage -= 1
        selectedIndex = 0
        schedulePreview(for: selectedItem)
    }

    func moveSelection(by offset: Int) {
        let total = filteredItems.count
        guard total > 0 else { return }
        // 以全局索引移动，越过页尾自动翻页；搜索时 ⌘←/→ 属于文本编辑，全靠 ↑/↓ 连续滚动。
        let current = currentPage * pageSize + selectedIndex
        let target = min(max(0, current + offset), total - 1)
        currentPage = target / pageSize
        selectedIndex = target % pageSize
        schedulePreview(for: selectedItem)
    }

    func pasteItem(at index: Int) {
        let values = pageItems
        guard values.indices.contains(index) else { return }
        paste(values[index])
    }

    func pasteSelected() {
        guard let selectedItem else { return }
        paste(selectedItem)
    }

    func pasteSelectedAsPlainText() {
        guard let selectedItem else { return }
        paste(selectedItem, mode: .plainText)
    }

    // MARK: - 批量队列模式

    /// ⌘V 后延迟多久把下一条写上剪贴板；0 表示同步写（测试用）。
    /// 延迟是必须的：目标应用可能在按键之后才读剪贴板，立即写会粘出下一条。
    var queueAdvanceDelay: TimeInterval = 0.3

    var batchItems: [ClipboardItem] {
        batchItemIDs.compactMap { id in store.items.first(where: { $0.id == id }) }
    }

    var nextBatchItem: ClipboardItem? {
        batchItems.first
    }

    func toggleBatchMode() {
        isBatchMode.toggle()
        if isBatchMode {
            pasteKeyObserver.start()
            if AXIsProcessTrusted() {
                showMessage("批量模式已开启：依次复制，再到目标应用连续 ⌘V")
            } else {
                showMessage("批量模式需要“辅助功能”权限才能按顺序粘贴")
            }
        } else {
            pasteKeyObserver.stop()
            batchItemIDs = []
        }
    }

    func isInBatch(_ item: ClipboardItem) -> Bool {
        batchItemIDs.contains(item.id)
    }

    /// 队列中的顺序（从 1 开始），不在队列时为 nil。
    func batchPosition(of item: ClipboardItem) -> Int? {
        batchItemIDs.firstIndex(of: item.id).map { $0 + 1 }
    }

    func toggleBatchMembership(_ item: ClipboardItem) {
        guard isBatchMode else { return }
        if let index = batchItemIDs.firstIndex(of: item.id) {
            batchItemIDs.remove(at: index)
        } else {
            batchItemIDs.append(item.id)
        }
        writeQueueHead()
    }

    func clearBatch() {
        batchItemIDs = []
    }

    /// 队列不变式：只要队列非空，队首内容就预写在系统剪贴板上，
    /// 因此目标应用的下一次 ⌘V 总是粘出队首。
    private func writeQueueHead() {
        guard isBatchMode else { return }
        var skippedUnreadableItem = false
        while let head = nextBatchItem {
            if pasteService.write(head, imagesDirectory: store.imagesDirectory) { break }
            batchItemIDs.removeFirst()
            skippedUnreadableItem = true
        }
        if skippedUnreadableItem {
            showMessage("队列中的记录已丢失，已跳过")
        }
    }

    /// 检测到一次外部 ⌘V：目标应用刚读走队首，弹出它并安排写入下一条。
    func advanceQueue() {
        guard isBatchMode, !batchItemIDs.isEmpty else { return }
        batchItemIDs.removeFirst()
        guard !batchItemIDs.isEmpty else {
            showMessage("批量队列已全部粘贴")
            return
        }
        if queueAdvanceDelay <= 0 {
            writeQueueHead()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + queueAdvanceDelay) { [weak self] in
                self?.writeQueueHead()
            }
        }
    }

    func revealInFinder(_ item: ClipboardItem) {
        guard item.kind == .files, !item.filePaths.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(
            item.filePaths.map { URL(fileURLWithPath: $0) }
        )
    }

    func paste(_ item: ClipboardItem, mode: PasteMode = .standard) {
        let itemToPaste = store.promote(item) ?? item
        hidePanel()
        let result = pasteService.paste(
            itemToPaste,
            imagesDirectory: store.imagesDirectory,
            targetApplication: previousApplication,
            mode: mode
        )
        switch result {
        case .pasted:
            // 面板单条粘贴合成的 ⌘V 不推进队列；粘完再把队首写回剪贴板。
            if isBatchMode {
                pasteKeyObserver.ignoreNextPaste()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.writeQueueHead()
                }
            }
        case .copiedOnly:
            showMessage("已复制；授权辅助功能后可直接粘贴")
        case .failed:
            showMessage("无法读取该记录，内容可能已丢失")
        }
    }

    func toggleFavorite(_ item: ClipboardItem) {
        store.toggleFavorite(item)
        normalizeNavigation()
        schedulePreview(for: selectedItem)
    }

    func toggleFavoriteForSelected() {
        guard let selectedItem else { return }
        toggleFavorite(selectedItem)
    }

    func move(_ item: ClipboardItem, to folder: FavoriteFolder?) {
        store.move(item, to: folder)
        normalizeNavigation()
    }

    func delete(_ item: ClipboardItem) {
        store.remove(item)
        normalizeNavigation()
        schedulePreview(for: selectedItem)
    }

    func deleteSelected() {
        guard let selectedItem else { return }
        delete(selectedItem)
    }

    func schedulePreview(for item: ClipboardItem?) {
        previewTask?.cancel()
        guard let item else {
            previewController?.hide()
            return
        }
        previewTask = Task { [weak self] in
            guard let self else { return }
            let nanoseconds = UInt64(max(0.3, self.settings.previewDelay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, self.panelController?.isVisible == true else { return }
            let previewController = self.previewController ?? PreviewController()
            self.previewController = previewController
            previewController.show(
                item,
                imagesDirectory: self.store.imagesDirectory,
                beside: self.panelController?.frame
            )
        }
    }

    func showPreviewImmediately() {
        previewTask?.cancel()
        guard let selectedItem else { return }
        let controller = self.previewController ?? PreviewController()
        previewController = controller
        controller.show(
            selectedItem,
            imagesDirectory: store.imagesDirectory,
            beside: panelController?.frame
        )
    }

    func normalizeNavigation() {
        currentPage = min(max(0, currentPage), pageCount - 1)
        selectedIndex = min(max(0, selectedIndex), max(0, pageItems.count - 1))
    }

    private func showMessage(_ message: String) {
        transientMessage = message
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.transientMessage = nil
        }
    }
}
