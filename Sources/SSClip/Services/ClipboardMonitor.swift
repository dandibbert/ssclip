import AppKit
import Foundation
import UniformTypeIdentifiers

struct EncodedClipboardImage: Sendable {
    let data: Data
    let dimensions: String
}

@MainActor
final class ClipboardMonitor {
    var onCapture: ((CapturedClipboard) -> Void)?

    private let pasteboard: NSPasteboard
    private let settings: AppSettings
    private var timer: Timer?
    private var lastChangeCount: Int
    private var ignoredChangeCount: Int?
    private var encodeTask: Task<Void, Never>?
    private let changeCountProvider: () -> Int
    private let imageEncoder: @Sendable (Data) async -> EncodedClipboardImage?

    init(
        settings: AppSettings,
        pasteboard: NSPasteboard = .general,
        changeCountProvider: (() -> Int)? = nil,
        imageEncoder: @escaping @Sendable (Data) async -> EncodedClipboardImage? = { data in
            await ClipboardMonitor.encodePNG(from: data)
        }
    ) {
        self.settings = settings
        self.pasteboard = pasteboard
        let changeCountProvider = changeCountProvider ?? { pasteboard.changeCount }
        self.changeCountProvider = changeCountProvider
        self.imageEncoder = imageEncoder
        lastChangeCount = changeCountProvider()
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForChange() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        encodeTask?.cancel()
        encodeTask = nil
    }

    func suppressNextChange() {
        ignoredChangeCount = changeCountProvider() + 1
    }

    func checkForChange() {
        let currentChangeCount = changeCountProvider()
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount
        encodeTask?.cancel()
        encodeTask = nil
        if ignoredChangeCount == currentChangeCount {
            ignoredChangeCount = nil
            return
        }
        guard !Self.shouldIgnore(types: pasteboard.types ?? []) else { return }

        if let capture = readTextOrFilesCapture() {
            guard changeCountProvider() == currentChangeCount else { return }
            deliver(capture)
            return
        }

        // PNG encoding of large screenshots can take noticeable time; keep it off the main actor.
        guard let tiff = NSImage(pasteboard: pasteboard)?.tiffRepresentation else { return }
        let sourceChangeCount = currentChangeCount
        encodeTask = Task { [weak self] in
            guard let self,
                  let encoded = await imageEncoder(tiff),
                  !Task.isCancelled,
                  changeCountProvider() == sourceChangeCount
            else { return }
            self.deliver(CapturedClipboard(
                kind: .image,
                title: "图片 · \(encoded.dimensions)",
                text: nil,
                imageData: encoded.data,
                filePaths: []
            ))
        }
    }

    private func deliver(_ capture: CapturedClipboard) {
        onCapture?(capture)
        if settings.soundEnabled {
            NSSound(named: NSSound.Name(settings.soundName))?.play()
        }
    }

    private func readTextOrFilesCapture() -> CapturedClipboard? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            let title = paths.count == 1
                ? urls[0].lastPathComponent
                : "\(urls[0].lastPathComponent) 等 \(paths.count) 个文件"
            return CapturedClipboard(kind: .files, title: title, text: nil, imageData: nil, filePaths: paths)
        }

        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            let title = Self.compactTitle(from: string)
            return CapturedClipboard(
                kind: .text,
                title: title,
                text: string,
                rtfData: Self.sanitizedRichData(pasteboard.data(forType: .rtf)),
                htmlData: Self.sanitizedRichData(pasteboard.data(forType: .html)),
                imageData: nil,
                filePaths: []
            )
        }
        return nil
    }

    /// 超过 1 MB 的富文本数据只保留纯文本，避免历史文件被单条记录撑爆。
    static let maximumRichDataBytes = 1 << 20

    static func sanitizedRichData(_ data: Data?) -> Data? {
        guard let data, data.count <= maximumRichDataBytes else { return nil }
        return data
    }

    nonisolated static func encodePNG(from tiff: Data) async -> EncodedClipboardImage? {
        guard let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        return EncodedClipboardImage(
            data: png,
            dimensions: "\(bitmap.pixelsWide) × \(bitmap.pixelsHigh)"
        )
    }

    static func compactTitle(from text: String) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(160))
    }

    static func shouldIgnore(types: [NSPasteboard.PasteboardType]) -> Bool {
        let ignored = Set([
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        ])
        return !ignored.isDisjoint(with: types)
    }
}
