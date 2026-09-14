import Foundation

/// 网易云的 MV 与视频。
///
/// 这块有两套**互不相通**的资源，别混：
///
/// - **MV**：id 是数字，取流走 `/api/song/enhance/play/mv/url`（基线 `mvStreamURL`），
///   模型是 `MV`（`ne:<数字>`）。搜索、艺人页、MV 榜给的都是这一套。
/// - **视频（cloudvideo / UGC）**：id 是 32 位十六进制的 `vid` 字符串，取流走
///   `/api/cloudvideo/playurl`，模型是本文件的 `NeteaseVideo`。
///
/// **不把视频塞进 `MV`**：`MV.id` 的约定是「冒号后面那截就是取流接口认的键」，
/// 把 vid 塞进去会造出一批点开必然 404 的条目。（`+Library.swift` 的 `favoriteMVs()`
/// 走的是另一条路——收藏夹里两种混着，那里做了字段归一，代价是视频那几条取不了流；
/// 这一轮没改它，属于已知缺口。）
///
/// **通道一律走 eapi**（参考实现这一批多半标 weapi，Amber 没有那条路）。
/// `personalized_mv`（推荐 MV）第一轮已经在 `+Discover.swift` 的 `personalizedMVs()`，
/// 这里不重复。
extension NeteaseAPI {

    // MARK: - MV

