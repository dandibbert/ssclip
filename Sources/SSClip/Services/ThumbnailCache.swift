import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 图片文件的头部元数据（只解析 header，不解码像素）。
struct ImageMetadata: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let colorModel: String?
    let bitDepth: Int?
    let hasAlpha: Bool
    let typeIdentifier: String?

    var dimensionsText: String {
        "\(pixelWidth) × \(pixelHeight) px"
    }

    var formatDisplayName: String {
        guard let typeIdentifier, let type = UTType(typeIdentifier),
              let fileExtension = type.preferredFilenameExtension
        else { return "图片" }
        return fileExtension.uppercased()
    }

    var colorSummary: String {
        var parts: [String] = []
        if let colorModel { parts.append(colorModel) }
        if let bitDepth { parts.append("\(bitDepth) 位") }
        if hasAlpha { parts.append("含透明") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    static func read(from url: URL) -> ImageMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return ImageMetadata(
            pixelWidth: width,
            pixelHeight: height,
            colorModel: properties[kCGImagePropertyColorModel] as? String,
            bitDepth: properties[kCGImagePropertyDepth] as? Int,
            hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
            typeIdentifier: CGImageSourceGetType(source) as String?
        )
    }
}

/// 列表缩略图与预览大图的生成与缓存。
/// 图片文件一经写入不再修改（UUID 文件名），因此缓存无需失效处理。
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    init(countLimit: Int = 400) {
        cache.countLimit = countLimit
    }

    /// 同步查缓存，供视图首帧直接命中、避免翻页闪烁。
    func cached(for url: URL, maxPixelSize: CGFloat) -> NSImage? {
        cache.object(forKey: Self.key(url, maxPixelSize))
    }

    func thumbnail(for url: URL, maxPixelSize: CGFloat) async -> NSImage? {
        let key = Self.key(url, maxPixelSize)
        if let cached = cache.object(forKey: key) { return cached }
        // NSImage 显式非 Sendable；后台只负责创建、创建后不再共享，装箱转移是安全的。
        let transferred = await Task.detached(priority: .userInitiated) {
            TransferredImage(image: Self.makeThumbnail(url: url, maxPixelSize: maxPixelSize))
        }.value
        if let image = transferred.image { cache.setObject(image, forKey: key) }
        return transferred.image
    }

    /// 用 CGImageSource 直接生成降采样位图，不必解码整张原图。
    nonisolated static func makeThumbnail(url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        // 显式按像素定点尺寸；size: .zero 会跟随屏幕 backing scale，行为不稳定。
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated private static func key(_ url: URL, _ maxPixelSize: CGFloat) -> NSString {
        "\(url.path)#\(Int(maxPixelSize))" as NSString
    }
}

private struct TransferredImage: @unchecked Sendable {
    let image: NSImage?
}

/// 文件类记录的系统图标，按路径缓存。
@MainActor
enum FileIconProvider {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(forPath path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }
}
