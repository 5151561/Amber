import Foundation

// MARK: - weapi 通道

/// 网易云的**第三条**请求通道：weapi（网页身份）。
///
/// 三条通道并存，各有各不可替代的地方，不为统一而统一：
///
/// - **明文 `/api/*` GET**：目录、搜索、专辑/艺人详情。这些接口匿名照样给全量数据。
/// - **eapi**（`interface.music.163.com/eapi/*`）：取流、歌词、账号歌单、歌单全量曲目。
///   它自称是 iPhone 客户端，`level`（取流档位）与 `yrc`（逐字歌词）是客户端专有字段，
///   网页身份**要不到**——所以 weapi 不是来取代 eapi 的。
/// - **weapi**（这里）：网页版自己那条路。**登录走它**（扫码，见 `NeteaseQRLogin.swift`）。
///
/// ## 为什么登录单走这条
///
/// eapi 那条路上我们自称 iPhone 客户端，而 deviceId 是每次现造的随机串、在网易那儿没有任何
/// 注册历史。这副身份在登录这一步就是风控的靶子，有一整笔实测账
/// [实测 2026-09-09 curl(eapi 探针)]：同一副身份上**只要之前打过任何一条 eapi 请求**，
/// 登录就一律回 `-462`（易盾滑块）——
///
/// - 全新身份、第一条就是登录 → `503 验证码错误`（正常业务响应，风控没插手）
/// - 同一身份再打第二次 → `-462`
/// - 全新身份，先打一条 `simiSong`（code 200）或 `captcha/sent`，再登录 → `-462`
/// - 每条请求各用一副全新身份 → 回的都是正常业务错误，连试三轮全稳
///
/// 而 Amber 的常态恰恰是最糟的那种：一个实例固定一个 deviceId、开机就注册匿名 token、
/// 目录页一直在打请求。当时的对策是给登录那几条各发一副一次性身份，后来用户实机仍在
/// 「填完验证码点登录」这一步被判风险环境（8810 / 10004），才把登录整条挪到 weapi：
/// **网页登录没有「这台设备有没有历史」这种预期**，参考实现
/// [chaunsin/netease-cloud-music] 能用的两条登录路（扫码、Cookie 导入）同样一条都不带
/// 客户端设备身份，而它那条走 eapi 的手机号登录在 README 里被划掉，注着「存在风控问题」。
///
/// 手机号登录（短信 / 密码）现已删除，那套一次性身份的开关也跟着删了。
///
/// ## 这条通道验到哪一步
///
/// - 通道本身：[主会话用 `scratchpad/weapi.py` 实测 2026-09-09]
///   `POST /weapi/w/login/cellphone` 拿错的验证码打 → `{"code":503,"message":"验证码错误"}`，
///   与 eapi 那条一模一样；`/weapi/cellphone/existence/check` 也通。
/// - 这份 **Swift 实现自己的输出**：[实测 2026-09-09] 把本文件拼请求体的那几行
///   （`weapiParams` + `csrf_token` + 下面那个百分号编码）编成独立小程序跑出 body，
///   原样 curl 打同一条接口，回的与 Python 探针逐字一致——所以
///   `SecKeyCreateEncryptedData(.rsaEncryptionRaw)` 算出来的 `encSecKey` 是服务端认的。
/// - 扫码那两条接口：[主会话用 scratchpad 里的 Swift 探针实测 2026-09-09]
///   `login/qrcode/unikey` 回 `{"code":200,"unikey":…}`，随即轮询回
///   `{"code":801,"message":"等待扫码"}`。803 那一步要真手机扫真码，没验过（也验不了）。
///
/// 请求形状照 [api-enhanced] `util/request.js` 的 `case 'weapi'`。
extension NeteaseAPI {

    /// weapi 专用会话：与 eapi 那条同样是 **ephemeral + 关掉系统 cookie 存储**。
    ///
    /// 理由和 eapi 一样：这条路上的 cookie 是我们自己按 header 拼出来发的，
    /// 让 URLSession 再插一手，登录态与匿名态的 cookie 会互相污染——登录这条尤其不能被污染，
    /// 它必须是「一副干净身份去换一份新凭证」。
    ///
    /// 写成 `static` 而不是实例属性：extension 里加不了存储属性，而这条会话本身**不带状态**
    /// （不存 cookie、不存身份），多个实例共用它与各自持有一份没有任何差别。
    /// 热身那条 GET（`warmWebSession`）也走它——正因为它不自己存 cookie，
    /// 服务端下发的那份才会原样落到响应头上等我们自己收。
    private static let weapiSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    /// 网页版的 UA / Referer / Cookie。三者要自洽：weapi 认的是「一个浏览器在 music.163.com
    /// 上发的请求」，缺 Referer 会被当成跨站调用直接挡掉。
    /// `os=pc; appver=8.9.70` 是网页版自己带的那两项，照 `util/request.js`。
    private static let weapiBase = "https://music.163.com"
    private static let weapiUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    private static let weapiCookie = "os=pc; appver=8.9.70"

    /// form 字段的百分号编码集：只放行 RFC 3986 的 unreserved 字符。
    ///
    /// `params` 是 base64，里头的 `+` `/` `=` 三个字符在 form body 里全是有含义的
    /// （`+` 会被服务端解成空格），不编码就等于把密文改了。
    private static let weapiFormAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// 打一条 weapi 接口，只要响应体。
    ///
    /// `path` 与 eapi 那边保持同一个写法：传完整的 `/api/xxx`，真正请求的地址是把开头的
    /// `/api/` 换成 `/weapi/`。这样同一条接口在两条通道之间挪的时候，调用点只改函数名。
    ///
    /// 不看 `code`：weapi 目前只服务登录那条路，而登录的 `code` 有一整套自己的分支
    /// （扫码的 800/801/802/803、风控挑战…），在这一层统一按「非 200 即错误」压成一句话
    /// 会把那些分支全抹掉——801「等待扫码」本来就不是错误。
    @discardableResult
    func weapi(_ path: String, _ body: [(String, NeteaseJSON)] = []) async throws -> [String: Any] {
        try await weapiRaw(path, body).body
    }

