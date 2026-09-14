import Foundation

/// 单曲/专辑/歌单的附加信息：百科、创作者、副歌、音质、可用性、动态计数、旧版歌词。
///
/// 这一批的共同点是「详情页上那些不影响播放、但少了就显得空」的数据。
/// **通道一律走 eapi**（参考实现这一批多半标 weapi 或默认通道，Amber 没有 weapi 那条路），
/// 下面每条都用匿名 eapi 探针实打过。
///
/// 取不到就返回 nil / 空——这一整个文件没有写接口，所以没有一条 throws。
extension NeteaseAPI {

    // MARK: - 音乐百科

    /// 音乐百科（播放页「关于这首歌」那一整页）。`/api/song/play/about/block/page`，
    /// 参数 `songId`，走 eapi。[api-enhanced] `module/song_wiki_summary.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `songId=1330348068` 回 `code:200`，
    /// `data = {cursor, blocks, hasMore, pageConfig, pageCodeContext}`，
    /// `blocks` 4 块，每块 `{showType, id, uiElement, creatives, code, extInfo, …}`，
    /// 实测拿到的 `showType` 依次是 `MUSIC_MEMORY_MULTI_TWO_GRID` /
    /// `SONG_PLAY_ABOUT_TAB_SONG_BASIC` / `LIST_SONG` / `PLAYLIST_MULTI_THREE_GRID`。
    ///
    /// **这是一套服务端下发的「积木页」，不是固定字段的数据接口**：块的种类、顺序、
    /// 数量都由服务端定，每种 `showType` 里 `creatives` 的形状还不一样。
    /// 所以这里不硬造模型——那等于把服务端某一天的排版抄成 Swift 结构体，
    /// 下次改版就全错。交出去的是原样的块表，调用方按认识的 `showType` 挑着用，
    /// 不认识的整块跳过（这也是网易云客户端自己的做法）。
    func songWikiBlocks(songID: String) async -> [[String: Any]] {
        guard let resp = try? await eapi("/api/song/play/about/block/page",
                                         [("songId", .string(songID.rawID))]),
              let blocks = (resp["data"] as? [String: Any])?["blocks"] as? [[String: Any]] else { return [] }
        return blocks
    }

    /// 歌曲百科（另一条入口，走通用的「页面关系构造」接口）。
    /// `/api/link/page/parent/relation/construct/info`，参数
    /// `positionCode="songWikiMainPosition"` 与 `extJson`（**一段 JSON 字符串**，
    /// 里面是 `{"states":{"playingResource":{"current":"<songId>","scene":"songWiki"}}}`），走 eapi。
    /// [api-enhanced] `module/song_wiki_info.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`，
    /// `data = {cursor, demote, hasDoubleFlow, blockCodeOrderList, blocks, hasMore, callbackParameters}`
    /// ——同样是积木页，比上一条多一个 `blockCodeOrderList`（块的排序）。
    ///
    /// 两条都留着是因为它们不是一回事：上一条是「播放页下面那一屏」，
    /// 这一条是「歌曲百科整页」。同上，交原样块表。
    func songWikiPageBlocks(songID: String) async -> [[String: Any]] {
        let extJSON = "{\"states\":{\"playingResource\":{\"current\":\"\(songID.rawID)\",\"scene\":\"songWiki\"}}}"
        guard let resp = try? await eapi("/api/link/page/parent/relation/construct/info", [
            ("extJson", .string(extJSON)),
            ("positionCode", .string("songWikiMainPosition")),
        ]), let blocks = (resp["data"] as? [String: Any])?["blocks"] as? [[String: Any]] else { return [] }
        return blocks
    }

