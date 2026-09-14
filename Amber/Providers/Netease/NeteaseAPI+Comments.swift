import Foundation

/// 网易云的评论区。
///
/// **资源类型号只在这一处映射**（`NeteaseCommentResource`）。网易云的评论接口有两套编号：
/// 一套是拼在 threadId 前面的字符串前缀（`R_SO_4_` / `A_PL_0_`…），另一套是
/// `commentInfo/list` 要的纯数字（4 / 0 / 3 / 5 / 1）。两者不是一一对应的直觉关系
/// （歌单是 `A_PL_0_` → 0，电台节目是 `A_DJ_1_` → 1，看着像但顺序完全不同），
/// 散在各方法里迟早写错，所以合成一个枚举，别的地方只准问它要。
/// 前缀表出处：[api-enhanced] `util/config.json` 的 `resourceTypeMap`。
///
/// **通道一律走 eapi。** 参考实现里热评、点赞、楼层标的是 weapi，发/回/删标的是
/// `xeapi` + `checkToken: v3`（反作弊 token）。Amber 没有 xeapi 也没有取 checkToken 的那套，
/// 这里退回普通 eapi 打同一条路径——同一份参考实现里的 `module/comment.js` 走的正是
/// `eapi` + `checkToken: v2` 的同一批路径，说明这几条 eapi 是认的。
/// 但**登录态下会不会因为缺 checkToken 被判为异常请求，没有验证过**
/// （与 `+Library.swift` 里红心那条同一个待办）。
///
/// 读接口取不到就返回空页；写接口（发、回、删、点赞）一律先拦登录态再发。
extension NeteaseAPI: MusicCommenting {

    // MARK: - 读

    /// 统一评论入口。`/api/v2/resource/comments`，参数 `threadId` / `pageNo` / `pageSize` /
    /// `cursor` / `sortType` / `showInner`，走 eapi。
    /// [api-enhanced] `module/comment_new.js`
    ///
    /// **翻页只认 cursor**：`CommentPage.cursor` 就是为它留的。
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名打「起风了」（`R_SO_4_1330348068`）回 `code:200`，
    /// `data` 里 `totalCount:1117051`、`hasMore:true`、`cursor:"1788936951005"`
    /// ——**游标是一个毫秒时间戳，不是页号**，而且 `sortType=99`（推荐）与 `sortType=3`（时间）
    /// 回的都是同一种时间戳游标。所以这里统一按「首页不带 cursor、后续把上一页的 cursor 原样发回」用，
    /// 不去算 `(pageNo-1)*pageSize`（参考实现那套算法只在 sortType 99/2 上成立，
    /// 而它算出来的 cursor 与服务端回的 cursor 根本不是同一个东西）。
    ///
    /// 每条评论的字段：`commentId` / `content` / `time`(ms) / `timeStr`("6分钟前") /
    /// `likedCount` / `liked` / `ipLocation.location`("湖南") / `beReplied` /
    /// `user.{userId,nickname,avatarUrl}`。`liked` 匿名恒为 false。
    ///
    /// 首页（`cursor == nil`）会顺带并发拉一次热评（`hotComments(for:limit:)`）填进
    /// `CommentPage.hot`；翻页时不再重复拉——热评是「置顶那几条」，不随页码变。
    func comments(for target: CommentTarget, limit: Int, cursor: String?) async throws -> CommentPage {
        guard let resource = NeteaseCommentResource(target) else {
            throw ProviderError.unavailable("这类资源没有评论区")
        }
        let threadID = resource.threadID(for: target)

        let body: [(String, NeteaseJSON)] = [
            ("threadId", .string(threadID)),
            ("pageNo", .int(1)),
            ("showInner", .bool(true)),
            ("pageSize", .int(limit)),
            ("cursor", .string(cursor ?? "0")),
            // 3 = 按时间。选它是因为只有这一档的游标语义在参考实现里是明写的
            // （`query.cursor || '0'`），另外两档要调用方自己按页号算。
            ("sortType", .int(3)),
        ]
        guard cursor == nil else {
            return Self.parseCommentPage(try await eapi("/api/v2/resource/comments", body))
        }
        // 首页与热评并发；热评失败不该让评论区整体报错（`hotComments` 自己吞异常）
        async let hotTask = hotComments(for: target, limit: min(limit, 20))
        let resp = try await eapi("/api/v2/resource/comments", body)
        var page = Self.parseCommentPage(resp)
        page.hot = await hotTask
        return page
    }

