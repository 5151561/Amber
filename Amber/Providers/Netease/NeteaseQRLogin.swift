import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 网易云扫码登录。
///
/// 流程与 QQ 那边同形（取码 → 轮询 → 换凭证），只有一处结构性差异：
/// **二维码的图要自己画**。QQ 是服务端直接回一张 PNG，网易云只给一个 `unikey`，
/// 图是客户端拿 `https://music.163.com/login?codekey=<unikey>` 现生成的。
///
/// ## 为什么走 weapi 而不是 eapi
///
/// 两条通道都有这两个接口（`login/qrcode/unikey` 与 `login/qrcode/client/login`），
/// 参数只差一个 `type`：weapi 传 1，eapi 传 3。这一版改走 weapi，理由是参考实现
/// [chaunsin/netease-cloud-music] 的四条登录路里，**能用的那两条都不带客户端设备身份**——
/// 扫码走 weapi（`api/weapi/login.go`），Cookie 导入压根不打登录接口；而它那条走 eapi 的
/// 手机号登录在 README 里被划掉，写着「存在风控问题」。
///
/// 与 Amber 自己的账对得上：eapi 那条路上我们自称 iPhone 客户端，deviceId 是现造的随机串、
/// 在网易那儿没有任何注册历史，登录一撞就是风控（`NeteaseWeapi.swift` 里记着那笔账）。
/// 网页身份没有「这台设备有没有历史」这种预期。
///
/// **验过的与没验的：**[主会话用 scratchpad 里的 Swift 探针实测 2026-09-09]
/// 拿本文件这套请求（`weapiParams` + 热身 `NMTID` + `csrf_token` 空串）打真接口：
/// `unikey` 回 `{"code":200,"unikey":"3448b482-…"}`，随即轮询回 `{"code":801,"message":"等待扫码"}`
/// ——**通道与两条接口都是通的**。没验的是 803 那一步：它要一台真手机扫真码，
/// 拿不到就走不到，所以「803 的 `Set-Cookie` 里有 `MUSIC_U`」这一条目前只有参考实现的
/// 行为作依据（`internal/ncmctl/login_qrcode.go` 扫完直接就能打 `account/get`）。
///
/// **换来的 `MUSIC_U` 照样能打 eapi。** 这不是推断：参考实现的主力登录方式就是把浏览器里
/// 导出的 cookie（纯网页身份）塞进去，然后全部接口照跑——Amber 的 Cookie 导入登录
/// （`NeteaseCookieImport`）依据的也是同一件事。
extension NeteaseAPI {

    struct QRLoginImage: Sendable {
        let imageData: Data
        let unikey: String
    }

    /// 轮询状态。网易云没有「用户在手机上拒绝」这一态（拒绝就一直停在 802），
    /// 所以这里比 QQ 少一个 `refused`。
    enum QRLoginStatus: Sendable {
        case waitingScan          // 801
        case scanned              // 802，已扫码待确认
        case expired              // 800，二维码过期
        case done(cookie: String) // 803，Set-Cookie 里带 MUSIC_U
    }

    /// 第一步：取 unikey 并把二维码画出来
    func fetchQRLoginImage() async throws -> QRLoginImage {
        let data = try await weapi("/api/login/qrcode/unikey", [("type", 1)])
        guard let unikey = data["unikey"] as? String, !unikey.isEmpty else {
            throw ProviderError.api("获取二维码失败")
        }
        guard let image = Self.qrCodePNG(for: Self.qrContent(unikey: unikey)) else {
            throw ProviderError.api("二维码生成失败")
        }
        return QRLoginImage(imageData: image, unikey: unikey)
    }

