import Foundation

// QQ 音乐的推荐段：猜你喜欢、雷达、推荐歌单、推荐新歌、客户端首页 feed。
// 移植来源：[QQMusicApi] `modules/recommend.py`。
//
// ⚠️ **这几条是「目录页的推荐段」，不是自动连播的候选源。**
// `design-ref/todo.md` §3 结过这笔账：自动连播分区头上写的是「将播放类似歌曲」，
// 「与当前这首相似」是这个功能对用户的承诺；而猜你喜欢/雷达/推荐歌单发回来的歌
// 与当前种子无关，接进 `similarTracks` 就是拿别的东西冒充承诺过的东西
// （网易那边已经因为同一个原因把私人 FM 与心动模式摘出去过一次）。
// 自动连播只走 `GetSimilarSongs`（`QQAPI.similarTracks`），这里的方法一条都不许接过去。
//
// 全部返回值都是「取不到就交空表」——推荐段少一段，页面把那一格省掉就是了。

extension QQAPI {

    // MARK: - 猜你喜欢

    /// 猜你喜欢（客户端首页那颗「每日推荐」电台）。
    /// `music.radioProxy.MbTrackRadioSvr/get_radio_track`
    /// （[QQMusicApi] `modules/recommend.py::get_guess_recommend`）。
    ///
    /// param 照抄：`{id: 99, num: 5, from: 0, scene: 0, song_ids: []}`。`id=99` 是
    /// 「猜你喜欢」这条电台的台号——`QQAPI.catalogItems` 里个性电台表（`pf.radiosvr`）
    /// 那条同名电台也是 99，两边对得上。
    ///
    /// **必须登录**：[实测 2026-09-09 curl] 匿名回 `code=1000`，`data` 是一份空壳
    /// （`tracks: null`）。参考实现的说法是「请求平台非 Android 时需要提供有效的
    /// Credential」，而 Amber 的 Android 档 comm（ct=11/cv=12060012）里没有 QIMEI 与
    /// GetSession 那一套设备会话，所以按「要登录」处理：没登录直接交空表，
    /// 不去打那一条——1000 在 `musicu` 里是凭证被拒码，白打一条还会顺手触发登录态复核。
    /// 登录态下的响应形状（`tracks[]` 是不是标准歌曲对象）**没有实机验证过**，
    /// 字段名取自参考实现的 `GuessRecommendResponse`（`tracks` → `list[Song]`）。
    func guessYouLikeTracks(count: Int = 30) async -> [Track] {
        guard isLoggedIn else { return [] }
        guard let data = try? await musicu(module: "music.radioProxy.MbTrackRadioSvr",
                                           method: "get_radio_track",
                                           param: ["id": 99, "num": count, "from": 0,
                                                   "scene": 0, "song_ids": []],
                                           clientType: 11, clientVersion: 12060012),
              let list = data["tracks"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parseSongListItem($0) }
    }

    // MARK: - 雷达

    /// 雷达推荐。`music.recommend.TrackRelationServer/GetRadarSong`
    /// （[QQMusicApi] `modules/recommend.py::get_radar_recommend`）。
    ///
    /// [实测 2026-09-09 curl] **匿名可用**，code=0，`Page:1` 回 `VecSongs` 10 条、
    /// `HasMore: true`。每条是 `{Track: {…标准歌曲对象…}}`（`id`/`mid`/`name`/`singer`/
    /// `album` 全在），所以剥一层 `Track` 再交给 `parseTrack`。
    ///
    /// 未登录时给的是大盘口味（跟私人 FM 匿名时一个道理），登录后才是「你的」雷达——
    /// 这一点决定了它只配摆在目录页的推荐段里，不能当「相似歌曲」用（见文件头）。
    func radarTracks(page: Int = 1) async -> [Track] {
        await catalogCache.value(for: "qq:TrackRelationServer.GetRadarSong?page=\(page)") {
            guard let data = try? await self.musicu(module: "music.recommend.TrackRelationServer",
                                                    method: "GetRadarSong",
                                                    param: ["Page": page, "ReqType": 0,
                                                            "FavSongs": [], "EntranceSongs": []],
                                                    clientType: 11, clientVersion: 12060012),
                  let list = data["VecSongs"] as? [[String: Any]] else { return nil }
            return list.compactMap { ($0["Track"] as? [String: Any]).flatMap(Self.parseTrack) }
        } ?? []
    }

