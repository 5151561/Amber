import Foundation

/// 网易云的电台/播客那一整块，以及与它同源但完全另一套数据的「广播电台」（voice/broadcast）。
///
/// 基线里只接了两条：`djradio/hot/v1`（目录页那格「热门电台」）与 `dj/program/byradio`
/// （电台详情页的节目单）。Amber 的「广播」页真要做起来，缺的是分类、精选、各种榜、
/// 以及电台自己的详情对象——这个文件把它们补齐。
///
/// **通道一律走 eapi。** 参考实现这一批标的多半是 `weapi`（`dj_catelist` / `dj_recommend` /
/// `dj_toplist`…），Amber 没有 weapi 那条路；同样的路径同样的参数 eapi 都认，
/// 下面每条都用匿名 eapi 探针实打过。
///
/// **这一批基本全部匿名可读**——与收藏那批（`+Library.swift`）不同，那边匿名清一色 301，
/// 这边只有「我的收藏」与「收藏/取消收藏」两条要登录。所以除了那两条，其余读接口
/// 一律「取不到就返回空」，不抛。
///
/// 注意 `dj_sub` / `dj_sublist`（订阅电台、订阅列表）第一轮已经在 `+Library.swift` 里，
/// 分别是 `setFavorite(.radio(_:))` 与 `favoriteRadios()`，这里不重复。
extension NeteaseAPI {

    // MARK: - 分类与推荐

    /// 电台分类列表。`/api/djradio/category/get`，**无参数**，走 eapi。
    /// [api-enhanced] `module/dj_catelist.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`，`categories` 一整串，
    /// 每项形如 `{"name":"情感","id":3,…}`，另外带**十来种尺寸的分类图**
    /// （`picPCWhiteUrl` / `picMacUrl` / `pic96x96Url` / `picIPadUrl`…）。
    /// Amber 只取 `picMacUrl`（Mac 客户端那一张），取不到再退 `pic96x96Url`——
    /// 其余那些是给 iPad / UWP / 深浅色主题用的，塞进模型只会让人以为有得选。
    func djCategories() async -> [NeteaseDJCategory] {
        guard let resp = try? await eapi("/api/djradio/category/get"),
              let list = resp["categories"] as? [[String: Any]] else { return [] }
        return list.compactMap { NeteaseDJCategory($0) }
    }

    /// 首页按分类分组的推荐电台。`/api/djradio/home/category/recommend`，**无参数**，走 eapi。
    /// [api-enhanced] `module/dj_category_recommend.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`，`data` 12 组，
    /// 每组 `{categoryId, categoryName, radios:[…]}`——**一次请求就够铺满一整个分区页**，
    /// 比按分类逐条打 `dj_recommend_type` 划算得多。
    func djCategoryRecommendations() async -> [NeteaseDJCategoryRadios] {
        guard let resp = try? await eapi("/api/djradio/home/category/recommend"),
              let data = resp["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { group in
            guard let name = group["categoryName"] as? String else { return nil }
            let radios = (group["radios"] as? [[String: Any]] ?? []).compactMap { Self.parseDJRadio($0) }
            guard !radios.isEmpty else { return nil }
            return NeteaseDJCategoryRadios(
                categoryID: (group["categoryId"] as? Int).map(String.init),
                categoryName: name,
                radios: radios)
        }
    }

