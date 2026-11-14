import AppKit
import Foundation
import Testing
@testable import SSClip

@MainActor
struct CaptureAndStateTests {
    @Test func ownWritesAreMarkedAndNotRecordedAgain() throws {
        let context = try makeMonitorContext()
        defer { context.cleanUp() }
        let service = PasteService(pasteboard: context.pasteboard)
        let item = ClipboardItem(kind: .text, title: "value", text: "value", fingerprint: "value")

        #expect(service.write(item, imagesDirectory: FileManager.default.temporaryDirectory))
        context.monitor.checkForChange()

        #expect(context.pasteboard.types?.contains(.ssclipOwnWrite) == true)
        #expect(context.pasteboard.string(forType: .string) == "value")
        #expect(context.captures.values.isEmpty)
    }

    @Test func copyRightAfterAnOwnWriteIsStillRecorded() throws {
        let context = try makeMonitorContext()
        defer { context.cleanUp() }
        let service = PasteService(pasteboard: context.pasteboard)
        let item = ClipboardItem(kind: .text, title: "value", text: "value", fingerprint: "value")

        // 自己写入之后、下一次轮询之前，用户又复制了别的内容。
        #expect(service.write(item, imagesDirectory: FileManager.default.temporaryDirectory))
        context.pasteboard.clearContents()
        context.pasteboard.setString("user copy", forType: .string)
        context.monitor.checkForChange()

        #expect(context.captures.values.map(\.title) == ["user copy"])
    }

    @Test func capturesCarryTheSourceApplication() throws {
        let context = try makeMonitorContext(
            source: ClipboardSourceApplication(name: "Notes", bundleIdentifier: "com.example.notes")
        )
        defer { context.cleanUp() }

        context.pasteboard.clearContents()
        context.pasteboard.setString("from notes", forType: .string)
        context.monitor.checkForChange()

        let capture = try #require(context.captures.values.first)
        #expect(capture.sourceAppName == "Notes")
        #expect(capture.sourceBundleID == "com.example.notes")
    }

    @Test func copiesFromExcludedApplicationsAreNotRecorded() throws {
        let context = try makeMonitorContext(
            source: ClipboardSourceApplication(name: "Vault", bundleIdentifier: "com.example.vault")
        )
        defer { context.cleanUp() }
        context.settings.excludedBundleIDs = ["com.example.vault"]

        context.pasteboard.clearContents()
        context.pasteboard.setString("secret", forType: .string)
        context.monitor.checkForChange()
        #expect(context.captures.values.isEmpty)

        context.settings.excludedBundleIDs = []
        context.pasteboard.clearContents()
        context.pasteboard.setString("public", forType: .string)
        context.monitor.checkForChange()
        #expect(context.captures.values.map(\.title) == ["public"])
    }

    @Test func pausedCaptureDropsChangesAndDoesNotReplayThemOnResume() throws {
        let context = try makeMonitorContext()
        defer { context.cleanUp() }
        context.settings.capturePaused = true

        context.pasteboard.clearContents()
        context.pasteboard.setString("while paused", forType: .string)
        context.monitor.checkForChange()
        #expect(context.captures.values.isEmpty)

        context.settings.capturePaused = false
        context.monitor.checkForChange()
        #expect(context.captures.values.isEmpty)

        context.pasteboard.clearContents()
        context.pasteboard.setString("after resume", forType: .string)
        context.monitor.checkForChange()
        #expect(context.captures.values.map(\.title) == ["after resume"])
    }

    @Test func excludedApplicationsPersist() throws {
        let suiteName = "SSClipTests-excluded-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.excludedBundleIDs.isEmpty)
        settings.excludedBundleIDs = ["com.example.vault"]

        #expect(AppSettings(defaults: defaults).excludedBundleIDs == ["com.example.vault"])
        #expect(!AppSettings(defaults: defaults).capturePaused)
    }

    @Test func sourceApplicationSurvivesAStoreReload() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(baseDirectory: directory)
        var capture = CapturedClipboard(kind: .text, title: "text", text: "text", imageData: nil, filePaths: [])
        capture.sourceAppName = "Notes"
        capture.sourceBundleID = "com.example.notes"
        store.add(capture)
        try store.saveImmediately()

