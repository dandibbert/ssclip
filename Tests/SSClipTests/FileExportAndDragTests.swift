import AppKit
import Foundation
import Testing
@testable import SSClip

@MainActor
struct FileExportAndDragTests {
    // MARK: - MarkdownDetector

    @Test func detectsClearlyRecognizableMarkdownTexts() {
        let samples = [
            "## 快速开始\n运行 `swift test` 完成校验。",
            "# 项目说明\n\n- 零依赖\n- 原生界面",
            "查看 [GitHub 仓库](https://github.com/dandibbert/ssclip) 获取详情。",
            "![预览图](./preview.png)\n\n说明文字",
            "```swift\nlet value = 42\nprint(value)\n```",
            "- [x] 已完成\n- [ ] 待处理",
            "| 名称 | 说明 |\n| --- | --- |\n| SSClip | 剪贴板工具 |",
            "这里有 **关键内容** 和 `命令行` 示例。",
            "> **提示**：按 `⌘V` 粘贴。",
            "参考链接见 [文档][doc]。\n\n[doc]: https://example.com/docs"
        ]

        for sample in samples {
            #expect(MarkdownDetector.isMarkdown(sample), "Expected Markdown for: \(sample)")
        }
    }

    @Test func rejectsPlainTextScriptsLogsAndStructuredDataAsNonMarkdown() {
        let nonMarkdownSamples = [
            "Hello world",
            "这是一段普通的剪贴板纯文本。",
            "1. 第一步\n2. 第二步\n3. 第三步",
            "- 牛奶\n- 面包\n- 鸡蛋",
            "#!/bin/bash\n# 安装依赖\nbrew install jq",
            "# TODO: refine this function\nlet count = 1",
            "SELECT `id`, `name` FROM `users` WHERE `active` = 1;",
            "{\"title\": \"## Not Markdown\", \"body\": \"**bold**\"}",
            "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1,2 +1,2 @@\n-old\n+new",
            "def __init__(self, **kwargs):\n    self.value = __name__",
            "> On Monday Alice wrote:\n> See you tomorrow.",
            "https://github.com/dandibbert/ssclip",
            "   \n\t  "
        ]

        for sample in nonMarkdownSamples {
            #expect(!MarkdownDetector.isMarkdown(sample), "Did not expect Markdown for: \(sample)")
        }
    }

    // MARK: - ClipboardFileExporter

    @Test func exportsImageAsCopiedPNGAndPreservesOriginalStoreFile() throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let imagesDirectory = tempRoot.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let imageFilename = "\(UUID().uuidString).png"
        let originalURL = imagesDirectory.appendingPathComponent(imageFilename)
        try pngBytes.write(to: originalURL)

        let item = ClipboardItem(
            kind: .image,
            title: "图片 · 100 × 100",
            imageFilename: imageFilename,
            fingerprint: "img-fp",
            byteCount: pngBytes.count
        )
        let exporter = ClipboardFileExporter(temporaryRootDirectory: tempRoot.appendingPathComponent("Drag", isDirectory: true))

        let exported = try #require(exporter.export(item, imagesDirectory: imagesDirectory))
        #expect(exported.kind == .image)
        #expect(exported.urls.count == 1)
        let draggedURL = try #require(exported.urls.first)
        #expect(draggedURL != originalURL)
        #expect(draggedURL.pathExtension == "png")
        #expect(draggedURL.lastPathComponent == "图片 · 100 × 100.png")
        #expect(try Data(contentsOf: draggedURL) == pngBytes)
        #expect(FileManager.default.fileExists(atPath: originalURL.path))

