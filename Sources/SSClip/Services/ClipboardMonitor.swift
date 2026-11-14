import AppKit
import Foundation
import UniformTypeIdentifiers

struct EncodedClipboardImage: Sendable {
    let data: Data
    let dimensions: String
}

struct ClipboardSourceApplication: Equatable, Sendable {
    let name: String?
    let bundleIdentifier: String?

    /// 复制发生时位于最前的应用；SSClip 自己不算来源。
    static func frontmost() -> ClipboardSourceApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return nil }
        return ClipboardSourceApplication(
            name: application.localizedName,
            bundleIdentifier: application.bundleIdentifier
        )
    }
}

extension NSPasteboard.PasteboardType {
    /// SSClip 写入剪贴板时附带的标记类型；监视器读到它就知道这次变化是自己造成的。
    static let ssclipOwnWrite = NSPasteboard.PasteboardType("local.rayscripts.ssclip.own-write")
}

@MainActor
final class ClipboardMonitor {
    var onCapture: ((CapturedClipboard) -> Void)?

    private let pasteboard: NSPasteboard
    private let settings: AppSettings
    private var timer: Timer?
    private var lastChangeCount: Int
    private var retryTask: Task<Void, Never>?
    private var encodeTask: Task<Void, Never>?
    private let changeCountProvider: () -> Int
    private let imageEncoder: @Sendable (Data) async -> EncodedClipboardImage?
    private let sourceApplicationProvider: () -> ClipboardSourceApplication?

    init(
        settings: AppSettings,
        pasteboard: NSPasteboard = .general,
        changeCountProvider: (() -> Int)? = nil,
        imageEncoder: @escaping @Sendable (Data) async -> EncodedClipboardImage? = { data in
            await ClipboardMonitor.encodePNG(from: data)
        },
        sourceApplicationProvider: @escaping () -> ClipboardSourceApplication? = {
            ClipboardSourceApplication.frontmost()
        }
    ) {
        self.settings = settings
        self.pasteboard = pasteboard
        let changeCountProvider = changeCountProvider ?? { pasteboard.changeCount }
        self.changeCountProvider = changeCountProvider
        self.imageEncoder = imageEncoder
        self.sourceApplicationProvider = sourceApplicationProvider
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
        retryTask?.cancel()
        retryTask = nil
        encodeTask?.cancel()
        encodeTask = nil
    }

    func checkForChange() {
        let currentChangeCount = changeCountProvider()
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount
        retryTask?.cancel()
        retryTask = nil
        encodeTask?.cancel()
        encodeTask = nil
        // 暂停期间的变化直接丢弃：恢复后不会补录暂停时复制的内容。
        guard !settings.capturePaused else { return }
        // 复制发生时位于最前的应用就是来源；重试期间用户可能已经切走，所以只在这里取一次。
        let source = sourceApplicationProvider()
        if let bundleID = source?.bundleIdentifier, settings.excludedBundleIDs.contains(bundleID) {
            return
        }
        attemptCapture(
            changeCount: currentChangeCount,
            source: source,
            retriesRemaining: Self.maximumReadRetries
        )
    }

    private func attemptCapture(
        changeCount: Int,
        source: ClipboardSourceApplication?,
        retriesRemaining: Int
    ) {
        guard changeCountProvider() == changeCount else { return }
        guard !Self.shouldIgnore(types: pasteboard.types ?? []) else { return }

        if let capture = readTextOrFilesCapture() {
            guard changeCountProvider() == changeCount else { return }
            retryTask = nil
            deliver(capture, source: source)
            return
        }

        // Browser clipboard APIs can increment changeCount before promised data is readable.
        // Retry the same generation briefly instead of permanently discarding that change.
        guard let imageData = readImageData() else {
            scheduleRetry(changeCount: changeCount, source: source, retriesRemaining: retriesRemaining)
            return
        }

        // Decoding and PNG encoding of large screenshots can take noticeable time; keep both off the main actor.
        encodeTask = Task { [weak self] in
            guard let self,
                  let encoded = await imageEncoder(imageData),
                  !Task.isCancelled,
                  changeCountProvider() == changeCount
            else { return }
            self.deliver(
                CapturedClipboard(
                    kind: .image,
                    title: "图片 · \(encoded.dimensions)",
                    text: nil,
                    imageData: encoded.data,
                    filePaths: []
                ),
                source: source
            )
        }
    }

    /// 优先直接取剪贴板上的 PNG / TIFF 原始数据，解码留给后台；
    /// 只有其他图片格式（如 PDF）才在主线程上经 NSImage 转成 TIFF。
    private func readImageData() -> Data? {
        if let png = pasteboard.data(forType: .png), !png.isEmpty { return png }
        if let tiff = pasteboard.data(forType: .tiff), !tiff.isEmpty { return tiff }
        return NSImage(pasteboard: pasteboard)?.tiffRepresentation
    }

    private func scheduleRetry(
        changeCount: Int,
        source: ClipboardSourceApplication?,
        retriesRemaining: Int
    ) {
        guard retriesRemaining > 0 else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.readRetryDelayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.attemptCapture(
                changeCount: changeCount,
                source: source,
                retriesRemaining: retriesRemaining - 1
            )
        }
    }

    private func deliver(_ capture: CapturedClipboard, source: ClipboardSourceApplication?) {
        var capture = capture
        capture.sourceAppName = source?.name
        capture.sourceBundleID = source?.bundleIdentifier
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

    /// Browser clipboard APIs can increment changeCount before promised data is readable.
    private static let maximumReadRetries = 8
    private static let readRetryDelayNanoseconds: UInt64 = 50_000_000

    /// 超过 1 MB 的富文本数据只保留纯文本，避免历史文件被单条记录撑爆。
    static let maximumRichDataBytes = 1 << 20

    static func sanitizedRichData(_ data: Data?) -> Data? {
        guard let data, data.count <= maximumRichDataBytes else { return nil }
        return data
    }

    nonisolated static func encodePNG(from imageData: Data) async -> EncodedClipboardImage? {
        guard let bitmap = NSBitmapImageRep(data: imageData),
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
            // SSClip 自己写回剪贴板的内容带这个标记，不重复记录。
            NSPasteboard.PasteboardType.ssclipOwnWrite,
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        ])
        return !ignored.isDisjoint(with: types)
    }
}
