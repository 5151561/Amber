import Foundation

/// 推荐与两种独立播放模式的接口。
///
/// ⚠️ **私人 FM（`personalFMTracks`）与心动模式（`intelligenceTracks`）不是
/// 自动连播的候选源。** 见 `design-ref/todo.md` §4 与 `MusicProvider.similarTracks`
/// 的注释：2026-09-09 把这两条串进过自动连播的分层召回，接错了，已摘除。
/// 队列面板自动播放分区头上写的是「将播放类似歌曲」，而这两条在网易云各自是
/// **独立的一种播放模式**——FM 是服务端按用户口味发歌、与种子无关；心动模式必须带
/// `playlistId`，语义是「在某张歌单里按心动顺序往下播」。这一轮只把接口做出来，
/// 一行都不许接进 `similarTracks` / `refillAutoplayIfNeeded`。
///
/// 通道：**个性化的那几条走 eapi**（推荐要认人，明文 GET 那条路压根不带凭证，
/// 登录了也只会拿到大盘热门）；纯目录性质的（`personalized/mv`、`privatecontent`）
/// 走明文 GET，与 `catalogItems` 里那批同一口径。
extension NeteaseAPI {

    // MARK: - 每日推荐

    /// 每日推荐歌曲。`/api/v3/discovery/recommend/songs`，参数 `afresh`（换一批），走 eapi。
    /// [api-enhanced] `module/recommend_songs.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl + eapi 探针] 匿名两条路都回 `code:200`，
    /// `data.dailySongs` 是一整批歌（明文那次头一首是「删了吧」，eapi 那次是「你的背包」）
    /// ——**匿名时它也给，只是给的是大盘热门而不是「你的口味」**，所以不能拿
    /// 「有没有回数据」当登录判据。字段是 v3 那套缩写（`ar` / `al` / `dt`），
    /// `parseTrack` 直接认。
    ///
    /// 另有 `data.recommendReasons`（每首歌的推荐语，形如「根据你喜欢的 xxx 推荐」），
    /// 这轮没有地方摆，先不解——真要用时它是与 `dailySongs` 平级的一张 id → 文案表。
    func dailyRecommendedTracks(refresh: Bool = false) async -> [Track] {
        var body: [(String, NeteaseJSON)] = []
        if refresh { body.append(("afresh", .string("true"))) }
        guard let resp = try? await eapi("/api/v3/discovery/recommend/songs", body),
              let songs = (resp["data"] as? [String: Any])?["dailySongs"] as? [[String: Any]]
        else { return [] }
        return songs.compactMap { Self.parseTrack($0) }
    }

    /// 每日推荐歌单。`/api/v1/discovery/recommend/resource`，**无参数**，走 eapi。
    /// [api-enhanced] `module/recommend_resource.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl + eapi 探针] 匿名两条路都回 `{"msg":null,"code":301}`
    /// ——**必须登录**，跟上面那条日推歌曲不一样（那条匿名也给）。
    /// **200 的响应形状未实机验证过**：按参考实现，歌单装在顶层 `recommend` 里；
    /// 这里顺手也认一下 `data.recommend`，免得服务端哪天挪了一层就整段空掉。
    ///
    /// 读接口取不到就返回空（`similarArtists` 的口径），不抛——首页少一段而已。
    func dailyRecommendedPlaylists() async -> [Playlist] {
        guard let resp = try? await eapi("/api/v1/discovery/recommend/resource") else { return [] }
        let list = (resp["recommend"] as? [[String: Any]])
            ?? ((resp["data"] as? [String: Any])?["recommend"] as? [[String: Any]])
            ?? []
        return list.compactMap { Self.parsePlaylist($0) }
    }