    /// 创作者（作词 / 作曲 / 编曲 / 制作人…）。`/api/song/creators`，参数 `songId`，走 eapi。
    /// [api-enhanced] `module/song_creators.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `songId=1330348068`（起风了）回 `code:200`、
    /// `message:"请求成功"`，`data = {titleName:"创作者", songCreatorsRoleVos:[…]}`，
    /// 每项 `{roleName:"作词", creatorMetaVOS:[{artistId, artistName, artistPic,
    /// identityMessage, artistMessage, jumpUrl, canFollowed}]}`
    /// ——角色名是**中文、逐曲不同**（实测拿到「作词」「作曲」），
    /// 正是 `TrackCredit` 不做成枚举的那个理由。
    ///
    /// 一个角色可能挂多个人（`creatorMetaVOS` 是数组），所以 `TrackCredit.names` 是数组。
    /// 顺序照服务端给的（作词在前、作曲在后），不自作主张排序。
    func songCredits(songID: String) async -> [TrackCredit] {
        guard let resp = try? await eapi("/api/song/creators", [("songId", .string(songID.rawID))]),
              let roles = (resp["data"] as? [String: Any])?["songCreatorsRoleVos"] as? [[String: Any]]
        else { return [] }
        return roles.compactMap { role in
            guard let name = role["roleName"] as? String, !name.isEmpty else { return nil }
            let names = (role["creatorMetaVOS"] as? [[String: Any]] ?? [])
                .compactMap { $0["artistName"] as? String }
                .filter { !$0.isEmpty }
            guard !names.isEmpty else { return nil }
            return TrackCredit(role: name, names: names)
        }
    }

    /// 副歌时间（「高潮部分」）。`/api/song/chorus`，参数 `ids`（**JSON 数组的字符串形式**），走 eapi。
    /// [api-enhanced] `module/song_chorus.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回
    /// `{"code":200,"chorus":[{"id":1330348068,"startTime":75938,"endTime":108943,"ugcLocked":1}],
    /// "data":[…同一份…]}`——**`chorus` 与 `data` 是同一份数据的两个键**，两个都在，
    /// 这里优先读 `chorus`（参考实现的语义）、读不到再退 `data`。
    ///
    /// 时间是毫秒，交出去折成秒（Amber 全线用 `TimeInterval` 的秒）。
    func songChorus(songID: String) async -> (start: TimeInterval, end: TimeInterval)? {
        guard let resp = try? await eapi("/api/song/chorus",
                                         [("ids", .string("[\"\(songID.rawID)\"]"))]) else { return nil }
        let list = (resp["chorus"] as? [[String: Any]]) ?? (resp["data"] as? [[String: Any]]) ?? []
        guard let first = list.first,
              let start = first["startTime"] as? Int, let end = first["endTime"] as? Int,
              end > start else { return nil }
        return (TimeInterval(start) / 1000, TimeInterval(end) / 1000)
    }

    /// 音质详情（每一档的码率、体积、增益）。`/api/song/music/detail/get`，
    /// 参数 `songId`，走 eapi。[api-enhanced] `module/song_music_detail.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `songId=1330348068` 回 `code:200`、
    /// `success:true`，`data = {songId, h, m, l, sq, hr, db, jm, je, sk, sks, vi}`，
    /// 每档形如 `{"br":986139,"fid":0,"size":40168924,"vd":-77539.0,"sr":44100}`。
    /// 实测起风了这首：`h` 320k、`m` 192k、`l` 128k、`sq` 986k(无损)、`hr` 2832k(Hi-Res 88.2kHz)、
    /// `jm` 5244k（沉浸声）、`db` 为 null。
    ///
    /// **这条给的是「这首歌存在哪些档」，不是「你能听哪些档」**——后者要看取流接口回的
    /// `level` 与权限。曲目详情里那个 `losslessAvailable` 判的也是前者
    /// （`parseTrack` 里看 `sq`/`hr` 的 size），两者口径一致。
    ///
    /// 交出来是 `[档位键: 规格]`，键名原样保留（`h`/`sq`/`hr`/`jm`…）——
    /// 网易云随时可能加档（`jm`、`je`、`sk` 这几个就是近年加的），
    /// 折成固定枚举等于把新档位悄悄丢掉。
    func songQualityDetail(songID: String) async -> [String: NeteaseAudioSpec] {
        guard let resp = try? await eapi("/api/song/music/detail/get",
                                         [("songId", .string(songID.rawID))]),
              let data = resp["data"] as? [String: Any] else { return [:] }
        var out: [String: NeteaseAudioSpec] = [:]
        for (key, value) in data {
            guard key != "songId", let spec = value as? [String: Any],
                  let bitrate = spec["br"] as? Int, bitrate > 0 else { continue }
            out[key] = NeteaseAudioSpec(
                bitrate: bitrate,
                bytes: spec["size"] as? Int ?? 0,
                sampleRate: spec["sr"] as? Int ?? 0,
                // vd 是响度增益，服务端给的是放大 1000 倍的整数形态的 Double
                volumeDelta: spec["vd"] as? Double ?? 0)
        }
        return out
    }

