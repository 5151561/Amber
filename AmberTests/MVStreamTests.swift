import XCTest
@testable import Amber

/// MV 取流的三块纯逻辑：设置档 → 高度上限、阶梯挑档、两家响应的解析。
/// 真取流要网络（且 QQ 的地址带 24 小时 vkey），这里只喂 fixture。
/// fixture 逐字段照 2026-09-07 实测的响应裁剪而来，出处见两个 API 里的注释。
final class MVStreamTests: XCTestCase {

    // MARK: 设置档 → 画面高度上限

    func testStreamQualityMaxHeight() {
        XCTAssertEqual(VideoStreamQuality.good.maxHeight, 480)
        XCTAssertEqual(VideoStreamQuality.better.maxHeight, 1080, "「较佳」括号里写的就是 1080p")
        XCTAssertNil(VideoStreamQuality.best.maxHeight, "「最佳（最高4K）」= 有多高要多高")
    }

    func testDownloadQualityMaxHeight() {
        XCTAssertEqual(VideoDownloadQuality.hd.maxHeight, 1080)
        XCTAssertEqual(VideoDownloadQuality.sd.maxHeight, 480)
        XCTAssertEqual(VideoDownloadQuality.compatible.maxHeight, 720)
    }

    // MARK: 阶梯挑档

    private func variant(_ height: Int) -> MVVariant {
        MVVariant(height: height, url: URL(string: "https://example.com/\(height).mp4")!)
    }

    func testPickTakesHighestUnderCap() {
        let ladder = [variant(360), variant(1080), variant(480), variant(720)]
        XCTAssertEqual(MVVariant.pick(ladder, maxHeight: 1080)?.height, 1080)
        XCTAssertEqual(MVVariant.pick(ladder, maxHeight: 720)?.height, 720)
        XCTAssertEqual(MVVariant.pick(ladder, maxHeight: 500)?.height, 480, "不越级：500 不许拿 720")
    }

    func testPickWithoutCapTakesHighest() {
        XCTAssertEqual(MVVariant.pick([variant(360), variant(720)], maxHeight: nil)?.height, 720)
    }

    /// 整个阶梯都高于上限时给最低那一档：上限是「别浪费带宽」，不是「宁可放不了」。
    func testPickFallsBackToLowestWhenAllAboveCap() {
        XCTAssertEqual(MVVariant.pick([variant(720), variant(1080)], maxHeight: 240)?.height, 720)
    }

    func testPickOnEmptyLadder() {
        XCTAssertNil(MVVariant.pick([], maxHeight: nil))
    }

    // MARK: QQ `music.stream.MvUrlProxy/GetMvUrls`

    /// 匿名实测的形状：filetype 0 是 `code:2000`（没有这一档），10/20/30 有地址，
    /// 40 往上 `code:1000`（取不到）。只有 code == 0 的才算数。
    private func qqFixture() -> [String: Any] {
        func entry(_ filetype: Int, _ code: Int, url: String?) -> [String: Any] {
            var item: [String: Any] = ["filetype": filetype, "code": code, "fileSize": filetype * 1000,
                                       "url": [], "freeflow_url": [], "cn": "", "vkey": ""]
            if let url {
                item["url"] = ["https://mv6.music.tc.qq.com/", "https://mv.music.tc.qq.com/"]
                item["freeflow_url"] = [url]
                item["cn"] = "qmmv_0b6bsy.f98\(filetype / 10)4.mp4"
                item["vkey"] = "CAFE\(filetype)"
            }
            return item
        }
        return ["w0026q7f01a": [
            "duration": 317,
            "mp4": [
                entry(0, 2000, url: nil),
                entry(10, 0, url: "https://mv6.music.tc.qq.com/A/qmmv.f9814.mp4"),
                entry(20, 0, url: "https://mv6.music.tc.qq.com/B/qmmv.f9824.mp4"),
                entry(30, 0, url: "https://mv6.music.tc.qq.com/C/qmmv.f9834.mp4"),
                entry(40, 1000, url: nil),
            ],
            "hls": [entry(10, 2000, url: nil)],
        ]]
    }

    func testQQParsesOnlyUsableFileTypes() {
        let variants = QQAPI.parseMVVariants(qqFixture(), vid: "w0026q7f01a")
        XCTAssertEqual(variants.map(\.height), [360, 480, 720], "code≠0 的档没有地址，不进阶梯")
        XCTAssertEqual(variants.first?.url.absoluteString,
                       "https://mv6.music.tc.qq.com/A/qmmv.f9814.mp4")
        XCTAssertEqual(variants.last?.bytes, 30000)
    }

    /// vid 对不上（换了一支 MV 的响应）时不能张冠李戴。
    func testQQParseWithUnknownVID() {
        XCTAssertTrue(QQAPI.parseMVVariants(qqFixture(), vid: "别的vid").isEmpty)
    }

