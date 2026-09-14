import Foundation

// QQ 音乐的评论那一段：评论数、热评、最新、推荐、时刻评论，以及发/删评论。
// 移植来源：[QQMusicApi] `modules/comment.py`、`models/comment.py`。
//
// 四条贯穿全文件的事实，先写在这里：
//
// 1. **读评论全部匿名可用，一个 comm 都不用带。** [实测 2026-09-09 curl] 下面每一条
//    读接口都是「不带 comm、不带 cookie」直接打 `musicu.fcg` 就回 code 0，
//    所以这里全部走 `musicu` 的默认档（`anonymous` 都不用开——没登录时它本来就不发 comm）。
//
// 2. **QQ 的评论挂在数字 id 上，不是 mid。** 曲目要 songId、专辑要 albumId，
//    歌单直接就是 tid（本来就是数字），MV 要数字 mvid。前三种的换算在别处已经有了
//    （`songID(mid:)` / `albumNumericID(mid:)`），MV 那条在 `QQAPI+Video.swift`
//    （`mvNumericID(vid:)`），这里只负责按类型分派，见 `QQCommentBiz`。
//
// 3. **翻页游标要自己编。** 参考实现用的是 `MultiFieldContinuationStrategy`——
//    「下一页」同时要改两个字段：`PageNum + 1` 与 `LastCommentSeqNo = 本页最后一条的 SeqNo`。
//    `CommentPage.cursor` 只有一个字符串位置，所以这里把两者拼成 `"<PageNum>|<SeqNo>"`
//    （见 `QQCommentCursor`）。分隔符取 `|`：SeqNo 实测是纯数字（雪花 id）或空串，
//    评论 id 那种带 `!` `.` `-` 的字符也不会撞上它。
//
//    ⚠️ 而且 [实测 2026-09-09 curl] **热评与最新评论的 `SeqNo` 一律是空串**
//    （告白气球 songid=102065750，`GetHotCommentList` / `GetNewCommentList` 各取 3 条，
//    每条 `SeqNo` 都是 `""`；只有时刻评论 `GetSongTsCmList` 给的是真游标，形如
//    `1591956178206788608`）。所以照参考实现的写法（游标取不到就停止翻页）会**只翻得动第一页**。
//    实测单靠 `PageNum` 就能翻：PageNum=0 与 1 拿到的是两批不同的评论（时间戳分别是
//    1788947500… 与 1788940138…）。因此这里以 PageNum 为准，SeqNo 有就带上、没有就传空串。
//
// 4. **写接口一律要登录。** [实测 2026-09-09 curl] 匿名打 `AddComment` / `DelComment`
//    都回 `code=1000`、无 data。1000 是 `musicu` 认的「凭证被拒」码，未登录还去打它
//    只会白跑一趟再顺手触发一次登录态复核，所以这里先自己拦（`requireCredential()`，
//    在 `QQAPI+Library.swift`）。**登录态下的成功响应形状没有实机验证过**，
//    字段名取自参考实现的 `AddCommentResponse`。

extension QQAPI: MusicCommenting {

    // MARK: - 资源映射

    /// `CommentTarget` 的五类资源在 QQ 这边对应的 `BizType`。
    /// 值照 [QQMusicApi] `models/comment.py::CommentBizType`。
    ///
    /// QQ 的评论接口没有「topic_id」这个概念——网易 v2 评论那套是 `type + id`，
    /// QQ 这边是 `BizType`(资源大类) + `BizId`(资源的数字 id) + 可选的 `BizSubType`(子类)。
    /// **只有单曲有子类**：参考实现在 `biz_type == SONG` 且调用方没指定时补 `biz_sub_type = 2`，
    /// 其余类型不传这个键。这里照办（见 `subType`）。
    enum QQCommentBiz: Int, Sendable {
        case song = 1
        case album = 2
        case playlist = 3
        case mv = 4
        /// 长音频（播客/有声书）。QQ 这边确有这一类，但 Amber 的 QQ 电台 id
        /// （`qq:radio:<台号>`，来自 `pf.radiosvr`）是**电台台号**不是长音频节目 id，
        /// 拿它当 BizId 打是猜，所以 `.radioProgram` 一律照实抛，不走这个值。
        /// 留着这一条是为了记住「QQ 有这类，只是 Amber 手上没有对应的 id」。
        case specialAudio = 15

