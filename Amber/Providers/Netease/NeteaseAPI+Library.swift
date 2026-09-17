import Foundation

/// 网易云账号里的「收藏」读写。
///
/// 这一整个文件只做一件事：把 `MusicLibraryWriting` 那套动作接到网易云的订阅接口上。
///
/// **通道一律走 eapi。** 参考实现里这批接口大半标的是 `weapi`（`album_sub` /
/// `artist_sub` / `mv_sub` / `dj_sub` / `user_subcount` / `playlist_create`…），
/// Amber 没有 weapi 那条路，也不打算为这一批新造一条：eapi 是客户端自己的通道，
/// 同样的路径同样的参数都认。[实测 2026-09-09 curl(eapi 探针)] 逐条打过一遍，
/// 匿名时回的是 301「未登录」/ 302 / 400「参数错误」，**没有一条回 404**——
/// 这至少坐实了路径与参数名没写错（写错路径网易回的是 `404 接口未找到`，
/// 见 `mvStreamURL` 注释里 `/api/mv/url` 那次）。真正 200 的响应形状**没有实机验证过**，
/// 下面每条方法的注释里逐条标了。
///
/// **写操作一律先看登录态。** 未登录时直接抛 `.unavailable`，不发请求也不静默返回：
/// 服务端对匿名写请求回的是「系统错误」这种没法向用户复述的话，而且悄悄失败的收藏
/// 比报错的收藏危险得多——用户会以为已经收藏了。
extension NeteaseAPI: MusicLibraryWriting {

    // MARK: - 收藏 / 取消收藏

    /// 收藏与取消收藏。六类目标各走各的接口，路径尾巴由 `favorite` 决定。
    ///
    /// | 目标 | 路径 | 关键参数 | 出处 |
    /// |---|---|---|---|
    /// | track | `/api/v1/radio/like` | `alg=itembased, trackId, like, time=3` | `module/like_v1.js` |
    /// | album | `/api/album/sub` \| `/api/album/unsub` | `id` | `module/album_sub.js` |
    /// | artist | `/api/artist/sub` \| `/api/artist/unsub` | `artistId, artistIds=[id]` | `module/artist_sub.js` |
    /// | playlist | `/api/playlist/subscribe` \| `/unsubscribe` | `id` | `module/playlist_subscribe.js` |
    /// | mv | `/api/mv/sub` \| `/api/mv/unsub` | `mvId, mvIds=["id"]` | `module/mv_sub.js` |
    /// | radio | `/api/djradio/sub` \| `/api/djradio/unsub` | `id` | `module/dj_sub.js` |
    ///
    /// 两处「一个 id 要传两遍」（artist 的 `artistId`+`artistIds`、mv 的 `mvId`+`mvIds`）
    /// 不是参考实现写冗余了，是服务端两个字段都读，照抄。
    ///
    /// **红心这条与参考实现有出入，得记一笔**：`like_v1.js` 现在走的是 `xeapi` 通道
    /// 并带 `checkToken: v3`（反作弊 token）。Amber 没有 xeapi，也没有取 checkToken 的那套，
    /// 这里退回普通 eapi 打同一条路径。[实测 2026-09-09 curl(eapi 探针)] 匿名回
    /// `{"msg":null,"code":301}`——路径在、参数认，但**登录态下会不会因为缺 checkToken
    /// 被判为异常请求，没有验证过**。真扫码登录之后第一件事是把这条打一遍看回什么码。
    func setFavorite(_ target: FavoriteTarget, favorite: Bool) async throws {
        switch target {
        case .track(let id):
            guard let songID = Int(id.rawID) else { throw ProviderError.invalidResponse }
            // time=3 是客户端原样发的常量（不是秒数，参考实现里写死成字符串 "3"）
            try await write("/api/v1/radio/like", [
                ("alg", .string("itembased")), ("trackId", .int(songID)),
                ("like", .bool(favorite)), ("time", .string("3")),
            ], action: favorite ? "红心歌曲" : "取消红心")

        case .album(let id):
            try await write("/api/album/\(favorite ? "sub" : "unsub")",
                            [("id", .string(id.rawID))],
                            action: favorite ? "收藏专辑" : "取消收藏专辑")

        case .artist(let id):
            let raw = id.rawID
            try await write("/api/artist/\(favorite ? "sub" : "unsub")", [
                ("artistId", .string(raw)), ("artistIds", .string("[\(raw)]")),
            ], action: favorite ? "关注歌手" : "取消关注")

        case .playlist(let id):
            try await write("/api/playlist/\(favorite ? "subscribe" : "unsubscribe")",
                            [("id", .string(id.rawID))],
                            action: favorite ? "收藏歌单" : "取消收藏歌单")

        case .mv(let id):
            let raw = id.rawID
            try await write("/api/mv/\(favorite ? "sub" : "unsub")", [
                ("mvId", .string(raw)), ("mvIds", .string("[\"\(raw)\"]")),
            ], action: favorite ? "收藏 MV" : "取消收藏 MV")

        case .radio(let id):
            try await write("/api/djradio/\(favorite ? "sub" : "unsub")",
                            [("id", .string(Self.radioRawID(id)))],
                            action: favorite ? "订阅电台" : "取消订阅电台")
        }
    }

