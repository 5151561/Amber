import Foundation

// MARK: - QQ 音乐登录凭证

/// QQ 音乐会话凭证（cookie + uin），解析规则对齐 qmdec 的 parse_cookie_string
struct QQCredential: Equatable, Sendable {
    let cookie: String
    let uin: String
}

/// 流媒体音质档位，声明顺序即由高到低的降级顺序（`allCases` 直接当阶梯用）。
///
/// 2026-09-05 用超级会员账号逐档实测：这些档位**取流全部是明文**——vkey 的 `ekey` 为空，
/// 取回的头字节就是 `fLaC` / `ftyp` / `OggS` / `ID3`，CDN 对任意 byte range 回 206。
/// 所以 AVPlayer 能直接播，不需要 QMC 解密；QMC 只加密客户端下载到本地的 `.mflac`。
/// 档位码与容器逐个对着线上实测过，完整表见 qmdec 的 `download.py`。
/// 不收 DTS:X（`DT03`）和 Sony 360 Reality Audio（`RA01`-`RA04`，MPEG-H `mhm1`）：
/// 两者线上都有，但 macOS 没有解码器——实测 `AVURLAsset.isPlayable` 为 false，
/// 落地后用 `AVAssetReader` 解也直接失败，播放器只会空转不出声，所以不放进选择器。
/// `Codable` 是给`SettingsValues.downloadQuality` 用的：设置窗那一整套偏好按 JSON 存一个键，
/// 里面带了这个类型，不给它 Codable 整个 `SettingsValues` 就合成不出来。
enum StreamQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case atmos = "dolby"
    case surround = "surround"
    case master = "master"
    case premium = "premium"
    case lossless = "flac"
    case ogg640 = "ogg640"
    /// rawValue 沿用旧的 "320"/"128"，老用户存在 UserDefaults 里的偏好不会被重置
    case high = "320"
    case aac192 = "aac192"
    case ogg192 = "ogg192"
    case standard = "128"
    case aac96 = "aac96"
    case ogg96 = "ogg96"
    case aac48 = "aac48"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .atmos: return "杜比全景声"
        case .surround: return "臻品全景声 (5.1)"
        case .master: return "臻品母带 (24bit/192k)"
        case .premium: return "臻品音质"
        case .lossless: return "无损 (FLAC)"
        case .ogg640: return "Vorbis 640k"
        case .high: return "高品质 (320k)"
        case .aac192: return "AAC 192k"
        case .ogg192: return "Vorbis 192k"
        case .standard: return "标准音质 (128k)"
        case .aac96: return "AAC 96k"
        case .ogg96: return "Vorbis 96k"
        case .aac48: return "AAC 48k"
        }
    }

    /// 选择器里的分组标题
    var group: String {
        switch self {
        case .atmos: return "沉浸声"
        case .surround, .master, .premium, .lossless: return "无损"
        default: return "有损"
        }
    }

    /// vkey 文件名用的档位码与扩展名。
    ///
    /// **扩展名必须和这一档真实的容器对上**，写错了 CDN 直接 404——而服务端照样会回一个
    /// purl，所以 purl 不是可用性判据。多个元素表示这一档有码率梯子，按从高到低试。
    var rungs: [(code: String, ext: String)] {
        switch self {
        case .atmos:
            // 只上 E-AC-3 JOC 的三档（约 775 / 645 / 450 kbps）。同族的 D004/D008/D009
            // 是 AC-4，macOS 解不了，故意不列。
            return [("D003", ".mp4"), ("D002", ".mp4"), ("D005", ".mp4")]
        case .surround: return [("Q001", ".flac")]
        case .master: return [("AI00", ".flac")]
        case .premium: return [("Q000", ".flac")]
        case .lossless: return [("F000", ".flac")]
        case .ogg640: return [("O801", ".ogg")]
        case .high: return [("M800", ".mp3")]
        case .aac192: return [("C600", ".m4a")]
        case .ogg192: return [("O600", ".ogg")]
        case .standard: return [("M500", ".mp3")]
        case .aac96: return [("C400", ".m4a")]
        case .ogg96: return [("O400", ".ogg")]
        case .aac48: return [("C200", ".m4a")]
        }
    }

    /// 从这一档往下的完整降级阶梯
    var ladder: [StreamQuality] {
        Array(Self.allCases.drop(while: { $0 != self }))
    }

    /// 选择器分组，保持 allCases 的从高到低顺序
    static let groups: [(name: String, qualities: [StreamQuality])] = {
        var out: [(name: String, qualities: [StreamQuality])] = []
        for quality in allCases {
            if out.last?.name == quality.group {
                out[out.count - 1].qualities.append(quality)
            } else {
                out.append((quality.group, [quality]))
            }
        }
        return out
    }()
}