        /// 单曲要带 `BizSubType = 2`，其余不带（照参考实现）。
        var subType: Int? { self == .song ? 2 : nil }
    }

    /// 把 Amber 的 `CommentTarget` 换成 QQ 的 (BizType, BizId)。
    ///
    /// 换算各走各的现成路：曲目 `songID(mid:)`、专辑 `albumNumericID(mid:)`、
    /// MV `mvNumericID(vid:)`；歌单的 `tid` 本来就是数字，剥掉前缀直接用。
    /// 换不出来就抛——评论区取不到内容和「这条 id 根本不对」是两回事，
    /// 后者应该让调用方看见（协议这条方法本来就是 `throws`）。
    func commentBiz(for target: CommentTarget) async throws -> (biz: QQCommentBiz, id: String) {
        switch target {
        case .track(let id):
            guard let songID = await songID(mid: id.rawID) else {
                throw ProviderError.unavailable("取不到这首歌的数字 id，看不了评论")
            }
            return (.song, String(songID))
        case .album(let id):
            guard let albumID = await albumNumericID(mid: id.rawID) else {
                throw ProviderError.unavailable("取不到这张专辑的数字 id，看不了评论")
            }
            return (.album, String(albumID))
        case .playlist(let id):
            let tid = id.rawID
            guard Int(tid) != nil else {
                throw ProviderError.unavailable("这个歌单没有 QQ 音乐的数字 id，看不了评论")
            }
            return (.playlist, tid)
        case .mv(let id):
            guard let mvID = await mvNumericID(vid: id.rawID) else {
                throw ProviderError.unavailable("取不到这个 MV 的数字 id，看不了评论")
            }
            return (.mv, String(mvID))
        case .radioProgram:
            throw ProviderError.unavailable("QQ音乐的电台没有可评论的节目 id")
        }
    }

    /// 三个键拼成 param 的公共那一段（`BizType` / `BizId` / 可选 `BizSubType`）。
    private static func bizParam(_ biz: QQCommentBiz, _ id: String) -> [String: Any] {
        var param: [String: Any] = ["BizType": biz.rawValue, "BizId": id]
        if let sub = biz.subType { param["BizSubType"] = sub }
        return param
    }

    // MARK: - 翻页游标

    /// QQ 评论列表的多字段游标（见文件头第 3 条）。
    /// 编码成 `"<PageNum>|<SeqNo>"` 塞进 `CommentPage.cursor`，下一页原样传回来。
    struct QQCommentCursor: Sendable {
        /// 服务端的页码从 0 起（参考实现传的是 `page - 1`）
        var pageNum: Int
        /// 上一页最后一条的 `SeqNo`；实测热评/最新评论一律给空串，那就传空串
        var lastSeqNo: String

        static let separator: Character = "|"

        init(pageNum: Int = 0, lastSeqNo: String = "") {
            self.pageNum = pageNum
            self.lastSeqNo = lastSeqNo
        }

        /// 解不出来就当第一页——游标是服务端来的字符串，格式变了不该让评论区整块报错。
        init(decoding raw: String?) {
            guard let raw, let cut = raw.firstIndex(of: Self.separator),
                  let page = Int(raw[raw.startIndex..<cut]) else {
                self.init()
                return
            }
            self.init(pageNum: page, lastSeqNo: String(raw[raw.index(after: cut)...]))
        }

        var encoded: String { "\(pageNum)\(Self.separator)\(lastSeqNo)" }
    }

    // MARK: - 协议入口

