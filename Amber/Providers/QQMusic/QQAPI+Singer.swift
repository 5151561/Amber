import Foundation

// 歌手页补全：按分类取歌手、歌手主页头、主页各 tab、歌曲/专辑的带翻页版。
// 移植来源：[QQMusicApi] `modules/singer.py`。
//
// 与基线的分工（三处并存，谁也别去改谁）：
//
// | 基线（`QQAPI.swift`） | 这里 | 差在哪 |
// | --- | --- | --- |
// | `GetSingerListIndex`（目录页「歌手」格子，按首字母 + `sin` 翻页） | `singerList(area:sex:genre:)` 走 `GetSingerList` | 后者**不翻页**，一次把这一档的歌手全给（实测 1000 位），另带 `hotlist` 与筛选项 `tags` |
// | `artistDetail` 里的 `GetSingerSongList` / `GetAlbumList`（各一条，`begin: 0` 固定一页） | `singerSongs` / `singerAlbums` 带 `offset` | 前者只要艺人页首屏那一屏，后者是「查看全部」要的完整翻页 |
// | `QQAPI+User.swift::userProfile()` 走 `GetHomepageHeader` | `singerHomepage` 走**同一个 method** | param 不同：那边传 `{uin: <euin>}` 取**用户**主页，这边传 `{SingerMid: …}` 取**歌手**主页。别混 |
//
// ⚠️ **`GetSingerSongList` / `GetAlbumList` 的 `number` 参数是摆设。**
// [实测 2026-09-09 curl] 周杰伦（`0025NhlN2yWrP4`）：`number` 传 10 / 50 / 100，
// 两条接口**一律回 30 条**。所以：
// - 基线 `artistDetail` 传的 `number: 50` 实际拿到的是 30 首 / 30 张，不是 50
//   （行为没错，只是那个数字没有意义）；
// - 参考实现的 `OffsetStrategy(page_size_key="number")` 按请求的页大小往前推 offset，
//   在这两条上会**跳过数据**（要 50 就把 begin 加 50，可服务端只给了 30）。
// 所以这里的翻页一律**按实际拿到的条数推进 `begin`**，不按请求的页大小。
// [实测] `begin: 0` 与 `begin: 30` 两页 30 首 mid 交集为 0，确实是接着来的。

extension QQAPI {

    // MARK: - 按分类取歌手

    /// 歌手筛选器的一组选项（地区 / 曲风 / 性别各一组）。
    struct QQSingerFilter: Hashable, Sendable {
        let id: Int
        let name: String
    }

    /// 歌手列表的一档结果。
    struct QQSingerCategory: Sendable {
        /// 这一档的全部歌手
        let singers: [Artist]
        /// 服务端另给的「热门」子集
        let hotSingers: [Artist]
        /// 筛选器选项（`hastag: 1` 时才有）
        let areas: [QQSingerFilter]
        let genres: [QQSingerFilter]
        let sexes: [QQSingerFilter]
    }

