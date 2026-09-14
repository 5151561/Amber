import Foundation

/// 账号资料、听歌数据、云盘，以及两条「打卡」写接口。
///
/// 通道分工照 `NeteaseAPI` 顶上那条规矩来：**别人也能看的公开数据走明文 GET**
/// （用户资料、听歌排行——这两条实测明文比 eapi 还靠谱，见各自注释），
/// **只有自己看得到的走 eapi**（云盘、会员、最近播放、退出登录）。
extension NeteaseAPI {

    // MARK: - 账号资料

    /// 用户公开资料。`/api/v1/user/detail/{uid}`（uid 在**路径**里，不是参数）。
    /// [api-enhanced] `module/user_detail.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl] 明文 GET 匿名就能读别人的公开资料：
    /// `uid=45441555` 回 `code:200`，顶层有 `level:10` / `listenSongs:75911` /
    /// `createDays` / `identify`（达人认证），`profile` 里有
    /// `userId` / `nickname:"阿卡琳"` / `avatarUrl` / `signature` / `vipType:11` /
    /// `follows:176` / `followeds:42672` / `playlistCount:73`。
    /// eapi 打同一条也回 200（形状一样），但既然匿名明文就够，就不多绕一层加解密。
    ///
    /// 两个键位容易记反：**关注数是 `follows`，粉丝数是 `followeds`**（多一个 ed 的是粉丝）。
    /// 等级 `level` 与听歌总数在**顶层**，不在 `profile` 里。
    ///
    /// 取不到就返回 nil（读接口的口径），不抛。
    func userProfile(uid: Int) async -> ProviderUserProfile? {
        guard let resp = try? await get("/api/v1/user/detail/\(uid)"),
              let profile = resp["profile"] as? [String: Any],
              let userID = profile["userId"] as? Int else { return nil }
        return ProviderUserProfile(
            uid: "\(userID)",
            nickname: profile["nickname"] as? String ?? "网易云用户",
            avatarURL: Self.artworkURL(profile["avatarUrl"] as? String ?? ""),
            signature: (profile["signature"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            vipLevel: profile["vipType"] as? Int,
            level: resp["level"] as? Int,
            followCount: profile["follows"] as? Int,
            followerCount: profile["followeds"] as? Int,
            playlistCount: profile["playlistCount"] as? Int)
    }

    /// 当前登录账号的资料。uid 走 `currentUID()`（凭证里存着，缺了才补打 `account/get`）。
    func currentUserProfile() async -> ProviderUserProfile? {
        guard let uid = await currentUID() else { return nil }
        return await userProfile(uid: uid)
    }

    // MARK: - 听歌排行

    /// 听歌排行。`/api/v1/play/record`，参数 `uid` / `type`（**0 = 所有时间，1 = 最近一周**）。
    /// [api-enhanced] `module/user_record.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl] 走**明文 GET**：`uid=45441555&type=0` 回 `code:200`、
    /// `allData` 100 条；`type=1` 回 `weekData`。**装数据的键随 type 变**
    /// （0→`allData`，1→`weekData`），不是同一个键，所以两个都认。
    /// 每项是 `{"playCount":…, "score":…, "song":{v3 那套字段 ar/al/dt}}`。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 换 eapi 打同一条回的是**空响应体**，
    /// 所以这条明确走明文，别「为了统一」挪到 eapi 上去。
    ///
    /// 还有两种「200 但没数据」要分清，界面上不能都说成出错：
    /// - `{"code":-2,"msg":"无权限访问"}`：这个人把听歌排行设成不公开（uid=1、32953014 都是）；
    /// - `{"weekData":[],"code":200}`：公开但这一周没听（uid=2029324、254633、1341830271）。
    ///
    /// `PlayRecordItem.lastPlayed` 一律是 nil——**这条接口不给时间**，只给次数和分数。
    /// 想要「什么时候听的」得走下面的 `recentPlayed*`。
    func playRecords(uid: Int, weekly: Bool = false) async -> [PlayRecordItem] {
        guard let resp = try? await get("/api/v1/play/record",
                                        params: ["uid": "\(uid)", "type": weekly ? "1" : "0"])
        else { return [] }
        let list = (resp[weekly ? "weekData" : "allData"] as? [[String: Any]]) ?? []
        return list.compactMap { item in
            guard let song = item["song"] as? [String: Any],
                  let track = Self.parseTrack(song) else { return nil }
            return PlayRecordItem(track: track,
                                  playCount: item["playCount"] as? Int ?? 0,
                                  lastPlayed: nil)
        }
    }

    /// 当前登录账号的听歌排行。
    func currentUserPlayRecords(weekly: Bool = false) async -> [PlayRecordItem] {
        guard let uid = await currentUID() else { return [] }
        return await playRecords(uid: uid, weekly: weekly)
    }

    // MARK: - 最近播放

    /// 最近播放的歌曲。`/api/play-record/song/list`，参数 `limit`（参考实现默认 100），走 eapi。
    /// [api-enhanced] `module/record_recent_song.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl + eapi 探针] 匿名两条路都回
    /// `{"code":200,"data":{"total":0,"list":[]},"message":""}`——**200 但空表**，
    /// 与「没登录」长得一样，所以别拿它判登录态。**登录态下 `list` 里每项长什么样
    /// 没有实机验证过**：参考实现只说它是最近播放表，字段名靠猜是不行的，
    /// 所以这里对每项按三种可能的容器（`data` / `song` / `resource`）各剥一次，
    /// 都剥不出来就把这项本身交给 `parseTrack` 试——解不出来的项直接丢，不造假数据。
    ///
    /// 时间戳同理：`playTime` / `resourcePlayTime` 哪个存在用哪个，都没有就是 nil。
    func recentPlayedTracks(limit: Int = 100) async -> [PlayRecordItem] {
        guard let list = await recentPlayList("/api/play-record/song/list", limit: limit)
        else { return [] }
        return list.compactMap { item in
            let raw = (item["data"] as? [String: Any])
                ?? (item["song"] as? [String: Any])
                ?? (item["resource"] as? [String: Any])
                ?? item
            guard let track = Self.parseTrack(raw) else { return nil }
            let ms = (item["playTime"] as? Int) ?? (item["resourcePlayTime"] as? Int)
            return PlayRecordItem(track: track,
                                  playCount: item["playCount"] as? Int ?? 0,
                                  lastPlayed: ms.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) })
        }
    }

