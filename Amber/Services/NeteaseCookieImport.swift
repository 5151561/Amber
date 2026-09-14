import Foundation

// MARK: - 浏览器 Cookie 导入

enum NeteaseCookieParseError: LocalizedError, Equatable {
    case empty
    case unrecognized
    case missingMusicU

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Cookie 为空"
        case .unrecognized:
            return "认不出这段 Cookie 的格式（支持浏览器复制的 name=value; 串、Cookie Editor 导出的 JSON、cookies.txt）"
        case .missingMusicU:
            return "Cookie 里没有 MUSIC_U——请确认导出的是已登录的 music.163.com 的 Cookie"
        }
    }
}

/// 把用户从浏览器里导出的 Cookie 解析成 Amber 认的凭证串。
///
/// 这条路是参考实现 [chaunsin/netease-cloud-music] 的**主力登录方式**：它的四条登录路里，
/// 短信与密码两条在 README 里被划掉（「存在风控问题」），文档中唯一明确说能绕开风控的就是
/// 「先在浏览器里登录，再把 Cookie 导进来」——因为这条路**根本不打登录接口**，
/// 风控要拦也没有可拦的请求。对 Amber 来说它还有一个扫码给不了的作用：扫码要掏手机、
/// 开 App、对准屏幕，而这条只要在已经登录的浏览器里复制一段。
///
/// ## 支持的三种格式
///
/// 与参考实现 `ncmctl login cookie` 的 `--format` 一一对应，并且同样**自动识别**
/// （`internal/ncmctl/login_cookie.go`：依次试 netscape → json → header，第一个能解出东西的赢）：
///
/// - `header`：`MUSIC_U=xxx; __csrf=yyy`，浏览器开发者工具里直接复制的那种。
/// - `json`：Cookie Editor 之类扩展导出的数组，每项至少有 `name` / `value`。
/// - `netscape`：`cookies.txt`（curl / 各种导出插件），制表符分隔的七列。
///
/// 顺序照抄参考实现，因为它是**互斥**的：netscape 认的是「一行七个制表符字段」，
/// header 串里没有制表符，JSON 更不会有，所以先试严格的那个不会误吃后两种。
///
/// ## 只留两项
///
/// 导出的 Cookie 动辄十几项（`NMTID` / `_ntes_nuid` / `WEVNSM` / `MUSIC_R_T`…），
/// 但 Amber 的凭证只用得上 `MUSIC_U`（身份）与 `__csrf`（每条 eapi 请求都要回传），
/// 与扫码那条换来的凭证保持同一个形状。多余的项不是无害的——它们要长期躺在 Keychain 里，
/// 而且带着别的会话标识去打请求只会让身份更说不清。
enum NeteaseCookieImport {

    /// 解析成 Amber 的凭证串（`MUSIC_U=…` 或 `MUSIC_U=…; __csrf=…`）。
    static func credentialCookie(from raw: String) throws -> String {
        let cookies = try parse(raw)
        guard let musicU = cookies["MUSIC_U"] else { throw NeteaseCookieParseError.missingMusicU }
        var cookie = "MUSIC_U=\(musicU)"
        if let csrf = cookies["__csrf"] { cookie += "; __csrf=\(csrf)" }
        return cookie
    }

    /// 解析成 name → value。三种格式依次试，都解不出来才报「认不出格式」。
    static func parse(_ raw: String) throws -> [String: String] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NeteaseCookieParseError.empty }
        for parser in [parseNetscape, parseJSON, parseHeader] {
            let cookies = parser(text)
            if !cookies.isEmpty { return cookies }
        }
        throw NeteaseCookieParseError.unrecognized
    }

    /// `cookies.txt`：`domain / flag / path / secure / expiration / name / value`，制表符分隔。
    ///
    /// `#` 开头是注释，唯一的例外是 `#HttpOnly_` 前缀——curl 和多数导出插件用它标 HttpOnly，
    /// 后面跟的是一条**真 cookie**，而 `MUSIC_U` 恰恰就是 HttpOnly 的，把这一行当注释跳过
    /// 等于把唯一要的那项扔了。
    static func parseNetscape(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#HttpOnly_") {
                line = String(line.dropFirst("#HttpOnly_".count))
            } else if line.hasPrefix("#") || line.isEmpty {
                continue
            }
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 7 else { continue }
            let name = fields[5].trimmingCharacters(in: .whitespaces)
            let value = fields[6].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            out[name] = value
        }
        return out
    }

    /// Cookie Editor 那种导出：一个数组，每项 `{"name":…, "value":…, "domain":…, …}`。
    ///
    /// **不按 domain 过滤**：导出里混着 `.163.com` 的项很正常，而我们最后只取 `MUSIC_U`
    /// 与 `__csrf` 两个 music.163.com 专有的键，多认几项也带不出别人的身份。
    /// 参考实现同样是全部塞进 jar 不做筛选。
    static func parseJSON(_ text: String) -> [String: String] {
        guard let data = text.data(using: .utf8),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return [:]
        }
        var out: [String: String] = [:]
        for item in items {
            guard let name = item["name"] as? String, !name.isEmpty,
                  let value = item["value"] as? String, !value.isEmpty else { continue }
            out[name] = value
        }
        return out
    }

    /// `MUSIC_U=xxx; __csrf=yyy`。
    ///
    /// 宽进：允许开头带 `Cookie:` 前缀（从开发者工具的请求头里整行复制就是这样），
    /// 分隔符除了 `;` 也认换行（有人是一行一条粘进来的）。
    /// 值里可能含 `=`，所以只按**首个** `=` 切。
    static func parseHeader(_ text: String) -> [String: String] {
        var body = text
        if body.lowercased().hasPrefix("cookie:") {
            body = String(body.dropFirst("cookie:".count))
        }
        var out: [String: String] = [:]
        for part in body.components(separatedBy: CharacterSet(charactersIn: ";\n\r")) {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            out[name] = value
        }
        return out
    }
}
