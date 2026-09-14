import Foundation

// MARK: - 风控挑战

/// 登录被风控拦下、但服务端给了一条出路（一张验证页）时的那种响应。
///
/// 单独立一个类型而不是折成 `ProviderError.api("接口错误 code=-462")`，是因为它**不是错误信息，
/// 是一条待办**：那一页过完才能继续登录，把它压成一句文案等于把用户唯一的出路扔了。
///
/// **判据是「服务端有没有给一个验证页」，不是某个具体的码。** 码至少见过三个：
///
/// - `-462`：验证信息整套塞在`data` 里（`data.url` / `data.blockText` / `data.verifyToken`）。
///   [实测 2026-09-09 curl(eapi 探针)]
/// - `10004`「当前登录存在安全风险，请稍后再试」、`8810`「您当前的网络环境存在安全风险」：
///   验证页直接摆在顶层 `redirectUrl` 上，没有`data`。[用户实机 2026-09-09，日志实测]
///
/// 起初只认 -462，于是后两条被当成普通业务错误、只把 `message` 显示出来，
/// **服务端明明给了出路却被我们扔了**——用户看到的就是一句「安全风险」加一条死路。
/// 下一个码是什么谁也不知道，但只要它给了 URL，用户就有一条路可走。
///
/// **现在谁会撞上它。** 手机号登录那条路已经删了（见 `NeteaseWeapi.swift` 的说明），
/// 剩下扫码与 Cookie 导入两条：Cookie 导入压根不打登录接口，撞不上；扫码这条会——
/// 参考实现 [chaunsin/netease-cloud-music] 的 `docs/qinglong.md` 明写「网易云风控严重可能随时
/// 不支持扫码登录，会出现 8821 需要行为验证码验证」。真出现时，`init?` 认不认得出取决于
/// 那条响应里有没有 URL；没有就照旧走普通错误路径，不会把业务错误伪装成一颗打不开的按钮。
struct NeteaseLoginChallenge: Error, LocalizedError, Equatable, Sendable {

    /// `-462`：验证信息整套塞在`data` 里那一种。判据不看它（见`init?`），
    /// 留着是给调用方和测试指名道姓用的。
    static let code = -462

    /// 验证页。`-462` 那种在`data.url`（参数`sign` / `event_id` / `verifyToken` 服务端
    /// 已经拼进 query），另两种在顶层 `redirectUrl`。两者都原样丢给浏览器，不要自己重拼。
    let url: URL
    /// 服务端给的提示语：`-462` 用`data.blockText`（「验证成功后，可进行下一步操作哦~」，
    /// **原文末尾带一个制表符**，不 trim 会在行尾撑出一段莫名空白）；
    /// 另两种用顶层的 `message` / `toast`。
    let blockText: String
    /// 风控令牌，形如 `00.40.<32 位 hex>.<数字>`，只有`-462` 那种给。
    /// 这一版没有把它回传给任何接口——参考实现里 `secureCaptcha` 收的是滑块过关后的票据，
    /// 不是这个 token，而那张票据只有易盾页面自己拿得到。留字段是为了出问题时能对日志。
    let verifyToken: String

    /// 从一条登录响应里认这条挑战。认不出来就返回 nil，交回原来的错误路径。
    init?(body: [String: Any]) {
        let code = body["code"] as? Int ?? 200
        guard code != 200 else { return nil }

        // ① 顶层 redirectUrl（8810 / 10004 那两种）
        if let link = body["redirectUrl"] as? String, let url = URL(string: link) {
            self.url = url
            let message = (body["message"] as? String) ?? (body["toast"] as? String) ?? ""
            self.blockText = message.trimmingCharacters(in: .whitespacesAndNewlines)
            self.verifyToken = ""
            return
        }

        // ② data 里那一整套（-462）
        guard let data = body["data"] as? [String: Any],
              let link = data["url"] as? String,
              let url = URL(string: link) else { return nil }
        self.url = url
        self.blockText = (data["blockText"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.verifyToken = data["verifyToken"] as? String ?? ""
    }

    /// 没有 `blockText` 时给一句自己的兜底——不然界面上会是一片空白。
    var errorDescription: String? {
        blockText.isEmpty ? "需要先完成安全验证才能登录" : blockText
    }
}
