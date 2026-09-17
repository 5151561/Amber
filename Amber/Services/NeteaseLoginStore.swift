import Combine
import Foundation

// MARK: - 网易云音乐登录凭证

/// 网易云会话凭证。
///
/// `cookie` 里真正管用的只有 `MUSIC_U`（身份）与 `__csrf`（每条 eapi 请求都要原样回传），
/// 所以扫码成功时只留这两项，不把服务端那一大串 `MUSIC_R_T` / `MUSIC_SNS` 一起收着。
/// `uid` 是账号歌单接口的入参，登录时顺手拿到就不用每次再补一条 `account/get`。
struct NeteaseCredential: Equatable, Sendable {
    let cookie: String
    let uid: Int?
    let nickname: String?

    func value(of name: String) -> String? { Self.value(of: name, in: cookie) }

    /// 从 `k=v; k=v` 里取一项。值本身可能含 `=`（MUSIC_U 是一长串十六进制，倒是不含，
    /// 但 `__csrf` 之外的键没这个保证），所以只按首个 `=` 切。
    static func value(of name: String, in cookie: String) -> String? {
        for part in cookie.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(name)="), trimmed.count > name.count + 1 else { continue }
            return String(trimmed.dropFirst(name.count + 1))
        }
        return nil
    }
}

// MARK: - Cookie 导入状态

/// 浏览器 Cookie 导入的状态机。
///
/// 没有复用 `QRLoginState`：那边的「等待扫码 / 已扫码待确认 / 二维码过期」在这条路上
/// 一条都不存在。这边总共只有三态——粘一段进来、打一条 `account/get` 校验、成或不成。
enum NeteaseCookieLoginState: Equatable {
    case idle
    case validating           // 正在拿这份 cookie 打 account/get 校验
    case failed(String)

    /// 面板上那行说明文字。错误一律用原话（解析器的或服务端的），别在这儿二次加工。
    var statusText: String {
        switch self {
        case .idle: return ""
        case .validating: return "正在校验 Cookie…"
        case .failed(let message): return message
        }
    }

    /// 有请求在飞。界面拿它禁按钮，避免连点打出两条校验。
    var isBusy: Bool { self == .validating }
}

// MARK: - 登录态服务

/// 网易云登录态：cookie 存 Keychain，uid/昵称这类非敏感信息存 UserDefaults。
///
/// 形状与 `QQLoginStore` 一一对应（同名方法、同语义、复用同一个 `QRLoginState`），
/// 设置窗那边两家音源的登录区块可以照同一套写。两条路：**扫码**（`qrState`）与
/// **浏览器 Cookie 导入**（`cookieState`），完全并行、互不读写对方。
///
/// 与 QQ 那边的差异只剩一处：网易云没有「用户在手机上拒绝」这一态（点取消就一直停在
/// 802），所以 `QRLoginState.refused` 在这条路上不会出现。
///
/// 曾经还有第三条**手机号登录**（短信 / 密码），已经删掉：它是两条通道上都被风控拦住的那条
/// ——eapi 那边判「设备环境异常」，改走 weapi 之后用户实机撞的是 8810「您当前的网络环境存在
/// 安全风险」。参考实现 [chaunsin/netease-cloud-music] 的 README 里，短信与密码两条同样被
/// 划掉、注着「存在风控问题」，它文档中推荐的正是现在留下的这两条。
@MainActor
@Observable
final class NeteaseLoginStore {

    private(set) var credential: NeteaseCredential?
    private(set) var qrState: QRLoginState = .idle
    private(set) var qrImageData: Data?
    /// 扫码被风控拦下、且服务端给了验证页时的那份挑战。
    ///
    /// 单独一个字段而不是往 `QRLoginState` 里加一个 case：那个枚举是与 QQ 共用的，
    /// 为网易云一条分支去改它，QQ 那边就得凭空多一个永远不会出现的态。
    /// 界面拿它多显示一颗「去完成验证」，`qrState` 那边照旧是 `.failed`。
    private(set) var qrChallenge: NeteaseLoginChallenge?

    /// Cookie 导入状态。与 `qrState` 并列，两条路谁也不碰谁的字段。
    private(set) var cookieState: NeteaseCookieLoginState = .idle

    /// 由 AppState 注入的 API 实例（扫码登录用）
    @ObservationIgnored var qrAPI: NeteaseAPI?

    private var qrTask: Task<Void, Never>?
    private var cookieTask: Task<Void, Never>?

    private static let cookieKey = "neteaseCookie"
    private static let uidKey = "neteaseUID"
    private static let nicknameKey = "neteaseNickname"

    init() {
        guard let cookie = KeychainHelper.get(Self.cookieKey),
              NeteaseCredential.value(of: "MUSIC_U", in: cookie) != nil else { return }
        let uid = UserDefaults.standard.integer(forKey: Self.uidKey)
        credential = NeteaseCredential(cookie: cookie,
                                       uid: uid > 0 ? uid : nil,
                                       nickname: UserDefaults.standard.string(forKey: Self.nicknameKey))
    }

    var isLoggedIn: Bool { credential != nil }

