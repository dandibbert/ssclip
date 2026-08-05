import AppKit
import CryptoKit
import Foundation

struct CapturedClipboard: Sendable {
    let kind: ClipboardItemKind
    let title: String
    let text: String?
    let rtfData: Data?
    let htmlData: Data?
    let imageData: Data?
    let filePaths: [String]

    init(
        kind: ClipboardItemKind,
        title: String,
        text: String?,
        rtfData: Data? = nil,
        htmlData: Data? = nil,
        imageData: Data?,
        filePaths: [String]
    ) {
        self.kind = kind
        self.title = title
        self.text = text
        self.rtfData = rtfData
        self.htmlData = htmlData
        self.imageData = imageData
        self.filePaths = filePaths
    }

    // 指纹刻意不包含富文本数据：同一段文字无论带什么样式都视为同一条记录。
    var fingerprint: String {
        var data = Data(kind.rawValue.utf8)
        if let text { data.append(Data(text.utf8)) }
        if let imageData { data.append(imageData) }
        if !filePaths.isEmpty { data.append(Data(filePaths.joined(separator: "\u{1F}").utf8)) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ClipboardFileOperations {
    var writeImageAtomically: (Data, URL) throws -> Void
    var setImageOwnerOnlyPermissions: (URL) throws -> Void
    var removeImage: (URL) throws -> Void

    static let live = ClipboardFileOperations(
        writeImageAtomically: { data, url in
            try data.write(to: url, options: .atomic)
        },
        setImageOwnerOnlyPermissions: { url in
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        },
        removeImage: { url in
            try FileManager.default.removeItem(at: url)
        }
    )
}

@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var folders: [FavoriteFolder] = []
    @Published private(set) var storageErrorMessage: String?

    let imagesDirectory: URL
    private let historyURL: URL
    private let fileOperations: ClipboardFileOperations
    private var pendingSave: DispatchWorkItem?
    private var pendingImageDeletions: Set<String> = []
    private var outstandingImagePersistenceErrorMessage: String?
    private var historyIsWritable = true

    init(
        baseDirectory: URL? = nil,
        fileOperations: ClipboardFileOperations = .live
    ) {
        self.fileOperations = fileOperations
        let fileManager = FileManager.default
        let root = baseDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("SSClip", isDirectory: true)
        imagesDirectory = root.appendingPathComponent("Images", isDirectory: true)
        historyURL = root.appendingPathComponent("history.json")
        do {
            try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imagesDirectory.path)
        } catch {
            recordStorageError("无法访问本地存储；本次会话的历史可能不会保存。")
            return
        }
        load()
    }

    @discardableResult
    func add(_ capture: CapturedClipboard) -> ClipboardItem? {
        guard !capture.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let fingerprint = capture.fingerprint
        let duplicate = items.first(where: { $0.fingerprint == fingerprint })

        var imageFilename: String?
        if let imageData = capture.imageData {
            let filename = "\(UUID().uuidString).png"
            guard let imageURL = ClipboardItem.safeImageURL(
                filename: filename,
                imagesDirectory: imagesDirectory
            ) else {
                recordImagePersistenceError()
                return nil
            }
            do {
                try fileOperations.writeImageAtomically(imageData, imageURL)
            } catch {
                recordImagePersistenceError()
                return nil
            }
            do {
                try fileOperations.setImageOwnerOnlyPermissions(imageURL)
            } catch {
                do {
                    try fileOperations.removeImage(imageURL)
                } catch {
                    pendingImageDeletions.insert(filename)
                    scheduleSave()
                }
                recordImagePersistenceError()
                return nil
            }
            outstandingImagePersistenceErrorMessage = nil
            imageFilename = filename
        }

        let item = ClipboardItem(
            kind: capture.kind,
            title: capture.title,
            text: capture.text,
            rtfData: capture.rtfData,
            htmlData: capture.htmlData,
            imageFilename: imageFilename,
            filePaths: capture.filePaths,
            fingerprint: fingerprint,
            byteCount: capture.imageData?.count ?? capture.text?.utf8.count ?? 0,
            isFavorite: duplicate?.isFavorite ?? false,
            folderID: duplicate?.folderID
        )
        if let duplicate { removeFromList(duplicate, deleteImage: false) }
        items.insert(item, at: 0)
        if let duplicate { enqueueImagesForDeletion([duplicate]) }
        scheduleSave()
        return item
    }

    func toggleFavorite(_ item: ClipboardItem) {
        update(item) { value in
            value.isFavorite.toggle()
            if !value.isFavorite { value.folderID = nil }
        }
    }

    func move(_ item: ClipboardItem, to folder: FavoriteFolder?) {
        update(item) { value in
            value.isFavorite = true
            value.folderID = folder?.id
        }
    }

    @discardableResult
    func promote(_ item: ClipboardItem, at date: Date = Date()) -> ClipboardItem? {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        var promoted = items.remove(at: index)
        promoted.createdAt = date
        items.insert(promoted, at: 0)
        scheduleSave()
        return promoted
    }

    func remove(_ item: ClipboardItem) {
        removeFromList(item, deleteImage: true)
        scheduleSave()
    }

    func removeAllHistoryKeepingFavorites() {
        let removed = items.filter { !$0.isFavorite }
        items.removeAll { !$0.isFavorite }
        enqueueImagesForDeletion(removed)
        scheduleSave()
    }

    @discardableResult
    func addFolder(named rawName: String) -> FavoriteFolder? {
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty,
              !folders.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        let folder = FavoriteFolder(name: name)
        folders.append(folder)
        scheduleSave()
        return folder
    }

    func removeFolder(_ folder: FavoriteFolder) {
        folders.removeAll { $0.id == folder.id }
        items = items.map { item in
            guard item.folderID == folder.id else { return item }
            var updated = item
            updated.folderID = nil
            return updated
        }
        scheduleSave()
    }

    func applyRetention(cutoff: Date?, maximumItems: Int?) {
        var retained = items
        if let cutoff {
            retained = retained.filter { $0.isFavorite || $0.createdAt >= cutoff }
        }
        if let maximumItems, retained.count > maximumItems {
            let favorites = retained.filter(\.isFavorite)
            let regularSlots = max(0, maximumItems - favorites.count)
            let regular = retained.filter { !$0.isFavorite }.prefix(regularSlots)
            let allowedIDs = Set(favorites.map(\.id) + regular.map(\.id))
            retained = retained.filter { allowedIDs.contains($0.id) }
        }
        guard retained != items else { return }
        let retainedIDs = Set(retained.map(\.id))
        let removed = items.filter { !retainedIDs.contains($0.id) }
        items = retained
        enqueueImagesForDeletion(removed)
        scheduleSave()
    }

    func saveImmediately() throws {
        pendingSave?.cancel()
        do {
            guard historyIsWritable else { throw ClipboardStorageError.historyNotWritable }
            let state = PersistedState(version: 1, items: items, folders: folders)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: historyURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        } catch {
            recordStorageError("历史保存失败；本次会话仍可使用，稍后将自动重试。")
            throw error
        }
        do {
            try flushPendingImageDeletions()
        } catch {
            recordStorageError("部分图片文件无法删除；稍后将自动重试。")
            throw error
        }
        storageErrorMessage = outstandingImagePersistenceErrorMessage
    }

    private func update(_ item: ClipboardItem, transform: (inout ClipboardItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        transform(&items[index])
        scheduleSave()
    }

    private func removeFromList(_ item: ClipboardItem, deleteImage: Bool) {
        items.removeAll { $0.id == item.id }
        if deleteImage { enqueueImagesForDeletion([item]) }
    }

    private func enqueueImagesForDeletion(_ removedItems: [ClipboardItem]) {
        let filenamesStillUsed = Set(items.compactMap(\.imageFilename))
        for filename in removedItems.compactMap(\.imageFilename)
            where !filenamesStillUsed.contains(filename) {
            guard ClipboardItem.safeImageURL(
                filename: filename,
                imagesDirectory: imagesDirectory
            ) != nil else { continue }
            pendingImageDeletions.insert(filename)
        }
    }

    private func flushPendingImageDeletions() throws {
        var firstFailure: Error?
        for filename in Array(pendingImageDeletions) {
            guard let url = ClipboardItem.safeImageURL(
                filename: filename,
                imagesDirectory: imagesDirectory
            ) else {
                pendingImageDeletions.remove(filename)
                continue
            }
            do {
                try fileOperations.removeImage(url)
                pendingImageDeletions.remove(filename)
            } catch {
                let cocoaError = error as NSError
                if cocoaError.domain == NSCocoaErrorDomain,
                   cocoaError.code == NSFileNoSuchFileError {
                    pendingImageDeletions.remove(filename)
                } else {
                    firstFailure = firstFailure ?? error
                }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            do {
                try self?.saveImmediately()
            } catch {
                // saveImmediately publishes a generic, non-sensitive recovery message.
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func load() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: historyURL.path) else { return }
        do {
            let data = try Data(contentsOf: historyURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(PersistedState.self, from: data)
            items = state.items
            folders = state.folders
        } catch {
            let quarantineURL = historyURL.deletingLastPathComponent()
                .appendingPathComponent("history.corrupt-\(Self.utcTimestamp()).json")
            do {
                try fileManager.moveItem(at: historyURL, to: quarantineURL)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: quarantineURL.path
                )
                recordStorageError("历史文件已损坏，已保留副本并从空历史启动。")
            } catch {
                historyIsWritable = false
                recordStorageError("历史文件已损坏且无法隔离；原文件未被覆盖。")
            }
        }
    }

    private func recordStorageError(_ message: String) {
        storageErrorMessage = message
    }

    private func recordImagePersistenceError() {
        let message = "图片保存失败；该图片未加入历史。"
        outstandingImagePersistenceErrorMessage = message
        recordStorageError(message)
    }

    private static func utcTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.string(from: Date())
    }
}

private enum ClipboardStorageError: Error {
    case historyNotWritable
}

private struct PersistedState: Codable {
    let version: Int
    let items: [ClipboardItem]
    let folders: [FavoriteFolder]
}