enum CookieParseError: LocalizedError {
    case empty
    case missingUin
    case missingSessionKey

    var errorDescription: String? {
        switch self {
        case .empty: return "Cookie 为空"
        case .missingUin: return "Cookie 中缺少 uin（需包含 qqmusic_uin=数字 或 uin=数字）"
        case .missingSessionKey: return "Cookie 中缺少会话密钥（需包含 qqmusic_key= 或 qm_keyst=）"
        }
    }
}

/// 解析粘贴的 cookie 串（对齐 qmdec：去掉 Cookie: 前缀、取第一行、提取数字 uin、校验会话密钥）
func parseQQCookie(_ raw: String) throws -> QQCredential {
    var cookie = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // 多行/带 NUL 时只取第一行
    for separator in ["\n", "\r", "\u{0}"] {
        if let range = cookie.range(of: separator) {
            cookie = String(cookie[..<range.lowerBound])
        }
    }
    cookie = cookie.trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
    if cookie.lowercased().hasPrefix("cookie:") {
        cookie = String(cookie.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !cookie.isEmpty else { throw CookieParseError.empty }

    // 提取数字 uin（兼容 o 前缀，如 uin=o123456789）
    var uin = ""
    let patterns = [
        "qqmusic_uin=[oO]?(\\d{4,})",
        "\\buin=[oO]?(\\d{4,})",
        "wxuin=[oO]?(\\d{4,})",
    ]
    for pattern in patterns {
        if let match = cookie.range(of: pattern, options: .regularExpression),
           let valueRange = cookie[match].range(of: "(?<=[=oO])\\d+", options: .regularExpression) {
            uin = String(cookie[valueRange])
            break
        }
    }
    guard !uin.isEmpty else { throw CookieParseError.missingUin }

    guard cookie.contains("qqmusic_key=") || cookie.contains("qm_keyst=") else {
        throw CookieParseError.missingSessionKey
    }

    // 统一补上 qqmusic_uin（与 qmdec 行为一致）
    var finalCookie = cookie
    if !finalCookie.contains("qqmusic_uin=") {
        finalCookie = "\(finalCookie); qqmusic_uin=\(uin)"
    }
    return QQCredential(cookie: finalCookie, uin: uin)
}

// MARK: - 登录态服务

/// 扫码登录流程状态
enum QRLoginState: Equatable {
    case idle
    case loadingQR            // 获取二维码中
    case waitingScan          // 已展示二维码，等待手机扫码
    case scanned              // 已扫码，等待确认
    case refused              // 用户在手机上拒绝
    case expired              // 二维码过期
    case authorizing          // 确认后正在换取凭证
    case failed(String)

    var statusText: String {
        switch self {
        case .idle: return ""
        case .loadingQR: return "正在获取二维码…"
        case .waitingScan: return "请使用 QQ 扫描二维码"
        case .scanned: return "已扫码，请在手机上确认"
        case .refused: return "已拒绝登录"
        case .expired: return "二维码已过期，请重新获取"
        case .authorizing: return "登录确认中…"
        case .failed(let message): return message
        }
    }
}

/// 已登录账号的昵称与头像。侧栏底部那颗按钮显示的就是它
///（Music 那颗按钮的 AX description 直接就是账号名，不是「已登录」这类状态词）。
struct QQAccountProfile: Equatable, Sendable {
    let nickname: String
    /// 头像地址，取不到就 nil（界面退回首字母／人形占位）。
    let avatarURL: String?
}

/// QQ 音乐登录态：cookie 存 Keychain，音质偏好存 UserDefaults。
///
/// `defaults` 可注入：测试拿的是自己的 suite。写死`.standard` 的话，单元测试跑在
/// **App 宿主进程**里，`UserDefaults.standard` 就是`com.changlepan.Amber` 本人——
/// 跑一次 `xcodebuild test` 就会把用户真实的音质偏好覆盖成默认档（曾经的实况：
/// 每次跑完测试，下次开 App 音质就回到 128k）。
@MainActor
final class QQLoginStore: ObservableObject {

    @Published private(set) var credential: QQCredential?
    @Published var quality: StreamQuality {
        didSet {
            defaults.set(quality.rawValue, forKey: Self.qualityKey)
        }
    }
    @Published private(set) var qrState: QRLoginState = .idle
    @Published private(set) var qrImageData: Data?

    /// 已登录账号的昵称与头像。没登录、或这一趟没取到就是 nil。
    @Published private(set) var profile: QQAccountProfile?

    /// 由 AppState 注入的 API 实例（扫码登录、取账号资料都走它，是同一份 `QQAPI`）
    var qrAPI: QQAPI?

    private var qrTask: Task<Void, Never>?
    private var profileTask: Task<Void, Never>?
    private let defaults: UserDefaults

    private static let cookieKey = "qqCookie"
    private static let qualityKey = "qqStreamQuality"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = KeychainHelper.get(Self.cookieKey),
           let uin = stored.range(of: "qqmusic_uin=[oO]?\\d{4,}", options: .regularExpression)
                .map({ String(stored[$0]).replacingOccurrences(of: "qqmusic_uin=", with: "") }) {
            credential = QQCredential(cookie: stored, uin: uin)
        }
        let qualityRaw = defaults.string(forKey: Self.qualityKey) ?? ""
        quality = StreamQuality(rawValue: qualityRaw) ?? .standard
    }

    var isLoggedIn: Bool { credential != nil }

    /// 登录：解析并保存 cookie。格式错误抛 CookieParseError。
    func login(cookieString: String) throws {
        let parsed = try parseQQCookie(cookieString)
        KeychainHelper.set(parsed.cookie, for: Self.cookieKey)
        credential = parsed
        refreshProfile()
    }

    func logout() {
        cancelQRLogin()
        KeychainHelper.delete(Self.cookieKey)
        credential = nil
        qrState = .idle
        refreshProfile()
    }

    /// 凭证失效（接口返回凭证过期错误码时调用）
    func markExpired() {
        credential = nil
        refreshProfile()
    }

    // MARK: - 账号资料

    /// 拉一次昵称与头像。没登录就直接清空——换号／注销后侧栏不能还挂着上一个人的名字。
    ///
    /// 启动时由 `AppState.runLaunchTasksOnce` 在校完凭证之后叫一次（`init` 里不发网络请求），
    /// 之后登录态每变一次重来一次。
    func refreshProfile() {
        profileTask?.cancel()
        profileTask = nil
        qrAPI?.resetAccountCache()
        guard let qrAPI, credential != nil else {
            profile = nil
            return
        }
        profileTask = Task { [weak self] in
            let fetched = await qrAPI.accountProfile()
            guard !Task.isCancelled else { return }
            self?.profile = fetched
        }
    }

    // MARK: - 扫码登录

    /// 开始扫码登录：取码 → 每 2 秒轮询 → 确认后换凭证
    func startQRLogin() {
        guard let qrAPI else {
            qrState = .failed("登录服务未初始化")
            return
        }
        cancelQRLogin()
        qrState = .loadingQR
        qrImageData = nil
        qrTask = Task { [weak self] in
            guard let self else { return }
            do {
                let qr = try await qrAPI.fetchQRLoginImage()
                guard !Task.isCancelled, self.qrState == .loadingQR else { return }
                self.qrImageData = qr.imageData
                self.qrState = .waitingScan
                await self.pollLoop(qrAPI: qrAPI, qrsig: qr.qrsig)
            } catch {
                if !Task.isCancelled {
                    self.qrState = .failed("获取二维码失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 轮询就跑在 `qrTask` 这一个任务里——**不要**在任务内部重新给`qrTask` 赋值：
    /// 那会把 `cancelQRLogin` 已经取消的那个句柄换掉，留下一个再也停不下来的轮询。
    private func pollLoop(qrAPI: QQAPI, qrsig: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            do {
                let status = try await qrAPI.pollQRLogin(qrsig: qrsig)
                switch status {
                case .waitingScan:
                    break
                case .scanned:
                    qrState = .scanned
                case .refused:
                    qrState = .refused
                    return
                case .expired:
                    qrState = .expired
                    return
                case .done(let uin, let sigx):
                    qrState = .authorizing
                    let credential = try await qrAPI.authorizeQRLogin(uin: uin, sigx: sigx)
                    saveCredential(credential)
                    qrState = .idle
                    qrImageData = nil
                    return
                }
            } catch {
                qrState = .failed("轮询登录状态失败：\(error.localizedDescription)")
                return
            }
        }
    }

    private func saveCredential(_ credential: QQCredential) {
        KeychainHelper.set(credential.cookie, for: Self.cookieKey)
        self.credential = credential
        refreshProfile()
    }

    func cancelQRLogin() {
        qrTask?.cancel()
        qrTask = nil
        qrState = .idle
        qrImageData = nil
    }
}