    /// 灰色歌曲的其他版本。`/api/song/copyright/rcmd`，参数 `songid`（**全小写 `songid`**，
    /// 与同一批接口里的 `songId` 不一致，接口自己就不统一），走 eapi。
    /// [api-enhanced] `module/song_copyright_rcmd.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`data = {originSong:{…}}`
    /// ——**拿一首没下架的歌问，`originSong` 就是这首歌本身**（实测起风了回的还是起风了）。
    /// 所以调用方得自己判「回来的和问的是不是同一首」，一样就是「没有替代版本」。
    /// 真正灰掉的歌回什么（是别的版本还是空），**未实机验证过**——手上没有稳定的灰歌样本，
    /// 而灰不灰是按账号地区和时间变的，拿一首当时正好灰的歌去验，结论也不可复现。
    func songAlternateVersion(songID: String) async -> Track? {
        guard let resp = try? await eapi("/api/song/copyright/rcmd",
                                         [("songid", .string(songID.rawID))]),
              let origin = (resp["data"] as? [String: Any])?["originSong"] as? [String: Any],
              let track = Self.parseTrack(origin) else { return nil }
        // 回的是自己就当作「没有别的版本」
        return track.id == "ne:\(songID.rawID)" ? nil : track
    }

    /// 歌曲动态封面。`/api/songplay/dynamic-cover`，参数 `songId`，走 eapi。
    /// [api-enhanced] `module/song_dynamic_cover.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"code":301,"message":"系统错误",…}`
    /// ——**这一批里唯一要登录的一条**（连红心数都不用登录，它却要）。
    /// 成功态未实机验证过；按参考实现 `data` 里是一份视频/动图地址。
    ///
    /// 因为是读接口，未登录时**返回 nil 而不是抛**——动态封面拿不到就退回静态封面，
    /// 不该弹错误。
    func songDynamicCover(songID: String) async -> URL? {
        guard isLoggedIn,
              let resp = try? await eapi("/api/songplay/dynamic-cover",
                                         [("songId", .string(songID.rawID))]),
              let data = resp["data"] as? [String: Any] else { return nil }
        // 键名未实机确认，几种常见写法都试一遍
        let raw = (data["url"] as? String) ?? (data["videoUrl"] as? String)
            ?? (data["dynamicCoverUrl"] as? String) ?? (data["coverUrl"] as? String)
        return raw.flatMap { $0.isEmpty ? nil : URL(string: $0.httpsUpgraded) }
    }

