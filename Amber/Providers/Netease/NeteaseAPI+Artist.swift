import Foundation

/// 网易云歌手页补全。
///
/// 基线的 `artistDetail(_:)` 只打两条（`/api/artist/<id>` 拿头 50 首热门 + `/api/artist/albums/<id>`
/// 拿前 30 张专辑），够撑一个最小的艺人页；Music 那种艺人页还要头图、介绍、全部专辑、
/// 全部单曲、粉丝数。这个文件把那些补上。
///
/// **通道一律走 eapi**（参考实现这一批多半标 weapi，Amber 没有那条路），下面每条都用匿名
/// eapi 探针实打过——**这一批全部匿名可读**，没有一条需要登录。
///
/// 三条**已经有了、这里不重复**：
/// - `similarArtists(_:)`（`/api/discovery/simiArtist`）在 `NeteaseAPI.swift`，
///   而且它**匿名一律回 301**，与本文件这批的脾气不同，别照着改。
/// - `toplist_artist`（`/api/toplist/artist`）在 `NeteaseAPI.swift` 的
///   `catalogItems(.artistSpotlights)` 里内联打了（写死 `type=1` 华语、取前 12 个）。
///   目录页只要那一格，没必要再包一层同名函数。
/// - `artist_mv`（歌手相关 MV）在 `+Video.swift` 的 `artistMVs(artistID:)`——
///   它属于视频那一族（字段名与别的 MV 接口不同，要归一），放在这里会两处漂移。
///
/// 收藏/取消关注（`artist_sub`）与关注列表（`artist_sublist`）第一轮在 `+Library.swift`。
extension NeteaseAPI {

    /// 歌手头图与身份信息。`/api/artist/head/info/get`，参数 `id`，走 eapi。
    /// [api-enhanced] `module/artist_detail.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `id=6452`（周杰伦）回 `code:200`、
    /// `message:"ok"`，`data` 里 `{artist, identify, videoCount, blacklist,
    /// preferShow, showPriMsg, secondaryExpertIdentiy}`。
    /// `identify` 是认证身份，实测 `{"imageUrl":null,
    /// "imageDesc":"歌手、作词、作曲、编曲、制作人、乐手","actionUrl":"orpheus://…"}`。
    ///
    /// **`artist` 这个对象的字段名与别处的歌手对象对不上**，这是这条接口最容易踩的坑：
    /// 它给的是 `{id, cover, avatar, name, transNames, alias, identities, identifyTag,
    /// briefDesc, rank, albumSize, musicSize, mvSize}`——
    /// **没有 `picUrl`**（方头像叫 `avatar`），宽幅头图叫 `cover`。
    /// 直接喂 `parseArtist` 会得到一个头像为 nil 的歌手，所以这里先把 `avatar` 补成 `picUrl`。
    ///
    /// `cover` 正是 `Artist.bannerURL` 要的那张宽幅图（与方形头像是两张不同的图，
    /// 见模型注释）；没有时留 nil，让 hero 自己回退到 `avatarURL`，不拿方图硬顶。
    func artistHeadInfo(_ artistID: String) async -> Artist? {
        guard let resp = try? await eapi("/api/artist/head/info/get",
                                         [("id", .string(artistID.rawID))]),
              let data = resp["data"] as? [String: Any],
              let raw = data["artist"] as? [String: Any] else { return nil }
        var normalized = raw
        if normalized["picUrl"] == nil { normalized["picUrl"] = raw["avatar"] }
        guard var artist = Self.parseArtist(normalized) else { return nil }
        artist.bannerURL = (raw["cover"] as? String).flatMap {
            $0.isEmpty ? nil : $0.httpsUpgraded
        }
        // 认证身份那行当一条 fact 挂上去——ArtistFact 的键名本来就由音源给（模型注释里的口径）
        if let desc = (data["identify"] as? [String: Any])?["imageDesc"] as? String, !desc.isEmpty {
            artist.facts.append(ArtistFact(label: "身份", value: desc))
        }
        return artist
    }