    /// 详情页评论区要的一页。
    ///
    /// 第一页（`cursor == nil`）三条请求并发：热评 + 最新 + 评论总数；
    /// 往后翻只再要最新那一条——热评是「这首歌的置顶几条」，翻页时重复给一遍没有意义。
    ///
    /// `total` 取 `GetCmCount` 那条而不是列表里的 `Total`：[实测 2026-09-09 curl]
    /// 同一首歌（songid=102065750），`GetCmCount` 回 82059，`GetNewCommentList`
    /// 的 `CommentList.Total` 也是 82059，但 `GetHotCommentList` 的 `Total` 只有 4000
    /// （热评榜自己的容量），`GetRecCommentList` 干脆回 0。三处不同名不同义，
    /// 计数只认专用的那条。
    func comments(for target: CommentTarget, limit: Int, cursor: String?) async throws -> CommentPage {
        let (biz, id) = try await commentBiz(for: target)
        let page = QQCommentCursor(decoding: cursor)
        let isFirstPage = cursor == nil

        async let hotTask = firstPageHotComments(isFirstPage, biz: biz, bizID: id, limit: limit)
        async let newTask = commentList(method: "GetNewCommentList", biz: biz, bizID: id,
                                        limit: limit, cursor: page)
        async let totalTask = firstPageCommentCount(isFirstPage, biz: biz, bizID: id)

        guard let latest = await newTask else { throw ProviderError.invalidResponse }
        var result = CommentPage()
        result.hot = await hotTask
        result.comments = latest.comments
        result.total = await totalTask
        result.hasMore = latest.hasMore
        result.cursor = latest.hasMore ? latest.next.encoded : nil
        return result
    }

    /// 热评与计数只在第一页要（见上）。写成两个小方法而不是在 `async let` 里写三目，
    /// 是因为 `async let` 的初始化式里放条件表达式在类型推断上很脆——这样也更好读。
    private func firstPageHotComments(_ wanted: Bool, biz: QQCommentBiz,
                                      bizID: String, limit: Int) async -> [MusicComment] {
        guard wanted else { return [] }
        return await hotComments(biz: biz, bizID: bizID, limit: limit)?.comments ?? []
    }

    private func firstPageCommentCount(_ wanted: Bool, biz: QQCommentBiz,
                                       bizID: String) async -> Int {
        guard wanted else { return 0 }
        return await commentCount(biz: biz, bizID: bizID)
    }

    // MARK: - 评论数

    /// 评论总数。`music.globalComment.CommentCountSrv/GetCmCount`
    /// （[QQMusicApi] `modules/comment.py::get_comment_count`）。
    ///
    /// param 比别处多套一层：`{"request": {biz_id, biz_type, biz_sub_type}}`——
    /// 而且**这三个键是小写下划线**，与列表接口那套大驼峰（`BizId` / `BizType`）不是一套写法，
    /// 别照着改。`biz_id` 传的是字符串。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0：
    /// - 曲目 102065750（告白气球）→ `response.count = 82059`、`count_view = "8w+"`；
    /// - 专辑 87495226 → 37615；歌单 7039749142（百听不厌的周杰伦）→ 966。
    /// - **MV 一律回 0**：数字 mvid（1053277 / 293791）与 vid（`w0026q7f01a`）都试过，
    ///   `biz_sub_type` 0/1/2/3 也都试过，`count` 全是 0。映射照参考实现留着，
    ///   但「QQ 的 MV 评论取不到数」是实测事实，不是这里写错了。
    func commentCount(for target: CommentTarget) async -> Int {
        guard let (biz, id) = try? await commentBiz(for: target) else { return 0 }
        return await commentCount(biz: biz, bizID: id)
    }

    private func commentCount(biz: QQCommentBiz, bizID: String) async -> Int {
        var request: [String: Any] = ["biz_id": bizID, "biz_type": biz.rawValue]
        if let sub = biz.subType { request["biz_sub_type"] = sub }
        guard let data = try? await musicu(module: "music.globalComment.CommentCountSrv",
                                           method: "GetCmCount",
                                           param: ["request": request]),
              let response = data["response"] as? [String: Any] else { return 0 }
        return response["count"] as? Int ?? 0
    }

    // MARK: - 三条列表