    // MARK: - 收藏列表

    /// 喜欢的歌曲 id 表（无序）。`/api/song/like/get`，参数只有 `uid`，走 eapi。
    /// [api-enhanced] `module/likelist.js`
    ///
    /// [实测 2026-09-09 curl] 明文 GET 那条路匿名回 `{"msg":null,"code":301}`，
    /// 换 eapi 打同一条（uid 填别人的公开账号 45441555）回 `{"ids":[],"checkPoint":…,"code":200}`
    /// ——**匿名时 code 是 200 但 ids 恒为空**，所以这条不能拿来当登录态判据，
    /// 那件事只有 `accountProfile()` 说了算（见 `validateCredential`）。
    ///
    /// 响应里的 `ids` 是裸的数字数组，这里统一加上 `ne:` 前缀交出去——调用方拿到的
    /// 永远是模型里那一个 id。
    func favoriteTrackIDs() async throws -> [String] {
        guard let uid = await currentUID() else {
            throw ProviderError.unavailable("请先登录网易云音乐账号，才能读取喜欢的歌曲")
        }
        let resp = try await eapi("/api/song/like/get", [("uid", .int(uid))])
        return (resp["ids"] as? [Int] ?? []).map { "ne:\($0)" }
    }

    /// 查一批歌在不在「我喜欢的音乐」里。`/api/song/like/check`，参数 `trackIds`
    /// （**JSON 数组的字符串形式**，不是逗号串），走 eapi。
    /// [api-enhanced] `module/song_like_check.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `trackIds=[1330348068]` 回
    /// `{"ids":[],"code":200}`。登录态下 `ids` 应当是「查询集合里已红心的那批」
    /// （参考实现的语义），**未实机验证过**——真要在界面上按它点亮红心之前，
    /// 先拿登录态对一遍这个键的含义（是「已红心的子集」还是「未红心的子集」）。
    ///
    /// 日常判红心走 `favoriteTrackIDs()` 一次拉全，这条只给「刚加载一屏、想少拉点」
    /// 的场景留着。
    func favoriteTrackIDs(checking trackIDs: [String]) async throws -> Set<String> {
        guard isLoggedIn else {
            throw ProviderError.unavailable("请先登录网易云音乐账号，才能查询红心状态")
        }
        let raw = trackIDs.map(\.rawID).filter { !$0.isEmpty }
        guard !raw.isEmpty else { return [] }
        let resp = try await eapi("/api/song/like/check",
                                  [("trackIds", .string("[" + raw.joined(separator: ",") + "]"))])
        return Set((resp["ids"] as? [Int] ?? []).map { "ne:\($0)" })
    }

    /// 已收藏专辑。`/api/album/sublist`，参数 `limit` / `offset` / `total=true`，走 eapi。
    /// [api-enhanced] `module/album_sublist.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"paidCount":0,"code":200}`
    /// ——**连 `data` 这个键都没有**，所以解析时不能拿「缺 data」当解析失败，
    /// 空表就是空表。登录态下 `data` 是专辑数组（`parseAlbum` 认的那套字段），
    /// **200 的形状未实机验证过**。
    func favoriteAlbums() async throws -> [Album] {
        try requireLogin("读取收藏的专辑")
        return try await paged("/api/album/sublist", key: "data").compactMap { Self.parseAlbum($0) }
    }

    /// 关注的歌手。`/api/artist/sublist`，参数同上，走 eapi。
    /// [api-enhanced] `module/artist_sublist.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"code":301,"message":"未登录"}`；
    /// 200 的形状未实机验证过，按参考实现是 `data` 里一批歌手对象。
    func favoriteArtists() async throws -> [Artist] {
        try requireLogin("读取关注的歌手")
        return try await paged("/api/artist/sublist", key: "data").compactMap { Self.parseArtist($0) }
    }