    /// 歌手介绍。`/api/artist/introduction`，参数 `id`，走 eapi。
    /// [api-enhanced] `module/artist_desc.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `id=6452` 回 `code:200`，
    /// `briefDesc` 是一段摘要，`introduction` 是 **6 段** `{ti, txt}`
    /// （`ti` 是小标题「早年经历」「演艺经历」，可能为空串；`txt` 是正文），
    /// 另有 `topicData`（相关专栏文章）与 `count`。
    ///
    /// 交出来是有序的段落表。`briefDesc` 单独给，因为它与第一段正文常常不重样
    /// （摘要是编辑写的，正文是百科抄的），页面上是两个位置。
    func artistIntroduction(_ artistID: String) async -> (brief: String?, sections: [(title: String?, text: String)]) {
        guard let resp = try? await eapi("/api/artist/introduction",
                                         [("id", .string(artistID.rawID))]) else { return (nil, []) }
        let sections = (resp["introduction"] as? [[String: Any]] ?? []).compactMap { item -> (String?, String)? in
            guard let text = item["txt"] as? String, !text.isEmpty else { return nil }
            return ((item["ti"] as? String).flatMap { $0.isEmpty ? nil : $0 }, text)
        }
        return ((resp["briefDesc"] as? String).flatMap { $0.isEmpty ? nil : $0 }, sections)
    }

    /// 歌手全部专辑，**带翻页**。`/api/artist/albums/<id>`（**id 在路径里**），
    /// 参数 `limit` / `offset` / `total=true`，走 eapi。
    /// [api-enhanced] `module/artist_album.js`（那边标的是 weapi）
    ///
    /// 与基线的关系：`artistDetail(_:)` 打的是同一条，但写死 `limit=30`、不翻页
    /// ——周杰伦这种一百多张专辑的歌手，「全部专辑」页会缺一大半。这条是完整版：
    /// `all` 为真时按 `more` 翻到底（上限 20 页兜底）。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `limit=3` 回 `code:200`、`hotAlbums` 3 条、
    /// `more:true`，另外顶层还给一个 `artist` 对象（顺手就有歌手信息，不用再打一条）。
    /// 每项带 `type`（Single / EP / 专辑），`parseAlbum` 已经把它读进 `albumType`
    /// ——艺人页靠它拆「单曲和 EP」那一段。
    func artistAlbums(_ artistID: String, limit: Int = 30, offset: Int = 0,
                      all: Bool = false) async -> [Album] {
        let rawID = artistID.rawID
        var out: [Album] = []
        var cursor = offset
        for _ in 0..<(all ? 20 : 1) {
            guard let resp = try? await eapi("/api/artist/albums/\(rawID)", [
                ("limit", .int(limit)), ("offset", .int(cursor)), ("total", .bool(true)),
            ]) else { break }
            let page = resp["hotAlbums"] as? [[String: Any]] ?? []
            out += page.compactMap { Self.parseAlbum($0) }
            if !all { break }
            if page.count < limit { break }
            if let more = resp["more"] as? Bool, !more { break }
            cursor += limit
        }
        return out
    }

    /// 歌手热门 50 首。`/api/artist/top/song`，参数 `id`，走 eapi。
    /// [api-enhanced] `module/artist_top_song.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `id=6452` 回 `code:200`、`songs` **50 条**、
    /// `more:true`。曲目用的是客户端那套缩写字段（`ar` / `al` / `dt` / `sq` / `hr`），
    /// `parseTrack` 本来就认。
    ///
    /// 与 `artists(_:)`（下一条）的差别：那条回的 `hotSongs` 也是 50 首，但顺带给
    /// `artist` 对象；这条只给歌。**只要歌就用这条**，少解析一坨用不上的东西。
    func artistTopSongs(_ artistID: String) async -> [Track] {
        guard let resp = try? await eapi("/api/artist/top/song", [("id", .string(artistID.rawID))]),
              let songs = resp["songs"] as? [[String: Any]] else { return [] }
        return songs.compactMap { Self.parseTrack($0) }
    }

    /// 歌手单曲（歌手对象 + 热门 50）。`/api/v1/artist/<id>`（**id 在路径里**），
    /// **无参数**，走 eapi。[api-enhanced] `module/artists.js`（那边标的是 weapi）
    ///
    /// **与基线 `artistDetail(_:)` 打的 `/api/artist/<id>` 不是同一条**（那条没有 `/v1`）。
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `id=6452` 回 `code:200`、`hotSongs` 50 条、
    /// `more:true`，`artist` 里比老版多一个 `mvSize`（MV 数）与 `publishTime`。
    /// 老那条这一轮没动——基线在用、且回的内容够；两条并存，需要 `mvSize` 时用 v1。
    func artistSongsWithProfile(_ artistID: String) async -> (artist: Artist?, tracks: [Track]) {
        guard let resp = try? await eapi("/api/v1/artist/\(artistID.rawID)") else { return (nil, []) }
        let artist = (resp["artist"] as? [String: Any]).flatMap { Self.parseArtist($0) }
        let tracks = (resp["hotSongs"] as? [[String: Any]] ?? []).compactMap { Self.parseTrack($0) }
        return (artist, tracks)
    }

