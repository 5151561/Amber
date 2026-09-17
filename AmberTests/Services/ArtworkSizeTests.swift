import AppKit
import XCTest
@testable import Amber

final class ArtworkSizeTests: XCTestCase {

    /// 阶梯是按 point 记的，URL 上要乘回像素倍率。
    ///
    /// 问的是 `ArtworkSize` 自己的兜底倍率而不是就地读一次 `NSScreen`：
    /// 兜底取的是**全部屏幕里最大的那个**（理由见 `ArtworkSize.defaultScale`），
    /// 混合 DPI 的机器上与 `NSScreen.main` 不是一个数。
    private var scale: Int { Int(ArtworkSize.defaultScale.rounded()) }

    func testNeteaseParamRewritten() {
        let url = ArtworkSize.url("https://p1.music.126.net/abc.jpg?param=300y300", points: 40)
        XCTAssertEqual(url, "https://p1.music.126.net/abc.jpg?param=\(40 * scale)y\(40 * scale)")
    }

    func testNeteaseParamAfterAnotherQueryKeepsSeparator() {
        let url = ArtworkSize.url("https://p1.music.126.net/abc.jpg?x=1&param=300y300", points: 40)
        XCTAssertEqual(url, "https://p1.music.126.net/abc.jpg?x=1&param=\(40 * scale)y\(40 * scale)")
    }

    /// QQ 的 CDN 只认 90/150/300/500/800/1200 这几档，别的尺寸直接 404，
    /// 所以要往上取到最近的一档。400pt @2x = 800px 正好落在档上。
    func testQQSizeRewritten() {
        let url = ArtworkSize.url("https://y.gtimg.cn/music/photo_new/T002R300x300M000abc.jpg", points: 400)
        let expected = 400 * scale <= 800 ? 800 : 1200
        XCTAssertEqual(url,
                       "https://y.gtimg.cn/music/photo_new/T002R\(expected)x\(expected)M000abc.jpg")
    }

    /// 整窗播放器那一档（800pt）@2x = 1600px，超过 CDN 最大的 1200，要夹住而不是原样发出去。
    func testQQSizeClampedToLargestSupported() {
        let url = ArtworkSize.url("https://y.gtimg.cn/music/photo_new/T002R300x300M000abc.jpg",
                                  points: ArtworkSize.fullPlayer)
        XCTAssertEqual(url, "https://y.gtimg.cn/music/photo_new/T002R1200x1200M000abc.jpg")
    }

    /// 小档要往上取，不能取到比要求还小的一档（40pt @2x = 80px → 90）。
    func testQQSizeRoundsUp() {
        let url = ArtworkSize.url("https://y.gtimg.cn/music/photo_new/T002R300x300M000abc.jpg", points: 40)
        let expected = [90, 150, 300, 500, 800, 1200].first { $0 >= 40 * scale }!
        XCTAssertEqual(url, "https://y.gtimg.cn/music/photo_new/T002R\(expected)x\(expected)M000abc.jpg")
    }

    /// 认不出规则的地址原样返回，不能拼出坏 URL。
    func testUnknownURLUntouched() {
        let raw = "https://example.com/cover.jpg"
        XCTAssertEqual(ArtworkSize.url(raw, points: 40), raw)
    }

    func testNilAndEmpty() {
        XCTAssertNil(ArtworkSize.url(nil, points: 40))
        XCTAssertNil(ArtworkSize.url("", points: 40))
    }

    /// 本地文件地址里没有档位段可改，档位写进 URL 片段交给 `ImageCache` 降采样。
    /// 片段不参与文件定位，所以路过别的消费方也读得到原文件。
    func testLocalFileCarriesPixelTier() {
        let raw = "file:///Users/x/Library/Application%20Support/Amber/Artwork/abc.jpg"
        XCTAssertEqual(ArtworkSize.url(raw, points: 40),
                       "\(raw)#\(ArtworkSize.localPixelMarker)\(40 * scale)")
        // 档位不同 → 串不同 → 缓存键不同，小档不会把大档的位图顶掉。
        XCTAssertNotEqual(ArtworkSize.url(raw, points: 40), ArtworkSize.url(raw, points: 400))
    }

    /// 地址自己已经带片段时不再追加一段，免得拼出两个 `#`。
    func testLocalFileWithExistingFragmentUntouched() {
        let raw = "file:///Users/x/cover.jpg#page=2"
        XCTAssertEqual(ArtworkSize.url(raw, points: 40), raw)
    }

    /// 倍率可以由调用点给：封面画在哪块屏上，只有那个调用点知道。
    func testExplicitScaleOverridesDefault() {
        let url = ArtworkSize.url("https://p1.music.126.net/abc.jpg?param=300y300",
                                  points: 40, scale: 1)
        XCTAssertEqual(url, "https://p1.music.126.net/abc.jpg?param=40y40")
    }

    /// 断点分档：<300 侧栏、<528 small、<672 medium、<760 large、否则 x-large。
    /// 出处 [实测] TSLLyricsControllerWrapper.breakpointForWidth:
    func testLyricsSizeClassBreakpoints() {
        XCTAssertEqual(MusicMetrics.Lyrics.sizeClass(forWidth: 211), .sidebar)
        XCTAssertEqual(MusicMetrics.Lyrics.sizeClass(forWidth: 300), .small)
        XCTAssertEqual(MusicMetrics.Lyrics.sizeClass(forWidth: 527), .small)
        XCTAssertEqual(MusicMetrics.Lyrics.sizeClass(forWidth: 528), .medium)
        XCTAssertEqual(MusicMetrics.Lyrics.sizeClass(forWidth: 672), .large)
        XCTAssertEqual(MusicMetrics.Lyrics.sizeClass(forWidth: 760), .xLarge)
    }

    /// 字号出处 [资源] TextStyles.plist 10200 / 10201–10204
    func testLyricsSizeLadder() {
        XCTAssertEqual(MusicMetrics.Lyrics.SizeClass.allCases.map(\.lineSize), [24, 28, 38, 50, 72])
        XCTAssertEqual(MusicMetrics.Lyrics.SizeClass.allCases.map(\.secondarySize), [13, 13, 17, 20, 24])
    }

    /// 电平条固有宽度 [实测] measurementsWithFitting:in: → levelWidth * 4 + 3
    func testNowPlayingLevelsIntrinsicWidth() {
        XCTAssertEqual(MusicMetrics.NowPlayingLevels.width(levelWidth: 2), 11)
        XCTAssertEqual(MusicMetrics.NowPlayingLevels.count, 4)
    }
}