    /// 按地区/性别/曲风取歌手。`music.musichallSinger.SingerList/GetSingerList`
    /// （[QQMusicApi] `modules/singer.py::get_singer_list`）。
    ///
    /// param `{hastag, area, sex, genre}`。三个筛选值的枚举照参考实现的
    /// `AreaType` / `SexType` / `GenreType`，`-100` 一律是「全部」；
    /// 但**不必把这三张表抄成 Swift 枚举**——[实测 2026-09-09 curl] 传 `hastag: 1`
    /// 时服务端会在 `tags` 里把三组选项连 id 带名字一起发回来
    /// （area：全部/内地(200)/港台(2)/欧美(5)/日本(4)/韩国(3)；
    /// genre：全部/流行(7)/说唱(3)/国风(19)/摇滚(4)/电子(2)/民谣(8)/R&B(11)/民族乐(37)/
    /// 轻音乐(93)/爵士(14)/古典(33)/乡村(13)/蓝调(10)；sex：全部/男(0)/女(1)/组合(2)）。
    /// 界面上的筛选器直接用这份，比在代码里写死一张会过期的表强。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0：
    /// - 全部/全部/全部 → `singerlist[]` **1000 条**、`hotlist[]` 200 条，一次给全，没有翻页参数；
    /// - 内地 + 男 + 流行 → 292 条（薛之谦、汪苏泷、许嵩、李荣浩、周深…），说明筛选是真生效的。
    ///
    /// 条目字段与 `GetSingerListIndex` 同名（`singer_mid` / `singer_name` / `singer_pic`），
    /// 但**这条接口的 `singer_pic` 是空字符串**，得回退到 `artistArtwork(mid)` 拼串
    /// ——见 `parseSinger`，那也是这里没直接用基线 `parseSingerListItem` 的原因。
    func singerList(area: Int = -100, sex: Int = -100, genre: Int = -100,
                    includeTags: Bool = true) async -> QQSingerCategory? {
        await catalogCache.value(for: "qq:SingerList.GetSingerList?a=\(area)&s=\(sex)&g=\(genre)") {
            guard let data = try? await self.musicu(
                module: "music.musichallSinger.SingerList", method: "GetSingerList",
                param: ["hastag": includeTags ? 1 : 0, "area": area, "sex": sex, "genre": genre])
            else { return nil }
            let tags = data["tags"] as? [String: Any] ?? [:]
            func filters(_ key: String) -> [QQSingerFilter] {
                (tags[key] as? [[String: Any]] ?? []).compactMap { t in
                    guard let id = t["id"] as? Int, let name = t["name"] as? String else { return nil }
                    return QQSingerFilter(id: id, name: name)
                }
            }
            return QQSingerCategory(
                singers: (data["singerlist"] as? [[String: Any]] ?? []).compactMap { Self.parseSinger($0) },
                hotSingers: (data["hotlist"] as? [[String: Any]] ?? []).compactMap { Self.parseSinger($0) },
                areas: filters("area"), genres: filters("genre"), sexes: filters("sex"))
        }
    }

