import Foundation

// QQ 音乐账号里的「资料库写入」那一段：红心、歌单增删歌、建/删歌单、收藏歌单/专辑，
// 以及收藏专辑/MV/关注歌手的读取。
//
// 移植来源：[QQMusicApi] `modules/songlist.py`、`modules/user.py`、`modules/album.py`。
// module/method/param 逐条照抄，没有一条是凭印象写的。
//
// 三条贯穿整个文件的事实，先写在这里，下面就不再重复：
//
// 1. **写接口一律要登录**。[实测 2026-09-09 curl] 匿名打 `PlaylistBaseWrite/AddPlaylist`、
//    `PlaylistDetailWrite/AddSonglist`、`PlaylistFavWrite/FavPlaylist`、`AlbumFavWrite/FavAlbum`
//    全部回 `code=1000`、`data=null`。而 1000 正是 `musicu` 认的「凭证被拒」码之一，
//    未登录还去打它，只会白跑一趟再顺手触发一次登录态复核。所以这边先自己拦
//    （`requireCredential()`），抛 `ProviderError.unavailable`，一个请求都不发。
//    **登录态下成功的响应形状没有实机验证过**，字段名取自参考实现的 models。
//
// 2. **QQ 的接口认数字 id，Amber 的模型里装的是 mid。** 曲目要 `songId`（`CgiGetTrackInfo` 换）、
//    专辑要 `albumId`（`GetAlbumDetail` 换），歌单写操作还要 `dirId`（自建歌单的目录号，
//    与 Amber 用作 id 的 `tid` 不是一个东西，`GetPlaylistByUin` 里两者都给）。
//    每条换算都在下面各自的方法里注明出处。
//
// 3. **读接口取不到就交空表，写接口一律 throws。** 与 `similarArtists` 同一口径：
//    少一段收藏列表不该让页面报错；而写错了是把用户账号里的歌单改坏，必须让调用方知道。

extension QQAPI: MusicLibraryWriting {

    // MARK: - 前置换算

    /// 写接口的登录闸。未登录直接抛，不发请求（理由见文件头第 1 条）。
    func requireCredential() throws -> QQCredential {
        guard let credential = credentialProvider?() else {
            throw ProviderError.unavailable("请先登录 QQ 音乐账号")
        }
        return credential
    }

    /// 收藏类接口只认加密 uin（euin），数字 uin 会回 80050。
    /// 复用 `QQAPI.encryptedUin(uin:)`（从「我喜欢」的 `encrypt_login` 捞，带账号级缓存），
    /// 别再各写各的一份——那会让同一次操作多打一条 `CgiGetDiss`。
    func requireEncryptedUin() async throws -> String {
        let credential = try requireCredential()
        let uin = credential.uin.filter(\.isNumber)
        guard !uin.isEmpty, let euin = await encryptedUin(uin: uin) else {
            throw ProviderError.unavailable("取不到账号的加密 uin，请重新登录后再试")
        }
        return euin
    }

    /// mid → (songId, songType)。歌单写操作的 `v_songInfo` 要的就是这一对
    /// （[QQMusicApi] `modules/songlist.py::_build_songlist_oper_param`）。
    ///
    /// `CgiGetTrackInfo` **收 mids 数组**，一次能换一整批，所以批量加歌只多一条请求，
    /// 不是每首一条（`QQAPI.songID(mid:)` 是单首版，那条给自动连播用）。
    /// [实测 2026-09-09 curl] `mids:["001Bbywq2gicae","0039MnYb0qxYhV"]` → 两条
    /// `tracks[]`，各带 `id`(102065750 / 97773)、`mid`、`type`(0)。按 mid 对回去，
    /// 不靠返回顺序。
    func songEntries(mids: [String]) async -> [(id: Int, type: Int)] {
        let mids = mids.filter { !$0.isEmpty }
        guard !mids.isEmpty else { return [] }
        guard let data = try? await musicu(module: "music.trackInfo.UniformRuleCtrl",
                                           method: "CgiGetTrackInfo",
                                           param: ["mids": mids,
                                                   "types": Array(repeating: 0, count: mids.count)]),
              let tracks = data["tracks"] as? [[String: Any]] else { return [] }
        var byMid: [String: (id: Int, type: Int)] = [:]
        for track in tracks {
            guard let mid = track["mid"] as? String, let id = track["id"] as? Int else { continue }
            byMid[mid] = (id, track["type"] as? Int ?? 0)
        }
        return mids.compactMap { byMid[$0] }
    }

