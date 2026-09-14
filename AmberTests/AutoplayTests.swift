import XCTest
@testable import Amber

/// 自动连播（队列面板顶部那颗 ∞）。
///
/// 两半各测各的，全程不触网、不起 App：
/// 1. 续队列的判据 / 去重 / 上限 / 关开关清场——`PlayerController` 上那四个纯函数
///    （`autoplayShouldRefill` / `autoplayAdditions` / `autoplayVictims`）与真队列上的一次验证；
/// 2. 两家音源的响应解析——对着 **curl 到的真实响应截下来的固定样本**。
///    样本是 2026-09-09 实测的原样字段，只做了「删掉用不上的键、少留几条」的裁剪。
/// 第 7、8 组要翻真实偏好里的「自动连播」开关，所以整个类挂 `@MainActor`
/// （`AppSettings.shared` 是主线程隔离的），与 `LibrarySyncSettingsTests` 同一种写法。
@MainActor
final class AutoplayTests: XCTestCase {

    /// 第 7、8 组要翻「自动连播」那个开关，而测试宿主就是 Amber 本身、
    /// `AppSettings.shared` 写的是**真实**偏好，所以整份存下来、跑完原样还回去。
    private var savedValues: SettingsValues!

    override func setUp() {
        super.setUp()
        savedValues = AppSettings.shared.values
    }

    override func tearDown() {
        AppSettings.shared.values = savedValues
        super.tearDown()
    }

    private func makeTrack(_ id: String) -> Track {
        Track(id: id, kind: .qq, title: "歌 \(id)", artistName: "艺人",
              artistId: nil, albumName: "", albumId: nil, artworkURL: nil, duration: 200)
    }

    // MARK: 1. 续队列的判据

    func testShouldRefillOnlyWhenTailRunsShort() {
        let threshold = PlayerController.autoplayRefillThreshold   // 3
        // 当前曲之后还剩 3 项（= 阈值）：够，不补。
        XCTAssertFalse(PlayerController.autoplayShouldRefill(
            queueCount: 10, currentIndex: 6, threshold: threshold))
        // 剩 2 项：不够，补。
        XCTAssertTrue(PlayerController.autoplayShouldRefill(
            queueCount: 10, currentIndex: 7, threshold: threshold))
        // 正在播最后一首：剩 0，补。
        XCTAssertTrue(PlayerController.autoplayShouldRefill(
            queueCount: 10, currentIndex: 9, threshold: threshold))
    }

    func testShouldNotRefillWithoutASeed() {
        let threshold = PlayerController.autoplayRefillThreshold
        // 还没起播：没有种子，自动连播无从谈起。
        XCTAssertFalse(PlayerController.autoplayShouldRefill(
            queueCount: 5, currentIndex: nil, threshold: threshold))
        // 队列空。
        XCTAssertFalse(PlayerController.autoplayShouldRefill(
            queueCount: 0, currentIndex: nil, threshold: threshold))
        // 下标越界（不该发生，但不能因此判成「要补」）。
        XCTAssertFalse(PlayerController.autoplayShouldRefill(
            queueCount: 3, currentIndex: 3, threshold: threshold))
        XCTAssertFalse(PlayerController.autoplayShouldRefill(
            queueCount: 3, currentIndex: -1, threshold: threshold))
    }

    // MARK: 2. 去重与上限

    func testAdditionsSkipAnythingAlreadyInTheQueue() {
        let existing = ["a", "b", "c"].map(makeTrack)
        let candidates = ["b", "d", "a", "e"].map(makeTrack)
        let out = PlayerController.autoplayAdditions(candidates: candidates,
                                                     existing: existing, limit: 10)
        XCTAssertEqual(out.map(\.id), ["d", "e"])
    }

    /// 「含历史」这一条单独钉住：`existing` 传的是整条 `queue`，
    /// 当前曲之前那一段（面板上的历史分区）同样算「已经在队列里」——
    /// 刚播过的又排回队尾是自动连播最容易犯的错。
    func testAdditionsSkipTracksAlreadyPlayed() {
        let queue = ["played1", "played2", "current", "next"].map(makeTrack)
        let candidates = ["played1", "fresh"].map(makeTrack)
        let out = PlayerController.autoplayAdditions(candidates: candidates,
                                                     existing: queue, limit: 10)
        XCTAssertEqual(out.map(\.id), ["fresh"])
    }

