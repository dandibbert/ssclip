import AppKit
import Foundation
import Testing
@testable import SSClip

@MainActor
struct ThumbnailTests {
    @Test func makeThumbnailDownsamplesToRequestedSize() throws {
        let url = try writeTestPNG(width: 400, height: 200)
        defer { try? FileManager.default.removeItem(at: url) }

        let thumbnail = try #require(ThumbnailCache.makeThumbnail(url: url, maxPixelSize: 48))

        // makeThumbnail 显式把点尺寸定为像素尺寸，size 即降采样后的真实大小。
        #expect(thumbnail.size.width <= 48)
        #expect(thumbnail.size.height <= 48)
        // 保持宽高比：400×200 → 48×24。
        #expect(thumbnail.size.width == 2 * thumbnail.size.height)
    }

    @Test func makeThumbnailForMissingFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).png")
        #expect(ThumbnailCache.makeThumbnail(url: url, maxPixelSize: 48) == nil)
    }

    @Test func cacheReturnsSameInstanceOnSecondRequest() async throws {
        let url = try writeTestPNG(width: 60, height: 60)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = ThumbnailCache(countLimit: 10)

        let first = await cache.thumbnail(for: url, maxPixelSize: 48)
        let second = await cache.thumbnail(for: url, maxPixelSize: 48)

        #expect(first != nil)
        #expect(first === second)
        #expect(cache.cached(for: url, maxPixelSize: 48) === first)
        // 不同尺寸是独立缓存项。
        #expect(cache.cached(for: url, maxPixelSize: 96) == nil)
    }

    @Test func imageMetadataReadsDimensionsAndFormat() throws {
        let url = try writeTestPNG(width: 320, height: 180)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try #require(ImageMetadata.read(from: url))

        #expect(metadata.pixelWidth == 320)
        #expect(metadata.pixelHeight == 180)
        #expect(metadata.dimensionsText == "320 × 180 px")
        #expect(metadata.formatDisplayName == "PNG")
        #expect(metadata.colorSummary != "—")
    }

    @Test func imageMetadataForNonImageFileReturnsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-image-\(UUID().uuidString).txt")
        try Data("plain text".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ImageMetadata.read(from: url) == nil)
    }

    private func writeTestPNG(width: Int, height: Int) throws -> URL {
        // 直接构造精确像素尺寸的位图；画图闭包在 Retina 屏会写出 2x 像素 + 144dpi 的文件，断言不稳定。
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = NSSize(width: width, height: height) // 72 dpi，像素与点一一对应
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-test-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }
}