    // MARK: - 推荐歌单

    /// 推荐歌单（歌单广场的推荐流）。`music.playlist.PlaylistSquare/GetRecommendFeed`
    /// （[QQMusicApi] `modules/recommend.py::get_recommend_songlist`）。
    ///
    /// [实测 2026-09-09 curl] 匿名 code=0，`{From:0, Size:5}` 回 `List` 5 条、
    /// `HasMore: true`、`FromLimit: 400`——**400 是服务端给的游标上限**，
    /// 翻页翻到这儿就没有了（`QQAPI.catalogItems` 里各段按 `From` 各取一截，
    /// 就是为了不越过这个上限还彼此不撞车）。
    ///
    /// 条目形状与 `QQAPI.parseFeedPlaylist` 认的一致（`List[].Playlist.basic`），
    /// 所以直接复用那条解析器，别再写一份。
    func recommendedPlaylists(from: Int = 0, size: Int = 25) async -> [Playlist] {
        await catalogCache.value(for: "qq:PlaylistSquare.GetRecommendFeed?from=\(from)&size=\(size)") {
            guard let data = try? await self.musicu(module: "music.playlist.PlaylistSquare",
                                                    method: "GetRecommendFeed",
                                                    param: ["From": from, "Size": size]),
                  let list = data["List"] as? [[String: Any]] else { return nil }
            return list.compactMap { Self.parseFeedPlaylist($0) }
        } ?? []
    }

    // MARK: - 推荐新歌

    /// 推荐新歌的频道。
    ///
    /// [实测 2026-09-09 curl] 频道号不用猜：`get_new_song_info` 的返回里自带 `lanlist`，
    /// 打出来是 **5=最新 / 1=内地 / 6=港台 / 2=欧美 / 4=韩国 / 3=日本**，
    /// 与 [QQMusicApi] `modules/recommend.py::get_recommend_newsong` 的注释完全一致。
    ///（`QQAPI.swift` 里 `newSongTracks()` 那行注释写的是另一套映射，与实测对不上；
    /// 那条只用 `type: 1`，不影响它自己的取数，这一轮不动它。）
    enum NewSongChannel: Int, CaseIterable, Sendable {
        case latest = 5
        case mainland = 1
        case hongKongTaiwan = 6
        case western = 2
        case korean = 4
        case japanese = 3
    }

    /// 推荐新歌。`newsong.NewSongServer/get_new_song_info`
    /// （[QQMusicApi] `modules/recommend.py::get_recommend_newsong`）。
    ///
    /// [实测 2026-09-09 curl] 匿名 code=0，`type: 5`（最新）回 `songlist` **63 条**，
    /// 另带 `lanlist`（频道表）与 `songTagInfoList`（「独家首发 7 天」这类角标）。
    /// 曲目是标准歌曲对象，`parseTrack` 直接认。
    func recommendedNewSongs(channel: NewSongChannel = .latest) async -> [Track] {
        await catalogCache.value(for: "qq:NewSongServer.get_new_song_info?type=\(channel.rawValue)") {
            guard let data = try? await self.musicu(module: "newsong.NewSongServer",
                                                    method: "get_new_song_info",
                                                    param: ["type": channel.rawValue]),
                  let list = data["songlist"] as? [[String: Any]] else { return nil }
            return list.compactMap { Self.parseTrack($0) }
        } ?? []
    }

    // MARK: - 客户端首页 feed

