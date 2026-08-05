import AppKit
import Foundation
import Testing
@testable import SSClip

@MainActor
struct AppModelTests {
    @Test func pasteTargetRejectsOwnOrMissingApplicationAndAcceptsAnotherLiveApplication() throws {
        _ = NSApplication.shared
        let currentApplication = try #require(NSRunningApplication(processIdentifier: getpid()))

        #expect(AppModel.pasteTarget(
            frontmost: currentApplication,
            ownBundleIdentifier: currentApplication.bundleIdentifier
        ) == nil)
        #expect(AppModel.pasteTarget(frontmost: nil, ownBundleIdentifier: "different.bundle") == nil)
        #expect(AppModel.pasteTarget(
            frontmost: currentApplication,
            ownBundleIdentifier: "different.bundle"
        ) === currentApplication)
    }

    @Test func deletingLastItemOnLastPageClampsCurrentPage() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.model
        for index in 0..<11 {
            context.store.add(makeCapture("条目 \(index)"))
        }
        model.currentPage = 1
        let lastPageItem = try #require(model.pageItems.first)

        model.delete(lastPageItem)

        #expect(model.pageCount == 1)
        #expect(model.currentPage == 0)
        #expect(model.selectedItem != nil)
    }

    @Test func deleteSelectedRemovesItemAndKeepsValidSelection() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.model
        for index in 0..<3 {
            context.store.add(makeCapture("条目 \(index)"))
        }
        model.selectedIndex = 2

        model.deleteSelected()

        #expect(context.store.items.count == 2)
        #expect(model.selectedIndex == 1)
        #expect(model.selectedItem != nil)
    }

    @Test func unfavoritingInFavoritesSectionClampsSelection() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.model
        let first = try #require(context.store.add(makeCapture("第一条")))
        let second = try #require(context.store.add(makeCapture("第二条")))
        model.toggleFavorite(first)
        model.toggleFavorite(second)
        model.selectSection(.favorites)
        model.selectedIndex = 1
        let selected = try #require(model.selectedItem)

        model.toggleFavorite(selected)

        #expect(model.filteredItems.count == 1)
        #expect(model.selectedIndex == 0)
        #expect(model.selectedItem != nil)
    }

    @Test func moveSelectionCrossesPagesInBothDirections() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.model
        for index in 0..<12 {
            context.store.add(makeCapture("条目 \(index)"))
        }

        // 页尾继续向下 → 翻到第 2 页第 1 条。
        model.selectedIndex = 9
        model.moveSelection(by: 1)
        #expect(model.currentPage == 1)
        #expect(model.selectedIndex == 0)

        // 页首继续向上 → 回到第 1 页最后一条。
        model.moveSelection(by: -1)
        #expect(model.currentPage == 0)
        #expect(model.selectedIndex == 9)

        // 边界钳制：最后一条再向下不动。
        model.currentPage = 1
        model.selectedIndex = 1
        model.moveSelection(by: 1)
        #expect(model.currentPage == 1)
        #expect(model.selectedIndex == 1)
    }

    @Test func moveSelectionDuringSearchNavigatesFilteredResults() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.model
        for index in 0..<15 {
            context.store.add(makeCapture(index % 2 == 0 ? "苹果 \(index)" : "香蕉 \(index)"))
        }
        model.searchQuery = "苹果"

        #expect(model.filteredItems.count == 8)
        model.moveSelection(by: 1)
        #expect(model.selectedIndex == 1)
        #expect(model.selectedItem?.title.hasPrefix("苹果") == true)
    }

    private func makeCapture(_ title: String) -> CapturedClipboard {
        CapturedClipboard(kind: .text, title: title, text: title, imageData: nil, filePaths: [])
    }

    private func makeContext() throws -> TestContext {
        let suiteName = "SSClipTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ClipboardStore(baseDirectory: directory)
        let model = AppModel(settings: AppSettings(defaults: defaults), store: store)
        return TestContext(model: model, store: store, suiteName: suiteName, directory: directory)
    }
}

@MainActor
private struct TestContext {
    let model: AppModel
    let store: ClipboardStore
    let suiteName: String
    let directory: URL

    func cleanUp() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
