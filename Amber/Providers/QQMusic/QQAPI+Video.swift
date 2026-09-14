import Foundation

// MV 与视频：批量视频详情、歌手 MV 列表、歌曲相关 MV。
// 移植来源：[QQMusicApi] `modules/mv.py`、`modules/song.py::get_related_mv`、
// `modules/singer.py::get_mv_list`。
//
// **取流不在这里。** `GetMvUrls`（`music.stream.MvUrlProxy`）与 MV 分类列表
// `GetAllocMvInfo`（`MvService.MvInfoProServer`）基线都已经有了：前者是
// `QQAPI.mvStreamURL`，后者在 `QQAPI.catalogItems` 的 MV 格子里。这一轮一条都不重复，
// 也不去动它们——`mvStreamURL` 那条的 comm 是实机试出来的（不带 comm 每档回 1000）。
//
// 三条都匿名可用（下面逐条有实测），所以走 `musicu` 默认档。取不到就交空表。

extension QQAPI {

    // MARK: - 视频详情

    /// 一条视频的完整信息。`MV` 模型只装播放要用的那几项，
    /// 简介、播放量、发布时间、关联歌曲这些没有位置，所以另起一个结构装。
    struct QQVideoInfo: Sendable {
        /// 已经组好的 `MV`（id 是 `qq:<vid>`），可以直接丢给播放/列表
        let mv: MV
        /// 数字 mvid。响应里的键叫 `sid`，不叫 mvid（见下）
        let mvID: Int
        let playCount: Int
        let publishDate: Date?
        let introduction: String?
        /// 这支 MV 关联的歌曲**数字 id** 列表（不是 mid）
        let relatedSongIDs: [Int]
        /// UGC 视频的上传者昵称；官方 MV 这几项都是空
        let uploaderName: String?
        let uploaderAvatarURL: String?
    }