    func testAdditionsDedupeWithinTheCandidatesThemselves() {
        let candidates = ["x", "y", "x", "y", "z"].map(makeTrack)
        let out = PlayerController.autoplayAdditions(candidates: candidates,
                                                     existing: [], limit: 10)
        XCTAssertEqual(out.map(\.id), ["x", "y", "z"])
    }

    func testAdditionsRespectTheBatchCap() {
        let candidates = (0..<50).map { makeTrack("s\($0)") }
        let out = PlayerController.autoplayAdditions(
            candidates: candidates, existing: [], limit: PlayerController.autoplayBatchSize)
        XCTAssertEqual(out.count, PlayerController.autoplayBatchSize)
        XCTAssertEqual(out.first?.id, "s0")
        // 上限是 0 或负数时一条都不追加（防「limit 算歪了反而灌爆队列」）。
        XCTAssertTrue(PlayerController.autoplayAdditions(
            candidates: candidates, existing: [], limit: 0).isEmpty)
    }

    // MARK: 3. 关掉开关时清哪几项

    /// 只清**当前曲之后**的 `.autoplay` 项：当前曲之前的落在历史分区（面板上不在
    /// 自动播放那一段），正在播的那首更不能删。
    func testVictimsCoverOnlyAutoplayItemsAfterTheCurrentTrack() {
        let origins: [PlayerController.QueueOrigin] =
            [.autoplay, .source, .autoplay, .manual, .source, .autoplay, .autoplay]
        //   0 历史      1 历史    2 当前曲   3        4        5         6
        XCTAssertEqual(PlayerController.autoplayVictims(origins: origins, currentIndex: 2),
                       IndexSet([5, 6]))
        // 还没起播：整条队列都在「当前曲之后」。
        XCTAssertEqual(PlayerController.autoplayVictims(origins: origins, currentIndex: nil),
                       IndexSet([0, 2, 5, 6]))
        // 正在播最后一首：后面一项都没有。
        XCTAssertTrue(PlayerController.autoplayVictims(origins: origins, currentIndex: 6).isEmpty)
        XCTAssertTrue(PlayerController.autoplayVictims(origins: [], currentIndex: nil).isEmpty)
    }

    /// 真队列上走一遍 `clearAutoplayItems()`：`.autoplay` 项掉光，
    /// 手动加的与「继续播放」的一项不动，`queueOrigins` 与 `queue` 照旧等长。
    @MainActor
    func testClearAutoplayItemsKeepsEverythingElse() {
        let player = PlayerController()
        player.providerResolver = { _ in
            try await Task.sleep(for: .seconds(600))
            throw ProviderError.api("测试不取流")
        }
        player.play(["a", "b"].map(makeTrack))
        player.playLast(["m"].map(makeTrack))                       // .manual
        player.insertIntoQueue(["p", "q"].map(makeTrack), at: 3, origin: .autoplay)

        XCTAssertEqual(player.queue.map(\.id), ["a", "m", "b", "p", "q"])
        XCTAssertEqual(player.queueOrigins, [.source, .manual, .source, .autoplay, .autoplay])

        player.clearAutoplayItems()

        XCTAssertEqual(player.queue.map(\.id), ["a", "m", "b"])
        XCTAssertEqual(player.queueOrigins, [.source, .manual, .source])
        XCTAssertEqual(player.currentIndex, 0, "清场不该动正在播的那首")
        XCTAssertEqual(player.queueOrigins.count, player.queue.count)
    }

    // MARK: 4. QQ：GetSimilarSongs 的响应解析