    /// 最近播放的专辑。`/api/play-record/album/list`，参数 `limit`，走 eapi。
    /// [api-enhanced] `module/record_recent_album.js`
    /// 匿名回 200 空表（同上），登录态形状未实机验证过——容器按同样三种可能剥。
    func recentPlayedAlbums(limit: Int = 100) async -> [Album] {
        guard let list = await recentPlayList("/api/play-record/album/list", limit: limit)
        else { return [] }
        return list.compactMap { Self.parseAlbum(Self.unwrapRecord($0)) }
    }

    /// 最近播放的歌单。`/api/play-record/playlist/list`，参数 `limit`，走 eapi。
    /// [api-enhanced] `module/record_recent_playlist.js`
    /// 匿名回 200 空表（同上），登录态形状未实机验证过。
    func recentPlayedPlaylists(limit: Int = 100) async -> [Playlist] {
        guard let list = await recentPlayList("/api/play-record/playlist/list", limit: limit)
        else { return [] }
        return list.compactMap { Self.parsePlaylist(Self.unwrapRecord($0)) }
    }

    /// 客户端首页那条「最近听歌」。`/api/pc/recent/listen/list`，**无参数**，走 eapi。
    /// [api-enhanced] `module/recent_listen_list.js`
    ///
    /// [实测 2026-09-09 curl + eapi 探针] 匿名两条路都回
    /// `{"code":200,"data":{"title":null,"resources":null},"message":""}`
    /// ——注意装数据的键是 **`resources`** 而不是上面那三条的 `list`，而且它是
    /// **`null` 不是空数组**，所以解析时不能强转数组。登录态形状未实机验证过。
    ///
    /// 这条与 `/api/play-record/*/list` 是两套东西：它把歌/专辑/歌单混在一张表里
    /// （每项带自己的类型），所以这里只把原样的项交出去，由调用方按需要挑——
    /// 在没见过真实响应之前，替它定一个模型只会定错。
    func recentListenList() async -> [[String: Any]] {
        guard let resp = try? await eapi("/api/pc/recent/listen/list"),
              let data = resp["data"] as? [String: Any],
              let resources = data["resources"] as? [[String: Any]] else { return [] }
        return resources
    }