    /// 批量取视频详情。`video.VideoDataServer/get_video_info_batch`
    /// （[QQMusicApi] `modules/mv.py::get_detail`）。
    ///
    /// param 有两项：`vidlist`（vid 数组）与 **`required`**——服务端按这张字段名单
    /// 决定发什么，名单里没写的字段一个都不给。所以这张表照参考实现原样抄，
    /// 少写一个就少一块数据（跟 `GetSingerDetail` 那几个 flag 是同一个脾气）。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0。`data` 是**以 vid 为键的字典**（不是数组），
    /// 每条给：`vid` / `name`（不是 title）/ `cover_pic` / `duration`(215) /
    /// `singers[]`（标准歌手对象）/ `playcnt`(80547684) / `pubdate`(1477584000，秒) /
    /// `desc`（一段 MV 拍摄介绍）/ `related_songs`（13 个**数字** songid）/
    /// **`sid`(1053277) 才是数字 mvid**，以及 `msg`（「抱歉，该视频需升级新版QQ音乐…」，
    /// 这条不代表取不到流——`mvStreamURL` 对同一个 vid 照样出地址）。
    /// `uploader_*` 那几项官方 MV 全是空串。
    ///
    /// **字段名与列表接口那套（vid/title/picurl/singers）只重合一半**：`name`≠`title`、
    /// `cover_pic`≠`picurl`，所以不能复用 `parseMvListItem`，这里单独解一份。
    func videoInfo(vids: [String]) async -> [String: QQVideoInfo] {
        let vids = vids.map { $0.rawID }.filter { !$0.isEmpty }
        guard !vids.isEmpty else { return [:] }
        guard let data = try? await musicu(module: "video.VideoDataServer",
                                           method: "get_video_info_batch",
                                           param: ["vidlist": vids, "required": Self.videoFields]) else {
            return [:]
        }
        var result: [String: QQVideoInfo] = [:]
        for vid in vids {
            guard let item = data[vid] as? [String: Any] else { continue }
            let singers = item["singers"] as? [[String: Any]] ?? []
            let pubdate = item["pubdate"] as? Int ?? 0
            let mv = MV(id: "qq:\(vid)", kind: .qq,
                        title: item["name"] as? String ?? "",
                        artistName: singers.compactMap { $0["name"] as? String }
                            .filter { !$0.isEmpty }.joined(separator: " / "),
                        coverURL: Self.httpsURL(item["cover_pic"] as? String),
                        duration: TimeInterval(item["duration"] as? Int ?? 0),
                        webURL: URL(string: "https://y.qq.com/n/ryqq/mv/\(vid)")!)
            result[vid] = QQVideoInfo(
                mv: mv,
                mvID: item["sid"] as? Int ?? 0,
                playCount: item["playcnt"] as? Int ?? 0,
                publishDate: pubdate > 0 ? Date(timeIntervalSince1970: TimeInterval(pubdate)) : nil,
                introduction: (item["desc"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                relatedSongIDs: item["related_songs"] as? [Int] ?? [],
                uploaderName: (item["uploader_nick"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                uploaderAvatarURL: Self.httpsURL(item["uploader_headurl"] as? String))
        }
        return result
    }

    /// 单条的便捷入口。
    func videoInfo(vid: String) async -> QQVideoInfo? {
        await videoInfo(vids: [vid])[vid.rawID]
    }

    /// vid → 数字 mvid。评论那边要它（`QQCommentBiz.mv` 的 BizId 收数字）。
    ///
    /// 数字 id 在详情响应里叫 **`sid`**——`GetSingerMvList` / `GetSongRelatedMv`
    /// 两条列表接口里同一个东西叫 `mvid`，三处不同名，别在别的地方找 `mvid` 键。
    /// [实测 2026-09-09 curl] `u00222le4ox`（告白气球 MV）→ `sid = 1053277`，
    /// 与 `GetSongRelatedMv` 给的 `mvid` 对得上。
    func mvNumericID(vid: String) async -> Int? {
        guard let info = await videoInfo(vid: vid), info.mvID > 0 else { return nil }
        return info.mvID
    }

    /// `get_video_info_batch` 的字段名单（照 [QQMusicApi] `modules/mv.py::get_detail`）。
    /// 参考实现里 `uploader_hasfollow` 写了两遍（应该是笔误），这里只留一份。
    private static let videoFields = [
        "vid", "type", "sid", "cover_pic", "duration", "singers", "video_switch",
        "msg", "name", "desc", "playcnt", "pubdate", "isfav", "gmid",
        "uploader_headurl", "uploader_nick", "uploader_encuin", "uploader_uin",
        "uploader_hasfollow", "uploader_follower_num", "related_songs",
    ]

    // MARK: - 歌手 MV 列表

    /// 歌手的 MV 列表（艺人页那条 MV 货架的完整版）。
    /// `MvService.MvInfoProServer/GetSingerMvList`
    /// （[QQMusicApi] `modules/singer.py::get_mv_list`）。
    ///
    /// param 的键都是**全小写**：`singermid`（不是 singerMid）、`order`、`count`、`start`。
    /// 与它同一个 module 的 `GetSongRelatedMv` 又换成 `songid`/`lastmvid`，
    /// 这个 module 的命名就是这么随意，逐条照抄别推广。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，周杰伦（`0025NhlN2yWrP4`）回
    /// `{list[], total: 10425}`，条目形状是 `{vid, mvid, title, picurl, duration, playcnt,
    /// pubdate, type, icon_type}`——正是 `parseMvListItem` 认的那一套（vid/title/picurl/
    /// singers/duration），所以直接复用它。
    /// **注意这条列表项里没有 `singers`**，所以 `parseMvListItem` 解出来的 `artistName`
    /// 是空串；这是艺人页自己的货架，歌手名本来就在页头上，不补。
    ///
    /// 翻页按 `start`（条数偏移）走，`total` 是总数。与 `GetSingerSongList` /
    /// `GetAlbumList` 那两条不同，**这条的 `count` 是认的**（要 3 条真的回 3 条）。
    func singerMVs(artistID: String, offset: Int = 0, limit: Int = 30) async -> (mvs: [MV], total: Int) {
        let mid = artistID.rawID
        guard !mid.isEmpty else { return ([], 0) }
        guard let data = try? await musicu(module: "MvService.MvInfoProServer",
                                           method: "GetSingerMvList",
                                           param: ["singermid": mid, "order": 1,
                                                   "count": limit, "start": offset]) else {
            return ([], 0)
        }
        let mvs = (data["list"] as? [[String: Any]] ?? []).compactMap { Self.parseMvListItem($0) }
        return (mvs, data["total"] as? Int ?? mvs.count)
    }

    // MARK: - 歌曲相关 MV

    /// 这首歌的相关 MV。`MvService.MvInfoProServer/GetSongRelatedMv`
    /// （[QQMusicApi] `modules/song.py::get_related_mv`）。
    ///
    /// param：`{songid: "<数字 id 的字符串>", songtype: 1, lastmvid: <上一批最后一个 vid>}`。
    /// **`songid` 在这条上是字符串**（参考实现写的是 `str(songid)`），
    /// 而同名参数在 `GetSongLabels` / `GetRelatedPlaylist` 上是数字——照抄，别统一。
    ///
    /// 翻页方式与 `GetRelatedPlaylist` 同族（`BatchRefreshStrategy`）：把上一批最后一条的
    /// **vid** 回传给 `lastmvid` 换下一批，第一次传 0。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，songid="107192078" 回 `{hasmore, list[]}` 3 条，
    /// 条目 `{vid, mvid, title, picurl, playcnt, singers[]}`——**没有 `duration`**，
    /// 所以 `parseMvListItem` 解出来时长是 0（要时长得再走一趟 `videoInfo(vids:)`）。
    /// `hasmore` 的键是**全小写**，跟 `GetRelatedPlaylist` 的 `hasMore` 又不一样，
    /// 而且[实测]两条给的都是数字 1 而不是 JSON 布尔（参考实现的 model 标的是 bool）。
    /// `NSNumber` 桥回 Swift 时 `as? Bool` 对 1 是成立的，所以两种写法都能读，
    /// 这里按实测的数字判，别被 model 带歪。
    func relatedMVs(of track: Track, after lastVID: String? = nil)
        async -> (mvs: [MV], hasMore: Bool) {
        guard let songID = await songID(mid: track.id.rawID) else { return ([], false) }
        let cursor = (lastVID?.rawID).flatMap { $0.isEmpty ? nil : $0 }
        guard let data = try? await musicu(module: "MvService.MvInfoProServer",
                                           method: "GetSongRelatedMv",
                                           param: ["songid": String(songID), "songtype": 1,
                                                   "lastmvid": cursor ?? "0"]) else {
            return ([], false)
        }
        let mvs = (data["list"] as? [[String: Any]] ?? []).compactMap { Self.parseMvListItem($0) }
        let hasMore = (data["hasmore"] as? Int ?? 0) == 1
        return (mvs, hasMore)
    }
}
