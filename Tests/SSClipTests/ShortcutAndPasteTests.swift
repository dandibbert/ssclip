import AppKit
import Foundation
import Testing
@testable import SSClip

@MainActor
struct ShortcutAndPasteTests {
    private final class FrontmostPIDState {
        var value: pid_t?

        init(_ value: pid_t?) {
            self.value = value
        }
    }

    @Test func defaultPanelShortcutsHaveNoConflicts() {
        let shortcuts = PanelShortcuts()
        #expect(shortcuts.conflictDescription(globalHotKey: HotKeyConfiguration()) == nil)
    }

    @Test func duplicateComboAcrossPanelActionsIsReported() {
        var shortcuts = PanelShortcuts()
        shortcuts.deleteItem = shortcuts.search
        let message = shortcuts.conflictDescription(globalHotKey: HotKeyConfiguration())
        #expect(message != nil)
        #expect(message?.contains("搜索") == true)
        #expect(message?.contains("删除") == true)
    }

    @Test func panelShortcutConflictsWithGlobalHotKeyIsReported() {
        var shortcuts = PanelShortcuts()
        let global = HotKeyConfiguration()
        shortcuts.toggleFavorite = global
        let message = shortcuts.conflictDescription(globalHotKey: global)
        #expect(message != nil)
        #expect(message?.contains("呼出面板") == true)
    }

    @Test func sameComboIgnoresDisplayName() {
        let first = HotKeyConfiguration(
            keyCode: 3, keyDisplayName: "F",
            usesCommand: true, usesOption: false, usesControl: false, usesShift: false
        )
        let second = HotKeyConfiguration(
            keyCode: 3, keyDisplayName: "f",
            usesCommand: true, usesOption: false, usesControl: false, usesShift: false
        )
        #expect(first.sameCombo(as: second))
    }

    @Test func legacyPanelShortcutsPayloadFallsBackToDefaultsForMissingKeys() throws {
        let json = #"{"search":{"keyCode":40,"keyDisplayName":"K","usesCommand":true,"usesOption":false,"usesControl":false,"usesShift":false}}"#
        let decoded = try JSONDecoder().decode(PanelShortcuts.self, from: Data(json.utf8))
        let defaults = PanelShortcuts()

        #expect(decoded.search.keyCode == 40)
        #expect(decoded.deleteItem.sameCombo(as: defaults.deleteItem))
        #expect(decoded.pastePlainText.sameCombo(as: defaults.pastePlainText))
    }

    @Test func plainTextPasteOmitsRichRepresentations() throws {
        let rtf = Data("rtf-bytes".utf8)
        let html = Data("<b>hi</b>".utf8)
        let item = ClipboardItem(
            kind: .text,
            title: "hi",
            text: "hi",
            rtfData: rtf,
            htmlData: html,
            fingerprint: "fp"
        )

        let standard = try #require(PasteService.textPasteboardItem(for: item, mode: .standard))
        #expect(standard.string(forType: .string) == "hi")
        #expect(standard.data(forType: .rtf) == rtf)
        #expect(standard.data(forType: .html) == html)

        let plain = try #require(PasteService.textPasteboardItem(for: item, mode: .plainText))
        #expect(plain.string(forType: .string) == "hi")
        #expect(plain.data(forType: .rtf) == nil)
        #expect(plain.data(forType: .html) == nil)
    }

    @Test func invalidHistoryItemsLeaveExistingPasteboardContentsUntouched() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SSClip.invalid-history.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let service = PasteService(pasteboard: pasteboard)
        let imagesDirectory = FileManager.default.temporaryDirectory
        let invalidItems = [
            ClipboardItem(kind: .text, title: "bad", text: nil, fingerprint: "missing-text"),
            ClipboardItem(
                kind: .image,
                title: "bad image",
                imageFilename: "missing.png",
                fingerprint: "missing-image"
            ),
            ClipboardItem(kind: .files, title: "bad files", filePaths: [], fingerprint: "empty-files"),
        ]