    func logout() {
        cancelQRLogin()
        resetCookieLogin()
        KeychainHelper.delete(Self.cookieKey)
        UserDefaults.standard.removeObject(forKey: Self.uidKey)
        UserDefaults.standard.removeObject(forKey: Self.nicknameKey)
        credential = nil
        qrState = .idle
    }

    /// 凭证失效（`account/get` 复核确认失效时调用）
    func markExpired() {
        credential = nil
    }

    // MARK: - 扫码登录

    /// 开始扫码登录：取 unikey 并画码 → 每 2 秒轮询 → 确认后换凭证
    func startQRLogin() {
        guard let qrAPI else {
            qrState = .failed("登录服务未初始化")
            return
        }
        cancelQRLogin()
        qrState = .loadingQR
        qrImageData = nil
        qrChallenge = nil
        qrTask = Task { [weak self] in
            guard let self else { return }
            do {
                let qr = try await qrAPI.fetchQRLoginImage()
                guard !Task.isCancelled, self.qrState == .loadingQR else { return }
                self.qrImageData = qr.imageData
                self.qrState = .waitingScan
                await self.pollLoop(qrAPI: qrAPI, unikey: qr.unikey)
            } catch {
                if !Task.isCancelled {
                    self.qrState = .failed("获取二维码失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 轮询就跑在 `qrTask` 这一个任务里——**不要**在任务内部重新给 `qrTask` 赋值：
    /// 那会把 `cancelQRLogin` 已经取消的那个句柄换掉，留下一个再也停不下来的轮询。
    private func pollLoop(qrAPI: NeteaseAPI, unikey: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            do {
                switch try await qrAPI.pollQRLogin(unikey: unikey) {
                case .waitingScan:
                    break
                case .scanned:
                    qrState = .scanned
                case .expired:
                    qrState = .expired
                    return
                case .done(let cookie):
                    qrState = .authorizing
                    saveCredential(try await qrAPI.credentialFromCookie(cookie))
                    qrState = .idle
                    qrImageData = nil
                    return
                }
            } catch let challenge as NeteaseLoginChallenge {
                // 风控拦下了，但服务端给了一张验证页：那不是「失败」，是「还差一步」。
                // 把 URL 留住，界面上多一颗「去完成验证」，否则用户只剩一句看不懂的提示。
                qrChallenge = challenge
                qrState = .failed(challenge.errorDescription ?? "需要先完成安全验证")
                return
            } catch {
                qrState = .failed("轮询登录状态失败：\(error.localizedDescription)")
                return
            }
        }
    }

    private func saveCredential(_ credential: NeteaseCredential) {
        KeychainHelper.set(credential.cookie, for: Self.cookieKey)
        UserDefaults.standard.set(credential.uid ?? 0, forKey: Self.uidKey)
        UserDefaults.standard.set(credential.nickname, forKey: Self.nicknameKey)
        self.credential = credential
    }

    /// 取消扫码。面板 `onDisappear` 也走这里，所以顺手把 Cookie 那边的**残留提示**一起清掉
    /// ——面板重开时不该还挂着上一次那句「Cookie 里没有 MUSIC_U」。
    func cancelQRLogin() {
        qrTask?.cancel()
        qrTask = nil
        qrState = .idle
        qrImageData = nil
        qrChallenge = nil
        resetCookieLogin()
    }

    // MARK: - 浏览器 Cookie 导入

    /// 清掉 Cookie 那条路的状态与在飞的校验。
    func resetCookieLogin() {
        cookieTask?.cancel()
        cookieTask = nil
        cookieState = .idle
    }

    /// 用一段从浏览器导出的 Cookie 登录。
    ///
    /// 两步：本地解析（`NeteaseCookieImport`，纯函数、能脱网单测），再拿解出来的
    /// `MUSIC_U` 打一条 `account/get` 换 uid 与昵称。**第二步不是可选的**——
    /// 粘进来的串是真是假、过没过期，只有服务端说了算；跳过它就会存下一份看着像登录、
    /// 实际每首 VIP 歌都取不到流的凭证（这正是 `validateCredential` 那段注释里说的那种降级）。
    ///
    /// 这条路**不打任何登录接口**，因此也没有风控可撞：参考实现
    /// [chaunsin/netease-cloud-music] 把它列为在风控下最稳的一条，正是这个原因。
    func loginWithCookie(_ raw: String) {
        // 先解析再看服务是否就绪：串填错时该说「串填错了」，
        // 而不是甩一句用户看不懂的「登录服务未初始化」。
        let cookie: String
        do {
            cookie = try NeteaseCookieImport.credentialCookie(from: raw)
        } catch {
            cookieState = .failed(error.localizedDescription)
            return
        }
        guard let qrAPI else {
            cookieState = .failed("登录服务未初始化")
            return
        }
        cookieTask?.cancel()
        cookieState = .validating
        cookieTask = Task { [weak self] in
            guard let self else { return }
            do {
                let credential = try await qrAPI.credentialFromCookie(cookie)
                guard !Task.isCancelled else { return }
                self.saveCredential(credential)
                self.cookieState = .idle
            } catch {
                guard !Task.isCancelled else { return }
                self.cookieState = .failed(error.localizedDescription)
            }
        }
    }
}