    // MARK: - 云盘

    /// 云盘列表。`/api/v1/cloud/get`，参数 `limit` / `offset`，走 eapi。
    /// [api-enhanced] `module/user_cloud.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回**空响应体**，明文 GET 回
    /// `{"code":301,"message":null}`——**必须登录**。200 的形状未实机验证过：
    /// 按参考实现，`data` 里每项带 `songId` / `songName` / `fileName` / `fileSize` /
    /// `bitrate` / `addTime`，另有一个完整的 `simpleSong`（v3 那套字段）。
    /// 这里以 `simpleSong` 为准解曲目，缺了就丢掉这一项——云盘条目没有曲目就没法播，
    /// 留一个只有文件名的壳没有意义。
    func cloudSongs(limit: Int = 30, offset: Int = 0) async throws -> [NeteaseCloudSong] {
        guard isLoggedIn else {
            throw ProviderError.unavailable("请先登录网易云音乐账号，才能查看云盘")
        }
        let resp = try await eapi("/api/v1/cloud/get",
                                  [("limit", .int(limit)), ("offset", .int(offset))])
        return (resp["data"] as? [[String: Any]] ?? []).compactMap { Self.parseCloudSong($0) }
    }

    /// 按 id 查云盘条目详情。`/api/v1/cloud/get/byids`，参数 `songIds`，走 eapi。
    /// [api-enhanced] `module/user_cloud_detail.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"code":301,"message":null}`；
    /// 200 的形状未实机验证过。
    ///
    /// `songIds` 发的是**真数组、元素是字符串**，照参考实现来
    /// （`module/user_cloud_detail.js`：`query.id.split(',')` 之后原样当数组发）。
    /// 别写成 `"[1,2]"` 那种字符串——那是 `playlist/manipulate/tracks` 的 `trackIds`
    /// 才认的写法，两条不通用。`NeteaseJSON.array` 这一档就是为这里加的。
    func cloudSongDetails(ids: [String]) async throws -> [NeteaseCloudSong] {
        guard isLoggedIn else {
            throw ProviderError.unavailable("请先登录网易云音乐账号，才能查看云盘")
        }
        let raw = ids.map(\.rawID).filter { !$0.isEmpty }
        guard !raw.isEmpty else { return [] }
        let resp = try await eapi("/api/v1/cloud/get/byids",
                                  [("songIds", .array(raw.map { .string($0) }))])
        return (resp["data"] as? [[String: Any]] ?? []).compactMap { Self.parseCloudSong($0) }
    }

    /// 删除云盘里的一首。`/api/cloud/del`，参数 `songIds`，走 eapi。
    /// [api-enhanced] `module/user_cloud_del.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"code":301,"message":null}`；
    /// 200 的形状未实机验证过。`songIds` 同样发真数组（见上一条）。
    ///
    /// 这是**删数据**，所以哪怕未登录也要抛而不是静默——用户以为删掉了、其实没删，
    /// 比报个错糟得多。
    func deleteCloudSongs(ids: [String]) async throws {
        guard isLoggedIn else {
            throw ProviderError.unavailable("请先登录网易云音乐账号，才能删除云盘歌曲")
        }
        let raw = ids.map(\.rawID).filter { !$0.isEmpty }
        guard !raw.isEmpty else { return }
        try await eapi("/api/cloud/del",
                       [("songIds", .array(raw.map { .string($0) }))])
    }

    // MARK: - 会员与等级