    /// 专辑 mid → 数字 albumId。`AlbumFavWrite` 的 `v_albumId` 只收数字。
    /// [实测 2026-09-09 curl] `GetAlbumDetail{albumMId:"0041WVfh2vtlJE"}` →
    /// `basicInfo.albumID == 87495226`，与搜索结果里那条专辑的 `id` 对得上。
    func albumNumericID(mid: String) async -> Int? {
        guard !mid.isEmpty else { return nil }
        guard let data = try? await musicu(module: "music.musichallAlbum.AlbumInfoServer",
                                           method: "GetAlbumDetail",
                                           param: ["albumMId": mid]),
              let basic = data["basicInfo"] as? [String: Any] else { return nil }
        return basic["albumID"] as? Int
    }

    /// 自建歌单的 `tid` → `dirId`。
    ///
    /// 歌单写操作（`AddSonglist` / `DelSonglist` / `DelPlaylist`）认的是 `dirId`——
    /// 那是**这个账号内部的目录号**（我喜欢固定 201，自建歌单从 2 起编），
    /// 而 Amber 的 `Playlist.id` 里装的是全站唯一的 `tid`（`qq:<tid>`，见
    /// `QQAPI.createdPlaylists`）。两者都在 `GetPlaylistByUin` 的同一条记录里，
    /// 所以这里回头查一次表。
    ///
    /// 没有把 dirId 塞进 `Playlist` 模型：那是共享模型，为一家音源的内部编号加一格
    /// 不划算，而写操作本来就低频（一次点击一次），多一条读请求可以接受。
    func playlistDirID(tid: Int) async throws -> Int {
        let credential = try requireCredential()
        let uin = credential.uin.filter(\.isNumber)
        let data = try await musicu(module: "music.musicasset.PlaylistBaseRead",
                                    method: "GetPlaylistByUin", param: ["uin": uin],
                                    clientType: 11, clientVersion: 12060012)
        let list = data["v_playlist"] as? [[String: Any]] ?? []
        for item in list where (item["tid"] as? Int) == tid {
            // 字段名两种写法都认：`createdPlaylists` 那边实测到的是 dirName / songNum 这套
            // 小驼峰，参考实现的 model 里同时列了 `dirid` 与 `dirId`。
            if let dirID = (item["dirId"] as? Int) ?? (item["dirid"] as? Int) { return dirID }
        }
        throw ProviderError.unavailable("这个歌单不在当前账号的自建歌单里，改不了")
    }

    /// 「我喜欢」的目录号。
    ///
    /// 依据有两处，且互相印证：
    /// - [QQMusicApi] `modules/songlist.py::like_song` 的注释「"我喜欢" 歌单的目录 ID
    ///   固定为 201」，`modules/user.py::get_fav_song` 也是拿 `dirid=201` 读收藏歌曲；
    /// - Amber 自己线上跑着的 `QQAPI.encryptedUin(uin:)` 就是用 `dirid=201` 打 `CgiGetDiss`
    ///   取 `encrypt_login` 的——那条路在实机上稳定出数，说明 201 确实是这个账号的
    ///   「我喜欢」目录（换成别的号取不到）。
    ///
    /// 所以 QQ 这边的红心 = 「往 dirid 201 里加/删歌」，没有独立的红心接口。
    static let favoriteDirID = 201

    // MARK: - 收藏 / 取消收藏

    /// 收藏与取消。QQ 只有曲目、歌单、专辑三类有写接口。
    ///
    /// - 曲目：`music.musicasset.PlaylistDetailWrite/AddSonglist`（红心＝加进「我喜欢」）
    /// - 歌单：`music.musicasset.PlaylistFavWrite/FavPlaylist` / `CancelFavPlaylist`
    /// - 专辑：`music.musicasset.AlbumFavWrite/FavAlbum` / `CancelFavAlbum`
    /// - 歌手 / MV / 电台：**参考实现里没有对应的写接口**（`modules/` 全文只有
    ///   `MVFavRead`、`RelationList` 这类读接口，没有 Fav 写的那一半），所以照实抛，
    ///   不去猜一个 method 名试出来——猜错了是往用户账号上乱写。
    func setFavorite(_ target: FavoriteTarget, favorite: Bool) async throws {
        switch target {
        case .track(let id):
            try await setFavoriteTrack(mid: id.rawID, favorite: favorite)
        case .playlist(let id):
            try await setFavoritePlaylist(tid: id.rawID, favorite: favorite)
        case .album(let id):
            try await setFavoriteAlbum(mid: id.rawID, favorite: favorite)
        case .artist:
            throw ProviderError.unavailable("QQ音乐这边没有关注/取关歌手的写接口")
        case .mv:
            throw ProviderError.unavailable("QQ音乐这边只有收藏 MV 的读接口，没有写接口")
        case .radio:
            throw ProviderError.unavailable("QQ音乐的电台不能收藏")
        }
    }