    /// 已收藏 MV。`/api/cloudvideo/allvideo/sublist`（**不是** `/api/mv/sublist`，
    /// 后者已经并进「全部视频」这条），参数 `limit` / `offset` / `total=true`，走 eapi。
    /// [api-enhanced] `module/mv_sublist.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回
    /// `{"code":301,"message":"系统错误",…}`；200 的形状未实机验证过。
    ///
    /// 这条的字段名跟 `parseMV` 认的那套**对不上**：视频接口给的是 `vid` / `title` /
    /// `coverUrl` / `durationms`，MV 接口给的是 `id` / `name` / `cover` / `duration`。
    /// 收藏夹里两种都可能出现（收藏的是 MV 还是 UGC 视频），所以这里先归一化再交给
    /// `parseMV`，而不是在 `parseMV` 里加分支——那条是搜索/目录页共用的，不该为
    /// 这一个收藏列表变形。
    func favoriteMVs() async throws -> [MV] {
        try requireLogin("读取收藏的 MV")
        return try await paged("/api/cloudvideo/allvideo/sublist", key: "data")
            .compactMap { Self.parseMV(Self.normalizedVideo($0)) }
    }

    /// 订阅的电台。`/api/djradio/get/subed`，参数 `limit` / `offset` / `total=true`，走 eapi。
    /// [api-enhanced] `module/dj_sublist.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回
    /// `{"count":0,"djRadios":[],"time":0,"hasMore":false,"code":200}`
    /// ——键名是 `djRadios` 不是 `data`，`hasMore` 也在顶层，翻页判据现成。
    /// 电台在 Amber 里就是一张 `Playlist`（id 形如 `ne:djradio:<id>`，见 `parseDJRadio`）。
    func favoriteRadios() async throws -> [Playlist] {
        try requireLogin("读取订阅的电台")
        return try await paged("/api/djradio/get/subed", key: "djRadios", pageSize: 30)
            .compactMap { Self.parseDJRadio($0) }
    }

    /// 各类收藏的条目数。`/api/subcount`，**无参数**，走 eapi。
    /// [api-enhanced] `module/user_subcount.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回**空响应体**（不是 JSON，连 code 都没有），
    /// 所以这条一定要登录；200 的形状未实机验证过，字段名照参考实现：
    /// `artistCount` / `mvCount` / `djRadioCount` / `createdPlaylistCount` /
    /// `subPlaylistCount` / `programCount`…
    ///
    /// **`subcount` 不给专辑数**（网易云自己的收藏页里专辑数是另算的），所以专辑那一格
    /// 另打一条 `album/sublist?limit=1` 读它的 `count`；喜欢的歌曲数也不在里面，
    /// 用 `favoriteTrackIDs()` 的条数顶。三条并发，一次刷新一共三个来回——
    /// 侧边栏角标不是热路径，比「少一个数字」划算。取不到的项留 nil，不折成 0
    /// （`FavoriteCounts` 的口径）。
    func favoriteCounts() async throws -> FavoriteCounts {
        try requireLogin("读取收藏计数")
        async let subcountTask = eapi("/api/subcount")
        async let albumTask = eapi("/api/album/sublist",
                                   [("limit", 1), ("offset", 0), ("total", true)])
        async let likedTask = favoriteTrackIDs()
        let sub = try? await subcountTask
        let albums = try? await albumTask
        let liked = try? await likedTask

        var counts = FavoriteCounts()
        counts.tracks = liked?.count
        counts.albums = albums?["count"] as? Int
        counts.artists = sub?["artistCount"] as? Int
        counts.mvs = sub?["mvCount"] as? Int
        counts.radios = sub?["djRadioCount"] as? Int
        // 自建 + 收藏两栏在网易云是分开数的，资料库侧栏只有一格「播放列表」，加起来
        if let created = sub?["createdPlaylistCount"] as? Int {
            counts.playlists = created + ((sub?["subPlaylistCount"] as? Int) ?? 0)
        }
        return counts
    }

    // MARK: - 歌单增删改

    /// 新建歌单。`/api/playlist/create`，参数 `name` / `privacy`（0 普通、10 隐私）/
    /// `type`（NORMAL / VIDEO / SHARED），走 eapi。
    /// [api-enhanced] `module/playlist_create.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回
    /// `{"code":301,"message":"系统错误",…}`；200 的形状未实机验证过，
    /// 按参考实现顶层有 `id`，另有一个完整的 `playlist` 对象。
    ///
    /// 交出来的 `Playlist` 优先用服务端回的那个对象（封面、创建者都齐），
    /// 只在它缺席时拿 `id` + 传进来的 `name` 拼一个最小的——**不能返回 nil 或者假 id**，
    /// 调用方拿到它就要直接跳详情页。
    func createPlaylist(name: String, isPrivate: Bool) async throws -> Playlist {
        try requireLogin("新建歌单")
        let resp = try await eapi("/api/playlist/create", [
            ("name", .string(name)),
            ("privacy", .string(isPrivate ? "10" : "0")),
            ("type", .string("NORMAL")),
        ])
        if let raw = resp["playlist"] as? [String: Any], let playlist = Self.parsePlaylist(raw) {
            return playlist
        }
        guard let id = (resp["id"] as? Int) ?? (resp["id"] as? String).flatMap(Int.init) else {
            throw ProviderError.invalidResponse
        }
        return Playlist(id: "ne:\(id)", kind: .netease, name: name)
    }

