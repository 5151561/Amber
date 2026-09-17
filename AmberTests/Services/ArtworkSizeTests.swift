import AppKit
import XCTest
@testable import Amber

final class ArtworkSizeTests: XCTestCase {

    /// 阶梯是按 point 记的，URL 上要乘回像素倍率。
    private var scale: Int { Int((NSScreen.main?.backingScaleFactor ?? 2).rounded()) }

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