    /// 红心：加进 / 移出「我喜欢」（dirid 201）。
    /// [QQMusicApi] `modules/songlist.py::like_song` / `unlike_song`。
    private func setFavoriteTrack(mid: String, favorite: Bool) async throws {
        if favorite {
            try await addTracks(["qq:\(mid)"], toDirID: Self.favoriteDirID, tid: 0)
        } else {
            try await removeTracks(["qq:\(mid)"], fromDirID: Self.favoriteDirID, tid: 0)
        }
    }

    /// 收藏别人的歌单。param 的 `uin` 收的是 **euin**，`v_playlistId` 是 tid 数组。
    /// [QQMusicApi] `modules/user.py::fav_songlist` / `unfav_songlist`。
    private func setFavoritePlaylist(tid: String, favorite: Bool) async throws {
        guard let playlistID = Int(tid) else {
            throw ProviderError.unavailable("这个歌单没有 QQ 音乐的数字 id，收藏不了")
        }
        let euin = try await requireEncryptedUin()
        let data = try await musicu(module: "music.musicasset.PlaylistFavWrite",
                                    method: favorite ? "FavPlaylist" : "CancelFavPlaylist",
                                    param: ["uin": euin, "v_playlistId": [playlistID]],
                                    clientType: 11, clientVersion: 12060012)
        // 参考实现判成功的口径：`result == 0` 且这条 id 不在 `v_failedPlaylistId` 里。
        // 顶层 code 非 0 时 `musicu` 已经抛过了，这里只查这两项。
        let failed = (data["v_failedPlaylistId"] as? [Int]) ?? []
        guard (data["result"] as? Int ?? 0) == 0, !failed.contains(playlistID) else {
            throw ProviderError.api(favorite ? "收藏歌单失败" : "取消收藏歌单失败")
        }
    }

    /// 收藏专辑。`v_albumId` 收数字 albumId（不是 mid），所以先换一次。
    /// [QQMusicApi] `modules/album.py::fav_album` / `del_fav_album`。
    private func setFavoriteAlbum(mid: String, favorite: Bool) async throws {
        _ = try requireCredential()
        guard let albumID = await albumNumericID(mid: mid) else {
            throw ProviderError.unavailable("取不到这张专辑的数字 id，收藏不了")
        }
        let data = try await musicu(module: "music.musicasset.AlbumFavWrite",
                                    method: favorite ? "FavAlbum" : "CancelFavAlbum",
                                    param: ["v_albumId": [albumID]],
                                    clientType: 11, clientVersion: 12060012)
        let failed = (data["v_failedAlbumId"] as? [Int]) ?? []
        guard (data["result"] as? Int ?? 0) == 0, !failed.contains(albumID) else {
            throw ProviderError.api(favorite ? "收藏专辑失败" : "取消收藏专辑失败")
        }
    }

    // MARK: - 账号里已有的收藏

    /// 「我喜欢」里的曲目 id 表（Amber 前缀形式）。红心状态靠它一次性拉全。
    ///
    /// 走的是读歌单那条老路：`music.srfDissInfo.DissInfo/CgiGetDiss`，
    /// `dirid=201` + `enc_host_uin=<euin>`（[QQMusicApi] `modules/user.py::get_fav_song`）。
    /// 一页 `song_num` 最多给到歌单上限，这里按 `total_song_num` 往后翻，翻满为止——
    /// 红心表少一页，界面上就有歌该红没红。
    func favoriteTrackIDs() async throws -> [String] {
        let euin = try await requireEncryptedUin()
        var ids: [String] = []
        var begin = 0
        while true {
            let data = try await musicu(
                module: "music.srfDissInfo.DissInfo", method: "CgiGetDiss",
                param: ["disstid": 0, "dirid": Self.favoriteDirID, "tag": false,
                        "song_begin": begin, "song_num": Self.favoritePageSize,
                        "userinfo": false, "orderlist": true, "enc_host_uin": euin],
                clientType: 11, clientVersion: 12060012)
            let page = (data["songlist"] as? [[String: Any]] ?? [])
                .compactMap { $0["mid"] as? String }
                .filter { !$0.isEmpty }
            ids += page.map { "qq:\($0)" }
            begin += Self.favoritePageSize
            let total = (data["total_song_num"] as? Int) ?? ids.count
            if page.isEmpty || ids.count >= total { break }
        }
        return ids.deduped { $0 }
    }

