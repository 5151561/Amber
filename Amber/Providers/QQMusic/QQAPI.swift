import Foundation
import os

/// QQ音乐客户端。
///
/// 使用经典 `u.y.qq.com/cgi-bin/musicu.fcg` JSON 协议（POST `{"req_0": {module, method, param}}`）。
/// 实测匿名请求无需 sign/comm 即可返回数据；取流（UrlGetVkey）对免费歌曲返回 result=0，
/// 付费/VIP 曲目返回 104003。
final class QQAPI: MusicProvider {

    let kind: ProviderKind = .qq

    private static let gateway = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!
    static let UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    /// 登录态请求使用的客户端 UA（对齐 QQ 桌面客户端/qmdec）
    static let clientUA = "QQMusic/21"
    private static let fallbackCDN = "https://isure.stream.qqmusic.qq.com/"

    /// 登录态由 AppState 注入：返回当前凭证（可能为 nil）
    var credentialProvider: (() -> QQCredential?)?
    /// 音质偏好由 AppState 注入
    var qualityProvider: (() -> StreamQuality)?
    private static let log = Logger(subsystem: "com.changlepan.Amber", category: "QQAPI")

    /// 复核校验接口同一时刻只跑一条（见 `noteCredentialRejected`）。
    private let credentialProbe = OSAllocatedUnfairLock(initialState: false)

    /// 凭证过期回调（`GetLoginUserInfo` 复核确认失效时触发）。
    /// 必须声明成主线程回调：触发点在 URLSession 的后台续体上，接的那头要弹 toast、
    /// 改 @Published；不带 @MainActor 的话 Swift 5 下编译期不查，运行期就在后台线程动
    /// AppKit（`NSView.isHidden` 直接抛异常 → SIGABRT）。
    var onCredentialExpired: (@MainActor @Sendable () -> Void)?

