import AppKit
import XCTest
@testable import Amber

/// 封面上屏这条路。两条回归：
/// 1. 图必须**当场**解码成位图再交出去——交一张「等着谁去画」的 `NSImage` 出去，
///    同一张图挂在几个尺寸的层上就要重新光栅化几次，几张一起画时会互相串成横带；
/// 2. 「没有封面」这一路每次都要真的把层清干净——卡片是复用的，
///    留着上一条目的图就是资料库艺人页那种「这张碟显示成别人的碟」。
final class ArtworkDisplayTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmberArtworkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 解码

    /// 交出去的必须是「已经是位图」的图：不用图形上下文就能拿到 CGImage，
    /// 尺寸按像素算（按 DPI 折算成 point 的话，NSCache 的 cost 与缩放都会跟着错）。
    func testDecodeReturnsReadyBitmap() throws {
        let data = try makeJPEG(size: 40, color: .systemPink)
        let image = try XCTUnwrap(ImageCache.decode(data))
        XCTAssertEqual(image.size, NSSize(width: 40, height: 40))
        let cgImage = try XCTUnwrap(image.amberCGImage)
        XCTAssertEqual(cgImage.width, 40)
        XCTAssertEqual(cgImage.height, 40)
        XCTAssertNil(ImageCache.decode(Data("不是图片".utf8)))
        XCTAssertNil(ImageCache.decode(Data()))
    }

    /// 本地封面按档解码：内嵌封面动辄 1500–3000px，40pt 的行只要 80px。
    ///
    /// 两条都要钉：给了档位就砍到档位（长边），**源图比档位还小时不放大**
    /// ——放大等于把 80px 的图插值成 4000px 再塞进缓存，比不降采样还糟。
    func testDecodeDownsamplesToRequestedPixelSize() throws {
        let data = try makeJPEG(size: 1200, color: .systemPink)
        let thumb = try XCTUnwrap(ImageCache.decode(data, maxPixelSize: 80))
        XCTAssertEqual(thumb.size, NSSize(width: 80, height: 80))
        XCTAssertEqual(try XCTUnwrap(thumb.amberCGImage).width, 80)

        let full = try XCTUnwrap(ImageCache.decode(data, maxPixelSize: 4000))
        XCTAssertEqual(full.size, NSSize(width: 1200, height: 1200))

        // 不给档位就是原尺寸，与改这条之前一致。
        XCTAssertEqual(try XCTUnwrap(ImageCache.decode(data)).size,
                       NSSize(width: 1200, height: 1200))
    }

    /// 几张图同时解码时互不影响（串图的原形是「解码推迟到画的时候」，
    /// 提前到这里之后每张图各有各的位图）。
    func testConcurrentDecodesStayIndependent() async throws {
        let pink = try makeJPEG(size: 32, color: .systemPink)
        let blue = try makeJPEG(size: 32, color: .systemBlue)
        let expected = [pixel(of: try XCTUnwrap(ImageCache.decode(pink))),
                        pixel(of: try XCTUnwrap(ImageCache.decode(blue)))]

        await withTaskGroup(of: (Int, [UInt8]?).self) { group in
            for index in 0..<16 {
                let data = index.isMultiple(of: 2) ? pink : blue
                group.addTask {
                    guard let image = ImageCache.decode(data) else { return (index, nil) }
                    return (index, Self.pixelBytes(of: image))
                }
            }
            for await (index, bytes) in group {
                XCTAssertEqual(bytes, expected[index % 2], "第 \(index) 张解出来的位图串了")
            }
        }
    }

    // MARK: - 「没有封面」这一路

    /// 复用的卡片配到「没有封面」的条目上时，层必须真被清空——连着配两次也一样
    /// （`nil == nil` 当成「没变」直接 return，正是本地专辑显示成别人封面的那个口子）。
    @MainActor
    func testNilURLAlwaysClearsTheLayer() async throws {
        let file = directory.appendingPathComponent("cover.jpg")
        try makeJPEG(size: 24, color: .systemGreen).write(to: file)

        let view = CatalogArtworkView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        let artwork = try XCTUnwrap(view.layer?.sublayers?.dropFirst().first,
                                    "第二层是封面层（第一层是渐变占位）")

        view.setArtwork(url: file.absoluteString, points: nil)
        try await waitUntil { artwork.contents != nil }
        XCTAssertFalse(artwork.isHidden)

        // 复用到一个没有封面的条目上
        view.setArtwork(url: nil, points: nil)
        XCTAssertNil(artwork.contents)
        XCTAssertTrue(artwork.isHidden)

        // 再复用到另一个没有封面的条目上：也不许把上一张留在层上
        view.setArtwork(url: nil, points: nil)
        XCTAssertNil(artwork.contents)
        XCTAssertTrue(artwork.isHidden)
    }

    // MARK: - 工具

    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() {
            if Date() > deadline { XCTFail("等超时了"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func pixel(of image: NSImage) -> [UInt8]? { Self.pixelBytes(of: image) }

    /// 左上角那个像素的字节，用来认「这是哪张图」。
    private static func pixelBytes(of image: NSImage) -> [UInt8]? {
        guard let cgImage = image.amberCGImage,
              let data = cgImage.dataProvider?.data as Data? else { return nil }
        return Array(data.prefix(3))
    }

    /// 现造一张边长精确的 JPEG。不走 `NSImage.lockFocus`：那条路在 Retina 上
    /// 会按 2 倍分辨率出图（40pt 的画布出来是 80×80 像素），验尺寸就没法验了。
    private func makeJPEG(size: Int, color: NSColor) throws -> Data {
        // 每像素 4 个分量（RGBA）：24 位打包的位图 CoreGraphics 建不出上下文来。
        guard let rep = unsafe NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size,
                                         pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = rep.representation(using: .jpeg, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return jpeg
    }
}
