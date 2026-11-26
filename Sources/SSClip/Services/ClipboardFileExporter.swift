import AppKit
import Foundation

enum ExportedFileKind: Equatable, Sendable {
    case image
    case richText
    case markdown
    case plainText
    case existingFiles
}

struct ExportedClipboardFiles: Equatable, Sendable {
    let urls: [URL]
    let kind: ExportedFileKind
    let stagingDirectory: URL?
}

/// 将快捷列表中的剪贴板条目转换为可拖出的本地文件（图片直出、富文本 `.rtf`、Markdown `.md`、纯文本 `.txt` 或原文件列表）。
@MainActor
final class ClipboardFileExporter {
    let temporaryRootDirectory: URL
    private let htmlToRTF: @MainActor (Data) -> Data?
    private let fileManager: FileManager

    init(
        temporaryRootDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSClipDrag", isDirectory: true),
        fileManager: FileManager = .default,
        htmlToRTF: (@MainActor (Data) -> Data?)? = nil
    ) {
        self.temporaryRootDirectory = temporaryRootDirectory
        self.fileManager = fileManager
        self.htmlToRTF = htmlToRTF ?? { Self.convertHTMLToRTF($0) }
    }

    func export(_ item: ClipboardItem, imagesDirectory: URL) -> ExportedClipboardFiles? {
        cleanUpExpiredStagingDirectories()

        switch item.kind {
        case .image:
            return exportImage(item, imagesDirectory: imagesDirectory)
        case .files:
            let urls = item.filePaths.compactMap { path -> URL? in
                fileManager.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
            }
            guard !urls.isEmpty else { return nil }
            return ExportedClipboardFiles(urls: urls, kind: .existingFiles, stagingDirectory: nil)
        case .text:
            return exportText(item)
        }
    }

    func cleanUp(_ exported: ExportedClipboardFiles) {
        guard let stagingDirectory = exported.stagingDirectory else { return }
        try? fileManager.removeItem(at: stagingDirectory)
    }

    func cleanUpExpiredStagingDirectories(olderThan maxAge: TimeInterval = 600, now: Date = Date()) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: temporaryRootDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in contents {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let timestamp = values?.contentModificationDate ?? values?.creationDate
            if let timestamp, now.timeIntervalSince(timestamp) >= maxAge {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    private func exportImage(_ item: ClipboardItem, imagesDirectory: URL) -> ExportedClipboardFiles? {
        guard let sourceURL = ClipboardItem.safeImageURL(
            filename: item.imageFilename,
            imagesDirectory: imagesDirectory
        ), fileManager.fileExists(atPath: sourceURL.path)
        else { return nil }

        guard let stagingDirectory = makeStagingDirectory() else { return nil }
        let filename = Self.fileName(for: item, fileExtension: "png")
        let destinationURL = stagingDirectory.appendingPathComponent(filename, isDirectory: false)
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
            return ExportedClipboardFiles(
                urls: [destinationURL],
                kind: .image,
                stagingDirectory: stagingDirectory
            )
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            return nil
        }
    }

    private func exportText(_ item: ClipboardItem) -> ExportedClipboardFiles? {
        guard let text = item.text, !text.isEmpty else { return nil }

        let resolved: (kind: ExportedFileKind, fileExtension: String, data: Data)
        if let rtfData = item.rtfData, !rtfData.isEmpty {
            resolved = (.richText, "rtf", rtfData)
        } else if MarkdownDetector.isMarkdown(text) {
            resolved = (.markdown, "md", Data(text.utf8))
        } else if let htmlData = item.htmlData,
                  !htmlData.isEmpty,
                  let convertedRTF = htmlToRTF(htmlData),
                  !convertedRTF.isEmpty {
            resolved = (.richText, "rtf", convertedRTF)
        } else {
            resolved = (.plainText, "txt", Data(text.utf8))
        }

        guard let stagingDirectory = makeStagingDirectory() else { return nil }
        let filename = Self.fileName(for: item, fileExtension: resolved.fileExtension)
        let destinationURL = stagingDirectory.appendingPathComponent(filename, isDirectory: false)
        do {
            try resolved.data.write(to: destinationURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
            return ExportedClipboardFiles(
                urls: [destinationURL],
                kind: resolved.kind,
                stagingDirectory: stagingDirectory
            )
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            return nil
        }
    }

    private func makeStagingDirectory() -> URL? {
        let directory = temporaryRootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryRootDirectory.path)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return directory
        } catch {
            return nil
        }
    }

    static func fileName(for item: ClipboardItem, fileExtension: String) -> String {
        let rawTitle: String
        if !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawTitle = item.title
        } else if let firstLine = item.text?
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            rawTitle = firstLine
        } else {
            rawTitle = ""
        }

        var stem = rawTitle
        if fileExtension.lowercased() == "md" {
            stem = stripMarkdownTitlePrefix(stem)
        }

        stem = sanitizeFilenameComponent(stem)

        let suffix = ".\(fileExtension)"
        if stem.lowercased().hasSuffix(suffix.lowercased()), stem.count > suffix.count {
            stem = String(stem.dropLast(suffix.count))
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        }

        if stem.count > 48 {
            stem = String(stem.prefix(48))
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        }

        if stem.isEmpty {
            stem = item.kind == .image ? "剪贴板图片" : "剪贴板文本"
        }

        return "\(stem).\(fileExtension)"
    }

    private static func stripMarkdownTitlePrefix(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsTitle = trimmed as NSString
        let range = NSRange(location: 0, length: nsTitle.length)
        if let match = markdownTitlePrefixRegex.firstMatch(in: trimmed, range: range) {
            return nsTitle.substring(from: match.range.length)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func sanitizeFilenameComponent(_ raw: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)
        let replaced = raw.unicodeScalars.map { scalar -> String in
            if disallowed.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                return " "
            }
            return String(scalar)
        }.joined()

        let collapsed = replaced
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        return collapsed.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }

    static func convertHTMLToRTF(_ htmlData: Data) -> Data? {
        let sanitized = sanitizeHTMLForOfflineConversion(htmlData)
        guard let attributed = try? NSAttributedString(
            data: sanitized,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ),
        attributed.length > 0,
        let rtfData = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ),
        !rtfData.isEmpty
        else { return nil }
        return rtfData
    }

    /// 剥离外部脚本、iframe、样式链接和远程资源引用，确保 HTML 转 RTF 完全在本地离线完成。
    static func sanitizeHTMLForOfflineConversion(_ data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) else {
            return data
        }
        for regex in offlineHTMLSanitizeRegexes {
            let range = NSRange(location: 0, length: (html as NSString).length)
            html = regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
        }
        return Data(html.utf8)
    }

    private static let markdownTitlePrefixRegex = try! NSRegularExpression(
        pattern: "^(?:#{1,6}[ \\t]+|>[ \\t]+|(?:[-*+]|\\d+\\.)[ \\t]+(?:\\[[ xX]\\][ \\t]+)?)"
    )

    private static let offlineHTMLSanitizeRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: "<script\\b[^>]*>[\\s\\S]*?</script>", options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: "<iframe\\b[^>]*>[\\s\\S]*?</iframe>", options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: "\\bsrc\\s*=\\s*([\"'])https?://[^\"']*\\1", options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: "@import\\s+[^;]+;", options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: "url\\(\\s*[\"']?https?://[^)]*\\)", options: [.caseInsensitive])
    ]
}
