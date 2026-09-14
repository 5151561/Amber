#!/usr/bin/swift

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct DiffOptions {
    let reference: String
    let candidate: String
    var output = "pixel-diff.png"
    var report: String?
    var threshold: UInt8 = 0

    static func parse(_ args: [String]) throws -> DiffOptions {
        guard args.count >= 3 else { throw DiffError("需要 reference.png 和 candidate.png") }
        var result = DiffOptions(reference: args[1], candidate: args[2])
        var index = 3
        while index < args.count {
            switch args[index] {
            case "--output", "-o":
                guard index + 1 < args.count else { throw DiffError("--output 缺少路径") }
                index += 1
                result.output = args[index]
            case "--report":
                guard index + 1 < args.count else { throw DiffError("--report 缺少路径") }
                index += 1
                result.report = args[index]
            case "--threshold":
                guard index + 1 < args.count, let value = UInt8(args[index + 1]) else {
                    throw DiffError("--threshold 必须是 0...255")
                }
                index += 1
                result.threshold = value
            case "--help", "-h":
                usage(); exit(0)
            default:
                throw DiffError("未知参数：\(args[index])")
            }
            index += 1
        }
        return result
    }
}

private struct DiffError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func usage() {
    print("""
    用法：swift Tools/pixel-diff.swift reference.png candidate.png [选项]
      --output, -o <png>   差异热图，默认 pixel-diff.png
      --report <json>      另存机器可读统计
      --threshold <0...255> 忽略每通道不超过该值的差异，默认 0
    两张图片必须具有完全相同的像素尺寸。
    """)
}

private struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]
}

private func loadBitmap(_ path: String) throws -> Bitmap {
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw DiffError("无法读取图片：\(url.path)")
    }
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw DiffError("无法创建位图上下文") }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return Bitmap(width: width, height: height, pixels: pixels)
}

private func writePNG(_ bitmap: Bitmap, to path: String) throws {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = Data(bitmap.pixels)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
            width: bitmap.width,
            height: bitmap.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bitmap.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
          ) else { throw DiffError("无法创建 PNG：\(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw DiffError("PNG 写入失败：\(url.path)") }
}

do {
    let options = try DiffOptions.parse(CommandLine.arguments)
    let reference = try loadBitmap(options.reference)
    let candidate = try loadBitmap(options.candidate)
    guard reference.width == candidate.width, reference.height == candidate.height else {
        throw DiffError("像素尺寸不同：reference=\(reference.width)×\(reference.height)，candidate=\(candidate.width)×\(candidate.height)")
    }

    let pixelCount = reference.width * reference.height
    var heatmap = Bitmap(
        width: reference.width,
        height: reference.height,
        pixels: [UInt8](repeating: 0, count: pixelCount * 4)
    )
    var changedPixels = 0
    var maxChannelDelta = 0
    var totalAbsoluteDelta: UInt64 = 0
    var totalSquaredDelta: Double = 0
    var minX = reference.width
    var minY = reference.height
    var maxX = -1
    var maxY = -1

    for pixel in 0..<pixelCount {
        let offset = pixel * 4
        var localMax = 0
        for channel in 0..<4 {
            let delta = abs(Int(reference.pixels[offset + channel]) - Int(candidate.pixels[offset + channel]))
            localMax = max(localMax, delta)
            maxChannelDelta = max(maxChannelDelta, delta)
            totalAbsoluteDelta += UInt64(delta)
            totalSquaredDelta += Double(delta * delta)
        }
        let isChanged = localMax > Int(options.threshold)
        if isChanged {
            changedPixels += 1
            let x = pixel % reference.width
            let y = pixel / reference.width
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        let intensity = isChanged ? UInt8(max(48, localMax)) : 0
        heatmap.pixels[offset] = intensity
        heatmap.pixels[offset + 1] = 0
        heatmap.pixels[offset + 2] = isChanged ? UInt8(Int(intensity) / 5) : 0
        heatmap.pixels[offset + 3] = isChanged ? 255 : 0
    }

    try writePNG(heatmap, to: options.output)
    let channelSampleCount = Double(pixelCount * 4)
    var report: [String: Any] = [
        "reference": URL(fileURLWithPath: options.reference).standardizedFileURL.path,
        "candidate": URL(fileURLWithPath: options.candidate).standardizedFileURL.path,
        "heatmap": URL(fileURLWithPath: options.output).standardizedFileURL.path,
        "width": reference.width,
        "height": reference.height,
        "threshold": Int(options.threshold),
        "changedPixels": changedPixels,
        "changedRatio": Double(changedPixels) / Double(pixelCount),
        "meanAbsoluteChannelError": Double(totalAbsoluteDelta) / channelSampleCount,
        "rootMeanSquareChannelError": sqrt(totalSquaredDelta / channelSampleCount),
        "maxChannelDelta": maxChannelDelta
    ]
    if changedPixels > 0 {
        report["differenceBounds"] = [
            "x": minX, "y": minY, "width": maxX - minX + 1, "height": maxY - minY + 1
        ]
    }
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    if let reportPath = options.report {
        let url = URL(fileURLWithPath: reportPath).standardizedFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    print(String(decoding: data, as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
    usage()
    exit(1)
}