    /// 收藏类列表一页要多少。与 `dissSongLimit` 同一个量级：QQ 歌单上限 1000 首，
    /// 服务端要几首给几首，「我喜欢」通常一两页就翻完了。
    static let favoritePageSize = 500

    /// 收藏的专辑。`music.musicasset.AlbumFavRead/CgiGetAlbumFavInfo`
    /// （[QQMusicApi] `modules/user.py::get_fav_album`），param 的键叫 `euin`（不是 uin）。
    ///
    /// [实测 2026-09-09 curl] 匿名（euin 传空串）回 `code=80000`，
    /// `data` 是一份空壳：`{number:0, hasmore:0, v_list:null, v_failAlbumId:null, total:0, hide:false}`。
    /// 80000 不是登录过期码，只是「这个 euin 没数据」——但空壳也说明了字段名，
    /// 条目形状取自参考实现的 `UserFavAlbumItem`（mid / name / songnum / pubtime / v_singer）。
    func favoriteAlbums() async throws -> [Album] {
        let euin = try await requireEncryptedUin()
        let data = try await musicu(module: "music.musicasset.AlbumFavRead",
                                    method: "CgiGetAlbumFavInfo",
                                    param: ["euin": euin, "offset": 0, "size": Self.favoritePageSize],
                                    clientType: 11, clientVersion: 12060012)
        return (data["v_list"] as? [[String: Any]] ?? []).compactMap { Self.parseFavoriteAlbum($0) }
    }

    /// 收藏专辑条目：字段名跟别处的专辑都不一样（`mid` / `name` / `v_singer` / `songnum`），
    /// 所以单独解一份，别硬塞给 `parseAlbum`（那条认的是 albumMID/albumName）。
    static func parseFavoriteAlbum(_ a: [String: Any]) -> Album? {
        guard let mid = a["mid"] as? String, !mid.isEmpty else { return nil }
        let singers = a["v_singer"] as? [[String: Any]] ?? []
        let artistName = singers.compactMap { $0["name"] as? String }
            .filter { !$0.isEmpty }.joined(separator: " / ")
        return Album(
            id: "qq:\(mid)",
            kind: .qq,
            name: a["name"] as? String ?? "未知专辑",
            artistName: artistName.isEmpty ? "未知歌手" : artistName,
            artistId: (singers.first?["mid"] as? String).map { "qq:\($0)" },
            artworkURL: Self.albumArtwork(mid),
            // `pubtime` 是秒级时间戳（参考实现标的是 int），Music 那行只摆年月日
            publishDate: (a["pubtime"] as? Int).flatMap { Self.dateString(timestamp: $0) },
            trackCount: a["songnum"] as? Int ?? 0,
            description: nil)
    }

    /// 收藏的 MV。`music.musicasset.MVFavRead/getMyFavMV_v2`
    /// （[QQMusicApi] `modules/user.py::get_fav_mv`）。
    /// param 的三个键都很别扭：`encuin`（euin）、`pagesize`（每页几条）、
    /// **`num` 是页码**（从 0 起，参考实现传的是 `page - 1`），不是条数。
    ///
    /// [实测 2026-09-09 curl] 匿名回 `code=1000`、`data=null`，成功态没验证过；
    /// 条目字段取自参考实现的 `UserFavMvItem`（vid / name / picUrl / singerName）。
    func favoriteMVs() async throws -> [MV] {
        let euin = try await requireEncryptedUin()
        let data = try await musicu(module: "music.musicasset.MVFavRead",
                                    method: "getMyFavMV_v2",
                                    param: ["encuin": euin, "pagesize": Self.favoritePageSize, "num": 0],
                                    clientType: 11, clientVersion: 12060012)
        return (data["mvlist"] as? [[String: Any]] ?? []).compactMap { item -> MV? in
            guard let vid = item["vid"] as? String, !vid.isEmpty else { return nil }
            return MV(id: "qq:\(vid)", kind: .qq,
                      title: (item["title"] as? String) ?? (item["name"] as? String) ?? "",
                      artistName: item["singerName"] as? String ?? "",
                      coverURL: Self.httpsURL(item["picUrl"] as? String),
                      duration: TimeInterval(item["duration"] as? Int ?? 0),
                      webURL: URL(string: "https://y.qq.com/n/ryqq/mv/\(vid)")!)
        }
    }