    /// 会员信息。`/api/music-vip-membership/front/vip/info`，参数 `userId`
    /// （参考实现允许空串＝查自己），走 eapi。
    /// [api-enhanced] `module/vip_info.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `userId=""` 回
    /// `{"message":"成功","data":{"associator":{"vipCode":0,"expireTime":0,"vipLevel":0,
    /// "iconUrl":"…","isSignIap":false,…},…}}`——**匿名也回 200**，只是各档全是 0，
    /// 所以不能拿「回没回 200」判会员，得看 `vipLevel` / `expireTime`。
    ///
    /// 三档会员是并列的三个节点：`associator`（黑胶 VIP）、`musicPackage`（音乐包）、
    /// `redplus`（红钻）。这里三个都收，谁有值谁说了算，不替业务层挑。
    func vipInfo() async -> NeteaseVIPInfo? {
        // userId 传空串＝查自己（参考实现的默认）；凭证里现成有 uid 就带上，省服务端一次推断
        let uid = credentialProvider?()?.uid
        guard let resp = try? await eapi("/api/music-vip-membership/front/vip/info",
                                         [("userId", .string(uid.map(String.init) ?? ""))]),
              let data = resp["data"] as? [String: Any] else { return nil }
        func tier(_ key: String) -> NeteaseVIPInfo.Tier? {
            guard let node = data[key] as? [String: Any] else { return nil }
            let expire = node["expireTime"] as? Int ?? 0
            return NeteaseVIPInfo.Tier(
                level: node["vipLevel"] as? Int ?? 0,
                code: node["vipCode"] as? Int ?? 0,
                // expireTime 是毫秒；0 表示「没有这一档」，别折成 1970-01-01
                expiresAt: expire > 0 ? Date(timeIntervalSince1970: TimeInterval(expire) / 1000) : nil)
        }
        return NeteaseVIPInfo(associator: tier("associator"),
                              musicPackage: tier("musicPackage"),
                              redPlus: tier("redplus"))
    }

    /// 账号等级。`/api/user/level`，**无参数**，走 eapi。
    /// [api-enhanced] `module/user_level.js`（模块文件头上那行中文注释写的是
    /// 「类别热门电台」——**是参考实现自己贴错了注释**，路径与数据都是等级，别被带偏）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"code":302,"message":null}`
    /// （明文 GET 回 301），**要登录**；200 的形状未实机验证过，
    /// 按参考实现 `data` 里有 `level` / `nowPlayCount` / `nextPlayCount` / `progress`。
    ///
    /// 顺带一提：等级这个数在 `user/detail` 的**顶层**也有一份（那条匿名就能读），
    /// 只想显示一个等级数字的话用那条更省事；这条多给的是「离升级还差多少」。
    func userLevel() async -> NeteaseUserLevel? {
        guard let resp = try? await eapi("/api/user/level"),
              let data = resp["data"] as? [String: Any],
              let level = data["level"] as? Int else { return nil }
        return NeteaseUserLevel(
            level: level,
            progress: (data["progress"] as? NSNumber)?.doubleValue ?? 0,
            playCount: data["nowPlayCount"] as? Int ?? 0,
            nextPlayCount: data["nextPlayCount"] as? Int ?? 0,
            loginCount: data["nowLoginCount"] as? Int ?? 0,
            nextLoginCount: data["nextLoginCount"] as? Int ?? 0)
    }

    // MARK: - 登录态维护

    /// 退出登录（让服务端把这份 cookie 作废）。`/api/logout`，**无参数**，走 eapi。
    /// [api-enhanced] `module/logout.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"code":200}`——**匿名打它也回 200**，
    /// 所以返回码说明不了任何事，别拿它当「注销成功」的证据。
    ///
    /// 本地那份凭证不归这里清（那是 `NeteaseLoginStore` 的活，这一轮不碰）；
    /// 这条只负责通知服务端。未登录时直接返回，不发无谓的请求。
    func logout() async throws {
        guard isLoggedIn else { return }
        try await eapi("/api/logout")
    }