    /// 热评。`music.globalComment.CommentRead/GetHotCommentList`
    /// （[QQMusicApi] `modules/comment.py::get_hot_comments`）。
    ///
    /// param 里那三个开关照抄参考实现：`HotType: 1`（要热榜这一路）、
    /// `WithAirborne: 0`（不要「空降」那种运营位）、`PicEnable: 1`（允许带图评论）。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，songid=102065750 取 3 条：
    /// `data.CommentList.Comments[]` 每条给 `CmId` / `Nick` / `Avatar` / `Content` /
    /// `PubTime` / `PraiseNum`(68525) / `IsPraised` / `EncryptUin` / `RepliedComments[]`；
    /// `CommentList` 同级还有 `HasMore: 1` / `Total: 4000` / `NextOffset` / `ListType: 1`。
    func hotComments(for target: CommentTarget, limit: Int = 15,
                     cursor: String? = nil) async -> [MusicComment] {
        guard let (biz, id) = try? await commentBiz(for: target) else { return [] }
        return await hotComments(biz: biz, bizID: id, limit: limit,
                                 cursor: QQCommentCursor(decoding: cursor))?.comments ?? []
    }

    private func hotComments(biz: QQCommentBiz, bizID: String, limit: Int,
                             cursor: QQCommentCursor = QQCommentCursor())
        async -> (comments: [MusicComment], hasMore: Bool, next: QQCommentCursor)? {
        await commentList(method: "GetHotCommentList", biz: biz, bizID: bizID,
                          limit: limit, cursor: cursor,
                          extra: ["HotType": 1, "WithAirborne": 0, "PicEnable": 1])
    }

    /// 最新评论。`music.globalComment.CommentRead/GetNewCommentList`
    /// （[QQMusicApi] `modules/comment.py::get_new_comments`）。
    ///
    /// 比热评多四个开关，照抄：`HashTagID: ""`（不按话题过滤）、`SelfSeeEnable: 1`
    /// （带上「仅自己可见」的那些，登录态下才有意义）、`AudioEnable: 1`（允许语音评论）、
    /// `PicEnable: 1`。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，`CommentList.Total = 82059`（与 `GetCmCount` 一致）、
    /// `HasMore: 1`；PageNum 0 与 1 拿到的是两批不同评论（见文件头第 3 条）。
    func newComments(for target: CommentTarget, limit: Int = 15,
                     cursor: String? = nil) async -> [MusicComment] {
        guard let (biz, id) = try? await commentBiz(for: target) else { return [] }
        return await commentList(method: "GetNewCommentList", biz: biz, bizID: id, limit: limit,
                                 cursor: QQCommentCursor(decoding: cursor))?.comments ?? []
    }

    /// 推荐评论。`music.globalComment.CommentRead/GetRecCommentList`
    /// （[QQMusicApi] `modules/comment.py::get_recommend_comments`）。
    ///
    /// 独有的两个开关：`Flag: 1`、`CmListUIVer: 1`（客户端评论区的版本号，服务端按它
    /// 决定发哪一版排版数据）。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，取 2 条真的回了 2 条，但
    /// `CommentList.Total` 是 **0**、`NextOffset` 是 2、`ListType` 是 7——
    /// 这一路的 Total 不能当计数用（见 `comments(for:limit:cursor:)` 的注释）。
    func recommendComments(for target: CommentTarget, limit: Int = 15,
                           cursor: String? = nil) async -> [MusicComment] {
        guard let (biz, id) = try? await commentBiz(for: target) else { return [] }
        return await commentList(method: "GetRecCommentList", biz: biz, bizID: id, limit: limit,
                                 cursor: QQCommentCursor(decoding: cursor),
                                 extra: ["Flag": 1, "CmListUIVer": 1,
                                         "PicEnable": 1, "AudioEnable": 1])?.comments ?? []
    }

    /// 三条列表接口的公共那一段。除了 method 与几个开关，param 与响应形状完全一样。
    private func commentList(method: String, biz: QQCommentBiz, bizID: String,
                             limit: Int, cursor: QQCommentCursor,
                             extra: [String: Any] = ["PicEnable": 1, "AudioEnable": 1,
                                                     "HashTagID": "", "SelfSeeEnable": 1])
        async -> (comments: [MusicComment], hasMore: Bool, next: QQCommentCursor)? {
        var param = Self.bizParam(biz, bizID)
        param["PageSize"] = max(1, limit)
        param["PageNum"] = cursor.pageNum
        param["LastCommentSeqNo"] = cursor.lastSeqNo
        param.merge(extra) { current, _ in current }
        guard let data = try? await musicu(module: "music.globalComment.CommentRead",
                                           method: method, param: param),
              let list = data["CommentList"] as? [String: Any] else { return nil }
        let raw = list["Comments"] as? [[String: Any]] ?? []
        let items = raw.compactMap { Self.parseComment($0) }
        let next = QQCommentCursor(pageNum: cursor.pageNum + 1,
                                   lastSeqNo: (raw.last?["SeqNo"] as? String) ?? "")
        // `HasMore` 是 0/1 的数字。服务端说没有了、或者这一页本来就空，都算到头
        // ——只认 HasMore 的话，空页 + HasMore=1 会让调用方原地打转。
        let hasMore = (list["HasMore"] as? Int ?? 0) == 1 && !items.isEmpty
        return (items, hasMore, next)
    }