    /// MV 详情。`/api/v1/mv/detail`，参数 `id`，走 eapi。
    /// [api-enhanced] `module/mv_detail.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `id=10896407`（Dance Monkey）回 `code:200`，
    /// `data` 里 `{id, name, artistName, artistId, cover, duration:236000(ms),
    /// playCount, subCount, commentCount, desc, briefDesc,
    /// publishTime:"2019-05-10"(**字符串日期，不是毫秒时间戳**),
    /// brs:[{br:240,size},{br:480},{br:720},{br:1080}], artists, videoGroup}`，
    /// 顶层另有 `subed`（当前账号收没收藏）与 `mp`（播放权限）。
    ///
    /// `brs` 里的 `br` 其实是**画面高度**（240/480/720/1080），不是码率——名字骗人，
    /// 别照名字当 bitrate 用。它只说明「有哪几档」，真正的地址还得打取流接口。
    func mvDetail(_ mvID: String) async -> NeteaseMVDetail? {
        guard let resp = try? await eapi("/api/v1/mv/detail", [("id", .string(mvID.rawID))]),
              let data = resp["data"] as? [String: Any],
              let mv = Self.parseMV(data) else { return nil }
        return NeteaseMVDetail(
            mv: mv,
            description: (data["desc"] as? String ?? data["briefDesc"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 },
            publishDate: (data["publishTime"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            playCount: data["playCount"] as? Int ?? 0,
            subscribedCount: data["subCount"] as? Int ?? 0,
            commentCount: data["commentCount"] as? Int ?? 0,
            subscribed: resp["subed"] as? Bool ?? false,
            availableHeights: (data["brs"] as? [[String: Any]] ?? []).compactMap { $0["br"] as? Int }.sorted())
    }

    /// MV 的点赞 / 转发 / 评论数。`/api/comment/commentthread/info`，
    /// 参数 `threadid`（**全小写的 `threadid`，与评论那批的 `threadId` 不同**）
    /// 与 `composeliked=true`，走 eapi。
    /// [api-enhanced] `module/mv_detail_info.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `threadid=R_MV_5_10896407` 回
    /// `{"likedCount":122760,"shareCount":14384,"commentCount":3283,"liked":false,"code":200}`
    /// ——就这四个数，扁平在顶层。
    ///
    /// 这条其实是通用的 thread 信息接口（前缀换一下就能问歌曲/歌单），
    /// 但计数那件事 `commentCounts(for:)`（`+Comments.swift`）能一次问一批，更划算；
    /// 这条留着是因为 MV 页只要一个资源的数，省一层数组。
    func mvCommentThreadInfo(_ mvID: String) async -> NeteaseCommentCount? {
        guard let resp = try? await eapi("/api/comment/commentthread/info", [
            ("threadid", .string(NeteaseCommentResource.mv.threadPrefix + mvID.rawID)),
            ("composeliked", .bool(true)),
        ]) else { return nil }
        return NeteaseCommentCount(
            commentCount: resp["commentCount"] as? Int ?? 0,
            likedCount: resp["likedCount"] as? Int ?? 0,
            shareCount: resp["shareCount"] as? Int ?? 0,
            liked: resp["liked"] as? Bool ?? false,
            commentCountText: nil)
    }

    /// 全部 MV（带三个筛选维度）。`/api/mv/all`，参数 `tags`（**一段 JSON 字符串，
    /// 键是中文的「地区」「类型」「排序」**）/ `offset` / `limit` / `total="true"`，走 eapi。
    /// [api-enhanced] `module/mv_all.js`
    ///
    /// 中文键不是笔误：服务端认的就是中文。默认值照参考实现（全部 / 全部 / 上升最快）。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`count:5000`、`hasMore:true`、
    /// `data` 每项 `{id, cover, name, playCount, briefDesc, desc, artistName, artistId,
    /// duration, mark, subed, artists}`——`parseMV` 认的字段齐了。
    func allMVs(area: String = "全部", type: String = "全部", order: String = "上升最快",
                limit: Int = 30, offset: Int = 0) async -> [MV] {
        let tags = "{\"地区\":\"\(area)\",\"类型\":\"\(type)\",\"排序\":\"\(order)\"}"
        guard let resp = try? await eapi("/api/mv/all", [
            ("tags", .string(tags)), ("offset", .int(offset)),
            ("total", .string("true")), ("limit", .int(limit)),
        ]), let list = resp["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parseMV($0) }
    }

    /// MV 排行榜。`/api/mv/toplist`，参数 `area`（空串 = 全部）/ `limit` / `offset` /
    /// `total=true`，走 eapi。[api-enhanced] `module/top_mv.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `area=""` 回 `code:200`、`data` 5 条、
    /// `hasMore:true`、`updateTime`。每项比 `mv/all` 多 `lastRank` / `score` / `mv`
    /// 三个榜单字段，其余同形。
    func mvToplist(area: String = "", limit: Int = 30, offset: Int = 0) async -> [MV] {
        guard let resp = try? await eapi("/api/mv/toplist", [
            ("area", .string(area)), ("limit", .int(limit)),
            ("offset", .int(offset)), ("total", .bool(true)),
        ]), let list = resp["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parseMV($0) }
    }

    /// 网易出品（独家 MV）。`/api/mv/exclusive/rcmd`，参数 `offset` / `limit`，走 eapi。
    /// [api-enhanced] `module/mv_exclusive_rcmd.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`data` 5 条、
    /// **翻页键叫 `more` 不是 `hasMore`**（同一族接口里这两个名字混着用，别猜）。
    func exclusiveMVs(limit: Int = 30, offset: Int = 0) async -> [MV] {
        guard let resp = try? await eapi("/api/mv/exclusive/rcmd", [
            ("offset", .int(offset)), ("limit", .int(limit)),
        ]), let list = resp["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parseMV($0) }
    }

    /// 相似 MV。`/api/discovery/simiMV`，参数 `mvid`，走 eapi。
    /// [api-enhanced] `module/simi_mv.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`mvs` 5 条
    /// ——**与相似歌手（`similarArtists`）不同，这条匿名就给**，不用先登录。
    /// 键名是 `mvs`，条数固定 5（没有 limit 参数）。
    func similarMVs(_ mvID: String) async -> [MV] {
        guard let resp = try? await eapi("/api/discovery/simiMV", [("mvid", .string(mvID.rawID))]),
              let list = resp["mvs"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parseMV($0) }
    }

    /// 歌手相关 MV。`/api/artist/mvs`，参数 `artistId` / `limit` / `offset` / `total=true`，走 eapi。
    /// [api-enhanced] `module/artist_mv.js`（那边标的是 weapi）
    ///
    /// **这条属于视频，所以放这个文件**，`+Artist.swift` 里不再写一份（免得两处漂移）。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `artistId=6452`（周杰伦）回 `code:200`、
    /// `mvs` 5 条 + `hasMore:true`。**字段名与别的 MV 接口对不上**：
    /// 封面叫 `imgurl`（方图）/ `imgurl16v9`（宽图），没有 `cover`；
    /// 其余 `id` / `name` / `duration` / `artistName` 是对的。所以先归一再喂 `parseMV`
    /// ——`parseMV` 是搜索/目录页共用的，不该为这一条接口长分支。
    func artistMVs(artistID: String, limit: Int = 30, offset: Int = 0) async -> [MV] {
        guard let resp = try? await eapi("/api/artist/mvs", [
            ("artistId", .string(artistID.rawID)), ("limit", .int(limit)),
            ("offset", .int(offset)), ("total", .bool(true)),
        ]), let list = resp["mvs"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            var raw = item
            if raw["cover"] == nil {
                // 16:9 那张更贴 MV 卡片的比例，优先；退回方图
                raw["cover"] = raw["imgurl16v9"] ?? raw["imgurl"]
            }
            return Self.parseMV(raw)
        }
    }

    // MARK: - 视频（cloudvideo / UGC）

    /// 视频详情。`/api/cloudvideo/v1/video/detail`，参数 `id`（**32 位十六进制的 vid**），走 eapi。
    /// [api-enhanced] `module/video_detail.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名拿真实 vid 回 `code:200`，`data` 里
    /// `{vid, title, description, coverUrl, durationms, threadId:"R_VI_62_<vid>",
    /// playTime, praisedCount, commentCount, shareCount, subscribeCount,
    /// publishTime(ms), width, height, creator:{userId,nickname,avatarUrl},
    /// resolutions:[{size,resolution:240|480|720}], videoGroup}`。
    ///
    /// **把 MV 的数字 id 传进来会回 `{"code":400,"message":"参数错误"}`**——
    /// 两套 id 不通用，这是最直接的证据。
    func videoDetail(vid: String) async -> NeteaseVideo? {
        guard let resp = try? await eapi("/api/cloudvideo/v1/video/detail",
                                         [("id", .string(vid.rawID))]),
              let data = resp["data"] as? [String: Any] else { return nil }
        return NeteaseVideo(data)
    }

    /// 视频取流。`/api/cloudvideo/playurl`，参数 `ids`（**JSON 数组的字符串形式，
    /// 一次只发一个也要写成 `["xxx"]`**）与 `resolution`，走 eapi。
    /// [api-enhanced] `module/video_url.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `resolution=1080` 回 `code:200`、
    /// `urls` 一条：`{id, url, size:16334796, validityTime:1200, needPay:false, payInfo:null, r:720}`
    /// ——**要 1080 给的是 720**（服务端按这条视频真有的最高档降级，`r` 是实际给到的高度），
    /// 与 `mvStreamURL` 那边「r 收 240/480/720/1080」是同一个脾气。
    /// `validityTime:1200` 是地址 20 分钟过期，别缓存。
    ///
    /// 把 MV 的数字 id 传进来**不报错、只回 `urls:[]`**（实测），所以拿不到时别当网络问题。
    func videoStreamURL(vid: String, maxHeight: Int = 1080) async -> MVVariant? {
        guard let resp = try? await eapi("/api/cloudvideo/playurl", [
            ("ids", .string("[\"\(vid.rawID)\"]")), ("resolution", .int(maxHeight)),
        ]), let first = (resp["urls"] as? [[String: Any]])?.first,
              let raw = first["url"] as? String, !raw.isEmpty,
              let url = URL(string: raw.httpsUpgraded) else { return nil }
        return MVVariant(height: first["r"] as? Int ?? maxHeight,
                         url: url,
                         bytes: first["size"] as? Int ?? 0)
    }

    /// 视频标签（首页视频那排 tab）。`/api/cloudvideo/group/list`，**无参数**，走 eapi。
    /// [api-enhanced] `module/video_group_list.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`message:"success"`、
    /// `data` **107 条**，每项 `{id, name, url, relatedVideoType, selectTab, abExtInfo}`。
    /// 107 条是给客户端自己挑着显示的，别原样铺满一屏。
    func videoGroups() async -> [NeteaseVideoGroup] {
        guard let resp = try? await eapi("/api/cloudvideo/group/list"),
              let list = resp["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { NeteaseVideoGroup($0) }
    }

    /// 视频分类（比标签粗一层）。`/api/cloudvideo/category/list`，
    /// 参数 `offset` / `limit` / `total="true"`，走 eapi。
    /// [api-enhanced] `module/video_category_list.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `limit=10` 回 `code:200`、`data` **只有 2 条**
    /// ——形状与 `group/list` 完全一样，就是那 107 条里被标成「分类」的那两条。
    /// 所以这条与上一条不是「分类 vs 标签」的两级结构，实际是同一张表的两个视图。
    func videoCategories(limit: Int = 99, offset: Int = 0) async -> [NeteaseVideoGroup] {
        guard let resp = try? await eapi("/api/cloudvideo/category/list", [
            ("offset", .int(offset)), ("total", .string("true")), ("limit", .int(limit)),
        ]), let list = resp["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { NeteaseVideoGroup($0) }
    }

    /// 某个标签下的视频。`/api/videotimeline/videogroup/otherclient/get`，
    /// 参数 `groupId` / `offset` / `need_preview_url="true"` / `total=true`，走 eapi。
    /// [api-enhanced] `module/video_group.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名拿 `group/list` 的第一个 id（58100「现场」）
    /// 回 `{"msg":…,"code":200}`——**通了，但连 `datas` 这个键都没有**（不是空数组，是没有）。
    /// 换句话说匿名下这条给不出内容；是要登录还是那个 group 恰好没内容，匿名分不出来。
    /// **成功态未实机验证过**，按同族的 `videotimeline/otherclient/get` 解析（`datas[].data`）。
    func videos(inGroup groupID: String, offset: Int = 0) async -> [NeteaseVideo] {
        guard let resp = try? await eapi("/api/videotimeline/videogroup/otherclient/get", [
            ("groupId", .string(groupID)), ("offset", .int(offset)),
            ("need_preview_url", .string("true")), ("total", .bool(true)),
        ]) else { return [] }
        return Self.parseVideoTimeline(resp)
    }

    /// 全部视频（视频页的默认流）。`/api/videotimeline/otherclient/get`，
    /// 参数 `groupId=0` / `offset` / `need_preview_url="true"` / `total=true`，走 eapi。
    /// [api-enhanced] `module/video_timeline_all.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`hasmore:true`（**全小写 `hasmore`**）、
    /// `datas` 8 条，每条是 `{type, displayed, alg, extAlg, data}` 的包壳，
    /// 真正的视频在 `data` 里（`vid` / `title` / `coverUrl` / `durationms` / `creator` /
    /// `resolutions` / `previewUrl`）。实测 `type` 清一色是 `1`。
    func videoTimeline(offset: Int = 0) async -> [NeteaseVideo] {
        guard let resp = try? await eapi("/api/videotimeline/otherclient/get", [
            ("groupId", .int(0)), ("offset", .int(offset)),
            ("need_preview_url", .string("true")), ("total", .bool(true)),
        ]) else { return [] }
        return Self.parseVideoTimeline(resp)
    }

    /// 推荐视频。`/api/videotimeline/get`，参数 `offset` / `filterLives="[]"` /
    /// `withProgramInfo="true"` / `needUrl="1"` / `resolution="480"`，走 eapi。
    /// [api-enhanced] `module/video_timeline_recommend.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`hasmore:true`、`datas` 8 条，
    /// 包壳与上一条一模一样。`needUrl=1` 会让服务端顺手把 480p 的地址塞进 `data.urlInfo`
    /// ——省一次取流请求，但那份地址同样 20 分钟过期。
    func recommendedVideos(offset: Int = 0) async -> [NeteaseVideo] {
        guard let resp = try? await eapi("/api/videotimeline/get", [
            ("offset", .int(offset)), ("filterLives", .string("[]")),
            ("withProgramInfo", .string("true")), ("needUrl", .string("1")),
            ("resolution", .string("480")),
        ]) else { return [] }
        return Self.parseVideoTimeline(resp)
    }

    /// 相关视频。`/api/cloudvideo/v1/allvideo/rcmd`，参数 `id` 与
    /// `type`（**纯数字 id 传 0（MV），vid 字符串传 1（视频）**），走 eapi。
    /// [api-enhanced] `module/related_allvideo.js`（那边标的是 weapi）
    ///
    /// `type` 这里自己按 id 长相判，与参考实现的 `/^\d+$/.test(id)` 同一条规则。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名两种 id 都回 `{"code":200,"message":"success","data":[]}`
    /// ——**通了但恒空**。是要登录还是这两个样本恰好没有相关视频，匿名分不出来；
    /// **非空的形状未实机验证过**，按同族接口当成 `data` 里一批视频对象解析。
    func relatedVideos(id: String) async -> [NeteaseVideo] {
        let raw = id.rawID
        let isMV = !raw.isEmpty && raw.allSatisfy(\.isNumber)
        guard let resp = try? await eapi("/api/cloudvideo/v1/allvideo/rcmd", [
            ("id", .string(raw)), ("type", .int(isMV ? 0 : 1)),
        ]), let list = resp["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { NeteaseVideo($0["data"] as? [String: Any] ?? $0) }
    }

    /// 歌曲相关的 mlog（网易云的短视频）。`/api/mlog/rcmd/feed/list`，参数
    /// `id`（MV id，没有就 0）/ `type=2` / `rcmdType=20` / `limit` /
    /// `extInfo`（**一段 JSON 字符串 `{"songId":"…"}`**），走 eapi。
    /// [api-enhanced] `module/mlog_music_rcmd.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `songId=1330348068` 回 `code:200`、
    /// `message:"ok"`、`data = {feeds, more:true, msg}`，`feeds` **只给了 1 条**（要 5 给 1）。
    /// 每条 `{id:"a1PvyoDUbEJmk0", type:1, resource:{mlogBaseData:{…}}, alg, reason, …}`，
    /// 内容在 `resource.mlogBaseData`：`{id, userId, type, originalTitle, text, desc,
    /// pubTime, coverUrl, coverDetail.{verticalCoverImage,horizontalCoverImage}, …}`。
    ///
    /// **mlog id 不是 vid**，要播得先过一道 `mlogVideoID(mlogID:)` 换成 vid。
    func songRelatedMlogs(songID: String, mvID: String? = nil, limit: Int = 10) async -> [NeteaseMlog] {
        guard let resp = try? await eapi("/api/mlog/rcmd/feed/list", [
            ("id", .string(mvID.map { $0.rawID } ?? "0")),
            ("type", .int(2)), ("rcmdType", .int(20)), ("limit", .int(limit)),
            ("extInfo", .string("{\"songId\":\"\(songID.rawID)\"}")),
        ]), let feeds = (resp["data"] as? [String: Any])?["feeds"] as? [[String: Any]] else { return [] }
        return feeds.compactMap { NeteaseMlog($0) }
    }

    /// mlog id → 视频 vid。`/api/mlog/video/convert/id`，参数 `mlogId`，走 eapi。
    /// [api-enhanced] `module/mlog_to_video.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `mlogId=a1PvyoDUbEJmk0` 回
    /// `{"code":200,"message":"ok","data":"DE752E060B68DDA2A1A86597DC9F80E7"}`
    /// ——**`data` 就是一个裸字符串**，不是对象，别按 `data.vid` 取。
    /// 换出来的 vid 接着喂 `videoStreamURL(vid:)` 就能播。
    func mlogVideoID(mlogID: String) async -> String? {
        guard let resp = try? await eapi("/api/mlog/video/convert/id", [("mlogId", .string(mlogID))]),
              let vid = resp["data"] as? String, !vid.isEmpty else { return nil }
        return vid
    }

    // MARK: - 内部

    /// 三条 videotimeline 接口共用的解包：`datas[].data` 才是视频本体。
    private static func parseVideoTimeline(_ resp: [String: Any]) -> [NeteaseVideo] {
        (resp["datas"] as? [[String: Any]] ?? []).compactMap {
            NeteaseVideo($0["data"] as? [String: Any] ?? [:])
        }
    }
}

// MARK: - 视频侧的小模型

/// MV 详情页要显示、而 `MV` 模型里没有的那些数。
/// 不往 `MV` 里加字段：那个模型是搜索、目录页、收藏夹共用的，
/// 为详情页多挂七八个恒 0 的计数只会让别处误以为有数据。
struct NeteaseMVDetail: Sendable {
    let mv: MV
    let description: String?
    /// 发行日期。接口给的就是 `"2019-05-10"` 这种字符串，不是时间戳。
    let publishDate: String?
    let playCount: Int
    let subscribedCount: Int
    let commentCount: Int
    /// 当前账号收没收藏。匿名恒为 false。
    let subscribed: Bool
    /// 有哪几档画质（240 / 480 / 720 / 1080，升序）。接口把它叫 `br`，其实是高度。
    let availableHeights: [Int]
}

/// 网易云的 UGC 视频。与 `MV` 是两套 id 空间，取流接口也不同，所以单独一个模型。
struct NeteaseVideo: Identifiable, Hashable, Sendable {
    /// 32 位十六进制的 `vid`（**不带 `ne:` 前缀**——它不是 Amber 模型里的 id，
    /// 也不能拿去打 MV 的取流接口）
    let id: String
    let title: String
    /// 作者昵称（`creator.nickname`）
    let creatorName: String?
    let creatorID: String?
    let coverURL: String?
    /// 秒
    let duration: TimeInterval
    let playCount: Int
    let praisedCount: Int
    let commentCount: Int
    /// 有哪几档画质（升序）。列表接口与详情接口都给。
    let availableHeights: [Int]
    /// 服务端顺手带上的地址（`needUrl=1` 时的 `urlInfo.url`）。**20 分钟过期**，别缓存；
    /// 给不出就打 `videoStreamURL(vid:)`。
    let previewURL: URL?

    init?(_ raw: [String: Any]) {
        guard let vid = raw["vid"] as? String, !vid.isEmpty else { return nil }
        self.id = vid
        self.title = raw["title"] as? String ?? ""
        let creator = raw["creator"] as? [String: Any]
        self.creatorName = (creator?["nickname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.creatorID = (creator?["userId"] as? Int).map(String.init)
        // 视频封面是 16:9，与方形封面走不同的取图模板，所以不套 artworkURL 的 300y300
        self.coverURL = (raw["coverUrl"] as? String).flatMap { $0.isEmpty ? nil : $0.httpsUpgraded }
        self.duration = TimeInterval(raw["durationms"] as? Int ?? 0) / 1000
        self.playCount = raw["playTime"] as? Int ?? 0
        self.praisedCount = raw["praisedCount"] as? Int ?? 0
        self.commentCount = raw["commentCount"] as? Int ?? 0
        self.availableHeights = (raw["resolutions"] as? [[String: Any]] ?? [])
            .compactMap { $0["resolution"] as? Int }.sorted()
        let urlInfo = raw["urlInfo"] as? [String: Any]
        self.previewURL = ((urlInfo?["url"] as? String) ?? (raw["previewUrl"] as? String))
            .flatMap { $0.isEmpty ? nil : URL(string: $0.httpsUpgraded) }
    }
}

/// 视频标签 / 分类。两条接口回的是同一种形状。
struct NeteaseVideoGroup: Identifiable, Hashable, Sendable {
    let id: String
    let name: String

    init?(_ raw: [String: Any]) {
        guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
        let rawID = (raw["id"] as? Int).map(String.init) ?? (raw["id"] as? String)
        guard let rawID else { return nil }
        self.id = rawID
        self.name = name
    }
}

/// 一条 mlog（网易云的竖屏短视频）。要播得先 `mlogVideoID(mlogID:)` 换成 vid。
struct NeteaseMlog: Identifiable, Hashable, Sendable {
    /// mlog id（`a1PvyoDUbEJmk0` 这种），**不是 vid**
    let id: String
    let title: String
    /// 正文/说明（`desc`），常与标题不同
    let note: String?
    /// 横图优先（卡片是横的），退回接口给的主封面
    let coverURL: String?
    let date: Date?

    init?(_ feed: [String: Any]) {
        let base = ((feed["resource"] as? [String: Any])?["mlogBaseData"] as? [String: Any]) ?? feed
        guard let id = (base["id"] as? String) ?? (feed["id"] as? String), !id.isEmpty else { return nil }
        self.id = id
        self.title = (base["originalTitle"] as? String) ?? (base["text"] as? String) ?? ""
        self.note = (base["desc"] as? String).flatMap { $0.isEmpty || $0 == (base["text"] as? String) ? nil : $0 }
        let detail = base["coverDetail"] as? [String: Any]
        let horizontal = (detail?["horizontalCoverImage"] as? [String: Any])?["imageUrl"] as? String
        self.coverURL = (horizontal ?? base["coverUrl"] as? String)
            .flatMap { $0.isEmpty ? nil : $0.httpsUpgraded }
        self.date = (base["pubTime"] as? Int).flatMap {
            $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0) / 1000) : nil
        }
    }
}