    /// 刷新登录 token。`/api/login/token/refresh`，**无参数**，走 eapi。
    /// [api-enhanced] `module/login_refresh.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"msg":null,"code":302,"message":null}`；
    /// 200 的形状未实机验证过。
    ///
    /// **新 cookie 在响应头里，不在响应体里**（参考实现也是从 `result.cookie` 拿的），
    /// 所以这条不能走 `eapi()`——那层只把 JSON 交出来。走 `eapiRaw` 拿到 `HTTPURLResponse`，
    /// 再用现成的 `setCookies(in:url:)` 解（多条 Set-Cookie 会被 URLSession 并成
    /// 一个逗号分隔的头，自己按逗号切会把 Expires 里的日期切断——那个坑已经踩过一次了）。
    ///
    /// 交出来的是这次下发的 cookie 键值对；没有 `MUSIC_U` 就说明服务端没给新的，
    /// 调用方该按「刷新失败」处理。写回本地凭证是 `NeteaseLoginStore` 的事，这轮不碰。
    func refreshLoginToken() async throws -> [String: String] {
        guard isLoggedIn else {
            throw ProviderError.unavailable("请先登录网易云音乐账号")
        }
        let (body, response) = try await eapiRaw("/api/login/token/refresh")
        let code = body["code"] as? Int ?? 200
        guard code == 200 else { throw ProviderError.api("接口错误 code=\(code)") }
        guard let url = response.url else { return [:] }
        return Self.setCookies(in: response, url: url)
    }

    // MARK: - 打卡

    /// 听歌打卡。`/api/feedback/weblog`，参数只有 `logs`（一段 **JSON 字符串**），走 eapi。
    /// [api-enhanced] `module/scrobble.js`
    ///
    /// **一次打卡是两条请求**，参考实现里写得很清楚，两条各干各的：
    /// 1. `action: "startplay"` —— 让这首歌进「最近播放」；
    /// 2. `action: "play"` —— 让「听歌排行」的计数涨一格。
    /// 只发一条会漏掉另一半，所以这里也发两条，顺序照旧。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"code":200,"data":"success","message":""}`
    /// ——**匿名也回 success**，所以返回码同样说明不了打卡真的记上了。
    /// 登录态下的效果未实机验证过。
    ///
    /// 两处与参考实现的出入，都记在这儿：
    /// - 参考实现把域名换成 `clientlog.music.163.com` 并往 cookie 里塞 `os=osx`。
    ///   Amber 的 eapi 通道域名与客户端身份是写死的（`interface.music.163.com` +
    ///   iPhone 9.0.90），改它要动 `NeteaseAPI` 的骨架。**实测默认域名这条路是通的**
    ///   （就是上面那个 200），所以先按默认走；哪天发现打卡不生效，
    ///   第一个要试的就是换 clientlog 域名 + `os=osx`。
    /// - `logs` 那段 JSON 用 `NeteaseJSON` 手工拼而不是 `JSONSerialization`：
    ///   后者的键序每次进程都不一样，而 eapi 的密文只取决于明文字节——
    ///   同一条打卡每次算出不同的 `params`，出了问题没法照着复现。
    ///
    /// - Parameters:
    ///   - sourceID: 从哪儿点进来播的（歌单 id / 专辑 id）。给不出就传空串，
    ///     参考实现原样发 `content: "id="`，服务端不挑。
    ///   - playedSeconds: 已播秒数，进 `play` 那条的 `time`。
    func scrobble(trackID: String, sourceID: String = "", playedSeconds: Int) async throws {
        guard isLoggedIn else {
            throw ProviderError.unavailable("请先登录网易云音乐账号，才能同步听歌记录")
        }
        let id = trackID.rawID
        guard !id.isEmpty else { return }
        let source = sourceID.rawID

        func logs(_ fields: [(String, NeteaseJSON)]) -> String {
            "[" + NeteaseJSON.object(fields).serialized + "]"
        }
        // 1) startplay：进「最近播放」
        let startplay = logs([
            ("action", .string("startplay")),
            ("json", .object([
                ("id", .string(id)), ("type", .string("song")),
                ("mainsite", .string("1")), ("mainsiteWeb", .string("1")),
                ("content", .string("id=\(source)")),
            ])),
        ])
        // 2) play：涨「听歌排行」计数
        let play = logs([
            ("action", .string("play")),
            ("json", .object([
                ("download", 0), ("end", .string("playend")),
                ("id", .string(id)), ("sourceId", .string(source)),
                ("time", .int(playedSeconds)), ("type", .string("song")),
                ("wifi", 0), ("source", .string("list")),
                ("mainsite", .string("1")), ("mainsiteWeb", .string("1")),
                ("content", .string("id=\(source)")),
            ])),
        ])
        try await eapi("/api/feedback/weblog", [("logs", .string(startplay))])
        try await eapi("/api/feedback/weblog", [("logs", .string(play))])
    }

