import Foundation

/// 曲风（style-tag）与榜单/分区那一批。
///
/// 曲风是网易云近几年新做的一套分类（「华语流行」「City Pop」这种），
/// 与老的「歌单 tag」不是一回事：曲风有自己的详情页、能按曲风查歌/专辑/歌手/歌单，
/// 歌单 tag 只是歌单的筛选词。两套都在这个文件里，方法名上分得清（`style*` / `playlist*Tags`）。
///
/// **通道一律走 eapi**（参考实现这一批多半标 weapi，Amber 没有那条路），
/// 下面每条都用匿名 eapi 探针实打过。
extension NeteaseAPI {

    // MARK: - 曲风

    /// 曲风列表（两层）。`/api/tag/list/get`，**无参数**，走 eapi。
    /// [api-enhanced] `module/style_list.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`data` **28 条**，
    /// 每条 `{tagId, tagName, enName, level, childrenTags, picUrl, colorDeep,
    /// colorShallow, link, showText, tabs}`——`childrenTags` 是二级曲风，
    /// `colorDeep` / `colorShallow` 是网易云给每个曲风配的主题色（十六进制串），
    /// 曲风卡片的底色就用它，不用自己从封面取色。
    func styleTags() async -> [NeteaseStyleTag] {
        guard let resp = try? await eapi("/api/tag/list/get"),
              let list = resp["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { NeteaseStyleTag($0) }
    }

    /// 曲风详情（头部那块）。`/api/style-tag/home/head`，参数 `tagId`，走 eapi。
    /// [api-enhanced] `module/style_detail.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `tagId=1000` 回 `code:200`，`data` 里
    /// `{tagId, name, level, parentNames, enName, desc, cover, colorDeep, colorShallow,
    /// songNum, artistNum, playRate, professionalReviews, favouriteSong, tagPortrait, tabs}`
    /// ——比列表那条多了 `desc`（曲风介绍）、`songNum`/`artistNum`（规模）与
    /// `professionalReviews`（乐评人的话）。
    func styleDetail(tagID: String) async -> NeteaseStyleDetail? {
        guard let resp = try? await eapi("/api/style-tag/home/head", [("tagId", .string(tagID))]),
              let data = resp["data"] as? [String: Any] else { return nil }
        return NeteaseStyleDetail(data)
    }

    /// 曲风下的歌。`/api/style-tag/home/song`，参数 `cursor` / `size` / `tagId` /
    /// `sort`（0 默认），走 eapi。[api-enhanced] `module/style_song.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `tagId=1000&size=2` 回 `code:200`，
    /// `data = {page:{cursor:0, size:2, total:2026, more:true}, songs:[…]}`
    /// ——**翻页信息在 `data.page` 里，游标就是 `cursor`（一个整数偏移量，
    /// 不是评论区那种时间戳）**，`total` 是这个曲风一共多少首。
    /// 曲目是客户端那套缩写字段（`ar`/`al`/`dt`/`sq`/`hr`），`parseTrack` 认得。
    func styleTracks(tagID: String, cursor: Int = 0, size: Int = 20,
                     sort: Int = 0) async -> (tracks: [Track], total: Int, hasMore: Bool) {
        guard let data = await styleBlock("song", tagID: tagID, cursor: cursor, size: size, sort: sort),
              let songs = data["songs"] as? [[String: Any]] else { return ([], 0, false) }
        let page = data["page"] as? [String: Any]
        return (songs.compactMap { Self.parseTrack($0) },
                page?["total"] as? Int ?? 0,
                page?["more"] as? Bool ?? false)
    }

    /// 曲风下的专辑。`/api/style-tag/home/album`，参数同上，走 eapi。
    /// [api-enhanced] `module/style_album.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`data = {albums, page}`，
    /// 专辑是完整对象（`parseAlbum` 认的那套）。
    func styleAlbums(tagID: String, cursor: Int = 0, size: Int = 20,
                     sort: Int = 0) async -> (albums: [Album], total: Int, hasMore: Bool) {
        guard let data = await styleBlock("album", tagID: tagID, cursor: cursor, size: size, sort: sort),
              let albums = data["albums"] as? [[String: Any]] else { return ([], 0, false) }
        let page = data["page"] as? [String: Any]
        return (albums.compactMap { Self.parseAlbum($0) },
                page?["total"] as? Int ?? 0,
                page?["more"] as? Bool ?? false)
    }

    /// 曲风下的歌手。`/api/style-tag/home/artist`，参数同上（**`sort` 恒 0**，
    /// 参考实现里这条不透传 sort），走 eapi。
    /// [api-enhanced] `module/style_artist.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`data = {artists, page}`，
    /// 每项带 `fansCount` / `awardTags`。
    func styleArtists(tagID: String, cursor: Int = 0,
                      size: Int = 20) async -> (artists: [Artist], total: Int, hasMore: Bool) {
        guard let data = await styleBlock("artist", tagID: tagID, cursor: cursor, size: size, sort: 0),
              let artists = data["artists"] as? [[String: Any]] else { return ([], 0, false) }
        let page = data["page"] as? [String: Any]
        return (artists.compactMap { Self.parseArtist($0) },
                page?["total"] as? Int ?? 0,
                page?["more"] as? Bool ?? false)
    }

    /// 曲风下的歌单。`/api/style-tag/home/playlist`，参数同上（`sort` 恒 0），走 eapi。
    /// [api-enhanced] `module/style_playlist.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `tagId=1000&size=2` 回 `code:200`、
    /// `data = {playlist:[…], page:{cursor,size,more,total:37}}`
    /// ——**键名是单数的 `playlist`**（歌/专辑/歌手那三条都是复数），别照着猜。
    ///
    /// 歌单字段也是**瘦身版**：`{id, name, cover, songCount, userName, userId, playCount}`，
    /// 没有 `picUrl` / `coverImgUrl` / `trackCount` / `creator`，`parsePlaylist` 一个都对不上。
    /// 所以这里先归一再喂——同 `+Library.swift` 处理收藏夹视频的做法，
    /// 不去改公共解析器。
    func stylePlaylists(tagID: String, cursor: Int = 0,
                        size: Int = 20) async -> (playlists: [Playlist], total: Int, hasMore: Bool) {
        guard let data = await styleBlock("playlist", tagID: tagID, cursor: cursor, size: size, sort: 0),
              let list = data["playlist"] as? [[String: Any]] else { return ([], 0, false) }
        let page = data["page"] as? [String: Any]
        let playlists = list.compactMap { item -> Playlist? in
            var raw = item
            if raw["picUrl"] == nil { raw["picUrl"] = raw["cover"] }
            if raw["trackCount"] == nil { raw["trackCount"] = raw["songCount"] }
            if raw["creator"] == nil, let userName = raw["userName"] {
                raw["creator"] = ["nickname": userName]
            }
            return Self.parsePlaylist(raw)
        }
        return (playlists, page?["total"] as? Int ?? 0, page?["more"] as? Bool ?? false)
    }

    /// 我的曲风偏好。`/api/tag/my/preference/get`，**无参数**，走 eapi。
    /// [api-enhanced] `module/style_preference.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、
    /// `data = {tagPreferenceVos, tags}`——**匿名也回 200**，只是内容是默认值。
    /// 登录态下 `tagPreferenceVos` 里各曲风的权重是不是真的按听歌历史算，
    /// **未实机验证过**。这里只把 `tags` 那份曲风表交出去（形状与 `styleTags()` 一致）。
    func stylePreferences() async -> [NeteaseStyleTag] {
        guard let resp = try? await eapi("/api/tag/my/preference/get"),
              let data = resp["data"] as? [String: Any],
              let tags = data["tags"] as? [[String: Any]] else { return [] }
        return tags.compactMap { NeteaseStyleTag($0) }
    }

    // MARK: - 榜单

    /// 所有榜单的内容摘要。`/api/toplist/detail/v2`，**无参数**，走 eapi。
    /// [api-enhanced] `module/toplist_detail_v2.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`data` **7 组**：
    /// 「榜单推荐(6)」「官方榜(9)」「精选榜(12)」「曲风榜(7)」「全球榜(6)」
    /// 「语种榜(7)」「特色榜(5)」，每组 `{name, categoryCode, displayType, list}`。
    /// 组里每张榜 `{id, name, coverUrl, updateFrequency, tracks, trackRankList,
    /// toplistCode, category, …}`——**`tracks` 是前几名的预览**（榜单卡片上那三行小字），
    /// 不是全曲目；点进去还得走 `playlistDetail`。
    ///
    /// 与基线的关系：`NeteaseAPI.swift` 里的 `toplist()` 打的是老的 `/api/toplist`
    /// （只回一维的榜单表，没有分组）。这条带分组与预览曲目，是「榜单页」该用的那条。
    func toplistGroups() async -> [NeteaseToplistGroup] {
        guard let resp = try? await eapi("/api/toplist/detail/v2"),
              let data = resp["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { group in
            guard let name = group["name"] as? String else { return nil }
            let charts = (group["list"] as? [[String: Any]] ?? []).compactMap { raw -> NeteaseChartEntry? in
                guard let id = raw["id"] as? Int, let chartName = raw["name"] as? String else { return nil }
                return NeteaseChartEntry(
                    playlistID: "ne:\(id)",
                    name: chartName,
                    coverURL: Self.artworkURL(raw["coverUrl"] as? String ?? ""),
                    updateFrequency: (raw["updateFrequency"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    previewTracks: (raw["tracks"] as? [[String: Any]] ?? []).compactMap {
                        // 预览曲目只有 first/second/third 三个名字字段时给不出 Track，
                        // 所以这里只收真正带 id 的那种
                        Self.parseTrack($0)
                    })
            }
            guard !charts.isEmpty else { return nil }
            return NeteaseToplistGroup(name: name,
                                       categoryCode: group["categoryCode"] as? String,
                                       charts: charts)
        }
    }

    /// 榜单详情（老的 v4 通道）。`/api/playlist/v4/detail`，参数 `id` / `n="500"` / `s="0"`。
    /// [api-enhanced] `module/top_list.js`
    ///
    /// ⚠️ **这条现在打不通，接了只是为了留个记录。**
    /// [实测 2026-09-09 curl + eapi 探针] 四种参数组合（字符串 / 数字 / 补 `t` / 只传 `id`）
    /// 走 eapi 全部回 `{"code":400,"message":"请求参数错误"}`；
    /// 明文 GET 打 `music.163.com` 与 `interface.music.163.com` 两个域也是同一个 400。
    /// 换句话说不是通道问题、也不是参数类型问题——**服务端这条已经不认了**
    /// （参考实现那份是旧快照）。
    ///
    /// 所以调用方拿到 nil 是常态，**该走的是基线的 `playlistDetail(_:)`**（v6 通道，
    /// 唯一给全量 trackIds 的那条）。留着它是因为「判断过、故意留空」比下次有人
    /// 再花半小时验一遍便宜。
    func legacyToplistDetail(playlistID: String) async -> PlaylistDetail? {
        guard let resp = try? await eapi("/api/playlist/v4/detail", [
            ("id", .string(playlistID.rawID)), ("n", .string("500")), ("s", .string("0")),
        ]), let raw = resp["playlist"] as? [String: Any],
              let playlist = Self.parsePlaylist(raw) else { return nil }
        let tracks = (raw["tracks"] as? [[String: Any]] ?? []).compactMap { Self.parseTrack($0) }
        return PlaylistDetail(playlist: playlist, tracks: tracks)
    }

    /// 指定维度的榜单头部信息。`/api/chart/detail`，参数 `chartCode` / `targetId` /
    /// `targetType`，走 eapi。[api-enhanced] `module/chart_detail.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `chartCode=HOT_SONG&targetId=0&targetType=0`
    /// 回 `code:200`，`data` 里 `{chartCode, chartId, name, coverUrl, updateTime,
    /// description, playCount, commentCount, shareCount, commentThreadId,
    /// chartSongPlayUserVOS, commonChartExtInfoVO}`。
    ///
    /// `chartCode` 是网易云自己的榜单代号（实测 `HOT_SONG` 认）；完整的代号表接口不给，
    /// **别在这里写死一份猜的**——真要做这个页面时从 `toplistGroups()` 的
    /// `toplistCode` 里取。
    func chartDetail(chartCode: String, targetID: Int = 0, targetType: Int = 0) async -> Playlist? {
        guard let resp = try? await eapi("/api/chart/detail", [
            ("chartCode", .string(chartCode)), ("targetId", .int(targetID)),
            ("targetType", .int(targetType)),
        ]), let data = resp["data"] as? [String: Any],
              let name = data["name"] as? String else { return nil }
        return Playlist(
            id: "ne:\((data["chartId"] as? Int).map(String.init) ?? chartCode)",
            kind: .netease,
            name: name,
            coverURL: Self.artworkURL(data["coverUrl"] as? String ?? ""),
            description: (data["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            playCount: data["playCount"] as? Int ?? 0)
    }

    /// 指定维度的榜单曲目。`/api/chart/song/detail`，参数同上，走 eapi。
    /// [api-enhanced] `module/chart_song_detail.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `chartCode=HOT_SONG` 回 `code:200`，
    /// `data = {chartCode, chartId, uuid, charts:[100 条], groupNameMap, periodUpdateTimeText}`，
    /// 每条是 `{songData:{…}, …}`——**歌包在 `songData` 里**。
    ///
    /// ⚠️ **`songData.al` 的形状和别处不一样**：它把封面塞进了
    /// `al.extProperties.picUrl` 与 `al.xInfo.picUrl`，**顶层没有 `al.picUrl`**。
    /// 直接喂 `parseTrack` 会得到一批没有封面的歌。所以这里先把 `extProperties.picUrl`
    /// 提回 `al.picUrl` 再解析。（这个坑只在这条接口上见过，所以补在这儿而不是
    /// 改公共的 `parseTrack`。）
    func chartTracks(chartCode: String, targetID: Int = 0, targetType: Int = 0) async -> [Track] {
        guard let resp = try? await eapi("/api/chart/song/detail", [
            ("chartCode", .string(chartCode)), ("targetId", .int(targetID)),
            ("targetType", .int(targetType)),
        ]), let charts = (resp["data"] as? [String: Any])?["charts"] as? [[String: Any]] else { return [] }
        return charts.compactMap { entry in
            guard var song = (entry["songData"] as? [String: Any]) ?? (entry["song"] as? [String: Any])
            else { return nil }
            if var album = song["al"] as? [String: Any], album["picUrl"] == nil {
                let ext = (album["extProperties"] as? [String: Any])
                    ?? (album["xInfo"] as? [String: Any])
                album["picUrl"] = ext?["picUrl"]
                song["al"] = album
            }
            return Self.parseTrack(song)
        }
    }

    // MARK: - 歌单分类

    /// 歌单分类页（某个 cat 下的歌单 + banner + 精品位）。`/api/playlist/category/list`，
    /// 参数 `cat`（默认「全部」）/ `limit` / `newStyle=true`，走 eapi。
    /// [api-enhanced] `module/playlist_category_list.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `cat=全部&limit=5` 回 `code:200`，
    /// `{playlists:[5 条], banners:[3 条], playlistIds:[**499 个 id**],
    /// highQuality:{picUrl,name,copywriter}, algMap}`
    /// ——`playlistIds` 是这一分类下全部歌单的 id 表，翻页靠它自己按需取详情，
    /// 而不是 offset（这条压根没有 offset 参数）。
    ///
    /// 交出来只给 `playlists` 与 `playlistIds`：`banners` 与 `highQuality`
    /// 是网易云自家的运营位，Amber 的分类页上没有对应位置。
    func playlistsInCategory(_ category: String = "全部",
                             limit: Int = 24) async -> (playlists: [Playlist], allIDs: [String]) {
        guard let resp = try? await eapi("/api/playlist/category/list", [
            ("cat", .string(category)), ("limit", .int(limit)), ("newStyle", .bool(true)),
        ]) else { return ([], []) }
        let playlists = (resp["playlists"] as? [[String: Any]] ?? []).compactMap { Self.parsePlaylist($0) }
        let ids = (resp["playlistIds"] as? [Int] ?? []).map { "ne:\($0)" }
        return (playlists, ids)
    }

    /// 热门歌单分类（首页那排词）。`/api/playlist/hottags`，**无参数**，走 eapi。
    /// [api-enhanced] `module/playlist_hot.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`tags` **10 条**，
    /// 每条 `{id, name, type, category, usedCount, hot, position, playlistTag, activity, createTime}`。
    /// 10 条正好是网易云客户端首页那一排的数量。
    func hotPlaylistTags() async -> [NeteasePlaylistTag] {
        guard let resp = try? await eapi("/api/playlist/hottags"),
              let tags = resp["tags"] as? [[String: Any]] else { return [] }
        return tags.compactMap { NeteasePlaylistTag($0) }
    }

    /// 精品歌单的分类词。`/api/playlist/highquality/tags`，**无参数**，走 eapi。
    /// [api-enhanced] `module/playlist_highquality_tags.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`tags` **33 条**，
    /// 每条只有 `{id, name, type, category, hot}`（比 hottags 那条瘦）。
    /// 配基线的 `highqualityPlaylists(offset:limit:)` 用——那条现在只取「全部」，
    /// 有了这张表才能做分类筛选。
    func highQualityPlaylistTags() async -> [NeteasePlaylistTag] {
        guard let resp = try? await eapi("/api/playlist/highquality/tags"),
              let tags = resp["tags"] as? [[String: Any]] else { return [] }
        return tags.compactMap { NeteasePlaylistTag($0) }
    }

    // MARK: - 新歌新碟

    /// 新歌速递。`/api/v1/discovery/new/songs`，参数 `areaId`（**0 全部 / 7 华语 /
    /// 96 欧美 / 8 日本 / 16 韩国**，与 `artist_list` 的 `area` 是同一套编号）
    /// 与 `total=true`，走 eapi。[api-enhanced] `module/top_song.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `areaId=0` 回 `code:200`、`data` **100 条**
    /// ——**这条不收 limit / offset**（参考实现里那两行是注释掉的），一次就是 100 首，
    /// 想少要只能自己截。曲目是明文接口那套字段（`album` / `artists` 全称），
    /// `parseTrack` 认得。
    func newSongs(area: NeteaseArtistArea = .all) async -> [Track] {
        guard let resp = try? await eapi("/api/v1/discovery/new/songs", [
            ("areaId", .int(area == .all ? 0 : area.rawValue)), ("total", .bool(true)),
        ]), let list = resp["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parseTrack($0) }
    }

    /// 新碟上架（按周 / 按月两栏）。`/api/discovery/new/albums/area`，参数
    /// `area`（ALL / ZH / EA / KR / JP）/ `limit` / `offset` / `type`（`new` / `hot`）/
    /// `year` / `month` / `total=false` / `rcmd=true`，走 eapi。
    /// [api-enhanced] `module/top_album.js`（那边标的是 weapi）
    ///
    /// `year` / `month` 不传就用当前月（参考实现的做法），这里同样默认当月。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `area=ALL&limit=3&year=2026&month=9` 回
    /// `code:200`、`weekData` **102 条** + `monthData` **256 条** + `hasMore:false`
    /// ——**`limit` 完全不起作用**（要 3 给了 102 和 256），两栏一次全给。
    ///
    /// 与基线 `newAlbums(limit:offset:area:)`（打 `/api/album/new`）的差别：
    /// 那条给的是一条扁平的新碟表，这条分「本周 / 本月」两栏，是新碟页该用的结构。
    func newAlbumsByArea(area: String = "ALL", type: String = "new",
                         year: Int? = nil, month: Int? = nil,
                         limit: Int = 50, offset: Int = 0) async -> (week: [Album], month: [Album]) {
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        guard let resp = try? await eapi("/api/discovery/new/albums/area", [
            ("area", .string(area)), ("limit", .int(limit)), ("offset", .int(offset)),
            ("type", .string(type)),
            ("year", .int(year ?? now.year ?? 2026)),
            ("month", .int(month ?? now.month ?? 1)),
            ("total", .bool(false)), ("rcmd", .bool(true)),
        ]) else { return ([], []) }
        func albums(_ key: String) -> [Album] {
            (resp[key] as? [[String: Any]] ?? []).compactMap { Self.parseAlbum($0) }
        }
        return (albums("weekData"), albums("monthData"))
    }

    /// 最新专辑（首页那一小排）。`/api/discovery/newAlbum`，**无参数**，走 eapi。
    /// [api-enhanced] `module/album_newest.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`albums` **12 条**
    /// ——固定 12 条，正好铺一排两行的格子。
    func newestAlbums() async -> [Album] {
        guard let resp = try? await eapi("/api/discovery/newAlbum"),
              let list = resp["albums"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parseAlbum($0) }
    }

    // MARK: - 首页运营位

    /// 音乐日历。`/api/mcalendar/detail`，参数 `startTime` / `endTime`（**毫秒时间戳**），走 eapi。
    /// [api-enhanced] `module/calendar.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、
    /// `data = {abtest, calendarEvents, calendarConfig}`。
    /// **区间选得不对时 `calendarEvents` 是 `null`（不是空数组）**：
    /// 我先拿一段过去的区间试，回的是 null；换成「今天起七天」才拿到 5 条。
    /// 所以调用方别把 nil 当失败——它就是「这段时间没有活动」。
    ///
    /// 每条 `{id, eventType, onlineTime, offlineTime, tag, title, imgUrl, targetUrl,
    /// resourceType, resourceId, eventStatus, statusText, headline, canRemind, …}`。
    func musicCalendar(from start: Date = Date(),
                       to end: Date = Date().addingTimeInterval(7 * 86400)) async -> [NeteaseCalendarEvent] {
        guard let resp = try? await eapi("/api/mcalendar/detail", [
            ("startTime", .int(Int(start.timeIntervalSince1970 * 1000))),
            ("endTime", .int(Int(end.timeIntervalSince1970 * 1000))),
        ]), let events = (resp["data"] as? [String: Any])?["calendarEvents"] as? [[String: Any]]
        else { return [] }
        return events.compactMap { NeteaseCalendarEvent($0) }
    }

    /// 首页轮播图。`/api/v2/banner/get`，参数 `clientType`（pc / android / iphone / ipad），走 eapi。
    /// [api-enhanced] `module/banner.js`
    ///
    /// **默认发 `iphone`**：eapi 那条通道的身份本来就伪装成 iPhone 客户端 9.0.90
    /// （见 `NeteaseAPI` 头部注释），发 `pc` 与 header 里的 `os/appver` 自相矛盾。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `clientType=iphone` 回 `code:200`、
    /// `banners` **8 条**，每条 `{bannerId, pic, url, targetId, targetType, typeTitle,
    /// encodeId, titleColor, exclusive, monitorImpressList, monitorClickList, …}`。
    /// `monitor*` 是曝光/点击埋点地址——**Amber 不打那两条**，轮播只是内容入口，
    /// 不替网易云上报用户行为。
    func banners(clientType: String = "iphone") async -> [NeteaseBanner] {
        guard let resp = try? await eapi("/api/v2/banner/get", [("clientType", .string(clientType))]),
              let list = resp["banners"] as? [[String: Any]] else { return [] }
        return list.compactMap { NeteaseBanner($0) }
    }

    /// 首页「发现」页那排圆形入口（每日推荐 / 私人漫游 / 歌单 / 排行榜…）。
    /// `/api/homepage/dragon/ball/static`，**无参数**，走 eapi。
    /// [api-enhanced] `module/homepage_dragon_ball.js`
    ///
    /// 参考实现在注释里写「非登录返回 []」。
    /// [实测 2026-09-09 curl(eapi 探针)] **未登录也回了 11 条**——因为 Amber 的 eapi 通道
    /// 会先注册匿名 token（`ensureAnonymousToken`），也就是参考实现说的「游客登录」。
    /// 所以那句注释不算错，但对 Amber 不成立，别照它的结论跳过这条。
    /// 每条 `{id, name, iconUrl, url, skinSupport, homepageMode, resourceState}`。
    func homepageEntries() async -> [NeteaseHomeEntry] {
        guard let resp = try? await eapi("/api/homepage/dragon/ball/static"),
              let list = resp["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { NeteaseHomeEntry($0) }
    }

    // MARK: - 内部

    /// 四条 `style-tag/home/*` 的公共部分：参数完全一样，只有路径与装数据的键名不同。
    private func styleBlock(_ kind: String, tagID: String, cursor: Int,
                            size: Int, sort: Int) async -> [String: Any]? {
        guard let resp = try? await eapi("/api/style-tag/home/\(kind)", [
            ("cursor", .int(cursor)), ("size", .int(size)),
            ("tagId", .string(tagID)), ("sort", .int(sort)),
        ]) else { return nil }
        return resp["data"] as? [String: Any]
    }
}

// MARK: - 曲风与榜单的小模型

/// 一个曲风。`childrenTags` 是二级曲风（一级才有）。
struct NeteaseStyleTag: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// 英文名（"Mandopop"），卡片上那行小字
    let englishName: String?
    let picURL: String?
    /// 网易云给这个曲风配的主题色，形如 `"#1A1A1A"`。深浅两支配着用。
    let colorDeep: String?
    let colorShallow: String?
    let children: [NeteaseStyleTag]

    init?(_ raw: [String: Any]) {
        guard let name = raw["tagName"] as? String, !name.isEmpty else { return nil }
        let rawID = (raw["tagId"] as? Int).map(String.init) ?? (raw["tagId"] as? String)
        guard let rawID else { return nil }
        self.id = rawID
        self.name = name
        self.englishName = (raw["enName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.picURL = NeteaseAPI.artworkURL(raw["picUrl"] as? String ?? "")
        self.colorDeep = (raw["colorDeep"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.colorShallow = (raw["colorShallow"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.children = (raw["childrenTags"] as? [[String: Any]] ?? []).compactMap { NeteaseStyleTag($0) }
    }
}

/// 曲风详情页头部。
struct NeteaseStyleDetail: Sendable {
    let id: String
    let name: String
    let englishName: String?
    /// 曲风介绍
    let description: String?
    /// 宽幅头图（`cover`）
    let coverURL: String?
    let colorDeep: String?
    let colorShallow: String?
    let songCount: Int
    let artistCount: Int
    /// 上级曲风名（一级曲风为空）
    let parentNames: [String]

    init?(_ raw: [String: Any]) {
        guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
        let rawID = (raw["tagId"] as? Int).map(String.init) ?? (raw["tagId"] as? String)
        guard let rawID else { return nil }
        self.id = rawID
        self.name = name
        self.englishName = (raw["enName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.description = (raw["desc"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // 头图是宽幅的，不套 artworkURL 的方图模板
        self.coverURL = (raw["cover"] as? String).flatMap { $0.isEmpty ? nil : $0.httpsUpgraded }
        self.colorDeep = (raw["colorDeep"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.colorShallow = (raw["colorShallow"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.songCount = raw["songNum"] as? Int ?? 0
        self.artistCount = raw["artistNum"] as? Int ?? 0
        self.parentNames = (raw["parentNames"] as? [String]) ?? []
    }
}

/// 榜单页的一组（「官方榜」「曲风榜」…）。
struct NeteaseToplistGroup: Identifiable, Hashable, Sendable {
    var id: String { categoryCode ?? name }
    let name: String
    let categoryCode: String?
    let charts: [NeteaseChartEntry]
}

/// 一张榜。`playlistID` 是 Amber 形式的歌单 id，点进去直接走 `playlistDetail(_:)`。
struct NeteaseChartEntry: Identifiable, Hashable, Sendable {
    var id: String { playlistID }
    let playlistID: String
    let name: String
    let coverURL: String?
    /// 「每日更新」这类文案
    let updateFrequency: String?
    /// 卡片上那几行预览曲目；接口只给前几名
    let previewTracks: [Track]
}

/// 歌单分类词。`hottags` 与 `highquality/tags` 两条共用（后者字段更少）。
struct NeteasePlaylistTag: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// 大类编号（0 语种 / 1 风格 / 2 场景 / 3 情感 / 4 主题，网易云自己的分法）
    let category: Int?
    /// 是不是热门词
    let isHot: Bool

    init?(_ raw: [String: Any]) {
        guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
        let rawID = (raw["id"] as? Int).map(String.init) ?? (raw["id"] as? String)
        guard let rawID else { return nil }
        self.id = rawID
        self.name = name
        self.category = raw["category"] as? Int
        self.isHot = raw["hot"] as? Bool ?? false
    }
}

/// 轮播图的一条。首页轮播（`banners()`）与电台 banner（`djBanners()`）共用——
/// 后者少了 `bannerId` / `encodeId`，其余字段同名。
struct NeteaseBanner: Identifiable, Hashable, Sendable {
    /// 有 `bannerId` 就用它，没有就退回 `targetId`（电台 banner 那条）
    let id: String
    let picURL: String?
    /// 落地页。多数是 `orpheus://` 这种客户端内跳，Amber 打不开——所以是可选，
    /// 打不开就只当一张图。
    let url: URL?
    /// 「歌单」「MV」这类类型角标文字
    let typeTitle: String?
    /// 目标资源 id 与类型码。类型码的含义网易云没公开，实测常见 1(歌曲)/10(专辑)/1004(MV)，
    /// **没有验全**，所以原样交出去让调用方自己判，这里不折成枚举。
    let targetID: String?
    let targetType: Int?

    init?(_ raw: [String: Any]) {
        let bannerID = (raw["bannerId"] as? String) ?? (raw["bannerId"] as? Int).map(String.init)
        let targetID = (raw["targetId"] as? Int).map(String.init) ?? (raw["targetId"] as? String)
        guard let id = bannerID ?? targetID else { return nil }
        self.id = id
        self.picURL = (raw["pic"] as? String).flatMap { $0.isEmpty ? nil : $0.httpsUpgraded }
        self.url = (raw["url"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        self.typeTitle = (raw["typeTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.targetID = targetID
        self.targetType = raw["targetType"] as? Int
    }
}

/// 音乐日历上的一条活动（新专上线、演唱会、直播…）。
struct NeteaseCalendarEvent: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// 「新专辑」这类角标
    let tag: String?
    let imageURL: String?
    let onlineTime: Date?
    /// 关联资源（专辑/歌单/MV）的 id 与类型码，原样交出
    let resourceID: String?
    let resourceType: String?

    init?(_ raw: [String: Any]) {
        let rawID = (raw["id"] as? Int).map(String.init) ?? (raw["id"] as? String)
        guard let rawID, let title = raw["title"] as? String, !title.isEmpty else { return nil }
        self.id = rawID
        self.title = title
        self.tag = (raw["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.imageURL = (raw["imgUrl"] as? String).flatMap { $0.isEmpty ? nil : $0.httpsUpgraded }
        self.onlineTime = (raw["onlineTime"] as? Int).flatMap {
            $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0) / 1000) : nil
        }
        self.resourceID = (raw["resourceId"] as? Int).map(String.init) ?? (raw["resourceId"] as? String)
        self.resourceType = raw["resourceType"] as? String
    }
}

/// 首页那排圆形入口。
struct NeteaseHomeEntry: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let iconURL: String?
    /// 客户端内跳地址（`orpheus://`），Amber 多半打不开，只当标识用
    let url: String?

    init?(_ raw: [String: Any]) {
        guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
        let rawID = (raw["id"] as? Int).map(String.init) ?? (raw["id"] as? String)
        guard let rawID else { return nil }
        self.id = rawID
        self.name = name
        self.iconURL = (raw["iconUrl"] as? String).flatMap { $0.isEmpty ? nil : $0.httpsUpgraded }
        self.url = (raw["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