    /// 歌手全部单曲，**带排序与翻页**。`/api/v1/artist/songs`，参数 `id` /
    /// `private_cloud="true"` / `work_type=1` / `order`（`hot` 热门 / `time` 时间）/
    /// `offset` / `limit`，走 eapi。[api-enhanced] `module/artist_songs.js`
    ///
    /// `private_cloud` 与 `work_type` 是客户端原样发的常量，照抄。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `id=6452&limit=3` 回 `code:200`、
    /// `songs` 3 条、`more:true`、**`total:566`**——总数在这条上，
    /// 「全部歌曲（566）」那个标题就靠它。所以这里把 total 一起交出去。
    func artistSongs(_ artistID: String, orderByTime: Bool = false,
                     limit: Int = 100, offset: Int = 0) async -> (tracks: [Track], total: Int, hasMore: Bool) {
        guard let resp = try? await eapi("/api/v1/artist/songs", [
            ("id", .string(artistID.rawID)),
            ("private_cloud", .string("true")),
            ("work_type", .int(1)),
            ("order", .string(orderByTime ? "time" : "hot")),
            ("offset", .int(offset)), ("limit", .int(limit)),
        ]) else { return ([], 0, false) }
        return ((resp["songs"] as? [[String: Any]] ?? []).compactMap { Self.parseTrack($0) },
                resp["total"] as? Int ?? 0,
                resp["more"] as? Bool ?? false)
    }

    /// 歌手动态信息（关注状态、演唱会、各类视频数）。`/api/artist/detail/dynamic`，
    /// 参数 `id`，走 eapi。[api-enhanced] `module/artist_detail_dynamic.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `id=6452` 回 `code:200`、
    /// `{followed:false, concert:{simpleConcert,onlineCount,view}, videoNum:[{cat,num}×2],
    /// rcmdResource:null}`——**没有粉丝数**（那在 `artistFollowCount` 那条上），
    /// 别被 `follow` 这个词误导。
    ///
    /// 交出来只留 Amber 用得上的两样：关注状态与「有没有演唱会」。
    /// `videoNum` / `rcmdResource` 是网易云自家分区的入口数，Amber 没有对应位置。
    func artistDynamicInfo(_ artistID: String) async -> (followed: Bool, onlineConcertCount: Int)? {
        guard let resp = try? await eapi("/api/artist/detail/dynamic",
                                         [("id", .string(artistID.rawID))]) else { return nil }
        let concert = resp["concert"] as? [String: Any]
        return (resp["followed"] as? Bool ?? false, concert?["onlineCount"] as? Int ?? 0)
    }

    /// 歌手粉丝数与关注情况。`/api/artist/follow/count/get`，参数 `id`，走 eapi。
    /// [api-enhanced] `module/artist_follow_count.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `id=6452` 回 `code:200`、`message:"success"`，
    /// `data = {isFollow, fansCnt, followCnt, followDay, followDayCnt, follow}`
    /// ——**要的是 `fansCnt`**（粉丝数）；`followCnt` 是这个歌手关注了多少人，
    /// `followDay*` 是「我关注了几天」，登录才有意义。
    func artistFollowCount(_ artistID: String) async -> (fans: Int, followed: Bool)? {
        guard let resp = try? await eapi("/api/artist/follow/count/get",
                                         [("id", .string(artistID.rawID))]),
              let data = resp["data"] as? [String: Any] else { return nil }
        return (data["fansCnt"] as? Int ?? 0,
                (data["isFollow"] as? Bool) ?? (data["follow"] as? Bool) ?? false)
    }

