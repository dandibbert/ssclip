import AppKit
import Foundation

enum ClipboardItemKind: String, Codable, CaseIterable, Sendable {
    case text
    case image
    case files

    var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }

    var localizedName: String {
        switch self {
        case .text: "文本"
        case .image: "图片"
        case .files: "文件"
        }
    }
}

struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var createdAt: Date
    let kind: ClipboardItemKind
    let title: String
    let text: String?
    let rtfData: Data?
    let htmlData: Data?
    let imageFilename: String?
    let filePaths: [String]
    let fingerprint: String
    let byteCount: Int
    var isFavorite: Bool
    var folderID: UUID?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        kind: ClipboardItemKind,
        title: String,
        text: String? = nil,
        rtfData: Data? = nil,
        htmlData: Data? = nil,
        imageFilename: String? = nil,
        filePaths: [String] = [],
        fingerprint: String,
        byteCount: Int = 0,
        isFavorite: Bool = false,
        folderID: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.title = title
        self.text = text
        self.rtfData = rtfData
        self.htmlData = htmlData
        self.imageFilename = imageFilename
        self.filePaths = filePaths
        self.fingerprint = fingerprint
        self.byteCount = byteCount
        self.isFavorite = isFavorite
        self.folderID = folderID
    }

    var searchableText: String {
        ([title, text ?? ""] + filePaths).joined(separator: " ")
    }

    var detail: String {
        switch kind {
        case .text:
            let characterCount = text?.count ?? 0
            return "\(characterCount) 个字符"
        case .image:
            return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        case .files:
            return "\(filePaths.count) 个文件"
        }
    }

    static func safeImageURL(filename: String?, imagesDirectory: URL) -> URL? {
        guard let filename,
              !filename.contains("/"),
              !filename.contains("\\"),
              filename != ".",
              filename != "..",
              URL(fileURLWithPath: filename).pathExtension == "png"
        else { return nil }

        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        guard UUID(uuidString: stem) != nil else { return nil }

        let root = imagesDirectory.standardizedFileURL
        let candidate = root.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        guard candidate.deletingLastPathComponent() == root else { return nil }

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.deletingLastPathComponent().path == resolvedRoot.path else { return nil }

        let fileManager = FileManager.default
        if (try? fileManager.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
            return nil
        }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: candidate.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        } catch {
            let cocoaError = error as NSError
            guard cocoaError.domain == NSCocoaErrorDomain,
                  [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoaError.code)
            else { return nil }
        }
        return candidate
    }

    func previewURL(imagesDirectory: URL) -> URL? {
        switch kind {
        case .text:
            return nil
        case .image:
            return Self.safeImageURL(filename: imageFilename, imagesDirectory: imagesDirectory)
        case .files:
            guard let path = filePaths.first else { return nil }
            return URL(fileURLWithPath: path)
        }
    }
}

struct FavoriteFolder: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

enum ClipboardSection: Hashable, Sendable {
    case all
    case favorites
    case folder(UUID)
}
