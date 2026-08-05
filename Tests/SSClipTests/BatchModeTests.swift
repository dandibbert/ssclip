import AppKit
import Foundation
import Testing
@testable import SSClip

@MainActor
struct BatchModeTests {
    @Test func capturesJoinQueueInOrderWhileBatchModeIsOn() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.model

        model.handleCapture(makeCapture("模式开启前"))
        model.toggleBatchMode()
        model.handleCapture(makeCapture("1"))
        model.handleCapture(makeCapture("2"))
        model.handleCapture(makeCapture("3"))

        #expect(model.batchItems.map(\.title) == ["1", "2", "3"])
        #expect(model.batchPosition(of: try #require(model.batchItems.first)) == 1)
    }

    @Test func queueHeadStaysOnPasteboardWhileCollecting() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.model
        model.toggleBatchMode()

        model.handleCapture(makeCapture("1"))
        model.handleCapture(makeCapture("2"))
        model.handleCapture(makeCapture("3"))

        // 复制 2、3 之后队首仍是 1，剪贴板必须被写回 1。
        #expect(context.pasteboard.string(forType: .string) == "1")
    }

    @Test func unreadableQueueHeadIsSkippedAndNextReadableItemIsWritten() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.model
        let imageData = try makeOnePixelPNG()
        let imageCapture = CapturedClipboard(
            kind: .image,
            title: "image",
            text: nil,
            imageData: imageData,
            filePaths: []
        )

        model.toggleBatchMode()
        model.handleCapture(imageCapture)
        model.handleCapture(makeCapture("text"))
        let badImage = try #require(model.batchItems.first)
        let filename = try #require(badImage.imageFilename)
        try FileManager.default.removeItem(
            at: context.store.imagesDirectory.appendingPathComponent(filename)
        )

        model.handleCapture(makeCapture("third"))

        #expect(!model.batchItemIDs.contains(badImage.id))
        #expect(model.batchItems.map(\.title) == ["text", "third"])
        #expect(context.pasteboard.string(forType: .string) == "text")
        #expect(model.transientMessage == "队列中的记录已丢失，已跳过")
    }

    @Test func eachExternalPasteAdvancesQueueInOrder() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.model
        model.toggleBatchMode()
        for value in ["1", "2", "3", "4"] {
            model.handleCapture(makeCapture(value))
        }

        model.advanceQueue()
        #expect(context.pasteboard.string(forType: .string) == "2")
        #expect(model.batchItems.map(\.title) == ["2", "3", "4"])

        model.advanceQueue()
        #expect(context.pasteboard.string(forType: .string) == "3")

        model.advanceQueue()
        #expect(context.pasteboard.string(forType: .string) == "4")

        model.advanceQueue()
        #expect(model.batchItemIDs.isEmpty)
        #expect(model.transientMessage == "批量队列已全部粘贴")
    }

    @Test func advanceQueueOutsideBatchModeDoesNothing() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.model
        model.handleCapture(makeCapture("内容"))

        model.advanceQueue()

        #expect(model.batchItemIDs.isEmpty)
        #expect(model.transientMessage == nil)
    }

    @Test func turningBatchModeOffClearsQueue() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.model
        model.toggleBatchMode()
        model.handleCapture(makeCapture("内容"))

        model.toggleBatchMode()

        #expect(!model.isBatchMode)
        #expect(model.batchItemIDs.isEmpty)
    }

    @Test func deletingQueueHeadRewritesNextItemToPasteboard() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.model
        model.toggleBatchMode()
        model.handleCapture(makeCapture("1"))
        model.handleCapture(makeCapture("2"))
        let head = try #require(model.nextBatchItem)

        model.delete(head)

        #expect(model.batchItems.map(\.title) == ["2"])
        #expect(context.pasteboard.string(forType: .string) == "2")
    }

    @Test func recopiedDuplicateMovesToEndOfQueue() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.model
        model.toggleBatchMode()
        model.handleCapture(makeCapture("甲"))
        model.handleCapture(makeCapture("乙"))
        model.handleCapture(makeCapture("甲"))

        #expect(model.batchItems.map(\.title) == ["乙", "甲"])
        #expect(context.pasteboard.string(forType: .string) == "乙")
    }

    @Test func manualToggleAddsExistingItemAndWritesHead() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let model = context.model
        model.handleCapture(makeCapture("旧记录"))
        model.toggleBatchMode()
        let item = try #require(context.store.items.first)

        model.toggleBatchMembership(item)
        #expect(model.batchPosition(of: item) == 1)
        #expect(context.pasteboard.string(forType: .string) == "旧记录")

        model.toggleBatchMembership(item)
        #expect(!model.isInBatch(item))
    }

    @Test func pasteKeyObserverSkipsIgnoredPastes() {
        let observer = PasteKeyObserver()
        var count = 0
        observer.onPaste = { count += 1 }

        observer.ignoreNextPaste()
        observer.handlePasteEvent()
        #expect(count == 0)

        observer.handlePasteEvent()
        #expect(count == 1)
    }

    private func makeCapture(_ title: String) -> CapturedClipboard {
        CapturedClipboard(kind: .text, title: title, text: title, imageData: nil, filePaths: [])
    }

    private func makeOnePixelPNG() throws -> Data {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4,
            bitsPerPixel: 32
        )
        return try #require(representation?.representation(using: .png, properties: [:]))
    }

    private func makeContext() throws -> BatchTestContext {
        let suiteName = "SSClipTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suiteName))
        let store = ClipboardStore(baseDirectory: directory)
        let model = AppModel(
            settings: AppSettings(defaults: defaults),
            store: store,
            pasteService: PasteService(pasteboard: pasteboard)
        )
        model.queueAdvanceDelay = 0
        return BatchTestContext(
            model: model,
            store: store,
            pasteboard: pasteboard,
            suiteName: suiteName,
            directory: directory
        )
    }
}

@MainActor
private struct BatchTestContext {
    let model: AppModel
    let store: ClipboardStore
    let pasteboard: NSPasteboard
    let suiteName: String
    let directory: URL

    func cleanUp() {
        pasteboard.releaseGlobally()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