    /// 这首歌被多少人红心。`/api/song/red/count`，参数 `songId`，走 eapi。
    /// [api-enhanced] `module/song_red_count.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `songId=1330348068` 回
    /// `{"code":200,"data":{"count":64021162,"countDesc":"999w+"}}`
    /// ——`countDesc` 是服务端算好的短格式，**顶到 "999w+" 就不再往上**，
    /// 所以要显示真实的「6402 万」得自己拿 `count` 格式化（`Int.compactCount` 那套）。
    func songRedHeartCount(songID: String) async -> (count: Int, text: String?)? {
        guard let resp = try? await eapi("/api/song/red/count",
                                         [("songId", .string(songID.rawID))]),
              let data = resp["data"] as? [String: Any],
              let count = data["count"] as? Int else { return nil }
        return (count, (data["countDesc"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// 歌曲可用性（「这首能不能放」）。`/api/song/enhance/player/url`，
    /// 参数 `ids`（**JSON 数组的字符串形式**）与 `br`，走 eapi。
    /// [api-enhanced] `module/check_music.js`（那边标的是 weapi）
    ///
    /// 参考实现在拿到响应之后自己判 `data[0].code == 200` 折成
    /// `{success:true}` / `{success:false, message:"亲爱的,暂无版权"}`，这里照做，
    /// 但把判据交回给调用方（返回 Bool），不编那句文案。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `ids=[1330348068]&br=999000` 回 `code:200`、
    /// `data` 1 条，里面 `{id, url, br, size, code, fee, level, freeTrialInfo, …}`
    /// ——**这条与基线 `trackStreamURL` 打的是同一族接口**（那边走 `/api/song/enhance/player/url/v1`
    /// 并带 `level`）。所以「查可用性」本质上就是取一次流然后不用；
    /// 真要播的时候别用这条的 url，用基线那条（它按音质偏好选档、并处理降级）。
    func isTrackPlayable(songID: String, bitrate: Int = 999_000) async -> Bool {
        guard let resp = try? await eapi("/api/song/enhance/player/url", [
            ("ids", .string("[\(songID.rawID)]")), ("br", .int(bitrate)),
        ]), let first = (resp["data"] as? [[String: Any]])?.first else { return false }
        // 每条自己的 code 才是判据；顶层 code 200 只说明请求本身成立
        guard (first["code"] as? Int ?? 0) == 200 else { return false }
        return (first["url"] as? String)?.isEmpty == false
    }

    // MARK: - 专辑与歌单的附加信息

    /// 专辑内每首歌的音质与权限。`/api/album/privilege`，参数 `id`，走 eapi。
    /// [api-enhanced] `module/album_privilege.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `id=34751811` 回 `code:200`、`data` 8 条
    /// （正好是那张专辑的曲目数），每条
    /// `{id, fee, payed, st, pl, dl, sp, cp, subp, cs, maxbr, fl, toast, flag, preSell,
    /// playMaxbr, downloadMaxbr, maxBrLevel, playMaxBrLevel, downloadMaxBrLevel,
    /// plLevel, dlLevel, flLevel, rscl}`。
    ///
    /// 交出来是 `[Amber 曲目 id: 最高可播档位]`。`playMaxBrLevel` 是 `"lossless"` /
    /// `"exhigh"` 这类字符串档位名，与 `neteaseLevel(for:)` 那套是同一套词
    /// ——专辑页要标「无损」角标就靠它，不用逐首打 `songQualityDetail`。
    func albumPrivileges(albumID: String) async -> [String: String] {
        guard let resp = try? await eapi("/api/album/privilege", [("id", .string(albumID.rawID))]),
              let data = resp["data"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for item in data {
            guard let id = item["id"] as? Int else { continue }
            guard let level = (item["playMaxBrLevel"] as? String) ?? (item["maxBrLevel"] as? String),
                  !level.isEmpty else { continue }
            out["ne:\(id)"] = level
        }
        return out
    }

    /// 专辑的动态数据（评论数、收藏数、当前账号收没收藏）。`/api/album/detail/dynamic`，
    /// 参数 `id`，走 eapi。[api-enhanced] `module/album_detail_dynamic.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `id=34751811` 回 `code:200`，**全部扁平在顶层**：
    /// `{commentCount:65, likedCount:0, shareCount:47, subCount:1260, isSub:false,
    /// subTime:0, onSale:false, albumNearbyProduct:{…}}`
    /// ——注意收藏数叫 `subCount`、收没收藏叫 `isSub`，与歌单那条（`bookedCount`/`subscribed`）
    /// 不同名，两条别互抄。
    func albumDynamicInfo(albumID: String) async -> NeteaseResourceDynamicInfo? {
        guard let resp = try? await eapi("/api/album/detail/dynamic",
                                         [("id", .string(albumID.rawID))]) else { return nil }
        return NeteaseResourceDynamicInfo(
            commentCount: resp["commentCount"] as? Int ?? 0,
            shareCount: resp["shareCount"] as? Int ?? 0,
            likedCount: resp["likedCount"] as? Int ?? 0,
            subscribedCount: resp["subCount"] as? Int ?? 0,
            playCount: 0,
            subscribed: resp["isSub"] as? Bool ?? false)
    }

    /// 歌单的动态数据。`/api/playlist/detail/dynamic`，参数 `id` / `n=100000` /
    /// `s`（参考实现默认 8，是「最近收藏者取几个」），走 eapi。
    /// [api-enhanced] `module/playlist_detail_dynamic.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `id=3779629`（新歌榜）回 `code:200`，
    /// 同样扁平在顶层：`{commentCount:158460, shareCount:14023, playCount:3215656960,
    /// bookedCount:2803732, subscribed:false, followed:false, gradeStatus:"NONE",
    /// remarkName:null, remixVideo:null}`
    /// ——**收藏数叫 `bookedCount`**（不是 subCount），收没收藏叫 `subscribed`（不是 isSub）。
    ///
    /// 歌单详情（基线的 `playlistDetail(_:)`）走的是 v6，它给的 `playCount` 是缓存值；
    /// 这条是实时的，详情页头部那几个数用它更准。
    func playlistDynamicInfo(playlistID: String) async -> NeteaseResourceDynamicInfo? {
        guard let resp = try? await eapi("/api/playlist/detail/dynamic", [
            ("id", .string(playlistID.rawID)), ("n", .int(100_000)), ("s", .int(8)),
        ]) else { return nil }
        return NeteaseResourceDynamicInfo(
            commentCount: resp["commentCount"] as? Int ?? 0,
            shareCount: resp["shareCount"] as? Int ?? 0,
            likedCount: 0,
            subscribedCount: resp["bookedCount"] as? Int ?? 0,
            playCount: resp["playCount"] as? Int ?? 0,
            subscribed: resp["subscribed"] as? Bool ?? false)
    }

    /// 相关歌单推荐（歌单详情页底部那排）。`/api/playlist/detail/rcmd/get`，
    /// 参数 `scene="playlist_head"` / `playlistId` / `newStyle="true"`，走 eapi。
    /// [api-enhanced] `module/playlist_detail_rcmd_get.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `playlistId=3779629` 回
    /// `{"code":200,"message":"success","data":null,"doesNotCache":true}`
    /// ——**通了但 `data` 是 null**。是要登录（这条明显是个性化推荐）还是榜单类歌单
    /// 本来就没有相关推荐，匿名分不出来。**非空的形状未实机验证过**，
    /// 按 `data` 里一批歌单对象解析；`data` 也可能包一层 `playlists`，两种都认。
    func relatedPlaylists(playlistID: String) async -> [Playlist] {
        guard let resp = try? await eapi("/api/playlist/detail/rcmd/get", [
            ("scene", .string("playlist_head")),
            ("playlistId", .string(playlistID.rawID)),
            ("newStyle", .string("true")),
        ]) else { return [] }
        let list = (resp["data"] as? [[String: Any]])
            ?? ((resp["data"] as? [String: Any])?["playlists"] as? [[String: Any]])
            ?? []
        return list.compactMap { Self.parsePlaylist($0) }
    }

    /// 「包含这首歌的歌单」。`/api/discovery/simiPlaylist`，参数
    /// `songid`（**是歌曲 id，不是歌单 id**——模块名叫 simi_playlist 很容易看成
    /// 「相似歌单」，其实是「相似歌曲所在的歌单」）/ `limit` / `offset`，走 eapi。
    /// [api-enhanced] `module/simi_playlist.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `songid=1330348068&limit=3` 回 `code:200`、
    /// `playlists` 3 条，字段是完整的歌单对象（`coverImgUrl` / `subscribedCount` /
    /// `creator`…），`parsePlaylist` 认得（它对 `picUrl` 与 `coverImgUrl` 两种都读）。
    ///
    /// **与 `similarArtists` 不同，这条匿名就给**，不用先登录。
    func playlistsContaining(songID: String, limit: Int = 50, offset: Int = 0) async -> [Playlist] {
        guard let resp = try? await eapi("/api/discovery/simiPlaylist", [
            ("songid", .string(songID.rawID)), ("limit", .int(limit)), ("offset", .int(offset)),
        ]), let list = resp["playlists"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parsePlaylist($0) }
    }

    /// 歌单的收藏者。`/api/playlist/subscribers`，参数 `id` / `limit` / `offset`，走 eapi。
    /// [api-enhanced] `module/playlist_subscribers.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `id=3779629&limit=3` 回 `code:200`、
    /// `subscribers` 3 条、`more:true`、**`total:30`**——
    /// 注意 `total` 是 30 而这张歌单实际有两百多万收藏（见上面 `bookedCount:2803732`），
    /// 也就是说**这条只给最近的一小批，`total` 不是收藏总数**。
    /// 真的收藏总数要问 `playlistDynamicInfo` 的 `subscribedCount`。
    ///
    /// 用户对象是平铺的（不像 `artistFans` 包一层 `userProfile`）。
    func playlistSubscribers(playlistID: String, limit: Int = 20, offset: Int = 0) async -> [ProviderUserProfile] {
        guard let resp = try? await eapi("/api/playlist/subscribers", [
            ("id", .string(playlistID.rawID)), ("limit", .int(limit)), ("offset", .int(offset)),
        ]), let list = resp["subscribers"] as? [[String: Any]] else { return [] }
        return list.compactMap { profile in
            guard let uid = profile["userId"] as? Int else { return nil }
            return ProviderUserProfile(
                uid: String(uid),
                nickname: profile["nickname"] as? String ?? "网易云用户",
                avatarURL: Self.artworkURL(profile["avatarUrl"] as? String ?? ""),
                signature: (profile["signature"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                vipLevel: profile["vipType"] as? Int)
        }
    }

    // MARK: - 旧版歌词

    /// 旧版歌词。`/api/song/lyric`，参数 `id` / `tv` / `lv` / `rv` / `kv`（**全传 -1**）/
    /// `_nmclfl=1`，走 eapi。[api-enhanced] `module/lyric.js`
    ///
    /// **与基线 `lyrics(track:)` 的差别**（那条走 `/api/song/lyric/v1`，
    /// [api-enhanced] `module/lyric_new.js`）：
    ///
    /// | | 旧版 `song/lyric` | 新版 `song/lyric/v1`（基线在用） |
    /// |---|---|---|
    /// | 逐字 | **没有** | `yrc` + `ytlrc` / `yromalrc` |
    /// | 卡拉 OK | `klyric`（老式逐字，格式与 yrc 不同） | 不给 |
    /// | 行级 | `lrc` / `tlyric` / `romalrc` | 同 |
    /// | 参数 | 版本号传 -1（要最新） | 版本号传 0 |
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `id=1330348068` 回 `code:200`，
    /// `lrc` / `klyric` / `tlyric` / `romalrc` 四份都有（各是 `{version, lyric}`），
    /// 顶层还有 `sgc` / `sfy` / `qfy` 三个布尔（是不是纯音乐 / 有没有翻译 / 有没有音译）。
    ///
    /// **Amber 日常走的是新版那条**（逐字是 Amber 歌词的核心，见 `am-lyrics-*` 那几条经验）。
    /// 这条留着只为一种情况：新版 `yrc` 与 `lrc` 都空、而老接口的 `klyric` 还在的老歌。
    /// 所以它的返回不是 `[LyricLine]` 而是原始的四份文本——要不要用、怎么合，
    /// 由调用方（将来 `lyrics(track:)` 的兜底分支）决定，这里不越俎代庖。
    func legacyLyrics(songID: String) async -> NeteaseLegacyLyrics? {
        guard let id = Int(songID.rawID) else { return nil }
        guard let resp = try? await eapi("/api/song/lyric", [
            ("id", .int(id)), ("tv", .int(-1)), ("lv", .int(-1)),
            ("rv", .int(-1)), ("kv", .int(-1)), ("_nmclfl", .int(1)),
        ]) else { return nil }
        func text(_ key: String) -> String? {
            let value = (resp[key] as? [String: Any])?["lyric"] as? String
            return (value?.isEmpty == false) ? value : nil
        }
        return NeteaseLegacyLyrics(
            lrc: text("lrc"),
            karaoke: text("klyric"),
            translation: text("tlyric"),
            transliteration: text("romalrc"),
            isPureMusic: resp["sgc"] as? Bool ?? false)
    }

    /// 云盘歌曲的歌词。`/api/cloud/lyric/get`，参数 `userId` / `songId` / `lv=-1` / `kv=-1`，走 eapi。
    /// [api-enhanced] `module/cloud_lyric_get.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名拿别人的 uid + 一首**非云盘**歌曲问，回
    /// `{"code":404}`（就这一个键，连 message 都没有）。这说明路径在、但那首歌不在那个人的云盘里。
    /// **成功态未实机验证过**——要验得先有一首自己云盘里的歌，而云盘上传这一轮没做。
    /// 按参考实现响应形状同旧版歌词（`lrc` / `klyric`）。
    ///
    /// 云盘歌曲（`+Account.swift` 的 `cloudSongs()`）匹配不上曲库时，普通歌词接口是空的，
    /// 只有这条能拿到用户自己传的那份歌词。所以签名要 uid：查的是「某人云盘里的这首」。
    func cloudLyrics(uid: Int, songID: String) async -> NeteaseLegacyLyrics? {
        guard let resp = try? await eapi("/api/cloud/lyric/get", [
            ("userId", .int(uid)), ("songId", .string(songID.rawID)),
            ("lv", .int(-1)), ("kv", .int(-1)),
        ]) else { return nil }
        func text(_ key: String) -> String? {
            let value = (resp[key] as? [String: Any])?["lyric"] as? String
            return (value?.isEmpty == false) ? value : nil
        }
        guard text("lrc") != nil || text("klyric") != nil else { return nil }
        return NeteaseLegacyLyrics(
            lrc: text("lrc"),
            karaoke: text("klyric"),
            translation: text("tlyric"),
            transliteration: text("romalrc"),
            isPureMusic: resp["sgc"] as? Bool ?? false)
    }
}

// MARK: - 附加信息的小模型

/// 一档音质的规格。键名（`h`/`m`/`l`/`sq`/`hr`/`jm`…）由调用方作为字典的键持有。
struct NeteaseAudioSpec: Hashable, Sendable {
    /// 码率（bps）。注意 MV 那边的 `br` 是画面高度，这里的才是真码率。
    let bitrate: Int
    let bytes: Int
    /// 采样率（Hz）。实测 Hi-Res 档是 88200，其余 44100。
    let sampleRate: Int
    /// 响度增益（服务端给的 `vd`）。取流那条路也给同名字段，含义一致。
    let volumeDelta: Double
}

/// 专辑 / 歌单的动态计数。两条接口的键名不同（见各自方法的注释），
/// 归一到这一个类型上，调用方不用记谁叫 `subCount` 谁叫 `bookedCount`。
struct NeteaseResourceDynamicInfo: Hashable, Sendable {
    let commentCount: Int
    let shareCount: Int
    /// 点赞数。歌单那条不给，恒 0。
    let likedCount: Int
    /// 收藏数
    let subscribedCount: Int
    /// 播放量。专辑那条不给，恒 0。
    let playCount: Int
    /// 当前账号收没收藏。匿名恒为 false。
    let subscribed: Bool
}

/// 旧版歌词接口交出来的原始文本。**不解析成 `[LyricLine]`**：
/// 它只在新版接口给不出东西时才登场，怎么合、要不要用由调用方决定。
struct NeteaseLegacyLyrics: Sendable {
    /// 行级歌词（LRC）
    let lrc: String?
    /// 老式卡拉 OK 逐字（`klyric`）。格式与新版的 `yrc` **不同**，
    /// 要用得先确认 `LyricParser` 认不认——这一轮没接线，也就没验过。
    let karaoke: String?
    let translation: String?
    let transliteration: String?
    /// 纯音乐（`sgc`）
    let isPureMusic: Bool
}