    /// 精选电台。`/api/djradio/recommend/v1`，**无参数**，走 eapi。
    /// [api-enhanced] `module/dj_recommend.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`djRadios` 10 条，
    /// 另有一个 `name` 字段是这一批的**主题名**（实测拿到的是 `"精选电台 - 谈情说爱"`）
    /// ——它每次刷新会变，是这批推荐的标题而不是固定栏目名，所以一起交出去。
    func recommendedRadios() async -> (title: String?, radios: [Playlist]) {
        guard let resp = try? await eapi("/api/djradio/recommend/v1") else { return (nil, []) }
        let radios = (resp["djRadios"] as? [[String: Any]] ?? []).compactMap { Self.parseDJRadio($0) }
        return ((resp["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }, radios)
    }

    /// 某个分类下的精选电台。`/api/djradio/recommend`，参数 `cateId`，走 eapi。
    /// [api-enhanced] `module/dj_recommend_type.js`（那边标的是 weapi）
    ///
    /// 分类 id 从 `djCategories()` 拿；参考实现在文件头列了一份写死的对照表
    /// （有声书 10001 / 知识技能 453050 / 人文历史 11 / 情感调频 3 …），
    /// **这里不抄那份表**——它是那个项目某一天的快照，接口本来就现给，写死只会过期。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `cateId=2`（音乐播客）回 `code:200`、
    /// `djRadios` 10 条 + 顶层 `hasMore:true`。注意这条**不收 limit/offset**，
    /// 想要更多只能靠 `hasMore`……而它没给游标，所以实际就是「一屏」。
    func recommendedRadios(categoryID: String) async -> [Playlist] {
        guard let resp = try? await eapi("/api/djradio/recommend",
                                         [("cateId", .string(categoryID))]),
              let list = resp["djRadios"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parseDJRadio($0) }
    }

    /// 个性化推荐电台。`/api/djradio/personalize/rcmd`，参数 `limit`（参考实现默认 6），走 eapi。
    /// [api-enhanced] `module/dj_personalize_recommend.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`data` 6 条
    /// ——**匿名也给**，只是给的是大众口味（未登录时没有「个性」可言）。
    /// 键名是 `data` 不是 `djRadios`，别照别的电台接口猜。
    func personalizedRadios(limit: Int = 6) async -> [Playlist] {
        guard let resp = try? await eapi("/api/djradio/personalize/rcmd", [("limit", .int(limit))]),
              let list = resp["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parseDJRadio($0) }
    }

    /// 今日优选。`/api/djradio/home/today/perfered`（**`perfered`，接口自己拼错了**，
    /// 别顺手改成 preferred），参数 `page`，走 eapi。
    /// [api-enhanced] `module/dj_today_perfered.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"code":200,"msg":null,"data":[]}`
    /// ——**通了但是空表**。空表是不是「未登录就没有今日优选」还是「当天真没有」，
    /// 匿名分不出来；登录态未实机验证过。按 `data` 是电台数组解析。
    func todayPreferredRadios(page: Int = 0) async -> [Playlist] {
        guard let resp = try? await eapi("/api/djradio/home/today/perfered", [("page", .int(page))]),
              let list = resp["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parseDJRadio($0) }
    }

    /// 付费电台（「付费精品」分区）。`/api/djradio/home/paygift/list`，
    /// 参数 `limit` / `offset` / `_nmclfl=1`，走 eapi。
    /// [api-enhanced] `module/dj_paygift.js`（那边标的是 weapi）
    ///
    /// `_nmclfl` 是客户端原样发的常量（参考实现里写死 1），照抄。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`，`data` 是个**对象**
    /// （`{hasMore, list}`）而不是数组，`list` 每项 `{id,name,rcmdText,picUrl,
    /// programCount,subCount,playCount,originalPrice,discountPrice,…}`
    /// ——字段名与 `parseDJRadio` 认的那套对得上（`rcmdText` 大小写与 `rcmdtext` 不同，
    /// 所以描述这里自己补）。
    func payGiftRadios(limit: Int = 30, offset: Int = 0) async -> [Playlist] {
        guard let resp = try? await eapi("/api/djradio/home/paygift/list", [
            ("limit", .int(limit)), ("offset", .int(offset)), ("_nmclfl", .int(1)),
        ]), let list = (resp["data"] as? [String: Any])?["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            var radio = Self.parseDJRadio(item)
            // 付费列表用 rcmdText（大写 T），parseDJRadio 认的是 rcmdtext / desc
            if radio?.description == nil, let text = item["rcmdText"] as? String, !text.isEmpty {
                radio?.description = text
            }
            return radio
        }
    }

    // MARK: - 电台详情与节目

    /// 电台详情。`/api/djradio/v2/get`，参数 `id`，走 eapi。
    /// [api-enhanced] `module/dj_detail.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名拿真实电台 id（792544462）回 `code:200`，
    /// `data` 里有 `id/name/picUrl/desc/subCount/programCount/commentCount/
    /// category/secondCategory/dj/rcmdText/subed/feeInfo`；
    /// **id 不存在时回的是 `{"code":404,"msg":"radio not exist"}`**（不是空 data），
    /// 所以「查不到」这条路上 `eapi` 会替我们抛，这里 `try?` 折成 nil。
    ///
    /// 与基线 `djRadioDetail(_:)` 的关系：基线是从**节目列表的第一条**里那个 `radio`
    /// 子对象反推电台信息的——节目为空的新电台就什么都拿不到。这条是电台自己的详情，
    /// 该由它当权威；`subed`（当前账号订没订）也只有它给。
    func djRadioDetail(radioID: String) async -> Playlist? {
        guard let resp = try? await eapi("/api/djradio/v2/get",
                                         [("id", .string(Self.djRawID(radioID)))]),
              let data = resp["data"] as? [String: Any] else { return nil }
        var radio = Self.parseDJRadio(data)
        if radio?.description == nil {
            radio?.description = (data["rcmdText"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (data["desc"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return radio
    }

    /// 电台节目列表，**带翻页与排序**。`/api/dj/program/byradio`，
    /// 参数 `radioId` / `limit` / `offset` / `asc`（true = 从第一期往后），走 eapi。
    /// [api-enhanced] `module/dj_program.js`（那边标的是 weapi）
    ///
    /// 与基线的关系：基线 `djRadioDetail(_:)`（`NeteaseAPI.swift`）打的是同一条，
    /// 但**写死 limit=50、offset 不动**——131 期的电台点进去只有 50 期，剩下的静默丢掉。
    /// 这条是完整版：`total` 为真时自己翻到底（`more` 为假就停），上限 20 页兜底，
    /// 免得几百期的电台一次刷新打上百个来回。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `radioId=792544462&limit=3` 回
    /// `{"count":31,"programs":[…3 条…],"more":true,"code":200}`；
    /// **id 不存在时回 `{"code":200,"count":0,"programs":[],"more":false}`**
    /// ——不报错、只是空表，所以不能拿「空」当「电台不存在」的判据（那件事问 `djRadioDetail`）。
    ///
    /// 每条节目的形状与 `parseDJProgram` 认的一致（`mainSong` + `radio` + `duration`）。
    func djPrograms(radioID: String, limit: Int = 30, offset: Int = 0,
                    ascending: Bool = false, all: Bool = false) async -> [Track] {
        let rid = Self.djRawID(radioID)
        var out: [Track] = []
        var cursor = offset
        for _ in 0..<(all ? 20 : 1) {
            guard let resp = try? await eapi("/api/dj/program/byradio", [
                ("radioId", .string(rid)), ("limit", .int(limit)),
                ("offset", .int(cursor)), ("asc", .bool(ascending)),
            ]) else { break }
            let programs = resp["programs"] as? [[String: Any]] ?? []
            out += programs.compactMap { Self.parseDJProgram($0) }
            if !all { break }
            if programs.count < limit { break }
            if let more = resp["more"] as? Bool, !more { break }
            cursor += limit
        }
        return out
    }

    /// 单期节目详情。`/api/dj/program/detail`，参数 `id`（**节目 id，不是 mainSong 的歌曲 id**），
    /// 走 eapi。[api-enhanced] `module/dj_program_detail.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"program":{…},"code":200}`，
    /// `program` 的形状与列表里那一条完全一样（`mainSong`/`radio`/`duration`/`programDesc`…），
    /// 所以直接喂 `parseDJProgram`；**id 传错回的是 `{"code":400,"msg":"参数错误"}`**。
    ///
    /// **这条接口的入参 id 与 `parseDJProgram` 交出来的 Track.id 不是同一个数**：
    /// `Track.id` 用的是 `mainSong.id`（取流要它），节目 id 在 `program.id` 上。
    /// 所以调用方得自己留着节目 id，不能拿曲目 id 反查——这里签名写成 `programID`
    /// 就是为了别让人误用。
    func djProgramDetail(programID: String) async -> Track? {
        guard let resp = try? await eapi("/api/dj/program/detail",
                                         [("id", .string(programID.rawID))]),
              let program = resp["program"] as? [String: Any] else { return nil }
        return Self.parseDJProgram(program)
    }

    /// 按分类推荐节目。`/api/program/recommend/v1`，参数 `cateId` / `limit` / `offset`，走 eapi。
    /// [api-enhanced] `module/program_recommend.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `cateId=2&limit=5` 回 `code:200`、
    /// `programs` 5 条（形状同节目列表）+ `more:false`。
    /// `cateId` 留空（不传）时服务端也认，给的是不分类的推荐。
    func recommendedPrograms(categoryID: String? = nil, limit: Int = 10, offset: Int = 0) async -> [Track] {
        var body: [(String, NeteaseJSON)] = [("limit", .int(limit)), ("offset", .int(offset))]
        if let categoryID { body.insert(("cateId", .string(categoryID)), at: 0) }
        guard let resp = try? await eapi("/api/program/recommend/v1", body),
              let programs = resp["programs"] as? [[String: Any]] else { return [] }
        return programs.compactMap { Self.parseDJProgram($0) }
    }

    /// 用户创建的电台。`/api/djradio/get/byuser`，参数 `userId`，走 eapi。
    /// [api-enhanced] `module/user_audio.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名查别人的公开账号（45441555）回
    /// `{"djRadios":[1 条],"hasMore":false,"count":1,"subCount":111,"code":200}`
    /// ——**不需要登录也能查别人**，所以这条不拦登录态；不传 uid 想查自己是不行的。
    func userRadios(uid: Int) async -> [Playlist] {
        guard let resp = try? await eapi("/api/djradio/get/byuser", [("userId", .int(uid))]),
              let list = resp["djRadios"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parseDJRadio($0) }
    }

    /// 电台 banner。`/api/djradio/banner/get`，**无参数**，走 eapi。
    /// [api-enhanced] `module/dj_banner.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`data` 3 条，
    /// 每条 `{targetId, targetType, pic, url, typeTitle, exclusive}`
    /// ——与首页轮播（`banners()`，见 `+Style.swift`）少了 `bannerId`/`encodeId`，
    /// 其余字段同名，所以共用 `NeteaseBanner`。
    func djBanners() async -> [NeteaseBanner] {
        guard let resp = try? await eapi("/api/djradio/banner/get"),
              let list = resp["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { NeteaseBanner($0) }
    }

    // MARK: - 电台各榜

    /// 电台榜（新晋 / 热门）。`/api/djradio/toplist`，参数 `limit` / `offset` /
    /// `type`（**0 新晋，1 热门**），走 eapi。
    /// [api-enhanced] `module/dj_toplist.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `type=0&limit=5` 回 `code:200`、
    /// `toplist` 4 条（**要 5 只给 4，服务端自己决定条数**）+ `updateTime`。
    /// 每项在电台字段之外多带 `rank` / `lastRank` / `score`，键名是 `toplist` 不是 `djRadios`。
    func djRadioToplist(hot: Bool = false, limit: Int = 100, offset: Int = 0) async -> [Playlist] {
        guard let resp = try? await eapi("/api/djradio/toplist", [
            ("limit", .int(limit)), ("offset", .int(offset)), ("type", .int(hot ? 1 : 0)),
        ]), let list = resp["toplist"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parseDJRadio($0) }
    }

    /// 付费精品榜。`/api/djradio/toplist/pay`，参数只有 `limit`（**不收 offset**），走 eapi。
    /// [api-enhanced] `module/dj_toplist_pay.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`，`data` 是个对象
    /// `{total, updateTime, list}`，`list` 每项只有 `{id,rank,lastRank,score,name,picUrl,creatorName}`
    /// ——**比别的电台接口瘦得多**（没有 programCount / subCount / desc），
    /// 所以卡片上只能显示封面、名字、主播名。
    func djPayToplist(limit: Int = 100) async -> [Playlist] {
        guard let resp = try? await eapi("/api/djradio/toplist/pay", [("limit", .int(limit))]),
              let list = (resp["data"] as? [String: Any])?["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            var radio = Self.parseDJRadio(item)
            if radio?.creatorName == nil { radio?.creatorName = item["creatorName"] as? String }
            return radio
        }
    }

    /// 节目榜。`/api/program/toplist/v1`，参数 `limit` / `offset`，走 eapi。
    /// [api-enhanced] `module/dj_program_toplist.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`toplist` 5 条 + `updateTime`，
    /// 每项是 `{program:{…}, rank, lastRank, score, programFeeType}`
    /// ——**节目包在 `program` 里**，不是平铺的。`parseDJProgram` 本来就认这种包法
    /// （它开头会先取 `p["program"]`），直接喂进去就行。
    func djProgramToplist(limit: Int = 100, offset: Int = 0) async -> [Track] {
        guard let resp = try? await eapi("/api/program/toplist/v1", [
            ("limit", .int(limit)), ("offset", .int(offset)),
        ]), let list = resp["toplist"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parseDJProgram($0) }
    }

    /// 24 小时节目榜。`/api/djprogram/toplist/hours`（**注意是 `djprogram` 连写**，
    /// 与上面那条的 `program` 不是一个路径），参数只有 `limit`，走 eapi。
    /// [api-enhanced] `module/dj_program_toplist_hours.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`，`data` 是对象
    /// `{total, updateTime, list}`，`list` 每项同样是 `{program, rank, lastRank, score, programFeeType}`。
    func djProgramToplistHourly(limit: Int = 100) async -> [Track] {
        guard let resp = try? await eapi("/api/djprogram/toplist/hours", [("limit", .int(limit))]),
              let list = (resp["data"] as? [String: Any])?["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.parseDJProgram($0) }
    }

    /// 主播榜三条：24 小时榜 / 新人榜 / 最热榜。三条的响应形状**完全一样**，
    /// 只有路径与「收不收 offset」不同，所以并成一个枚举。
    ///
    /// | 榜 | 路径 | offset | 出处 |
    /// |---|---|---|---|
    /// | 24 小时 | `/api/dj/toplist/hours` | 不收 | `module/dj_toplist_hours.js` |
    /// | 新人 | `/api/dj/toplist/newcomer` | 收 | `module/dj_toplist_newcomer.js` |
    /// | 最热 | `/api/dj/toplist/popular` | 不收 | `module/dj_toplist_popular.js` |
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 三条匿名都回 `code:200`，`data` 是
    /// `{total, updateTime, list}`，`list` 每项
    /// `{id, rank, lastRank, score, nickName, avatarUrl, userType, userFollowedCount,
    /// mainAuthDesc, liveStatus, liveType, liveId, roomNo}`。
    ///
    /// **主播不是 `Artist`**：这里的 `id` 是网易云的用户 uid，喂给歌手接口只会 404。
    /// 所以单开一个 `NeteaseDJAnchor`，与 `+Discover.swift` 里 `NeteasePrivateContent` 同一个理由
    /// ——宁可多一个小类型，也不要造出一批点进去打不开的假艺人。
    func djAnchorToplist(_ kind: NeteaseDJAnchorChart, limit: Int = 100, offset: Int = 0) async -> [NeteaseDJAnchor] {
        var body: [(String, NeteaseJSON)] = [("limit", .int(limit))]
        if kind.acceptsOffset { body.append(("offset", .int(offset))) }
        guard let resp = try? await eapi(kind.path, body),
              let list = (resp["data"] as? [String: Any])?["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { NeteaseDJAnchor($0) }
    }

    // MARK: - 广播电台（voice/broadcast）

    /// 广播电台列表（真·电波电台，Amber 这边和播客是两套数据）。
    /// `/api/voice/broadcast/channel/list`，参数 `categoryId` / `regionId` / `limit` /
    /// `lastId`（**游标就是它，不是 offset**）/ `score`，走 eapi。
    /// [api-enhanced] `module/broadcast_channel_list.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `categoryId=0&regionId=0&limit=5` 回
    /// `code:200`，`data = {hasMore, list, total}`，`list` **给了 9 条**（要 5 给 9，
    /// limit 只是下限提示）。每项形如
    /// `{"id":875,"regionName":"福建","name":"安溪人民广播电台",
    /// "coverUrl":"http://…","subed":false,"score":808,"source":"QT","roomId":0}`
    /// ——`source:"QT"` 说明内容是从蜻蜓 FM 接过来的。
    ///
    /// 翻页要把上一页最后一条的 `id` 当 `lastId` 发回去，同时把它的 `score` 当 `score`
    /// （两个一起才是完整游标，只带 id 会从头开始）。
    func broadcastChannels(categoryID: String = "0", regionID: String = "0",
                           limit: Int = 20, lastID: String = "0",
                           score: String = "-1") async -> (channels: [NeteaseBroadcastChannel], hasMore: Bool) {
        guard let resp = try? await eapi("/api/voice/broadcast/channel/list", [
            ("categoryId", .string(categoryID)), ("regionId", .string(regionID)),
            ("limit", .string("\(limit)")), ("lastId", .string(lastID)), ("score", .string(score)),
        ]), let data = resp["data"] as? [String: Any] else { return ([], false) }
        let list = (data["list"] as? [[String: Any]] ?? []).compactMap { NeteaseBroadcastChannel($0) }
        return (list, data["hasMore"] as? Bool ?? false)
    }

    /// 广播电台当前在播什么（含**取流地址**）。`/api/voice/broadcast/channel/currentinfo`，
    /// 参数 `channelId`，走 eapi。[api-enhanced] `module/broadcast_channel_currentinfo.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `channelId=875` 回 `code:200`，`data` 里有
    /// `id/regionName/channelName/channelCoverUrl/programId/programName/broadcaster/
    /// startTime/endTime/duration/playUrl/currentTime/thirdChannelId/thirdProgramId`
    /// ——**`playUrl` 就在这条里**，广播不走 `song/enhance/player/url` 那条取流路。
    func broadcastNowPlaying(channelID: String) async -> NeteaseBroadcastNowPlaying? {
        guard let resp = try? await eapi("/api/voice/broadcast/channel/currentinfo",
                                         [("channelId", .string(channelID.rawID))]),
              let data = resp["data"] as? [String: Any] else { return nil }
        return NeteaseBroadcastNowPlaying(data)
    }

    /// 广播电台的分类与地区两张表。`/api/voice/broadcast/category/region/get`，
    /// **无参数**，走 eapi。[api-enhanced] `module/broadcast_category_region_get.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`data = {categoryList, regionList}`
    /// ——一条请求同时拿到筛选器的两个维度，配 `broadcastChannels` 的
    /// `categoryId` / `regionId` 用。
    func broadcastCategoriesAndRegions() async -> (categories: [NeteaseDJCategory], regions: [NeteaseDJCategory]) {
        guard let resp = try? await eapi("/api/voice/broadcast/category/region/get"),
              let data = resp["data"] as? [String: Any] else { return ([], []) }
        return ((data["categoryList"] as? [[String: Any]] ?? []).compactMap { NeteaseDJCategory($0) },
                (data["regionList"] as? [[String: Any]] ?? []).compactMap { NeteaseDJCategory($0) })
    }

    /// 我收藏的广播电台。`/api/content/channel/collect/list`，参数
    /// `contentType="BROADCAST"` / `limit` / `timeReverseOrder="true"` /
    /// `startDate`（**参考实现写死 `4762584922000`，一个 2120 年的时间戳，
    /// 意思是「从未来往回捞」＝全都要**），走 eapi。
    /// [api-enhanced] `module/broadcast_channel_collect_list.js`
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"code":301,"message":"系统错误",…}`
    /// ——必须登录，所以先自己拦住；**200 的形状未实机验证过**，
    /// 按接口族推断 `data` 里是一批与 `broadcastChannels` 同形的频道。
    func favoriteBroadcastChannels(limit: Int = 99999) async throws -> [NeteaseBroadcastChannel] {
        guard isLoggedIn else {
            throw ProviderError.unavailable("请先登录网易云音乐账号，才能读取收藏的广播电台")
        }
        let resp = try await eapi("/api/content/channel/collect/list", [
            ("contentType", .string("BROADCAST")), ("limit", .string("\(limit)")),
            ("timeReverseOrder", .string("true")), ("startDate", .string("4762584922000")),
        ])
        // 这一族接口的 data 有时是数组、有时是 {list:[…]} 的对象，两种都认
        let raw = (resp["data"] as? [[String: Any]])
            ?? ((resp["data"] as? [String: Any])?["list"] as? [[String: Any]])
            ?? []
        return raw.compactMap { NeteaseBroadcastChannel($0) }
    }

    /// 收藏 / 取消收藏广播电台。`/api/content/interact/collect`，参数
    /// `contentType="BROADCAST"` / `contentId` / `cancelCollect`（**取消时才是 true**），走 eapi。
    /// [api-enhanced] `module/broadcast_sub.js`
    ///
    /// 参考实现那句 `query.t = query.t == 1 ? 'false' : 'true'` 读着别扭，
    /// 意思是「t=1 收藏 → cancelCollect=false」，这里直接按 `collect` 的语义写。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"code":301,"message":"系统错误",…}`；
    /// **200 的形状未实机验证过**。写接口一律先拦登录态（同 `+Library.swift` 的规矩）。
    ///
    /// 这条不并进 `setFavorite(_:favorite:)`：`FavoriteTarget.radio` 指的是**播客电台**
    /// （djradio），广播频道是另一套 id 空间，混进同一个枚举只会让调用方发错接口。
    func setBroadcastChannelCollected(_ channelID: String, collected: Bool) async throws {
        guard isLoggedIn else {
            throw ProviderError.unavailable("请先登录网易云音乐账号，才能\(collected ? "收藏" : "取消收藏")广播电台")
        }
        try await eapi("/api/content/interact/collect", [
            ("contentType", .string("BROADCAST")),
            ("contentId", .string(channelID.rawID)),
            ("cancelCollect", .string(collected ? "false" : "true")),
        ])
    }

    // MARK: - 内部

    /// `ne:djradio:123` / `ne:123` / `123` → `123`。
    /// `parseDJRadio` 造的 id 带 `djradio:` 这一层，而接口只认裸数字，`rawID` 只剥得掉 `ne:`。
    /// （`+Library.swift` 里有一份同样的私有实现，两边都是 file-private，故各留一份。）
    static func djRawID(_ id: String) -> String {
        let raw = id.rawID
        return raw.hasPrefix("djradio:") ? String(raw.dropFirst("djradio:".count)) : raw
    }
}

// MARK: - 电台侧的小模型

/// 电台分类 / 广播分类 / 广播地区共用的一条。三张表的字段名一样（`id` + `name`），
/// 只有配图那批键在电台分类上才有，所以合成一个类型。
struct NeteaseDJCategory: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// 分类图。接口给十来种尺寸，这里只取 Mac 客户端那张，退而求其次是 96×96。
    let picURL: String?

    init?(_ raw: [String: Any]) {
        guard let name = raw["name"] as? String else { return nil }
        let rawID = (raw["id"] as? Int).map(String.init) ?? (raw["id"] as? String)
        guard let rawID else { return nil }
        self.id = rawID
        self.name = name
        self.picURL = NeteaseAPI.artworkURL(
            (raw["picMacUrl"] as? String) ?? (raw["pic96x96Url"] as? String) ?? "")
    }
}

/// 首页那种「一个分类 + 这个分类下几张电台」的分组。
struct NeteaseDJCategoryRadios: Identifiable, Hashable, Sendable {
    var id: String { categoryID ?? categoryName }
    let categoryID: String?
    let categoryName: String
    let radios: [Playlist]
}

/// 主播榜的一条。**不是 `Artist`**：`id` 是网易云用户 uid，不是歌手 id。
struct NeteaseDJAnchor: Identifiable, Hashable, Sendable {
    /// 用户 uid（裸数字，不带 `ne:` 前缀——它不是 Amber 模型里的 id）
    let id: String
    let nickname: String
    let avatarURL: String?
    let rank: Int
    /// 上一期名次；接口给 0 表示新上榜
    let lastRank: Int
    let score: Int
    let followerCount: Int
    /// 认证身份那行字（`mainAuthDesc`），大部分主播是空
    let authDescription: String?
    /// 正在直播（`liveStatus` 非 0）
    let isLive: Bool

    init?(_ raw: [String: Any]) {
        guard let uid = raw["id"] as? Int, let nickname = raw["nickName"] as? String else { return nil }
        self.id = String(uid)
        self.nickname = nickname
        self.avatarURL = NeteaseAPI.artworkURL(raw["avatarUrl"] as? String ?? "")
        self.rank = raw["rank"] as? Int ?? 0
        self.lastRank = raw["lastRank"] as? Int ?? 0
        self.score = raw["score"] as? Int ?? 0
        self.followerCount = raw["userFollowedCount"] as? Int ?? 0
        self.authDescription = (raw["mainAuthDesc"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.isLive = (raw["liveStatus"] as? Int ?? 0) != 0
    }
}

/// 主播榜的三种维度。三条接口响应同形，只有路径与收不收 offset 不同。
enum NeteaseDJAnchorChart: String, CaseIterable, Sendable {
    /// 24 小时主播榜
    case hourly
    /// 新人榜
    case newcomer
    /// 最热主播榜
    case popular

    var path: String {
        switch self {
        case .hourly: return "/api/dj/toplist/hours"
        case .newcomer: return "/api/dj/toplist/newcomer"
        case .popular: return "/api/dj/toplist/popular"
        }
    }

    /// 只有新人榜收 offset，另外两条传了也不认（参考实现在注释里明写「不支持 offset」）。
    var acceptsOffset: Bool { self == .newcomer }
}

/// 广播电台的一个频道。与播客电台（`Playlist` + `ne:djradio:`）不是一套东西：
/// 它没有节目列表，只有「此刻在播什么」，取流地址也在另一条接口上。
struct NeteaseBroadcastChannel: Identifiable, Hashable, Sendable {
    /// 频道 id（裸数字）
    let id: String
    let name: String
    /// 归属地（「福建」这类）
    let regionName: String?
    let coverURL: String?
    /// 当前账号收没收藏。匿名恒为 false。
    let subscribed: Bool
    /// 内容来源，实测是 `"QT"`（蜻蜓 FM）
    let source: String?
    /// 翻页游标的另一半：下一页要把最后一条的 id 与 score 一起发回去
    let score: Int

    init?(_ raw: [String: Any]) {
        guard let name = raw["name"] as? String else { return nil }
        let rawID = (raw["id"] as? Int).map(String.init) ?? (raw["id"] as? String)
        guard let rawID else { return nil }
        self.id = rawID
        self.name = name
        self.regionName = (raw["regionName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.coverURL = NeteaseAPI.artworkURL(raw["coverUrl"] as? String ?? "")
        self.subscribed = raw["subed"] as? Bool ?? false
        self.source = raw["source"] as? String
        self.score = raw["score"] as? Int ?? 0
    }
}

/// 广播频道此刻在播的节目。`playURL` 是可直接送给播放器的直播流。
struct NeteaseBroadcastNowPlaying: Sendable {
    let channelID: String
    let channelName: String?
    let coverURL: String?
    let programID: String?
    let programName: String?
    /// 主持人（`broadcaster`），常为空
    let broadcaster: String?
    let startTime: Date?
    let endTime: Date?
    /// 直播流地址。给不出时是 nil——这条没有别的取流兜底路。
    let playURL: URL?

    init?(_ raw: [String: Any]) {
        let rawID = (raw["id"] as? Int).map(String.init) ?? (raw["id"] as? String)
        guard let rawID else { return nil }
        func date(_ key: String) -> Date? {
            guard let ms = raw[key] as? Int, ms > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        self.channelID = rawID
        self.channelName = raw["channelName"] as? String
        self.coverURL = NeteaseAPI.artworkURL(raw["channelCoverUrl"] as? String ?? "")
        self.programID = (raw["programId"] as? Int).map(String.init) ?? (raw["programId"] as? String)
        self.programName = (raw["programName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.broadcaster = (raw["broadcaster"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.startTime = date("startTime")
        self.endTime = date("endTime")
        // 直播流实测是 http 的；与封面同理统一升 https 再交出去
        self.playURL = (raw["playUrl"] as? String).flatMap {
            $0.isEmpty ? nil : URL(string: $0.httpsUpgraded)
        }
    }
}