    /// 日推里的「不感兴趣」。`/api/v2/discovery/recommend/dislike`，
    /// 参数 `resId`（日推歌曲 id）/ `resType=4` / `sceneType=1`，走 eapi。
    /// [api-enhanced] `module/recommend_songs_dislike.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"msg":null,"code":301}`；
    /// 200 的形状未实机验证过（参考实现说会回一首替补歌，装在 `data`）。
    ///
    /// 这是**写**操作（改的是账号的推荐口味），所以 throws、且未登录直接抛。
    /// 返回值是服务端补上来的那首替补歌，没有就是 nil。
    @discardableResult
    func dislikeRecommendedTrack(_ trackID: String) async throws -> Track? {
        guard isLoggedIn else {
            throw ProviderError.unavailable("请先登录网易云音乐账号，才能对每日推荐说不感兴趣")
        }
        let resp = try await eapi("/api/v2/discovery/recommend/dislike", [
            ("resId", .string(trackID.rawID)), ("resType", 4), ("sceneType", 1),
        ])
        guard let data = resp["data"] as? [String: Any] else { return nil }
        return Self.parseTrack(data)
    }

    /// 历史日推有哪几天。`/api/discovery/recommend/songs/history/recent`，**无参数**，走 eapi。
    /// [api-enhanced] `module/history_recommend_songs.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl + eapi 探针] 匿名回 `code:200`，但
    /// `data = {"dates":[], "songs":null, "noHistoryMessage":"黑胶VIP可查看近期5次历史记录，明天再来就会有哦", …}`
    /// ——**这是黑胶会员功能**：不是会员时 `dates` 就是空表，与「没登录」长得一模一样，
    /// 所以界面上别把空表说成「出错了」。日期是 `yyyy-MM-dd` 的字符串，
    /// 原样交出去给下面那条当参数用。
    func recommendedSongHistoryDates() async -> [String] {
        guard let resp = try? await eapi("/api/discovery/recommend/songs/history/recent"),
              let dates = (resp["data"] as? [String: Any])?["dates"] as? [String] else { return [] }
        return dates
    }

    /// 某一天的历史日推。`/api/discovery/recommend/songs/history/detail`，
    /// 参数 `date`（`yyyy-MM-dd`，取自上面那条），走 eapi。
    /// [api-enhanced] `module/history_recommend_songs_detail.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `date=2026-09-08` 回 `{"msg":null,"code":301}`；
    /// **200 的形状未实机验证过**：按参考实现每项是 `{"song": {歌曲对象}, …}`，
    /// 所以这里先剥 `song` 再解析，剥不出来就把这一项本身当歌曲试一次
    /// （服务端两种形状都见过，兜一下不亏）。
    func recommendedSongHistory(date: String) async -> [Track] {
        guard let resp = try? await eapi("/api/discovery/recommend/songs/history/detail",
                                         [("date", .string(date))]),
              let data = resp["data"] as? [String: Any],
              let songs = data["songs"] as? [[String: Any]] else { return [] }
        return songs.compactMap { Self.parseTrack(($0["song"] as? [String: Any]) ?? $0) }
    }

    // MARK: - 私人 FM（独立播放模式，⚠️ 不是自动连播的候选源）

