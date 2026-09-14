import Foundation

// QQ 音乐搜索侧的补充：热搜榜、智能补全、快速搜索、综合搜索。
// 移植来源：[QQMusicApi] `modules/search.py`。
//
// 这一整个文件的接口**匿名全部可用**，各方法上都有当天的 curl 实测记录。
// 与 `QQAPI.swift` 里那条 `search(keyword:type:…)`（DoSearchForQQMusicDesktop）不冲突：
// 那条是「按类型分页搜」，这里是「搜索框下拉」与「一次回多类型」。

extension QQAPI: MusicSearchSuggesting {

    // MARK: - 搜索框下拉

    /// 搜索框下拉里的建议。
    ///
    /// 两条接口拼一份：`complete`（关键词补全）打头，`quick_search`（直达条目）在后。
    /// 顺序是照 Music 的搜索下拉来的——上面几行是「你可能想搜的词」，下面才是
    /// 歌/专辑/艺人的直达条目。
    ///
    /// 协议约定「给不出就返回空」，所以两条各自吞错：补全挂了还能有直达，反过来也一样。
    func searchSuggestions(keyword: String) async -> [SearchSuggestion] {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        async let completions = searchCompletions(keyword: keyword)
        async let quick = quickSearch(keyword: keyword)
        return await (completions + quick).deduped { "\($0.kind.rawValue)|\($0.id)" }
    }

    /// 关键词补全。`music.smartboxCgi.SmartBoxCgi/GetSmartBoxResult`
    /// （[QQMusicApi] `modules/search.py::complete`）。
    ///
    /// param：`{search_id, query, num_per_page: 0, page_idx: 0}`。`num_per_page: 0`
    /// 不是笔误——参考实现就是这么传的，服务端照样给满一屏。
    ///
    /// [实测 2026-09-09 curl] 匿名 code=0，query「周杰伦」回 `items[]`：
    /// `hint`（纯文本词）、`hint_hilight`（带 `<em>` 的高亮版）、`res_type`、`type`、`score`。
    /// 里面混着几条 `jump_type=3` 的 AI 助手入口（`hint` 像「周杰伦中国风里最上头的歌」，
    /// `jump_url` 是 `qqmusic://` 的 scheme），那种点了在 Amber 里没有落点，按 `jump_url`
    /// 非空滤掉。
    func searchCompletions(keyword: String) async -> [SearchSuggestion] {
        guard let data = try? await musicu(module: "music.smartboxCgi.SmartBoxCgi",
                                           method: "GetSmartBoxResult",
                                           param: ["search_id": Self.searchID(),
                                                   "query": keyword,
                                                   "num_per_page": 0, "page_idx": 0]),
              let items = data["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item -> SearchSuggestion? in
            guard let hint = item["hint"] as? String, !hint.isEmpty else { return nil }
            guard (item["jump_url"] as? String ?? "").isEmpty else { return nil }
            return SearchSuggestion(id: hint, kind: .keyword, text: hint, subtitle: nil)
        }
    }