        exporter.cleanUp(exported)
        #expect(!FileManager.default.fileExists(atPath: draggedURL.path))
    }

    @Test func imageTraversalFilenameIsRejectedOnExport() throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let imagesDirectory = tempRoot.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        let outsideFilename = "\(UUID().uuidString).png"
        try Data("secret".utf8).write(to: tempRoot.appendingPathComponent(outsideFilename))

        let item = ClipboardItem(
            kind: .image,
            title: "outside",
            imageFilename: "../\(outsideFilename)",
            fingerprint: "outside"
        )
        let exporter = ClipboardFileExporter(temporaryRootDirectory: tempRoot.appendingPathComponent("Drag", isDirectory: true))
        #expect(exporter.export(item, imagesDirectory: imagesDirectory) == nil)
    }

    @Test func exportsRichTextWithRTFDataAsRTFFile() throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let rtfBytes = Data(#"{\rtf1\ansi Hello}"#.utf8)
        let item = ClipboardItem(
            kind: .text,
            title: "## Heading",
            text: "## Heading\n\n- item",
            rtfData: rtfBytes,
            fingerprint: "rtf-fp"
        )
        let exporter = ClipboardFileExporter(temporaryRootDirectory: tempRoot.appendingPathComponent("Drag", isDirectory: true))

        let exported = try #require(exporter.export(item, imagesDirectory: tempRoot))
        #expect(exported.kind == .richText)
        let url = try #require(exported.urls.first)
        #expect(url.pathExtension == "rtf")
        #expect(try Data(contentsOf: url) == rtfBytes)
    }

    @Test func exportsHTMLOnlyRichTextAsRTFAndKeepsMarkdownFromCodeEditorAsMarkdown() throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let stubRTF = Data(#"{\rtf1\ansi converted}"#.utf8)
        let exporter = ClipboardFileExporter(
            temporaryRootDirectory: tempRoot.appendingPathComponent("Drag", isDirectory: true),
            htmlToRTF: { _ in stubRTF }
        )

        let htmlRichItem = ClipboardItem(
            kind: .text,
            title: "加粗文章段落",
            text: "加粗文章段落",
            rtfData: nil,
            htmlData: Data("<b>加粗文章段落</b>".utf8),
            fingerprint: "html-rich"
        )
        let exportedRich = try #require(exporter.export(htmlRichItem, imagesDirectory: tempRoot))
        #expect(exportedRich.kind == .richText)
        #expect(exportedRich.urls.first?.pathExtension == "rtf")
        #expect(try Data(contentsOf: try #require(exportedRich.urls.first)) == stubRTF)

        let editorMarkdownItem = ClipboardItem(
            kind: .text,
            title: "## 安装指南",
            text: "## 安装指南\n\n- 运行 `swift build`",
            rtfData: nil,
            htmlData: Data("<div><span>## 安装指南</span></div>".utf8),
            fingerprint: "editor-md"
        )
        let exportedMD = try #require(exporter.export(editorMarkdownItem, imagesDirectory: tempRoot))
        #expect(exportedMD.kind == .markdown)
        #expect(exportedMD.urls.first?.pathExtension == "md")
        #expect(exportedMD.urls.first?.lastPathComponent == "安装指南.md")
    }

    @Test func exportsMarkdownAndPlainTextWithExpectedExtensionsAndContent() throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let exporter = ClipboardFileExporter(temporaryRootDirectory: tempRoot.appendingPathComponent("Drag", isDirectory: true))

        let markdownText = "# 更新日志\n\n- 新增拖出文件支持\n- 修复若干问题"
        let markdownItem = ClipboardItem(
            kind: .text,
            title: "# 更新日志",
            text: markdownText,
            fingerprint: "md-fp"
        )
        let exportedMD = try #require(exporter.export(markdownItem, imagesDirectory: tempRoot))
        #expect(exportedMD.kind == .markdown)
        let mdURL = try #require(exportedMD.urls.first)
        #expect(mdURL.pathExtension == "md")
        #expect(mdURL.lastPathComponent == "更新日志.md")
        #expect(try String(contentsOf: mdURL, encoding: .utf8) == markdownText)

        let plainText = "这是一段普通的记录内容"
        let plainItem = ClipboardItem(
            kind: .text,
            title: "这是一段普通的记录内容",
            text: plainText,
            fingerprint: "txt-fp"
        )
        let exportedTXT = try #require(exporter.export(plainItem, imagesDirectory: tempRoot))
        #expect(exportedTXT.kind == .plainText)
        let txtURL = try #require(exportedTXT.urls.first)
        #expect(txtURL.pathExtension == "txt")
        #expect(txtURL.lastPathComponent == "这是一段普通的记录内容.txt")
        #expect(try String(contentsOf: txtURL, encoding: .utf8) == plainText)
    }

    @Test func exportsExistingFilesDirectlyAndSkipsMissingOnes() throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let existingURL = tempRoot.appendingPathComponent("report.pdf")
        let missingURL = tempRoot.appendingPathComponent("deleted.pdf")
        try Data("pdf".utf8).write(to: existingURL)

        let exporter = ClipboardFileExporter(temporaryRootDirectory: tempRoot.appendingPathComponent("Drag", isDirectory: true))

        let partialItem = ClipboardItem(
            kind: .files,
            title: "report.pdf 等 2 个文件",
            filePaths: [existingURL.path, missingURL.path],
            fingerprint: "files-fp"
        )
        let exported = try #require(exporter.export(partialItem, imagesDirectory: tempRoot))
        #expect(exported.kind == .existingFiles)
        #expect(exported.stagingDirectory == nil)
        #expect(exported.urls == [existingURL])

        let allMissingItem = ClipboardItem(
            kind: .files,
            title: "deleted.pdf",
            filePaths: [missingURL.path],
            fingerprint: "missing-files"
        )
        #expect(exporter.export(allMissingItem, imagesDirectory: tempRoot) == nil)
    }

    @Test func filenameSanitizationHandlesInvalidCharactersDotsAndDuplicateExtensions() {
        let dirtyItem = ClipboardItem(
            kind: .text,
            title: "../a/b:c\\notes.md",
            text: "## title\n\n- item",
            fingerprint: "dirty"
        )
        let mdName = ClipboardFileExporter.fileName(for: dirtyItem, fileExtension: "md")
        #expect(!mdName.contains("/"))
        #expect(!mdName.contains(":"))
        #expect(!mdName.hasPrefix("."))
        #expect(!mdName.hasSuffix(".md.md"))
        #expect(mdName.hasSuffix(".md"))

        let emptyTitleItem = ClipboardItem(kind: .text, title: "...", text: "plain", fingerprint: "empty")
        #expect(ClipboardFileExporter.fileName(for: emptyTitleItem, fileExtension: "txt") == "剪贴板文本.txt")
    }

    @Test func offlineHTMLSanitizerStripsRemoteScriptsLinksAndImages() {
        let html = """
        <html><head><link rel="stylesheet" href="https://evil.example/a.css"><script>alert(1)</script></head>\
        <body><b>Hello</b><img src="https://tracker.example/p.png"><div style="background:url(https://evil.example/bg.png)">!</div></body></html>
        """
        let sanitizedData = ClipboardFileExporter.sanitizeHTMLForOfflineConversion(Data(html.utf8))
        let sanitized = String(data: sanitizedData, encoding: .utf8) ?? ""

        #expect(sanitized.contains("<b>Hello</b>"))
        #expect(!sanitized.contains("<script"))
        #expect(!sanitized.contains("<link"))
        #expect(!sanitized.contains("https://tracker.example"))
        #expect(!sanitized.contains("https://evil.example"))
    }

    @Test func expiredStagingDirectoriesAreCleanedUpWithoutRemovingFreshOnes() throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let dragRoot = tempRoot.appendingPathComponent("Drag", isDirectory: true)
        let expiredDir = dragRoot.appendingPathComponent("expired", isDirectory: true)
        let freshDir = dragRoot.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: expiredDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: freshDir, withIntermediateDirectories: true)

        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-900)],
            ofItemAtPath: expiredDir.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-30)],
            ofItemAtPath: freshDir.path
        )

        let exporter = ClipboardFileExporter(temporaryRootDirectory: dragRoot)
        exporter.cleanUpExpiredStagingDirectories(olderThan: 600, now: now)

        #expect(!FileManager.default.fileExists(atPath: expiredDir.path))
        #expect(FileManager.default.fileExists(atPath: freshDir.path))
    }

    @Test func draggingItemsProvideFileURLsForAllExportedFiles() throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let fileURL = tempRoot.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: fileURL)

        let item = ClipboardItem(kind: .text, title: "note", text: "hello", fingerprint: "fp")
        let exported = ExportedClipboardFiles(urls: [fileURL], kind: .plainText, stagingDirectory: nil)

        let draggingItems = ClipboardPanelDragCoordinator.makeDraggingItems(
            for: exported,
            item: item,
            cursorPoint: NSPoint(x: 40, y: 18),
            imagesDirectory: tempRoot
        )

        #expect(draggingItems.count == 1)
        let writer = try #require(draggingItems.first?.item as? NSURL)
        #expect((writer as URL) == fileURL)
        #expect(draggingItems.first?.draggingFrame.size == NSSize(width: 48, height: 48))
    }

    @Test func convertHTMLToRTFProducesValidRTFData() throws {
        let rtfData = try #require(
            ClipboardFileExporter.convertHTMLToRTF(Data("<b>加粗</b> <i>斜体</i>".utf8))
        )
        let rtfPrefix = String(decoding: rtfData.prefix(6), as: UTF8.self)
        #expect(rtfPrefix.hasPrefix("{\\rtf"))
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSClipDragTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