        let reloaded = ClipboardStore(baseDirectory: directory)
        #expect(reloaded.items.first?.sourceAppName == "Notes")
        #expect(reloaded.items.first?.sourceBundleID == "com.example.notes")
        #expect(reloaded.items.first?.searchableText.contains("Notes") == true)
    }

    @Test func unreferencedImagesAreRemovedWhenHistoryLoads() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(baseDirectory: directory)
        let item = try #require(store.add(CapturedClipboard(
            kind: .image,
            title: "image",
            text: nil,
            imageData: Data([0x01, 0x02]),
            filePaths: []
        )))
        try store.saveImmediately()
        let keptURL = store.imagesDirectory.appendingPathComponent(try #require(item.imageFilename))
        let orphanURL = store.imagesDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let unrelatedURL = store.imagesDirectory.appendingPathComponent("notes.txt")
        try Data([0x03]).write(to: orphanURL)
        try Data([0x04]).write(to: unrelatedURL)

        _ = ClipboardStore(baseDirectory: directory)

        #expect(FileManager.default.fileExists(atPath: keptURL.path))
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    @Test func failedSaveIsRetriedWithoutAnotherChange() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var removeShouldFail = true
        var operations = ClipboardFileOperations.live
        operations.removeImage = { url in
            if removeShouldFail { throw InjectedRemoveError.failed }
            try ClipboardFileOperations.live.removeImage(url)
        }
        let store = ClipboardStore(baseDirectory: directory, fileOperations: operations)
        store.saveRetryDelay = 0.05
        let item = try #require(store.add(CapturedClipboard(
            kind: .image,
            title: "image",
            text: nil,
            imageData: Data([0x01, 0x02]),
            filePaths: []
        )))
        let imageURL = store.imagesDirectory.appendingPathComponent(try #require(item.imageFilename))
        try store.saveImmediately()

        store.remove(item)
        #expect(throws: (any Error).self) { try store.saveImmediately() }
        #expect(FileManager.default.fileExists(atPath: imageURL.path))
        #expect(store.storageErrorMessage != nil)

        removeShouldFail = false
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(!FileManager.default.fileExists(atPath: imageURL.path))
        #expect(store.storageErrorMessage == nil)
    }

    @Test func searchRequiresEveryTermInAnyOrder() throws {
        let context = try makeModelContext()
        defer { context.cleanUp() }
        let model = context.model
        context.store.add(makeCapture("swift package manifest"))
        context.store.add(makeCapture("swift concurrency"))
        context.store.add(makeCapture("package lock"))

        model.searchQuery = "package  swift"
        #expect(model.filteredItems.map(\.title) == ["swift package manifest"])

        model.searchQuery = "   "
        #expect(model.filteredItems.count == 3)
    }

    @Test func rejectedHotKeyIsRestoredInSettings() async throws {
        let context = try makeModelContext()
        defer { context.cleanUp() }
        let unusable = HotKeyConfiguration(
            keyCode: 0,
            keyDisplayName: "A",
            usesCommand: false,
            usesOption: false,
            usesControl: false,
            usesShift: false
        )

        context.settings.hotKey = unusable
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(context.settings.hotKey == HotKeyConfiguration())
        #expect(context.settings.hotKeyValidationMessage != nil)
        #expect(AppSettings(defaults: context.defaults).hotKey == HotKeyConfiguration())
        _ = context.model
    }

    @Test func skippedAutomaticPasteIsReported() throws {
        _ = NSApplication.shared
        let target = try #require(NSRunningApplication(processIdentifier: getpid()))
        var postedPasteCount = 0
        var skippedCount = 0
        let environment = PasteService.Environment(
            requestAccessibility: { true },
            activate: { _ in true },
            frontmostProcessIdentifier: { nil },
            schedulePaste: { action in action() },
            postCommandV: { _ in postedPasteCount += 1 }
        )
        let pasteboard = NSPasteboard(name: .init("SSClip.skipped-paste.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let service = PasteService(pasteboard: pasteboard, environment: environment)
        service.onAutomaticPasteSkipped = { skippedCount += 1 }
        let item = ClipboardItem(kind: .text, title: "value", text: "value", fingerprint: "value")

        _ = service.paste(
            item,
            imagesDirectory: FileManager.default.temporaryDirectory,
            targetApplication: target
        )

        #expect(postedPasteCount == 0)
        #expect(skippedCount == 1)
        #expect(pasteboard.string(forType: .string) == "value")
    }

    private func makeCapture(_ title: String) -> CapturedClipboard {
        CapturedClipboard(kind: .text, title: title, text: title, imageData: nil, filePaths: [])
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SSClipTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeMonitorContext(
        source: ClipboardSourceApplication? = nil
    ) throws -> MonitorTestContext {
        let suiteName = "SSClipTests-capture-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let settings = AppSettings(defaults: defaults)
        settings.soundEnabled = false
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suiteName))
        let monitor = ClipboardMonitor(
            settings: settings,
            pasteboard: pasteboard,
            sourceApplicationProvider: { source }
        )
        let captures = CaptureLog()
        monitor.onCapture = { captures.values.append($0) }
        return MonitorTestContext(
            settings: settings,
            pasteboard: pasteboard,
            monitor: monitor,
            captures: captures,
            suiteName: suiteName
        )
    }

    private func makeModelContext() throws -> ModelTestContext {
        let suiteName = "SSClipTests-state-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let directory = makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: defaults)
        let store = ClipboardStore(baseDirectory: directory)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suiteName))
        let model = AppModel(
            settings: settings,
            store: store,
            pasteService: PasteService(pasteboard: pasteboard)
        )
        return ModelTestContext(
            model: model,
            settings: settings,
            store: store,
            defaults: defaults,
            pasteboard: pasteboard,
            suiteName: suiteName,
            directory: directory
        )
    }
}

private enum InjectedRemoveError: Error { case failed }

private final class CaptureLog {
    var values: [CapturedClipboard] = []
}

@MainActor
private struct MonitorTestContext {
    let settings: AppSettings
    let pasteboard: NSPasteboard
    let monitor: ClipboardMonitor
    let captures: CaptureLog
    let suiteName: String

    func cleanUp() {
        pasteboard.releaseGlobally()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private struct ModelTestContext {
    let model: AppModel
    let settings: AppSettings
    let store: ClipboardStore
    let defaults: UserDefaults
    let pasteboard: NSPasteboard
    let suiteName: String
    let directory: URL

    func cleanUp() {
        pasteboard.releaseGlobally()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