    /// weapi 的裸请求：连响应一起交出去。
    ///
    /// 扫码必须走这一层——`MUSIC_U` 只在响应头的 `Set-Cookie` 里，body 里一个字都没有。
    func weapiRaw(_ path: String,
                  _ body: [(String, NeteaseJSON)] = []) async throws
                  -> (body: [String: Any], response: HTTPURLResponse) {
        // `csrf_token` 是 weapi 请求体里必须有的一个键（`util/request.js` 无条件塞）。
        // 我们这条路上没有会话、拿不到真的 `__csrf`，给空串即可：
        // [主会话用 `scratchpad/weapi.py` 实测 2026-09-09] 空串照样 200，服务端不校验它的值。
        // 调用方自己带了就用调用方那份，不覆盖。
        var fields = body
        if !fields.contains(where: { $0.0 == "csrf_token" }) {
            fields.append(("csrf_token", .string("")))
        }
        let (params, encSecKey) = NeteaseCrypto.weapiParams(json: NeteaseJSON.serialize(fields))

        await warmWebSession()

        var request = URLRequest(url: URL(string: Self.weapiBase + "/weapi/" + path.dropFirst("/api/".count))!)
        request.httpMethod = "POST"
        request.httpBody = Data("params=\(Self.formEncoded(params))&encSecKey=\(Self.formEncoded(encSecKey))".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.weapiUA, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.weapiBase, forHTTPHeaderField: "Referer")
        request.setValue(webCookieHeader(), forHTTPHeaderField: "Cookie")

        let (data, response) = try await Self.weapiSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderError.api("请求失败")
        }
        // weapi 的响应一律是明文 JSON——没有 eapi 那条 `e_r` 的密文分支，不用去猜。
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidResponse
        }
        return (dict, http)
    }

    // MARK: - 网页会话

    /// 登录之前先把网页会话「热」一下：拿一份服务端下发的 `NMTID` 再去打 weapi。
    ///
    /// 真浏览器走到登录页时，手上早就有一份网站给的会话 cookie；而我们干打一条 weapi，
    /// 在风控眼里同样是「一个没有任何历史的环境」——而登录被拒的原话正是
    /// 「风险环境」「设备环境异常」（[用户实机 2026-09-09]，那时走的还是 eapi）。
    /// 多带这一份不保证能过，但方向对：让这条请求更像一个真的浏览器。
    ///
    /// **热身地址是 `/discover` 不是首页。** [实测 2026-09-09 curl] `https://music.163.com/`
    /// 回 200 却**一个 Set-Cookie 都不给**（用 CookieJar 收，收到的是空表）；
    /// `https://music.163.com/discover` 才下发
    /// `NMTID=…; Max-Age=315360000; Path=/; Domain=music.163.com`。
    /// 换句话说，照直觉去 GET 首页是白跑一趟。
    ///
    /// `__csrf` 这一层**匿名阶段拿不到**：它是登录之后才有的东西，所以请求体里的
    /// `csrf_token` 仍旧是空串（参考实现在未登录时发的也是空串）。
    ///
    /// **热身失败一律不影响登录**：断网、非 200、没给 cookie，都照旧用手上这份发出去。
    /// 它是「让请求更像浏览器」的加分项，不是登录的前置条件，为它多一个失败点不划算。
    /// [实测 2026-09-09] 带上 `NMTID` 之后拿错的验证码打登录，回的仍是
    /// `{"code":503,"message":"验证码错误"}`——多带这份会话不会把原本能用的请求打坏。
    private func warmWebSession() async {
        // 已经热过就不再热。整个进程里这份 cookie 只取一次：它的 Max-Age 是十年，
        // 而登录本来就是个低频动作，没必要每次都多一条往返。
        if webCookies.withLock({ !$0.isEmpty }) { return }
        var request = URLRequest(url: URL(string: Self.weapiBase + "/discover")!)
        request.setValue(Self.weapiUA, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await Self.weapiSession.data(for: request),
              let http = response as? HTTPURLResponse, let url = http.url else { return }
        let cookies = Self.setCookies(in: http, url: url)
            .filter { ["NMTID", "__csrf"].contains($0.key) }
        guard !cookies.isEmpty else { return }
        webCookies.withLock { store in
            for (name, value) in cookies { store[name] = value }
        }
    }

    /// weapi 请求的 Cookie 头：网页版固定那两项 + 热身收到的会话 cookie。
    private func webCookieHeader() -> String {
        let session = webCookies.withLock { $0 }
        guard !session.isEmpty else { return Self.weapiCookie }
        return ([Self.weapiCookie] + session.map { "\($0.key)=\($0.value)" }).joined(separator: "; ")
    }

    /// 百分号编码。`addingPercentEncoding` 只在传进来的字符串不是合法 Unicode 时才返回 nil，
    /// 这里的输入是 base64 与十六进制，不可能触发；兜底返回原串而不是崩，
    /// 反正真到了那一步服务端会回一条正常的错误。
    private static func formEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: weapiFormAllowed) ?? value
    }
}