    /// 没有 `freeflow_url` 时按 CDN 前缀 + vkey + 文件名自己拼。
    func testQQComposesURLWithoutFreeflow() {
        let data: [String: Any] = ["v1": ["mp4": [[
            "filetype": 30, "code": 0, "fileSize": 42,
            "url": ["https://mv6.music.tc.qq.com/"],
            "freeflow_url": [],
            "vkey": "KEY", "cn": "qmmv.f9834.mp4",
        ]]]]
        XCTAssertEqual(QQAPI.parseMVVariants(data, vid: "v1").first?.url.absoluteString,
                       "https://mv6.music.tc.qq.com/KEY/qmmv.f9834.mp4?fname=qmmv.f9834.mp4")
    }

    /// 表里没有的 filetype 当「不认识」丢掉，不拿猜的高度去撞上限。
    func testQQFileTypeHeights() {
        XCTAssertEqual(QQAPI.mvHeight(forFileType: 10), 360)
        XCTAssertEqual(QQAPI.mvHeight(forFileType: 20), 480)
        XCTAssertEqual(QQAPI.mvHeight(forFileType: 30), 720)
        XCTAssertEqual(QQAPI.mvHeight(forFileType: 40), 1080)
        XCTAssertNil(QQAPI.mvHeight(forFileType: 0))
        XCTAssertNil(QQAPI.mvHeight(forFileType: 99))
    }

    /// 搜索结果里 MV 的 id 装的是 **vid**（取流接口只认它），不是数字 mv_id。
    func testQQParseMVUsesVID() {
        let mv = QQAPI.parseMV([
            "v_id": "w0026q7f01a", "mv_id": 293791, "mv_name": "晴天",
            "singer_name": "周杰伦", "duration": 317,
            "mv_pic_url": "http://puui.qpic.cn/x.jpg",
        ])
        XCTAssertEqual(mv?.id, "qq:w0026q7f01a")
        XCTAssertEqual(mv?.id.rawID, "w0026q7f01a")
        XCTAssertEqual(mv?.webURL.absoluteString, "https://y.qq.com/n/ryqq/mv/w0026q7f01a")
        // 列表接口那套字段（vid/title/singers）也落同一种 id
        let listed = QQAPI.parseMvListItem([
            "vid": "k0013x8ao6z", "mvid": 55200, "title": "七里香",
            "singers": [["name": "周杰伦"]], "duration": 303,
        ])
        XCTAssertEqual(listed?.id, "qq:k0013x8ao6z")
        XCTAssertEqual(listed?.artistName, "周杰伦")
    }

    // MARK: 网易云 `/api/song/enhance/play/mv/url`

    /// 服务端自己降级：问 1080 只有 480 时回的就是 480，`r` 才是真实档位。
    func testNeteaseParsesVariantAndUpgradesScheme() {
        let resp: [String: Any] = ["code": 200, "data": [
            "id": 376199, "r": 480, "size": 33536696,
            "url": "http://vodkgeyttp8.vod.126.net/cloudmusic/x.mp4?wsSecret=abc",
            "fee": 0, "code": 200,
        ]]
        let variant = NeteaseAPI.parseMVVariant(resp)
        XCTAssertEqual(variant?.height, 480)
        XCTAssertEqual(variant?.bytes, 33536696)
        XCTAssertEqual(variant?.url.scheme, "https", "vod.126.net 回的是 http，要升 https 否则 ATS 挡")
    }

    /// 取不到时 `url` 是空串或 "null"（不是缺字段），两种都要折成 nil。
    func testNeteaseParseRejectsEmptyURL() {
        XCTAssertNil(NeteaseAPI.parseMVVariant(["data": ["id": 1, "r": 0, "url": ""]]))
        XCTAssertNil(NeteaseAPI.parseMVVariant(["data": ["id": 1, "r": 0, "url": "null"]]))
        XCTAssertNil(NeteaseAPI.parseMVVariant(["code": 200]))
    }

    func testNeteaseParseMVKeepsNumericID() {
        let mv = NeteaseAPI.parseMV([
            "id": 14689667, "name": "早发白帝城", "artistName": "许嵩",
            "duration": 287000, "cover": "http://p1.music.126.net/x.jpg",
        ])
        XCTAssertEqual(mv?.id, "ne:14689667")
        XCTAssertEqual(mv?.id.rawID, "14689667", "取流接口认这个数字 id")
        XCTAssertEqual(mv?.duration, 287)
    }

    // MARK: 落盘命名

    @MainActor
    func testMVDownloadPath() {
        let mv = MV(id: "qq:w0026q7f01a", kind: .qq, title: "晴天", artistName: "周杰伦",
                    coverURL: nil, duration: 317,
                    webURL: URL(string: "https://y.qq.com/n/ryqq/mv/w0026q7f01a")!)
        XCTAssertEqual(DownloadStore.mvRelativePath(for: mv), "MV/晴天-q7f01a.mp4")
        // 标题里的斜杠不能变成目录层级
        let slashed = MV(id: "ne:1", kind: .netease, title: "A/B", artistName: "",
                         coverURL: nil, duration: 0, webURL: URL(string: "https://music.163.com")!)
        XCTAssertEqual(DownloadStore.mvRelativePath(for: slashed), "MV/A_B-ne_1.mp4")
        // 索引/状态的键带前缀，跟曲目 id 撞不上
        XCTAssertEqual(DownloadStore.mvKey("qq:w0026q7f01a"), "mv:qq:w0026q7f01a")
    }
}