    /// 关注的歌手就是 QQ 这边的「收藏歌手」，接口在 `QQAPI+User.swift`
    /// （`music.concern.RelationList/GetFollowSingerList`）。这里只是把它接到协议上，
    /// 免得资料库那边还要认「QQ 要另外调一个方法」。
    func favoriteArtists() async throws -> [Artist] {
        try await followedArtists()
    }

    /// 侧栏角标用的计数。
    ///
    /// 曲目 / 专辑 / 歌单三项各打一条 `size=1` 的请求，只取返回里的 `total`
    /// （三条接口都给这个字段），不把整张表拉下来。
    /// **MV 那项给不出**：`getMyFavMV_v2` 的响应里没有 total（参考实现的
    /// `UserFavMvResponse` 只有 `mvlist`），要数就得整表拉一遍，为一个角标不值当，
    /// 所以留 nil（模型的约定就是「给不出的项是 nil，不折成 0」）。
    func favoriteCounts() async throws -> FavoriteCounts {
        let euin = try await requireEncryptedUin()
        async let tracks = totalCount(module: "music.srfDissInfo.DissInfo", method: "CgiGetDiss",
                                      param: ["disstid": 0, "dirid": Self.favoriteDirID, "tag": false,
                                              "song_begin": 0, "song_num": 1, "userinfo": false,
                                              "orderlist": true, "enc_host_uin": euin],
                                      key: "total_song_num")
        async let albums = totalCount(module: "music.musicasset.AlbumFavRead",
                                      method: "CgiGetAlbumFavInfo",
                                      param: ["euin": euin, "offset": 0, "size": 1],
                                      key: "total")
        async let playlists = totalCount(module: "music.musicasset.PlaylistFavRead",
                                         method: "CgiGetPlaylistFavInfo",
                                         param: ["uin": euin, "offset": 0, "size": 1],
                                         key: "total")
        var counts = FavoriteCounts()
        counts.tracks = await tracks
        counts.albums = await albums
        counts.playlists = await playlists
        return counts
    }

    /// 只要一个 total 的轻量请求。取不到就是 nil（角标少一个，不该把整块炸掉）。
    private func totalCount(module: String, method: String,
                            param: [String: Any], key: String) async -> Int? {
        guard let data = try? await musicu(module: module, method: method, param: param,
                                           clientType: 11, clientVersion: 12060012) else { return nil }
        return data[key] as? Int
    }

    // MARK: - 歌单增删

    /// 新建歌单。`music.musicasset.PlaylistBaseWrite/AddPlaylist`
    /// （[QQMusicApi] `modules/songlist.py::create`）。
    ///
    /// 两条参考实现里写明的行为：重名不会失败，服务端自己加时间戳；
    /// 返回的 `result` 里带 `tid` / `dirId` / `dirName`。
    /// **QQ 没有「私有歌单」这个参数**（`AddPlaylist` 只收 dirName），
    /// 所以 `isPrivate` 在这一家是无效参数，照实忽略、不假装支持。
    func createPlaylist(name: String, isPrivate: Bool) async throws -> Playlist {
        _ = try requireCredential()
        let data = try await musicu(module: "music.musicasset.PlaylistBaseWrite",
                                    method: "AddPlaylist", param: ["dirName": name],
                                    clientType: 11, clientVersion: 12060012)
        guard (data["retCode"] as? Int ?? 0) == 0,
              let result = data["result"] as? [String: Any],
              let tid = result["tid"] as? Int, tid > 0 else {
            throw ProviderError.api("新建歌单失败")
        }
        return Playlist(id: "qq:\(tid)", kind: .qq,
                        name: (result["dirName"] as? String) ?? name,
                        creatorName: await accountProfile()?.nickname)
    }

    /// 删歌单。`music.musicasset.PlaylistBaseWrite/DelPlaylist`，收的是 **dirId**
    /// （[QQMusicApi] `modules/songlist.py::delete`：删不存在的歌单时返回的 dirid 为 0）。
    func deletePlaylist(_ playlistID: String) async throws {
        guard let tid = Int(playlistID.rawID) else {
            throw ProviderError.unavailable("这个歌单没有 QQ 音乐的数字 id，删不了")
        }
        let dirID = try await playlistDirID(tid: tid)
        let data = try await musicu(module: "music.musicasset.PlaylistBaseWrite",
                                    method: "DelPlaylist", param: ["dirId": dirID],
                                    clientType: 11, clientVersion: 12060012)
        guard (data["retCode"] as? Int ?? 0) == 0 else { throw ProviderError.api("删除歌单失败") }
    }

