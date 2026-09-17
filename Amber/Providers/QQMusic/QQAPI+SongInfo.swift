import Foundation

// 单曲的附加信息：标签、其他版本、制作人、相关歌单、粉丝数、歌曲详情、CDN 调度、曲谱。
// 移植来源：[QQMusicApi] `modules/song.py`。
//
// 三条贯穿全文件的事实：
//
// 1. **这一批全部匿名可用**。[实测 2026-09-09 curl] 下面每一条读接口都是不带 comm、
//    不带 cookie 直接打 `musicu.fcg` 就回 code 0（曲谱那三条要自带 comm，见下），
//    所以一律走 `musicu` 的默认档。
//
// 2. **接口只认数字 songid / songMid，看方法而定。** Amber 的曲目 id 是 `qq:<mid>`，
//    要数字的那几条先走现成的 `songID(mid:)`（`CgiGetTrackInfo`，带一条额外请求）。
//    参考实现里凡是 `value: int | str` 的方法都同时收两种键（数字用 `songid`，
//    mid 用 `songmid`），能用 mid 的就用 mid，省掉那次换算——下面逐条注明走的是哪一路。
//
// 3. **`GetSimilarSongs` 不在这个文件里，也不许再实现一份。** 它已经是
//    `QQAPI.similarTracks`（自动连播那条路），`design-ref/todo.md` §3 记过账：
//    自动连播承诺的是「与当前这首相似」，只有它满足；这里的标签/相关歌单/其他版本
//    都不是候选源，别接过去。
//
// 读接口取不到就交空/nil（协议口径），这一批没有写接口。

extension QQAPI {

    // MARK: - 歌曲标签

    /// 播放页歌曲名底下那排小标签（曲风、成就、「87%的人听完」这类）。
    struct QQSongLabel: Hashable, Sendable {
        let id: Int
        /// 展示文案。纯图标标签（`tagType 24`/`20`/`23` 那几个）这里可能是空串
        let text: String
        let iconURL: String?
        /// 点进去的地址。有 http(s) 的网页地址，也有 `qqmusic://` 的客户端 scheme——
        /// Amber 只用得上前者，后者原样留着（判断能不能点归调用方）
        let jumpURL: String?
        /// 标签大类（`tagType`）
        let type: Int
    }

