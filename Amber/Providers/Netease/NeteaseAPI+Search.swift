import Foundation

/// 搜索侧的补充：下拉建议、热搜榜、默认词、多类型匹配，外加一条更肥的搜索通道。
///
/// **这一批全走明文 `get`**，理由与 `NeteaseAPI` 顶上那段一样：逐条 curl 打过，
/// 匿名就给全量数据，换 eapi 一个字段都不会多，只会多一层加解密和一次匿名注册的等待。
/// 参考实现里它们标的是 `weapi`（`search_suggest` / `search_hot_detail` /
/// `search_multimatch`）或默认通道，Amber 这边统一落到明文 GET——`/api/*` 这条路
/// 对这些只读接口本来就是通的。
///
/// 搜索建议这一段的三条（`searchSuggestions` / `hotSearches` / `defaultSearchKeyword`）
/// 都是「给不出就返回空」：搜索框少一个下拉，不该让搜索本身失败。
extension NeteaseAPI: MusicSearchSuggesting {

    // MARK: - 搜索建议

    /// 搜索框下拉。`/api/search/suggest/web`，参数只有 `s`。
    /// [api-enhanced] `module/search_suggest.js`（`type=mobile` 走 `/keyword`，
    /// 其余走 `/web`；那边标的是 weapi，这里走明文 GET）
    ///
    /// [实测 2026-09-09 curl] `s=晴天` 匿名回 `code:200`，
    /// `result` 里有 `songs`(4) / `albums`(2) / `artists`(1) / `order`；
    /// `s=周杰伦` 那次还带 `playlists`——**每类都可能整个缺席**，所以逐类 optional 取，
    /// 缺了不算失败。`order` 是服务端建议的分组顺序（那次是
    /// `["songs","artists","albums"]`），照它排，别自己定死一个顺序。
    ///
    /// 曲目/专辑/艺人用的是明文接口那套字段（`artists` / `album` / `duration`），
    /// 现成的 `parseTrack` / `parseAlbum` / `parseArtist` 直接认。
    func searchSuggestions(keyword: String) async -> [SearchSuggestion] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let resp = try? await get("/api/search/suggest/web", params: ["s": trimmed]),
              let result = resp["result"] as? [String: Any] else { return [] }