    /// 歌单打卡（让歌单的播放量涨一次）。`/api/playlist/update/playcount`，
    /// 参数 `id`，走 eapi。[api-enhanced] `module/playlist_update_playcount.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"code":200}`——同样是「匿名也回 200」，
    /// 别拿返回码当证据。
    func updatePlaylistPlayCount(_ playlistID: String) async throws {
        guard isLoggedIn else {
            throw ProviderError.unavailable("请先登录网易云音乐账号")
        }
        let id = playlistID.rawID
        guard !id.isEmpty else { return }
        try await eapi("/api/playlist/update/playcount", [("id", .string(id))])
    }

    // MARK: - 内部

    /// `/api/play-record/*/list` 三条的公共部分：参数只有 `limit`，数据在 `data.list`。
    /// 取不到（未登录、请求失败）返回 nil，与「登录了但确实没有记录」的空表分开——
    /// 前者不该在界面上写成「你还没听过歌」。
    private func recentPlayList(_ path: String, limit: Int) async -> [[String: Any]]? {
        guard isLoggedIn else { return nil }
        guard let resp = try? await eapi(path, [("limit", .int(limit))]),
              let data = resp["data"] as? [String: Any] else { return nil }
        return data["list"] as? [[String: Any]] ?? []
    }

    /// 最近播放列表里一项的外壳：真正的专辑/歌单可能被包在 `data` / `resource` 里，
    /// 也可能就是这一项本身。三种都试一遍——这条的真实形状没验证过，
    /// 与其赌一个键名，不如都认。
    private static func unwrapRecord(_ item: [String: Any]) -> [String: Any] {
        if let inner = item["data"] as? [String: Any] { return inner }
        if let inner = item["resource"] as? [String: Any] { return inner }
        return item
    }

    /// 云盘一项 → `NeteaseCloudSong`。曲目以 `simpleSong` 为准；解不出曲目就丢掉这一项。
    private static func parseCloudSong(_ item: [String: Any]) -> NeteaseCloudSong? {
        let raw = (item["simpleSong"] as? [String: Any]) ?? item
        guard let track = Self.parseTrack(raw) else { return nil }
        let addTime = item["addTime"] as? Int ?? 0
        return NeteaseCloudSong(
            track: track,
            fileName: item["fileName"] as? String ?? "",
            fileSize: item["fileSize"] as? Int ?? 0,
            bitrate: item["bitrate"] as? Int ?? 0,
            addedAt: addTime > 0 ? Date(timeIntervalSince1970: TimeInterval(addTime) / 1000) : nil)
    }
}

// MARK: - 只有网易云有的那几类

/// 云盘里的一首歌。曲目本体是统一的 `Track`，外面这几项是云盘特有的
/// （文件名、体积、码率、上传时间），所以留在这个扩展文件里，不进 `ProviderAPIModels`。
struct NeteaseCloudSong: Identifiable, Hashable, Sendable {
    var id: String { track.id }
    let track: Track
    /// 上传时的原始文件名（可能与曲名完全不同，云盘列表里要显示它）
    let fileName: String
    /// 字节
    let fileSize: Int
    /// bps
    let bitrate: Int
    let addedAt: Date?
}

/// 会员信息。三档并列，各自可能缺席（缺席＝没有这一档）。
struct NeteaseVIPInfo: Sendable {
    struct Tier: Sendable {
        let level: Int
        /// 网易的 `vipCode`（不同档位的编号，0 表示没有）
        let code: Int
        /// 到期时间。接口给的是毫秒时间戳，0 表示没有这一档，此时是 nil。
        let expiresAt: Date?

        var isActive: Bool { level > 0 || expiresAt.map { $0 > Date() } == true }
    }
    /// 黑胶 VIP
    let associator: Tier?
    /// 音乐包
    let musicPackage: Tier?
    /// 红钻
    let redPlus: Tier?
}

/// 账号等级与「离升级还差多少」。
struct NeteaseUserLevel: Sendable {
    let level: Int
    /// 0…1 的进度（接口给的就是小数）
    let progress: Double
    let playCount: Int
    let nextPlayCount: Int
    let loginCount: Int
    let nextLoginCount: Int
}