    /// 私人 FM 发的下一批歌。`/api/v1/radio/get`，**无参数**，走 eapi。
    /// [api-enhanced] `module/personal_fm.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl] 匿名（没有 `MUSIC_U`）照样回 `code:200`；
    /// `data` 里**恒 1 条**，连打 6 条拿到 6 首互不相同的歌，6 条总共约 1.3 秒。
    /// 未登录时发的是大盘热门而不是「你的口味」。
    /// 曲目是明文接口那套字段（`artists` / `album` / `duration`），`parseTrack` 直接认；
    /// 档位节点叫 `bMusic` / `hMusic`（**不是** `sq` / `hr`，所以 `losslessAvailable`
    /// 是 nil＝未知），碟号那一格叫 `disc` 不是 `cd`（取不到就是 nil）。
    ///
    /// 一次只有一首不是缺陷，是 FM 这种模式本来的形状：播一首要一首。
    /// 想预取就连打几条（各自独立，服务端不去重也不认 offset）。
    func personalFMTracks() async -> [Track] {
        guard let resp = try? await eapi("/api/v1/radio/get"),
              let data = resp["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { Self.parseTrack($0) }
    }

    /// FM 的垃圾桶（「不再播放」）。`/api/radio/trash/add`，
    /// 参数 `songId` / `alg=RT` / `time`（已播秒数，参考实现默认 25），走 eapi。
    /// [api-enhanced] `module/fm_trash.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"songs":[],"count":0,"code":200}`
    /// ——**匿名时 code 是 200 但什么也没发生**（`count` 恒 0）。所以这条不能靠返回码
    /// 判断成功与否，只能靠「有没有登录」；未登录一律先抛，别让用户以为扔进去了。
    /// 登录态下的 200 形状未实机验证过。
    func trashFMTrack(_ trackID: String, playedSeconds: Int = 25) async throws {
        guard isLoggedIn else {
            throw ProviderError.unavailable("请先登录网易云音乐账号，才能把这首歌扔进垃圾桶")
        }
        try await eapi("/api/radio/trash/add", [
            ("songId", .string(trackID.rawID)), ("alg", .string("RT")),
            ("time", .int(playedSeconds)),
        ])
    }

    // MARK: - 心动模式（独立播放模式，⚠️ 不是自动连播的候选源）

    /// 心动模式（智能播放）。`/api/playmode/intelligence/list`，参数
    /// `songId` / `type="fromPlayOne"` / **`playlistId`（必填）** / `startMusicId` / `count`，
    /// 走 eapi。[api-enhanced] `module/playmode_intelligence_list.js`
    ///
    /// 语义是「在**某张歌单里**按心动顺序往下播」，所以它天然绑着一张歌单——
    /// 没有 `playlistId` 这条接口就不成立，这也是它不能当「找相似」用的根本原因。
    ///
    /// **要登录**，而且匿名时两条路回的码还不一样：
    /// [实测 2026-09-09 curl] 明文 GET 回 `{"code":301}`（网易云的「未登录」码）；
    /// [实测 2026-09-09 curl(eapi 探针)] eapi 回 `{"code":400,"message":"不支持该歌单类型","data":null}`
    /// ——热歌榜（3778678）与随便一张精品 UGC 歌单（6666112560）都是这个码，
    /// 所以「不支持该歌单类型」多半只是匿名态的说辞，不是真的挑歌单。
    /// **200 的响应形状从未实机验证过**：参考实现里每项是 `{"id": …, "songInfo": {歌曲对象}}`，
    /// 所以这里先剥 `songInfo`，剥不出来再把这一项本身当歌曲试一次。
    /// 哪天扫码登录之后，第一件事是把这条的真实响应对一遍。
    func intelligenceTracks(seedTrackID: String, playlistID: String,
                            count: Int = 1) async -> [Track] {
        let seed = seedTrackID.rawID
        guard !seed.isEmpty, !playlistID.rawID.isEmpty else { return [] }
        guard let resp = try? await eapi("/api/playmode/intelligence/list", [
            ("songId", .string(seed)), ("type", .string("fromPlayOne")),
            ("playlistId", .string(playlistID.rawID)), ("startMusicId", .string(seed)),
            ("count", .int(count)),
        ]) else { return [] }
        let data = resp["data"] as? [[String: Any]] ?? []
        return data.compactMap { Self.parseTrack(($0["songInfo"] as? [String: Any]) ?? $0) }
    }

    // MARK: - 推荐 MV 与独家放送

    /// 推荐 MV。`/api/personalized/mv`，**无参数**。
    /// [api-enhanced] `module/personalized_mv.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl + eapi 探针] 匿名两条路都回 `code:200`，`result` 一整排，
    /// 每条形如 `{"id":10973299,"type":5,"name":"Mute","picUrl":"…","duration":184000,
    /// "playCount":3331261,"artists":[{"id":12098023,"name":"孟美岐"}],"artistName":"孟美岐",…}`。
    /// 匿名也给全量，所以走明文 GET。
    ///
    /// **封面那一格叫 `picUrl` 不是 `cover`**，`parseMV` 只认 `cover`，
    /// 所以这里补一手再交过去（不改 `parseMV`——那条是搜索/目录页共用的）。
    func personalizedMVs() async -> [MV] {
        guard let resp = try? await get("/api/personalized/mv"),
              let result = resp["result"] as? [[String: Any]] else { return [] }
        return result.compactMap { item -> MV? in
            var normalized = item
            if normalized["cover"] == nil, let pic = normalized["picUrl"] {
                normalized["cover"] = pic
            }
            return Self.parseMV(normalized)
        }
    }

    /// 独家放送。`/api/personalized/privatecontent`，**无参数**。
    /// [api-enhanced] `module/personalized_privatecontent.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl] 匿名回 `code:200`、`name:"独家放送"`，`result` 3 条，
    /// 每条形如 `{"id":14514232,"url":"","picUrl":"…","sPicUrl":"…","type":5,
    /// "copywriter":"《超级面对面》第254期 keshi：我的音乐永远新鲜","name":"…","alg":"…"}`
    /// ——三条都是访谈类视频（`type:5`）。
    ///
    /// **它不能当 MV 用**：没有时长、没有艺人，硬塞进 `MV` 会造出一堆
    /// `duration: 0` 的假数据。所以单独给一个 `NeteasePrivateContent`，
    /// 有多少信息交多少，不编。`url` 实测是空串，进不去详情页要靠 `type` + `id`
    /// 自己拼（这轮不做，等真有落点时再说）。
    func privateContents() async -> [NeteasePrivateContent] {
        guard let resp = try? await get("/api/personalized/privatecontent"),
              let result = resp["result"] as? [[String: Any]] else { return [] }
        return result.compactMap { item in
            guard let id = item["id"] as? Int else { return nil }
            return NeteasePrivateContent(
                id: "ne:\(id)",
                type: item["type"] as? Int ?? 0,
                title: item["name"] as? String ?? "",
                // copywriter 常与 name 重复，重复时不当副标题使（卡片上会显示两行一样的字）
                note: (item["copywriter"] as? String).flatMap {
                    $0.isEmpty || $0 == (item["name"] as? String) ? nil : $0
                },
                coverURL: Self.artworkURL(item["picUrl"] as? String ?? ""),
                webURL: (item["url"] as? String).flatMap {
                    $0.isEmpty ? nil : URL(string: $0.httpsUpgraded)
                })
        }
    }
}

// MARK: - 减少推荐

/// 「减少推荐」在网易云只有**单向**的一记：`/api/v2/discovery/recommend/dislike`
/// （上面的 `dislikeRecommendedTrack`，界面上就是日推那句「不感兴趣」）。
///
/// 两件事必须说在前面，免得下次照着 QQ 那边的形状来找：
///
/// 1. **没有撤销接口。** 整份 [api-enhanced] 里与它成对的一条都没有——
///    `fm_trash` 那条也一样是单向的。所以 `supportsUndoSuggestLess` 报 false，
///    「撤销减少推荐」在网易云的曲目上根本不摆（`MenuSpec` 的禁用即隐藏）。
/// 2. **走的是「不感兴趣」而不是 FM 垃圾桶（`trashFMTrack`）。** 两条都是口味反馈，
///    但垃圾桶改的是私人 FM 的发歌（Amber 还没有那个模式），「不感兴趣」改的正是推荐，
///    与菜单上这一条说的是同一件事。
///
/// 参数里的 `resType = 4`（歌曲）是日推那一路带的，**用在非日推的歌上没有实机验证过**：
/// 服务端要是不认，`dislikeRecommendedTrack` 会抛，调用点原样把话报成 toast——
/// 不吞错、也不假装成功。
extension NeteaseAPI: MusicTasteWriting {

    func suggestLess(tracks trackIDs: [String], less: Bool) async throws {
        guard less else {
            throw ProviderError.unavailable("网易云没有撤销「不感兴趣」的接口")
        }
        for id in trackIDs {
            _ = try await dislikeRecommendedTrack(id)
        }
    }
}

/// 独家放送里的一条。只有网易云有这种条目（访谈/纪录片/短片混在一起），
/// 所以类型留在这个扩展文件里，不往 `ProviderAPIModels` 里凑。
struct NeteasePrivateContent: Identifiable, Hashable, Sendable {
    /// `ne:<id>`。网易那边这个 id 的含义随 `type` 变（实测那三条 `type:5` 是视频 id）
    let id: String
    /// 网易的资源类型码。实测目前清一色是 5（视频）；别的值没见过，也就没敢猜。
    let type: Int
    let title: String
    /// 推荐语（`copywriter`）。与标题重复或为空时是 nil。
    let note: String?
    let coverURL: String?
    /// 接口给的落地页。实测恒为空串，所以基本上是 nil。
    let webURL: URL?
}
