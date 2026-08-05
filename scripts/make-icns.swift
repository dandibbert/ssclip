#!/usr/bin/env swift

import Darwin
import Foundation

private struct IconRepresentation {
    let type: String
    let fileName: String
    let pixelSize: UInt32
}

private enum IconBuildError: Error, CustomStringConvertible {
    case usage
    case missingFile(String)
    case invalidPNG(String)
    case wrongSize(file: String, expected: UInt32, actualWidth: UInt32, actualHeight: UInt32)
    case outputTooLarge

    var description: String {
        switch self {
        case .usage:
            "Usage: swift scripts/make-icns.swift <AppIcon.iconset> <AppIcon.icns>"
        case let .missingFile(path):
            "Missing icon representation: \(path)"
        case let .invalidPNG(path):
            "Invalid PNG representation: \(path)"
        case let .wrongSize(file, expected, actualWidth, actualHeight):
            "Wrong icon size for \(file): expected \(expected)x\(expected), got \(actualWidth)x\(actualHeight)"
        case .outputTooLarge:
            "Generated ICNS exceeds the format size limit"
        }
    }
}

private let representations = [
    IconRepresentation(type: "icp4", fileName: "icon_16x16.png", pixelSize: 16),
    IconRepresentation(type: "ic11", fileName: "icon_16x16@2x.png", pixelSize: 32),
    IconRepresentation(type: "icp5", fileName: "icon_32x32.png", pixelSize: 32),
    IconRepresentation(type: "ic12", fileName: "icon_32x32@2x.png", pixelSize: 64),
    IconRepresentation(type: "ic07", fileName: "icon_128x128.png", pixelSize: 128),
    IconRepresentation(type: "ic13", fileName: "icon_128x128@2x.png", pixelSize: 256),
    IconRepresentation(type: "ic08", fileName: "icon_256x256.png", pixelSize: 256),
    IconRepresentation(type: "ic14", fileName: "icon_256x256@2x.png", pixelSize: 512),
    IconRepresentation(type: "ic09", fileName: "icon_512x512.png", pixelSize: 512),
    IconRepresentation(type: "ic10", fileName: "icon_512x512@2x.png", pixelSize: 1024)
]

private let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

private func uint32(from data: Data, at offset: Int) -> UInt32 {
    data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

private func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    Swift.withUnsafeBytes(of: &bigEndian) { bytes in
        data.append(contentsOf: bytes)
    }
}

private func buildIconset(from directory: URL, outputURL: URL) throws {
    var body = Data()

    for representation in representations {
        let sourceURL = directory.appendingPathComponent(representation.fileName)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw IconBuildError.missingFile(sourceURL.path)
        }

        let png = try Data(contentsOf: sourceURL)
        guard png.count >= 24, png.prefix(8) == pngSignature else {
            throw IconBuildError.invalidPNG(sourceURL.path)
        }

        let width = uint32(from: png, at: 16)
        let height = uint32(from: png, at: 20)
        guard width == representation.pixelSize, height == representation.pixelSize else {
            throw IconBuildError.wrongSize(
                file: representation.fileName,
                expected: representation.pixelSize,
                actualWidth: width,
                actualHeight: height
            )
        }

        body.append(contentsOf: representation.type.utf8)
        guard png.count <= Int(UInt32.max) - 8 else { throw IconBuildError.outputTooLarge }
        appendBigEndian(UInt32(png.count + 8), to: &body)
        body.append(png)
    }

    guard body.count <= Int(UInt32.max) - 8 else { throw IconBuildError.outputTooLarge }
    var output = Data("icns".utf8)
    appendBigEndian(UInt32(body.count + 8), to: &output)
    output.append(body)
    try output.write(to: outputURL, options: .atomic)
}

do {
    guard CommandLine.arguments.count == 3 else { throw IconBuildError.usage }
    try buildIconset(
        from: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true),
        outputURL: URL(fileURLWithPath: CommandLine.arguments[2])
    )
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