    /// [实测 2026-09-09 curl] `music.recommend.TrackRelationServer/GetSimilarSongs`
    /// songid=107192078（告白气球）的真实响应，裁剪版：
    /// `vecSongNew` 那一组原样 15 首这里留 3 首，`vecSong` 原样 11 首这里留 2 首。
    /// 第 3 首是我特意把 `vecSong` 里的一条改成与 `vecSongNew` 同 mid，用来验去重
    /// ——真实响应里这两段的 mid 交集恰好为空，但解析器不能靠这个。
    private static let qqSimilarSongsSample = """
    {
      "retcode": 0,
      "msg": "",
      "songTagInfoList": [{"id": 5177680, "tag": "十大中文金曲获奖", "tagid": 132}],
      "vecSongNew": [{
        "title_template": "听「{String}」的也在听",
        "title_content": "周杰伦",
        "songs": [
          {"track": {"id": 5177680, "mid": "003xv4w313tZHV", "name": "红尘客栈",
                     "interval": 274, "index_album": 8, "index_cd": 0,
                     "singer": [{"id": 4558, "mid": "0025NhlN2yWrP4", "name": "周杰伦"}],
                     "album": {"id": 194021, "mid": "003Ow85E3pnoqi", "name": "十二新作"},
                     "file": {"media_mid": "000d5VXa1mFK4G", "size_flac": 28520892, "size_hires": 0}}},
          {"track": {"id": 447257, "mid": "001N8e5Q4Gjxda", "name": "Always Online",
                     "interval": 225, "index_album": 7, "index_cd": 0,
                     "singer": [{"id": 4286, "mid": "001BLpXF2DyJe2", "name": "林俊杰"}],
                     "album": {"id": 36160, "mid": "002g6zv02X7SNi", "name": "JJ陆"},
                     "file": {"media_mid": "001gRiqC0dCS2q", "size_flac": 25185263, "size_hires": 0}}},
          {"track": {"id": 7112749, "mid": "0001oIjs0YFIf7", "name": "坏女孩",
                     "interval": 246, "index_album": 10, "index_cd": 0,
                     "singer": [{"id": 22704, "mid": "004aRKga0CXIPm", "name": "徐良"},
                                {"id": 29263, "mid": "001EuCQF42PV9e", "name": "小凌"}],
                     "album": {"id": 91325, "mid": "002apRhZ4Bq99d", "name": "不良少年"},
                     "file": {"media_mid": "0003QzLv1kzY7F", "size_flac": 24457943, "size_hires": 0}}}
        ]
      }],
      "vecSong": [
        {"track": {"id": 107187351, "mid": "001fAL3S0Xlnu5", "name": "温暖你的冬",
                   "interval": 207, "index_album": 1, "index_cd": 0,
                   "singer": [{"id": 1038252, "mid": "0003R3WI40ZZYG", "name": "欧阳娜娜"}],
                   "album": {"id": 1458228, "mid": "000unN2w0erwT3", "name": "温暖你的冬"},
                   "file": {"media_mid": "003NCHhP2KCLKo", "size_flac": 45472986, "size_hires": 0}}},
        {"track": {"id": 5177680, "mid": "003xv4w313tZHV", "name": "红尘客栈",
                   "interval": 274, "index_album": 8, "index_cd": 0,
                   "singer": [{"id": 4558, "mid": "0025NhlN2yWrP4", "name": "周杰伦"}],
                   "album": {"id": 194021, "mid": "003Ow85E3pnoqi", "name": "十二新作"},
                   "file": {"media_mid": "000d5VXa1mFK4G", "size_flac": 28520892, "size_hires": 0}}}
      ]
    }
    """

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testQQParsesGroupedAndFlatSimilarSongs() throws {
        let tracks = QQAPI.parseSimilarSongs(try json(Self.qqSimilarSongsSample))
        // vecSongNew 的 3 首在前、vecSong 的新那 1 首在后，重复那条被去掉。
        XCTAssertEqual(tracks.map(\.id),
                       ["qq:003xv4w313tZHV", "qq:001N8e5Q4Gjxda",
                        "qq:0001oIjs0YFIf7", "qq:001fAL3S0Xlnu5"])
        let first = try XCTUnwrap(tracks.first)
        XCTAssertEqual(first.kind, .qq)
        XCTAssertEqual(first.title, "红尘客栈")
        XCTAssertEqual(first.artistName, "周杰伦")
        XCTAssertEqual(first.artistId, "qq:0025NhlN2yWrP4")
        XCTAssertEqual(first.albumName, "十二新作")
        XCTAssertEqual(first.albumId, "qq:003Ow85E3pnoqi")
        XCTAssertEqual(first.duration, 274)
        XCTAssertEqual(first.mediaMid, "000d5VXa1mFK4G")
        XCTAssertEqual(first.losslessAvailable, true, "file.size_flac > 0 就是有无损")
        // 多位歌手用「 / 」连，与别处的 parseTrack 同一口径。
        XCTAssertEqual(tracks[2].artistName, "徐良 / 小凌")
    }