    /// 快速搜索（直达条目）。**这条不走 musicu**，是老式 HTTP GET
    /// `https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?key=<词>`
    /// （[QQMusicApi] `modules/search.py::quick_search` 用的是 `_build_http("GET", …)`）。
    ///
    /// [实测 2026-09-09 curl] 匿名 `code=0 subcode=0`，`data` 下四个桶
    /// `song` / `singer` / `album` / `mv`，各带 `count` 与 `itemlist`；
    /// 条目字段是 `docid` / `id` / `mid` / `name` / `singer` / `pic` / `vid`
    /// （key=周杰伦 → 歌 4、歌手 2、专辑 2、MV 2）。
    /// **mid 就是 Amber 要的那截**（歌/歌手/专辑取 `mid`，MV 取 `vid`），所以直达条目能直接点开。
    func quickSearch(keyword: String) async -> [SearchSuggestion] {
        var components = URLComponents(string: "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg")!
        components.queryItems = [.init(name: "key", value: keyword),
                                 .init(name: "format", value: "json")]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(Self.UA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await session.data(for: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["data"] as? [String: Any] else { return [] }

        func bucket(_ key: String, _ kind: SearchSuggestion.Kind,
                    idKey: String) -> [SearchSuggestion] {
            let list = (payload[key] as? [String: Any])?["itemlist"] as? [[String: Any]] ?? []
            return list.compactMap { item -> SearchSuggestion? in
                guard let id = item[idKey] as? String, !id.isEmpty,
                      let name = item["name"] as? String, !name.isEmpty else { return nil }
                let singer = (item["singer"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return SearchSuggestion(id: "qq:\(id)", kind: kind, text: name,
                                        // 歌手桶里 singer 与 name 是同一个人名，别重复摆一遍
                                        subtitle: kind == .artist ? nil : singer)
            }
        }
        return bucket("song", .track, idKey: "mid")
            + bucket("singer", .artist, idKey: "mid")
            + bucket("album", .album, idKey: "mid")
            + bucket("mv", .mv, idKey: "vid")
    }

    // MARK: - 热搜

    /// 热搜榜。`music.musicsearch.HotkeyService/GetHotkeyForQQMusicMobile`
    /// （[QQMusicApi] `modules/search.py::get_hotkey`）。
    ///
    /// [实测 2026-09-09 curl] 匿名 code=0，一次回 `vec_hotkey` **30 条**。
    /// 每条：`query`（真正拿去搜的词）、`title`（展示词，热搜这边两者一样）、
    /// `score`（**字符串**，如 "1038529"）、`description`（「正在热搜」「新专辑」这类推荐语）、
    /// `cover_pic_url`（http 的封面图）。
    /// `vec_reckey`（推荐词）匿名时是空表，所以搜索框的默认词不从这条接口来
    /// （`defaultSearchKeyword()` 保持协议默认的 nil，不拿热搜第一条硬顶——
    /// 那不是「默认词」，是另一回事）。
    ///
    /// 进 `catalogCache` 是有意的，虽然 `RequestCache` 的说明里写着「搜索不进这里」：
    /// 那条规矩挡的是**按关键词**的结果（每次输入都不一样，缓存只会给出旧答案）。
    /// 热搜榜没有关键词，是一份跟「巅峰榜」同性质的日更目录数据，
    /// 而搜索页每打开一次就要一遍，5 分钟内不重复发才是对的。
    /// 上面 `searchCompletions` / `quickSearch` 那两条带关键词的**没有进缓存**。
    func hotSearches() async -> [HotSearchItem] {
        await catalogCache.value(for: "qq:HotkeyService.GetHotkeyForQQMusicMobile") {
            guard let data = try? await self.musicu(module: "music.musicsearch.HotkeyService",
                                                    method: "GetHotkeyForQQMusicMobile",
                                                    param: ["search_id": Self.searchID()]),
                  let list = data["vec_hotkey"] as? [[String: Any]] else { return nil }
            return list.compactMap { item -> HotSearchItem? in
                guard let query = item["query"] as? String, !query.isEmpty else { return nil }
                let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let note = (item["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return HotSearchItem(
                    keyword: query,
                    displayName: title ?? query,
                    note: note,
                    iconURL: Self.httpsURL(item["cover_pic_url"] as? String),
                    // score 是字符串，取不到就是 0（模型的约定）
                    score: Int(item["score"] as? String ?? "") ?? 0)
            }
        } ?? []
    }

    // MARK: - 综合搜索

    /// 综合搜索的一页：五类结果 + 相关搜索词。
    ///
    /// `SearchResults` 是共享模型，装不下「相关搜索词」，所以外面再包一层
    /// （只有 QQ 这一家给这个东西，不往共享模型里塞）。
    struct GeneralSearch: Sendable {
        var results = SearchResults()
        /// 结果页底部那排「大家还在搜」
        var relatedKeywords: [String] = []
        /// 还有没有下一页（`meta.nextpage == -1` 表示到底了）
        var hasMore = false
    }

    /// 综合搜索。`music.adaptor.SearchAdaptor/do_search_v2`，`search_type=100`
    /// （[QQMusicApi] `modules/search.py::general_search`）。
    ///
    /// [实测 2026-09-09 curl] 匿名 code=0。query「周杰伦」、page_num=10 时
    /// `body` 下同时回：`item_song` 30 条、`singer` 3 条、`item_album` 3 条、
    /// `item_songlist` 5 条、`item_mv` 5 条、`item_related` 10 条相关词，
    /// `meta.nextpage=2`、`meta.nextpage_start` 是各类型各自的游标。
    ///
    /// **两个坑，都实测过**：
    /// ① `highlight: false` 照样带 `<em>` 标签（专辑的 `singer`、歌单的 `dissname`、
    ///    MV 的 `singername` 都是 `<em>周杰伦</em>`），所以一律走 `stripHighlight` 洗一遍；
    /// ② 各桶的字段名跟别处的搜索**不一样**：专辑是小写 `albummid`（不是 `albumMID`）、
    ///    歌单是 `logo`/`songnum`（不是 `imgurl`/`song_count`）、MV 是 `vid`/`mvname`/
    ///    `singername`（既不是搜索那套 `v_id`/`mv_name`，也不是列表那套 `title`/`singers`）。
    ///    所以这里各解各的，不硬塞给 `QQAPI.swift` 里现成的解析器。
    ///    只有歌曲那一桶是标准歌曲对象，`parseTrack` 直接认。
    func generalSearch(keyword: String, page: Int = 1, num: Int = 15) async -> GeneralSearch {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return GeneralSearch() }
        guard let data = try? await musicu(module: "music.adaptor.SearchAdaptor",
                                           method: "do_search_v2",
                                           param: ["searchid": Self.searchID(),
                                                   "search_type": 100,
                                                   "page_num": num,
                                                   "query": keyword,
                                                   "page_id": page,
                                                   "highlight": false,
                                                   "grp": true]),
              let body = data["body"] as? [String: Any] else { return GeneralSearch() }

        func items(_ key: String) -> [[String: Any]] {
            (body[key] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        }

        var search = GeneralSearch()
        search.results.tracks = items("item_song").compactMap { Self.parseTrack($0) }
        search.results.artists = items("singer").compactMap { Self.parseArtist($0) }
        search.results.albums = items("item_album").compactMap { Self.parseGeneralSearchAlbum($0) }
        search.results.playlists = items("item_songlist").compactMap { Self.parseGeneralSearchPlaylist($0) }
        search.results.mvs = items("item_mv").compactMap { Self.parseGeneralSearchMV($0) }
        search.relatedKeywords = items("item_related").compactMap {
            ($0["search_word"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let meta = data["meta"] as? [String: Any]
        search.hasMore = (meta?["nextpage"] as? Int ?? -1) != -1
        return search
    }

    /// 综合搜索的专辑桶（字段见 `generalSearch` 的坑②）。
    static func parseGeneralSearchAlbum(_ a: [String: Any]) -> Album? {
        guard let mid = a["albummid"] as? String, !mid.isEmpty else { return nil }
        let singers = a["singer_list"] as? [[String: Any]] ?? []
        let names = singers.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
        let artistName = names.isEmpty
            ? Self.stripHighlight(a["singer"] as? String ?? "")
            : names.joined(separator: " / ")
        return Album(
            id: "qq:\(mid)",
            kind: .qq,
            name: Self.stripHighlight(a["name"] as? String ?? "未知专辑"),
            artistName: artistName.isEmpty ? "未知歌手" : artistName,
            // singer_list 里只有数字 id 与名字，**没有 mid**，所以给不出艺人链接
            artistId: nil,
            artworkURL: Self.httpsURL(a["pic"] as? String) ?? Self.albumArtwork(mid),
            publishDate: (a["publish_date"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            trackCount: a["song_num"] as? Int ?? 0,
            description: nil)
    }

    /// 综合搜索的歌单桶。`dissid` 在这一桶里是**字符串**。
    static func parseGeneralSearchPlaylist(_ p: [String: Any]) -> Playlist? {
        let id = (p["dissid"] as? Int) ?? (p["dissid"] as? String).flatMap(Int.init)
        guard let id else { return nil }
        return Playlist(
            id: "qq:\(id)",
            kind: .qq,
            name: Self.stripHighlight(p["dissname"] as? String ?? "歌单"),
            coverURL: Self.httpsURL(p["logo"] as? String),
            // 这一桶的 description 是「99首 今晚月色很美 4.1亿次播放」这种拼串，
            // 不是歌单简介，摆到简介位上会很怪，所以不要
            description: nil,
            playCount: p["listennum"] as? Int ?? 0,
            trackCount: p["songnum"] as? Int ?? 0,
            creatorName: (p["nickname"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// 综合搜索的 MV 桶。id 里装 vid（取流只认它，见 `QQAPI.parseMV`）。
    static func parseGeneralSearchMV(_ m: [String: Any]) -> MV? {
        guard let vid = m["vid"] as? String, !vid.isEmpty else { return nil }
        return MV(
            id: "qq:\(vid)",
            kind: .qq,
            title: Self.stripHighlight(m["mvname"] as? String ?? ""),
            artistName: Self.stripHighlight(m["singername"] as? String ?? ""),
            coverURL: Self.httpsURL(m["pic"] as? String),
            duration: TimeInterval(m["duration"] as? Int ?? 0),
            webURL: URL(string: "https://y.qq.com/n/ryqq/mv/\(vid)")!)
    }

    // MARK: - 小工具

    /// 洗掉搜索结果里的高亮标签。只认 `<em>`／`</em>` 这一对——服务端就发这一种，
    /// 上正则或 HTML 解析纯属加戏。
    static func stripHighlight(_ text: String) -> String {
        guard text.contains("<em>") || text.contains("</em>") else { return text }
        return text.replacingOccurrences(of: "<em>", with: "")
            .replacingOccurrences(of: "</em>", with: "")
    }

    /// 搜索会话 id。参考实现（[QQMusicApi] `utils/common.py::get_searchID`）是
    /// `随机(1...20) * 18014398509481984 + 随机(0...4194304) * 4294967296 + 当天毫秒数`，
    /// 这里照搬。服务端只拿它做埋点串联，**不校验**（实测随手传 "87654321" 也照样 code=0），
    /// 但既然参考实现这么生成，就照它来，免得哪天服务端真开始看格式。
    static func searchID() -> String {
        let head = UInt64.random(in: 1...20) &* 18_014_398_509_481_984
        let mid = UInt64.random(in: 0...4_194_304) &* 4_294_967_296
        let millisOfDay = UInt64(Date().timeIntervalSince1970 * 1000) % (24 * 60 * 60 * 1000)
        return String(head &+ mid &+ millisOfDay)
    }
}