        func list(_ key: String) -> [[String: Any]] { result[key] as? [[String: Any]] ?? [] }
        func suggestions(_ key: String) -> [SearchSuggestion] {
            switch key {
            case "songs":
                return list(key).compactMap { Self.parseTrack($0) }.map {
                    SearchSuggestion(id: $0.id, kind: .track, text: $0.title,
                                     subtitle: $0.albumName.isEmpty
                                        ? $0.artistName : "\($0.artistName) - \($0.albumName)")
                }
            case "albums":
                return list(key).compactMap { Self.parseAlbum($0) }.map {
                    SearchSuggestion(id: $0.id, kind: .album, text: $0.name, subtitle: $0.artistName)
                }
            case "artists":
                return list(key).compactMap { Self.parseArtist($0) }.map {
                    SearchSuggestion(id: $0.id, kind: .artist, text: $0.name, subtitle: nil)
                }
            case "playlists":
                return list(key).compactMap { Self.parsePlaylist($0) }.map {
                    SearchSuggestion(id: $0.id, kind: .playlist, text: $0.name,
                                     subtitle: $0.creatorName)
                }
            default:
                return []
            }
        }
        // order 里没提到的分类补在后面，免得服务端哪天多回一类就被我们吞掉
        let known = ["songs", "artists", "albums", "playlists"]
        let order = (result["order"] as? [String] ?? []).filter { known.contains($0) }
        return (order + known.filter { !order.contains($0) }).flatMap(suggestions)
    }

    /// 纯关键词建议（移动端那套）。`/api/search/suggest/keyword`，参数 `s`。
    /// [api-enhanced] `module/search_suggest.js` 的 `type=mobile` 分支
    ///
    /// [实测 2026-09-09 curl] `s=周杰伦` 匿名回 `code:200`，
    /// `result.allMatch` 6 条：`周杰伦 / 周杰伦歌单 / 周杰伦晴天 / 周杰伦稻香 /
    /// 周杰伦七里香 / 周杰伦青花瓷`，每条是 `{keyword, type, alg, …}`。
    ///
    /// 与上面那条是**两种下拉**，不是一条的两种参数：这条只给「你可能想搜的词」，
    /// 上面那条给的是能直接点进去的实体。Music 的搜索框两种都用，所以两条都留着。
    func searchKeywordSuggestions(keyword: String) async -> [SearchSuggestion] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let resp = try? await get("/api/search/suggest/keyword", params: ["s": trimmed]),
              let all = (resp["result"] as? [String: Any])?["allMatch"] as? [[String: Any]]
        else { return [] }
        return all.compactMap { item in
            guard let word = item["keyword"] as? String, !word.isEmpty else { return nil }
            return SearchSuggestion(id: "ne:kw:\(word)", kind: .keyword, text: word, subtitle: nil)
        }
    }

    /// PC 端的搜索建议。`/api/search/pc/suggest/keyword/get`，参数 **`keyword`**
    /// （不是 `s`）。[api-enhanced] `module/search_suggest_pc.js`
    ///
    /// [实测 2026-09-09 curl] `keyword=晴天` 匿名回 `code:200`，`data.recTitle` 是
    /// 「相关搜索」，`data.suggests` 10 条：`晴天 / 晴天周杰伦 / 晴天有点孤单玩具丢在旁边 /
    /// 晴天娃娃吴青峰 / …`。每条带 `highLightInfo`（一段 JSON 字符串，标了哪几段要高亮）、
    /// `iconUrl`、以及 `relatedResource`——头一条往往挂着艺人卡
    /// （`relatedResource.resourceType == "artist"`，里面是完整的艺人对象）。
    ///
    /// 这里只取词与副标题；`highLightInfo` 那层留给将来真做高亮时再解，
    /// 现在解出来也没有地方摆。
    func searchPCSuggestions(keyword: String) async -> [SearchSuggestion] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let resp = try? await get("/api/search/pc/suggest/keyword/get",
                                        params: ["keyword": trimmed]),
              let suggests = (resp["data"] as? [String: Any])?["suggests"] as? [[String: Any]]
        else { return [] }
        return suggests.compactMap { item in
            guard let word = item["keyword"] as? String, !word.isEmpty else { return nil }
            let related = item["relatedResource"] as? [String: Any]
            return SearchSuggestion(id: "ne:kw:\(word)", kind: .keyword, text: word,
                                    subtitle: related?["resourceName"] as? String)
        }
    }

    // MARK: - 热搜与默认词

    /// 热搜榜（带推荐语与角标的那份）。`/api/hotsearchlist/get`，**无参数**。
    /// [api-enhanced] `module/search_hot_detail.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl] 匿名回 `code:200`，`data` 一整排，每条形如
    /// `{"score":135697,"iconType":4,"searchWord":"教师节","iconUrl":"…png","content":"","url":""}`；
    /// 其中一条带推荐语（`content:"老弟落壳逆袭黑马"`）。
    ///
    /// 两个坑：`content` 常常是**空串而不是缺字段**（空串在榜单里会白占一行），
    /// `iconUrl` 只有「热/新」那几条才有——两者都折成 nil。
    /// 榜里没有单独的「显示词 / 搜索词」之分，`displayName` 就等于 `searchWord`。
    func hotSearches() async -> [HotSearchItem] {
        guard let resp = try? await get("/api/hotsearchlist/get"),
              let data = resp["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { item in
            guard let word = item["searchWord"] as? String, !word.isEmpty else { return nil }
            return HotSearchItem(
                keyword: word,
                displayName: word,
                note: (item["content"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                iconURL: (item["iconUrl"] as? String).flatMap {
                    $0.isEmpty ? nil : $0.httpsUpgraded
                },
                score: item["score"] as? Int ?? 0)
        }
    }

    /// 老的热门搜索（只有词，没有热度也没有推荐语）。`/api/search/hot`，参数 `type=1111`。
    /// [api-enhanced] `module/search_hot.js`
    ///
    /// [实测 2026-09-09 curl] 匿名回 `code:200`，`result.hots` 10 条，
    /// 每条是 `{"first":"教师节","second":1,"third":null,"iconType":1}`——**词在 `first`**，
    /// 其余三个字段没有可用的信息量。
    ///
    /// 榜单要摆得好看还得靠上面那条（有热度分和推荐语）；这条留着当兜底：
    /// 哪天 `hotsearchlist` 改了形状，至少还有一排词可用。`score` 一律给 0（接口不给，
    /// 不能瞎编一个）。
    func hotSearchKeywords() async -> [HotSearchItem] {
        guard let resp = try? await get("/api/search/hot", params: ["type": "1111"]),
              let hots = (resp["result"] as? [String: Any])?["hots"] as? [[String: Any]]
        else { return [] }
        return hots.compactMap { item in
            guard let word = item["first"] as? String, !word.isEmpty else { return nil }
            return HotSearchItem(keyword: word, displayName: word, note: nil,
                                 iconURL: nil, score: 0)
        }
    }

    /// 搜索框里的那句灰字。`/api/search/defaultkeyword/get`，**无参数**。
    /// [api-enhanced] `module/search_default.js`
    ///
    /// **通道要留神**：参考实现这条用的是 `createOption(query)`＝默认通道，而
    /// `util/request.js` 里默认通道在 `APP_CONF.encrypt` 为真时解析成 **eapi**，
    /// 不是明文——所以「参考实现走的哪条」这件事光看 module 文件是看不出来的。
    /// [实测 2026-09-09 curl(eapi 探针)] eapi 打这条匿名回的是**空响应体**，
    /// 反倒是明文 GET 好好的，所以这里走明文。
    ///
    /// [实测 2026-09-09 curl] 明文匿名回 `code:200`，
    /// `data = {"showKeyword":"🔥我不难过 最近很火哦","realkeyword":"我不难过", …}`。
    /// 两个键分工不同：`showKeyword` 是带 emoji 和吆喝的**展示串**，
    /// `realkeyword` 才是回车时真正去搜的词。搜索框的占位要的是展示串，
    /// 所以这里交 `showKeyword`，取不到才退到 `realkeyword`。
    func defaultSearchKeyword() async -> String? {
        guard let resp = try? await get("/api/search/defaultkeyword/get"),
              let data = resp["data"] as? [String: Any] else { return nil }
        let show = (data["showKeyword"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let real = (data["realkeyword"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return show ?? real
    }

    /// 多类型搜索（一次拿回「最匹配的那个艺人/专辑/歌单…」）。
    /// `/api/search/suggest/multimatch`，参数 `s`、`type`。
    /// [api-enhanced] `module/search_multimatch.js`（那边标的是 weapi，`type` 默认 1）
    ///
    /// [实测 2026-09-09 curl] 这条的脾气跟参考实现的默认值**打架**：
    /// `s=周杰伦&type=1` 与 `s=Jay Chou&type=1` 都只回 `{"result":{"orders":[]},"code":200}`，
    /// 把 `type` 整个去掉反而回得出东西——`s=蔡依林` 回 `result` 里有
    /// `artist`(1 条，完整艺人对象) / `voice`(1 条，声音节目) / `orders`。
    /// 所以这里**默认不发 `type`**，把它做成可选参数，谁想复现参考实现的行为自己传。
    ///
    /// 注意键名是**单数**（`artist` / `album` / `playlist` / `song`），跟
    /// `search/suggest/web` 的复数键不是一套。`orders` 是服务端给的分组顺序。
    func multiMatch(keyword: String, type: Int? = nil) async -> NeteaseMultiMatch {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return NeteaseMultiMatch() }
        var params = ["s": trimmed]
        if let type { params["type"] = "\(type)" }
        guard let resp = try? await get("/api/search/suggest/multimatch", params: params),
              let result = resp["result"] as? [String: Any] else { return NeteaseMultiMatch() }
        func list(_ key: String) -> [[String: Any]] { result[key] as? [[String: Any]] ?? [] }
        return NeteaseMultiMatch(
            artists: list("artist").compactMap { Self.parseArtist($0) },
            albums: list("album").compactMap { Self.parseAlbum($0) },
            playlists: list("playlist").compactMap { Self.parsePlaylist($0) },
            tracks: list("song").compactMap { Self.parseTrack($0) },
            orders: result["orders"] as? [String] ?? [])
    }

    // MARK: - cloudsearch：更肥的那条搜索

    /// `/api/cloudsearch/pc`：与现有 `searchTracks` 走的 `/api/search/get` 是**两条**接口，
    /// 参数一模一样（`s` / `type` / `limit` / `offset` / `total`），回的东西不一样。
    /// [api-enhanced] `module/cloudsearch.js`
    ///
    /// [实测 2026-09-09 curl] `s=晴天&type=1&limit=3` 匿名回 `code:200`，
    /// 每首歌带 `sq` / `h` / `privilege` 这些**老接口完全没有**的节点：
    /// `sq:{"br":1607018,"size":56037067,…}`、
    /// `privilege:{"maxBrLevel":"lossless","plLevel":"exhigh","fl":320000,…}`。
    /// 有了 `sq` / `hr`，`parseTrack` 的 `losslessAvailable` 就不再是 nil（未知）而是真值——
    /// 搜索结果里那颗无损标记只有走这条才点得亮。
    /// 字段用的是 v3 那套缩写（`ar` / `al` / `dt`），`parseTrack` 两套都认。
    ///
    /// **现有的 `searchTracks` 等五条这轮一个字没动**：上层在用它们，换通道是另一件事，
    /// 要换也该连着「搜索结果页怎么显示无损标记」一起改。这里只把新路铺好。
    ///
    /// type 表（照参考实现的注释）：1 单曲 / 10 专辑 / 100 歌手 / 1000 歌单 /
    /// 1002 用户 / 1004 MV / 1006 歌词 / 1009 电台 / 1014 视频。
    func cloudsearchTracks(keyword: String, limit: Int = 30, offset: Int = 0) async throws -> [Track] {
        let result = try await cloudsearch(keyword: keyword, type: 1, limit: limit, offset: offset)
        return (result["songs"] as? [[String: Any]] ?? []).compactMap { Self.parseTrack($0) }
    }

    /// 见 `cloudsearchTracks`。type=10，装在 `result.albums`。
    func cloudsearchAlbums(keyword: String, limit: Int = 30, offset: Int = 0) async throws -> [Album] {
        let result = try await cloudsearch(keyword: keyword, type: 10, limit: limit, offset: offset)
        return (result["albums"] as? [[String: Any]] ?? []).compactMap { Self.parseAlbum($0) }
    }

    /// 见 `cloudsearchTracks`。type=100，装在 `result.artists`。
    func cloudsearchArtists(keyword: String, limit: Int = 30, offset: Int = 0) async throws -> [Artist] {
        let result = try await cloudsearch(keyword: keyword, type: 100, limit: limit, offset: offset)
        return (result["artists"] as? [[String: Any]] ?? []).compactMap { Self.parseArtist($0) }
    }

    /// 见 `cloudsearchTracks`。type=1000，装在 `result.playlists`。
    func cloudsearchPlaylists(keyword: String, limit: Int = 30, offset: Int = 0) async throws -> [Playlist] {
        let result = try await cloudsearch(keyword: keyword, type: 1000, limit: limit, offset: offset)
        return (result["playlists"] as? [[String: Any]] ?? []).compactMap { Self.parsePlaylist($0) }
    }

    /// 见 `cloudsearchTracks`。type=1004，装在 `result.mvs`。
    func cloudsearchMVs(keyword: String, limit: Int = 30, offset: Int = 0) async throws -> [MV] {
        let result = try await cloudsearch(keyword: keyword, type: 1004, limit: limit, offset: offset)
        return (result["mvs"] as? [[String: Any]] ?? []).compactMap { Self.parseMV($0) }
    }

    /// cloudsearch 的公共部分。`total=true` 是照参考实现发的，服务端拿它决定回不回总数。
    private func cloudsearch(keyword: String, type: Int,
                             limit: Int, offset: Int) async throws -> [String: Any] {
        let resp = try await get("/api/cloudsearch/pc", params: [
            "s": keyword, "type": "\(type)",
            "limit": "\(limit)", "offset": "\(offset)", "total": "true",
        ])
        return resp["result"] as? [String: Any] ?? [:]
    }
}

/// `search/suggest/multimatch` 的一次结果。
///
/// 只有网易云有这种「一次把各类最佳匹配都给你」的接口，所以类型留在这个扩展文件里，
/// 不往 `ProviderAPIModels` 里凑（那儿只放两家都交得出来的）。
struct NeteaseMultiMatch: Sendable {
    var artists: [Artist] = []
    var albums: [Album] = []
    var playlists: [Playlist] = []
    var tracks: [Track] = []
    /// 服务端建议的分组顺序（`result.orders`）。空数组表示它没给意见。
    var orders: [String] = []

    var isEmpty: Bool {
        artists.isEmpty && albums.isEmpty && playlists.isEmpty && tracks.isEmpty
    }
}