        for item in invalidItems {
            #expect(service.write(item, imagesDirectory: imagesDirectory) == false)
            #expect(pasteboard.string(forType: .string) == "original")
        }
    }

    @Test func maliciousImageFilenameCannotReadOutsideImagesDirectory() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSClipReadBoundary-\(UUID().uuidString)", isDirectory: true)
        let imagesDirectory = baseDirectory.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
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
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.addRepresentation(representation)
        let outsideData = try #require(image.tiffRepresentation)
        let outsideFilename = "\(UUID().uuidString).png"
        try outsideData.write(to: baseDirectory.appendingPathComponent(outsideFilename))
        let pasteboard = NSPasteboard(name: .init("SSClip.read-boundary.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let service = PasteService(pasteboard: pasteboard)
        let malicious = ClipboardItem(
            kind: .image,
            title: "outside",
            imageFilename: "../\(outsideFilename)",
            fingerprint: "outside"
        )

        #expect(service.write(malicious, imagesDirectory: imagesDirectory) == false)
        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test func uuidImageSymlinkCannotPreviewOrPasteOutsideImagesDirectory() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSClipSymlinkBoundary-\(UUID().uuidString)", isDirectory: true)
        let imagesDirectory = baseDirectory.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let outsideImageURL = baseDirectory.appendingPathComponent("outside.png")
        let outsideImage = try makeOnePixelImage()
        let outsideData = try #require(outsideImage.tiffRepresentation)
        try outsideData.write(to: outsideImageURL)
        let symlinkURL = imagesDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideImageURL)
        let item = ClipboardItem(
            kind: .image,
            title: "external symlink",
            imageFilename: symlinkURL.lastPathComponent,
            fingerprint: "external-symlink"
        )
        let pasteboard = NSPasteboard(name: .init("SSClip.symlink-boundary.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let environment = PasteService.Environment(
            requestAccessibility: { false },
            activate: { _ in false },
            frontmostProcessIdentifier: { nil },
            schedulePaste: { _ in },
            postCommandV: { _ in }
        )
        let service = PasteService(pasteboard: pasteboard, environment: environment)

        #expect(item.previewURL(imagesDirectory: imagesDirectory) == nil)
        let result = service.paste(
            item,
            imagesDirectory: imagesDirectory,
            targetApplication: nil
        )
        guard case .failed = result else {
            Issue.record("External symlink image should fail before copying or posting")
            return
        }
        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test func pasteWithoutAnActivatedTargetCopiesWithoutPostingCommandV() throws {
        var postedPasteCount = 0
        let environment = PasteService.Environment(
            requestAccessibility: { true },
            activate: { _ in false },
            frontmostProcessIdentifier: { nil },
            schedulePaste: { action in action() },
            postCommandV: { _ in postedPasteCount += 1 }
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SSClip.target-gate.\(UUID().uuidString)"))
        let service = PasteService(pasteboard: pasteboard, environment: environment)
        let item = ClipboardItem(kind: .text, title: "valid", text: "valid", fingerprint: "valid")
        let imagesDirectory = FileManager.default.temporaryDirectory

        let missingTargetResult = service.paste(
            item,
            imagesDirectory: imagesDirectory,
            targetApplication: nil
        )
        guard case .copiedOnly = missingTargetResult else {
            Issue.record("Missing paste target should copy only")
            return
        }
        #expect(postedPasteCount == 0)

        _ = NSApplication.shared
        let currentApplication = try #require(NSRunningApplication(processIdentifier: getpid()))
        let failedActivationResult = service.paste(
            item,
            imagesDirectory: imagesDirectory,
            targetApplication: currentApplication
        )
        guard case .copiedOnly = failedActivationResult else {
            Issue.record("Failed target activation should copy only")
            return
        }
        #expect(postedPasteCount == 0)
    }

    @Test func delayedPasteOnlyPostsToTheOriginallyActivatedProcess() throws {
        _ = NSApplication.shared
        let target = try #require(NSRunningApplication(processIdentifier: getpid()))
        let frontmostPID = FrontmostPIDState(target.processIdentifier)
        var scheduledAction: (@MainActor @Sendable () -> Void)?
        var postedPasteCount = 0
        let environment = PasteService.Environment(
            requestAccessibility: { true },
            activate: { _ in true },
            frontmostProcessIdentifier: { frontmostPID.value },
            schedulePaste: { scheduledAction = $0 },
            postCommandV: { _ in postedPasteCount += 1 }
        )
        let pasteboard = NSPasteboard(name: .init("SSClip.focus-race.\(UUID().uuidString)"))
        let service = PasteService(pasteboard: pasteboard, environment: environment)
        let item = ClipboardItem(kind: .text, title: "value", text: "value", fingerprint: "value")

        let changedFocusResult = service.paste(
            item,
            imagesDirectory: FileManager.default.temporaryDirectory,
            targetApplication: target
        )
        guard case .pasted = changedFocusResult else {
            Issue.record("Activated target should schedule an automatic paste")
            return
        }
        frontmostPID.value = target.processIdentifier &+ 1
        scheduledAction?()
        #expect(postedPasteCount == 0)

        frontmostPID.value = target.processIdentifier
        let unchangedFocusResult = service.paste(
            item,
            imagesDirectory: FileManager.default.temporaryDirectory,
            targetApplication: target
        )
        guard case .pasted = unchangedFocusResult else {
            Issue.record("Activated target should schedule an automatic paste")
            return
        }
        scheduledAction?()
        #expect(postedPasteCount == 1)
    }

    @Test func delayedPasteDoesNotPostAfterAnExternalPasteboardWrite() throws {
        _ = NSApplication.shared
        let target = try #require(NSRunningApplication(processIdentifier: getpid()))
        var scheduledAction: (@MainActor @Sendable () -> Void)?
        var postedPasteCount = 0
        let environment = PasteService.Environment(
            requestAccessibility: { true },
            activate: { _ in true },
            frontmostProcessIdentifier: { target.processIdentifier },
            schedulePaste: { scheduledAction = $0 },
            postCommandV: { _ in postedPasteCount += 1 }
        )
        let pasteboard = NSPasteboard(name: .init("SSClip.external-write-race.\(UUID().uuidString)"))
        let service = PasteService(pasteboard: pasteboard, environment: environment)
        let item = ClipboardItem(kind: .text, title: "SSClip", text: "SSClip", fingerprint: "SSClip")

        let result = service.paste(
            item,
            imagesDirectory: FileManager.default.temporaryDirectory,
            targetApplication: target
        )
        guard case .pasted = result else {
            Issue.record("Activated target should schedule an automatic paste")
            return
        }
        pasteboard.clearContents()
        pasteboard.setString("external", forType: .string)

        scheduledAction?()

        #expect(postedPasteCount == 0)
        #expect(pasteboard.string(forType: .string) == "external")
    }

    @Test func onlyNewestRapidPastePostsToItsCapturedTarget() throws {
        _ = NSApplication.shared
        let target = try #require(NSRunningApplication(processIdentifier: getpid()))
        var scheduledActions: [@MainActor @Sendable () -> Void] = []
        var postedPasteCount = 0
        let environment = PasteService.Environment(
            requestAccessibility: { true },
            activate: { _ in true },
            frontmostProcessIdentifier: { target.processIdentifier },
            schedulePaste: { scheduledActions.append($0) },
            postCommandV: { _ in postedPasteCount += 1 }
        )
        let pasteboard = NSPasteboard(name: .init("SSClip.rapid-paste-race.\(UUID().uuidString)"))
        let service = PasteService(pasteboard: pasteboard, environment: environment)
        let first = ClipboardItem(kind: .text, title: "first", text: "first", fingerprint: "first")
        let second = ClipboardItem(kind: .text, title: "second", text: "second", fingerprint: "second")

        let firstResult = service.paste(
            first,
            imagesDirectory: FileManager.default.temporaryDirectory,
            targetApplication: target
        )
        guard case .pasted = firstResult else {
            Issue.record("First activated target should schedule an automatic paste")
            return
        }
        let secondResult = service.paste(
            second,
            imagesDirectory: FileManager.default.temporaryDirectory,
            targetApplication: target
        )
        guard case .pasted = secondResult else {
            Issue.record("Second activated target should schedule an automatic paste")
            return
        }
        #expect(scheduledActions.count == 2)

        scheduledActions[0]()
        #expect(postedPasteCount == 0)
        scheduledActions[1]()

        #expect(postedPasteCount == 1)
        #expect(pasteboard.string(forType: .string) == "second")
    }

    @Test func delayedPastePassesCapturedTargetPIDToPoster() throws {
        _ = NSApplication.shared
        let target = try #require(NSRunningApplication(processIdentifier: getpid()))
        var postedPIDs: [pid_t] = []
        let environment = PasteService.Environment(
            requestAccessibility: { true },
            activate: { _ in true },
            frontmostProcessIdentifier: { target.processIdentifier },
            schedulePaste: { action in action() },
            postCommandV: { postedPIDs.append($0) }
        )
        let pasteboard = NSPasteboard(name: .init("SSClip.targeted-paste.\(UUID().uuidString)"))
        let service = PasteService(pasteboard: pasteboard, environment: environment)
        let item = ClipboardItem(kind: .text, title: "value", text: "value", fingerprint: "value")

        let result = service.paste(
            item,
            imagesDirectory: FileManager.default.temporaryDirectory,
            targetApplication: target
        )

        guard case .pasted = result else {
            Issue.record("Activated target should post an automatic paste")
            return
        }
        #expect(postedPIDs == [target.processIdentifier])
    }

    @Test func oversizedRichDataIsDropped() {
        let oversized = Data(count: ClipboardMonitor.maximumRichDataBytes + 1)
        let allowed = Data(count: 128)
        #expect(ClipboardMonitor.sanitizedRichData(oversized) == nil)
        #expect(ClipboardMonitor.sanitizedRichData(allowed) == allowed)
        #expect(ClipboardMonitor.sanitizedRichData(nil) == nil)
    }

    @Test func fingerprintIgnoresRichDataSoRestyledTextDeduplicates() throws {
        let plain = CapturedClipboard(kind: .text, title: "hi", text: "hi", imageData: nil, filePaths: [])
        let styled = CapturedClipboard(
            kind: .text,
            title: "hi",
            text: "hi",
            rtfData: Data("rtf".utf8),
            htmlData: Data("<b>hi</b>".utf8),
            imageData: nil,
            filePaths: []
        )
        #expect(plain.fingerprint == styled.fingerprint)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSClipTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(baseDirectory: directory)
        store.add(plain)
        store.add(styled)

        #expect(store.items.count == 1)
        #expect(store.items.first?.rtfData != nil)
    }

    @Test func itemsPersistedBeforeRichTextSupportStillDecode() throws {
        let json = """
        {"version":1,"folders":[],"items":[{"id":"\(UUID().uuidString)","createdAt":"2026-07-01T00:00:00Z",\
        "kind":"text","title":"旧记录","text":"旧记录","filePaths":[],"fingerprint":"fp","byteCount":9,\
        "isFavorite":false}]}
        """
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSClipTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(json.utf8).write(to: directory.appendingPathComponent("history.json"))

        let store = ClipboardStore(baseDirectory: directory)
        #expect(store.items.count == 1)
        #expect(store.items.first?.rtfData == nil)
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