    /// 往歌单里加歌。`music.musicasset.PlaylistDetailWrite/AddSonglist`。
    func addTracks(_ trackIDs: [String], to playlistID: String) async throws {
        guard let tid = Int(playlistID.rawID) else {
            throw ProviderError.unavailable("这个歌单没有 QQ 音乐的数字 id，加不了歌")
        }
        let dirID = try await playlistDirID(tid: tid)
        try await addTracks(trackIDs, toDirID: dirID, tid: tid)
    }

    /// 从歌单里删歌。`music.musicasset.PlaylistDetailWrite/DelSonglist`。
    func removeTracks(_ trackIDs: [String], from playlistID: String) async throws {
        guard let tid = Int(playlistID.rawID) else {
            throw ProviderError.unavailable("这个歌单没有 QQ 音乐的数字 id，删不了歌")
        }
        let dirID = try await playlistDirID(tid: tid)
        try await removeTracks(trackIDs, fromDirID: dirID, tid: tid)
    }

    private func addTracks(_ trackIDs: [String], toDirID dirID: Int, tid: Int) async throws {
        try await writeSongs(method: "AddSonglist", trackIDs: trackIDs, dirID: dirID, tid: tid,
                             failure: "添加歌曲失败")
    }

    private func removeTracks(_ trackIDs: [String], fromDirID dirID: Int, tid: Int) async throws {
        try await writeSongs(method: "DelSonglist", trackIDs: trackIDs, dirID: dirID, tid: tid,
                             failure: "移除歌曲失败")
    }

    /// 歌单增删歌的公共那一段。
    ///
    /// param 的形状照 [QQMusicApi] `modules/songlist.py::_build_songlist_oper_param`：
    /// `{dirId, tid, bFmtUtf8: true, v_songInfo: [{songId, songType}]}`。
    /// `bFmtUtf8` 要真的是布尔——参考实现在 `add_songs` 那条上专门开了 `preserve_bool=True`
    /// （它默认会把 bool 折成 0/1），说明这个键服务端认的是 JSON 布尔值。
    private func writeSongs(method: String, trackIDs: [String],
                            dirID: Int, tid: Int, failure: String) async throws {
        _ = try requireCredential()
        let mids = trackIDs.map { $0.rawID }.filter { !$0.isEmpty }
        guard !mids.isEmpty else { return }
        let entries = await songEntries(mids: mids)
        guard !entries.isEmpty else {
            throw ProviderError.unavailable("取不到这些歌的数字 id，改不了歌单")
        }
        let songInfo = entries.map { ["songId": $0.id, "songType": $0.type] }
        do {
            let data = try await musicu(module: "music.musicasset.PlaylistDetailWrite",
                                        method: method,
                                        param: ["dirId": dirID, "tid": tid, "bFmtUtf8": true,
                                                "v_songInfo": songInfo],
                                        clientType: 11, clientVersion: 12060012)
            guard (data["retCode"] as? Int ?? 0) == 0 else { throw ProviderError.api(failure) }
        } catch let error as ProviderError where Self.isAlreadySettled(error) {
            // 80092＝「加的歌已经在歌单里 / 删的歌本来就不在」。参考实现在这个码上
            // 返回 False 而不是抛错，对 Amber 来说这就是**目标状态已经达成**，当成功。
            //
            // 按错误文案认码不好看，但 `musicu` 把非 0 的 code 折进了 `.api("接口错误 code=…")`，
            // 外面拿不到结构化的码；而改 `musicu` 的签名不在这一轮的范围里。
            // 只在这一处这么认，别扩散成一种写法。
            return
        }
    }

    /// `musicu` 把 code 折进了错误文案，这里按文本认那一个良性码（见 `writeSongs`）。
    private static func isAlreadySettled(_ error: ProviderError) -> Bool {
        guard case .api(let message) = error else { return false }
        return message.contains("code=80092")
    }

    /// 秒级时间戳 → `yyyy-MM-dd`（收藏专辑那条给的是时间戳，模型要的是字符串）。
    private static func dateString(timestamp: Int) -> String? {
        guard timestamp > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}