    /// 歌手的粉丝列表。`/api/artist/fans/get`，参数 `id` / `limit` / `offset`，走 eapi。
    /// [api-enhanced] `module/artist_fans.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `id=6452&limit=3` 回 `code:200`、
    /// `message:"success"`、`data` 3 条，每条是 `{userProfile:{…}, vipRights:{…}}`
    /// ——**用户在 `userProfile` 里包着一层**，不是平铺。
    ///
    /// 交出来是 `ProviderUserProfile`（共享模型），与账号那边同一套。
    func artistFans(_ artistID: String, limit: Int = 20, offset: Int = 0) async -> [ProviderUserProfile] {
        guard let resp = try? await eapi("/api/artist/fans/get", [
            ("id", .string(artistID.rawID)), ("limit", .int(limit)), ("offset", .int(offset)),
        ]), let data = resp["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { item in
            guard let profile = item["userProfile"] as? [String: Any],
                  let uid = profile["userId"] as? Int else { return nil }
            return ProviderUserProfile(
                uid: String(uid),
                nickname: profile["nickname"] as? String ?? "网易云用户",
                avatarURL: Self.artworkURL(profile["avatarUrl"] as? String ?? ""),
                signature: (profile["signature"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                vipLevel: profile["vipType"] as? Int)
        }
    }

    /// 歌手分类（按类型 / 地区 / 首字母筛）。`/api/v1/artist/list`，参数
    /// `type`（1 男歌手 / 2 女歌手 / 3 乐队）、`area`（-1 全部 / 7 华语 / 96 欧美 /
    /// 8 日本 / 16 韩国 / 0 其他）、`initial`（**A–Z 的 ASCII 码**，不是字母本身）、
    /// `offset` / `limit` / `total=true`，走 eapi。
    /// [api-enhanced] `module/artist_list.js`（那边标的是 weapi）
    ///
    /// `initial` 那层转换（字母 → 65…90）在这儿做，调用方给字符就行；
    /// 传 nil 表示不按首字母筛（参考实现里是 `undefined`，不发这个键）。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `type=1&area=7&initial=65&limit=3` 回
    /// `code:200`、`artists` 3 条 + `more:true`，每项带 `fansCount`（粉丝数，
    /// 别的歌手接口不给）。
    func artistList(type: NeteaseArtistKind = .male, area: NeteaseArtistArea = .all,
                    initial: Character? = nil, limit: Int = 30, offset: Int = 0) async -> [Artist] {
        var body: [(String, NeteaseJSON)] = []
        if let initial, let ascii = initial.uppercased().first?.asciiValue {
            body.append(("initial", .int(Int(ascii))))
        }
        body += [
            ("offset", .int(offset)), ("limit", .int(limit)), ("total", .bool(true)),
            ("type", .string(String(type.rawValue))), ("area", .int(area.rawValue)),
        ]
        guard let resp = try? await eapi("/api/v1/artist/list", body),
              let list = resp["artists"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parseArtist($0) }
    }

    /// 热门歌手。`/api/artist/top`，参数 `limit` / `offset` / `total=true`，走 eapi。
    /// [api-enhanced] `module/top_artists.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `limit=3` 回 `code:200`、`artists` 3 条、
    /// `more:true`，每项带 `fansCount` / `mvSize` / `identifyTag`。
    ///
    /// 与 `/api/toplist/artist`（歌手榜，基线在 `catalogItems(.artistSpotlights)` 里用）
    /// 的差别：那条是**分语种的排行榜**（type=1 华语、2 欧美…，带名次），
    /// 这条是不分语种的「热门」大表，能翻页。两条不是一回事，别互相顶替。
    func topArtists(limit: Int = 50, offset: Int = 0) async -> [Artist] {
        guard let resp = try? await eapi("/api/artist/top", [
            ("limit", .int(limit)), ("offset", .int(offset)), ("total", .bool(true)),
        ]), let list = resp["artists"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parseArtist($0) }
    }
}

// MARK: - 歌手分类的两个维度

/// `artist_list` 的 `type`。出处：[api-enhanced] `module/artist_list.js` 文件头的对照表。
enum NeteaseArtistKind: Int, CaseIterable, Sendable {
    case male = 1
    case female = 2
    case band = 3

    var displayName: String {
        switch self {
        case .male: return "男歌手"
        case .female: return "女歌手"
        case .band: return "乐队"
        }
    }
}

/// `artist_list` 的 `area`。数字不连续、也不排序，是网易云自己的语种编号，照抄。
enum NeteaseArtistArea: Int, CaseIterable, Sendable {
    case all = -1
    case chinese = 7
    case western = 96
    case japanese = 8
    case korean = 16
    case other = 0

    var displayName: String {
        switch self {
        case .all: return "全部"
        case .chinese: return "华语"
        case .western: return "欧美"
        case .japanese: return "日本"
        case .korean: return "韩国"
        case .other: return "其他"
        }
    }
}
