import CryptoKit
import Foundation

// QQ 音乐的账号与社交那一段：用户主页、会员信息、关注/粉丝/好友、不喜欢名单、登出。
// 移植来源：[QQMusicApi] `modules/user.py`、`modules/login.py`。
//
// 与 `QQAPI.swift` 里已有的两条**不重复**，命名上也刻意分开：
// - `accountProfile()` 走 `GetLoginUserInfo`，只要昵称与头像，侧栏那颗按钮用；
// - 这里的 `userProfile()` 走 `GetHomepageHeader`，是完整的一份主页资料
//   （加密 uin、头像、背景图、关注数、粉丝数）+ 会员等级。
// 两条各有各的落点，谁也别去改谁。
//
// 除了「不喜欢名单」那三条要签名（见 `signedMusicu`），其余都走现成的 `musicu`。

extension QQAPI {

    // MARK: - 用户主页

    /// 当前登录账号的主页资料。
    /// `music.UnifiedHomepage.UnifiedHomepageSrv/GetHomepageHeader`，param `{uin: <euin>,
    /// IsQueryTabDetail: 1}`（[QQMusicApi] `modules/user.py::get_homepage`）。
    /// 同一个 method 换成 `{SingerMid: …}` 就是歌手主页（`modules/singer.py::get_info`），
    /// 这里只做用户那一路。
    ///
    /// [实测 2026-09-09 curl] 匿名（uin 传空串）回 `code=10000`，但**结构完整地回了一份空壳**，
    /// 所以字段名是实打实看过的，不是照着 model 猜的：
    /// `Info.BaseInfo` 有 `EncryptedUin` / `Name` / `Avatar` / `BigAvatar` /
    /// `BackgroundImage` / `IsHost` / `IsSinger` / `UserType`；同级还有
    /// `FansNum` / `FollowNum` / `FriendsNum` / `VisitorNum`（都是 `{HasEntry, Num, Add, jumpURL}`
    /// 这种小对象，数字在 `Num` 里）、`IsFollowed`、`IP.Location`、`Gender.Gender`。
    /// **值全是空的**（10000 ＝ 没给出有效的 uin），登录态下的真实取值没有实机验证过。
    ///
    /// 两项模型里有、这条接口给不出的，照实留 nil：
    /// - `signature`（个性签名）：主页头里根本没有这个字段，它在音乐基因那条
    ///   （`music.recommend.UserProfileSettingSvr/GetProfileReport` 的 `UserInfoCard.Signature`），
    ///   那条不在这一轮的清单里，不为了填一格去多打一条；
    /// - `playlistCount`：账号歌单数走 `accountPlaylists()` 就有，不在这条上凑。
    ///
    /// `vipLevel` 单独并了一条 `vip_login_base`（两条并发，见 `vipStatus()`）。
    func userProfile() async -> ProviderUserProfile? {
        guard isLoggedIn else { return nil }
        guard let euin = try? await requireEncryptedUin() else { return nil }
        async let headerTask = try? musicu(module: "music.UnifiedHomepage.UnifiedHomepageSrv",
                                           method: "GetHomepageHeader",
                                           param: ["uin": euin, "IsQueryTabDetail": 1],
                                           clientType: 11, clientVersion: 12060012)
        async let vipTask = vipStatus()
        guard let data = await headerTask, let info = data["Info"] as? [String: Any] else { return nil }
        let vip = await vipTask
        let base = info["BaseInfo"] as? [String: Any] ?? [:]
        func number(_ key: String) -> Int? { (info[key] as? [String: Any])?["Num"] as? Int }
        // 昵称/头像取不到时退回 `accountProfile()`（`GetLoginUserInfo`，带账号级缓存，
        // 侧栏那颗按钮本来就已经拉过一次了）
        let fallback = await accountProfile()
        let name = (base["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var profile = ProviderUserProfile(
            uid: (base["EncryptedUin"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? euin,
            nickname: name ?? fallback?.nickname ?? "QQ音乐用户")
        // 头像有大小两版，主页头上摆大的；两个都空才退回登录态那条给的 logo
        profile.avatarURL = Self.httpsURL(base["BigAvatar"] as? String)
            ?? Self.httpsURL(base["Avatar"] as? String)
            ?? fallback?.avatarURL
        profile.followCount = number("FollowNum")
        profile.followerCount = number("FansNum")
        profile.vipLevel = vip?.level
        return profile
    }

    // MARK: - 会员

    /// 会员信息。给不出的项是 0/nil，不猜。
    struct VipStatus: Sendable {
        /// 绿钻（`identity.vip`）
        let isVip: Bool
        /// 豪华绿钻（`identity.HugeVip`）
        let isHugeVip: Bool
        /// 超级会员（顶层 `svip`）
        let isSuperVip: Bool
        /// 会员等级（`identity.level`），拿不到时退回 `userinfo.music_level`
        let level: Int?
        /// 豪华绿钻到期日（`identity.HugeVipEnd`，服务端给的是字符串）
        let hugeVipEnd: String?
        /// 这个账号最多能建几个歌单 / 一个歌单最多几首（`maxdirnum` / `maxsongnum`）。
        /// 建歌单前想先拦一道的话用得上。
        let maxPlaylistCount: Int?
        let maxSongsPerPlaylist: Int?
    }

    /// 会员信息。`VipLogin.VipLoginInter/vip_login_base`
    /// （[QQMusicApi] `modules/user.py::get_vip_info`）。param 是空对象。
    ///
    /// [实测 2026-09-09 curl] 匿名**也回 code=0**（不是 1000），但值全是 0：
    /// `svip=0`、`star=0`、`identity.HugeVip=0`、`userinfo.music_level=0`，
    /// `maxdirnum` / `maxsongnum` 也是 0。所以「code 0」在这条上不等于「拿到了会员信息」，
    /// 未登录时直接返回 nil，别把匿名的一串 0 当成「这个账号没有会员」摆到界面上。
    ///
    /// 键名两套并存（顶层是全小写的 `svip`/`maxdirnum`，`identity` 里是大驼峰的
    /// `HugeVip`/`HugeVipEnd`），实测的 keys 就是这样，参考实现的 `UserVipInfoResponse`
    /// 也是靠 AliasChoices 兼容一堆写法——这里按实测那一套读。
    func vipStatus() async -> VipStatus? {
        guard isLoggedIn else { return nil }
        guard let data = try? await musicu(module: "VipLogin.VipLoginInter",
                                           method: "vip_login_base", param: [:],
                                           clientType: 11, clientVersion: 12060012) else { return nil }
        let identity = data["identity"] as? [String: Any] ?? [:]
        let userinfo = data["userinfo"] as? [String: Any] ?? [:]
        let level = (identity["level"] as? Int) ?? (userinfo["music_level"] as? Int)
        return VipStatus(
            isVip: (identity["vip"] as? Int ?? 0) > 0,
            isHugeVip: (identity["HugeVip"] as? Int ?? 0) > 0,
            isSuperVip: (data["svip"] as? Int ?? 0) > 0,
            level: level,
            hugeVipEnd: (identity["HugeVipEnd"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            maxPlaylistCount: (data["maxdirnum"] as? Int).flatMap { $0 > 0 ? $0 : nil },
            maxSongsPerPlaylist: (data["maxsongnum"] as? Int).flatMap { $0 > 0 ? $0 : nil })
    }

    // MARK: - 关注 / 粉丝 / 好友

    /// 关注的歌手。`music.concern.RelationList/GetFollowSingerList`
    /// （[QQMusicApi] `modules/user.py::get_follow_singers`），
    /// param `{HostUin: <euin>, From: 偏移, Size: 每页}`。
    ///
    /// [实测 2026-09-09 curl] 匿名回 `code=1000`（`GetFansList` / `GetFollowUserList`
    /// 还在 data 里明说了 `Msg: "未登录"`），成功态未实机验证。
    /// 条目形状取自参考实现的 `RelationUser`：`MID` / `EncUin` / `Name` / `Desc` /
    /// `AvatarUrl` / `FanNum` / `IsFollow`，列表在 `List[]`。
    /// 歌手这一路的 `MID` 就是 singer mid，所以 id 拼成 `qq:<MID>` 能直接开艺人页。
    func followedArtists(from: Int = 0, size: Int = 100) async throws -> [Artist] {
        let list = try await relationList(method: "GetFollowSingerList", from: from, size: size)
        return list.compactMap { item -> Artist? in
            guard let mid = item["MID"] as? String, !mid.isEmpty else { return nil }
            return Artist(id: "qq:\(mid)", kind: .qq,
                          name: item["Name"] as? String ?? "未知歌手",
                          avatarURL: Self.httpsURL(item["AvatarUrl"] as? String) ?? Self.artistArtwork(mid),
                          description: (item["Desc"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// 关注的用户。`music.concern.RelationList/GetFollowUserList`。
    func followedUsers(from: Int = 0, size: Int = 100) async throws -> [ProviderUserProfile] {
        try await relationList(method: "GetFollowUserList", from: from, size: size)
            .compactMap { Self.parseRelationUser($0) }
    }

    /// 粉丝。`music.concern.RelationList/GetFansList`。
    func fans(from: Int = 0, size: Int = 100) async throws -> [ProviderUserProfile] {
        try await relationList(method: "GetFansList", from: from, size: size)
            .compactMap { Self.parseRelationUser($0) }
    }

    /// `RelationList` 那三条共用的一段：都要 euin，都是 `From` / `Size` 偏移分页，
    /// 结果都在 `List[]`。
    private func relationList(method: String, from: Int, size: Int) async throws -> [[String: Any]] {
        let euin = try await requireEncryptedUin()
        let data = try await musicu(module: "music.concern.RelationList", method: method,
                                    param: ["HostUin": euin, "From": from, "Size": size],
                                    clientType: 11, clientVersion: 12060012)
        return data["List"] as? [[String: Any]] ?? []
    }

    private static func parseRelationUser(_ u: [String: Any]) -> ProviderUserProfile? {
        guard let uin = u["EncUin"] as? String, !uin.isEmpty else { return nil }
        var profile = ProviderUserProfile(uid: uin, nickname: u["Name"] as? String ?? "QQ音乐用户")
        profile.avatarURL = Self.httpsURL(u["AvatarUrl"] as? String)
        profile.signature = (u["Desc"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        profile.followerCount = u["FanNum"] as? Int
        return profile
    }

    /// 好友（QQ 关系链里的好友，跟「关注的用户」不是一回事）。
    /// `music.homepage.Friendship/GetFriendList`（[QQMusicApi] `modules/user.py::get_friend`），
    /// param `{PageSize: 每页, Page: 页码从 0 起}`——**这条不收 euin，服务端按 cookie 认人**，
    /// 分页也是页码不是偏移，跟上面三条都不一样。
    ///
    /// [实测 2026-09-09 curl] 匿名回 `code=1000`、`data=null`，成功态未实机验证。
    /// 条目取自参考实现的 `FriendEntry`：`EncryptUin` / `UserName` / `AvatarUrl` / `IsFollow`，
    /// 列表在 `Friends`（注意这个键跟 RelationList 的 `List` 不同名）。
    func friends(page: Int = 0, size: Int = 100) async throws -> [ProviderUserProfile] {
        _ = try requireCredential()
        let data = try await musicu(module: "music.homepage.Friendship", method: "GetFriendList",
                                    param: ["PageSize": size, "Page": page],
                                    clientType: 11, clientVersion: 12060012)
        return (data["Friends"] as? [[String: Any]] ?? []).compactMap { friend -> ProviderUserProfile? in
            guard let uin = friend["EncryptUin"] as? String, !uin.isEmpty else { return nil }
            var profile = ProviderUserProfile(uid: uin,
                                              nickname: friend["UserName"] as? String ?? "QQ音乐用户")
            profile.avatarURL = Self.httpsURL(friend["AvatarUrl"] as? String)
            return profile
        }
    }

    // MARK: - 不喜欢名单

    /// 不喜欢名单里的一条。
    struct DislikeItem: Sendable {
        /// 服务端给的是字符串 id（歌曲/歌手是数字 id 的字符串形式，风格是风格 id）
        let id: String
        let name: String
        let imageURL: String?
        let kind: DislikeKind
        let addedAt: Date?
    }

    /// 不喜欢的三类。
    ///
    /// **这里有个必须看一眼的坑**：同一套东西，读和写的编号不一样。
    /// [QQMusicApi] `modules/user.py`：`get_dislike_list` 的 `Cmd` 是 **2=歌手 / 3=歌曲 / 4=风格**，
    /// 而 `add_dislike` / `cancel_dislike` 的 `IdType` 是 **1=歌曲 / 2=歌手 / 3=风格**。
    /// 两套只有「歌手=2」这一项碰巧重合，照着一套去用另一套必错，所以这里分开两个属性，
    /// 谁也别偷懒共用。
    enum DislikeKind: Sendable {
        case song, singer, style

        /// `GetDislikeList` 的 `Cmd`
        var listCommand: Int {
            switch self {
            case .singer: return 2
            case .song: return 3
            case .style: return 4
            }
        }

        /// `AddDislike` / `CancelDislike` 的 `IdType`，也是 param 里那个键名的选择依据
        var idType: Int {
            switch self {
            case .song: return 1
            case .singer: return 2
            case .style: return 3
            }
        }

        /// 写接口里装 id 的那个键
        var writeKey: String {
            switch self {
            case .song: return "Songs"
            case .singer: return "Singers"
            case .style: return "Styles"
            }
        }

        /// 读接口返回里装这一类的那个键
        var readKey: String {
            switch self {
            case .song: return "Songs"
            case .singer: return "Singers"
            case .style: return "Styles"
            }
        }
    }

    /// 不喜欢名单。`music.feedback.FeedbackBlack/GetDislikeList`
    /// （[QQMusicApi] `modules/user.py::get_dislike_list`）。
    ///
    /// **这条要签名**：参考实现在这一条上单独开了 `sign=True`，于是请求换到
    /// `musics.fcg` + `?_=<毫秒>&sign=<zzc…>`（同文件里 `AddDislike` / `CancelDislike`
    /// 反而没开，所以只有这一条走签名通道，见 `signedMusicu`）。
    ///
    /// [实测 2026-09-09 curl] 匿名带**正确签名**打 `musics.fcg` 回
    /// `{"code":0,…,"req_0":{"code":1000}}`（1000 ＝ 未登录）；签名写错则**整个响应是空的**
    /// （连 HTTP body 都没有）。所以「有 JSON 回来」这件事本身就证明签名算对了。
    /// 登录态下的名单形状未实机验证，条目取自参考实现的 `DislikeItem`：
    /// `ID` / `Name` / `Img` / `IdType` / `Time`，三类分别装在 `Songs` / `Singers` / `Styles`。
    func dislikeList(_ kind: DislikeKind, page: Int = 1, lastID: Int = 0) async throws -> [DislikeItem] {
        _ = try requireCredential()
        var param: [String: Any] = ["Cmd": kind.listCommand, "Page": page]
        if lastID > 0 {
            // 游标键名逐类不同（`SingersLastid` / `SongLastid` / `StyleLastid`），
            // 照参考实现的表来
            let key = ["SingersLastid", "SongLastid", "StyleLastid"]
            switch kind {
            case .singer: param[key[0]] = lastID
            case .song: param[key[1]] = lastID
            case .style: param[key[2]] = lastID
            }
        }
        let data = try await signedMusicu(module: "music.feedback.FeedbackBlack",
                                          method: "GetDislikeList", param: param)
        return (data[kind.readKey] as? [[String: Any]] ?? []).compactMap { item -> DislikeItem? in
            guard let id = item["ID"] as? String, !id.isEmpty else { return nil }
            let time = item["Time"] as? Int ?? 0
            return DislikeItem(id: id,
                               name: item["Name"] as? String ?? "",
                               imageURL: Self.httpsURL(item["Img"] as? String),
                               kind: kind,
                               addedAt: time > 0 ? Date(timeIntervalSince1970: TimeInterval(time)) : nil)
        }
    }

    /// 加进不喜欢名单。`music.feedback.FeedbackBlack/AddDislike`
    /// （[QQMusicApi] `modules/user.py::add_dislike`）。
    /// param 形如 `{"Songs": [{"ID": "123", "IdType": 1}]}`——**ID 是字符串**，
    /// `IdType` 是数字，键名跟着类型走（见 `DislikeKind.writeKey`）。
    /// 成功判据是 `Retcode == 0`（大写 R，跟歌单那边的 `retCode` 不是同一个写法）。
    func addDislike(_ kind: DislikeKind, ids: [String]) async throws {
        try await writeDislike(method: "AddDislike", kind: kind, ids: ids, failure: "加入不喜欢失败")
    }

    /// 从不喜欢名单里移除。`music.feedback.FeedbackBlack/CancelDislike`。
    func cancelDislike(_ kind: DislikeKind, ids: [String]) async throws {
        try await writeDislike(method: "CancelDislike", kind: kind, ids: ids, failure: "取消不喜欢失败")
    }

    private func writeDislike(method: String, kind: DislikeKind,
                              ids: [String], failure: String) async throws {
        _ = try requireCredential()
        let ids = ids.map { $0.rawID }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        let entries = ids.map { ["ID": $0, "IdType": kind.idType] }
        let data = try await musicu(module: "music.feedback.FeedbackBlack", method: method,
                                    param: [kind.writeKey: entries],
                                    clientType: 11, clientVersion: 12060012)
        guard (data["Retcode"] as? Int ?? 0) == 0 else { throw ProviderError.api(failure) }
    }

    /// 清空不喜欢的歌曲。`music.feedback.FeedbackBlack/CancelAllDislike`
    /// （[QQMusicApi] `modules/user.py::cancel_all_dislike_song`）。
    ///
    /// **要打两次**：第一次 `{ISOnlyGetToken: true}` 换一个 `Token`，
    /// 第二次 `{DelType: 3, Token: <上一步的>}` 才真的清。服务端拿这个 token 防误清，
    /// 所以中间那一步不能省。
    func cancelAllDislikeSongs() async throws {
        _ = try requireCredential()
        let tokenData = try await musicu(module: "music.feedback.FeedbackBlack",
                                         method: "CancelAllDislike",
                                         param: ["ISOnlyGetToken": true],
                                         clientType: 11, clientVersion: 12060012)
        let token = tokenData["Token"] as? String ?? ""
        let data = try await musicu(module: "music.feedback.FeedbackBlack",
                                    method: "CancelAllDislike",
                                    param: ["DelType": 3, "Token": token],
                                    clientType: 11, clientVersion: 12060012)
        guard (data["Retcode"] as? Int ?? 0) == 0 else { throw ProviderError.api("清空不喜欢失败") }
    }

    // MARK: - 登出

    /// 服务端登出。`music.login.LoginServer/Logout`（[QQMusicApi] `modules/login.py::logout`），
    /// param 是空对象。
    ///
    /// [实测 2026-09-09 curl] 匿名回 `code=1000`。参考实现在这条上放行了一批错误码
    /// （`allow_error_codes`）——票据本来就要作废，服务端说什么都不该拦住本地清理，
    /// 所以这里也**只在真的成功时才不抛**，而调用方该在 `try?` 之后照常清本地凭证
    /// （本地那一步是 `QQLoginStore` 的事，这一轮不碰）。
    func logout() async throws {
        _ = try requireCredential()
        _ = try await musicu(module: "music.login.LoginServer", method: "Logout", param: [:],
                             clientType: 11, clientVersion: 12060012)
    }

    // MARK: - 签名通道

    /// 走签名网关的一条请求：`https://u.y.qq.com/cgi-bin/musics.fcg?_=<毫秒>&sign=<zzc…>`。
    ///
    /// 少数接口普通网关不认，必须签名：`GetDislikeList`（参考实现里唯一开了 `sign=True`
    /// 的那条）、虫虫钢琴曲谱（`QQAPI+SongInfo.swift`，普通网关回 500031）。
    /// 没往 `QQAPI.musicu` 里加一个 `sign:` 参数，是因为改那条的签名等于动它的
    /// 每一个调用点（取流、歌词、目录页全在上面），为两条接口不值当。
    ///
    /// 与 `musicu` 的两点不同，都是有意的：
    /// - 签名算的是**将要发出去的那串字节**，所以这里必须先把 payload 序列化成 Data、
    ///   对它算签名、再把同一份 Data 发出去。中间不能重新序列化一次（键序会变，签名就废了）；
    /// - 不接 `noteCredentialRejected` 那套登录态复核（它是 private）。这条通道的调用点
    ///   已经在上面拦过「必须登录」，剩下的非 0 码当接口错误报出去就好。
    ///
    /// `commOverride` 与 `userAgent` 是给曲谱那条留的：它要的是 h5 身份的 comm 与网页 UA，
    /// 与「不喜欢名单」的客户端身份不是一套。除此之外两条一模一样，别再各写一份发请求的壳。
    func signedMusicu(module: String, method: String,
                      param: [String: Any],
                      commOverride: [String: Any]? = nil,
                      userAgent: String = QQAPI.clientUA) async throws -> [String: Any] {
        var payload: [String: Any] = [
            "req_0": ["module": module, "method": method, "param": param],
        ]
        if let commOverride {
            payload["comm"] = commOverride
        } else if let credential = credentialProvider?() {
            payload["comm"] = [
                "cv": 12060012, "ct": 11, "format": "json",
                "uin": Int(credential.uin.filter(\.isNumber)) ?? 0,
                "g_tk": 5381,
            ]
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        var components = URLComponents(string: "https://u.y.qq.com/cgi-bin/musics.fcg")!
        components.queryItems = [
            .init(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000))),
            .init(name: "sign", value: Self.zzcSign(body)),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        if let cookie = credentialProvider?()?.cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderError.api("请求失败")
        }
        // 签名不对时服务端回的是**空 body**（[实测 2026-09-09 curl]），所以解不出 JSON
        // 首先要怀疑签名，而不是「接口改了」。
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let req0 = obj["req_0"] as? [String: Any] else {
            throw ProviderError.invalidResponse
        }
        if let code = req0["code"] as? Int, code != 0 {
            throw ProviderError.api("接口错误 code=\(code)")
        }
        return (req0["data"] as? [String: Any]) ?? [:]
    }

    /// QQ 音乐客户端的 zzc 签名。逐行照 [QQMusicApi] `algorithms/sign.py::zzc_sign` 翻译：
    ///
    /// 1. 对 payload 取 SHA1，转成**大写**十六进制（40 个字符）；
    /// 2. 按两张定死的下标表各挑出一串字符（part1 7 个、part2 8 个）；
    /// 3. 把 40 个 hex 字符两两还原成 20 个字节，与一张 20 项的扰动表逐字节异或，
    ///    Base64 之后删掉 `\ / + =` 四种字符；
    /// 4. 拼成 `zzc + part1 + base64段 + part2`，整体转小写。
    ///
    /// [实测 2026-09-09] 与 Python 版对同一份 payload 输出逐字节一致；拿它去打
    /// `musics.fcg` 能拿到正常 JSON（故意改坏则响应为空），见 `signedMusicu` 的注释。
    static func zzcSign(_ payload: Data) -> String {
        let hex = Insecure.SHA1.hash(data: payload).map { String(format: "%02X", $0) }.joined()
        let chars = Array(hex)
        let part1 = [23, 14, 6, 36, 16, 7, 19].map { String(chars[$0]) }.joined()
        let part2 = [16, 1, 32, 12, 19, 27, 8, 5].map { String(chars[$0]) }.joined()
        var scrambled = Data(capacity: Self.signScramble.count)
        for (index, value) in Self.signScramble.enumerated() {
            let byte = UInt8(hex[hex.index(hex.startIndex, offsetBy: index * 2)...]
                .prefix(2), radix: 16) ?? 0
            scrambled.append(value ^ byte)
        }
        let base64 = scrambled.base64EncodedString()
            .filter { !"\\/+=".contains($0) }
        return ("zzc" + part1 + base64 + part2).lowercased()
    }

    /// 签名第 3 步那张扰动表（照抄参考实现的 `SCRAMBLE_VALUES`，一个数都不能动）。
    private static let signScramble: [UInt8] = [
        89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133, 143, 161, 121, 179,
    ]
}

// MARK: - 减少推荐

/// 「减少推荐 / 撤销减少推荐」在 QQ 这边就是**不喜欢名单**的加与删（上面那三条接口），
/// 这里只做菜单要的那一层换算：Amber 手里的 id 与接口要的 id 不是同一种。
extension QQAPI: MusicTasteWriting {

    /// `CancelDislike` 就是撤销，所以这一家两条都摆得出来。
    var supportsUndoSuggestLess: Bool { true }
    /// 不喜欢名单收歌手（`IdType = 2`）。
    var supportsArtistSuggestLess: Bool { true }

    /// **先把 mid 换成数字 songid**：Amber 的 QQ 曲目 id 是 mid（`qq:004OJ2Hr0NDxI7`），
    /// 而 `AddDislike` 的 `Songs[].ID` 收的是数字 id 的字符串形式。换算走的是歌单增删歌
    /// 那条现成的 `songEntries`（一条 `CgiGetTrackInfo` 批量换一整批），别再另写一份。
    func suggestLess(tracks trackIDs: [String], less: Bool) async throws {
        _ = try requireCredential()
        let mids = trackIDs.map(\.rawID).filter { !$0.isEmpty }
        guard !mids.isEmpty else { return }
        let ids = await songEntries(mids: mids).map { String($0.id) }
        guard !ids.isEmpty else {
            throw ProviderError.unavailable("取不到这些歌的数字 id，改不了不喜欢名单")
        }
        if less {
            try await addDislike(.song, ids: ids)
        } else {
            try await cancelDislike(.song, ids: ids)
        }
    }

    /// 歌手同理：Amber 的艺人 id 是 singerMid（`qq:0025NhlN2yWrP4`），名单要的是数字 SingerID，
    /// 走歌手主页那条（`singerHomepage` → `Info.Singer.SingerID`，本身带缓存）换一次。
    func suggestLess(artist artistID: String, less: Bool) async throws {
        _ = try requireCredential()
        guard let singerID = await singerHomepage(artistID: artistID)?.singerID, singerID > 0 else {
            throw ProviderError.unavailable("取不到这个歌手的数字 id，改不了不喜欢名单")
        }
        let ids = [String(singerID)]
        if less {
            try await addDislike(.singer, ids: ids)
        } else {
            try await cancelDislike(.singer, ids: ids)
        }
    }
}
