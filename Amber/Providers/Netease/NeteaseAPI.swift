import Foundation
import os

/// 网易云音乐客户端。
///
/// 三条通道并存，按「这条接口靠哪条通道能多拿到什么」来分，不为统一而统一：
///
/// - **明文 `/api/*` GET**：目录页、搜索、专辑/艺人详情。这些接口匿名照样给全量数据，
///   换成 eapi 一个字段都不会多，只会多一层加解密和一次匿名注册的等待。
/// - **eapi（`interface.music.163.com/eapi/*`）**：取流、歌词、账号歌单、
///   歌单全量曲目。这几条明文那边是残的——取流封顶 128k、歌词没有逐字、
///   歌单只给前若干首。[实测 2026-09-06]
/// - **weapi（网页身份，见 `NeteaseWeapi.swift`）**：登录。扫码走它，
///   而不是走 eapi——客户端身份在登录这一步是风控的靶子。
///
/// eapi 身份统一伪装成 iPhone 客户端 9.0.90：`level`（取流档位）与 `yrc`（逐字歌词）
/// 都是客户端接口才有的字段，网页身份要不到。
final class NeteaseAPI: MusicProvider {

    let kind: ProviderKind = .netease

    private static let base = "https://music.163.com"
    private static let interfaceBase = "https://interface.music.163.com"
    private static let UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    /// eapi 的客户端身份。三处必须自洽：UA、header 里的 `os/appver/osver`、以及 `channel`。
    static let clientUA = "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)"
    private static let clientOS = "iPhone OS"
    private static let clientOSVersion = "17.4.1"
    private static let clientAppVersion = "9.0.90"
    private static let clientChannel = "distribution"

    static let log = Logger(subsystem: "com.changlepan.Amber", category: "NeteaseAPI")

    /// 登录态、音质、过期回调三样由 AppState **推**进来。
    ///
    /// 以前是反过来「拉」的闭包（`credentialProvider` 直读 store 上的 `credential`）。
    /// 改成推是因为请求要能跑在协作线程池上：继承调用方隔离域的函数里，编译器无从证明
    /// 调用方是主 actor，`@MainActor` 闭包在那里根本调不了。三样都是 Sendable 的小值
    /// 类型，放同一把锁后面即可——与仓库里别处的 `OSAllocatedUnfairLock` 同一手法。
    private struct Injected: Sendable {
        var credential: NeteaseCredential?
        var quality: StreamQuality = .standard
        var onCredentialExpired: (@MainActor @Sendable () -> Void)?
    }
    private let injected = OSAllocatedUnfairLock(initialState: Injected())

    /// 当前登录凭证（可能为 nil）。AppState 订阅 store 的 `credential` 推进来。
    var credential: NeteaseCredential? {
        get { injected.withLock { $0.credential } }
        set {
            let changed = injected.withLock { state -> Bool in
                let changed = state.credential != newValue
                state.credential = newValue
                return changed
            }
            if changed {
                let cache = catalogCache
                Task { await cache.invalidateAll() }
            }
        }
    }

    /// 全局流播放档位，已过设置窗的夹取（无损开关 / 杜比全景声）。
    var quality: StreamQuality {
        get { injected.withLock { $0.quality } }
        set { injected.withLock { $0.quality = newValue } }
    }
    /// 凭证过期回调（专用校验接口确认失效时触发）。
    /// 与 QQAPI 同样声明成主线程回调：触发点在 URLSession 的后台续体上，
    /// 接的那头要改 `@Observable` 状态对象上的属性、弹提示，
    /// 跑到后台线程动 AppKit 会直接 SIGABRT。
    var onCredentialExpired: (@MainActor @Sendable () -> Void)? {
        get { injected.withLock { $0.onCredentialExpired } }
        set { injected.withLock { $0.onCredentialExpired = newValue } }
    }

    private let session: URLSession
    /// eapi 专用会话：**关掉系统 cookie 存储**。
    /// eapi 的 cookie 是我们自己按 header 拼出来发的（同一批键值对既进请求体也进 Cookie 头），
    /// 让 URLSession 再插一手，登录态和匿名态的 MUSIC_U / MUSIC_A 会互相污染。
    private let eapiSession: URLSession
    /// 目录类请求的缓存与去重（搜索/取流/歌词不进这里）
    let catalogCache = RequestCache()