    /// 服务端只发一段（或一段都不发）都不能崩，交不出来就是空数组。
    func testQQSimilarSongsToleratesMissingSections() throws {
        XCTAssertTrue(QQAPI.parseSimilarSongs(try json(#"{"retcode": 0}"#)).isEmpty)
        XCTAssertTrue(QQAPI.parseSimilarSongs(
            try json(#"{"vecSongNew": [], "vecSong": []}"#)).isEmpty)
        // 只有旧字段：照样解得出来（兜底那条路）。
        let flatOnly = #"""
        {"vecSong": [{"track": {"id": 1, "mid": "m1", "name": "只有旧字段", "interval": 100,
                                "singer": [{"mid": "s1", "name": "某人"}],
                                "album": {"mid": "a1", "name": "某碟"}}}]}
        """#
        let tracks = QQAPI.parseSimilarSongs(try json(flatOnly))
        XCTAssertEqual(tracks.map(\.id), ["qq:m1"])
        // 没有 file 节点＝档位未知，不能判成「没有无损」。
        XCTAssertNil(tracks[0].losslessAvailable)
    }

    // MARK: 5. 网易云：/api/v1/discovery/simiSong 的响应解析

    /// [实测 2026-09-09 curl] eapi `/api/v1/discovery/simiSong`
    /// `songid=1330348068` 匿名请求的真实响应，裁剪版（原样 5 条这里留 2 条，
    /// 每条只留 `parseTrack` 会读的键）。
    ///
    /// 要点：这条接口回的是**明文接口那套字段**（`artists` / `album` / `duration`），
    /// 不是 v3 详情的 `ar` / `al` / `dt`；而且不带 `sq` / `hr` 档位节点。
    private static let neteaseSimiSongSample = """
    {
      "code": 200,
      "songs": [
        {"id": 475479888, "name": "在你的身边", "duration": 262251, "no": 1,
         "artists": [{"id": 12395355, "name": "盛哲"}],
         "album": {"id": 34641110, "name": "在你的身边",
                   "picUrl": "https://p2.music.126.net/AYNBdRxJ8EdZo4xFjp7b4Q==/109951163191178425.jpg"}},
        {"id": 465921195, "name": "还是分开", "duration": 226791, "no": 2, "cd": "1",
         "artists": [{"id": 12281171, "name": "张叶蕾"}],
         "album": {"id": 34531581, "name": "还是分开", "picUrl": ""}}
      ]
    }
    """

    func testNeteaseParsesSimiSongResponse() throws {
        let data = try json(Self.neteaseSimiSongSample)
        let songs = try XCTUnwrap(data["songs"] as? [[String: Any]])
        let tracks = songs.compactMap { NeteaseAPI.parseTrack($0) }
        XCTAssertEqual(tracks.map(\.id), ["ne:475479888", "ne:465921195"])
        let first = try XCTUnwrap(tracks.first)
        XCTAssertEqual(first.kind, .netease)
        XCTAssertEqual(first.title, "在你的身边")
        XCTAssertEqual(first.artistName, "盛哲")
        XCTAssertEqual(first.artistId, "ne:12395355")
        XCTAssertEqual(first.albumName, "在你的身边")
        XCTAssertEqual(first.albumId, "ne:34641110")
        // duration 是毫秒，Track 上是秒。
        XCTAssertEqual(first.duration, 262.251, accuracy: 0.001)
        XCTAssertNotNil(first.artworkURL)
        // 没有 sq/hr 节点＝档位未知，与搜索结果同（不是「没有无损」）。
        XCTAssertNil(first.losslessAvailable)
        // cd 可能是字符串。
        XCTAssertEqual(tracks[1].discNumber, 1)
    }

    // MARK: 6. 能力位

    /// 两家都有相似歌曲接口，所以面板上那颗 ∞ 不该恒置灰。
    func testBothProvidersDeclareAutoplaySupport() {
        XCTAssertTrue(QQAPI().supportsAutoplay)
        XCTAssertTrue(NeteaseAPI().supportsAutoplay)
    }

    /// QQ 的自动连播候选就是相似歌曲那一批，没有别的召回。
    /// 这条钉住的是「别哪天顺手给 QQ 也掺点别的进去」。
    func testQQAutoplayUsesSimilarTracksOnly() async {
        // 空 mid 的曲目连 `songID(mid:)` 那一跳都进不去，直接空表返回，全程不触网。
        let track = Track(id: "qq:", kind: .qq, title: "空", artistName: "", artistId: nil,
                          albumName: "", albumId: nil, artworkURL: nil, duration: 0)
        let out = await QQAPI().similarTracks(track, limit: 10)
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: 7. 自动连播只有「相似歌曲」这一条路

    /// 网易云这边也是相似歌曲一条路走到黑：`simiSong` 交不出来就是空，
    /// **不会再去打私人 FM（`/api/v1/radio/get`）或心动模式
    /// （`/api/playmode/intelligence/list`）**——那两条各自是网易云里独立的一种播放模式，
    /// 与「与当前这首相似」无关，2026-09-09 接错过一次，已摘除。
    ///
    /// id 不是数字的曲目连 eapi 那一跳都进不去，直接空表返回，全程不触网。
    func testNeteaseAutoplayHasNoSecondRecall() async {
        let track = Track(id: "ne:", kind: .netease, title: "空", artistName: "", artistId: nil,
                          albumName: "", albumId: nil, artworkURL: nil, duration: 0)
        let out = await NeteaseAPI().similarTracks(track, limit: 10)
        XCTAssertTrue(out.isEmpty)
    }

    /// 相似歌曲**给不够**（要 10 首只给了 2 首）时不会再去别处补：音源只被问这一次，
    /// 队尾也只多出它给的那两首。这一条钉住的就是「别再往下接第二、第三条召回」——
    /// 一批少几首不是毛病：种子跟着当前曲往前走，下一首歌就会再问一批
    /// （见 `testAutoplaySeedFollowsTheCurrentTrack`）。
    @MainActor
    func testShortBatchIsNotToppedUpFromAnywhereElse() async {
        let player = PlayerController()
        player.providerResolver = { _ in
            try await Task.sleep(for: .seconds(600))
            throw ProviderError.api("测试不取流")
        }
        player.autoplaySupported = { _ in true }

        let log = SeedLog()
        let oneAsk = expectation(description: "问一次")
        let noSecondAsk = expectation(description: "不该有第二次")
        noSecondAsk.isInverted = true
        player.autoplayCandidatesProvider = { seed, limit in
            log.seeds.append(seed.id)
            log.limits.append(limit)
            if log.seeds.count == 1 { oneAsk.fulfill() } else { noSecondAsk.fulfill() }
            // 一批要 10 首，只给得出 2 首（网易云匿名的 simiSong 就是这个量级）。
            return ["s1", "s2"].map(self.makeTrack)
        }

        AppSettings.shared.values.playQueueAutoplay = true
        player.play(["a", "b"].map(makeTrack))

        await fulfillment(of: [oneAsk], timeout: 3)
        await fulfillment(of: [noSecondAsk], timeout: 0.4)
        XCTAssertEqual(log.limits, [PlayerController.autoplayBatchSize])
        XCTAssertEqual(player.queue.map(\.id), ["a", "b", "s1", "s2"],
                       "给几首就是几首，没有第二条路来把这一批填满")
    }


    // MARK: 8. 种子后移与「一首都没剩」时的重试

    /// 记一笔「音源被问了几次、每次拿谁当种子、要了几首」。
    private final class SeedLog {
        var seeds: [String] = []
        var limits: [Int] = []
    }

    /// 队列往前走，种子就跟着往前走。
    ///
    /// 这是「无限」的那条路：`autoplaySeedID` 只挡住同一个种子问第二次，
    /// 当前曲一换就是新种子、队尾又见底，于是自然再补一批。
    @MainActor
    func testAutoplaySeedFollowsTheCurrentTrack() async {
        let player = PlayerController()
        player.providerResolver = { _ in
            try await Task.sleep(for: .seconds(600))
            throw ProviderError.api("测试不取流")
        }
        player.autoplaySupported = { _ in true }

        let log = SeedLog()
        let twoRounds = expectation(description: "两个种子各补一批")
        twoRounds.expectedFulfillmentCount = 2
        player.autoplayCandidatesProvider = { seed, _ in
            log.seeds.append(seed.id)
            twoRounds.fulfill()
            return [self.makeTrack("fresh\(log.seeds.count)")]
        }

        AppSettings.shared.values.playQueueAutoplay = true
        player.play(["a", "b"].map(makeTrack),
                    source: .init(title: "某张歌单",
                                  route: .playlist(Playlist(id: "ne:1", kind: .netease, name: "某张歌单"))))
        // 第一批按当前曲 a 补，然后往下走一首，第二批就该按 b 补。
        // 第一批落定之前不能按下一首（否则种子还没被问过就换人了）。
        for _ in 0..<2000 where log.seeds.isEmpty { await Task.yield() }
        player.next()
        await fulfillment(of: [twoRounds], timeout: 3)

        XCTAssertEqual(log.seeds, ["a", "b"], "种子跟着当前曲往前走")
        XCTAssertEqual(player.queue.map(\.id), ["a", "b", "fresh1", "fresh2"])
        XCTAssertEqual(Array(player.queueOrigins.suffix(2)), [.autoplay, .autoplay])
    }

    /// 补回来的一批去重后一首都没剩：换**队尾**那首当种子再问一次，
    /// 还是空就这一轮放弃——**只重试一次**，不递归、不循环打网络。
    @MainActor
    func testEmptyBatchRetriesOnceWithTheTailSeed() async {
        let player = PlayerController()
        player.providerResolver = { _ in
            try await Task.sleep(for: .seconds(600))
            throw ProviderError.api("测试不取流")
        }
        player.autoplaySupported = { _ in true }

        let log = SeedLog()
        let twoAsks = expectation(description: "当前曲种子一次 + 队尾种子一次")
        twoAsks.expectedFulfillmentCount = 2
        let noThirdAsk = expectation(description: "不该有第三次")
        noThirdAsk.isInverted = true
        player.autoplayCandidatesProvider = { seed, _ in
            log.seeds.append(seed.id)
            if log.seeds.count <= 2 { twoAsks.fulfill() } else { noThirdAsk.fulfill() }
            // 回来的全是队列里已经有的：去重之后一首不剩。
            return ["a", "b"].map(self.makeTrack)
        }

        AppSettings.shared.values.playQueueAutoplay = true
        player.play(["a", "b"].map(makeTrack))

        await fulfillment(of: [twoAsks], timeout: 3)
        await fulfillment(of: [noThirdAsk], timeout: 0.4)
        XCTAssertEqual(log.seeds, ["a", "b"], "第二次拿队尾那首当种子")
        XCTAssertEqual(player.queue.map(\.id), ["a", "b"], "什么都没补进来")
    }

    /// 第一批就补到了东西：不该再拿队尾种子多问一次。
    @MainActor
    func testSuccessfulBatchDoesNotRetry() async {
        let player = PlayerController()
        player.providerResolver = { _ in
            try await Task.sleep(for: .seconds(600))
            throw ProviderError.api("测试不取流")
        }
        player.autoplaySupported = { _ in true }

        let log = SeedLog()
        let firstAsk = expectation(description: "问一次")
        let noSecondAsk = expectation(description: "不该有第二次")
        noSecondAsk.isInverted = true
        player.autoplayCandidatesProvider = { seed, _ in
            log.seeds.append(seed.id)
            if log.seeds.count == 1 { firstAsk.fulfill() } else { noSecondAsk.fulfill() }
            return [self.makeTrack("fresh")]
        }

        AppSettings.shared.values.playQueueAutoplay = true
        player.play(["a", "b"].map(makeTrack))

        await fulfillment(of: [firstAsk], timeout: 3)
        await fulfillment(of: [noSecondAsk], timeout: 0.4)
        XCTAssertEqual(player.queue.map(\.id), ["a", "b", "fresh"])
    }
}
