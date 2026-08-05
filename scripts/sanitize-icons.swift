#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SanitizeError: Error {
    case usage
    case decode(String)
    case context(String)
    case destination(String)
}

func sanitize(_ url: URL) throws {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw SanitizeError.decode(url.path) }

    let width = sourceImage.width
    let height = sourceImage.height
    let bytesPerRow = width * 4
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 64)
    defer { buffer.deallocate() }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: buffer,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: bytesPerRow,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  | CGBitmapInfo.byteOrder32Big.rawValue
          )
    else { throw SanitizeError.context(url.path) }

    context.interpolationQuality = .high
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let rendered = context.makeImage() else { throw SanitizeError.context(url.path) }

    let temporary = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).sanitize-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let destination = CGImageDestinationCreateWithURL(
        temporary as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { throw SanitizeError.destination(url.path) }
    CGImageDestinationAddImage(destination, rendered, [:] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw SanitizeError.destination(url.path)
    }
    try Data(contentsOf: temporary).write(to: url, options: .atomic)
}

do {
    guard CommandLine.arguments.count > 1 else { throw SanitizeError.usage }
    for path in CommandLine.arguments.dropFirst() {
        try sanitize(URL(fileURLWithPath: path))
    }
} catch {
    FileHandle.standardError.write(Data("Icon sanitization failed: \(error)\n".utf8))
    exit(1)
}