    /// 歌曲标签。`music.recommend.TrackRelationServer/GetSongLabels`
    /// （[QQMusicApi] `modules/song.py::get_labels`），param `{songid: <数字 id>}`。
    ///
    /// 与 `GetSimilarSongs` 同一个 module，但**不是**同一件事：这条只回标签，
    /// 不回歌（见文件头第 3 条）。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，songid=107192078（告白气球）回 `labels[]` 9 条：
    /// `{id, tagTxt, tagIcon, tagUrl, tagType, species}`。真实取值示例——
    /// `"传唱TOP100"`(tagType 0)、`"87%的人听完"`(31)、`"#Pop"`(1)、`"金曲奖提名"`(6)、
    /// `"收藏999w+"`(9)、`"10852人在听"`(23)。前三条 `tagTxt` 是空串只有图标。
    func songLabels(_ track: Track) async -> [QQSongLabel] {
        guard let songID = await songID(mid: track.id.rawID) else { return [] }
        return await catalogCache.value(for: "qq:TrackRelationServer.GetSongLabels?id=\(songID)") {
            guard let data = try? await self.musicu(module: "music.recommend.TrackRelationServer",
                                                    method: "GetSongLabels",
                                                    param: ["songid": songID]) else { return nil }
            return (data["labels"] as? [[String: Any]] ?? []).compactMap { l -> QQSongLabel? in
                guard let id = l["id"] as? Int else { return nil }
                return QQSongLabel(id: id,
                                   text: l["tagTxt"] as? String ?? "",
                                   iconURL: Self.httpsURL(l["tagIcon"] as? String),
                                   jumpURL: (l["tagUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                   type: l["tagType"] as? Int ?? 0)
            }
        } ?? []
    }

    // MARK: - 其他版本

    /// 这首歌的其他版本（Live、翻唱、女声版、多语言版…）。
    /// `music.musichallSong.OtherVersionServer/GetOtherVersionSongs`
    /// （[QQMusicApi] `modules/song.py::get_other_version`）。
    ///
    /// **走 mid 那一路**（`songmid`），省掉一次 `CgiGetTrackInfo`：参考实现里
    /// 这条同时收 `songid` 与 `songmid`，我们手上本来就是 mid。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，`songmid=003OUlho2HcRHC`（告白气球）回
    /// `versionList[]` 10 条，**每条就是标准歌曲对象**（`id`/`mid`/`name`/`title`/
    /// `singer[]`/`album`/`file`/`interval` 全在），所以直接交给 `parseTrack`——
    /// 不用另写解析。真实内容：成毅的 Live 版、二珂/曲肖冰的翻唱、王俊凯版、
    /// 「14种语言翻唱版」等。同级还有 `extras[]`（每条一个 `tag`，与 versionList 一一对应）
    /// 与 `songTagInfoList`（这次是 null），本轮用不上。
    ///
    /// 注意 `title` 才是带后缀的那个（「告白气球 (Live)」），`name` 都是「告白气球」；
    /// `parseTrack` 取的是 `name`，所以版本列表在界面上要区分只能靠歌手/专辑列——
    /// 真要显示 `title` 得改 `parseTrack`，那是共享解析器，不在这一轮动。
    func otherVersions(of track: Track) async -> [Track] {
        let mid = track.id.rawID
        guard !mid.isEmpty else { return [] }
        return await catalogCache.value(for: "qq:OtherVersionServer?mid=\(mid)") {
            guard let data = try? await self.musicu(module: "music.musichallSong.OtherVersionServer",
                                                    method: "GetOtherVersionSongs",
                                                    param: ["songmid": mid]) else { return nil }
            return (data["versionList"] as? [[String: Any]] ?? [])
                .compactMap { Self.parseTrack($0) }
                .dedupedByID()
        } ?? []
    }

    // MARK: - 制作人

    /// 一首歌的创作者表（词/曲/编曲/演唱…）。
    /// `music.sociality.KolWorksTag/SongProducer`
    /// （[QQMusicApi] `modules/song.py::get_producer`），同样走 mid 那一路。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，告白气球回 `Lst[]` 4 组：
    /// `{Title: "演唱"|"作词"|"作曲"|"编曲", Type, Producers: [{Name, SingerMid, Icon, Scheme}]}`，
    /// 内容是 周杰伦 / 方文山 / 周杰伦 / 林迈可。同级还有一句现成的
    /// `ReinforceMsg: "词：方文山 / 曲：周杰伦 / 编曲：林迈可"`（见 `songCreditLine`）。
    ///
    /// 角色名由接口给（中文、逐曲不同），所以直接装进 `TrackCredit.role`——
    /// 共享模型那边不做成枚举正是这个理由。
    func songProducers(_ track: Track) async -> [TrackCredit] {
        let mid = track.id.rawID
        guard !mid.isEmpty else { return [] }
        return await catalogCache.value(for: "qq:KolWorksTag.SongProducer?mid=\(mid)") {
            guard let data = try? await self.musicu(module: "music.sociality.KolWorksTag",
                                                    method: "SongProducer",
                                                    param: ["songmid": mid]) else { return nil }
            return (data["Lst"] as? [[String: Any]] ?? []).compactMap { group -> TrackCredit? in
                guard let role = group["Title"] as? String, !role.isEmpty else { return nil }
                let names = (group["Producers"] as? [[String: Any]] ?? [])
                    .compactMap { $0["Name"] as? String }
                    .filter { !$0.isEmpty }
                return names.isEmpty ? nil : TrackCredit(role: role, names: names)
            }
        } ?? []
    }

    /// 服务端已经拼好的那一行创作者文案（`ReinforceMsg`）。
    /// 与 `songProducers` 同一条请求（走同一个缓存键），要一行字时不必自己拼。
    func songCreditLine(_ track: Track) async -> String? {
        let mid = track.id.rawID
        guard !mid.isEmpty else { return nil }
        guard let data = try? await musicu(module: "music.sociality.KolWorksTag",
                                           method: "SongProducer",
                                           param: ["songmid": mid]) else { return nil }
        return (data["ReinforceMsg"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - 相关歌单

    /// 「收录这首歌的歌单」。`music.recommend.TrackRelationServer/GetRelatedPlaylist`
    /// （[QQMusicApi] `modules/song.py::get_related_songlist`）。
    ///
    /// 翻页方式很特别：参考实现走的是 `BatchRefreshStrategy`——**把上一批的歌单 id
    /// 原样回传给 `vecPlaylist`**，服务端据此换一批（不是 offset 也不是游标）。
    /// 所以 `exclude` 收的是「已经看过的 tid」，第一次传空数组。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，songid=107192078 回 `vecPlaylist[]` 3 条 +
    /// `hasMore`；条目是 `{tid, songNum, cover, title, creator, playCnt}`——
    /// **字段名跟别处的歌单全不一样**（`parseSearchPlaylist` 认 dissid/dissname/imgurl，
    /// `parseFeedPlaylist` 认 Playlist.basic），所以这里单独解一份。
    /// `playCnt` 实测是空字符串（不是数字），所以播放量留 0 不猜；
    /// `hasMore` 实测是数字 1（参考实现的 model 标的是 bool），按数字判。
    /// 同级还有个 `vecPlaylistNew`，本轮不读——两段的关系没验证过，不凭想象合并。
    func relatedPlaylists(of track: Track, excluding exclude: [Int] = []) async -> (playlists: [Playlist], hasMore: Bool) {
        guard let songID = await songID(mid: track.id.rawID) else { return ([], false) }
        guard let data = try? await musicu(module: "music.recommend.TrackRelationServer",
                                           method: "GetRelatedPlaylist",
                                           param: ["songid": songID, "vecPlaylist": exclude]) else {
            return ([], false)
        }
        let list = (data["vecPlaylist"] as? [[String: Any]] ?? []).compactMap { p -> Playlist? in
            guard let tid = p["tid"] as? Int else { return nil }
            return Playlist(id: "qq:\(tid)", kind: .qq,
                            name: p["title"] as? String ?? "歌单",
                            coverURL: Self.httpsURL(p["cover"] as? String),
                            trackCount: p["songNum"] as? Int ?? 0,
                            creatorName: (p["creator"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        return (list, (data["hasMore"] as? Int ?? 0) == 1)
    }

    // MARK: - 收藏数

    /// 一批歌各自的收藏人数。`music.musicasset.SongFavRead/GetSongFansNumberById`
    /// （[QQMusicApi] `modules/song.py::get_fav_num`），param `{v_songId: [数字 id…]}`。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，`v_songId:[107192078,102065750]` 回两张表：
    /// `m_numbers`（**以 songid 的字符串形式为键**的数字，两首都是 1000001）与
    /// `m_show`（同一批键，值是文案 `"4000w+"` / `"3400w+"`）。
    ///
    /// 注意 `m_numbers` 的 1000001 明显是个封顶值（两首不同热度的歌一模一样），
    /// 真要给用户看就用 `m_show` 那份文案——所以这里两样都交出去，别只留数字。
    ///
    /// 返回值以 **mid** 为键（调用方手上就是 mid）。mid→songid 这一步没有复用
    /// `songEntries(mids:)`：那条方法把换不出来的 mid 直接丢掉（`compactMap`），
    /// 返回的数组与入参**长度可能不等**，按位置 zip 回去就会串行——
    /// 这里要的是一张对得住的表，所以自己收一次 `CgiGetTrackInfo` 的 `mid`↔`id`。
    /// 请求本身与那条完全一样（一条请求换一整批），不是多打了接口。
    func songFanCounts(_ tracks: [Track]) async -> [String: (count: Int, display: String)] {
        let mids = tracks.map { $0.id.rawID }.filter { !$0.isEmpty }
        guard !mids.isEmpty else { return [:] }
        guard let info = try? await musicu(module: "music.trackInfo.UniformRuleCtrl",
                                           method: "CgiGetTrackInfo",
                                           param: ["mids": mids,
                                                   "types": Array(repeating: 0, count: mids.count)]),
              let entries = info["tracks"] as? [[String: Any]] else { return [:] }
        var idByMid: [String: Int] = [:]
        for entry in entries {
            guard let mid = entry["mid"] as? String, let id = entry["id"] as? Int else { continue }
            idByMid[mid] = id
        }
        guard !idByMid.isEmpty else { return [:] }
        guard let data = try? await musicu(module: "music.musicasset.SongFavRead",
                                           method: "GetSongFansNumberById",
                                           param: ["v_songId": Array(idByMid.values)]) else { return [:] }
        let numbers = data["m_numbers"] as? [String: Int] ?? [:]
        let shows = data["m_show"] as? [String: String] ?? [:]
        // 两张表的键是 songid 的**字符串**形式，换回 mid 交出去
        var result: [String: (count: Int, display: String)] = [:]
        for (mid, id) in idByMid {
            let key = String(id)
            guard numbers[key] != nil || shows[key] != nil else { continue }
            result[mid] = (numbers[key] ?? 0, shows[key] ?? "")
        }
        return result
    }

    // MARK: - 歌曲详情（网页版那份）

    /// 歌曲详情里的几段文字（简介、流派、语种、唱片公司、发行时间）。
    struct QQSongExtraInfo: Sendable {
        var introduction: String?
        var genre: String?
        var language: String?
        var company: String?
        var publishDate: String?
    }

    /// 歌曲详情。`music.pf_song_detail_svr/get_song_detail_yqq`
    /// （[QQMusicApi] `modules/song.py::get_detail`），走 mid 那一路（`song_mid`）。
    ///
    /// **与基线的 `CgiGetTrackInfo` 并存，两条拿的是不同的东西**：
    /// - `CgiGetTrackInfo`（`music.trackInfo.UniformRuleCtrl`，见 `songID(mid:)` 与
    ///   `songEntries(mids:)`）拿的是**播放要用的那一份**：数字 id、songType、
    ///   各档位文件大小；它收 mids **数组**，一次能换一整批；
    /// - 这一条拿的是**页面上要显示的那一份**：一段编辑写的简介、流派、语种、唱片公司。
    ///   它一次只问一首，且这些字段 `CgiGetTrackInfo` 一个都不给。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，`song_mid=003OUlho2HcRHC` 回三段：
    /// `info`（分节的展示信息）、`extras`（`{name, transname, subtitle, wikiurl}`）、
    /// `track_info`（标准歌曲对象）。`info` 下每节形如
    /// `{title: "唱片公司", content: [{value: "杰威尔音乐有限公司", …}], type, pos}`，
    /// 这次实测到 5 节：company / genre("R&B") / intro(一段 200 余字的编辑简介) /
    /// lan("国语") / pub_time("2016-06-24")。**值都在 `content[].value` 里**，不是 title 上。
    func songExtraInfo(_ track: Track) async -> QQSongExtraInfo? {
        let mid = track.id.rawID
        guard !mid.isEmpty else { return nil }
        return await catalogCache.value(for: "qq:pf_song_detail_svr?mid=\(mid)") {
            guard let data = try? await self.musicu(module: "music.pf_song_detail_svr",
                                                    method: "get_song_detail_yqq",
                                                    param: ["song_mid": mid]),
                  let info = data["info"] as? [String: Any] else { return nil }
            func section(_ key: String) -> String? {
                guard let node = info[key] as? [String: Any],
                      let content = node["content"] as? [[String: Any]] else { return nil }
                let values = content.compactMap { $0["value"] as? String }.filter { !$0.isEmpty }
                return values.isEmpty ? nil : values.joined(separator: " / ")
            }
            return QQSongExtraInfo(introduction: section("intro"),
                                   genre: section("genre"),
                                   language: section("lan"),
                                   company: section("company"),
                                   publishDate: section("pub_time"))
        }
    }

    // MARK: - CDN 调度

    /// 取流域名的调度结果。
    struct QQCdnDispatch: Sendable {
        /// 普通取流的 CDN 前缀表（`sip`）
        let servers: [String]
        /// 免流卡用的那一组（`freeflowsip`）
        let freeflowServers: [String]
    }

    /// CDN 调度。`music.audioCdnDispatch.cdnDispatch/GetCdnDispatch`
    /// （[QQMusicApi] `modules/song.py::get_cdn_dispatch`）。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，回 `sip[]` 7 条、`freeflowsip[]` 4 条，
    /// 形如 `http://ws.stream.qqmusic.qq.com/`、`http://121.204.225.148/amobile.music.tc.qq.com/`
    /// （**全是 http，还有直接给 IP 的**），另带 `testfile2g` / `testfilewifi` 两条测速用的
    /// 带 vkey 的相对地址。
    ///
    /// 只交出地址表，**不去替换取流路径**：`trackStreamURL` 现在用的是
    /// `UrlGetVkey` 自己回的 `sip` + 一条 `fallbackCDN` 兜底，那条路是实机验证过的；
    /// 这里给的 http 地址还要过 ATS，换过去是另一件事，不在这一轮。
    func cdnDispatch() async -> QQCdnDispatch? {
        await catalogCache.value(for: "qq:audioCdnDispatch.GetCdnDispatch") {
            guard let data = try? await self.musicu(module: "music.audioCdnDispatch.cdnDispatch",
                                                    method: "GetCdnDispatch",
                                                    param: ["guid": Self.sheetGuid, "uid": "0",
                                                            "use_new_domain": 1, "use_ipv6": 1]) else {
                return nil
            }
            return QQCdnDispatch(servers: data["sip"] as? [String] ?? [],
                                 freeflowServers: data["freeflowsip"] as? [String] ?? [])
        }
    }

    /// CDN 调度那条要的 guid。它只用来做调度的分桶，不参与取流鉴权
    /// （取流那条走 `QQAPI` 自己的 `guid`，是 private 的、也不该给别的接口共用）。
    private static let sheetGuid = "1234567890"

    // MARK: - 曲谱

    /// 一份曲谱。
    struct QQSheetMusic: Hashable, Sendable {
        let id: String
        let name: String
        /// 「简谱」「五线谱」「其他曲谱」
        let scoreType: String
        /// 「钢琴」「吉他」这类
        let instrument: String
        /// 「弹唱版」「演奏版」，虫虫那一路是空的
        let version: String
        /// 谱面图（虫虫那一路给的是 null，只能走 `webURL` 看）
        let pageURLs: [String]
        let coverURL: String?
        let uploader: String
        let viewCount: Int
        /// 网页版谱面地址
        let webURL: String?
    }

    /// 曲谱来源。`ttype` 与 `scoreType` 的组合照 [QQMusicApi] `modules/song.py::get_sheet`。
    enum QQSheetSource: Sendable {
        /// 用户上传（ttype 0 / scoreType -1）
        case user
        /// 引擎生成 / AI 曲谱（ttype 1 / scoreType -473）
        case engine
        /// 虫虫钢琴（走 `GetChongChongSheetMusic`，**必须签名**，见 `signedSheetRequest`）
        case chongchong
    }

    /// 这首歌有没有曲谱。`music.mir.SheetMusicSvr/HasSheetMusic`
    /// （[QQMusicApi] `modules/song.py::has_sheet`），param `{songMid: <mid>}`。
    ///
    /// **这一族接口要自带 comm**：参考实现在三条上都开了 `override_comm`，塞的是
    /// 一份 h5 风格的 comm（`g_tk`/`uin`/`format`/`inCharset`/`outCharset`/`notice`/`needNewCode`），
    /// 与 `musicu` 平时那份（cv/ct/uin/g_tk）不是一套。`musicu` 的 `commOverride`
    /// 正好是干这个的，所以这里显式补一份。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，告白气球回
    /// `{hasGuitar: true, hasMore: true, hasLDY: true, hasQRCX: true, hasChongChong: true}`。
    /// 五个布尔各自对应一路谱源；这里只把整体「有没有」与虫虫那一路交出去——
    /// LDY / QRCX 两个键在参考实现里也没有对应的取谱接口，留着也没处用。
    func hasSheetMusic(_ track: Track) async -> (hasAny: Bool, chongchong: Bool) {
        let mid = track.id.rawID
        guard !mid.isEmpty else { return (false, false) }
        guard let data = try? await musicu(module: "music.mir.SheetMusicSvr",
                                           method: "HasSheetMusic",
                                           param: ["songMid": mid],
                                           commOverride: Self.sheetComm) else { return (false, false) }
        let flags = ["hasGuitar", "hasMore", "hasLDY", "hasQRCX", "hasChongChong"]
        let hasAny = flags.contains { (data[$0] as? Bool) == true }
        return (hasAny, (data["hasChongChong"] as? Bool) == true)
    }

    /// 取曲谱。用户上传与引擎两路走 `GetMoreSheetMusic`，虫虫那一路走
    /// `GetChongChongSheetMusic`（[QQMusicApi] `modules/song.py::get_sheet`）。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0：
    /// - `.user`（ttype 0 / scoreType -1）→ `result[]`，第一条是「告白气球 / 弹唱版 /
    ///   简谱 / 上传者 向幸福加油 / viewFrequency 22379」，`picURLs[]` 里是谱面图；
    /// - `.engine`（ttype 1 / scoreType -473）→ 「演奏版 / 五线谱 / 新的开始 / 10608」，
    ///   `picURLs` 有 2 张；
    /// - `.chongchong` → 「告白气球_周杰伦——完美还原版 / 其他曲谱 / B调·虫虫钢琴」，
    ///   `picURLs` 是 **null**，只有 `url` 那条 h5 地址能看。
    ///
    /// 参考实现在前两路上放行了错误码 10007（「没有曲谱」不算错），这里的口径是
    /// 「读接口取不到就交空表」，所以整条吞掉——10007 与网络失败在调用方看来一样是空。
    func sheetMusic(_ track: Track, source: QQSheetSource = .user,
                    limit: Int = 100) async -> [QQSheetMusic] {
        let mid = track.id.rawID
        guard !mid.isEmpty else { return [] }
        let data: [String: Any]?
        switch source {
        case .user, .engine:
            let ttype = source == .engine ? 1 : 0
            let scoreType = source == .engine ? -473 : -1
            data = try? await musicu(module: "music.mir.SheetMusicSvr",
                                     method: "GetMoreSheetMusic",
                                     param: ["songMid": mid, "begin": 0, "end": limit,
                                             "scoreType": scoreType, "ttype": ttype],
                                     commOverride: Self.sheetComm)
        case .chongchong:
            data = try? await signedSheetRequest(mid: mid, limit: limit)
        }
        return (data?["result"] as? [[String: Any]] ?? []).compactMap { s -> QQSheetMusic? in
            guard let id = s["scoreMID"] as? String, !id.isEmpty else { return nil }
            return QQSheetMusic(
                id: id,
                name: s["scoreName"] as? String ?? "",
                scoreType: s["strScoreType"] as? String ?? "",
                instrument: s["strInsType"] as? String ?? "",
                version: s["version"] as? String ?? "",
                pageURLs: (s["picURLs"] as? [String] ?? []).compactMap { Self.httpsURL($0) },
                coverURL: Self.httpsURL(s["coverURL"] as? String),
                uploader: (s["uploader"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (s["author"] as? String ?? ""),
                viewCount: s["viewFrequency"] as? Int ?? 0,
                webURL: (s["url"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// 曲谱这一族要的 h5 comm（照 [QQMusicApi] `modules/song.py::get_sheet` 的 `comm=`）。
    /// 虫虫那一路多一个 `platform: "h5"`，见 `signedSheetRequest`。
    // 写成计算属性而不是 `static let`：`[String: Any]` 不是 Sendable，当存储属性就是全局可变状态。
    // 这几个键值是每条请求都要现拼进去的，没有存下来的必要。
    private static var sheetComm: [String: Any] { [
        "g_tk": 5381, "uin": "", "format": "json",
        "inCharset": "utf-8", "outCharset": "utf-8",
        "notice": 0, "needNewCode": 1,
    ] }

    /// 虫虫钢琴那条**必须走签名网关**（`musics.fcg?_=<毫秒>&sign=<zzc…>`）。
    ///
    /// [实测 2026-09-09 curl] 同一份 param 打普通的 `musicu.fcg` 回 `code=500031`；
    /// 换成签名网关立刻回 code 0 与整张谱表。所以 500031 在这条上就是「没签名」，
    /// 不是参数错、更不是登录过期。
    ///
    /// 发请求的壳与签名都走 `QQAPI.signedMusicu`（`QQAPI+User.swift`），这里只把
    /// 这条特有的两样东西交给它：h5 身份的 comm、网页 UA。签名算的是**将要发出去的
    /// 那串字节**，所以序列化只能发生一次——这件事由 `signedMusicu` 负责，别在这儿
    /// 再拼一份 payload 出来。
    private func signedSheetRequest(mid: String, limit: Int) async throws -> [String: Any] {
        var comm = Self.sheetComm
        comm["platform"] = "h5"
        return try await signedMusicu(
            module: "music.mir.SheetMusicSvr",
            method: "GetChongChongSheetMusic",
            param: ["songMid": mid, "begin": 0, "end": limit,
                    "scoreType": -1, "ttype": 1],
            commOverride: comm,
            userAgent: Self.UA)
    }
}