    /// 普通请求会话（musicu 与 c.y.qq.com 上那几条老式 fcgi 都走它）
    let session: URLSession
    /// 目录类请求的缓存与去重（搜索/取流/歌词/登录态相关的都不进这里）
    let catalogCache = RequestCache()
    /// 不跟随重定向的会话（扫码登录换取 p_skey/code 时需要拦截 302）
    private let noRedirectSession: URLSession
    /// 每次请求的 guid
    private let guid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)

        let noRedirectConfig = URLSessionConfiguration.ephemeral
        noRedirectConfig.timeoutIntervalForRequest = 30
        noRedirectConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        noRedirectSession = URLSession(configuration: noRedirectConfig, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        // 用 completionHandler 那一版而不是 async 版：Swift 6.4（swiftlang-6.4.0.30.4）
        // 给 async 版的 @objc thunk 做 SILGen 时会段错误崩在
        // `SILGenFunction::emitNativeToForeignThunk`，整个 emit-module 挂掉。
        // 两版语义一样（都是「别跟随重定向」），这一版不经过那条会崩的代码路径。
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil) // 不跟随重定向，保留 Set-Cookie / Location 供解析
        }
    }

    // MARK: - 基础请求

    /// 登录态下带 comm/cookie（对齐 qmdec）：搜索类 ct=24，取流类 ct=1。
    /// commOverride 用于登录类请求（如 QQConnectLogin 只需 tmeLoginType）。
    func musicu(module: String, method: String, param: [String: Any],
                clientType: Int = 24, clientVersion: Int = 4747474,
                commOverride: [String: Any]? = nil,
                anonymous: Bool = false,
                verifiesCredential: Bool = false) async throws -> [String: Any] {
        let credential = anonymous ? nil : credentialProvider?()
        var payload: [String: Any] = [:]
        if let commOverride {
            payload["comm"] = commOverride
        } else if let credential {
            payload["comm"] = [
                "cv": clientVersion,
                "ct": clientType,
                "format": "json",
                "uin": Int(credential.uin.filter(\.isNumber)) ?? 0,
                "g_tk": 5381,
            ]
        }
        payload["req_0"] = ["module": module, "method": method, "param": param]

        var request = URLRequest(url: Self.gateway)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credential != nil ? Self.clientUA : Self.UA, forHTTPHeaderField: "User-Agent")
        if let credential {
            request.setValue(credential.cookie, forHTTPHeaderField: "Cookie")
        }
        request.setValue("https://y.qq.com/portal/player.html", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderError.api("请求失败")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let req0 = obj["req_0"] as? [String: Any] else {
            throw ProviderError.invalidResponse
        }
        if let code = req0["code"] as? Int, code != 0 {
            // 凭证过期类错误码。
            //
            // **104400 曾经在这个名单里，它不是过期码，是「参数非法」**：[实测 2026-09-06 curl]
            // `GetAlbumList` 传空 mid、或拿艺人名当 mid，一律回 104400，匿名 / 带 web comm /
            // 带 cookie 三种一模一样；同一个坏 mid 给 `GetSingerSongList` 反而回 code 0 空表。
            // 留在名单里的后果是资料库派生艺人（`Artist.libraryIDPrefix`，冒号后面是名字不是
            // mid）一打开就把刚登录的账号弹「登录已过期」——码表照抄 QQMusicApi 抄出来的账。
            if [1000, 104401].contains(code) {
                await noteCredentialRejected(module: module, method: method, code: code,
                                             authoritative: verifiesCredential)
                throw ProviderError.api("QQ音乐登录已过期，请重新登录")
            }
            throw ProviderError.api("接口错误 code=\(code)")
        }
        return (req0["data"] as? [String: Any]) ?? [:]
    }

    /// 「凭证被拒」只有**专用校验接口**说了算，别的接口回这三个码一律只当疑似。
    ///
    /// 起因（2026-09-06 实机）：艺人页一打开，刚登录的账号就被注销了。`markExpired()`
    /// 干的是 `credential = nil`，所以任意一条接口回这几个码都能把人踢下线——
    /// 而目录类接口拒掉一次请求实在算不上「登录过期」的证据，代价与证据完全不成比例。
    /// （那次的真凶是 104400，它压根不是过期码；这条复核是防下一个抄错的码表。）
    ///
    /// 现在非校验接口只触发一次 `GetLoginUserInfo` 复核，由它来决定注销与否；
    /// 同时把被拒的 module/method 记进日志，下次实机能直接指名道姓：
    /// `log stream --predicate 'subsystem == "com.changlepan.Amber"'`
    private func noteCredentialRejected(module: String, method: String, code: Int,
                                        authoritative: Bool) async {
        Self.log.error("凭证被拒 code=\(code, privacy: .public) \(module, privacy: .public)/\(method, privacy: .public) 判定=\(authoritative ? "直接注销" : "复核", privacy: .public)")
        if authoritative {
            await onCredentialExpired?()
            return
        }
        // 艺人页一次并发三条请求，全被拒时不该打三次校验。
        let alreadyProbing = credentialProbe.withLock { probing -> Bool in
            defer { probing = true }
            return probing
        }
        guard !alreadyProbing else { return }
        await validateCredential()
        credentialProbe.withLock { $0 = false }
    }

    /// 校验当前 cookie 还认不认。
    ///
    /// 取流和搜索这些接口在登录态失效时**不会**报错，服务端直接按匿名处理并照常返回数据，
    /// 界面上就一直显示「已登录」，只是 VIP 曲目全部取不到流。要发现这件事得主动打一个
    /// 必须登录才有数据的接口：失效时它回 1000，musicu 会顺手触发 onCredentialExpired。
    func validateCredential() async {
        guard credentialProvider?() != nil else { return }
        _ = try? await musicu(module: "music.UserInfo.userInfoServer", method: "GetLoginUserInfo",
                              param: [:], clientType: 1, clientVersion: 13030508,
                              verifiesCredential: true)
    }

    // MARK: - 解析

    static func parseTrack(_ s: [String: Any]) -> Track? {
        guard let mid = s["mid"] as? String, !mid.isEmpty else { return nil }
        let singers = s["singer"] as? [[String: Any]] ?? []
        let artistName = singers.compactMap { $0["name"] as? String }
            .filter { !$0.isEmpty }.joined(separator: " / ")
        let album = s["album"] as? [String: Any]
        let file = s["file"] as? [String: Any]
        let mediaMid = file?["media_mid"] as? String
        // file 节点里各档位的字节数；> 0 即音源有该档。flac/hires 对应无损与更高。
        let losslessSize = ["size_flac", "size_hires"]
            .compactMap { file?[$0] as? Int }
            .max() ?? 0
        return Track(
            id: "qq:\(mid)",
            kind: .qq,
            title: s["name"] as? String ?? s["songname"] as? String ?? "未知歌曲",
            artistName: artistName.isEmpty ? "未知歌手" : artistName,
            artistId: (singers.first?["mid"] as? String).map { "qq:\($0)" },
            albumName: album?["name"] as? String ?? "",
            albumId: (album?["mid"] as? String).map { "qq:\($0)" },
            artworkURL: (album?["mid"] as? String).flatMap { Self.albumArtwork($0) },
            duration: TimeInterval(s["interval"] as? Int ?? 0),
            // 专辑/歌单接口带碟内序号；搜索结果没有这两个键，留 nil
            trackNumber: s["index_album"] as? Int,
            discNumber: s["index_cd"] as? Int,
            mediaMid: (mediaMid?.isEmpty == false) ? mediaMid : nil,
            losslessAvailable: file == nil ? nil : losslessSize > 0)
    }

    /// QQ 分开给「曲风」与「语种」（如 Pop + 国语）；Apple Music 把两者合成
    /// Mandopop / Cantopop / J-Pop / K-Pop 这类标签，其余语种直接用曲风。
    static func genreLabel(genre: String?, language: String?) -> String? {
        let genre = genre?.trimmingCharacters(in: .whitespaces)
        guard let genre, !genre.isEmpty else { return nil }
        let prefixes = ["国语": "Mando", "粤语": "Canto", "日语": "J-", "韩语": "K-"]
        guard genre.caseInsensitiveCompare("Pop") == .orderedSame,
              let language, let prefix = prefixes[language] else { return genre }
        return prefix + (prefix.hasSuffix("-") ? "Pop" : "pop")
    }

    static func parseAlbum(_ a: [String: Any]) -> Album? {
        guard let mid = a["albumMID"] as? String, !mid.isEmpty else { return nil }
        return Album(
            id: "qq:\(mid)",
            kind: .qq,
            name: a["albumName"] as? String ?? "未知专辑",
            artistName: a["singerName"] as? String ?? "未知歌手",
            artistId: (a["singerMID"] as? String).map { "qq:\($0)" },
            artworkURL: a["albumPic"] as? String ?? Self.albumArtwork(mid),
            publishDate: a["publicTime"] as? String,
            trackCount: 0,
            description: nil)
    }

    static func parseSingerAlbum(_ a: [String: Any]) -> Album? {
        guard let mid = a["albumMid"] as? String, !mid.isEmpty else { return nil }
        return Album(
            id: "qq:\(mid)",
            kind: .qq,
            name: a["albumName"] as? String ?? "未知专辑",
            artistName: a["singerName"] as? String ?? "未知歌手",
            artistId: nil,
            artworkURL: Self.albumArtwork(mid),
            publishDate: a["publishDate"] as? String,
            // [实测 2026-09-06 curl] 列表项给 totalNum（曲目数）；艺人页「最新發行」
            // 卡上那行「N 首歌曲」靠它（网易走 size，本来就是全的）。
            trackCount: a["totalNum"] as? Int ?? 0,
            description: nil,
            // [实测 2026-09-06 curl] 周杰伦 43 张里给了 4 类：录音室专辑 / EP / Single /
            // 演唱会。艺人页按它拆「单曲和 EP」与「现场演出专辑」。
            albumType: a["albumType"] as? String)
    }

    static func parseArtist(_ a: [String: Any]) -> Artist? {
        guard let mid = a["singerMID"] as? String ?? a["mid"] as? String, !mid.isEmpty else { return nil }
        return Artist(
            id: "qq:\(mid)",
            kind: .qq,
            name: a["singerName"] as? String ?? a["name"] as? String ?? "未知歌手",
            avatarURL: a["singerPic"] as? String ?? Self.artistArtwork(mid),
            description: nil)
    }

    static func parseSearchPlaylist(_ p: [String: Any]) -> Playlist? {
        // dissid 在搜索结果里是字符串，歌单接口里是数字，两种情况都要兼容
        let id = (p["dissid"] as? Int) ?? (p["dissid"] as? String).flatMap(Int.init)
        guard let id else { return nil }
        return Playlist(
            id: "qq:\(id)",
            kind: .qq,
            name: p["dissname"] as? String ?? "歌单",
            coverURL: p["imgurl"] as? String,
            description: p["introduction"] as? String,
            playCount: p["listennum"] as? Int ?? 0,
            trackCount: p["song_count"] as? Int ?? 0,
            creatorName: (p["creator"] as? [String: Any])?["name"] as? String)
    }

    static func parseFeedPlaylist(_ item: [String: Any]) -> Playlist? {
        guard let pl = item["Playlist"] as? [String: Any],
              let basic = pl["basic"] as? [String: Any],
              let tid = basic["tid"] as? Int else { return nil }
        let cover = basic["cover"] as? [String: Any]
        let desc = (basic["desc"] as? String)?
            .replacingOccurrences(of: "<br>", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Playlist(
            id: "qq:\(tid)",
            kind: .qq,
            name: basic["title"] as? String ?? "歌单",
            coverURL: (cover?["small_url"] as? String) ?? (cover?["medium_url"] as? String),
            description: desc?.isEmpty == true ? nil : desc,
            playCount: 0,
            trackCount: 0,
            creatorName: (basic["creator"] as? [String: Any])?["nick"] as? String)
    }

    static func albumArtwork(_ mid: String) -> String {
        "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(mid).jpg"
    }

    static func artistArtwork(_ mid: String) -> String {
        "https://y.gtimg.cn/music/photo_new/T001R300x300M000\(mid).jpg"
    }

    /// 歌单/歌手/专辑接口里歌曲统一包在 songInfo 下
    static func parseSongListItem(_ item: [String: Any]) -> Track? {
        if let si = item["songInfo"] as? [String: Any] {
            var merged = si
            if merged["singer"] == nil { merged["singer"] = item["singer"] }
            if merged["album"] == nil { merged["album"] = item["album"] }
            return parseTrack(merged)
        }
        return parseTrack(item)
    }

    // MARK: - 搜索

    private func search(keyword: String, type: Int, limit: Int, offset: Int, bodyKey: String) async throws -> [[String: Any]] {
        let page = offset / max(limit, 1) + 1
        let data = try await musicu(
            module: "music.search.SearchCgiService",
            method: "DoSearchForQQMusicDesktop",
            param: ["query": keyword, "num_per_page": limit, "page_num": page, "search_type": type])
        let body = data["body"] as? [String: Any]
        return (body?[bodyKey] as? [String: Any])?["list"] as? [[String: Any]] ?? []
    }

    func searchTracks(keyword: String, limit: Int, offset: Int) async throws -> [Track] {
        try await search(keyword: keyword, type: 0, limit: limit, offset: offset, bodyKey: "song")
            .compactMap { Self.parseTrack($0) }
    }

    func searchAlbums(keyword: String, limit: Int, offset: Int) async throws -> [Album] {
        try await search(keyword: keyword, type: 2, limit: limit, offset: offset, bodyKey: "album")
            .compactMap { Self.parseAlbum($0) }
    }

    func searchArtists(keyword: String, limit: Int, offset: Int) async throws -> [Artist] {
        try await search(keyword: keyword, type: 1, limit: limit, offset: offset, bodyKey: "singer")
            .compactMap { Self.parseArtist($0) }
    }

    func searchPlaylists(keyword: String, limit: Int, offset: Int) async throws -> [Playlist] {
        try await search(keyword: keyword, type: 3, limit: limit, offset: offset, bodyKey: "songlist")
            .compactMap { Self.parseSearchPlaylist($0) }
    }

    func searchMVs(keyword: String, limit: Int, offset: Int) async throws -> [MV] {
        try await search(keyword: keyword, type: 4, limit: limit, offset: offset, bodyKey: "mv")
            .compactMap { Self.parseMV($0) }
    }

    /// 空串折成 nil，其余走公用的 http→https（见 ProviderHelpers）。
    static func httpsURL(_ url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        return url.httpsUpgraded
    }

    /// **id 里装的是 `vid`（那串字母数字），不是数字 `mv_id`**：取流的
    /// `GetMvUrls` 只认 vid，数字 id 在那条接口上没有落点。
    static func parseMV(_ m: [String: Any]) -> MV? {
        guard let vid = m["v_id"] as? String, !vid.isEmpty else { return nil }
        return MV(
            id: "qq:\(vid)",
            kind: .qq,
            title: m["mv_name"] as? String ?? "",
            artistName: m["singer_name"] as? String ?? "",
            coverURL: Self.httpsURL(m["mv_pic_url"] as? String),
            duration: TimeInterval((m["duration"] as? Int) ?? 0),
            webURL: URL(string: "https://y.qq.com/n/ryqq/mv/\(vid)")!)
    }

    /// MV 列表接口（GetAllocMvInfo / GetSingerMvList / GetSongRelatedMv）的条目。
    /// 字段跟搜索那套（v_id / mv_name / singer_name）**不同名**，是 vid / title / singers。
    /// id 同样装 vid（见 `parseMV`）。
    static func parseMvListItem(_ m: [String: Any]) -> MV? {
        guard let vid = m["vid"] as? String, !vid.isEmpty else { return nil }
        let singers = m["singers"] as? [[String: Any]] ?? []
        return MV(
            id: "qq:\(vid)",
            kind: .qq,
            title: m["title"] as? String ?? "",
            artistName: singers.compactMap { $0["name"] as? String }
                .filter { !$0.isEmpty }.joined(separator: " / "),
            coverURL: Self.httpsURL(m["picurl"] as? String),
            duration: TimeInterval((m["duration"] as? Int) ?? 0),
            webURL: URL(string: "https://y.qq.com/n/ryqq/mv/\(vid)")!)
    }

    // MARK: - 目录页取数

    /// 页面结构由 CatalogPages 定死（照 Apple Music），这里只按格子交数据。
    func catalogItems(_ slot: CatalogSlot) async -> CatalogSlotResult {
        switch slot {
        case .recentlyPlayed, .musicMemories:
            return .empty   // 本地资料库来的，页面自己填

        case .topPicks:
            // 电台/专辑/心情/歌单**交替**摆，配方在 CatalogSlotResult.topPicks。
            // QQ 的个人电台是「猜你喜欢」「随心听」（个性电台「热门」组的头两条），
            // 正对 Music 那两张个人电台卡；其余热门台排在后面备用。
            async let albums = newAlbums(from: 0, count: 4)
            async let groups = radioGroups()
            let (al, gr) = await (albums, groups)
            let hot = gr.first { $0.title == "热门" }?.stations ?? []
            let personalNames = ["猜你喜欢", "随心听"]
            let radios = hot.filter { personalNames.contains($0.name) }
                + hot.filter { !personalNames.contains($0.name) }
            let moods = gr.first { $0.title == "心情" }?.stations ?? []
            return .topPicks(radios: radios, moods: moods, albums: al)

        case .madeForYou:
            // Music 这一段是 Apple 自动生成的**个人混音歌单**（pl.pm-，醒神节拍/放松歌单/
            // 音乐新发现），只有 3 张。QQ 的对应物在客户端推荐流的功能入口行（shelf 301）里：
            // 「每日30首」「百万收藏」「新歌推荐」都是 type=500 的真歌单，带真 tid 和封面。
            // 不拿歌单广场的推荐流顶——那批是 UGC 标题，跟这一段不是一回事。
            return .init(items: .playlists(await personalMixes()))

        case .moodStations:
            let groups = await radioGroups()
            return .init(items: .playlists(groups.first { $0.title == "心情" }?.stations ?? []))
        case .stations:
            let groups = await radioGroups()
            return .init(items: .playlists(Array((groups.first { $0.title == "热门" }?.stations ?? [])
                .prefix(12))))

        case .latestReleases:
            // 「为你推荐最新作品」：新歌速递所属的专辑
            let albums = await newSongTracks().compactMap { track -> Album? in
                guard let albumId = track.albumId, !track.albumName.isEmpty else { return nil }
                return Album(id: albumId, kind: .qq, name: track.albumName,
                             artistName: track.artistName, artistId: track.artistId,
                             artworkURL: track.artworkURL, publishDate: nil,
                             trackCount: 0, description: nil)
            }
            return .init(items: .albums(albums.dedupedByID()))

        case .recommendedPlaylist:
            // 整宽大横幅，只要一张编辑歌单。推荐流 6..13 给「为你制作的歌单」、
            // 14..19 给探新 hero、24 起给「歌单已更新」，这里取最前面那张。
            return .init(items: .playlists(await recommendFeed(from: 0, size: 1)))

        case .tagged(let tag):
            // Music 长尾货架里主要是专辑：语种维度直接取该地区的新碟（area 参数）；
            // 曲风/场景没有按维度取专辑的接口，退回标签歌单；年代 QQ 没有，整段省掉。
            if let area = Self.albumArea(tag) {
                return .init(items: .albums(await newAlbums(from: 0, count: 12, area: area)))
            }
            guard let categoryID = Self.tagCategoryID(tag) else { return .empty }
            return .init(items: .playlists(await taggedPlaylists(categoryID, limit: 12)))

        case .moreLikeThis(let seeds):
            // Music 的「更多类似作品」段：种子是你听过的一首歌，段里装相似作品的**专辑**。
            // GetSimilarSongs 要数字 songid，而 Amber 的 QQ 曲目 id 是 mid，先换一次。
            for seed in seeds {
                let mid = seed.id.rawID
                guard let songID = await songID(mid: mid),
                      let data = try? await musicu(module: "music.recommend.TrackRelationServer",
                                                    method: "GetSimilarSongs",
                                                    param: ["songid": songID],
                                                    clientType: 11, clientVersion: 12060012),
                      let list = data["vecSong"] as? [[String: Any]] else { continue }
                let albums = list.compactMap { item -> Album? in
                    guard let track = item["track"] as? [String: Any],
                          let album = track["album"] as? [String: Any],
                          let albumMid = album["mid"] as? String, !albumMid.isEmpty,
                          let name = album["name"] as? String else { return nil }
                    let singers = track["singer"] as? [[String: Any]] ?? []
                    return Album(id: "qq:\(albumMid)", kind: .qq, name: name,
                                 artistName: singers.compactMap { $0["name"] as? String }
                                    .filter { !$0.isEmpty }.joined(separator: " / "),
                                 artistId: (singers.first?["mid"] as? String).map { "qq:\($0)" },
                                 artworkURL: Self.albumArtwork(albumMid),
                                 publishDate: nil, trackCount: 0, description: nil)
                }
                let deduped = albums.dedupedByID()
                if !deduped.isEmpty {
                    let seedAlbum: Album = Album(
                        id: seed.albumId ?? seed.id, kind: seed.kind,
                        name: seed.albumName.isEmpty ? seed.title : seed.albumName,
                        artistName: seed.artistName, artistId: seed.artistId,
                        artworkURL: seed.artworkURL, publishDate: nil,
                        trackCount: 0, description: nil)
                    return .init(items: .albums(deduped), title: seed.title,
                                 headline: "更多类似作品", seedArtworkURL: seed.artworkURL,
                                 seedAlbum: seedAlbum)
                }
            }
            return .empty

        case .cityCharts:
            // QQ 巅峰榜里的地区榜（内地/港台/欧美/日本/韩国），落在同一格
            return .init(items: .playlists(Array(await toplists().dropFirst(6).prefix(12))))

        case .featured:
            // 探新顶部：官方出品歌单。GetRecommendFeed 是清一色 UGC（is_official 全 false），
            // 「抖音最火」那类标题上不得编辑位（同 topPicks 不收推荐流歌单的规矩）。
            let picked = await officialEditorPlaylists()
            guard picked.count >= 6 else {
                return .init(items: .playlists(Array(await recommendFeed(from: 14, size: 6))))
            }
            let featured = await heroDescriptions(for: Array(picked.prefix(6)))
            var eyebrows: [String: String] = [:]
            featured.forEach { eyebrows[$0.id] = "官方歌单" }
            return .init(items: .playlists(featured), eyebrows: eyebrows)

        case .artistSpotlights:
            guard let data = try? await musicu(module: "music.musichallSinger.SingerList",
                                               method: "GetSingerListIndex",
                                               param: ["area": -100, "sex": -100, "genre": -100,
                                                       "index": -100, "sin": 0, "cur_page": 1],
                                               clientType: 11, clientVersion: 12060012),
                  let list = data["singerlist"] as? [[String: Any]] else { return .empty }
            return .init(items: .artists(list.prefix(12).compactMap { Self.parseSingerListItem($0) }))

        case .newSongs:
            let tracks = await newSongTracks()
            return .init(items: .tracks(Array(tracks.prefix(20))),
                         seeAll: ChartCatalog.charts(for: .qq).first { $0.name == "新歌榜" }
                            .map { ChartCatalog.playlist(for: $0, kind: .qq) })
        case .trendingSongs:
            return await chartSlot(playlistID: "qq:top:62")   // 飙升榜
        case .popularSongs:
            return await chartSlot(playlistID: "qq:top:26")   // 热歌榜

        case .newReleases(let page):
            return .init(items: .albums(await newAlbums(from: page * 24, count: 24)))

        case .updatedPlaylists:
            // 与顶部 hero 共用官方打捞流：hero 取头 6 条，这里往后取。
            // 打捞不足（官方条目太少）就退回推荐流补差额，别让货架塌掉。
            let official = await officialEditorPlaylists()
            let rest = Array(official.dropFirst(6).prefix(24))
            guard rest.count >= 12 else {
                let pad = await recommendFeed(from: 24, size: max(1, 24 - rest.count))
                return .init(items: .playlists(rest + pad))
            }
            return .init(items: .playlists(rest))

        case .charts:
            return .init(items: .playlists(await toplists()))

        case .browseGroups:
            return .init(items: .tagGroups(await tagGroups()))

        case .artistShares:
            // Music 这一段是 MV + 访谈；QQ 没有访谈，用 MV 列表顶（条目类型一致）。
            // area 实测是个摆设：-1..100 挨个试过，返回的都是同一批 total=1000 的表，
            // 分不了地区；order=1 取最新。
            guard let data = try? await musicu(module: "MvService.MvInfoProServer",
                                               method: "GetAllocMvInfo",
                                               param: ["area": 15, "version": 0, "order": 1,
                                                       "start": 0, "size": 12],
                                               clientType: 11, clientVersion: 12060012),
                  let list = data["list"] as? [[String: Any]] else { return .empty }
            return .init(items: .mvs(list.compactMap { Self.parseMvListItem($0) }))

        case .radioEpisodes:
            // QQ 的长音频是广播剧/有声书，跟 Music 的电台单集不是一回事，不拿来顶
            return .empty

        case .radioFeatured:
            let groups = await radioGroups()
            return .init(items: .playlists(Array((groups.first { $0.title == "热门" }?.stations ?? [])
                .prefix(4))))
        case .radioStations(let page):
            // Music 中国区两条都叫「风格电台」，这里用 QQ 的曲风组与主题组各填一条
            let wanted = ["曲风", "主题"]
            guard page < wanted.count else { return .empty }
            let groups = await radioGroups()
            return .init(items: .playlists(groups.first { $0.title == wanted[page] }?.stations ?? []))
        }
    }

    /// Music 的曲风/年代/语种/场景段 → QQ 歌单标签 categoryId
    /// （`fcg_get_diss_tag_conf`）。QQ 没有年代标签，那两段整段省掉。
    /// 语种维度 → 新碟接口的 area。实测 1 内地 / 2 港台 / 3 欧美 / **4 韩国 / 5 日本**
    /// （4、5 跟常见文档里写的反了，按实际返回的歌手对的）。
    private static func albumArea(_ tag: CatalogTag) -> Int? {
        switch tag {
        case .mandopop: return 1
        case .cantopop: return 2
        case .western: return 3
        case .kpop: return 4
        case .jpop: return 5
        default: return nil
        }
    }

    /// 曲风/场景维度 → 歌单标签 categoryId（`fcg_get_diss_tag_conf`）。
    /// QQ 没有年代标签，那两段整段省掉。
    private static func tagCategoryID(_ tag: CatalogTag) -> Int? {
        switch tag {
        case .alternative: return 218 // 后摇
        case .electronic: return 24
        case .cafe: return 223        // 咖啡馆
        default: return nil
        }
    }

    /// 按标签取歌单走老版 fcg（musicu 的 PlaylistSquare 不认标签参数）
    /// 分类浏览页：标签 id 是 categoryId
    func playlists(tag: CatalogTagRef) async -> [Playlist] {
        await taggedPlaylists(Int(tag.id) ?? 0, limit: 30)
    }

    /// 歌单标签配置：分组（语种/流派/主题/心情/场景）+ 组内标签的 categoryId。
    /// 组名在 `categoryGroupName`（不是 categoryName，那个在组这一层是空的）；
    /// 标签名带 HTML 实体（`R&#38;B`），要还原。
    private func tagGroups() async -> [CatalogTagGroup] {
        await catalogCache.value(for: "qq:fcg_get_diss_tag_conf") { await self.loadTagGroups() } ?? []
    }

    private func loadTagGroups() async -> [CatalogTagGroup]? {
        var components = URLComponents(
            string: "https://c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_tag_conf.fcg")!
        components.queryItems = [
            .init(name: "format", value: "json"), .init(name: "inCharset", value: "utf8"),
            .init(name: "outCharset", value: "utf-8"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(Self.UA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await session.data(for: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let categories = (obj["data"] as? [String: Any])?["categories"] as? [[String: Any]]
        else { return nil }
        return categories.compactMap { group in
            guard let name = group["categoryGroupName"] as? String else { return nil }
            let tags = (group["items"] as? [[String: Any]] ?? []).compactMap { item -> CatalogTagRef? in
                guard let id = item["categoryId"] as? Int,
                      let tagName = item["categoryName"] as? String else { return nil }
                return CatalogTagRef(id: "\(id)", name: Self.unescaped(tagName))
            }
            // 「热门」组只有一条「全部」，不成一组
            guard tags.count > 1 else { return nil }
            return CatalogTagGroup(id: "qq-\(name)", kind: .qq, name: name, tags: tags)
        }
    }

    /// 标签名里的数字实体（`R&#38;B` → `R&B`）
    private static func unescaped(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "&#"), let end = rest[start.upperBound...].firstIndex(of: ";") {
            result += rest[..<start.lowerBound]
            let digits = rest[start.upperBound..<end]
            if let code = UInt32(digits), let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            }
            rest = rest[rest.index(after: end)...]
        }
        return result + rest
    }

    private func taggedPlaylists(_ categoryID: Int, limit: Int) async -> [Playlist] {
        await catalogCache.value(for: "qq:fcg_get_diss_by_tag?cat=\(categoryID)&limit=\(limit)") {
            await self.loadTaggedPlaylists(categoryID, limit: limit)
        } ?? []
    }

    private func loadTaggedPlaylists(_ categoryID: Int, limit: Int) async -> [Playlist]? {
        var components = URLComponents(string: "https://c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_by_tag.fcg")!
        components.queryItems = [
            .init(name: "format", value: "json"), .init(name: "inCharset", value: "utf8"),
            .init(name: "outCharset", value: "utf-8"), .init(name: "picmid", value: "1"),
            .init(name: "categoryId", value: "\(categoryID)"), .init(name: "sortId", value: "5"),
            .init(name: "sin", value: "0"), .init(name: "ein", value: "\(limit - 1)"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(Self.UA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await session.data(for: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (obj["data"] as? [String: Any])?["list"] as? [[String: Any]] else { return nil }
        return list.compactMap { Self.parseSearchPlaylist($0) }
    }

    /// 歌单广场的推荐流。`From` 是游标（服务端 FromLimit 400），各段各取一截，
    /// 免得同一页出现同一批歌单。
    private func recommendFeed(from: Int, size: Int) async -> [Playlist] {
        await catalogCache.value(for: "qq:PlaylistSquare.GetRecommendFeed?from=\(from)&size=\(size)") {
            guard let data = try? await self.musicu(module: "music.playlist.PlaylistSquare",
                                                    method: "GetRecommendFeed",
                                                    param: ["From": from, "Size": size]),
                  let list = data["List"] as? [[String: Any]] else { return nil }
            return list.compactMap { Self.parseFeedPlaylist($0) }
        } ?? []
    }

    /// 官方出品（QQ音乐官方歌单）的打捞名单：分类 categoryId 按产出密度排
    /// （2026-09-06 各分类热榜 top30 实测：嘻哈 6 / 影视 5 / 爵士 5 / 流行 4 / 古典 4 …，
    /// 全部、古风、情歌等一批是 0 条，不进名单）。
    private static let officialFishingCategories = [
        153, 133, 21, 6, 27, 167, 116, 168, 166, 15, 28, 24, 223, 165,
    ]

    /// 官方出品歌单流。官方没有独立的列表接口（servedDiss / GetCreator 一类都 500003），
    /// 只在各分类热榜里零散露头，所以并发出各分类 30 条再过滤、去重、合成一条流，
    /// 新发现顶部 hero（头 6 条）与「歌单已更新」（后 24 条）共用。
    /// 合成按分类**轮转**取（嘻哈一条→影视一条→爵士一条…），不是串完一桶再下一桶——
    /// 密度高的分类会灌满头部，顶栏清一色说唱就没编辑气质了。
    private func officialEditorPlaylists() async -> [Playlist] {
        await withTaskGroup(of: (Int, [Playlist]).self) { group in
            for id in Self.officialFishingCategories {
                group.addTask { (id, await self.taggedPlaylists(id, limit: 30)) }
            }
            var buckets: [Int: [Playlist]] = [:]
            for await (id, list) in group { buckets[id] = list }
            var queues = Self.officialFishingCategories.map { id in
                (buckets[id] ?? []).filter { $0.creatorName?.contains("官方") == true }
            }
            var seen = Set<String>()
            var official: [Playlist] = []
            var exhausted = false
            while !exhausted {
                exhausted = true
                for queue in queues.indices where !queues[queue].isEmpty {
                    let playlist = queues[queue].removeFirst()
                    if seen.insert(playlist.id).inserted { official.append(playlist) }
                    exhausted = false
                }
            }
            return official
        }
    }

    /// hero 卡图上那行编辑语（Music 的 description-on-image）。标签热榜的 introduction
    /// 是空串（2026-09-06 实测），拿轻量歌单详情（song_num=1，只要 dirinfo.desc）补；
    /// 取不到就留空，不挡货架。
    private func heroDescriptions(for playlists: [Playlist]) async -> [Playlist] {
        await withTaskGroup(of: (Int, String?).self) { group in
            for (index, playlist) in playlists.enumerated() {
                group.addTask { (index, await self.lightPlaylistDescription(playlist)) }
            }
            var descs = [String?](repeating: nil, count: playlists.count)
            for await (index, desc) in group { descs[index] = desc }
            var filled = playlists
            for (index, desc) in descs.enumerated() where desc != nil {
                filled[index].description = desc
            }
            return filled
        }
    }

    private func lightPlaylistDescription(_ playlist: Playlist) async -> String? {
        guard let disstid = Int(playlist.id.rawID) else { return nil }
        return await catalogCache.value(for: "qq:CgiGetDiss.desc?\(disstid)") {
            guard let data = try? await self.musicu(module: "music.srfDissInfo.DissInfo",
                                                    method: "CgiGetDiss",
                                                    param: ["disstid": disstid, "dirid": 0,
                                                            "tag": false, "song_begin": 0,
                                                            "song_num": 1, "userinfo": false,
                                                            "orderlist": false,
                                                            "onlysonglist": true]),
                  let dir = data["dirinfo"] as? [String: Any],
                  let desc = dir["desc"] as? String else { return nil }
            let cleaned = desc.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    /// QQ 版的「为你制作的歌单」：客户端首页推荐流（`get_recommend_feed`）的**功能入口行**里
    /// 那几张 type=500 的歌单卡（每日30首 / 百万收藏 / 新歌推荐）。
    /// 要 Android comm（ct=11 / cv=12060012）+ 登录态；卡上带真 tid 与封面，能点开。
    /// 入口行里还有 type=700（电台「猜你喜欢」）与 type=900（雷达模式这类功能页），这里只取歌单。
    private func personalMixes() async -> [Playlist] {
        guard let data = try? await musicu(module: "music.recommend.RecommendFeed",
                                           method: "get_recommend_feed",
                                           param: ["From": 0, "Size": 10],
                                           clientType: 11, clientVersion: 12060012),
              let shelves = data["v_shelf"] as? [[String: Any]] else { return [] }
        let cards = shelves.flatMap { shelf in
            (shelf["v_niche"] as? [[String: Any]] ?? [])
                .flatMap { ($0["v_card"] as? [[String: Any]]) ?? [] }
        }
        return cards.compactMap { card -> Playlist? in
            guard (card["type"] as? Int) == 500,
                  let id = card["id"] as? String, id != "0", !id.isEmpty,
                  let title = card["title"] as? String, !title.isEmpty else { return nil }
            let cover = (card["cover"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Playlist(id: "qq:\(id)", kind: .qq, name: title,
                            coverURL: cover, creatorName: "QQ音乐")
        }.dedupedByID()
    }

    /// 个性电台分组（热门/心情/主题/场景/曲风/语言/人群/乐器…），一次请求全拿。
    private func radioGroups() async -> [(id: String, title: String, stations: [Playlist])] {
        // 「专属精选推荐 / 心情电台 / 电台 / 广播精选 / 风格电台」五个格子要的是同一张表。
        await catalogCache.value(for: "qq:pf.radiosvr.GetRadiolist") {
            await self.loadRadioGroups()
        } ?? []
    }

    private func loadRadioGroups() async -> [(id: String, title: String, stations: [Playlist])]? {
        guard let data = try? await musicu(module: "pf.radiosvr", method: "GetRadiolist",
                                           param: ["ct": "24"]),
              let groups = data["radio_list"] as? [[String: Any]] else { return nil }
        return groups.compactMap { group in
            guard let id = group["id"] as? Int, let title = group["title"] as? String else { return nil }
            let stations = (group["list"] as? [[String: Any]] ?? []).compactMap { Self.parseRadio($0) }
            guard !stations.isEmpty else { return nil }
            return ("group-\(id)", title, stations)
        }
    }

    /// 电台台号打 `qq:radio:` 前缀，playlistDetail 会走电台歌曲流（见 radioDetail），
    /// 于是「点开即播」跟歌单走同一条路，不用额外的电台详情页。
    /// 歌手列表接口的条目（字段名跟搜索/详情那套不一样，是 singer_mid / singer_name / singer_pic）
    ///
    /// 头像那一格原先写的是 `(s["singer_pic"] as? String) ?? artistArtwork(mid)`，
    /// **空串是合法 String，`??` 永远不触发**，回退形同虚设。
    /// [实测 2026-09-09 curl] `GetSingerList`（分类歌手页那条）的每一项 `singer_pic`
    /// 都是空串，照原样走会得到一批 `avatarURL == ""` 的歌手；目录页用的
    /// `GetSingerListIndex` 恰好给了地址，所以一直没暴露出来。
    /// 顺带：它给的是 `http://`，这里补一道 `httpsURL`，与 QQAPI 别处的图一致。
    static func parseSingerListItem(_ s: [String: Any]) -> Artist? {
        guard let mid = s["singer_mid"] as? String, !mid.isEmpty else { return nil }
        let pic = (s["singer_pic"] as? String).flatMap { $0.isEmpty ? nil : Self.httpsURL($0) }
        return Artist(id: "qq:\(mid)", kind: .qq,
                      name: s["singer_name"] as? String ?? "未知歌手",
                      avatarURL: pic ?? Self.artistArtwork(mid),
                      description: nil)
    }

    /// mid → 数字 songid（相似歌曲这类接口只认数字 id）
    func songID(mid: String) async -> Int? {
        guard let data = try? await musicu(module: "music.trackInfo.UniformRuleCtrl",
                                            method: "CgiGetTrackInfo",
                                            param: ["mids": [mid], "types": [0]]),
              let track = (data["tracks"] as? [[String: Any]])?.first else { return nil }
        return track["id"] as? Int
    }

    static func parseRadio(_ r: [String: Any]) -> Playlist? {
        guard let id = r["id"] as? Int else { return nil }
        return Playlist(
            id: "qq:radio:\(id)",
            kind: .qq,
            name: r["title"] as? String ?? "电台",
            coverURL: r["pic_url"] as? String,
            description: nil,
            playCount: r["listenNum"] as? Int ?? 0,
            trackCount: 0,
            creatorName: "电台")
    }

    /// 新碟上架（`area` 1=内地/2=港台/3=欧美/4=日本/5=韩国，0 是全部；翻页用 `start`——
    /// 接口也认 `sin`，但那个键是摆设，传什么都回第一页）。
    private func newAlbums(from: Int, count: Int, area: Int = 0) async -> [Album] {
        await catalogCache.value(for: "qq:get_new_album_info?area=\(area)&start=\(from)&num=\(count)") {
            guard let data = try? await self.musicu(module: "newalbum.NewAlbumServer",
                                                    method: "get_new_album_info",
                                                    param: ["area": area, "start": from, "num": count]),
                  let albums = data["albums"] as? [[String: Any]] else { return nil }
            return albums.compactMap { Self.parseNewAlbum($0) }
                .sorted { ($0.publishDate ?? "") > ($1.publishDate ?? "") }
        } ?? []
    }

    static func parseNewAlbum(_ a: [String: Any]) -> Album? {
        guard let mid = a["mid"] as? String, !mid.isEmpty else { return nil }
        let singers = a["singers"] as? [[String: Any]] ?? []
        let artistName = singers.compactMap { $0["name"] as? String }
            .filter { !$0.isEmpty }.joined(separator: " / ")
        return Album(
            id: "qq:\(mid)",
            kind: .qq,
            name: a["name"] as? String ?? "未知专辑",
            artistName: artistName.isEmpty ? "未知歌手" : artistName,
            artistId: (singers.first?["mid"] as? String).map { "qq:\($0)" },
            artworkURL: Self.albumArtwork(mid),
            publishDate: a["release_time"] as? String,
            trackCount: (a["ex"] as? [String: Any])?["track_nums"] as? Int ?? 0,
            description: nil)
    }

    /// 新歌速递。这里固定要**内地**那一档（`type: 1`）。
    ///
    /// 频道号别照旧注释记：那份写的是「1=内地/2=港台/3=欧美/4=韩国/5=日本」，与接口自己
    /// 回的频道表对不上。[实测 2026-09-09 curl] 响应里的 `lanlist` 是权威表——
    /// **5=最新 / 1=内地 / 6=港台 / 2=欧美 / 4=韩国 / 3=日本**。枚举写在
    /// `QQAPI+Recommend.NewSongChannel`，要换档从那儿取。
    private func newSongTracks() async -> [Track] {
        // 「为你推荐最新作品」与「新歌」两个格子共用这一条。
        await catalogCache.value(for: "qq:get_new_song_info?type=1") {
            guard let data = try? await self.musicu(module: "newsong.NewSongServer",
                                                    method: "get_new_song_info",
                                                    param: ["type": 1]),
                  let list = data["songlist"] as? [[String: Any]] else { return nil }
            return list.compactMap { Self.parseTrack($0) }
        } ?? []
    }

    /// 巅峰榜目录
    private func toplists() async -> [Playlist] {
        // 「排行榜」与「城市榜」两个格子共用这一条。
        await catalogCache.value(for: "qq:musicToplist.GetAll") { await self.loadToplists() } ?? []
    }

    private func loadToplists() async -> [Playlist]? {
        guard let data = try? await musicu(module: "music.musicToplist.Toplist",
                                           method: "GetAll", param: [:]),
              let groups = data["group"] as? [[String: Any]] else { return nil }
        return groups.flatMap { $0["toplist"] as? [[String: Any]] ?? [] }.prefix(12).compactMap { t in
            guard let topId = t["topId"] as? Int else { return nil }
            let rawCover = (t["headPicUrl"] as? String) ?? (t["frontPicUrl"] as? String)
            return Playlist(id: "qq:top:\(topId)", kind: .qq,
                            name: t["title"] as? String ?? "排行榜",
                            coverURL: Self.httpsURL(rawCover),
                            creatorName: "排行榜")
        }
    }

    // MARK: - 账号歌单

    /// 账号级的两项缓存。`accountPlaylists` 里 `async let` 与 TaskGroup 会并发碰它们，
    /// QQAPI 又不是 actor（调用方遍布界面层），所以用锁包住这两个可变字段。
    private struct AccountCache {
        /// 加密 uin（euin）。收藏类接口只认它，数字 uin 会回 80050；
        /// 而扫码登录只落了数字 uin，所以从「我喜欢」的返回里捞（`encrypt_login`）。
        var encryptedUin: String?
        /// 账号昵称 + 头像：自建歌单拿昵称当创建者显示，侧栏底部那颗按钮两样都要。
        var profile: QQAccountProfile?
    }
    private let accountCache = OSAllocatedUnfairLock(initialState: AccountCache())

    /// 手上有没有凭证。注入的 `credentialProvider` 直读 `QQLoginStore.credential`，
    /// 与边栏那句「已登录」是同一个来源。
    var isLoggedIn: Bool { credentialProvider?() != nil }

    /// 已登录账号的歌单：先自建（`GetPlaylistByUin`，收数字 uin），
    /// 再收藏（`CgiGetPlaylistFavInfo`，收 euin）。
    ///
    /// 这两条都只读；往账号里写是另外两套协议的事（`MusicLibraryWriting` /
    /// `MusicTasteWriting`），每一处写入都由用户在菜单上点出来。
    func accountPlaylists() async -> [Playlist] {
        guard let credential = credentialProvider?() else { return [] }
        let uin = credential.uin.filter(\.isNumber)
        guard !uin.isEmpty else { return [] }

        async let nickname = accountNickname()
        var result = await createdPlaylists(uin: uin, nickname: nickname)
        if let euin = await encryptedUin(uin: uin) {
            let existing = Set(result.map(\.id))
            result += await favoritePlaylists(euin: euin).filter { !existing.contains($0.id) }
        }
        return result
    }

    private func accountNickname() async -> String? {
        await accountProfile()?.nickname
    }

    /// 已登录账号的昵称与头像。`GetLoginUserInfo` 一条就都有了：
    /// [实测 2026-09-08 `-qqplaylistprobe`] `info.nick` = 昵称、
    /// `info.logo` = `http://thirdqq.qlogo.cn/g?…&s=140`（140px 的方图，升到 https 照样回 200）。
    func accountProfile() async -> QQAccountProfile? {
        if let cached = accountCache.withLock({ $0.profile }) { return cached }
        guard credentialProvider?() != nil,
              let data = try? await musicu(module: "music.UserInfo.userInfoServer",
                                           method: "GetLoginUserInfo", param: [:],
                                           clientType: 1, clientVersion: 13030508),
              let info = data["info"] as? [String: Any],
              let nick = info["nick"] as? String, !nick.isEmpty else { return nil }
        let profile = QQAccountProfile(nickname: nick,
                                       avatarURL: Self.httpsURL(info["logo"] as? String))
        accountCache.withLock { $0.profile = profile }
        return profile
    }

    /// 换号／注销时清掉账号级缓存：euin 与昵称头像都是「上一个人」的，留着会串号。
    func resetAccountCache() {
        accountCache.withLock { $0 = AccountCache() }
    }

    /// 「我喜欢」（dirid 201）用数字 uin 就能打，返回里的 `encrypt_login` 就是 euin。
    func encryptedUin(uin: String) async -> String? {
        if let cached = accountCache.withLock({ $0.encryptedUin }) { return cached }
        guard let data = try? await musicu(
            module: "music.srfDissInfo.DissInfo", method: "CgiGetDiss",
            param: ["disstid": 0, "dirid": 201, "tag": false, "song_begin": 0, "song_num": 1,
                    "userinfo": true, "orderlist": true, "enc_host_uin": uin],
            clientType: 11, clientVersion: 12060012),
            let euin = data["encrypt_login"] as? String, !euin.isEmpty else { return nil }
        accountCache.withLock { $0.encryptedUin = euin }
        return euin
    }

    /// 自建歌单。字段名跟别处都不一样：`dirName` / `songNum` / `picUrl`（不是 title/songnum/logo）。
    private func createdPlaylists(uin: String, nickname: String?) async -> [Playlist] {
        guard let data = try? await musicu(module: "music.musicasset.PlaylistBaseRead",
                                           method: "GetPlaylistByUin", param: ["uin": uin],
                                           clientType: 11, clientVersion: 12060012),
              let list = data["v_playlist"] as? [[String: Any]] else { return [] }
        return list.compactMap { item -> Playlist? in
            guard let tid = item["tid"] as? Int, tid > 0,
                  item["invalid"] as? Bool != true else { return nil }
            let name = (item["dirName"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let cover = [item["picUrl"], item["bigpicUrl"], item["albumPicUrl"]]
                .compactMap { $0 as? String }.first { !$0.isEmpty }
            return Playlist(id: "qq:\(tid)", kind: .qq, name: name,
                            coverURL: Self.httpsURL(cover),
                            description: (item["desc"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                            trackCount: item["songNum"] as? Int ?? 0,
                            creatorName: nickname,
                            // 这一条走的是「自建歌单」接口，回来的每一份都写得进去
                            // （收藏来的那批在 `favoritePlaylists` 里，那边不标）。
                            isOwned: true)
        }
    }

    /// 收藏的歌单（别人的公开歌单 + 官方歌单，如「每日30首」）。
    private func favoritePlaylists(euin: String, size: Int = 100) async -> [Playlist] {
        guard let data = try? await musicu(module: "music.musicasset.PlaylistFavRead",
                                           method: "CgiGetPlaylistFavInfo",
                                           param: ["uin": euin, "offset": 0, "size": size],
                                           clientType: 11, clientVersion: 12060012),
              let list = data["v_list"] as? [[String: Any]] else { return [] }
        return list.compactMap { item -> Playlist? in
            guard let tid = item["tid"] as? Int, tid > 0 else { return nil }
            let name = (item["name"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let cover = [item["logo"], item["albumPicUrl"]]
                .compactMap { $0 as? String }.first { !$0.isEmpty }
            return Playlist(id: "qq:\(tid)", kind: .qq, name: name,
                            coverURL: Self.httpsURL(cover),
                            trackCount: item["songnum"] as? Int ?? 0,
                            creatorName: (item["nickname"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    // MARK: - 详情

    func playlistDetail(_ playlist: Playlist) async throws -> PlaylistDetail {
        if playlist.id.hasPrefix("qq:top:") {
            return try await toplistDetail(playlist)
        }
        if playlist.id.hasPrefix("qq:radio:") {
            return try await radioDetail(playlist)
        }
        // 主接口可能被风控，失败时回退到老版 fcg 接口；
        // 两条都挂就把**主接口**的错抛出去——兜底那条只会说「接口返回异常」，没有信息量。
        do {
            return try await dissDetail(playlist)
        } catch {
            if let fallback = try? await legacyPlaylistDetail(playlist) { return fallback }
            throw error
        }
    }

    /// 一次最多取多少首。QQ 歌单上限 1000 首，服务端给多少就返多少（要几首给几首）。
    private static let dissSongLimit = 1000

    private func dissDetail(_ playlist: Playlist) async throws -> PlaylistDetail {
        // disstid **必须是数字**：传字符串时服务端一律回 code=10004，
        // 于是每次点开歌单都退到老 fcg 兜底，兜底再挂就是界面上的「接口返回异常」。
        guard let disstid = Int(playlist.id.rawID) else { throw ProviderError.invalidResponse }
        // onlysonglist=true 只回歌曲，dirinfo 里标题/封面/简介/播放量全是空的，所以要 false。
        let data = try await musicu(
            module: "music.srfDissInfo.DissInfo",
            method: "CgiGetDiss",
            param: ["disstid": disstid, "dirid": 0, "tag": true, "song_begin": 0,
                    "song_num": Self.dissSongLimit,
                    "userinfo": true, "orderlist": true, "onlysonglist": false])
        let dir = data["dirinfo"] as? [String: Any]
        let tracks = (data["songlist"] as? [[String: Any]] ?? []).compactMap { Self.parseTrack($0) }
        guard !tracks.isEmpty else { throw ProviderError.invalidResponse }
        // dirinfo 的字段名是 title / picurl / host_nick（不是老 fcg 那套 dissname / logo）
        let rawCover = (dir?["picurl"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? (dir?["picurl2"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? playlist.coverURL
            ?? tracks.first?.artworkURL
        let creator = ((dir?["creator"] as? [String: Any])?["nick"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? (dir?["host_nick"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? playlist.creatorName
        let p = Playlist(
            id: playlist.id,
            kind: .qq,
            name: (dir?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? playlist.name,
            coverURL: Self.httpsURL(rawCover),
            description: (dir?["desc"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? playlist.description,
            playCount: dir?["listennum"] as? Int ?? playlist.playCount,
            trackCount: (data["total_song_num"] as? Int) ?? (dir?["songnum"] as? Int) ?? tracks.count,
            creatorName: creator)
        return PlaylistDetail(playlist: p, tracks: tracks)
    }

    /// 老版 fcg 歌单接口（无需 musicu 网关），作为 CgiGetDiss 被风控时的兜底
    private func legacyPlaylistDetail(_ playlist: Playlist) async throws -> PlaylistDetail {
        let rawID = playlist.id.rawID
        let urlString = "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg"
            + "?type=1&json=1&utf8=1&onlysong=0&disstid=\(rawID)"
            + "&format=json&inCharset=utf8&outCharset=utf8&notice=0&platform=yqq.json&needNewCode=0"
        var request = URLRequest(url: URL(string: urlString)!)
        request.setValue(Self.UA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderError.api("请求失败")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["code"] as? Int == 0,
              let cd = (obj["cdlist"] as? [[String: Any]])?.first else {
            throw ProviderError.invalidResponse
        }
        let tracks = (cd["songlist"] as? [[String: Any]] ?? []).compactMap { item -> Track? in
            // 老接口字段名与 musicu 不同：songmid/songname/albummid/albumname
            var converted: [String: Any] = item
            if converted["mid"] == nil { converted["mid"] = item["songmid"] }
            if converted["name"] == nil { converted["name"] = item["songname"] }
            if converted["interval"] == nil { converted["interval"] = item["interval"] }
            let album: [String: Any] = [
                "mid": item["albummid"] as Any,
                "name": item["albumname"] as Any,
            ]
            converted["album"] = album
            return Self.parseTrack(converted)
        }
        let rawCover = (cd["logo"] as? String)
            ?? (cd["picurl"] as? String)
            ?? playlist.coverURL
            ?? tracks.first?.artworkURL
        let p = Playlist(
            id: playlist.id,
            kind: .qq,
            name: cd["dissname"] as? String ?? playlist.name,
            coverURL: Self.httpsURL(rawCover),
            description: playlist.description,
            playCount: playlist.playCount,
            trackCount: tracks.count,
            creatorName: playlist.creatorName)
        return PlaylistDetail(playlist: p, tracks: tracks)
    }

    private func toplistDetail(_ playlist: Playlist) async throws -> PlaylistDetail {
        let topId = String(playlist.id.dropFirst("qq:top:".count))
        let data = try await musicu(
            module: "music.musicToplist.Toplist",
            method: "GetDetail",
            param: ["topId": Int(topId) ?? 0, "offset": 0, "num": 50, "withTags": true])
        let info = (data["data"] as? [String: Any]) ?? (data["info"] as? [String: Any])
        let tracks = (data["songInfoList"] as? [[String: Any]] ?? []).compactMap { Self.parseTrack($0) }
        let rawCover = (info?["headPicUrl"] as? String)
            ?? (info?["frontPicUrl"] as? String)
            ?? (info?["mbHeadPicUrl"] as? String)
            ?? (info?["mbFrontPicUrl"] as? String)
            ?? playlist.coverURL
            ?? tracks.first?.artworkURL
        let cover = Self.httpsURL(rawCover)
        let p = Playlist(
            id: playlist.id,
            kind: .qq,
            name: (info?["title"] as? String) ?? playlist.name,
            coverURL: cover,
            description: (info?["intro"] as? String) ?? playlist.description,
            playCount: (info?["listenNum"] as? Int) ?? playlist.playCount,
            trackCount: (info?["totalNum"] as? Int) ?? tracks.count,
            creatorName: "排行榜")
        return PlaylistDetail(playlist: p, tracks: tracks)
    }

    /// 电台详情：电台是无限流，一次取一批当曲目列表用（`firstplay` 让服务端从头给）。
    private func radioDetail(_ playlist: Playlist) async throws -> PlaylistDetail {
        let radioID = Int(playlist.id.dropFirst("qq:radio:".count)) ?? 0
        let data = try await musicu(module: "pf.radiosvr", method: "GetRadiosonglist",
                                    param: ["id": radioID, "firstplay": 1, "num": 30])
        let tracks = (data["track_list"] as? [[String: Any]] ?? []).compactMap { Self.parseTrack($0) }
        let p = Playlist(
            id: playlist.id,
            kind: .qq,
            name: playlist.name,
            coverURL: playlist.coverURL,
            description: playlist.description,
            playCount: playlist.playCount,
            trackCount: tracks.count,
            creatorName: playlist.creatorName)
        return PlaylistDetail(playlist: p, tracks: tracks)
    }

    func albumDetail(_ album: Album) async throws -> AlbumDetail {
        let mid = album.id.rawID
        // 一页最多 50 首，`totalNum` 是整张碟的曲目数，超了就接着往下翻——
        // 双碟／演唱会实况动辄二三十首，合辑更多，一页封顶会**少歌**。
        // [实测 2026-09-08 curl] 窗口按 `begin` 稳定推进，既不重复也不漏。
        var songItems: [[String: Any]] = []
        while true {
            let songsData = try await musicu(
                module: "music.musichallAlbum.AlbumSongList",
                method: "GetAlbumSongList",
                param: ["albumMid": mid, "begin": songItems.count, "num": 50])
            let page = songsData["songList"] as? [[String: Any]] ?? []
            songItems += page
            let total = songsData["totalNum"] as? Int ?? songItems.count
            if page.isEmpty || songItems.count >= total { break }
        }
        // 回来的顺序不是曲序，得自己排（原因见 `sortedByAlbumOrder`）。
        let tracks = songItems.compactMap { Self.parseSongListItem($0) }.sortedByAlbumOrder()

        var finalAlbum = album
        if let infoData = try? await musicu(
            module: "music.musichallAlbum.AlbumInfoServer",
            method: "GetAlbumDetail",
            param: ["albumMId": mid]),
           let basic = infoData["basicInfo"] as? [String: Any] {
            finalAlbum = Album(
                id: album.id,
                kind: .qq,
                name: basic["albumName"] as? String ?? album.name,
                artistName: album.artistName,
                artistId: album.artistId,
                artworkURL: album.artworkURL ?? Self.albumArtwork(mid),
                publishDate: basic["publishDate"] as? String ?? album.publishDate,
                trackCount: tracks.count,
                description: basic["desc"] as? String,
                genre: Self.genreLabel(genre: basic["genreNew"] as? String,
                                       language: basic["language"] as? String))
        }
        return AlbumDetail(album: finalAlbum, tracks: tracks)
    }

    /// 艺人页的三条请求**一律匿名**（不带 comm / 不带 Cookie）。
    ///
    /// 歌手的热门歌曲、专辑列表、头图简介都是公开目录数据，票据换不来更多东西，
    /// [实测 curl] 这三条连 comm 都不带也全部 code 0、数据完整——不递票据，也就没得可拒。
    ///
    /// 顺带记一笔破案经过：实机上「一打开艺人页就报登录已过期」与票据无关，
    /// 是 `GetAlbumList` 回的 104400（参数非法，见 `musicu` 里那段）被当成了过期码，
    /// 而 mid 之所以非法，是资料库派生艺人的 id 冒号后面是艺人名不是 mid。
    func artistDetail(_ artist: Artist) async throws -> ArtistDetail {
        let mid = artist.id.rawID
        async let songsResp = musicu(
            module: "musichall.song_list_server",
            method: "GetSingerSongList",
            param: ["singerMid": mid, "order": 1, "number": 50, "begin": 0],
            anonymous: true)
        // `number` 在这两条上是**摆设**：[实测 2026-09-09 curl] 传 10 / 50 / 100
        // 一律只回 30 条。原先写 50 是照参考实现抄的，实际拿到的一直是 30——
        // 歌曲这一格无所谓（这一页本来就只摆热门几首），专辑那一格是真缺：
        // 高产歌手的专辑会被截掉一大半。所以专辑下面按 `total` 再补几页（见 `albumTail`）。
        async let albumsResp = musicu(
            module: "music.musichallAlbum.AlbumListServer",
            method: "GetAlbumList",
            param: ["singerMid": mid, "order": 1, "number": Self.singerPageSize, "begin": 0],
            anonymous: true)
        // 头图与简介单独一条，且**失败不算失败**：拿不到只是 hero 退回方头像，
        // 不该让整页变成错误页（歌曲/专辑才是这一页的正文）。
        // 这几个 flag 少一个就少一块数据：只传 `pic` 时 `ex_info.desc` 与 `wiki` 都回空
        // （[实测 2026-09-06 curl] 周杰伦、薛之谦都是空串，一度以为 QQ 不给简介）。
        // flag 名照 QQMusicApi 的 `singer.get_desc`，补齐后 `ex_info.desc` 是 249 字的简介、
        // `wiki` 是一段 XML（长简介 + 「外文名/国籍/出生地/职业/生日/出道日期/代表作品」事实表）。
        async let singerResp = try? musicu(
            module: "music.musichallSinger.SingerInfoInter",
            method: "GetSingerDetail",
            param: ["singer_mids": [mid], "pic": 1, "ex_singer": 1, "wiki_singer": 1,
                    "group_singer": 1, "photos": 1],
            anonymous: true)
        let (songsData, albumsData) = try await (songsResp, albumsResp)
        let hotTracks = (songsData["songList"] as? [[String: Any]] ?? []).compactMap { Self.parseSongListItem($0) }
        let firstPage = (albumsData["albumList"] as? [[String: Any]] ?? []).compactMap { Self.parseSingerAlbum($0) }
        // 第一页回来就知道 `total` 了，剩下的页偏移量都是算得出来的，于是并发补齐，
        // 不必一页等一页。上限 4 页追加（共 150 张）——再多就不是艺人页该一次端上来的量了，
        // 要一张不落用 `QQAPI+Singer.swift` 的 `singerAlbums(artistID:offset:)` 自己翻。
        let total = (albumsData["total"] as? Int) ?? firstPage.count
        let albums = firstPage + (await albumTail(artistID: artist.id, total: total, have: firstPage.count))
        let enriched = Self.parseSingerDetail(await singerResp, into: artist)
        return ArtistDetail(artist: enriched, hotTracks: hotTracks, albums: albums)
    }

    /// 艺人页专辑的后续页，并发取（见 `artistDetail` 里的注释）。
    private func albumTail(artistID: String, total: Int, have: Int) async -> [Album] {
        guard total > have, have > 0 else { return [] }
        let page = Self.singerPageSize
        let offsets = stride(from: have, to: min(total, have + page * 4), by: page).map { $0 }
        guard !offsets.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, [Album]).self) { group in
            for offset in offsets {
                group.addTask { (offset, await self.singerAlbums(artistID: artistID, offset: offset).albums) }
            }
            var pages: [(Int, [Album])] = []
            for await page in group { pages.append(page) }
            return pages.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    /// 相似艺人（艺人页底部那条货架）。
    ///
    /// [实测 2026-09-06 curl] `music.SimilarSingerSvr/GetSimilarSingerList` 匿名可用、
    /// code 0，`data.singerlist[]` 每项给 `singerMid` / `singerName` / `singerPic`。
    /// 与艺人页其余三条一样走 `anonymous: true`：公开目录数据，递票据换不来更多东西，
    /// 也就没得可拒（见 `artistDetail` 的注释）。
    ///
    /// **交不出来就返回空**（协议约定），所以整条吞掉错误：这是页面底部锦上添花的一段，
    /// 没有它页面照常成立，更不该让它把人从登录态里踢出去。
    /// 资料库派生艺人（`Artist.libraryIDPrefix`，冒号后面是名字不是 mid）直接短路，
    /// 别拿名字当 mid 去打——那会回 104400（参数非法，见 `musicu` 里那段账）。
    /// 曲目级流派。走的是**歌曲详情**那一条（`songExtraInfo`，`music.pf_song_detail_svr`），
    /// 不是 `CgiGetTrackInfo`——后者只给播放要用的那一份，没有流派。
    /// 那条已经挂在 `catalogCache` 上，同一首问第二次不再发请求。
    func trackGenre(_ track: Track) async -> String? {
        let genre = await songExtraInfo(track)?.genre?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (genre?.isEmpty == false) ? genre : nil
    }

    func similarArtists(_ artist: Artist) async -> [Artist] {
        guard !artist.isLibraryDerived else { return [] }
        let mid = artist.id.rawID
        guard !mid.isEmpty else { return [] }
        // 目录类数据，进 `catalogCache`：同一位艺人来回切页不重复发。
        return await catalogCache.value(for: "qq:SimilarSingerSvr?mid=\(mid)") {
            guard let data = try? await self.musicu(
                module: "music.SimilarSingerSvr",
                method: "GetSimilarSingerList",
                param: ["singerMid": mid, "number": Self.similarArtistCount],
                anonymous: true) else { return nil }
            return (data["singerlist"] as? [[String: Any]] ?? []).compactMap(Self.parseSimilarSinger)
        } ?? []
    }

    /// 要几位。Music 的相似艺人也就一行货架，10 位足够铺满并留出横滚。
    private static let similarArtistCount = 10

    // MARK: - 相似歌曲（自动连播）

    /// QQ 有「按这首找相似歌」的接口，所以自动连播可用。
    var supportsAutoplay: Bool { true }

    /// 相似歌曲，自动连播用它续队列。
    ///
    /// 接口 `music.recommend.TrackRelationServer` / `GetSimilarSongs`
    /// （[QQMusicApi] `qqmusic_api/modules/song.py::get_similar_song`）。
    ///
    /// **它只认数字 songid，而 Amber 的 QQ 曲目 id 是 mid**（`qq:004OJ2Hr0NDxI7`），
    /// 所以先用现成的 `songID(mid:)`（`CgiGetTrackInfo`）换一次——解析歌曲那一步
    /// （`parseTrack`）拿的是 mid，Track 上没有留数字 id 的位置，补一次详情请求最省事：
    /// 每补一批队列才多打这一条，且它本来就是自动连播这条路上唯一的额外开销。
    /// [实测 2026-09-09 curl] `mids:["003OUlho2HcRHC"]` → `tracks[0].id == 107192078`。
    ///
    /// `limit` 由调用方夹（接口自己不收这个参数，一次给多少是服务端定的）。
    func similarTracks(_ track: Track, limit: Int) async -> [Track] {
        let mid = track.id.rawID
        guard !mid.isEmpty, let songID = await songID(mid: mid) else { return [] }
        guard let data = try? await musicu(module: "music.recommend.TrackRelationServer",
                                          method: "GetSimilarSongs",
                                          param: ["songid": songID],
                                          clientType: 11, clientVersion: 12060012) else { return [] }
        return Array(Self.parseSimilarSongs(data).prefix(limit))
    }

    /// `GetSimilarSongs` 的响应解析（纯函数，可对着固定样本单测）。
    ///
    /// [实测 2026-09-09 curl] songid=107192078（告白气球）回三段：
    /// - `vecSongNew`：**按卡片分组**的结果，每组 `{title_template, title_content, songs:[{track}]}`，
    ///   这次是 1 组 15 首（`title_template` = 「听「{String}」的也在听」）；
    /// - `vecSong`：平铺的 11 首，形状同样是 `{track}`。**与 `vecSongNew` 不重叠**
    ///   （同一次响应里两边 mid 交集为空），不是它的子集，更像是另一路召回；
    /// - `songTagInfoList`：附带的标签（获奖/榜单），本轮用不上。
    ///
    /// 两段都读、`vecSongNew` 在前：分组那段与种子的关系明确（组名就是「听「周杰伦」的
    /// 也在听」），排在前面才会被 `limit` 先取走；`vecSong` 留在后面当兜底，
    /// 哪天服务端只发一段也不至于整个空掉。交集为空归交集为空，`dedupedByID` 照留——
    /// 这是解析器的兜底，不是靠一次采样定的结论。
    /// 组内的 `track` 就是标准歌曲对象，直接交给 `parseTrack`。
    static func parseSimilarSongs(_ data: [String: Any]) -> [Track] {
        let grouped = (data["vecSongNew"] as? [[String: Any]] ?? [])
            .flatMap { $0["songs"] as? [[String: Any]] ?? [] }
        let flat = data["vecSong"] as? [[String: Any]] ?? []
        return (grouped + flat)
            .compactMap { ($0["track"] as? [String: Any]).flatMap(Self.parseTrack) }
            .dedupedByID()
    }

    /// `singerlist[]` 的键与别处不同（`singerMid` 小写 d，`parseArtist` 认的是
    /// `singerMID` / `mid`），所以单独解一份。
    ///
    /// 头像取接口给的 `singerPic` 而不是 `artistArtwork(mid)` 拼串：两者本来就是同一套
    /// `T001R{n}x{n}M000<mid>.jpg` 模板（[实测] 接口给 150 档、`artistArtwork` 拼 300 档，
    /// 同一 mid 两档都 200），档位段 `R{n}x{n}M` 会被 `ArtworkSize.url` 按用途改写，
    /// 所以两条路等价——那就用接口那条，艺人换图时它先更新。
    /// 只有字段缺失才回退到拼串。地址是 http，走 `httpsURL` 抬一次（ATS）。
    private static func parseSimilarSinger(_ s: [String: Any]) -> Artist? {
        guard let mid = s["singerMid"] as? String, !mid.isEmpty else { return nil }
        return Artist(
            id: "qq:\(mid)",
            kind: .qq,
            name: s["singerName"] as? String ?? "未知歌手",
            avatarURL: Self.httpsURL(s["singerPic"] as? String) ?? Self.artistArtwork(mid),
            description: nil)
    }

    /// 把 `GetSingerDetail` 的图与简介并进艺人（拿不到就原样返回）。
    ///
    /// - `pic.big_black` / `pic.big_white`：官方艺人页的**页头宽幅图**，
    ///   [实测 2026-09-06 curl] 统一 2000×938（≈2.13:1），分暗色/亮色两版；
    ///   约一半艺人这两个字段是空字符串，只能回退到方头像。hero 上压的是白字 + 黑渐变，
    ///   所以优先要暗色那版。
    /// - `pic.pic`：300×300 方头像，比搜索结果给的 `singer_pic` 新（艺人换头像时先更这条）。
    ///
    /// 两点接口事实与 qmdec `docs/singer-images.md` 的记载相反，以这里的实测为准：
    /// ① 这条**匿名可用**——web comm（ct=24/cv=4747474）与完全不带 comm 都回 code 0，
    ///    并不需要 Android 设备会话（QIMEI + GetSession）；
    /// ② 换成 Android comm（ct=11/cv=12060012）反而回 104403。所以这里走 musicu 的默认档。
    ///
    /// URL 里的 `V21`(图片版本) 与 `_11`(照片编号) 每位艺人各不相同，且服务器只有预生成的
    /// 固定尺寸，不能像 `T00xR{n}x{n}M000` 那样改写档位（实测改了必 404）。
    /// `ArtworkSize.url` 认的正是 `R{n}x{n}M`，这类地址匹配不上、原样透传，安全。
    private static func parseSingerDetail(_ data: [String: Any]?, into artist: Artist) -> Artist {
        guard let singer = (data?["singer_list"] as? [[String: Any]])?.first else { return artist }
        let pic = singer["pic"] as? [String: Any] ?? [:]
        func image(_ key: String) -> String? {
            let value = pic[key] as? String ?? ""
            return value.isEmpty ? nil : value
        }
        // 简介两个来源：`wiki` 那段 XML 里的长简介，与 `ex_info.desc` 的短简介。
        // 介绍面板要的是「关于」那种成段正文，所以优先长的（实测周杰伦：wiki 1.2k 字 /
        // ex_info 249 字），长的没有才退回短的。
        let wiki = singer["wiki"] as? String ?? ""
        let shortDesc = (singer["ex_info"] as? [String: Any])?["desc"] as? String ?? ""
        let desc = Self.wikiDescription(wiki) ?? (shortDesc.isEmpty ? nil : shortDesc)
        return Artist(id: artist.id, kind: artist.kind, name: artist.name,
                      avatarURL: image("pic") ?? artist.avatarURL,
                      description: desc ?? artist.description,
                      bannerURL: image("big_black") ?? image("big_white"),
                      facts: Self.parseWikiFacts(wiki))
    }

    /// 百科 XML 的 `<desc><![CDATA[…]]></desc>`：成段的艺人简介。
    private static func wikiDescription(_ xml: String) -> String? {
        guard let range = xml.range(of: #"<desc>(?s).*?</desc>"#, options: .regularExpression)
        else { return nil }
        let text = String(xml[range])
            .replacingOccurrences(of: "<desc>", with: "")
            .replacingOccurrences(of: "</desc>", with: "")
            .replacingOccurrences(of: "<![CDATA[", with: "")
            .replacingOccurrences(of: "]]>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 百科 XML 的 `<basic><item><key/><value/></item>…`：艺人介绍面板上那几行事实。
    ///
    /// [实测 2026-09-06 curl] 键名是中文且逐人不同（周杰伦有「外文名/别名/国籍/出生地/职业/
    /// 生日/出道日期/主要成就/代表作品/从艺历程/荣誉记录」，周深还多出「粉丝名称/应援色」）。
    /// Music 的面板只摆两三行短事实，所以这里按 `wikiFactKeys` 白名单挑、按白名单的顺序排，
    /// 并且丢掉长文（「从艺历程」「荣誉记录」那种整篇的，正文位置已经有简介了）。
    private static func parseWikiFacts(_ xml: String) -> [ArtistFact] {
        guard !xml.isEmpty,
              let regex = try? NSRegularExpression(
                pattern: #"<item><key>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</key><value>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</value></item>"#,
                options: [.dotMatchesLineSeparators])
        else { return [] }
        var found: [String: String] = [:]
        let text = xml as NSString
        for match in regex.matches(in: xml, range: NSRange(location: 0, length: text.length)) {
            guard match.numberOfRanges == 3 else { continue }
            let key = text.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = text.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 一行放不下的就不是「事实行」了
            guard !value.isEmpty, value.count <= Self.wikiFactValueLimit,
                  found[key] == nil else { continue }
            found[key] = value
        }
        return Self.wikiFactKeys.compactMap { key in
            found[key].map { ArtistFact(label: key, value: $0) }
        }
    }

    /// 面板上按这个顺序摆，最多这么几行（Music 那块也只有两三行）。
    private static let wikiFactKeys = ["成立日期", "生日", "出道日期", "国籍", "职业", "代表作品"]
    private static let wikiFactValueLimit = 40

    // MARK: - 播放与歌词

    func trackStreamURL(track: Track, quality: StreamQuality?) async throws -> URL {
        let mid = track.id.rawID
        // 显式档位（下载）优先；没传就用全局的流播放档。两者都只是阶梯的**起点**。
        let wanted = quality ?? qualityProvider?() ?? .standard
        let candidates = try await vkeyCandidates(songMid: mid, mediaMid: track.mediaMid,
                                                  from: wanted)

        // 空 purl 表示这首歌确实没有这一档——对表里这些真实档位码，这个负信号是可靠的。
        // 反过来不成立：实测有的歌 Q001 给了 purl，一取却是 404。所以选中的还要探一下。
        for url in candidates.urls {
            if await isFetchable(url) { return url }
        }

        if credentialProvider?() == nil {
            throw ProviderError.unavailable("付费或 VIP 曲目，匿名状态无法播放")
        }
        // 服务端对取流只回 104003「无权播放」，不区分「没有会员」和「登录早就掉了」。
        // 先确认一下登录态，别把过期的 cookie 说成会员等级不够。
        await validateCredential()
        if credentialProvider?() == nil {
            throw ProviderError.unavailable("QQ音乐登录已过期，请重新登录后再播放")
        }
        throw ProviderError.unavailable(candidates.reason.isEmpty
            ? "该曲目无法播放（可能需要更高会员等级）" : candidates.reason)
    }

    private struct StreamCandidates {
        /// 服务端认账的取流地址，按音质从高到低
        let urls: [URL]
        /// 一个都没有时的原因（取第一条非 0 的 result）
        let reason: String
    }

    /// 一次把整个降级阶梯问完。
    ///
    /// `UrlGetVkey` 的 `filename` / `songmid` / `songtype` 都收数组，桌面客户端本身就是这么
    /// 批量取的。阶梯有十几档，一档一个往返太慢，这里一次问完按顺序挑。
    ///
    /// 文件名是「档位码 + media_mid + **该档真实的扩展名**」。扩展名写错 CDN 直接 404，
    /// 所以不能像以前那样一律拼 `.mp3`。没有 media_mid 时只能退回老的
    /// `<码><mid><mid>.mp3` 格式，那套只有 MP3 两档认。
    private func vkeyCandidates(songMid: String, mediaMid: String?,
                                from wanted: StreamQuality) async throws -> StreamCandidates {
        let filenames: [String]
        if let mediaMid, !mediaMid.isEmpty, credentialProvider?() != nil {
            filenames = wanted.ladder.flatMap { quality in
                quality.rungs.map { "\($0.code)\(mediaMid)\($0.ext)" }
            }
        } else {
            // 老格式只有 MP3 两档认。偏好落在 320k 以下时这里会筛空，保底给一个标准档，
            // 免得没有 media_mid 的曲目直接空手而归、报一个跟真实原因无关的错。
            let mp3Rungs = wanted.ladder.filter { $0 == .high || $0 == .standard }
            filenames = (mp3Rungs.isEmpty ? [.standard] : mp3Rungs)
                .map { "\($0.rungs[0].code)\(songMid)\(songMid).mp3" }
        }

        let param: [String: Any] = [
            "uin": credentialProvider?()?.uin ?? "0",
            "filename": filenames,
            "guid": guid,
            "songmid": Array(repeating: songMid, count: filenames.count),
            "songtype": Array(repeating: 0, count: filenames.count),
            "ctx": 0,
        ]
        // 登录态按 qmdec 的桌面客户端方式（ct=1 comm + Cookie）；匿名时 musicu 不带 comm。
        let data = try await musicu(module: "music.vkey.GetVkey", method: "UrlGetVkey",
                                    param: param, clientType: 1, clientVersion: 13030508)
        let sip = (data["sip"] as? [String])?.first ?? Self.fallbackCDN
        var urls: [URL] = []
        var reason = ""
        for info in data["midurlinfo"] as? [[String: Any]] ?? [] {
            let purl = info["purl"] as? String ?? ""
            guard !purl.isEmpty else {
                let result = info["result"] as? Int ?? -1
                if reason.isEmpty, result != 0 { reason = Self.vkeyReason(result) }
                continue
            }
            if let url = URL(string: purl.hasPrefix("http") ? purl : sip + purl) {
                urls.append(url)
            }
        }
        return StreamCandidates(urls: urls, reason: reason)
    }

    private static func vkeyReason(_ result: Int) -> String {
        switch result {
        case 104003: return "该曲目为付费/VIP 内容，当前账号无权播放"
        case 0: return ""
        default: return "取流失败（result=\(result)）"
        }
    }

    /// 探一个字节，确认这个地址真能取到东西——purl 会多报，光有地址不算数。
    private func isFetchable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.setValue(Self.clientUA, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// 歌词。
    ///
    /// **逐字（QRC）的开关是参数里的 `qrc`，跟登录态无关**——以前这里按「登录才给逐字」
    /// 去切客户端身份，是错的：换成 `ct=1` 的桌面身份照样只回行级 LRC。
    /// 带上 `qrc=1` 之后匿名身份就能拿到逐字，代价是 `lyric`/`trans` 从 base64 明文
    /// 变成十六进制密文，要过一遍 `QRCDecoder`（3DES 变体 + zlib + XML）。
    ///
    /// 逐字要不到就退回行级：有的歌本来就没做逐字，服务端会回 `qrc=0`。
    /// `LyricParser` 两种格式都认，所以下游不用关心拿到的是哪一种。
    func lyrics(track: Track) async throws -> [LyricLine] {
        let mid = track.id.rawID
        // 逐字这条先问。**非 nil ＝ 这一趟有结论**，空数组也是结论（音源明说这首没有词，
        // 见下面的 `lyric_style`），到此为止；nil ＝ 没给出结论（没有逐字版、或请求失败），
        // 退回行级再问一次。`(try? …) ?? nil` 是把`[LyricLine]??` 压平一层。
        if let decided = (try? await lyrics(mid: mid, wordByWord: true)) ?? nil { return decided }
        return ((try? await lyrics(mid: mid, wordByWord: false)) ?? nil) ?? []
    }

    /// nil = 这条路没给出结论，可以再试另一条；`[]` = 音源明说这首没有词。
    private func lyrics(mid: String, wordByWord: Bool) async throws -> [LyricLine]? {
        let data = try await musicu(
            module: "music.musichallSong.PlayLyricInfo",
            method: "GetPlayLyricInfo",
            param: ["songMid": mid, "qrc": wordByWord ? 1 : 0, "crypt": 0,
                    "lrc_t": 0, "qrc_t": 0, "roma": 1, "trans": 1,
                    "ct": 24, "cv": 4747474])
        // **`lyric_style = 1` 就是「这首没有填词」这个类别位。** 这种歌的 `lyric` 不是空的，
        // 而是一句占位词「此歌曲为没有填词的纯音乐／口白／DJ 节目，请您欣赏」——
        // 照原样解析出来就是拿一句客服话术占满整块歌词面板，所以在这里就归成「没有词」，
        // 让它跟真没词的歌走同一条空态。
        //
        // [实测 2026-09-17 curl 匿名] 占位词的两首（`0020o44K0KFFZ8` / `004gBEBP0YhVMe`）
        // `lyric_style = 1`，真歌词的两首（`002s0gpg1JsKQl` / `003tOxVg13WbDh`）`= 0`；
        // `qrc=1` 与 `qrc=0` 两种请求下这个字段都在，所以放在分叉之前判。
        // 别改回「按 `纯音乐` 三个字匹配」：音源自己给了类别位，凭字面猜既会误伤真词
        //（词里唱到这三个字的），也会漏——占位词不止一种形态，网易那边 `pureMusic` 的歌
        // 有的 `lrc` 是三行「作曲 : …」，一个「纯音乐」都没有。
        if data["lyric_style"] as? Int == 1 { return [] }
        // 服务端可能忽略请求、回退成行级；以返回的 qrc 标志为准，不以请求为准
        if wordByWord, (data["qrc"] as? Int ?? 0) != 1 { return nil }
        guard let raw = data["lyric"] as? String,
              let lyric = QRCDecoder.decodePayload(raw), !lyric.isEmpty else { return nil }
        let translation = (data["trans"] as? String).flatMap { QRCDecoder.decodePayload($0) }
        // `roma=1` 一直在请求里，只是以前没接：音译（Music 界面上叫「发音」）
        // 与 `trans` 同样走 `QRCDecoder`，qrc 模式下是逐字格式。
        let transliteration = (data["roma"] as? String).flatMap { QRCDecoder.decodePayload($0) }
        return LyricParser.parse(lyric, translation: translation,
                                 transliteration: transliteration)
    }

    // MARK: - MV 取流

    /// MV 地址。[实测 2026-09-07 curl]
    ///
    /// 接口是 `music.stream.MvUrlProxy/GetMvUrls`（**不是** `MvService.MvInfoProServer/GetMvUrl`，
    /// 那个名字回 500005「没有这个方法」；MvInfoProServer 只管 MV 列表与详情）。
    /// 请求：`{vids:[vid], request_type:10001, addrtype:3, format:264, maxFiletype:80, guid}`。
    /// **`comm` 块是必须的**，匿名也要带：不带 comm 时每档都回 `code:1000`、地址全空
    ///（这跟登录态无关，`ct=11` 与 `ct=1` 两种客户端身份实测等价）——`musicu` 只在有凭证时
    /// 才发 comm，所以这里走 `commOverride` 显式补一份。
    ///
    /// 响应：`data[vid].mp4[]`，每档一条
    /// `{filetype, code, fileSize, cn, vkey, url:[CDN 前缀…], freeflow_url:[整条地址…]}`。
    /// `code == 0` 才有地址；`1000` = 这档取不到（匿名下 filetype ≥ 40 一律如此，
    /// [推] 要登录/会员），`2000` = 这档不存在（`filetype 0` 与整个 `hls[]` 都是它）。
    /// `freeflow_url[0]` 就是 `url[0] + vkey + "/" + cn + "?fname=" + cn`，直接用。
    ///
    /// 匿名实测三首（周杰伦 晴天/七里香、女儿殿下）：10 → 640×360、20 → 848×476、
    /// 30 → 1280×720，全部 `vcodec=h264 acodec=aac`、`content-type: video/mp4`、Range 回 206。
    func mvStreamURL(mv: MV, maxHeight: Int?) async throws -> URL {
        let vid = mv.id.rawID
        guard !vid.isEmpty else { throw ProviderError.invalidResponse }
        let uin = credentialProvider?()?.uin.filter(\.isNumber) ?? ""
        let data = try await musicu(
            module: "music.stream.MvUrlProxy", method: "GetMvUrls",
            param: ["vids": [vid], "request_type": 10001, "addrtype": 3,
                    "format": 264, "maxFiletype": 80, "guid": guid],
            commOverride: ["ct": 11, "cv": 12060012, "format": "json",
                           "uin": Int(uin) ?? 0, "g_tk": 5381])
        let variants = Self.parseMVVariants(data, vid: vid)
        guard let picked = MVVariant.pick(variants, maxHeight: maxHeight) else {
            throw ProviderError.unavailable(credentialProvider?() == nil
                ? "这支 MV 匿名状态下取不到地址，登录后再试"
                : "这支 MV 当前账号无权观看")
        }
        return picked.url
    }

    /// `GetMvUrls` 的响应 → 画质阶梯。纯函数，喂 fixture 就能单测。
    static func parseMVVariants(_ data: [String: Any], vid: String) -> [MVVariant] {
        guard let entry = data[vid] as? [String: Any],
              let list = entry["mp4"] as? [[String: Any]] else { return [] }
        return list.compactMap { item -> MVVariant? in
            guard (item["code"] as? Int) == 0,
                  let height = mvHeight(forFileType: item["filetype"] as? Int ?? -1),
                  let url = mvURL(from: item) else { return nil }
            return MVVariant(height: height, url: url, bytes: item["fileSize"] as? Int ?? 0)
        }
    }

    /// 整条地址：优先 `freeflow_url`，缺了就按 CDN 前缀 + vkey + 文件名自己拼
    ///（两者实测逐字节相同，拼一份只是防它哪天不发 freeflow_url）。
    private static func mvURL(from item: [String: Any]) -> URL? {
        if let flat = (item["freeflow_url"] as? [String])?.first(where: { $0.hasPrefix("http") }),
           let url = URL(string: flat) {
            return url
        }
        guard let prefix = (item["url"] as? [String])?.first, prefix.hasPrefix("http"),
              let vkey = item["vkey"] as? String, !vkey.isEmpty,
              let name = item["cn"] as? String, !name.isEmpty else { return nil }
        return URL(string: "\(prefix)\(vkey)/\(name)?fname=\(name)")
    }

    /// `filetype` → 画面高度。
    ///
    /// 10/20/30 是匿名逐条量出来的（响应头 `x-cos-meta-video` 里直接有 width/height）；
    /// 40 往上匿名一律 `code:1000` 取不到，按 QQ 客户端画质菜单的顺序补，标 [推]。
    /// 表里没有的档位当「不认识」丢掉——宁可少给一档，也不要拿一个猜的高度去撞上限。
    static func mvHeight(forFileType filetype: Int) -> Int? {
        switch filetype {
        case 10: return 360      // [实测] 640×360
        case 20: return 480      // [实测] 848×476
        case 30: return 720      // [实测] 1280×720
        case 40, 50: return 1080 // [推] 50 是同分辨率的高码率档
        case 60: return 1440     // [推]
        case 70, 80: return 2160 // [推]
        default: return nil
        }
    }

    // MARK: - QQ 扫码登录（流程对齐 L-1124/QQMusicApi 的 _get_qq_qr / _check_qq_qr / _authorize_qq_qr）

    struct QRLoginImage: Sendable {
        let imageData: Data
        let qrsig: String
    }

    enum QRLoginStatus: Sendable {
        case waitingScan
        case scanned
        case expired
        case refused
        case done(uin: String, sigx: String)
    }

    /// hash33（QQ 的经典哈希，用于 ptqrtoken / g_tk）
    static func hash33(_ s: String, initial: Int = 0) -> Int {
        var h = initial
        for c in s.utf8 {
            h = (h &<< 5) &+ h &+ Int(c)
        }
        return h & 2147483647
    }

    /// 第一步：获取登录二维码（PNG）+ qrsig
    func fetchQRLoginImage() async throws -> QRLoginImage {
        var components = URLComponents(string: "https://ssl.ptlogin2.qq.com/ptqrshow")!
        components.queryItems = [
            URLQueryItem(name: "appid", value: "716027609"),
            URLQueryItem(name: "e", value: "2"),
            URLQueryItem(name: "l", value: "M"),
            URLQueryItem(name: "s", value: "3"),
            URLQueryItem(name: "d", value: "72"),
            URLQueryItem(name: "v", value: "4"),
            URLQueryItem(name: "t", value: String(Double.random(in: 0...1))),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.UA, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let qrsig = Self.cookieValue("qrsig", in: http) else {
            throw ProviderError.api("获取二维码失败")
        }
        return QRLoginImage(imageData: data, qrsig: qrsig)
    }

    /// 第二步：轮询扫码状态。响应形如 ptuiCB('66','0','','0','二维码未失效。', '')
    func pollQRLogin(qrsig: String) async throws -> QRLoginStatus {
        var components = URLComponents(string: "https://ssl.ptlogin2.qq.com/ptqrlogin")!
        components.queryItems = [
            URLQueryItem(name: "u1", value: "https://graph.qq.com/oauth2.0/login_jump"),
            URLQueryItem(name: "ptqrtoken", value: String(Self.hash33(qrsig))),
            URLQueryItem(name: "ptredirect", value: "0"),
            URLQueryItem(name: "h", value: "1"),
            URLQueryItem(name: "t", value: "1"),
            URLQueryItem(name: "g", value: "1"),
            URLQueryItem(name: "from_ui", value: "1"),
            URLQueryItem(name: "ptlang", value: "2052"),
            URLQueryItem(name: "action", value: "0-0-\(Int(Date().timeIntervalSince1970 * 1000))"),
            URLQueryItem(name: "js_ver", value: "20102616"),
            URLQueryItem(name: "js_type", value: "1"),
            URLQueryItem(name: "pt_uistyle", value: "40"),
            URLQueryItem(name: "aid", value: "716027609"),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308"),
            URLQueryItem(name: "has_onekey", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("qrsig=\(qrsig)", forHTTPHeaderField: "Cookie")
        request.setValue(Self.UA, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              // 响应可能是 GBK 编码，先按 UTF-8 解，失败则保留原始字节
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let inner = Self.firstMatch("ptuiCB\\((.*?)\\)", in: text) else {
            throw ProviderError.invalidResponse
        }
        // 提取单引号包裹的参数
        let args = Self.matches("'((?:\\\\.|[^'])*)'", in: inner)
        guard let codeString = args.first else { throw ProviderError.invalidResponse }
        switch codeString {
        case "0":
            guard args.count >= 3 else { throw ProviderError.invalidResponse }
            let redirectURL = args[2]
            guard let sigx = Self.firstMatch("(?:\\?|&)ptsigx=(.+?)&s_url", in: redirectURL),
                  let uin = Self.firstMatch("(?:\\?|&)uin=(.+?)&service", in: redirectURL) else {
                throw ProviderError.invalidResponse
            }
            return .done(uin: uin, sigx: sigx)
        case "65":
            return .expired
        case "66":
            return .waitingScan
        case "67":
            return .scanned
        case "68":
            return .refused
        default:
            return .waitingScan
        }
    }

    /// 第三步：扫码确认后换取 QQ 音乐登录凭证（musicid + musickey）
    func authorizeQRLogin(uin: String, sigx: String) async throws -> QQCredential {
        // 3a. check_sig → 302，Set-Cookie 带 p_skey
        var checkComponents = URLComponents(string: "https://ssl.ptlogin2.graph.qq.com/check_sig")!
        checkComponents.queryItems = [
            URLQueryItem(name: "uin", value: uin),
            URLQueryItem(name: "pttype", value: "1"),
            URLQueryItem(name: "service", value: "ptqrlogin"),
            URLQueryItem(name: "nodirect", value: "0"),
            URLQueryItem(name: "ptsigx", value: sigx),
            URLQueryItem(name: "s_url", value: "https://graph.qq.com/oauth2.0/login_jump"),
            URLQueryItem(name: "ptlang", value: "2052"),
            URLQueryItem(name: "ptredirect", value: "100"),
            URLQueryItem(name: "aid", value: "716027609"),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "j_later", value: "0"),
            URLQueryItem(name: "low_login_hour", value: "0"),
            URLQueryItem(name: "regmaster", value: "0"),
            URLQueryItem(name: "pt_login_type", value: "3"),
            URLQueryItem(name: "pt_aid", value: "0"),
            URLQueryItem(name: "pt_aaid", value: "16"),
            URLQueryItem(name: "pt_light", value: "0"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308"),
        ]
        var checkRequest = URLRequest(url: checkComponents.url!)
        checkRequest.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
        checkRequest.setValue(Self.UA, forHTTPHeaderField: "User-Agent")
        let (_, checkResponse) = try await noRedirectSession.data(for: checkRequest)
        guard let http = checkResponse as? HTTPURLResponse,
              let pSkey = Self.cookieValue("p_skey", in: http) else {
            throw ProviderError.api("获取 p_skey 失败")
        }
        // 注意：不手动带 Cookie——check_sig 的 302 返回的所有 Set-Cookie 已被
        // noRedirectSession 的 cookie 存储自动保存，authorize 请求会自动携带

        // 3b. oauth2 authorize → 302，Location 携带 code
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: "100497308"),
            URLQueryItem(name: "redirect_uri", value: "https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/"),
            URLQueryItem(name: "scope", value: "get_user_info,get_app_friends"),
            URLQueryItem(name: "state", value: "state"),
            URLQueryItem(name: "switch", value: ""),
            URLQueryItem(name: "from_ptlogin", value: "1"),
            URLQueryItem(name: "src", value: "1"),
            URLQueryItem(name: "update_auth", value: "1"),
            URLQueryItem(name: "openapi", value: "1010_1030"),
            URLQueryItem(name: "g_tk", value: String(Self.hash33(pSkey, initial: 5381))),
            URLQueryItem(name: "auth_time", value: String(Int(Date().timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "ui", value: UUID().uuidString),
        ]
        var authorizeRequest = URLRequest(url: URL(string: "https://graph.qq.com/oauth2.0/authorize")!)
        authorizeRequest.httpMethod = "POST"
        authorizeRequest.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)
        authorizeRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        authorizeRequest.setValue(Self.UA, forHTTPHeaderField: "User-Agent")
        let (authorizeData, authorizeResponse) = try await noRedirectSession.data(for: authorizeRequest)
        guard let authorizeHTTP = authorizeResponse as? HTTPURLResponse else {
            throw ProviderError.api("获取授权 code 失败（无响应）")
        }
        let location = authorizeHTTP.value(forHTTPHeaderField: "Location") ?? ""
        guard let code = Self.firstMatch("(?<=code=)(.+?)(?=&|$)", in: location), !code.isEmpty else {
            // 调试信息：状态码 + Location 摘要 + 响应体摘要
            let bodySnippet = String(data: authorizeData, encoding: .utf8)?
                .prefix(120).replacingOccurrences(of: "\n", with: " ") ?? ""
            throw ProviderError.api("获取授权 code 失败（http \(authorizeHTTP.statusCode)，Location: \(location.prefix(100))，body: \(bodySnippet)）")
        }

        // 3c. QQConnectLogin → musicid / musickey
        let data = try await musicu(
            module: "QQConnectLogin.LoginServer",
            method: "QQLogin",
            param: ["code": code],
            commOverride: ["tmeLoginType": 2])
        let musicID = (data["musicid"] as? Int) ?? (data["musicid"] as? String).flatMap(Int.init)
            ?? (data["musicId"] as? Int) ?? (data["musicId"] as? String).flatMap(Int.init)
        let musicKey = (data["musickey"] as? String) ?? (data["musickey"] as? String)
        guard let musicID, let musicKey, !musicKey.isEmpty else {
            throw ProviderError.api("登录凭证解析失败")
        }
        let cookie = "qm_keyst=\(musicKey); qqmusic_key=\(musicKey); qqmusic_uin=\(musicID)"
        return QQCredential(cookie: cookie, uin: String(musicID))
    }

#if DEBUG
    // MARK: - 登录态接口探测（-qqprobe）

    /// 拿当前登录态挨个打候选接口，把 code 和顶层字段写到文件，用来判断
    /// 「瞩目之星 / 更多类似作品 / 即将发布」这些段在 QQ 上到底能不能接。
    /// 匿名探测会被 500003/500005 一律挡掉，看不出是「没有这个接口」还是「要登录」。
    func debugProbeCatalog(to path: String) async {
        let seedSongID = 107192078      // 告白气球，用来试相似歌曲
        let seedSongMid = "003OUlho2HcRHC"
        let seedSingerMid = "0025NhlN2yWrP4" // 周杰伦
        let candidates: [(String, String, [String: Any])] = [
            // 瞩目之星：歌手列表 / 相似歌手
            ("music.musichallSinger.SingerList", "GetSingerListIndex",
             ["area": -100, "sex": -100, "genre": -100, "index": -100, "sin": 0, "cur_page": 1]),
            ("music.musichallSinger.SingerList", "GetSingerList",
             ["hastag": 0, "area": -100, "sex": -100, "genre": -100]),
            ("music.SimilarSingerSvr", "GetSimilarSingerList",
             ["singerMid": seedSingerMid, "number": 10]),
            // 更多类似作品：相似歌曲 / 相关歌单 / 相关 MV
            ("music.recommend.TrackRelationServer", "GetSimilarSongs", ["songid": seedSongID]),
            ("music.recommend.TrackRelationServer", "GetRelatedPlaylist",
             ["songid": seedSongID, "vecPlaylist": [Int]()]),
            ("MvService.MvInfoProServer", "GetSongRelatedMv",
             ["songid": "\(seedSongID)", "songtype": 1, "lastmvid": 0]),
            // 观看艺人分享：MV 列表
            ("MvService.MvInfoProServer", "GetAllocMvInfo",
             ["area": 15, "version": 0, "order": 1, "start": 0, "size": 10]),
            ("MvService.MvInfoProServer", "GetSingerMvList",
             ["singermid": seedSingerMid, "order": 1, "count": 10, "start": 0]),
            // 为你制作的歌单：客户端首页推荐流（要 Android comm，见下面的 clientType/clientVersion）
            ("music.recommend.RecommendFeed", "get_recommend_feed", ["From": 0, "Size": 10]),
            // 即将发布：专辑列表
            ("music.musichallAlbum.AlbumListServer", "GetAlbumList",
             ["singerMid": seedSingerMid, "order": 1, "number": 10, "begin": 0]),
        ]

        var report = "QQ 登录态接口探测  \(Date())\n登录态：\(credentialProvider?() != nil ? "有" : "无")\n\n"
        for (module, method, param) in candidates {
            var line = "\(module)/\(method)  "
            do {
                let data = try await musicu(module: module, method: method, param: param,
                                            clientType: 11, clientVersion: 12060012)
                let keys = data.keys.sorted().prefix(10).joined(separator: ",")
                var detail = ""
                // 推荐流是「货架里套卡」的两层结构，光打首项看不出有哪些段，单独摊开
                if let shelves = data["v_shelf"] as? [[String: Any]] {
                    for shelf in shelves {
                        let title = ((shelf["title_content"] as? [String: Any])?["title"]) as? String
                            ?? (shelf["title_content"] as? String) ?? "(无题)"
                        let cards = (shelf["v_niche"] as? [[String: Any]] ?? [])
                            .flatMap { ($0["v_card"] as? [[String: Any]]) ?? [] }
                        let sample = cards.prefix(6).map { card -> String in
                            let cover = (card["cover"] as? String) ?? ""
                            return "\(card["title"] as? String ?? "?")"
                                + "[type=\(card["type"] as? Int ?? -1) id=\(card["id"] as? String ?? "?")"
                                + " cover=\(cover.isEmpty ? "空" : String(cover.suffix(28)))]"
                        }.joined(separator: " ; ")
                        detail += "\n  shelf \(shelf["id"] as? Int ?? -1) 「\(title)」"
                            + " 卡\(cards.count)：\(sample)"
                    }
                }
                for key in data.keys where (data[key] as? [Any])?.isEmpty == false {
                    if let arr = data[key] as? [[String: Any]], let first = arr.first {
                        detail += " | \(key)[\(arr.count)] 首项字段: "
                            + first.keys.sorted().prefix(10).joined(separator: ",")
                        // 光有字段名写不出解析器（值的类型、id 前缀都得看），把首项整条打出来
                        if let json = try? JSONSerialization.data(withJSONObject: first,
                                                                  options: [.prettyPrinted,
                                                                            .withoutEscapingSlashes]),
                           let text = String(data: json, encoding: .utf8) {
                            detail += "\n首项:\n" + text.prefix(1500)
                        }
                        break
                    }
                }
                line += "OK  {\(keys)}\(detail)"
            } catch {
                line += "FAIL  \(error.localizedDescription)"
            }
            report += line + "\n"
        }
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
        NSLog("[qqprobe] 写入 \(path)")
    }

    // MARK: - 账号歌单接口探测（-qqplaylistprobe）

    /// 拿当前登录态探「我创建的歌单 / 我收藏的歌单 / 我喜欢」这几条。
    ///
    /// 收藏类接口的 `uin` 收的是**加密 uin（euin）**，不是 cookie 里那个数字 uin，
    /// 而扫码登录只落了数字 uin。所以先打一遍账号信息接口，从返回里捞 euin 候选，
    /// 再拿每个候选去试收藏接口——省得靠猜。
    func debugProbeUserPlaylists(to path: String) async {
        let numericUin = credentialProvider?()?.uin.filter(\.isNumber) ?? ""
        var report = "QQ 账号歌单接口探测  \(Date())\n"
        report += "登录态：\(credentialProvider?() != nil ? "有" : "无")  数字 uin：\(numericUin)\n\n"

        func dump(_ label: String, _ value: Any, limit: Int = 2600) -> String {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value,
                                                         options: [.prettyPrinted, .withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8)
            else { return "\(label): \(value)" }
            return "\(label):\n" + String(text.prefix(limit))
        }

        /// 递归找 euin 候选：键名带 euin/encrypt 的字符串值。
        func euinCandidates(_ any: Any, into found: inout [String: String]) {
            if let dict = any as? [String: Any] {
                for (key, value) in dict {
                    let lower = key.lowercased()
                    if let text = value as? String, !text.isEmpty,
                       lower.contains("euin") || lower.contains("encrypt") {
                        found[key] = text
                    }
                    euinCandidates(value, into: &found)
                }
            } else if let array = any as? [Any] {
                for item in array { euinCandidates(item, into: &found) }
            }
        }

        var euins: [String: String] = [:]

        // 1. 账号信息：既确认登录态，也用来捞 euin
        for (module, method, param, ct, cv) in [
            ("music.UserInfo.userInfoServer", "GetLoginUserInfo", [String: Any](), 1, 13030508),
            ("VipLogin.VipLoginInter", "vip_login_base", [String: Any](), 11, 12060012),
        ] as [(String, String, [String: Any], Int, Int)] {
            do {
                let data = try await musicu(module: module, method: method, param: param,
                                            clientType: ct, clientVersion: cv)
                euinCandidates(data, into: &euins)
                report += dump("\(module)/\(method)  OK", data) + "\n\n"
            } catch {
                report += "\(module)/\(method)  FAIL  \(error.localizedDescription)\n\n"
            }
        }
        report += "euin 候选：\(euins)\n\n"

        // 1b. 「我喜欢」（dirid 201）用数字 uin 就能打，它的返回里带 encrypt_login = euin
        do {
            let data = try await musicu(module: "music.srfDissInfo.DissInfo", method: "CgiGetDiss",
                                        param: ["disstid": 0, "dirid": 201, "tag": true,
                                                "song_begin": 0, "song_num": 3, "userinfo": true,
                                                "orderlist": true, "enc_host_uin": numericUin],
                                        clientType: 11, clientVersion: 12060012)
            if let euin = data["encrypt_login"] as? String, !euin.isEmpty {
                euins["encrypt_login"] = euin
            }
            report += "CgiGetDiss(dirid=201) 拿到 encrypt_login：\(euins["encrypt_login"] ?? "无")\n\n"
        } catch {
            report += "CgiGetDiss(dirid=201) FAIL \(error.localizedDescription)\n\n"
        }

        // 2. 我创建的歌单：这条收的是数字 uin
        var uinCandidates: [String] = numericUin.isEmpty ? [] : [numericUin]
        uinCandidates.append(contentsOf: euins.values.filter { !uinCandidates.contains($0) })

        for uin in uinCandidates {
            do {
                let data = try await musicu(module: "music.musicasset.PlaylistBaseRead",
                                            method: "GetPlaylistByUin",
                                            param: ["uin": uin],
                                            clientType: 11, clientVersion: 12060012)
                let list = (data["v_playlist"] as? [[String: Any]]) ?? []
                report += "PlaylistBaseRead/GetPlaylistByUin uin=\(uin.prefix(6))…  OK"
                    + "  total=\(data["total"] as? Int ?? -1) 条数=\(list.count)\n"
                if let first = list.first { report += dump("  首项", first) + "\n" }
                report += "  全部标题：" + list.compactMap {
                    "\($0["title"] as? String ?? "?")[tid=\($0["tid"] as? Int ?? -1)"
                        + " dirid=\($0["dirid"] as? Int ?? -1) n=\($0["songnum"] as? Int ?? -1)]"
                }.joined(separator: " ; ") + "\n\n"
            } catch {
                report += "PlaylistBaseRead/GetPlaylistByUin uin=\(uin.prefix(6))…  FAIL  \(error.localizedDescription)\n\n"
            }
        }

        // 3. 收藏的歌单 / 收藏的专辑 / 我喜欢（dirid 201）
        for uin in uinCandidates {
            let tag = String(uin.prefix(6)) + "…"
            for (module, method, param) in [
                ("music.musicasset.PlaylistFavRead", "CgiGetPlaylistFavInfo",
                 ["uin": uin, "offset": 0, "size": 30] as [String: Any]),
                ("music.musicasset.AlbumFavRead", "CgiGetAlbumFavInfo",
                 ["uin": uin, "offset": 0, "size": 30] as [String: Any]),
                ("music.srfDissInfo.DissInfo", "CgiGetDiss",
                 ["disstid": 0, "dirid": 201, "tag": true, "song_begin": 0, "song_num": 5,
                  "userinfo": true, "orderlist": true, "enc_host_uin": uin] as [String: Any]),
                ("music.UnifiedHomepage.UnifiedHomepageSrv", "GetHomepageHeader",
                 ["uin": uin, "IsQueryTabDetail": 1] as [String: Any]),
            ] {
                do {
                    let data = try await musicu(module: module, method: method, param: param,
                                                clientType: 11, clientVersion: 12060012)
                    report += "\(module)/\(method) uin=\(tag)  OK  顶层字段："
                        + data.keys.sorted().joined(separator: ",") + "\n"
                    report += dump("  返回", data, limit: 1800) + "\n\n"
                } catch {
                    report += "\(module)/\(method) uin=\(tag)  FAIL  \(error.localizedDescription)\n\n"
                }
            }
        }

        // 自建歌单的曲目怎么取，2026-09-03 已经探清楚：`disstid=tid` 与
        // `dirid + enc_host_uin` 两条路对自建歌单（含 dirid=201 的「我喜欢」）返回一致，
        // 所以 Amber 直接复用现成的 `dissDetail`，不必为账号歌单另开一条取数路径。

        try? report.write(toFile: path, atomically: true, encoding: .utf8)
        NSLog("[qqprobe] 账号歌单探测写入 \(path)")
    }
#endif

    // MARK: - 正则小工具

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func cookieValue(_ name: String, in response: HTTPURLResponse) -> String? {
        // Set-Cookie 可能有多条，取第一条；值里可能有 "="，按首个 ";" 截断
        let header = response.value(forHTTPHeaderField: "Set-Cookie") ?? ""
        for part in header.components(separatedBy: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(name)=") else { continue }
            var value = String(trimmed.dropFirst(name.count + 1))
            if let semicolon = value.firstIndex(of: ";") {
                value = String(value[..<semicolon])
            }
            return value
        }
        return nil
    }
}