    /// 热门评论。`/api/v1/resource/hotcomments/<threadId>`（**id 在路径里**），
    /// 参数 `rid` / `limit` / `offset` / `beforeTime`，走 eapi。
    /// [api-enhanced] `module/comment_hot.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `code:200`、`hotComments` 3 条、
    /// `total:18020`、`hasMore:true`，另有一个恒空的 `topComments`（置顶评论，
    /// 只有官方账号的资源才有，这里不解析）。每项字段与 v2 那条一致。
    ///
    /// 路径里的 `<threadId>` 与参数里的 `rid` 是重复的（一个带前缀一个不带），
    /// 不是参考实现写冗余，服务端两边都读，照抄。
    func hotComments(for target: CommentTarget, limit: Int = 20, offset: Int = 0) async -> [MusicComment] {
        guard let resource = NeteaseCommentResource(target) else { return [] }
        let threadID = resource.threadID(for: target)
        guard let resp = try? await eapi("/api/v1/resource/hotcomments/\(threadID)", [
            ("rid", .string(resource.rawID(for: target))),
            ("limit", .int(limit)), ("offset", .int(offset)), ("beforeTime", .int(0)),
        ]) else { return [] }
        return (resp["hotComments"] as? [[String: Any]] ?? []).compactMap { Self.parseComment($0) }
    }