    // MARK: - 时刻评论

    /// 时刻评论（贴在歌曲某个时间点上的那种）。
    /// `music.globalComment.SongTsComment/GetSongTsCmList`
    /// （[QQMusicApi] `modules/comment.py::get_moment_comments`）。
    ///
    /// **这一路与上面三条完全不是一套**，别混：
    /// - 分页键叫 `LastPos` / `Size`（没有 PageNum），游标是响应里的 `NextPos`，
    ///   所以它用的是普通的单字段游标（参考实现这条走 `CursorStrategy`），
    ///   而不是上面那个双字段的；这里就把 `NextPos` 原样当 cursor 返回，不编码；
    /// - `SeekTs: -1` 表示「不从某个时间点开始，给我整条流」；
    /// - 评论列在 `data.CmList`，**作者信息不在评论对象里**，另装在 `data.MapCmExt`
    ///   （以 CmId 为键的一张表，昵称/头像/是否点过赞都在那儿）。这是它与上面三条
    ///   最大的形状差异，解析时要两边合起来。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，songid=102065750 取 2 条：
    /// `HasMore: 1`、`NextPos: "50_1522491906326674176"`，每条给 `SongTsElems: [{S,E,Ts}]`
    /// （正文里哪一段对应第几秒）与 `Location: "重庆"`——**只有这一路带 IP 归属地**，
    /// 上面三条的评论对象里没有这个字段。而且这一路的 `SeqNo` 是真游标（雪花 id）。
    func momentComments(for target: CommentTarget, limit: Int = 15,
                        cursor: String? = nil) async -> (comments: [MusicComment], cursor: String?) {
        guard let (biz, id) = try? await commentBiz(for: target) else { return ([], nil) }
        var param = Self.bizParam(biz, id)
        param["LastPos"] = cursor ?? ""
        param["HashTagID"] = ""
        param["SeekTs"] = -1
        param["Size"] = max(1, limit)
        guard let data = try? await musicu(module: "music.globalComment.SongTsComment",
                                           method: "GetSongTsCmList", param: param) else {
            return ([], nil)
        }
        let ext = data["MapCmExt"] as? [String: [String: Any]] ?? [:]
        let items = (data["CmList"] as? [[String: Any]] ?? []).compactMap { item -> MusicComment? in
            guard let cmid = item["CmId"] as? String else { return nil }
            // 作者那几项从 MapCmExt 里补回去（见上面的形状说明）
            var merged = item
            for (key, value) in ext[cmid] ?? [:] where merged[key] == nil { merged[key] = value }
            return Self.parseComment(merged)
        }
        let hasMore = (data["HasMore"] as? Int ?? 0) == 1
        let next = (data["NextPos"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (items, hasMore ? next : nil)
    }

    // MARK: - 发 / 删

    /// 发一条评论（`replyTo` 非空就是回复某条）。
    /// `music.globalComment.CommentWriteServer/AddComment`
    /// （[QQMusicApi] `modules/comment.py::add_comment`）。
    ///
    /// param 的键：`Content` / `BizType` / `BizId`，回复时多一个 `RepliedCmId`
    /// （注意是 **Cm**Id，不是 CommentId——删评论那条才叫 CommentId，两条不一样）。
    ///
    /// [实测 2026-09-09 curl] 匿名回 `code=1000`、无 data，成功态未实机验证。
    /// 成功判据取自参考实现的 `AddCommentResponse`：`SubCode == 0`，
    /// 新评论 id 在 `AddedCmId`；`VerifyUrl` 非空表示服务端要求过验证码——
    /// 那种情况这里照实抛，不去碰验证码（Amber 不做机器验证那套）。
    @discardableResult
    func addComment(_ content: String, to target: CommentTarget,
                    replyTo replyCommentID: String? = nil) async throws -> String {
        _ = try requireCredential()
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderError.unavailable("评论内容是空的") }
        let (biz, id) = try await commentBiz(for: target)
        var param = Self.bizParam(biz, id)
        param["Content"] = text
        if let replyCommentID, !replyCommentID.isEmpty { param["RepliedCmId"] = replyCommentID }
        let data = try await musicu(module: "music.globalComment.CommentWriteServer",
                                    method: "AddComment", param: param,
                                    clientType: 11, clientVersion: 12060012)
        if let verify = data["VerifyUrl"] as? String, !verify.isEmpty {
            throw ProviderError.unavailable("QQ音乐要求先完成验证才能评论，请到官方客户端里发")
        }
        guard (data["SubCode"] as? Int ?? 0) == 0 else {
            throw ProviderError.api((data["Msg"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "发表评论失败")
        }
        return data["AddedCmId"] as? String ?? ""
    }

    /// 删自己的评论。`music.globalComment.CommentWriteServer/DelComment`
    /// （[QQMusicApi] `modules/comment.py::delete_comment`），param 是 `{CommentId: <CmId>}`。
    ///
    /// [实测 2026-09-09 curl] 匿名回 `code=1000`、无 data，成功态未实机验证。
    /// 参考实现的判据是 `SubCode == 0`，并注明「评论不存在也算成功」——
    /// 对 Amber 来说「删完了它就不该在了」，目标状态达成即成功，照它办。
    func deleteComment(_ commentID: String) async throws {
        _ = try requireCredential()
        guard !commentID.isEmpty else { throw ProviderError.unavailable("没有要删的评论 id") }
        let data = try await musicu(module: "music.globalComment.CommentWriteServer",
                                    method: "DelComment", param: ["CommentId": commentID],
                                    clientType: 11, clientVersion: 12060012)
        guard (data["SubCode"] as? Int ?? 0) == 0 else {
            throw ProviderError.api((data["Msg"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "删除评论失败")
        }
    }

    // MARK: - 解析

    /// 一条评论。四条列表（热评/最新/推荐/时刻）共用这一份：
    /// 前三条的字段名完全一致，时刻那条是它的子集 + `Location`，
    /// 作者信息在调用点先从 `MapCmExt` 合进来（见 `momentComments`）。
    ///
    /// 几处与网易不同、值得写下来的：
    /// - **没有数字 uid**，只有 `EncryptUin`（加密 uin，形如 `oK6kowEAoK4z7eE57wCloeCAoz**`），
    ///   所以 `userID` 装的是它；
    /// - `IsPraised` / `IsSelf` 是 0/1 的数字不是布尔；
    /// - 被回复的那条在 `RepliedComments[]`（[实测 2026-09-09 curl] 里真的有数据：
    ///   `{Nick, Content, CmId, …}`）。参考实现的 model 里只列了 `SubComments`，
    ///   同一份响应里那个字段是空数组——两个都读，`RepliedComments` 优先。
    static func parseComment(_ c: [String: Any]) -> MusicComment? {
        guard let cmid = c["CmId"] as? String, !cmid.isEmpty else { return nil }
        let replied = (c["RepliedComments"] as? [[String: Any]])?.first
            ?? (c["SubComments"] as? [[String: Any]])?.first
        let pubTime = c["PubTime"] as? Int ?? 0
        return MusicComment(
            id: cmid,
            userID: (c["EncryptUin"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            userName: (c["Nick"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "QQ音乐用户",
            avatarURL: Self.httpsURL(c["Avatar"] as? String),
            content: c["Content"] as? String ?? "",
            date: pubTime > 0 ? Date(timeIntervalSince1970: TimeInterval(pubTime)) : nil,
            likeCount: c["PraiseNum"] as? Int ?? 0,
            liked: (c["IsPraised"] as? Int ?? 0) == 1,
            ipLocation: (c["Location"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            repliedUserName: (replied?["Nick"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            repliedContent: (replied?["Content"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}
