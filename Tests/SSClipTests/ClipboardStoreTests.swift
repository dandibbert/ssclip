import AppKit
import Foundation
import Testing
@testable import SSClip

private enum InjectedFileError: Error { case failed }

private final class ChangeCountSequence {
    private var values: [Int]

    init(_ values: [Int]) {
        self.values = values
    }

    func next() -> Int {
        values.removeFirst()
    }
}

@MainActor
struct ClipboardStoreTests {
    @Test func compactTitleCollapsesWhitespaceAndNewlines() {
        let value = ClipboardMonitor.compactTitle(from: "  第一行\n\n  第二行\t结尾 ")
        #expect(value == "第一行 第二行 结尾")
    }

    @Test func concealedAndTransientClipboardTypesAreNotRecorded() {
        #expect(ClipboardMonitor.shouldIgnore(types: [.init("org.nspasteboard.ConcealedType")]))
        #expect(ClipboardMonitor.shouldIgnore(types: [.init("org.nspasteboard.TransientType")]))
        #expect(!ClipboardMonitor.shouldIgnore(types: [.string]))
    }

    @Test func newerTextCancelsAnEarlierImageCapture() async throws {
        let suiteName = "SSClipTests-monitor-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suiteName))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(
            settings: AppSettings(defaults: defaults),
            pasteboard: pasteboard,
            imageEncoder: { _ in
                try? await Task.sleep(nanoseconds: 100_000_000)
                return EncodedClipboardImage(data: Data([0x01]), dimensions: "1 × 1")
            }
        )
        var captures: [CapturedClipboard] = []
        monitor.onCapture = { captures.append($0) }

        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([try makeOnePixelImage()]))
        monitor.checkForChange()
        pasteboard.clearContents()
        pasteboard.setString("new text", forType: .string)
        monitor.checkForChange()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(captures.count == 1)
        #expect(captures.first?.kind == .text)
        #expect(captures.first?.title == "new text")
    }

    @Test func newerFilesCancelAnEarlierImageCapture() async throws {
        let suiteName = "SSClipTests-monitor-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suiteName))
        defer { pasteboard.releaseGlobally() }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("new-file-\(UUID().uuidString).txt")
        try Data("file".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let monitor = ClipboardMonitor(
            settings: AppSettings(defaults: defaults),
            pasteboard: pasteboard,
            imageEncoder: { _ in
                try? await Task.sleep(nanoseconds: 100_000_000)
                return EncodedClipboardImage(data: Data([0x01]), dimensions: "1 × 1")
            }
        )
        var captures: [CapturedClipboard] = []
        monitor.onCapture = { captures.append($0) }

        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([try makeOnePixelImage()]))
        monitor.checkForChange()
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([fileURL as NSURL]))
        monitor.checkForChange()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(captures.count == 1)
        #expect(captures.first?.kind == .files)
        #expect(captures.first?.title == fileURL.lastPathComponent)
    }

    @Test func changedGenerationDropsSynchronousTextCapture() throws {
        let suiteName = "SSClipTests-text-generation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let pasteboard = NSPasteboard(name: .init(suiteName))
        defer { pasteboard.releaseGlobally() }
        let changeCounts = ChangeCountSequence([0, 1, 2])
        let monitor = ClipboardMonitor(
            settings: AppSettings(defaults: defaults),
            pasteboard: pasteboard,
            changeCountProvider: { changeCounts.next() }
        )
        var captures: [CapturedClipboard] = []
        monitor.onCapture = { captures.append($0) }

        pasteboard.clearContents()
        pasteboard.setString("stale text", forType: .string)
        monitor.checkForChange()

        #expect(captures.isEmpty)
    }

    @Test func changedGenerationDropsSynchronousFilesCapture() throws {
        let suiteName = "SSClipTests-files-generation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let pasteboard = NSPasteboard(name: .init(suiteName))
        defer { pasteboard.releaseGlobally() }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-file-\(UUID().uuidString).txt")
        try Data("file".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let changeCounts = ChangeCountSequence([0, 1, 2])
        let monitor = ClipboardMonitor(
            settings: AppSettings(defaults: defaults),
            pasteboard: pasteboard,
            changeCountProvider: { changeCounts.next() }
        )
        var captures: [CapturedClipboard] = []
        monitor.onCapture = { captures.append($0) }

        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([fileURL as NSURL]))
        monitor.checkForChange()

        #expect(captures.isEmpty)
    }

    @Test func imageEncodingDoesNotDeliverAfterAnUnpolledClipboardChange() async throws {
        let suiteName = "SSClipTests-unpolled-monitor-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let pasteboard = NSPasteboard(name: .init(suiteName))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(
            settings: AppSettings(defaults: defaults),
            pasteboard: pasteboard,
            imageEncoder: { _ in
                try? await Task.sleep(nanoseconds: 100_000_000)
                return EncodedClipboardImage(data: Data([0x01]), dimensions: "1 × 1")
            }
        )
        var captures: [CapturedClipboard] = []
        monitor.onCapture = { captures.append($0) }

        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([try makeOnePixelImage()]))
        monitor.checkForChange()
        pasteboard.clearContents()
        pasteboard.setString("new but not polled", forType: .string)
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(captures.isEmpty)
    }

    @Test func legacyLetterShortcutMigratesToRecordedKeyCode() throws {
        let json = #"{"key":"v","usesCommand":true,"usesOption":true,"usesControl":false,"usesShift":false}"#
        let configuration = try JSONDecoder().decode(HotKeyConfiguration.self, from: Data(json.utf8))

        #expect(configuration.keyCode == 9)
        #expect(configuration.displayName == "⌥⌘V")
        #expect(configuration.isValid)
    }

    @Test func recordedShortcutRoundTripsWithSpecialKey() throws {
        let original = HotKeyConfiguration(
            keyCode: 123,
            keyDisplayName: "←",
            usesCommand: true,
            usesOption: false,
            usesControl: true,
            usesShift: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotKeyConfiguration.self, from: data)

        #expect(decoded == original)
        #expect(decoded.displayName == "⌃⌘←")
    }

    @Test func duplicateCaptureMovesToFrontWithoutLosingFavorite() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(baseDirectory: directory)
        let first = CapturedClipboard(kind: .text, title: "第一条", text: "first", imageData: nil, filePaths: [])
        let second = CapturedClipboard(kind: .text, title: "第二条", text: "second", imageData: nil, filePaths: [])

        let original = try #require(store.add(first))
        store.toggleFavorite(original)
        store.add(second)
        let repeated = try #require(store.add(first))

        #expect(store.items.map(\.title) == ["第一条", "第二条"])
        #expect(repeated.isFavorite)
    }

    @Test func pastedHistoryItemMovesToFrontAndKeepsItsCollection() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(baseDirectory: directory)
        let folder = try #require(store.addFolder(named: "常用"))
        let older = try #require(store.add(.init(
            kind: .text,
            title: "旧记录",
            text: "older",
            imageData: nil,
            filePaths: []
        )))
        store.move(older, to: folder)
        store.add(.init(kind: .text, title: "新记录", text: "newer", imageData: nil, filePaths: []))
        let reusedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let promoted = try #require(store.promote(older, at: reusedAt))

        #expect(store.items.first?.id == older.id)
        #expect(promoted.createdAt == reusedAt)
        #expect(promoted.isFavorite)
        #expect(promoted.folderID == folder.id)
    }

    @Test func retentionKeepsFavoritesAndLimitsRegularItems() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(baseDirectory: directory)

        for index in 0..<15 {
            let capture = CapturedClipboard(
                kind: .text,
                title: "条目 \(index)",
                text: "value-\(index)",
                imageData: nil,
                filePaths: []
            )
            store.add(capture)
        }
        let oldest = try #require(store.items.last)
        store.toggleFavorite(oldest)
        store.applyRetention(cutoff: nil, maximumItems: 10)

        #expect(store.items.count == 10)
        #expect(store.items.contains { $0.id == oldest.id })
    }

    @Test func foldersPersistAcrossStoreReload() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(baseDirectory: directory)
        let folder = try #require(store.addFolder(named: "工作"))
        let item = try #require(store.add(.init(kind: .text, title: "内容", text: "内容", imageData: nil, filePaths: [])))
        store.move(item, to: folder)
        try store.saveImmediately()

        let reloaded = ClipboardStore(baseDirectory: directory)
        #expect(reloaded.folders == [folder])
        #expect(reloaded.items.first?.folderID == folder.id)
    }

    @Test func unavailableStorageRemainsUsableInMemoryAndPublishesAnError() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unavailableRoot = directory.appendingPathComponent("not-a-directory")
        try Data("blocking file".utf8).write(to: unavailableRoot)

        let store = ClipboardStore(baseDirectory: unavailableRoot)

        #expect(store.storageErrorMessage == "无法访问本地存储；本次会话的历史可能不会保存。")
        let captured = store.add(.init(
            kind: .text,
            title: "仍可使用",
            text: "in-memory",
            imageData: nil,
            filePaths: []
        ))
        #expect(captured != nil)
        #expect(store.items.count == 1)

        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(store.storageErrorMessage != nil)
    }

    @Test func corruptHistoryIsPreservedAndSuccessfulRetryCreatesFreshHistory() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyURL = directory.appendingPathComponent("history.json")
        try Data("{not-json".utf8).write(to: historyURL)

        let store = ClipboardStore(baseDirectory: directory)

        #expect(store.items.isEmpty)
        #expect(store.storageErrorMessage == "历史文件已损坏，已保留副本并从空历史启动。")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains { $0.hasPrefix("history.corrupt-") && $0.hasSuffix(".json") })

        store.add(.init(
            kind: .text,
            title: "新记录",
            text: "new value",
            imageData: nil,
            filePaths: []
        ))
        try store.saveImmediately()

        #expect(store.storageErrorMessage == nil)
        let savedData = try Data(contentsOf: historyURL)
        #expect((try JSONSerialization.jsonObject(with: savedData)) is [String: Any])
    }

    @Test func historyImageURLOnlyAcceptsUUIDPNGBasenames() throws {
        let baseDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let imagesDirectory = baseDirectory.appendingPathComponent("Images", isDirectory: true)
        let validName = "\(UUID().uuidString).png"
        let expected = imagesDirectory.standardizedFileURL.appendingPathComponent(validName)
        let traversalName = "\(UUID().uuidString).png"
        let absoluteName = baseDirectory.appendingPathComponent("\(UUID().uuidString).png").path

        #expect(ClipboardItem.safeImageURL(
            filename: validName,
            imagesDirectory: imagesDirectory
        ) == expected)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let directoryName = "\(UUID().uuidString).png"
        try FileManager.default.createDirectory(
            at: imagesDirectory.appendingPathComponent(directoryName),
            withIntermediateDirectories: false
        )
        #expect(ClipboardItem.safeImageURL(
            filename: directoryName,
            imagesDirectory: imagesDirectory
        ) == nil)
        for invalid in [
            "../\(traversalName)",
            absoluteName,
            "not-a-uuid.png",
            "\(UUID().uuidString).PNG",
            "\(UUID().uuidString).jpg",
            ".",
            "..",
        ] {
            #expect(ClipboardItem.safeImageURL(
                filename: invalid,
                imagesDirectory: imagesDirectory
            ) == nil)
        }

        let malicious = ClipboardItem(
            kind: .image,
            title: "malicious",
            imageFilename: "../\(traversalName)",
            fingerprint: "malicious"
        )
        #expect(malicious.previewURL(imagesDirectory: imagesDirectory) == nil)
    }

    @Test func maliciousImageFilenameCannotDeleteOutsideImagesDirectory() throws {
        let baseDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let itemID = UUID()
        let sentinelFilename = "\(UUID().uuidString).png"
        let json = """
        {"version":1,"folders":[],"items":[{"id":"\(itemID.uuidString)",\
        "createdAt":"2026-07-01T00:00:00Z","kind":"image","title":"outside",\
        "imageFilename":"../\(sentinelFilename)","filePaths":[],"fingerprint":"outside",\
        "byteCount":16,"isFavorite":false}]}
        """
        try Data(json.utf8).write(to: baseDirectory.appendingPathComponent("history.json"))
        let sentinelURL = baseDirectory.appendingPathComponent(sentinelFilename)
        let sentinel = Data("outside-sentinel".utf8)
        try sentinel.write(to: sentinelURL)
        let store = ClipboardStore(baseDirectory: baseDirectory)
        let item = try #require(store.items.first)

        store.remove(item)
        try store.saveImmediately()

        #expect(try Data(contentsOf: sentinelURL) == sentinel)
    }

    @Test func imageWriteFailureIsVisibleAndDoesNotAddHistory() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var operations = ClipboardFileOperations.live
        operations.writeImageAtomically = { _, _ in throw InjectedFileError.failed }
        let store = ClipboardStore(baseDirectory: directory, fileOperations: operations)

        let added = store.add(.init(
            kind: .image,
            title: "image",
            text: nil,
            imageData: Data([0x01]),
            filePaths: []
        ))

        #expect(added == nil)
        #expect(store.items.isEmpty)
        #expect(store.storageErrorMessage == "图片保存失败；该图片未加入历史。")
    }

    @Test func imagePermissionFailureKeepsExistingDuplicate() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var permissionAttempts = 0
        var operations = ClipboardFileOperations.live
        operations.setImageOwnerOnlyPermissions = { url in
            permissionAttempts += 1
            if permissionAttempts == 2 { throw InjectedFileError.failed }
            try ClipboardFileOperations.live.setImageOwnerOnlyPermissions(url)
        }
        let store = ClipboardStore(baseDirectory: directory, fileOperations: operations)
        let capture = CapturedClipboard(
            kind: .image,
            title: "same image",
            text: nil,
            imageData: Data([0x01, 0x02]),
            filePaths: []
        )
        let original = try #require(store.add(capture))
        let folder = try #require(store.addFolder(named: "images"))
        store.move(original, to: folder)

        #expect(store.add(capture) == nil)
        #expect(store.items.map(\.id) == [original.id])
        #expect(store.items.first?.isFavorite == true)
        #expect(store.items.first?.folderID == folder.id)
        #expect(store.storageErrorMessage == "图片保存失败；该图片未加入历史。")
    }

    @Test func permissionFailureTracksOrphanUntilScheduledCleanupSucceeds() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var writtenURLs: [URL] = []
        var permissionAttempts = 0
        var removeAttempts = 0
        var operations = ClipboardFileOperations.live
        operations.writeImageAtomically = { data, url in
            writtenURLs.append(url)
            try ClipboardFileOperations.live.writeImageAtomically(data, url)
        }
        operations.setImageOwnerOnlyPermissions = { url in
            permissionAttempts += 1
            if permissionAttempts == 2 { throw InjectedFileError.failed }
            try ClipboardFileOperations.live.setImageOwnerOnlyPermissions(url)
        }
        operations.removeImage = { url in
            removeAttempts += 1
            if removeAttempts == 1 { throw InjectedFileError.failed }
            try ClipboardFileOperations.live.removeImage(url)
        }
        let store = ClipboardStore(baseDirectory: directory, fileOperations: operations)
        let capture = CapturedClipboard(
            kind: .image,
            title: "same image",
            text: nil,
            imageData: Data([0x01, 0x02]),
            filePaths: []
        )
        let original = try #require(store.add(capture))
        try store.saveImmediately()
        let originalImageURL = try #require(ClipboardItem.safeImageURL(
            filename: original.imageFilename,
            imagesDirectory: store.imagesDirectory
        ))

        #expect(store.add(capture) == nil)
        let orphanURL = try #require(writtenURLs.last)
        #expect(orphanURL != originalImageURL)
        #expect(store.items.map(\.id) == [original.id])
        #expect(FileManager.default.fileExists(atPath: originalImageURL.path))
        #expect(FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(removeAttempts == 1)

        try await Task.sleep(nanoseconds: 600_000_000)

        #expect(removeAttempts == 2)
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(FileManager.default.fileExists(atPath: originalImageURL.path))
        #expect(store.items.map(\.id) == [original.id])
    }

    @Test func olderPendingSaveCannotClearImagePersistenceFailure() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var imageWriteShouldFail = true
        var operations = ClipboardFileOperations.live
        operations.writeImageAtomically = { data, url in
            if imageWriteShouldFail { throw InjectedFileError.failed }
            try ClipboardFileOperations.live.writeImageAtomically(data, url)
        }
        let store = ClipboardStore(baseDirectory: directory, fileOperations: operations)
        store.add(.init(
            kind: .text,
            title: "pending text save",
            text: "pending",
            imageData: nil,
            filePaths: []
        ))

        #expect(store.add(.init(
            kind: .image,
            title: "failed image",
            text: nil,
            imageData: Data([0x01]),
            filePaths: []
        )) == nil)
        #expect(store.storageErrorMessage == "图片保存失败；该图片未加入历史。")

        try await Task.sleep(nanoseconds: 600_000_000)

        #expect(store.storageErrorMessage == "图片保存失败；该图片未加入历史。")
        imageWriteShouldFail = false
        #expect(store.add(.init(
            kind: .image,
            title: "successful image",
            text: nil,
            imageData: Data([0x02]),
            filePaths: []
        )) != nil)
        try store.saveImmediately()
        #expect(store.storageErrorMessage == nil)
    }

    @Test func deletionRecoveryRestoresOutstandingImagePersistenceFailure() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var imageWriteShouldFail = false
        var removalShouldFail = true
        var operations = ClipboardFileOperations.live
        operations.writeImageAtomically = { data, url in
            if imageWriteShouldFail { throw InjectedFileError.failed }
            try ClipboardFileOperations.live.writeImageAtomically(data, url)
        }
        operations.removeImage = { url in
            if removalShouldFail {
                removalShouldFail = false
                throw InjectedFileError.failed
            }
            try ClipboardFileOperations.live.removeImage(url)
        }
        let store = ClipboardStore(baseDirectory: directory, fileOperations: operations)
        let original = try #require(store.add(.init(
            kind: .image,
            title: "original image",
            text: nil,
            imageData: Data([0x01]),
            filePaths: []
        )))
        try store.saveImmediately()
        imageWriteShouldFail = true

        #expect(store.add(.init(
            kind: .image,
            title: "failed image",
            text: nil,
            imageData: Data([0x02]),
            filePaths: []
        )) == nil)
        #expect(store.storageErrorMessage == "图片保存失败；该图片未加入历史。")
        store.remove(original)

        #expect(throws: (any Error).self) { try store.saveImmediately() }
        #expect(store.storageErrorMessage == "部分图片文件无法删除；稍后将自动重试。")

        try store.saveImmediately()
        #expect(store.storageErrorMessage == "图片保存失败；该图片未加入历史。")

        imageWriteShouldFail = false
        #expect(store.add(.init(
            kind: .image,
            title: "recovered image",
            text: nil,
            imageData: Data([0x03]),
            filePaths: []
        )) != nil)
        try store.saveImmediately()
        #expect(store.storageErrorMessage == nil)
    }

    @Test func failedImageDeletionRemainsVisibleUntilRetrySucceeds() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var removeAttempts = 0
        var operations = ClipboardFileOperations.live
        operations.removeImage = { url in
            removeAttempts += 1
            if removeAttempts == 1 { throw InjectedFileError.failed }
            try ClipboardFileOperations.live.removeImage(url)
        }
        let store = ClipboardStore(baseDirectory: directory, fileOperations: operations)
        let item = try #require(store.add(.init(
            kind: .image,
            title: "image",
            text: nil,
            imageData: Data([0x01]),
            filePaths: []
        )))
        let imageURL = try #require(ClipboardItem.safeImageURL(
            filename: item.imageFilename,
            imagesDirectory: store.imagesDirectory
        ))
        store.remove(item)

        #expect(throws: (any Error).self) { try store.saveImmediately() }
        #expect(store.storageErrorMessage == "部分图片文件无法删除；稍后将自动重试。")
        #expect(FileManager.default.fileExists(atPath: imageURL.path))
        let savedObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("history.json"))
            ) as? [String: Any]
        )
        let savedItems = try #require(savedObject["items"] as? [[String: Any]])
        #expect(savedItems.isEmpty)

        try store.saveImmediately()
        #expect(store.storageErrorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: imageURL.path))
        #expect(removeAttempts == 2)
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSClipTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeOnePixelImage() throws -> NSImage {
        let representation = try #require(NSBitmapImageRep(
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
        ))
        representation.bitmapData?[0] = 0x33
        representation.bitmapData?[1] = 0x66
        representation.bitmapData?[2] = 0x99
        representation.bitmapData?[3] = 0xFF
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.addRepresentation(representation)
        return image
    }
}