    /// 一批资源的评论计数。`/api/resource/commentInfo/list`，参数
    /// `resourceType`（**纯数字那套编号**）/ `resourceIds`（JSON 数组的字符串形式），走 eapi。
    /// [api-enhanced] `module/comment_info_list.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名 `resourceType=4&resourceIds=["1330348068"]`
    /// 回 `code:200`、`data` 1 条，字段
    /// `{resourceId, resourceType, commentCount, likedCount, shareCount, liked,
    /// commentCountDesc, threadId, …}`——**一次能问一批**，
    /// 所以歌单页那一列「评论数」不用逐首打接口。
    ///
    /// 交出来的是 `[Amber 前缀 id: 计数]`。同一批里必须是同一类资源（接口按 `resourceType`
    /// 一刀切），所以签名吃的是 `[CommentTarget]` 而不是裸 id——类型混了直接在这儿拦住。
    func commentCounts(for targets: [CommentTarget]) async -> [String: NeteaseCommentCount] {
        guard let first = targets.first, let resource = NeteaseCommentResource(first) else { return [:] }
        let ids = targets.compactMap { target -> String? in
            guard NeteaseCommentResource(target) == resource else { return nil }
            return resource.rawID(for: target)
        }
        guard !ids.isEmpty else { return [:] }
        let json = "[" + ids.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        guard let resp = try? await eapi("/api/resource/commentInfo/list", [
            ("resourceType", .string("\(resource.resourceType)")),
            ("resourceIds", .string(json)),
        ]), let data = resp["data"] as? [[String: Any]] else { return [:] }
        var out: [String: NeteaseCommentCount] = [:]
        for item in data {
            let rid = (item["resourceId"] as? Int).map(String.init) ?? (item["resourceId"] as? String)
            guard let rid else { continue }
            out["ne:\(rid)"] = NeteaseCommentCount(
                commentCount: item["commentCount"] as? Int ?? 0,
                likedCount: item["likedCount"] as? Int ?? 0,
                shareCount: item["shareCount"] as? Int ?? 0,
                liked: item["liked"] as? Bool ?? false,
                // "999w+" 这种服务端算好的短格式；给不出就让调用方自己格式化 commentCount
                commentCountText: (item["commentCountDesc"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        return out
    }

    /// 某条评论下面的楼层（回复串）。`/api/resource/comment/floor/get`，参数
    /// `parentCommentId` / `threadId` / `time`（游标，首屏 -1）/ `limit`，走 eapi。
    /// [api-enhanced] `module/comment_floor.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名拿真实评论 id 回 `code:200`、
    /// `message:"获取成功"`，`data` 里有 `ownerComment`（被回复的那条主楼）与
    /// `comments`（楼层）；**parentCommentId 传 `1` 这种假 id 回的是
    /// `{"code":400,"message":"参数错误"}`**，不是空楼层。
    ///
    /// 交出来只给楼层本身：主楼调用方手上本来就有（就是它点开的那条）。
    /// `hasMore` / `time` 游标一起交，翻页把上一页最后一条的 `time` 发回去。
    func commentFloor(for target: CommentTarget, parentCommentID: String,
                      time: Int = -1, limit: Int = 20) async -> (comments: [MusicComment], hasMore: Bool, cursor: Int?) {
        guard let resource = NeteaseCommentResource(target) else { return ([], false, nil) }
        guard let resp = try? await eapi("/api/resource/comment/floor/get", [
            ("parentCommentId", .string(parentCommentID)),
            ("threadId", .string(resource.threadID(for: target))),
            ("time", .int(time)), ("limit", .int(limit)),
        ]), let data = resp["data"] as? [String: Any] else { return ([], false, nil) }
        let comments = (data["comments"] as? [[String: Any]] ?? []).compactMap { Self.parseComment($0) }
        return (comments,
                data["hasMore"] as? Bool ?? false,
                (data["time"] as? Int) ?? (comments.last?.date).map { Int($0.timeIntervalSince1970 * 1000) })
    }

    // MARK: - 写

    /// 给一条评论点赞 / 取消点赞。`/api/v1/comment/like` \| `/api/v1/comment/unlike`，
    /// 参数 `threadId` / `commentId`，走 eapi。
    /// [api-enhanced] `module/comment_like.js`（那边标的是 weapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"msg":null,"code":301}`
    /// ——路径在、参数认；**200 的形状未实机验证过**。
    func setCommentLiked(_ commentID: String, on target: CommentTarget, liked: Bool) async throws {
        guard let resource = NeteaseCommentResource(target) else {
            throw ProviderError.unavailable("这类资源没有评论区")
        }
        try requireCommentLogin(liked ? "给评论点赞" : "取消点赞")
        try await eapi("/api/v1/comment/\(liked ? "like" : "unlike")", [
            ("threadId", .string(resource.threadID(for: target))),
            ("commentId", .string(commentID)),
        ])
    }

    /// 发一条评论。`/api/resource/comments/add`，参数 `threadId` / `content` /
    /// `resourceType="0"` / `expressionPicId="-1"` / `bubbleId="-1"`，走 eapi。
    /// [api-enhanced] `module/comment_add.js`（那边标的是 xeapi + checkToken v3）
    ///
    /// 后三个参数是客户端原样发的常量（表情图、气泡皮肤都不用），照抄。
    /// 注意 `resourceType` 这里恒为 `"0"`，**不是**资源类型号——真正的类型信息在
    /// threadId 的前缀里，这个字段在参考实现里就是写死的 0。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"code":301,…}`；
    /// **200 的形状未实机验证过**，按参考实现顶层有一个 `comment` 对象是刚发出的那条。
    @discardableResult
    func addComment(_ content: String, to target: CommentTarget) async throws -> MusicComment? {
        guard let resource = NeteaseCommentResource(target) else {
            throw ProviderError.unavailable("这类资源没有评论区")
        }
        try requireCommentLogin("发表评论")
        let resp = try await eapi("/api/resource/comments/add", [
            ("threadId", .string(resource.threadID(for: target))),
            ("content", .string(content)),
            ("resourceType", .string("0")),
            ("expressionPicId", .string("-1")),
            ("bubbleId", .string("-1")),
        ])
        return (resp["comment"] as? [String: Any]).flatMap { Self.parseComment($0) }
    }

    /// 回复一条评论。`/api/v1/resource/comments/reply`，参数 `threadId` / `commentId` /
    /// `content` / `resourceType="0"`，走 eapi。
    /// [api-enhanced] `module/comment_reply.js`（那边标的是 xeapi + checkToken v3）
    ///
    /// 同一份参考实现的 `module/comment.js` 里还有一条 `/api/resource/comments/reply`
    /// （少了 `/v1`）走 eapi，两条都在。这里用带 `/v1` 的那条——它是专门文件里的写法，
    /// 参数也更全。
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"code":301,…}`；200 的形状未实机验证过。
    @discardableResult
    func replyToComment(_ commentID: String, on target: CommentTarget,
                        content: String) async throws -> MusicComment? {
        guard let resource = NeteaseCommentResource(target) else {
            throw ProviderError.unavailable("这类资源没有评论区")
        }
        try requireCommentLogin("回复评论")
        let resp = try await eapi("/api/v1/resource/comments/reply", [
            ("threadId", .string(resource.threadID(for: target))),
            ("commentId", .string(commentID)),
            ("content", .string(content)),
            ("resourceType", .string("0")),
        ])
        return (resp["comment"] as? [String: Any]).flatMap { Self.parseComment($0) }
    }

    /// 删自己的评论。`/api/resource/comments/delete`，参数 `commentId` / `threadId`，走 eapi。
    /// [api-enhanced] `module/comment_delete.js`（那边标的是 xeapi）
    ///
    /// [实测 2026-09-09 curl(eapi 探针)] 匿名回 `{"code":301,…}`；200 的形状未实机验证过。
    func deleteComment(_ commentID: String, on target: CommentTarget) async throws {
        guard let resource = NeteaseCommentResource(target) else {
            throw ProviderError.unavailable("这类资源没有评论区")
        }
        try requireCommentLogin("删除评论")
        try await eapi("/api/resource/comments/delete", [
            ("commentId", .string(commentID)),
            ("threadId", .string(resource.threadID(for: target))),
        ])
    }

    // MARK: - 解析

    /// v2 那条的 `data` → `CommentPage`。热评由调用方另填。
    private static func parseCommentPage(_ resp: [String: Any]) -> CommentPage {
        guard let data = resp["data"] as? [String: Any] else { return CommentPage() }
        var page = CommentPage()
        page.comments = (data["comments"] as? [[String: Any]] ?? []).compactMap { parseComment($0) }
        page.total = data["totalCount"] as? Int ?? 0
        page.hasMore = data["hasMore"] as? Bool ?? false
        // 游标服务端可能给成数字，统一折成字符串（CommentPage.cursor 是 String?）
        page.cursor = (data["cursor"] as? String)
            ?? (data["cursor"] as? Int).map(String.init)
            ?? (data["cursor"] as? Int64).map(String.init)
        return page
    }

    /// 一条评论。v2、热评、楼层三处的字段名完全一致，共用这一个。
    static func parseComment(_ raw: [String: Any]) -> MusicComment? {
        let idValue = (raw["commentId"] as? Int).map(String.init)
            ?? (raw["commentId"] as? Int64).map(String.init)
            ?? (raw["commentId"] as? String)
        guard let id = idValue else { return nil }
        let user = raw["user"] as? [String: Any]
        // beReplied 是数组（可能有多层），只取被回复的那一条——评论区是一段展示，
        // 不做整棵楼（`MusicComment` 的口径）。
        let replied = (raw["beReplied"] as? [[String: Any]])?.first
        let repliedUser = replied?["user"] as? [String: Any]
        let timeMS = (raw["time"] as? Int) ?? (raw["time"] as? Int64).map(Int.init) ?? 0
        return MusicComment(
            id: id,
            userID: (user?["userId"] as? Int).map(String.init),
            userName: user?["nickname"] as? String ?? "网易云用户",
            avatarURL: artworkURL(user?["avatarUrl"] as? String ?? ""),
            content: raw["content"] as? String ?? "",
            date: timeMS > 0 ? Date(timeIntervalSince1970: TimeInterval(timeMS) / 1000) : nil,
            likeCount: raw["likedCount"] as? Int ?? 0,
            liked: raw["liked"] as? Bool ?? false,
            // ipLocation 是个对象，要的是里面的 location（"湖南"），不是 ip
            ipLocation: ((raw["ipLocation"] as? [String: Any])?["location"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 },
            repliedUserName: repliedUser?["nickname"] as? String,
            repliedContent: (replied?["content"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    private func requireCommentLogin(_ action: String) throws {
        guard isLoggedIn else {
            throw ProviderError.unavailable("请先登录网易云音乐账号，才能\(action)")
        }
    }
}

// MARK: - 资源类型映射

/// 评论挂载的资源类型。两套编号都在这儿，别的地方不许再写字面量。
/// 出处：[api-enhanced] `util/config.json` 的 `resourceTypeMap`，
/// 数字那套是 `module/comment_info_list.js` 从前缀里截出来的（`R_SO_4_` → 4）。
enum NeteaseCommentResource: String, Sendable {
    case track = "R_SO_4_"
    case mv = "R_MV_5_"
    case playlist = "A_PL_0_"
    case album = "R_AL_3_"
    case radioProgram = "A_DJ_1_"
    /// 视频（UGC）。`CommentTarget` 里目前没有对应项，留着是因为 `+Video.swift`
    /// 拿到的 `video_detail.threadId` 就是这个前缀，将来接视频评论时不用再查一次表。
    case video = "R_VI_62_"

    /// threadId 的前缀
    var threadPrefix: String { rawValue }

    /// `commentInfo/list` 要的纯数字编号。**不是前缀里那个数字的直觉顺序**，
    /// 所以逐个写死而不是从 rawValue 里截——截出来对，但读的人会以为是巧合。
    var resourceType: Int {
        switch self {
        case .track: return 0
        case .mv: return 1
        case .playlist: return 2
        case .album: return 3
        case .radioProgram: return 4
        case .video: return 5
        }
    }

    init?(_ target: CommentTarget) {
        switch target {
        case .track: self = .track
        case .album: self = .album
        case .playlist: self = .playlist
        case .mv: self = .mv
        case .radioProgram: self = .radioProgram
        }
    }

    /// 目标的裸 id。电台节目那一档要多剥一层 `djradio:`（`parseDJRadio` 造的 id 带它）。
    func rawID(for target: CommentTarget) -> String {
        switch target {
        case .track(let id), .album(let id), .playlist(let id), .mv(let id):
            return id.rawID
        case .radioProgram(let id):
            return NeteaseAPI.djRawID(id)
        }
    }

    func threadID(for target: CommentTarget) -> String {
        threadPrefix + rawID(for: target)
    }
}

/// 一个资源的评论区计数。
struct NeteaseCommentCount: Hashable, Sendable {
    let commentCount: Int
    let likedCount: Int
    let shareCount: Int
    /// 当前账号点没点过赞（匿名恒为 false）
    let liked: Bool
    /// 服务端算好的短格式（"999w+"）；给不出就是 nil
    let commentCountText: String?
}