    /// 首页推荐流里的一张卡。`type` 决定它是什么东西，`id` 的含义跟着 `type` 走：
    ///
    /// [实测 2026-09-09 curl] 匿名一屏里出现过这些：
    /// - 200 单曲（`id` 是数字 songid）
    /// - 400 长音频/有声书专辑
    /// - 500 歌单（`id` 是 tid，能直接点开）
    /// - 700 电台（「猜你喜欢」，`id`=99）
    /// - 900 功能页（「雷达模式」）
    /// - 1000 排行榜（`id` 是 topId，对应 Amber 的 `qq:top:<id>`）
    /// - -1 纯运营位（`id` 是一条 https 网页地址）
    struct HomeFeedCard: Sendable {
        let type: Int
        let id: String
        let title: String
        let subtitle: String?
        let coverURL: String?
    }

    /// 首页推荐流的一层楼。
    struct HomeFeedShelf: Sendable {
        let id: Int
        /// 楼层标题。服务端把它拆成模板 + 内容两段（`title_template` 里可能有 `{String}`
        /// 占位），这里取实际展示的那一段（`title_content`），空了才退回模板。
        let title: String
        let cards: [HomeFeedCard]
    }

    /// 客户端首页推荐流。`music.recommend.RecommendFeed/get_recommend_feed`
    /// （[QQMusicApi] `modules/recommend.py::get_home_feed`）。
    ///
    /// [实测 2026-09-09 curl，带 Android comm ct=11/cv=12060012] **匿名就有数据**：
    /// code=0，一屏回 7 层——301「hi 今日为你打造」（猜你喜欢/每日30首/雷达模式）、
    /// 207「大家都在听」（35 张 type=200 的单曲卡）、302（运营位）、271「你的私荐歌单」、
    /// 272「热门节目」、276「为你精选的AI歌单」、114「排行榜」。
    /// 匿名时 301 里那张「每日30首」的 `id` 是 **0**（点不开），登录后才有真 tid——
    /// `QQAPI.personalMixes()` 取的就是这一行，那条方法的注释里记的是登录态的观察。
    ///
    /// 翻页照参考实现：`direction=1`、`page+1`、`s_num` 累加已出的层数，
    /// `v_cache` 装已经出过的层 id 防重复。这里只交出「取一页」的能力，
    /// 游标由调用方自己攒（目录页现在只用第一页）。
    func homeFeed(page: Int = 1, direction: Int = 0,
                  shelfCount: Int = 0, seenShelfIDs: [String] = []) async -> [HomeFeedShelf] {
        guard let data = try? await musicu(module: "music.recommend.RecommendFeed",
                                           method: "get_recommend_feed",
                                           param: ["direction": direction, "page": page,
                                                   "s_num": shelfCount, "v_cache": seenShelfIDs],
                                           clientType: 11, clientVersion: 12060012),
              let shelves = data["v_shelf"] as? [[String: Any]] else { return [] }
        return shelves.compactMap { shelf -> HomeFeedShelf? in
            guard let id = shelf["id"] as? Int else { return nil }
            let content = (shelf["title_content"] as? String) ?? ""
            let template = (shelf["title_template"] as? String) ?? ""
            let cards = (shelf["v_niche"] as? [[String: Any]] ?? [])
                .flatMap { ($0["v_card"] as? [[String: Any]]) ?? [] }
                .compactMap { card -> HomeFeedCard? in
                    guard let type = card["type"] as? Int,
                          let cardID = card["id"] as? String, !cardID.isEmpty,
                          let title = card["title"] as? String else { return nil }
                    return HomeFeedCard(
                        type: type, id: cardID, title: title,
                        subtitle: (card["subtitle"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                        coverURL: Self.httpsURL(card["cover"] as? String))
                }
            guard !cards.isEmpty else { return nil }
            return HomeFeedShelf(id: id, title: content.isEmpty ? template : content, cards: cards)
        }
    }
}