    /// 删除歌单。`/api/playlist/remove`，参数 `ids`（**JSON 数组的字符串形式**），走 eapi。
    /// [api-enhanced] `module/playlist_delete.js`
    ///
    /// 路径是 `remove` 不是 `delete`——名字与模块名对不上，别照模块名猜。
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"code":301,"message":"系统错误",…}`；
    /// 200 的形状未实机验证过。
    func deletePlaylist(_ playlistID: String) async throws {
        try await write("/api/playlist/remove",
                        [("ids", .string("[\(playlistID.rawID)]"))],
                        action: "删除歌单")
    }

    /// 改歌单名。`/api/playlist/update/name`，参数 `id` / `name`，走 eapi。
    /// [api-enhanced] `module/playlist_name_update.js`
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 301；200 的形状未实机验证过。
    func renamePlaylist(_ playlistID: String, name: String) async throws {
        try await write("/api/playlist/update/name",
                        [("id", .string(playlistID.rawID)), ("name", .string(name))],
                        action: "重命名歌单")
    }

    /// 改歌单简介。`/api/playlist/desc/update`，参数 `id` / **`desc`**（不是 description），
    /// 走 eapi。[api-enhanced] `module/playlist_desc_update.js`
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 301；200 的形状未实机验证过。
    func updatePlaylistDescription(_ playlistID: String, description: String) async throws {
        try await write("/api/playlist/desc/update",
                        [("id", .string(playlistID.rawID)), ("desc", .string(description))],
                        action: "修改歌单简介")
    }

    /// 往歌单里加歌。见 `manipulateTracks`。
    func addTracks(_ trackIDs: [String], to playlistID: String) async throws {
        try await manipulateTracks(op: "add", trackIDs: trackIDs, playlistID: playlistID)
    }

    /// 从歌单里删歌。见 `manipulateTracks`。
    func removeTracks(_ trackIDs: [String], from playlistID: String) async throws {
        try await manipulateTracks(op: "del", trackIDs: trackIDs, playlistID: playlistID)
    }

    /// 歌单排序（拖动我的歌单那一列）。`/api/playlist/order/update`，参数 `ids`
    /// （**JSON 数组的字符串形式**，按想要的先后排好），走 eapi。
    /// [api-enhanced] `module/playlist_order_update.js`（那边标的是 weapi）
    ///
    /// 签名是自拟的（协议里没有这一条）：吃一整串 Amber 形式的歌单 id，顺序即结果。
    /// 服务端按「整表覆盖」处理，所以**必须把全部自建歌单一次性发全**，
    /// 只发挪动的那两条会把没发的那些排到后面去。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"code":301,"message":"系统错误",…}`；
    /// 200 的形状未实机验证过。
    func reorderPlaylists(_ playlistIDs: [String]) async throws {
        let raw = playlistIDs.map(\.rawID).filter { !$0.isEmpty }
        guard !raw.isEmpty else { return }
        try await write("/api/playlist/order/update",
                        [("ids", .string("[" + raw.joined(separator: ",") + "]"))],
                        action: "调整歌单顺序")
    }

    // MARK: - 内部

    /// `/api/playlist/manipulate/tracks`：加歌与删歌是同一条，靠 `op` 分（add / del）。
    /// 参数 `op` / `pid`（歌单 id）/ `trackIds`（**JSON 数组的字符串形式**）/ `imme=true`，
    /// 走 eapi。[api-enhanced] `module/playlist_tracks.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回
    /// `{"code":301,"message":"系统错误",…,"msg":"系统错误"}`；200 的形状未实机验证过。
    ///
    /// **code 512 那条歪路照抄了参考实现**：网易云在某些情况下对这条回 512，
    /// 而把同一批 id 重复一遍再发就成了（参考实现里 `[...tracks, ...tracks]`）。
    /// 没有人知道服务端为什么这样，但那是唯一已知的绕法，所以这里也只在 512 时重试一次。
    ///
    /// 这条不能用 `eapi` 默认的「非 200 就抛」：要先看见 512 才能决定重试。
    /// 代价是绕开了 `eapi` 里的 301 自动注销逻辑，所以 301 在这里自己翻译成
    /// 「登录已过期」的话再抛——写操作悄悄失败比报错危险得多。
    private func manipulateTracks(op: String, trackIDs: [String], playlistID: String) async throws {
        try requireLogin(op == "add" ? "把歌加进歌单" : "从歌单里删歌")
        let raw = trackIDs.map(\.rawID).filter { !$0.isEmpty }
        guard !raw.isEmpty else { return }
        let pid = playlistID.rawID

        func send(_ ids: [String]) async throws -> Int {
            let resp = try await eapi("/api/playlist/manipulate/tracks", [
                ("op", .string(op)), ("pid", .string(pid)),
                ("trackIds", .string("[" + ids.joined(separator: ",") + "]")),
                ("imme", .string("true")),
            ], acceptsAnyCode: true)
            return resp["code"] as? Int ?? 200
        }

        var code = try await send(raw)
        if code == 512 { code = try await send(raw + raw) }
        guard code == 200 else {
            if code == 301 { throw ProviderError.api("网易云音乐登录已过期，请重新登录") }
            throw ProviderError.api("接口错误 code=\(code)")
        }
    }

    /// 写操作的统一入口：先看登录态，再走 eapi。
    /// `action` 是给用户看的动词短语（「收藏专辑」），拼进 `.unavailable` 的话里。
    @discardableResult
    private func write(_ path: String, _ body: [(String, NeteaseJSON)],
                       action: String) async throws -> [String: Any] {
        try requireLogin(action)
        return try await eapi(path, body)
    }

    private func requireLogin(_ action: String) throws {
        guard isLoggedIn else {
            throw ProviderError.unavailable("请先登录网易云音乐账号，才能\(action)")
        }
    }

    /// 当前账号 uid。凭证里存了登录时拿到的那个；老版本存下来的可能为空，
    /// 那就补打一条 `account/get`（与 `accountPlaylists` 同一套兜底）。
    func currentUID() async -> Int? {
        if let uid = credential?.uid { return uid }
        return try? await accountProfile().uid
    }

    /// 订阅列表的翻页。三条 sublist 的参数完全一样（`limit` / `offset` / `total`），
    /// 只有装数据的键名不同，所以并成一个。
    ///
    /// 停止条件按顺序看三样：顶层 `hasMore` 为假、这一页不满、页数到上限。
    /// 上限存在的理由很实在——收藏几千张专辑的账号是有的，但资料库一次刷新不该
    /// 打上百个来回；到顶就停，宁可少几条也不要把接口打成限流。
    private func paged(_ path: String, key: String,
                       pageSize: Int = 100, maxPages: Int = 20) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        for page in 0..<maxPages {
            let resp = try await eapi(path, [
                ("limit", .int(pageSize)), ("offset", .int(page * pageSize)), ("total", true),
            ])
            let items = resp[key] as? [[String: Any]] ?? []
            out += items
            if items.count < pageSize { break }
            if let hasMore = resp["hasMore"] as? Bool, !hasMore { break }
        }
        return out
    }

    /// `ne:djradio:123` / `ne:123` → `123`。
    /// 电台在 Amber 里带 `djradio:` 这一层（`parseDJRadio` 造的），而接口只认裸数字，
    /// `rawID` 只剥得掉 `ne:`，所以这里再剥一层。
    private static func radioRawID(_ id: String) -> String {
        let raw = id.rawID
        return raw.hasPrefix("djradio:") ? String(raw.dropFirst("djradio:".count)) : raw
    }

    /// 「全部视频」那套字段 → `parseMV` 认的字段。缺的键才补，已有的不动
    /// （收藏夹里混着真 MV 与 UGC 视频，前者本来就是对的形状）。
    private static func normalizedVideo(_ item: [String: Any]) -> [String: Any] {
        var out = item
        if out["id"] == nil, let vid = out["vid"] { out["id"] = vid }
        if out["name"] == nil, let title = out["title"] { out["name"] = title }
        if out["cover"] == nil, let cover = out["coverUrl"] { out["cover"] = cover }
        if out["duration"] == nil, let ms = out["durationms"] { out["duration"] = ms }
        if out["artistName"] == nil {
            // MV 给 artists / artistName，UGC 视频给 creator（一串作者）
            let creators = (out["creator"] as? [[String: Any]]) ?? []
            let names = creators.compactMap { ($0["userName"] ?? $0["nickname"]) as? String }
            if !names.isEmpty { out["artistName"] = names.joined(separator: " / ") }
        }
        return out
    }
}