    /// 设备号：一个实例固定一个。它同时是匿名 token 的种子，换一个等于换台设备重新注册。
    private let deviceID = NeteaseCrypto.randomDeviceID()
    /// 服务端下发的 eapi 会话 cookie（`NMTID` / `__csrf` / 匿名的 `MUSIC_A`）。
    /// NMTID 由服务端在第一条 eapi 请求后下发，我们只负责带回去，不自己造。
    private let sessionCookies = OSAllocatedUnfairLock(initialState: [String: String]())
    /// weapi 那条路上的**网页**会话 cookie（目前只有 `NMTID`）。
    /// 与上面那份 eapi 的分开存：两套身份混在一起，说不清是谁在发请求——
    /// 而登录那条恰恰就是被服务端挑身份挑掉的（见 `NeteaseWeapi.swift`）。
    let webCookies = OSAllocatedUnfairLock(initialState: [String: String]())
    private let anonymousToken = AnonymousTokenGate()
    /// 复核校验接口同一时刻只跑一条（见 `noteCredentialRejected`）
    private let credentialProbe = OSAllocatedUnfairLock(initialState: false)

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)

        let eapiConfig = URLSessionConfiguration.ephemeral
        eapiConfig.timeoutIntervalForRequest = 30
        eapiConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        eapiConfig.httpShouldSetCookies = false
        eapiConfig.httpCookieStorage = nil
        eapiSession = URLSession(configuration: eapiConfig)
    }

    // MARK: - 基础请求

    func get(_ path: String, params: [String: String] = [:]) async throws -> [String: Any] {
        try await get(base: Self.base, path, params: params)
    }

    /// 部分端点（如专辑详情）仅在 interface.music.163.com 上可用
    func getInterface(_ path: String, params: [String: String] = [:]) async throws -> [String: Any] {
        try await get(base: Self.interfaceBase, path, params: params)
    }

    /// 两个 base 只差域名，请求头（UA / Referer 都指主站）与校验完全一样。
    private func get(base: String, _ path: String,
                     params: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(string: base + path)!
        if !params.isEmpty {
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue(Self.UA, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.base + "/", forHTTPHeaderField: "Referer")
        // 连接类失败重试两次（指数退避），业务错误（下面那条 `code != 200`）不重试。
        // 名单与理由都在 `withConnectionRetry`。
        let (data, response) = try await withConnectionRetry { try await session.data(for: request) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderError.api("请求失败")
        }
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else { throw ProviderError.invalidResponse }
        if let code = dict["code"] as? Int, code != 200 {
            throw ProviderError.api("接口错误 code=\(code)")
        }
        return dict
    }

    // MARK: - eapi 通道

    /// 打一条 eapi 接口。
    ///
    /// `path` 写完整的 `/api/xxx`（加密明文里就是它），真正请求的地址是把开头的 `/api/`
    /// 换成 `/eapi/`——两者不一致就会算出对不上的摘要。
    ///
    /// 请求体是**有序**的（`NeteaseJSON`）：密文只取决于明文字节，键序一变密文就变，
    /// 用 Dictionary 会让同一条请求每次进程算出不同的 `params`。
    ///
    /// - Parameters:
    ///   - anonymous: 只给匿名注册自己用，避免「取匿名 token」再去取匿名 token 的死循环。
    ///   - verifiesCredential: 这条接口是不是「凭证有效性」的权威判据（见 `noteCredentialRejected`）。
    ///   - acceptsAnyCode: 「非 200 才是正常状态」的接口，交给调用方自己看 code。
    @discardableResult
    func eapi(_ path: String, _ body: [(String, NeteaseJSON)] = [],
              anonymous: Bool = false,
              verifiesCredential: Bool = false,
              acceptsAnyCode: Bool = false,
              cookieOverride: String? = nil) async throws -> [String: Any] {
        // 用 cookieOverride 时打的是**别人的**身份（刚扫码换来的那份），
        // 它回 301 跟当前登录态无关，不能拿去注销手上的凭证。
        let credential = (anonymous || cookieOverride != nil) ? nil : credential
        let dict = try await eapiRaw(path, body, anonymous: anonymous,
                                     cookieOverride: cookieOverride).body
        let code = dict["code"] as? Int ?? 200
        guard acceptsAnyCode || code == 200 else {
            // 301「未登录」是网易云唯一的凭证类错误码；其余都是业务错误，不该动登录态。
            if code == 301, credential != nil {
                await noteCredentialRejected(path: path, code: code, authoritative: verifiesCredential)
                throw ProviderError.api("网易云音乐登录已过期，请重新登录")
            }
            throw ProviderError.api("接口错误 code=\(code)")
        }
        return dict
    }

    /// eapi 的裸请求：不看 `code`，连响应一起交出去。
    /// `token/refresh` 那条要的是响应头里的 `Set-Cookie`，所以它直接走这一层。
    ///
    /// **登录不在这条路上**：eapi 自称 iPhone 客户端，而 deviceId 是现造的随机串、
    /// 在网易那儿没有任何注册历史，登录一撞就是风控。那笔实测账连同「一条请求一副现造身份」
    /// 的对策记在 `NeteaseWeapi.swift` 里——现在两条登录路（扫码、Cookie 导入）都不走 eapi，
    /// 那套一次性身份的开关也就跟着手机号登录一起删了。
    func eapiRaw(_ path: String, _ body: [(String, NeteaseJSON)] = [],
                 anonymous: Bool = false,
                 cookieOverride: String? = nil) async throws -> (body: [String: Any], response: HTTPURLResponse) {
        let credential = anonymous ? nil : credential
        // 免登录也要 320k 就得先拿匿名 token；有 MUSIC_U 时不能再带 MUSIC_A，
        // 两个身份一起发服务端只认后者、登录态白丢。
        if !anonymous, credential == nil, cookieOverride == nil {
            await ensureAnonymousToken()
        }

        let header = eapiHeader(credential: credential, cookieOverride: cookieOverride)
        let json = NeteaseJSON.serialize(body + [("header", .object(header.map { ($0.0, .string($0.1)) }))])
        let params = NeteaseCrypto.eapiParams(url: path, json: json)

        var request = URLRequest(url: URL(string: Self.interfaceBase + "/eapi/" + path.dropFirst("/api/".count))!)
        request.httpMethod = "POST"
        request.httpBody = Data("params=\(params)".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.clientUA, forHTTPHeaderField: "User-Agent")
        // 请求体里的 header 与 HTTP 的 Cookie 头是同一批键值对，缺一不可
        request.setValue(header.map { "\($0.0)=\($0.1)" }.joined(separator: "; "),
                         forHTTPHeaderField: "Cookie")

        // 同上：只重试连接类失败。301（登录过期）与别的业务码由 `eapi` 那一层看 `code`，
        // 走不到这里，所以这一句包起来不会把「已过期」拖成三次。
        let (data, response) = try await withConnectionRetry { try await eapiSession.data(for: request) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderError.api("请求失败")
        }
        captureCookies(from: http, url: request.url!)

        guard let dict = Self.decodeEapiBody(data) else { throw ProviderError.invalidResponse }
        return (dict, http)
    }

    /// eapi 的请求头字段。**顺序照客户端**：加密明文里键序一变密文就变。
    private func eapiHeader(credential: NeteaseCredential?,
                            cookieOverride: String?) -> [(String, String)] {
        let cookies = sessionCookies.withLock { $0 }
        func cookie(_ name: String) -> String? {
            if let cookieOverride { return NeteaseCredential.value(of: name, in: cookieOverride) }
            if let credential { return credential.value(of: name) ?? cookies[name] }
            return cookies[name]
        }
        var header: [(String, String)] = [
            ("osver", Self.clientOSVersion),
            ("deviceId", deviceID),
            ("os", Self.clientOS),
            ("appver", Self.clientAppVersion),
            ("versioncode", "140"),
            ("mobilename", ""),
            // 10 位秒级时间戳字符串，客户端拿它当构建号发
            ("buildver", String(Int(Date().timeIntervalSince1970))),
            ("resolution", "1920x1080"),
            ("__csrf", cookie("__csrf") ?? ""),
            ("channel", Self.clientChannel),
            ("requestId", "\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0..<1000).zeroPadded(to: 4))"),
        ]
        if let musicU = cookie("MUSIC_U") {
            header.append(("MUSIC_U", musicU))
        } else if let musicA = cookies["MUSIC_A"] {
            header.append(("MUSIC_A", musicA))
        }
        // NMTID 由服务端下发：第一条 eapi 请求故意不带，拿到之后每条都带回去。
        // 冷启动第一条请求偶尔回 400 就是因为它还没下发（见 `ensureAnonymousToken` 的重试）。
        if let nmtid = cookies["NMTID"] { header.append(("NMTID", nmtid)) }
        return header
    }

    /// 响应一般是明文 JSON；少数接口回 AES-ECB 同密钥的十六进制密文（`e_r` 那条路）。
    /// 两种都认，且以「能不能按 JSON 解析」为准，不按请求参数猜。
    private static func decodeEapiBody(_ data: Data) -> [String: Any]? {
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return dict }
        guard let text = String(data: data, encoding: .utf8),
              let plain = NeteaseCrypto.decryptResponse(hex: text) else { return nil }
        return try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
    }

    /// 一条响应里的 Set-Cookie。多条 Set-Cookie 会被 URLSession 并成一个逗号分隔的头，
    /// 自己按逗号切会把 Expires 里的日期切断——交给 Foundation 的解析器。
    static func setCookies(in response: HTTPURLResponse, url: URL) -> [String: String] {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { out, pair in
            if let key = pair.key as? String, let value = pair.value as? String { out[key] = value }
        }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .filter { !$0.value.isEmpty }
            .reduce(into: [String: String]()) { $0[$1.name] = $1.value }
    }

    private func captureCookies(from response: HTTPURLResponse, url: URL) {
        let cookies = Self.setCookies(in: response, url: url)
            .filter { ["NMTID", "__csrf", "MUSIC_A"].contains($0.key) }
        guard !cookies.isEmpty else { return }
        sessionCookies.withLock { store in
            for (name, value) in cookies { store[name] = value }
        }
    }

    /// 匿名 token：免登录取 320k 的前提。
    ///
    /// 不带它时 `song/enhance/player/url/v1` 对免费歌只肯给 128k——这正是老明文那条路
    /// 音质封顶的真正原因（不是 `br` 参数写死了）。[实测 2026-09-06]
    ///
    /// 整个实例只试这一轮（内含一次重试）：注册接口按 IP 限流，实测冷启动挺容易回 400，
    /// 失败了就按没有匿名 token 继续跑（目录、搜索、128k 取流照常），
    /// 而不是每条请求都去撞一次限流。
    private func ensureAnonymousToken() async {
        await anonymousToken.acquire { [weak self] in
            guard let self else { return }
            let body: [(String, NeteaseJSON)] = [
                ("username", .string(NeteaseCrypto.anonymousUsername(deviceID: self.deviceID))),
            ]
            for attempt in 1...2 {
                // 首次请求服务端还没下发 NMTID，会回 400；重试那条带上 NMTID 就成了
                let code = (try? await self.eapi("/api/register/anonimous", body, anonymous: true,
                                                 acceptsAnyCode: true))?["code"] as? Int
                if code == 200 { return }
                Self.log.notice("匿名 token 注册未成功 code=\(code ?? -1, privacy: .public) 第 \(attempt, privacy: .public) 次")
            }
        }
    }

    // MARK: - 登录态

    /// 手上有没有凭证。`credential` 由 AppState 从 `NeteaseLoginStore` 推进来。
    var isLoggedIn: Bool { credential != nil }

    /// 校验当前 cookie 还认不认。
    ///
    /// 与 QQ 那边同一个道理：取流/搜索在登录态失效时**不报错**，服务端直接按匿名处理，
    /// 界面上一直显示「已登录」、只是 VIP 歌全部取不到流。要发现这件事得主动打一条
    /// 必须登录才有数据的接口——`account/get` 匿名时 `profile` 为空、`anonimousUser` 为真。
    /// 回 301 那条路由 `eapi` 自己处理（`verifiesCredential` 直接注销），所以这里
    /// 只判「回了 200、profile 却是空的」这一种降级。请求本身失败（断网、超时）
    /// 一律**不动**登录态——没证据说明凭证坏了，不能因为网抖一下就把人踢下线。
    func validateCredential() async {
        guard credential != nil else { return }
        guard let profile = try? await accountProfile(verifiesCredential: true) else { return }
        if profile.uid == nil { await onCredentialExpired?() }
    }

    /// 「凭证被拒」只有 `account/get` 说了算，别的接口回 301 一律只当疑似。
    ///
    /// 照抄 QQAPI 那条教训：`markExpired()` 干的是把凭证清空，代价太大——目录类接口拒掉
    /// 一次请求算不上「登录过期」的证据。非权威接口只触发一次复核，由复核决定注销与否。
    private func noteCredentialRejected(path: String, code: Int, authoritative: Bool) async {
        Self.log.error("凭证被拒 code=\(code, privacy: .public) \(path, privacy: .public) 判定=\(authoritative ? "直接注销" : "复核", privacy: .public)")
        if authoritative {
            await onCredentialExpired?()
            return
        }
        let alreadyProbing = credentialProbe.withLock { probing -> Bool in
            defer { probing = true }
            return probing
        }
        guard !alreadyProbing else { return }
        await validateCredential()
        credentialProbe.withLock { $0 = false }
    }

    /// `account/get`：登录态的权威判据，同时也是取 uid / 昵称的地方。
    /// 匿名时它照样回 `code:200`，只是 `profile` 为空——所以判据是 profile 而不是 code。
    func accountProfile(cookieOverride: String? = nil,
                        verifiesCredential: Bool = false) async throws -> (uid: Int?, nickname: String?) {
        let data = try await eapi("/api/w/nuser/account/get", verifiesCredential: verifiesCredential,
                                  cookieOverride: cookieOverride)
        let profile = data["profile"] as? [String: Any]
        return (profile?["userId"] as? Int, profile?["nickname"] as? String)
    }

    /// 已登录账号的歌单（自建 + 收藏都在这一条里，`subscribed` 区分）。
    /// 这一条只读；往账号里写是另外两套协议的事（`MusicLibraryWriting` /
    /// `MusicTasteWriting`），每一处写入都由用户在菜单上点出来。
    func accountPlaylists() async -> [Playlist] {
        guard let credential = credential else { return [] }
        // 凭证里存了登录时拿到的 uid；万一为空（老版本存下来的）再补打一次 account/get
        var resolved = credential.uid
        if resolved == nil { resolved = try? await accountProfile().uid }
        guard let uid = resolved else { return [] }
        let data = try? await eapi("/api/user/playlist", [
            ("uid", .int(uid)), ("limit", 100), ("offset", 0), ("includeVideo", true),
        ])
        return (data?["playlist"] as? [[String: Any]] ?? []).compactMap { item in
            guard var playlist = Self.parsePlaylist(item) else { return nil }
            // 自建与收藏在这一条里混着回，`subscribed` 才是分界；`userId` 再核一次归属，
            // 免得把别人的歌单标成可写（「添加到播放列表」只列自建的那批）。
            playlist.isOwned = (item["subscribed"] as? Bool != true)
                && (item["userId"] as? Int) == uid
            return playlist
        }
    }

    /// 相似艺人。**匿名一律回 301「未登录」**，所以未登录时连打都不打。
    /// 曲目级流派。**网易云没有单曲级的流派**：曲目接口（`song/detail`、歌单/专辑里的
    /// 曲目节点）一个流派字段都不给，只有专辑详情的 `tags` 偶尔带一个（见 `albumDetail`
    /// 里那条注释）。所以这里是去问所属专辑——面板已经先查过资料库里那份专辑了，
    /// 会问到这儿说明本地没有，值得为一格只读文字发一次请求（带缓存）。
    ///
    /// 曲目没有 albumId（搜索接口常常不给）就交不出来，返回 nil。
    func trackGenre(_ track: Track) async -> String? {
        guard let albumId = track.albumId, !albumId.isEmpty else { return nil }
        let stub = Album(id: albumId, kind: .netease, name: track.albumName,
                         artistName: track.artistName, artistId: track.artistId,
                         artworkURL: track.artworkURL, publishDate: nil,
                         trackCount: 0, description: nil)
        guard let detail = try? await albumDetail(stub),
              let genre = detail.album.genre?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !genre.isEmpty else { return nil }
        return genre
    }

    func similarArtists(_ artist: Artist) async -> [Artist] {
        guard isLoggedIn, !artist.isLibraryDerived, let id = Int(artist.id.rawID) else { return [] }
        let data = try? await eapi("/api/discovery/simiArtist", [("artistid", .int(id))])
        return (data?["artists"] as? [[String: Any]] ?? []).compactMap { Self.parseArtist($0) }
    }

    /// 网易云有「按这首找相似歌」的接口，所以自动连播可用。
    var supportsAutoplay: Bool { true }

    /// 相似歌曲，自动连播用它续队列。走 eapi 的 `/api/v1/discovery/simiSong`，
    /// 参数 `songid` / `limit` / `offset`。曲目 id 本来就是数字（`ne:<id>`），不用换算。
    ///
    /// [实测 2026-09-09 curl] 匿名（只带 eapi 头、无 MUSIC_U）就能打通：
    /// songid=1330348068 → `{"code":200,"songs":[…]}`，5 条；`limit` 传 10 或 20 都还是 5 条，
    /// 所以这里把 `limit` 只当「最多要这么多」，给不够不算失败。冷门种子会回 0 条
    /// （songid=185811 就是空表，code 仍是 200），照 `similarArtists` 的口径当「交不出来」。
    ///
    /// 回来的歌是**明文接口那套字段**（`artists` / `album` / `duration`，不是 v3 的
    /// `ar` / `al` / `dt`），`parseTrack` 两套都认，直接交给它。
    /// 没有 `sq` / `hr` 档位节点，于是 `losslessAvailable` 是 nil（未知），与搜索结果同。
    ///
    /// **自动连播只有这一条路**，别再往下接第二、第三条。理由见
    /// `MusicProvider.similarTracks` 的注释——面板上写的是「将播放类似歌曲」。
    func similarTracks(_ track: Track, limit: Int) async -> [Track] {
        guard let id = Int(track.id.rawID) else { return [] }
        let data = try? await eapi("/api/v1/discovery/simiSong",
                                   [("songid", .int(id)), ("limit", .int(Self.simiSongLimit)),
                                    ("offset", 0)])
        let songs = (data?["songs"] as? [[String: Any]] ?? []).compactMap { Self.parseTrack($0) }
        return Array(songs.prefix(limit))
    }

    /// 发给 `simiSong` 的 `limit`。官方默认就是 50（[api-enhanced] `module/simi_song.js`），
    /// 所以一律按 50 要，不跟着调用方那个「一批补几首」的小数走——反正给不满，
    /// 能多拿一首是一首；调用方的 `limit` 在本地 `prefix` 那一步夹。
    ///
    /// [实测 2026-09-09 curl] 匿名 songid=1330348068：`limit` 传 50 回来仍是 5 条，
    /// `offset` 传 5/10/20/50 回的都是**同一批 5 条**（服务端不认这个翻页参数）。
    /// 一次只有 5 条并不意味着自动连播会断：种子跟着当前曲往前走，每换一首就再问一批，
    /// 见 `PlayerController.refillAutoplayIfNeeded`。
    private static let simiSongLimit = 50

    // MARK: - 解析

    private static func artists(_ song: [String: Any]) -> (names: String, firstID: String?) {
        let list = (song["artists"] as? [[String: Any]]) ?? (song["ar"] as? [[String: Any]]) ?? []
        let names = list.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }.joined(separator: " / ")
        let firstID = (list.first?["id"] as? Int).map { "ne:\($0)" }
        return (names.isEmpty ? "未知歌手" : names, firstID)
    }

    static func parseTrack(_ song: [String: Any]) -> Track? {
        guard let id = song["id"] as? Int else { return nil }
        let (artistName, artistId) = artists(song)
        // 明文接口给 `album`，客户端接口（`v3/song/detail`）给缩写的 `al`，字段内容一样
        let album = (song["album"] ?? song["al"]) as? [String: Any]
        let durationMs = (song["duration"] as? Int) ?? (song["dt"] as? Int) ?? 0
        // 专辑/歌单接口的曲目带 sq（无损）与 hr（Hi-Res）档位节点；
        // 搜索接口不带任何档位信息，此时留 nil 表示未知而不是「没有无损」。
        func qualitySize(_ key: String) -> Int {
            ((song[key] as? [String: Any])?["size"] as? Int) ?? 0
        }
        let hasQualityInfo = ["sq", "hr", "h", "m", "l"].contains { song[$0] != nil }
        return Track(
            id: "ne:\(id)",
            kind: .netease,
            title: song["name"] as? String ?? "未知歌曲",
            artistName: artistName,
            artistId: artistId,
            albumName: album?["name"] as? String ?? "",
            albumId: (album?["id"] as? Int).map { "ne:\($0)" },
            artworkURL: Self.artworkURL(album?["picUrl"] as? String ?? ""),
            duration: TimeInterval(durationMs) / 1000,
            // no/cd 是碟内序号与碟号（cd 可能是 "1" 这样的字符串）
            trackNumber: song["no"] as? Int,
            discNumber: (song["cd"] as? Int) ?? (song["cd"] as? String).flatMap(Int.init),
            losslessAvailable: hasQualityInfo
                ? (qualitySize("sq") > 0 || qualitySize("hr") > 0)
                : nil)
    }

    static func parseAlbum(_ a: [String: Any]) -> Album? {
        guard let id = a["id"] as? Int else { return nil }
        let artist = a["artist"] as? [String: Any]
        let artistName: String = {
            if let name = artist?["name"] as? String, !name.isEmpty { return name }
            if let artists = a["artists"] as? [[String: Any]] {
                let joined = artists.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }.joined(separator: " / ")
                if !joined.isEmpty { return joined }
            }
            if let name = a["artistName"] as? String, !name.isEmpty { return name }
            return "未知歌手"
        }()
        let artistId: String? = {
            if let aid = artist?["id"] as? Int, aid > 0 { return "ne:\(aid)" }
            if let artists = a["artists"] as? [[String: Any]], let aid = artists.first?["id"] as? Int, aid > 0 {
                return "ne:\(aid)"
            }
            return nil
        }()
        return Album(
            id: "ne:\(id)",
            kind: .netease,
            name: a["name"] as? String ?? "未知专辑",
            artistName: artistName,
            artistId: artistId,
            artworkURL: Self.artworkURL(a["picUrl"] as? String ?? ""),
            publishDate: Self.formatDate(ms: a["publishTime"] as? Int ?? 0),
            trackCount: a["size"] as? Int ?? 0,
            description: a["description"] as? String,
            // [实测 2026-09-06 curl] /api/artist/albums 每项给 type（Single / EP / 专辑），
            // 艺人页按它拆「单曲和 EP」。
            albumType: a["type"] as? String)
    }

    static func parseArtist(_ a: [String: Any]) -> Artist? {
        guard let id = a["id"] as? Int else { return nil }
        return Artist(
            id: "ne:\(id)",
            kind: .netease,
            name: a["name"] as? String ?? "未知歌手",
            avatarURL: Self.artworkURL(a["picUrl"] as? String ?? ""),
            description: a["briefDesc"] as? String)
    }

    static func parsePlaylist(_ p: [String: Any]) -> Playlist? {
        guard let id = p["id"] as? Int else { return nil }
        return Playlist(
            id: "ne:\(id)",
            kind: .netease,
            name: p["name"] as? String ?? "歌单",
            coverURL: Self.artworkURL(p["picUrl"] as? String ?? p["coverImgUrl"] as? String ?? ""),
            // 匿名状态下 copywriter 是空串（不是缺字段）；空串会在海报卡上多占一行、
            // 在大横幅上变成一张没字的图，统一折成 nil
            description: (p["copywriter"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            playCount: p["playCount"] as? Int ?? 0,
            trackCount: p["trackCount"] as? Int ?? 0,
            creatorName: (p["creator"] as? [String: Any])?["nickname"] as? String)
    }

    static func artworkURL(_ url: String) -> String? {
        guard !url.isEmpty else { return nil }
        // 电台/心情歌单这些接口给的是 http 封面，走 ATS 会被挡，统一升 https
        let url = url.httpsUpgraded
        if url.contains("?") { return url }
        return url + "?param=300y300"
    }

    private static func formatDate(ms: Int) -> String? {
        guard ms > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    // MARK: - 搜索

    func searchTracks(keyword: String, limit: Int, offset: Int) async throws -> [Track] {
        let resp = try await get("/api/search/get", params: [
            "s": keyword, "type": "1", "limit": "\(limit)", "offset": "\(offset)",
        ])
        let songs = (resp["result"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []
        return songs.compactMap { Self.parseTrack($0) }
    }

    func searchAlbums(keyword: String, limit: Int, offset: Int) async throws -> [Album] {
        let resp = try await get("/api/search/get", params: [
            "s": keyword, "type": "10", "limit": "\(limit)", "offset": "\(offset)",
        ])
        let albums = (resp["result"] as? [String: Any])?["albums"] as? [[String: Any]] ?? []
        return albums.compactMap { Self.parseAlbum($0) }
    }

    func searchArtists(keyword: String, limit: Int, offset: Int) async throws -> [Artist] {
        let resp = try await get("/api/search/get", params: [
            "s": keyword, "type": "100", "limit": "\(limit)", "offset": "\(offset)",
        ])
        let artists = (resp["result"] as? [String: Any])?["artists"] as? [[String: Any]] ?? []
        return artists.compactMap { Self.parseArtist($0) }
    }

    func searchPlaylists(keyword: String, limit: Int, offset: Int) async throws -> [Playlist] {
        let resp = try await get("/api/search/get", params: [
            "s": keyword, "type": "1000", "limit": "\(limit)", "offset": "\(offset)",
        ])
        let playlists = (resp["result"] as? [String: Any])?["playlists"] as? [[String: Any]] ?? []
        return playlists.compactMap { Self.parsePlaylist($0) }
    }

    func searchMVs(keyword: String, limit: Int, offset: Int) async throws -> [MV] {
        let resp = try await get("/api/search/get", params: [
            "s": keyword, "type": "1004", "limit": "\(limit)", "offset": "\(offset)",
        ])
        let mvs = (resp["result"] as? [String: Any])?["mvs"] as? [[String: Any]] ?? []
        return mvs.compactMap { Self.parseMV($0) }
    }

    static func parseMV(_ m: [String: Any]) -> MV? {
        guard let id = m["id"] as? Int else { return nil }
        let durationMS = (m["duration"] as? Int) ?? 0
        // MV 封面是 16:9 模板：按 640y360 取图（与 artworkURL 的方图阶梯区分开），并升 https。
        var cover = (m["cover"] as? String)?.httpsUpgraded
        if let unwrapped = cover, !unwrapped.contains("?") {
            cover = unwrapped + "?param=640y360"
        }
        return MV(
            id: "ne:\(id)",
            kind: .netease,
            title: m["name"] as? String ?? "",
            artistName: m["artistName"] as? String ?? "",
            coverURL: cover,
            duration: TimeInterval(durationMS) / 1000,
            webURL: URL(string: "https://music.163.com/#/mv?id=\(id)")!)
    }

    // MARK: - 目录页取数

    /// 按页面（主页 / 新发现 / 广播）与当前登录态组织原生货架。
    ///
    /// 外层套 `CatalogFailureSink.attachFeed`：收集连接类失败，仅在整页全空时填 `failure`。
    func catalogFeed(for page: CatalogFeedPage, recentTracks: [Track]) async -> CatalogFeedResult {
        await CatalogFailureSink.attachFeed {
            switch page {
            case .home:
                return await self.homeShelves(recentTracks: recentTracks)
            case .browse:
                return await self.browseShelves()
            case .radio:
                return await self.radioShelves()
            }
        }
    }

    private func homeShelves(recentTracks: [Track]) async -> [CatalogShelf] {
        let loggedIn = isLoggedIn
        async let blocksTask = homepageBlocks()
        async let dailySongsTask: (tracks: [Track], reasons: [String]) = loggedIn ? cachedDailyRecommendedTracksWithReasons() : ([], [])
        async let dailyListsTask: [Playlist] = loggedIn ? cachedDailyRecommendedPlaylists() : []
        async let officialRadarsTask: [Playlist] = loggedIn ? officialRadarPlaylists() : []
        async let roamingTask = roamingTrackPacks()
        async let prefStyleTask = preferredStyleTracksShelf()
        async let personalizedListsTask = personalized("/api/personalized/playlist", limit: 12)
        async let hqListsTask = highqualityPlaylists(offset: 0, limit: 12)
        async let stylesTask = cachedStyleTags()
        async let radiosTask = cachedRecommendedRadios()
        async let hotRadiosTask = hotDJRadios(limit: 12)
        async let albumsTask = newAlbums(limit: 12, offset: 0)
        async let artistsTask = cachedTopArtists(limit: 12)

        let (blocks, dailySongsPack, dailyLists, officialRadars, roaming, prefStyle,
             personalizedLists, hqLists, styles, rcmdRadios, hotRadios, albums, artists) = await (
            blocksTask, dailySongsTask, dailyListsTask, officialRadarsTask, roamingTask, prefStyleTask,
            personalizedListsTask, hqListsTask, stylesTask, radiosTask, hotRadiosTask, albumsTask, artistsTask
        )

        let dailySongs = dailySongsPack.tracks
        let seedPool = recentTracks.isEmpty ? Array(dailySongs.prefix(3)) : Array(recentTracks.prefix(5))

        async let heartbeatTask: CatalogTrackPack? = loggedIn ? heartbeatTrackPack(seedTracks: seedPool) : nil
        async let moreLikeTracksTask = moreLikeTracksResult(seeds: seedPool)
        async let moreLikeAlbumsTask = moreLikeThisResult(seeds: seedPool)
        async let simiArtistsTask: CatalogSlotResult? = loggedIn ? similarArtistsSlot(seeds: seedPool) : nil

        let (heartbeatPack, moreLikeTracks, moreLikeAlbums, simiArtists) = await (
            heartbeatTask, moreLikeTracksTask, moreLikeAlbumsTask, simiArtistsTask
        )

        var shelves: [CatalogShelf] = []

        // 1. 专属精选推荐（海报卡）：头卡汇聚「每日歌曲推荐」「私人漫游」「心动模式」三大个性化曲目包，随后穿插雷达歌单、新碟与官方场景歌单
        var leadPacks: [CatalogTrackPack] = []
        if !dailySongs.isEmpty {
            let previewNames = dailySongs.prefix(3).map(\.title).joined(separator: " · ")
            let reasonSummary = dailySongsPack.reasons.prefix(2).joined(separator: " · ")
            let subtitle = reasonSummary.isEmpty
                ? "根据你的音乐口味生成 · 每日 6:00 更新"
                : "\(reasonSummary) · 每日 6:00 更新"
            leadPacks.append(CatalogTrackPack(
                id: "ne:daily-songs",
                title: "每日歌曲推荐",
                eyebrow: "每日推荐",
                subtitle: subtitle,
                description: previewNames.isEmpty ? nil : previewNames,
                artworkURL: dailySongs.first?.artworkURL,
                tracks: dailySongs
            ))
        }
        if let defaultFM = roaming.defaultPack {
            leadPacks.append(defaultFM)
        }
        if let heartbeatPack {
            leadPacks.append(heartbeatPack)
        }

        let allRadars = (dailyLists + blocks.radarPlaylists + officialRadars).dedupedByID()
        let topRadios = Array(allRadars.prefix(3))
        let topRadioIDs = Set(topRadios.map(\.id))
        let cleanRecommended = blocks.recommendedPlaylists.filter { !Self.isLowQualityPlaylistTitle($0.name) }
        let topMoods = Array((blocks.officialPlaylists + cleanRecommended).dedupedByID().prefix(4))
        let topMoodIDs = Set(topMoods.map(\.id))
        let mergedAlbums = (blocks.newAlbums + albums).dedupedByID()
        let topAlbums = Array(mergedAlbums.prefix(6))

        let topPicks = CatalogSlotResult.topPicks(
            leadPacks: leadPacks,
            radios: topRadios,
            moods: topMoods,
            albums: topAlbums
        )
        if let shelf = CatalogShelf.make(id: "top-picks", title: "专属精选推荐", style: .poster, result: topPicks) {
            shelves.append(shelf)
        }

        // 2. 专属与雷达歌单（海报卡）：优先展示未在首屏用掉的私人雷达与日推歌单
        let remainingRadars = allRadars.filter { !topRadioIDs.contains($0.id) }
        let madePlaylists = remainingRadars.isEmpty ? allRadars : remainingRadars
        if let shelf = CatalogShelf.playlists(
            id: "made-for-you",
            title: loggedIn ? "专属与雷达歌单" : "雷达歌单",
            style: .poster,
            Array(madePlaylists.prefix(8))
        ) {
            shelves.append(shelf)
        }

        // 3. 私人漫游 · 场景与模式（多模式 FM 曲目包：熟悉 / 探索 / 专注 / 夜晚情绪 / 运动）
        if roaming.scenePacks.count > 1,
           let shelf = CatalogShelf.trackPacks(
               id: "fm-modes",
               title: "私人漫游 · 场景与模式",
               style: .squares(rows: 1),
               roaming.scenePacks
           ) {
            shelves.append(shelf)
        }

        // 4. 个性化风格曲目流（来自登录态 HOMEPAGE_BLOCK_STYLE_RCMD，如「根据『Play a Love Song』为你推荐」）
        let homeTracks = !blocks.styleSongs.isEmpty ? blocks.styleSongs : blocks.newSongs
        let homeTrackTitle = !blocks.styleSongs.isEmpty ? (blocks.styleTitle ?? "风格精选") : "新歌速递"
        if let shelf = CatalogShelf.tracks(
            id: "home-songs",
            title: homeTrackTitle,
            style: .trackColumns(rows: 4),
            showsChevron: true,
            Array(homeTracks.prefix(16))
        ) {
            shelves.append(shelf)
        }

        // 5. 偏爱曲风专属曲目流（来自 /api/tag/my/preference/get + /api/style-tag/home/song）
        if let prefStyle {
            let homeTrackIDs = Set(homeTracks.prefix(16).map(\.id))
            let filteredPrefTracks = prefStyle.tracks.filter { !homeTrackIDs.contains($0.id) }
            if let shelf = CatalogShelf.tracks(
                id: "preferred-style-songs",
                title: prefStyle.title,
                style: .trackColumns(rows: 4),
                showsChevron: true,
                Array(filteredPrefTracks.prefix(16))
            ) {
                shelves.append(shelf)
            }
        }

        // 6. 单曲级相似推荐曲目流（基于最近播放或日推首曲的 /api/v1/discovery/simiSong）
        if let moreLikeTracks,
           let shelf = CatalogShelf.make(
               id: "more-like-tracks",
               style: .trackColumns(rows: 4),
               showsChevron: true,
               result: moreLikeTracks
           ) {
            shelves.append(shelf)
        }

        // 7. 更多类似作品（专辑级相似推荐）
        if let moreLikeAlbums,
           let shelf = CatalogShelf.make(
               id: "more-like-1",
               style: .squares(rows: 1),
               showsChevron: true,
               result: moreLikeAlbums
           ) {
            shelves.append(shelf)
        }

        // 8. 相似艺人推荐（登录态 /api/discovery/simiArtist）
        if let simiArtists,
           let shelf = CatalogShelf.make(
               id: "similar-artists",
               style: .squares(rows: 1),
               showsChevron: true,
               result: simiArtists
           ) {
            shelves.append(shelf)
        }

        // 9. 专属场景歌单（来自首页 HOMEPAGE_BLOCK_OFFICIAL_PLAYLIST 官方甄选）
        let officialLists = blocks.officialPlaylists.filter { !topMoodIDs.contains($0.id) }
        if let shelf = CatalogShelf.playlists(
            id: "official-playlists",
            title: "专属场景歌单",
            style: .squares(rows: 1),
            showsChevron: true,
            officialLists.isEmpty ? blocks.officialPlaylists : officialLists
        ) {
            shelves.append(shelf)
        }

        // 10. 推荐歌单（过滤营销号标题，结合精品歌单兜底）
        let cleanPersonalized = personalizedLists.filter { !Self.isLowQualityPlaylistTitle($0.name) }
        let rcmdLists = (cleanRecommended + cleanPersonalized + hqLists)
            .filter { !topMoodIDs.contains($0.id) && !topRadioIDs.contains($0.id) }
            .dedupedByID()
        if let shelf = CatalogShelf.playlists(
            id: "recommended-playlists",
            title: "甄选歌单",
            style: .squares(rows: 1),
            showsChevron: true,
            Array(rcmdLists.prefix(16))
        ) {
            shelves.append(shelf)
        }

        // 11. 曲风馆（视觉卡片，登录态下将用户偏好的曲风排在最前）
        let preferredParentIDs = prefStyle?.preferredParentIDs ?? []
        let orderedStyles: [NeteaseStyleTag]
        if preferredParentIDs.isEmpty {
            orderedStyles = styles
        } else {
            let prefSet = Set(preferredParentIDs)
            let front = preferredParentIDs.compactMap { id in styles.first(where: { $0.id == id }) }
            let rest = styles.filter { !prefSet.contains($0.id) }
            orderedStyles = front + rest
        }
        let styleGroups = Self.visualStyleGroups(from: orderedStyles)
        if let shelf = CatalogShelf.tagGroups(
            id: "style-tags",
            title: "曲风馆",
            style: .stations,
            showsChevron: true,
            styleGroups
        ) {
            shelves.append(shelf)
        }

        // 12. 热门播客
        let mergedRadios = (rcmdRadios.radios + hotRadios).dedupedByID()
        if let shelf = CatalogShelf.playlists(
            id: "hot-radios",
            title: "热门播客",
            style: .stations,
            showsChevron: true,
            mergedRadios
        ) {
            shelves.append(shelf)
        }

        // 13. 最新上架
        if let shelf = CatalogShelf.albums(
            id: "latest-albums",
            title: "最新上架",
            style: .squares(rows: 1),
            showsChevron: true,
            mergedAlbums
        ) {
            shelves.append(shelf)
        }

        // 14. 热门歌手
        if let shelf = CatalogShelf.artists(
            id: "hot-artists",
            title: "热门歌手",
            style: .squares(rows: 1),
            showsChevron: true,
            artists
        ) {
            shelves.append(shelf)
        }

        return shelves
    }

    private func browseShelves() async -> [CatalogShelf] {
        async let hqHeroTask = highqualityPlaylists(offset: 0, limit: 6)
        async let hqMoreTask = highqualityPlaylists(offset: 6, limit: 24)
        async let newSongsTask = cachedNewSongs(area: .all)
        async let areaAlbumsTask = cachedNewAlbumsByArea()
        async let fallbackAlbumsTask = newAlbums(limit: 24, offset: 0)
        async let toplistsTask = cachedToplistGroups()
        async let mvsTask = cachedLatestMVs(limit: 12)
        async let catalogueTask = cachedPlaylistCatalogue()
        async let stylesTask = cachedStyleTags()

        let (hqHero, hqMore, newSongsList, areaAlbums, fallbackAlbums,
             toplistGroups, mvs, catalogue, styles) = await (
            hqHeroTask, hqMoreTask, newSongsTask, areaAlbumsTask, fallbackAlbumsTask,
            toplistsTask, mvsTask, catalogueTask, stylesTask
        )

        var shelves: [CatalogShelf] = []

        // 1. 顶部 Hero：精品歌单前 6 张
        if !hqHero.isEmpty {
            var eyebrows: [String: String] = [:]
            for item in hqHero { eyebrows[item.id] = "精品歌单" }
            if let shelf = CatalogShelf.make(
                id: "hero",
                style: .hero,
                result: .init(items: .playlists(hqHero), eyebrows: eyebrows)
            ) {
                shelves.append(shelf)
            }
        }

        // 2. 新歌速递（/api/v1/discovery/new/songs）
        let newSongChart = Playlist(id: "ne:3779629", kind: .netease, name: "新歌榜")
        if let shelf = CatalogShelf.tracks(
            id: "new-songs",
            title: "新歌速递",
            style: .trackColumns(rows: 4),
            showsChevron: true,
            seeAll: newSongChart,
            Array(newSongsList.prefix(20))
        ) {
            shelves.append(shelf)
        }

        // 3. 本周新碟 & 本月新碟（/api/discovery/new/albums/area）
        let weekAlbums = !areaAlbums.week.isEmpty ? Array(areaAlbums.week.prefix(24)) : fallbackAlbums
        if let shelf = CatalogShelf.albums(
            id: "new-albums-week",
            title: "本周新碟",
            style: .squares(rows: 1),
            showsChevron: true,
            weekAlbums
        ) {
            shelves.append(shelf)
        }

        let weekIDs = Set(weekAlbums.map(\.id))
        let monthAlbums = Array(areaAlbums.month.filter { !weekIDs.contains($0.id) }.prefix(24))
        if let shelf = CatalogShelf.albums(
            id: "new-albums-month",
            title: "本月新碟",
            style: .squares(rows: 1),
            showsChevron: true,
            monthAlbums
        ) {
            shelves.append(shelf)
        }

        // 4. 精品歌单（双行方卡）
        if let shelf = CatalogShelf.playlists(
            id: "highquality-playlists",
            title: "精品歌单",
            style: .squares(rows: 2),
            showsChevron: true,
            hqMore
        ) {
            shelves.append(shelf)
        }

        // 5. 排行榜全分组（/api/toplist/detail/v2 原生 7 组：榜单推荐/官方榜/精选榜/曲风榜/全球榜/语种榜/特色榜）
        var seenToplistGroupIDs: [String: Int] = [:]
        for group in toplistGroups {
            let count = seenToplistGroupIDs[group.id, default: 0]
            seenToplistGroupIDs[group.id] = count + 1
            let shelfID = count == 0 ? "toplist-\(group.id)" : "toplist-\(group.id)-\(count)"
            let charts = group.charts.map { entry in
                Playlist(
                    id: entry.playlistID,
                    kind: .netease,
                    name: entry.name,
                    coverURL: entry.coverURL,
                    description: entry.updateFrequency,
                    creatorName: group.name
                )
            }
            if let shelf = CatalogShelf.playlists(
                id: shelfID,
                title: group.name,
                style: .squares(rows: 1),
                showsChevron: true,
                charts
            ) {
                shelves.append(shelf)
            }
        }

        // 6. 最新 MV
        if let shelf = CatalogShelf.mvs(
            id: "mv-first",
            title: "最新 MV",
            style: .videos,
            showsChevron: true,
            mvs
        ) {
            shelves.append(shelf)
        }

        // 7. 歌单与曲风分类（探索更多）
        var exploreGroups = catalogue
        if !styles.isEmpty {
            let styleRefs = styles.map { CatalogTagRef(id: "style:\($0.id)", name: $0.name) }
            exploreGroups.append(CatalogTagGroup(
                id: "ne-style-all",
                kind: .netease,
                name: "曲风分类",
                tags: styleRefs
            ))
        }
        if let shelf = CatalogShelf.tagGroups(
            id: "explore",
            title: "歌单分类",
            style: .links,
            exploreGroups
        ) {
            shelves.append(shelf)
        }

        return shelves
    }

    private func radioShelves() async -> [CatalogShelf] {
        async let rcmdTask = cachedRecommendedRadios()
        async let personalTask = cachedPersonalizedRadios()
        async let hourlyProgramsTask = cachedProgramToplistHourly(limit: 24)
        async let hotToplistTask = cachedRadioToplist(hot: true, limit: 16)
        async let newToplistTask = cachedRadioToplist(hot: false, limit: 16)
        async let categoriesTask = cachedDJCategoryRecommendations()

        let (rcmd, personal, hourlyPrograms, hotToplist, newToplist, categories) = await (
            rcmdTask, personalTask, hourlyProgramsTask, hotToplistTask, newToplistTask, categoriesTask
        )

        var shelves: [CatalogShelf] = []

        // 1. 广播顶部 Hero：精选电台 + 个性化推荐电台
        let heroRadios = Array((rcmd.radios + personal).dedupedByID().prefix(6))
        if !heroRadios.isEmpty {
            var eyebrows: [String: String] = [:]
            let badge = rcmd.title ?? "精选播客"
            for radio in heroRadios { eyebrows[radio.id] = badge }
            if let shelf = CatalogShelf.make(
                id: "radio-hero",
                style: .hero,
                result: .init(items: .playlists(heroRadios), eyebrows: eyebrows)
            ) {
                shelves.append(shelf)
            }
        }

        // 2. 24 小时节目热榜（/api/djprogram/toplist/hours）
        if let shelf = CatalogShelf.tracks(
            id: "program-toplist",
            title: "24 小时节目榜",
            style: .episodes(rows: 3),
            showsChevron: true,
            hourlyPrograms
        ) {
            shelves.append(shelf)
        }

        // 3. 热门电台榜 & 新晋电台榜（/api/djradio/toplist）
        if let shelf = CatalogShelf.playlists(
            id: "radio-hot",
            title: "热门电台榜",
            style: .stations,
            showsChevron: true,
            hotToplist
        ) {
            shelves.append(shelf)
        }
        if let shelf = CatalogShelf.playlists(
            id: "radio-new",
            title: "新晋电台榜",
            style: .stations,
            showsChevron: true,
            newToplist
        ) {
            shelves.append(shelf)
        }

        // 4. 分类推荐电台全矩阵（/api/djradio/home/category/recommend 一次返回全部 12 组）
        var seenCategoryIDs: [String: Int] = [:]
        for category in categories {
            let count = seenCategoryIDs[category.id, default: 0]
            seenCategoryIDs[category.id] = count + 1
            let shelfID = count == 0 ? "dj-cat-\(category.id)" : "dj-cat-\(category.id)-\(count)"
            if let shelf = CatalogShelf.playlists(
                id: shelfID,
                title: category.categoryName,
                style: .stations,
                showsChevron: true,
                category.radios
            ) {
                shelves.append(shelf)
            }
        }

        return shelves
    }

    /// 分类浏览页：支持曲风标签（`style:<tagId>` 走 `stylePlaylists`）与传统歌单分类（`/api/playlist/list`）。
    func playlists(tag: CatalogTagRef) async -> [Playlist] {
        if tag.id.hasPrefix("style:") {
            let tagID = String(tag.id.dropFirst("style:".count))
            return await catalogCache.value(for: "ne:style/playlist:\(tagID)") {
                let list = await self.stylePlaylists(tagID: tagID, size: 36).playlists
                return list.isEmpty ? nil : list
            } ?? []
        }
        return await taggedPlaylists(tag.id, limit: 36)
    }

    /// 一级曲风列表转为带封面与二级胶囊的 `CatalogTagGroup`。
    private static func visualStyleGroups(from tags: [NeteaseStyleTag]) -> [CatalogTagGroup] {
        tags.compactMap { tag in
            let allRef = CatalogTagRef(id: "style:\(tag.id)", name: "全部")
            let childRefs = tag.children.map { CatalogTagRef(id: "style:\($0.id)", name: $0.name) }
            return CatalogTagGroup(
                id: "ne-style-\(tag.id)",
                kind: .netease,
                name: tag.name,
                subtitle: tag.englishName,
                coverURL: tag.picURL,
                tags: [allRef] + childRefs
            )
        }
    }

    private func moreLikeTracksResult(seeds: [Track]) async -> CatalogSlotResult? {
        for seed in seeds.prefix(3) {
            var resp = try? await eapi("/api/v1/discovery/simiSong", [
                ("songid", .string(seed.id.rawID)),
                ("limit", 12),
                ("offset", 0),
            ])
            if resp == nil {
                resp = try? await get("/api/discovery/simiSong",
                                      params: ["songid": seed.id.rawID, "limit": "12"])
            }
            guard let songs = resp?["songs"] as? [[String: Any]] else { continue }
            let tracks = songs.compactMap { Self.parseTrack($0) }.dedupedByID()
            if !tracks.isEmpty {
                let seedAlbum = Album(
                    id: seed.albumId ?? seed.id, kind: seed.kind,
                    name: seed.albumName.isEmpty ? seed.title : seed.albumName,
                    artistName: seed.artistName, artistId: seed.artistId,
                    artworkURL: seed.artworkURL, publishDate: nil,
                    trackCount: 0, description: nil
                )
                return .init(
                    items: .tracks(Array(tracks.prefix(12))),
                    title: seed.title,
                    headline: "听过这首歌也会喜欢",
                    seedArtworkURL: seed.artworkURL,
                    seedAlbum: seedAlbum
                )
            }
        }
        return nil
    }

    private func moreLikeThisResult(seeds: [Track]) async -> CatalogSlotResult? {
        for seed in seeds.prefix(3) {
            var resp = try? await eapi("/api/v1/discovery/simiSong", [
                ("songid", .string(seed.id.rawID)),
                ("limit", 12),
                ("offset", 0),
            ])
            if resp == nil {
                resp = try? await get("/api/discovery/simiSong",
                                      params: ["songid": seed.id.rawID, "limit": "12"])
            }
            guard let songs = resp?["songs"] as? [[String: Any]] else { continue }
            let albums = songs.compactMap { song -> Album? in
                guard let album = (song["album"] as? [String: Any]) ?? (song["al"] as? [String: Any]) else { return nil }
                return Self.parseAlbum(album)
            }.dedupedByID()
            if !albums.isEmpty {
                let seedAlbum = Album(
                    id: seed.albumId ?? seed.id, kind: seed.kind,
                    name: seed.albumName.isEmpty ? seed.title : seed.albumName,
                    artistName: seed.artistName, artistId: seed.artistId,
                    artworkURL: seed.artworkURL, publishDate: nil,
                    trackCount: 0, description: nil
                )
                return .init(
                    items: .albums(albums),
                    title: seed.title,
                    headline: "更多类似作品",
                    seedArtworkURL: seed.artworkURL,
                    seedAlbum: seedAlbum
                )
            }
        }
        return nil
    }

    private func similarArtistsSlot(seeds: [Track]) async -> CatalogSlotResult? {
        var seenArtistIDs = Set<String>()
        for seed in seeds {
            guard let artistID = seed.artistId, !artistID.isEmpty, !seed.artistName.isEmpty,
                  seenArtistIDs.insert(artistID).inserted else { continue }
            let cleanArtistName = seed.artistName.split(separator: "/").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? seed.artistName
            let seedArtist = Artist(
                id: artistID, kind: .netease, name: cleanArtistName,
                avatarURL: nil, description: nil
            )
            let artists = await similarArtists(seedArtist)
            if !artists.isEmpty {
                return .init(
                    items: .artists(Array(artists.prefix(12))),
                    title: "与「\(cleanArtistName)」相似的歌手"
                )
            }
        }
        return nil
    }

    private struct PreferredStylePack: Sendable {
        let title: String
        let tracks: [Track]
        let preferredParentIDs: [String]
    }

    /// 登录态下获取用户听歌偏好曲风（`/api/tag/my/preference/get`），并拉取排名第一的偏好子曲风下的精选曲目流。
    private func preferredStyleTracksShelf() async -> PreferredStylePack? {
        guard isLoggedIn else { return nil }
        let uidKey = credential?.uid ?? 0
        return await catalogCache.value(for: "ne:preferredStyleTracks:\(uidKey)") { () -> PreferredStylePack? in
            let prefs = await self.stylePreferences()
            guard let topParent = prefs.first else { return nil }
            let parentIDs = prefs.map(\.id)
            let chosenTag = topParent.children.first ?? topParent
            let res = await self.styleTracks(tagID: chosenTag.id, cursor: 0, size: 20, sort: 0)
            guard !res.tracks.isEmpty else { return nil }
            return PreferredStylePack(
                title: "为你精选 · \(chosenTag.name)",
                tracks: res.tracks,
                preferredParentIDs: parentIDs
            )
        }
    }

    /// 过滤混入 `HOMEPAGE_BLOCK_PLAYLIST_RCMD` 与 `/api/personalized/playlist` 的低质标题党 / 营销号 UGC 歌单。
    static func isLowQualityPlaylistTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        let spamKeywords = [
            "抖音", "快手", "车载", "土嗨", "蹦迪", "夜店", "喊麦", "神曲", "网红",
            "慢摇", "串烧", "0.8x", "0.9x", "1.2x", "降调", "倍速", "听前奏",
            "百万红心", "999+", "删前", "不甜不要钱", "开口跪", "前方高能",
            "建议收藏", "vip免费", "免费听", "游戏专用", "吃鸡", "王者",
        ]
        for kw in spamKeywords where lower.contains(kw) {
            return true
        }
        // 含 2 个及以上「|」或「/」堆砌标签的标题党歌单
        let pipeCount = title.filter { $0 == "|" || $0 == "｜" }.count
        if pipeCount >= 2 { return true }
        return false
    }

    // MARK: - 首页聚合与目录缓存

    private struct HomepageBlocks: Sendable {
        var radarPlaylists: [Playlist] = []
        var officialPlaylists: [Playlist] = []
        var recommendedPlaylists: [Playlist] = []
        var styleTitle: String?
        var styleSongs: [Track] = []
        var newSongs: [Track] = []
        var newAlbums: [Album] = []
    }

    private func homepageBlocks() async -> HomepageBlocks {
        let uidKey = credential?.uid ?? 0
        return await catalogCache.value(for: "ne:/api/homepage/block/page:\(uidKey)") {
            await self.loadHomepageBlocks()
        } ?? HomepageBlocks()
    }

    private func loadHomepageBlocks() async -> HomepageBlocks? {
        var resp = try? await eapi("/api/homepage/block/page")
        if resp == nil {
            resp = try? await get("/api/homepage/block/page")
        }
        guard let blocks = (resp?["data"] as? [String: Any])?["blocks"] as? [[String: Any]] else {
            return nil
        }
        var out = HomepageBlocks()
        for block in blocks {
            guard let code = block["blockCode"] as? String else { continue }
            let creatives = block["creatives"] as? [[String: Any]] ?? []
            switch code {
            case "HOMEPAGE_BLOCK_MGC_PLAYLIST":
                out.radarPlaylists = Self.parseBlockPlaylists(
                    creatives: creatives,
                    splitRadarTitle: true,
                    defaultCreator: "网易云音乐"
                )
            case "HOMEPAGE_BLOCK_OFFICIAL_PLAYLIST":
                out.officialPlaylists = Self.parseBlockPlaylists(
                    creatives: creatives,
                    splitRadarTitle: false,
                    defaultCreator: "官方甄选"
                )
            case "HOMEPAGE_BLOCK_PLAYLIST_RCMD":
                out.recommendedPlaylists = Self.parseBlockPlaylists(
                    creatives: creatives,
                    splitRadarTitle: false,
                    defaultCreator: nil
                )
            case "HOMEPAGE_BLOCK_STYLE_RCMD":
                let ui = block["uiElement"] as? [String: Any]
                out.styleTitle = ((ui?["subTitle"] as? [String: Any])?["title"] as? String)
                    ?? ((ui?["mainTitle"] as? [String: Any])?["title"] as? String)
                out.styleSongs = Self.parseBlockTracks(creatives: creatives)
            case "HOMEPAGE_BLOCK_NEW_ALBUM_NEW_SONG":
                let songCreatives = creatives.filter { ($0["creativeType"] as? String) == "NEW_SONG_HOMEPAGE" }
                let albumCreatives = creatives.filter {
                    let type = $0["creativeType"] as? String
                    return type == "NEW_ALBUM_HOMEPAGE" || type == "DIGITAL_ALBUM_HOMEPAGE"
                }
                out.newSongs = Self.parseBlockTracks(creatives: songCreatives)
                out.newAlbums = Self.parseBlockAlbums(creatives: albumCreatives)
            default:
                break
            }
        }
        return out
    }

    private static func parseBlockPlaylists(
        creatives: [[String: Any]],
        splitRadarTitle: Bool,
        defaultCreator: String?
    ) -> [Playlist] {
        var playlists: [Playlist] = []
        for creative in creatives {
            let resources = (creative["resources"] as? [[String: Any]]) ?? []
            let nodes = resources.isEmpty ? [creative] : resources
            for node in nodes {
                let id = (node["resourceId"] as? String)
                    ?? (node["creativeId"] as? String)
                    ?? (creative["creativeId"] as? String)
                guard let id, !id.isEmpty, Int(id) != nil else { continue }
                let ui = (node["uiElement"] as? [String: Any]) ?? (creative["uiElement"] as? [String: Any])
                guard let rawTitle = ((ui?["mainTitle"] as? [String: Any])?["title"]) as? String,
                      !rawTitle.isEmpty else { continue }
                let cover = ((ui?["image"] as? [String: Any])?["imageUrl"]) as? String ?? ""
                let subTitle = ((ui?["subTitle"] as? [String: Any])?["title"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 }
                let ext = node["resourceExtInfo"] as? [String: Any]
                let playCount = ext?["playCount"] as? Int ?? 0

                let parts = rawTitle.split(separator: "|", maxSplits: 1)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let name: String
                let desc: String?
                if parts.count > 1 {
                    name = splitRadarTitle ? parts[1] : parts[0]
                    desc = splitRadarTitle ? parts[0] : parts[1]
                } else {
                    name = rawTitle
                    desc = subTitle
                }
                playlists.append(Playlist(
                    id: "ne:\(id)",
                    kind: .netease,
                    name: name,
                    coverURL: artworkURL(cover),
                    description: desc,
                    playCount: playCount,
                    creatorName: defaultCreator
                ))
            }
        }
        return playlists.dedupedByID()
    }

    private static func parseBlockTracks(creatives: [[String: Any]]) -> [Track] {
        var tracks: [Track] = []
        for creative in creatives {
            let resources = (creative["resources"] as? [[String: Any]]) ?? []
            for resource in resources {
                let ext = resource["resourceExtInfo"] as? [String: Any]
                if let songData = (ext?["songData"] as? [String: Any]) ?? (ext?["song"] as? [String: Any]),
                   let track = parseTrack(songData) {
                    tracks.append(track)
                }
            }
        }
        return tracks.dedupedByID()
    }

    private static func parseBlockAlbums(creatives: [[String: Any]]) -> [Album] {
        var albums: [Album] = []
        for creative in creatives {
            let resources = (creative["resources"] as? [[String: Any]]) ?? []
            for resource in resources {
                guard let id = resource["resourceId"] as? String, !id.isEmpty else { continue }
                let ui = resource["uiElement"] as? [String: Any]
                guard let name = ((ui?["mainTitle"] as? [String: Any])?["title"]) as? String,
                      !name.isEmpty else { continue }
                let cover = ((ui?["image"] as? [String: Any])?["imageUrl"]) as? String ?? ""
                let ext = resource["resourceExtInfo"] as? [String: Any]
                let artists = ext?["artists"] as? [[String: Any]] ?? []
                let artistName = artists.compactMap { $0["name"] as? String }
                    .filter { !$0.isEmpty }
                    .joined(separator: " / ")
                let artistId = (artists.first?["id"] as? Int).map { "ne:\($0)" }
                let subTitle = ((ui?["subTitle"] as? [String: Any])?["title"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 }
                albums.append(Album(
                    id: "ne:\(id)",
                    kind: .netease,
                    name: name,
                    artistName: artistName.isEmpty ? "未知歌手" : artistName,
                    artistId: artistId,
                    artworkURL: artworkURL(cover),
                    publishDate: nil,
                    trackCount: 0,
                    description: subTitle
                ))
            }
        }
        return albums.dedupedByID()
    }

    private struct DailyTracksPack: Sendable {
        let tracks: [Track]
        let reasons: [String]
    }

    private func cachedDailyRecommendedTracksWithReasons() async -> (tracks: [Track], reasons: [String]) {
        let uidKey = credential?.uid ?? 0
        let pack = await catalogCache.value(for: "ne:dailyRecommendedTracksPack:\(uidKey)") { () -> DailyTracksPack? in
            let res = await self.dailyRecommendedTracksWithReasons()
            guard !res.tracks.isEmpty else { return nil }
            return DailyTracksPack(tracks: res.tracks, reasons: res.reasons)
        }
        return (pack?.tracks ?? [], pack?.reasons ?? [])
    }

    private func cachedDailyRecommendedTracks() async -> [Track] {
        await cachedDailyRecommendedTracksWithReasons().tracks
    }

    private func cachedDailyRecommendedPlaylists() async -> [Playlist] {
        let uidKey = credential?.uid ?? 0
        return await catalogCache.value(for: "ne:dailyRecommendedPlaylists:\(uidKey)") {
            let lists = await self.dailyRecommendedPlaylists()
            return lists.isEmpty ? nil : lists
        } ?? []
    }

    private func cachedStyleTags() async -> [NeteaseStyleTag] {
        await catalogCache.value(for: "ne:/api/tag/list/get") {
            let tags = await self.styleTags()
            return tags.isEmpty ? nil : tags
        } ?? []
    }

    private func cachedToplistGroups() async -> [NeteaseToplistGroup] {
        await catalogCache.value(for: "ne:/api/toplist/detail/v2") {
            let groups = await self.toplistGroups()
            return groups.isEmpty ? nil : groups
        } ?? []
    }

    private func cachedNewSongs(area: NeteaseArtistArea) async -> [Track] {
        await catalogCache.value(for: "ne:/api/v1/discovery/new/songs:\(area.rawValue)") {
            let songs = await self.newSongs(area: area)
            return songs.isEmpty ? nil : songs
        } ?? []
    }

    private struct AreaAlbumsPair: Sendable {
        let week: [Album]
        let month: [Album]
    }

    private func cachedNewAlbumsByArea() async -> AreaAlbumsPair {
        await catalogCache.value(for: "ne:/api/discovery/new/albums/area:ALL") {
            let pair = await self.newAlbumsByArea(area: "ALL", type: "new", limit: 30)
            guard !pair.week.isEmpty || !pair.month.isEmpty else { return nil }
            return AreaAlbumsPair(week: pair.week, month: pair.month)
        } ?? AreaAlbumsPair(week: [], month: [])
    }

    private func cachedTopArtists(limit: Int) async -> [Artist] {
        await catalogCache.value(for: "ne:/api/artist/top?limit=\(limit)") {
            let list = await self.topArtists(limit: limit, offset: 0)
            if !list.isEmpty { return list }
            guard let resp = try? await self.get("/api/toplist/artist", params: ["type": "1"]),
                  let artists = ((resp["list"] as? [String: Any])?["artists"]) as? [[String: Any]]
            else { return nil }
            return Array(artists.prefix(limit)).compactMap { Self.parseArtist($0) }
        } ?? []
    }

    private func cachedLatestMVs(limit: Int) async -> [MV] {
        await catalogCache.value(for: "ne:/api/mv/first?limit=\(limit)") {
            guard let resp = try? await self.get("/api/mv/first", params: ["limit": "\(limit)"]),
                  let data = resp["data"] as? [[String: Any]] else { return nil }
            let mvs = data.compactMap { Self.parseMV($0) }
            return mvs.isEmpty ? nil : mvs
        } ?? []
    }

    private func cachedPlaylistCatalogue() async -> [CatalogTagGroup] {
        await catalogCache.value(for: "ne:/api/playlist/catalogue") {
            guard let resp = try? await self.get("/api/playlist/catalogue"),
                  let categories = resp["categories"] as? [String: Any],
                  let sub = resp["sub"] as? [[String: Any]] else { return nil }
            let groups = categories.keys.compactMap(Int.init).sorted().compactMap { index -> CatalogTagGroup? in
                guard let name = categories["\(index)"] as? String else { return nil }
                let tags = sub
                    .filter { ($0["category"] as? Int) == index }
                    .compactMap { $0["name"] as? String }
                    .map { CatalogTagRef(id: $0, name: $0) }
                guard !tags.isEmpty else { return nil }
                return CatalogTagGroup(id: "ne-\(index)", kind: .netease, name: name, tags: tags)
            }
            return groups.isEmpty ? nil : groups
        } ?? []
    }

    private struct RecommendedRadioPack: Sendable {
        let title: String?
        let radios: [Playlist]
    }

    private func cachedRecommendedRadios() async -> RecommendedRadioPack {
        await catalogCache.value(for: "ne:/api/djradio/recommend/v1") {
            let res = await self.recommendedRadios()
            guard !res.radios.isEmpty else { return nil }
            return RecommendedRadioPack(title: res.title, radios: res.radios)
        } ?? RecommendedRadioPack(title: nil, radios: [])
    }

    private func cachedPersonalizedRadios() async -> [Playlist] {
        let uidKey = credential?.uid ?? 0
        return await catalogCache.value(for: "ne:/api/djradio/personalize/rcmd:\(uidKey)") {
            let list = await self.personalizedRadios(limit: 6)
            return list.isEmpty ? nil : list
        } ?? []
    }

    private func cachedProgramToplistHourly(limit: Int) async -> [Track] {
        await catalogCache.value(for: "ne:/api/djprogram/toplist/hours?limit=\(limit)") {
            var tracks = await self.djProgramToplistHourly(limit: limit)
            if tracks.isEmpty {
                tracks = await self.djProgramToplist(limit: limit, offset: 0)
            }
            return tracks.isEmpty ? nil : tracks
        } ?? []
    }

    private func cachedRadioToplist(hot: Bool, limit: Int) async -> [Playlist] {
        await catalogCache.value(for: "ne:/api/djradio/toplist?hot=\(hot)&limit=\(limit)") {
            let list = await self.djRadioToplist(hot: hot, limit: limit, offset: 0)
            return list.isEmpty ? nil : list
        } ?? []
    }

    private func cachedDJCategoryRecommendations() async -> [NeteaseDJCategoryRadios] {
        await catalogCache.value(for: "ne:/api/djradio/home/category/recommend") {
            let groups = await self.djCategoryRecommendations()
            return groups.isEmpty ? nil : groups
        } ?? []
    }

    private func taggedPlaylists(_ tag: String, limit: Int) async -> [Playlist] {
        await catalogCache.value(for: "ne:/api/playlist/list?cat=\(tag)&limit=\(limit)") {
            guard let resp = try? await self.get("/api/playlist/list", params: [
                "cat": tag, "order": "hot", "limit": "\(limit)", "offset": "0",
            ]), let playlists = resp["playlists"] as? [[String: Any]] else { return nil }
            return playlists.compactMap { Self.parsePlaylist($0) }
        } ?? []
    }

    /// 精品歌单：网易云编辑从全站歌单里人工过审入库的池子
    /// （`/api/playlist/highquality/list`，匿名可读，2026-09-06 实测 total 400+）。
    /// 新发现顶部 hero 与「精品歌单」共用这一条流，靠 offset 分段不重不漏。
    private func highqualityPlaylists(offset: Int, limit: Int) async -> [Playlist] {
        await catalogCache.value(for: "ne:/api/playlist/highquality/list?limit=\(limit)&offset=\(offset)") {
            guard let resp = try? await self.get("/api/playlist/highquality/list", params: [
                "cat": "全部", "limit": "\(limit)", "offset": "\(offset)",
            ]), let playlists = resp["playlists"] as? [[String: Any]] else { return nil }
            return playlists.compactMap { Self.parsePlaylist($0) }
        } ?? []
    }

    private func personalized(_ path: String, limit: Int) async -> [Playlist] {
        await catalogCache.value(for: "ne:\(path)?limit=\(limit)") {
            guard let resp = try? await self.get(path, params: ["limit": "\(limit)"]),
                  let result = resp["result"] as? [[String: Any]] else { return nil }
            return result.compactMap { Self.parsePlaylist($0) }
        } ?? []
    }

    private func hotDJRadios(limit: Int) async -> [Playlist] {
        await catalogCache.value(for: "ne:/api/djradio/hot/v1?limit=\(limit)") {
            guard let resp = try? await self.get("/api/djradio/hot/v1", params: ["limit": "\(limit)"]),
                  let radios = resp["djRadios"] as? [[String: Any]] else { return nil }
            return radios.compactMap { Self.parseDJRadio($0) }
        } ?? []
    }

    /// 新碟。`area` = ALL / ZH 华语 / EA 欧美 / KR 韩国 / JP 日本。
    private func newAlbums(limit: Int, offset: Int, area: String = "ALL") async -> [Album] {
        await catalogCache.value(
            for: "ne:/api/album/new?area=\(area)&limit=\(limit)&offset=\(offset)"
        ) {
            guard let resp = try? await self.get("/api/album/new", params: [
                "area": area, "limit": "\(limit)", "offset": "\(offset)",
            ]), let albums = resp["albums"] as? [[String: Any]] else { return nil }
            return albums.compactMap { Self.parseAlbum($0) }
                .sorted { ($0.publishDate ?? "") > ($1.publishDate ?? "") }
        } ?? []
    }

    static func parseDJRadio(_ r: [String: Any]) -> Playlist? {
        guard let id = r["id"] as? Int else { return nil }
        return Playlist(
            id: "ne:djradio:\(id)",
            kind: .netease,
            name: r["name"] as? String ?? "电台",
            coverURL: Self.artworkURL(r["picUrl"] as? String ?? ""),
            description: r["rcmdtext"] as? String ?? r["desc"] as? String,
            playCount: r["playCount"] as? Int ?? 0,
            trackCount: r["programCount"] as? Int ?? 0,
            creatorName: r["category"] as? String
                ?? ((r["dj"] as? [String: Any])?["nickname"] as? String))
    }

    /// 电台节目单集：本身就是一条可播曲目（mainSong），标题用节目名、副标题用台名。
    static func parseDJProgram(_ p: [String: Any]) -> Track? {
        let program = (p["program"] as? [String: Any]) ?? p
        guard let song = program["mainSong"] as? [String: Any],
              let id = song["id"] as? Int else { return nil }
        let radio = program["radio"] as? [String: Any]
        let cover = program["coverUrl"] as? String ?? p["picUrl"] as? String ?? ""
        return Track(
            id: "ne:\(id)",
            kind: .netease,
            title: program["name"] as? String ?? song["name"] as? String ?? "节目",
            artistName: radio?["name"] as? String ?? "电台",
            artistId: nil,
            albumName: radio?["name"] as? String ?? "",
            albumId: (radio?["id"] as? Int).map { "ne:djradio:\($0)" },
            artworkURL: Self.artworkURL(cover),
            duration: TimeInterval(program["duration"] as? Int ?? song["duration"] as? Int ?? 0) / 1000)
    }

    // MARK: - 详情

    func playlistDetail(_ playlist: Playlist) async throws -> PlaylistDetail {
        if playlist.id.hasPrefix("ne:djradio:") {
            return try await djRadioDetail(playlist)
        }
        guard let rawID = Int(playlist.id.rawID) else { throw ProviderError.invalidResponse }
        // v6 是唯一给**全量** trackIds 的一条：老的 `/api/playlist/detail` 与 v6 的 `tracks`
        // 一样只回前若干首（服务端自己截断），几百首的歌单点进去只有开头一截。
        let resp = try await eapi("/api/v6/playlist/detail",
                                  [("id", .int(rawID)), ("n", 100000), ("s", 8)])
        guard let result = resp["playlist"] as? [String: Any] else { throw ProviderError.invalidResponse }
        let ids = (result["trackIds"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int }
        var tracks = (result["tracks"] as? [[String: Any]] ?? []).compactMap { Self.parseTrack($0) }
        if ids.count > tracks.count {
            tracks = await songDetails(ids: ids)
        }
        let p = Playlist(
            id: playlist.id,
            kind: .netease,
            name: result["name"] as? String ?? playlist.name,
            coverURL: Self.artworkURL(result["coverImgUrl"] as? String ?? "") ?? playlist.coverURL ?? tracks.first?.artworkURL,
            description: result["description"] as? String,
            playCount: result["playCount"] as? Int ?? 0,
            trackCount: result["trackCount"] as? Int ?? tracks.count,
            creatorName: (result["creator"] as? [String: Any])?["nickname"] as? String)
        return PlaylistDetail(playlist: p, tracks: tracks)
    }

    /// 按 id 批量取曲目详情，**顺序照给进来的 id**（歌单曲序就是它，不能按返回顺序）。
    /// 服务端单批上限 1000，超了整批不回。
    private func songDetails(ids: [Int]) async -> [Track] {
        var byID: [Int: Track] = [:]
        for batch in stride(from: 0, to: ids.count, by: 1000).map({ Array(ids[$0..<min($0 + 1000, ids.count)]) }) {
            let c = "[" + batch.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
            guard let data = try? await eapi("/api/v3/song/detail", [("c", .string(c))]),
                  let songs = data["songs"] as? [[String: Any]] else { continue }
            for song in songs {
                guard let id = song["id"] as? Int, let track = Self.parseTrack(song) else { continue }
                byID[id] = track
            }
        }
        return ids.compactMap { byID[$0] }
    }

    /// 电台详情：节目单集列表。每条节目的 mainSong 就是可播曲目，直接当歌单曲目用，
    /// 「广播」页的台点开即播，不再需要单独的电台详情页。
    ///
    /// 两处都改过（2026-09-09），起因是原实现**会静默截断**：
    ///
    /// 1. 节目单原先写死 `limit=50` 且不翻页——131 期的电台点进去只有 50 期，
    ///    剩下的连个「加载更多」都没有。现在走 `djPrograms(radioID:limit:all:)`
    ///    翻到底（100/页，`more` 为假就停）。
    /// 2. 电台信息原先是从**节目列表第一条**里那个 `radio` 子对象反推的，
    ///    一期节目都没有的新电台于是名字、封面、简介全空。现在先问电台自己的详情
    ///    （`djRadioDetail(radioID:)` → `/api/djradio/v2/get`），它才是权威；
    ///    拿不到再退回原来那条反推的路。
    private func djRadioDetail(_ playlist: Playlist) async throws -> PlaylistDetail {
        let radioID = String(playlist.id.dropFirst("ne:djradio:".count))
        async let detailTask = djRadioDetail(radioID: radioID)
        async let programsTask = djPrograms(radioID: radioID, limit: 100, all: true)
        let (detail, tracks) = await (detailTask, programsTask)
        let p = Playlist(
            id: playlist.id,
            kind: .netease,
            name: detail?.name ?? playlist.name,
            coverURL: detail?.coverURL ?? playlist.coverURL,
            description: detail?.description ?? playlist.description,
            playCount: playlist.playCount,
            trackCount: max(detail?.trackCount ?? 0, tracks.count),
            creatorName: detail?.creatorName ?? playlist.creatorName)
        return PlaylistDetail(playlist: p, tracks: tracks)
    }

    /// 专辑详情走 interface.music.163.com（主站的 /api/album 系列已下线或需登录）。
    func albumDetail(_ album: Album) async throws -> AlbumDetail {
        let rawID = album.id.rawID
        let resp = try await getInterface("/api/v1/album/\(rawID)")
        guard let albumInfo = resp["album"] as? [String: Any],
              let songs = resp["songs"] as? [[String: Any]] else {
            throw ProviderError.invalidResponse
        }
        let tracks = songs.compactMap { Self.parseTrack($0) }.sortedByAlbumOrder()
        let artist = albumInfo["artist"] as? [String: Any]
        let finalAlbum = Album(
            id: album.id,
            kind: .netease,
            name: albumInfo["name"] as? String ?? album.name,
            artistName: artist?["name"] as? String ?? album.artistName,
            artistId: (artist?["id"] as? Int).map { "ne:\($0)" } ?? album.artistId,
            artworkURL: Self.artworkURL(albumInfo["picUrl"] as? String ?? "") ?? album.artworkURL,
            publishDate: Self.formatDate(ms: albumInfo["publishTime"] as? Int ?? 0) ?? album.publishDate,
            trackCount: tracks.count,
            description: (albumInfo["description"] as? String)?.isEmpty == false ? albumInfo["description"] as? String : nil,
            // 网易云专辑接口不给曲风，只有 tags 偶尔带一个；为空就整段省略，
            // 不拿「专辑」这种没有信息量的词占位。
            genre: (albumInfo["tags"] as? String)?.isEmpty == false ? albumInfo["tags"] as? String : nil)
        return AlbumDetail(album: finalAlbum, tracks: tracks)
    }

    func artistDetail(_ artist: Artist) async throws -> ArtistDetail {
        let rawID = artist.id.rawID
        async let detailResp = get("/api/artist/\(rawID)")
        // 专辑原先只要 30 张且不翻页，周杰伦这种一百多张的歌手「全部专辑」会缺一大半。
        // 改成一页 100 张：仍然只是**一条**请求（没有多打来回），却足够覆盖绝大多数歌手。
        // 真要一张不落地翻到底，用 `artistAlbums(_:all:true)`。
        async let albumsTask = artistAlbums(artist.id, limit: 100)
        let detail = try await detailResp
        let albums = await albumsTask

        let info = detail["artist"] as? [String: Any]
        let hotTracks = (detail["hotSongs"] as? [[String: Any]] ?? []).compactMap { Self.parseTrack($0) }
        let a = Artist(
            id: artist.id,
            kind: .netease,
            name: info?["name"] as? String ?? artist.name,
            avatarURL: Self.artworkURL(info?["picUrl"] as? String ?? "") ?? artist.avatarURL,
            description: (info?["briefDesc"] as? String)?.isEmpty == false ? info?["briefDesc"] as? String : nil)
        return ArtistDetail(artist: a, hotTracks: hotTracks, albums: albums)
    }

    // MARK: - 播放与歌词

    /// 取流。
    ///
    /// 与 QQ 那边不同，**问一次就够**：网易云自己会降级（要 `hires` 回 `exhigh` 是正常的），
    /// 不需要像 vkey 那样把整个阶梯问一遍再挑。
    /// 音质封顶靠的是身份而不是参数——匿名 token 能到 320k，无损以上要会员。[实测 2026-09-06]
    func trackStreamURL(track: Track, quality: StreamQuality?) async throws -> URL {
        let songID = track.id.rawID
        // 显式档位（下载）优先；没传就用全局的流播放档。
        let level = Self.neteaseLevel(for: quality ?? self.quality)
        let resp = try await eapi("/api/song/enhance/player/url/v1", [
            ("ids", .string("[\(songID)]")), ("level", .string(level)), ("encodeType", "flac"),
        ])
        guard let data = resp["data"] as? [[String: Any]], let first = data.first else {
            throw ProviderError.invalidResponse
        }
        if let urlString = first["url"] as? String,
           !urlString.isEmpty, urlString != "null",
           let url = URL(string: urlString.httpsUpgraded) {
            return url
        }
        // url 为空只说明「这个身份取不到」，服务端不区分「没会员」和「登录早就掉了」，
        // 措辞上得先把这两件事分开，别把过期的 cookie 说成会员等级不够。
        if credential == nil {
            throw ProviderError.unavailable("付费或 VIP 曲目，匿名状态无法播放")
        }
        await validateCredential()
        if credential == nil {
            throw ProviderError.unavailable("网易云音乐登录已过期，请重新登录后再播放")
        }
        throw ProviderError.unavailable("该曲目为付费/VIP 内容，当前账号无权播放")
    }

    /// Amber 的音质档位（13 档，按 QQ 的档位表定的）映射到网易云的 8 档 `level`。
    ///
    /// 规则是**不越级**：挑「不高于所选档位」的最高一档网易档。
    /// 所以 640k 有损落到 `exhigh`（320k）而不是往上凑 `lossless`——用户选有损档是给
    /// 带宽和体积定了个上限，给他一个更大的文件不算「满足偏好」。
    /// 反过来 96k / 48k 这些比网易云最低档还低的，只能给 `standard`（128k），到底了。
    static func neteaseLevel(for quality: StreamQuality) -> String {
        switch quality {
        case .atmos, .surround: return "sky"      // 沉浸环绕声
        case .master: return "jymaster"           // 超清母带
        case .premium: return "jyeffect"          // 高清臻音
        case .lossless: return "lossless"
        case .ogg640, .high: return "exhigh"      // 320k
        case .aac192, .ogg192: return "higher"    // 192k
        case .standard, .aac96, .ogg96, .aac48: return "standard"
        }
    }

    /// 歌词，逐字优先。
    ///
    /// `v1` 是唯一给逐字（`yrc`）的一条，明文那条老接口只有行级 `lrc`。
    /// 请求里那一串 `tv/lv/rv/kv/yv/ytv/yrv` 全填 0 是客户端的原样：它们是「已有版本号」，
    /// 填 0 表示手上没有、把各语种全量发过来。
    ///
    /// 逐字与行级的翻译/音译是**两套**字段：`yrc` 配 `ytlrc`/`yromalrc`，`lrc` 配
    /// `tlyric`/`romalrc`，混着用会出现正文逐字、翻译却按行对不上的情况，所以成对取。
    /// `LyricParser` 两种格式都认，下游不用关心拿到的是哪一种。
    func lyrics(track: Track) async throws -> [LyricLine] {
        let songID = track.id.rawID
        guard let id = Int(songID) else { return [] }
        let resp = try await eapi("/api/song/lyric/v1", [
            ("id", .int(id)), ("cp", false), ("tv", 0), ("lv", 0), ("rv", 0),
            ("kv", 0), ("yv", 0), ("ytv", 0), ("yrv", 0),
        ])
        // **`pureMusic = true` 就是「这首是纯音乐」这个类别位。** 与 QQ 的 `lyric_style` 同理：
        // 这种歌的 `lrc` 不是空的，而是一句占位词「纯音乐，请欣赏」（或只挂一行「作曲 : …」），
        // 照原样显示就是拿一句话占满整块歌词面板，这里直接归成「没有词」。
        //
        // [实测 2026-09-17 eapi 匿名] 三首纯音乐（`478507889` / `34532273` / `29414800`）
        // 都带`pureMusic: true`，真歌词的 `347230` 连这个键都没有。
        // 与它同一块的 `sgc`/`sfy`/`qfy` 说的是别的事（见 `NeteaseAPI+SongInfo`），别混。
        if resp["pureMusic"] as? Bool == true { return [] }
        func lyric(_ key: String) -> String? {
            let text = (resp[key] as? [String: Any])?["lyric"] as? String
            return (text?.isEmpty == false) ? text : nil
        }
        if let yrc = lyric("yrc") {
            return LyricParser.parse(yrc, translation: lyric("ytlrc") ?? lyric("tlyric"),
                                     transliteration: lyric("yromalrc") ?? lyric("romalrc"),
                                     title: track.title)
        }
        guard let lrc = lyric("lrc") else { return [] }
        return LyricParser.parse(lrc, translation: lyric("tlyric"),
                                 transliteration: lyric("romalrc"), title: track.title)
    }

    // MARK: - MV 取流

    /// MV 地址。[实测 2026-09-07 curl + eapi]
    ///
    /// 路径是 `/api/song/enhance/play/mv/url`，**不是** `/api/mv/url`——后者两条路都回
    /// `404 接口未找到`（明文 GET 与 eapi 一样）。参数只有 `{id, r}`，`r` 收 240/480/720/1080。
    /// 响应 `data = {id, url, r, size, fee, code}`，`url` 是 **http** 的 `vod.126.net`
    /// 直链（要升 https，升完照样 200、`content-type: video/mp4`、Range 回 206），带
    /// `wsSecret`/`wsTime` 签名，匿名 token 就能取，不用登录。
    ///
    /// **跟它的音频取流一样是服务端自己降级**：问一个没有的档位不会失败，直接回最高的那一档
    ///（Beyond《海阔天空》只有 240/480，问 1080 回 480；问 4000 也回 1080 封顶），
    /// 所以问一次就够，不用像 QQ 那样把整个阶梯要回来自己挑；回来的 `r` 才是真实档位。
    func mvStreamURL(mv: MV, maxHeight: Int?) async throws -> URL {
        let id = mv.id.rawID
        guard !id.isEmpty else { throw ProviderError.invalidResponse }
        // 不封顶时要一个高过一切的数，服务端会降到这支 MV 的最高档。
        let resp = try await eapi("/api/song/enhance/play/mv/url", [
            ("id", .string(id)), ("r", .int(maxHeight ?? 4000)),
        ])
        guard let variant = Self.parseMVVariant(resp) else {
            if credential == nil {
                throw ProviderError.unavailable("这支 MV 匿名状态下取不到地址")
            }
            throw ProviderError.unavailable("这支 MV 当前账号无权观看")
        }
        return variant.url
    }

    /// `song/enhance/play/mv/url` 的响应 → 一档画质。纯函数，喂 fixture 就能单测。
    static func parseMVVariant(_ resp: [String: Any]) -> MVVariant? {
        guard let data = resp["data"] as? [String: Any],
              let raw = data["url"] as? String, !raw.isEmpty, raw != "null",
              let url = URL(string: raw.httpsUpgraded) else { return nil }
        return MVVariant(height: data["r"] as? Int ?? 0, url: url,
                         bytes: (data["size"] as? NSNumber)?.intValue ?? 0)
    }
}

/// 匿名 token 的「只取一次」闸门。
///
/// 首页十来个格子并发起来，第一批 eapi 请求会同时发现「还没有匿名 token」——
/// 没有这道闸门就会并发注册十来次，注册接口按 IP 限流，结果是一个都拿不到。
private actor AnonymousTokenGate {
    private var attempted = false
    private var task: Task<Void, Never>?

    /// 成功与否都只试这一轮：失败了按没有匿名 token 继续跑（目录/搜索/128k 取流照常），
    /// 不让后面每条请求都去撞一次限流。
    func acquire(_ load: @Sendable @escaping () async -> Void) async {
        if attempted { return }
        if let task { return await task.value }
        let task = Task { await load() }
        self.task = task
        await task.value
        self.task = nil
        attempted = true
    }
}