    /// 二维码里那条 URL。
    ///
    /// **不带 `chainId`。** 参考实现在 `platform == "web"` 时会往后面拼一段
    /// `&chainId=v1_<deviceId>_web_login_<毫秒>`（`api/weapi/login.go`），那是网页版给登录链路
    /// 做埋点用的，扫码本身不需要它；而它要一个网页侧的 deviceId，这条路上我们没有、
    /// 造一个又多一份要长期存的身份。代价不对等：这段字符串是**手机 App 去解析**的，
    /// 拼错的后果是扫不出来，而扫码眼下是仅剩的两条登录路之一。
    static func qrContent(unikey: String) -> String {
        "https://music.163.com/login?codekey=\(unikey)"
    }

    /// 第二步：轮询扫码状态。
    /// 走裸请求是因为凭证只在响应头里：803 的 body 不含 MUSIC_U，只有 `Set-Cookie` 有。
    func pollQRLogin(unikey: String) async throws -> QRLoginStatus {
        let (body, response) = try await weapiRaw("/api/login/qrcode/client/login",
                                                  [("key", .string(unikey)), ("type", 1)])
        switch body["code"] as? Int ?? 0 {
        case 801: return .waitingScan
        case 802: return .scanned
        case 800: return .expired
        case 803:
            let cookies = Self.setCookies(in: response, url: response.url!)
            guard let musicU = cookies["MUSIC_U"] else { throw ProviderError.api("登录成功但未拿到凭证") }
            // 只留登录真正用得上的两项：MUSIC_U 是身份，__csrf 每条 eapi 请求都要回传
            var cookie = "MUSIC_U=\(musicU)"
            if let csrf = cookies["__csrf"] { cookie += "; __csrf=\(csrf)" }
            return .done(cookie: cookie)
        case let code:
            // 风控把扫码也拦下来时（参考实现记的是 8821），服务端可能给一张验证页。
            // 给了就把那条路交到用户手上，别压成一句 "登录失败 code=8821"。
            if let challenge = NeteaseLoginChallenge(body: body) { throw challenge }
            throw ProviderError.api("扫码登录失败 code=\(code)")
        }
    }

    /// 第三步：拿刚到手的 cookie 打一次 `account/get`，把 uid 与昵称一起收进凭证。
    ///
    /// uid 不是可有可无的装饰：账号歌单接口只认 uid，登录时顺手拿到就不用每次再补一条请求。
    /// 这里必须用 `cookieOverride`——此刻凭证还没落进 `credentialProvider`。
    ///
    /// **两条登录路的最后一步都是它**：扫码换来的 cookie 和用户从浏览器导进来的 cookie，
    /// 到这一层没有任何区别，都是「一串 MUSIC_U，问问服务端它是谁」。
    /// 顺带这一条也是 Cookie 导入唯一的有效性校验——粘进来的串真假只有服务端说了算。
    func credentialFromCookie(_ cookie: String) async throws -> NeteaseCredential {
        let profile = try await accountProfile(cookieOverride: cookie)
        // 无效/过期的 MUSIC_U 不会挨 301，服务端照回 `code:200` 只是把 `profile` 留空
        // （[实测 2026-09-09 curl(eapi 探针)]：伪造一份同形状的 MUSIC_U 打 `account/get`
        // → `{"code":200,"account":…,"profile":null}`）。所以判据是 profile 而不是 code，
        // 那句话也照这个说——「校验失败」听不出发生了什么。
        guard let uid = profile.uid else {
            throw ProviderError.api("没换到账号信息，这份登录态多半已经失效了")
        }
        return NeteaseCredential(cookie: cookie, uid: uid, nickname: profile.nickname)
    }

    /// 二维码 PNG。
    ///
    /// 纠错级别取 `M`：内容就是一条几十字节的短 URL，M 足够，再高只会把码画得更密。
    /// `CIQRCodeGenerator` 出的图一个模块只有 1 像素，直接给 NSImage 会被插值糊成一团，
    /// 所以先整数倍放大（`CIImage.transformed` 用最近邻，不会引入灰边）再编码。
    static func qrCodePNG(for text: String, scale: CGFloat = 10) -> Data? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: scale, y: scale)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