    /// 歌手列表条目。字段名与基线 `parseSingerListItem` 完全一致，两点处理不同，
    /// 所以单独解一份而不是复用它——**这两点在基线那条上是漏的，写在这里备案**：
    ///
    /// 1. **`singer_pic` 是空串时要退回拼串。** 基线写的是
    ///    `(s["singer_pic"] as? String) ?? Self.artistArtwork(mid)`——空字符串是个合法的
    ///    `String`，`??` 根本不会触发，于是头像变成 `""`。
    ///    [实测 2026-09-09 curl] `GetSingerList` 的每一条 `singer_pic` 都是空串
    ///    （`GetSingerListIndex` 那条倒是给地址，所以基线在目录页上没暴露出来）。
    /// 2. **地址要抬成 https。** [实测] `GetSingerListIndex` 给的是
    ///    `http://y.gtimg.cn/music/photo_new/T001R300x300M000<mid>.webp`——http 的，
    ///    而 `QQAPI` 里别处的图都过了 `httpsURL`。基线这条没过，靠 ATS 例外兜着。
    ///
    /// 两条都只在这里修，没去改共享的那份（这一轮不动 `QQAPI.swift`）。
    static func parseSinger(_ s: [String: Any]) -> Artist? {
        guard let mid = s["singer_mid"] as? String, !mid.isEmpty else { return nil }
        let pic = (s["singer_pic"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Artist(id: "qq:\(mid)", kind: .qq,
                      name: s["singer_name"] as? String ?? "未知歌手",
                      avatarURL: Self.httpsURL(pic) ?? Self.artistArtwork(mid),
                      description: nil)
    }

    // MARK: - 歌手主页头

    /// 歌手主页头上的那一份信息。
    struct QQSingerHomepage: Sendable {
        /// 已经并好头图/头像的艺人
        let artist: Artist
        /// 数字 singerID
        let singerID: Int
        /// 这位歌手的账号 euin（有些歌手在 QQ 音乐里同时是「用户」）
        let encryptedUin: String?
        /// 外文名（`ForeignName`）
        let foreignName: String?
        let fansCount: Int
        /// 当前账号关注没关注（未登录一律 false）
        let isFollowed: Bool
        /// 主页上摆得出来的 tab（`TabDetail` 里非空的那几个）
        let tabs: [QQSingerTab]
    }

    /// 歌手主页的 tab。`tabID` 是请求要传的值，`node` 是响应里装内容的键名。
    /// 表照 [QQMusicApi] `modules/singer.py::TabType`。
    enum QQSingerTab: String, CaseIterable, Sendable {
        case wiki, album, video
        case song = "song_sing"
        case composer = "song_composing"
        case lyricist = "song_lyric"
        case producer
        case arranger
        case musician

        /// 请求里的 `TabID`
        var tabID: String { rawValue }

        /// 响应里内容装在哪个键下。参考实现的 `TabType` 第二个字段就是它：
        /// 五种「作品」类 tab（唱/作曲/作词/制作/编曲/音乐人）共用 `SongTab`。
        var node: String {
            switch self {
            case .wiki: return "IntroductionTab"
            case .album: return "AlbumTab"
            case .video: return "VideoTab"
            case .song, .composer, .lyricist, .producer, .arranger, .musician: return "SongTab"
            }
        }
    }

    /// 歌手主页头。`music.UnifiedHomepage.UnifiedHomepageSrv/GetHomepageHeader`，
    /// param `{SingerMid: <mid>}`（[QQMusicApi] `modules/singer.py::get_info`）。
    ///
    /// **必须走 Android 档的 comm**，而且匿名也要带：
    /// [实测 2026-09-09 curl] 不带 comm / 带 web comm（ct=24、cv=4747474）都回 `code=10000`
    /// 并且给一份**结构完整但值全空**的壳；换成 `{cv: 12060012, ct: 11}` 立刻 code 0 出真数据。
    /// `musicu` 只在有凭证时才发 comm，所以这里用 `commOverride` 显式补一份
    /// （与 `mvStreamURL` 那条同一个手法）。参考实现在这条上标的正是 `platform=Platform.ANDROID`。
    ///
    /// [实测 2026-09-09 curl] 周杰伦回：`Info.BaseInfo` 有
    /// `Name: "周杰伦"` / `Avatar`(300 方图) / `BackgroundImage`(**800×800**，
    /// 不是艺人页那种 2000×938 宽幅——所以它进 `avatarURL` 的备选，不进 `bannerURL`) /
    /// `EncryptedUin: "7eoP7e4koi4qNn**"` / `IsSinger: 1`；
    /// `Info.Singer` 有 `SingerID: 4558` / `SingerMid` / `ForeignName` / `SingerType` /
    /// `SingerPic`(空) / `pc_singer_portrait_list`(几十个写真 pmid)；
    /// `Info.FansNum.Num = 50729887`（数字在 `Num` 子键里，与用户主页同一形状）；
    /// `Info.IsFollowed` 是 0/1。`TabDetail.TabList` 实测是 **null**，
    /// 所以「有哪些 tab」只能看 `TabDetail` 下哪几个节点非空（见 `availableTabs`）。
    func singerHomepage(artistID: String) async -> QQSingerHomepage? {
        let mid = artistID.rawID
        guard !mid.isEmpty else { return nil }
        return await catalogCache.value(for: "qq:UnifiedHomepage.Singer?mid=\(mid)") {
            guard let data = try? await self.musicu(
                module: "music.UnifiedHomepage.UnifiedHomepageSrv", method: "GetHomepageHeader",
                param: ["SingerMid": mid], commOverride: Self.androidComm),
                let info = data["Info"] as? [String: Any] else { return nil }
            let base = info["BaseInfo"] as? [String: Any] ?? [:]
            let singer = info["Singer"] as? [String: Any] ?? [:]
            let name = (singer["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (base["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "未知歌手"
            let artist = Artist(
                id: "qq:\(mid)", kind: .qq, name: name,
                avatarURL: Self.httpsURL(base["Avatar"] as? String)
                    ?? Self.httpsURL(base["BackgroundImage"] as? String)
                    ?? Self.artistArtwork(mid),
                description: nil)
            return QQSingerHomepage(
                artist: artist,
                singerID: singer["SingerID"] as? Int ?? 0,
                encryptedUin: (base["EncryptedUin"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                foreignName: (singer["ForeignName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                fansCount: (info["FansNum"] as? [String: Any])?["Num"] as? Int ?? 0,
                isFollowed: (info["IsFollowed"] as? Int ?? 0) == 1,
                tabs: Self.availableTabs(data["TabDetail"] as? [String: Any] ?? [:]))
        }
    }

    /// `TabList` 是 null（实测），所以按「`TabDetail` 下这个 tab 的节点里有没有东西」来判。
    /// 五种作品类 tab 共用 `SongTab` 一个节点，没法从这里分辨——所以只报一条 `.song`，
    /// 「这位歌手有没有作曲/作词页」得各打一次 `singerTab` 才知道。
    private static func availableTabs(_ detail: [String: Any]) -> [QQSingerTab] {
        [QQSingerTab.song, .album, .video, .wiki].filter { tab in
            guard let node = detail[tab.node] as? [String: Any] else { return false }
            return node.values.contains { ($0 as? [Any])?.isEmpty == false }
        }
    }

    /// 歌手主页头那条要的 Android comm（见 `singerHomepage` 的说明）。
    // 写成计算属性而不是 `static let`：`[String: Any]` 不是 Sendable，当存储属性就是全局可变状态。
    // 这几个键值是每条请求都要现拼进去的，没有存下来的必要。
    private static var androidComm: [String: Any] { [
        "cv": 12060012, "ct": 11, "format": "json", "uin": 0, "g_tk": 5381,
    ] }

    // MARK: - 歌手主页各 tab

    /// 一页 tab 内容。四类内容各占一个数组，其余为空。
    struct QQSingerTabPage: Sendable {
        var tracks: [Track] = []
        var albums: [Album] = []
        var mvs: [MV] = []
        /// wiki tab 里的相似歌手（见下）
        var similarArtists: [Artist] = []
        /// wiki tab 里的分节文字（`{标题: 正文}`，如「简介」）
        var introductions: [(title: String, content: String)] = []
        var hasMore: Bool = false
    }

    /// 歌手主页某个 tab 的一页。
    /// `music.UnifiedHomepage.UnifiedHomepageSrv/GetHomepageTabDetail`
    /// （[QQMusicApi] `modules/singer.py::get_tab_detail`），param
    /// `{SingerMid, IsQueryTabDetail: 1, TabID, PageNum(**从 0 起**), PageSize, Order: 0}`。
    /// comm 与 `singerHomepage` 同（不带 Android comm 一样回 10000）。
    ///
    /// **响应形状要注意**：不管请求哪个 tab，`data` 里 `SongTab`/`AlbumTab`/`VideoTab`/
    /// `IntroductionTab`/`MomentTab`/`DiscTab`/… 十来个节点**永远都在**，
    /// 只有请求的那个才有内容——所以取数要按 `QQSingerTab.node` 去对应的键下取，
    /// 别遍历。`data.TabID` 会回显你请求的那个，可以拿来自检。
    ///
    /// [实测 2026-09-09 curl] 周杰伦，`PageSize: 2`、`PageNum: 0`，四个 tab 都 code 0：
    /// - `song_sing` → `SongTab.List[]`，条目是**标准歌曲对象**（不是 `{songInfo:…}` 包装），
    ///   `parseSongListItem` 两种都认，直接用；`HasMore: 1`；
    /// - `album` → `AlbumTab.AlbumList[]`，条目 `{albumMid, albumName, publishDate, totalNum,
    ///   albumID, singerName, albumType}`——正是 `parseSingerAlbum` 认的那一套；
    /// - `video` → `VideoTab.VideoList[]`，`{mvid, vid, title, picurl, duration, playcnt, pubdate}`
    ///   ——`parseMvListItem` 认的那一套；
    /// - `wiki` → `IntroductionTab.List[]` 6 条，按 `ItemType` 分：
    ///   2＝`SingerInfoList`（「简介」正文）、3＝精选歌曲、4＝精选视频、
    ///   6＝TA 的乐库、8＝艺人成就、**7＝`SimilarArtistsList`（相似艺人）**。
    ///   相似艺人这里也拿一份：与基线的 `similarArtists`（`music.SimilarSingerSvr`）
    ///   是两条不同的接口，这条附在主页里、不用额外请求，但只在 wiki tab 上有。
    func singerTab(artistID: String, tab: QQSingerTab,
                   page: Int = 0, pageSize: Int = 30) async -> QQSingerTabPage {
        let mid = artistID.rawID
        guard !mid.isEmpty else { return QQSingerTabPage() }
        guard let data = try? await musicu(
            module: "music.UnifiedHomepage.UnifiedHomepageSrv", method: "GetHomepageTabDetail",
            param: ["SingerMid": mid, "IsQueryTabDetail": 1, "TabID": tab.tabID,
                    "PageNum": max(0, page), "PageSize": pageSize, "Order": 0],
            commOverride: Self.androidComm) else { return QQSingerTabPage() }
        let node = data[tab.node] as? [String: Any] ?? [:]
        var result = QQSingerTabPage()
        result.hasMore = (data["HasMore"] as? Int ?? 0) == 1
        switch tab {
        case .song, .composer, .lyricist, .producer, .arranger, .musician:
            result.tracks = (node["List"] as? [[String: Any]] ?? [])
                .compactMap { Self.parseSongListItem($0) }
        case .album:
            result.albums = (node["AlbumList"] as? [[String: Any]] ?? [])
                .compactMap { Self.parseSingerAlbum($0) }
        case .video:
            result.mvs = (node["VideoList"] as? [[String: Any]] ?? [])
                .compactMap { Self.parseMvListItem($0) }
        case .wiki:
            for item in node["List"] as? [[String: Any]] ?? [] {
                for group in item["SingerInfoList"] as? [[String: Any]] ?? [] {
                    let title = group["Title"] as? String ?? ""
                    let content = group["Content"] as? String ?? ""
                    if !content.isEmpty { result.introductions.append((title, content)) }
                }
                for group in item["SimilarArtistsList"] as? [[String: Any]] ?? [] {
                    let list = (group["SingerList"] as? [String: Any])?["singerList"] as? [[String: Any]]
                    // 这一段的条目用的是 `mid` / `name`（不是 singer_mid），
                    // 正好落在 `parseArtist` 认的第二套键上
                    result.similarArtists += (list ?? []).compactMap { Self.parseArtist($0) }
                }
            }
            result.similarArtists = result.similarArtists.dedupedByID()
        }
        return result
    }

    // MARK: - 歌曲 / 专辑的带翻页版

    /// 歌手的全部歌曲（带翻页）。`musichall.song_list_server/GetSingerSongList`
    /// （[QQMusicApi] `modules/singer.py::get_songs_list`）。
    ///
    /// 与基线 `artistDetail` 里那条同一个 module/method——那条固定 `begin: 0`，
    /// 只要艺人页首屏那一屏；这条是「查看全部」用的，`offset` 由调用方推进。
    /// **`number` 不起作用**（文件头那条 ⚠️），所以这里不收页大小参数：
    /// 一页就是服务端给的 30 条，`total` 用来判断还有没有下一页。
    ///
    /// [实测 2026-09-09 curl] 周杰伦：`begin: 0` 与 `begin: 30` 各回 30 条、
    /// mid 交集为 0；`totalNum = 1012`（键名是 `totalNum`，参考实现 model 里写的
    /// `total_num` 是它自己的字段名，别照着找）。
    func singerSongs(artistID: String, offset: Int = 0) async -> (tracks: [Track], total: Int) {
        let mid = artistID.rawID
        guard !mid.isEmpty else { return ([], 0) }
        guard let data = try? await musicu(module: "musichall.song_list_server",
                                           method: "GetSingerSongList",
                                           param: ["singerMid": mid, "order": 1,
                                                   "number": Self.singerPageSize, "begin": offset],
                                           anonymous: true) else { return ([], 0) }
        let tracks = (data["songList"] as? [[String: Any]] ?? []).compactMap { Self.parseSongListItem($0) }
        return (tracks, data["totalNum"] as? Int ?? tracks.count)
    }

    /// 歌手的全部专辑（带翻页）。`music.musichallAlbum.AlbumListServer/GetAlbumList`
    /// （[QQMusicApi] `modules/singer.py::get_album_list`）。与上一条同样的关系与限制。
    ///
    /// [实测 2026-09-09 curl] 周杰伦：`total = 43`（这条的键叫 **`total`**，
    /// 不是歌曲那条的 `totalNum`——同一族接口两个写法）；`begin: 20` 回 23 条
    /// （43-20，正好是剩下的全部，说明一页 30 是上限不是定额）。
    func singerAlbums(artistID: String, offset: Int = 0) async -> (albums: [Album], total: Int) {
        let mid = artistID.rawID
        guard !mid.isEmpty else { return ([], 0) }
        guard let data = try? await musicu(module: "music.musichallAlbum.AlbumListServer",
                                           method: "GetAlbumList",
                                           param: ["singerMid": mid, "order": 1,
                                                   "number": Self.singerPageSize, "begin": offset],
                                           anonymous: true) else { return ([], 0) }
        let albums = (data["albumList"] as? [[String: Any]] ?? []).compactMap { Self.parseSingerAlbum($0) }
        return (albums, data["total"] as? Int ?? albums.count)
    }

    /// 请求里还是照参考实现把 `number` 带上（服务端忽略它，但少一个键不如照抄），
    /// 值取实测的那一页大小 30——这样至少「请求写的」与「实际拿到的」是一回事。
    static let singerPageSize = 30
}
