import Foundation

// MARK: - 音源网页版的公开落地页

/// 「分享」要一条**别人也打得开**的链接。Amber 自己没有服务端、没有可对外的形态，
/// 但两家音源的网页版给每首歌 / 每张碟 / 每份歌单 / 每位歌手都留了一页——分享的就是它。
///
/// [实测 2026-09-09 curl] 下面每一条路径都回 200。要说清楚的是**这只证明路由在**：
/// 两家的详情页都是 SPA，正文由 JS 渲染，服务端只发一个壳，所以 curl 证不了「这个 id
/// 对不对」。两处旁证：QQ 的 `songDetail` 拿真 mid 会被服务端改路由到 `ryqq_v2`
/// （胡编的 mid 不会），网易云的 `song?id=` / `playlist?id=` / `djradio?id=` / `mv?id=`
/// 服务端会把真标题渲进 `<title>` 与 og 卡片里（`song?id=1330348068` → 「起风了…」）。
/// 网易云的 `artist?id=` / `album?id=` 匿名只回壳（登录才渲染），路径形状与站内链接一致。
///
/// **网易云这里用不带 `#/` 的形式**：实测就是它会渲染出真标题与 og 卡片，
/// 分享到聊天工具里能出预览卡；`#/` 那种把路径藏在锚点里，服务端什么都看不到。
/// （MV 卡「在网页中打开」用的 `MV.webURL` 是历史上就有的 `#/mv?id=` 形式，
/// 浏览器里两者等价，那条是「自己去看」不是「发给别人」，不动它。）
///
/// 给不出链接的一律返回 nil，菜单里那条「分享」就不摆（`MenuSpec` 的禁用即隐藏）：
/// 本地导入的歌、资料库按名字归出来的艺人、Amber 自己建的播放列表，网上本来就没有这一页。
enum ProviderWebLink {

    static func track(id: String, kind: ProviderKind) -> URL? {
        guard !id.hasPrefix(Track.localIDPrefix) else { return nil }
        switch kind {
        case .qq: return url("https://y.qq.com/n/ryqq/songDetail/\(id.rawID)")
        case .netease: return url("https://music.163.com/song?id=\(id.rawID)")
        }
    }

    static func album(id: String, kind: ProviderKind) -> URL? {
        guard !id.hasPrefix(Album.localIDPrefix) else { return nil }
        switch kind {
        case .qq: return url("https://y.qq.com/n/ryqq/albumDetail/\(id.rawID)")
        case .netease: return url("https://music.163.com/album?id=\(id.rawID)")
        }
    }

    static func artist(id: String, kind: ProviderKind) -> URL? {
        guard !id.hasPrefix(Artist.libraryIDPrefix) else { return nil }
        switch kind {
        case .qq: return url("https://y.qq.com/n/ryqq/singer/\(id.rawID)")
        case .netease: return url("https://music.163.com/artist?id=\(id.rawID)")
        }
    }

    /// 歌单这一条要按 id 的**三种前缀**分路：普通歌单、榜单（`qq:top:` 走 `toplist/`）、
    /// 电台（网易的 `ne:djradio:` 有自己的页；QQ 的 `qq:radio:` 在网页版没有对应页，
    /// 与其猜一条打不开的链接，不如不摆这一条）。
    static func playlist(id: String, kind: ProviderKind) -> URL? {
        switch kind {
        case .qq:
            if let top = suffix(of: id, after: "qq:top:") {
                return url("https://y.qq.com/n/ryqq/toplist/\(top)")
            }
            if id.hasPrefix("qq:radio:") { return nil }
            return url("https://y.qq.com/n/ryqq/playlist/\(id.rawID)")
        case .netease:
            if let radio = suffix(of: id, after: "ne:djradio:") {
                return url("https://music.163.com/djradio?id=\(radio)")
            }
            return url("https://music.163.com/playlist?id=\(id.rawID)")
        }
    }

    private static func suffix(of id: String, after prefix: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        return rest.isEmpty ? nil : rest
    }

    private static func url(_ string: String) -> URL? {
        // rawID 里可能有 `+` 之类的字符（网易的电台节目 id 见过），交给百分号编码兜一道。
        URL(string: string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? string)
    }
}

extension Track {
    /// 这首歌在音源网页版的公开页面。本地导入的歌没有，返回 nil。
    var webShareURL: URL? { ProviderWebLink.track(id: id, kind: kind) }
}

extension Album {
    var webShareURL: URL? { ProviderWebLink.album(id: id, kind: kind) }
}

extension Artist {
    var webShareURL: URL? { ProviderWebLink.artist(id: id, kind: kind) }
}

extension Playlist {
    var webShareURL: URL? { ProviderWebLink.playlist(id: id, kind: kind) }
}

extension LibraryPlaylist {
    /// Amber 自己建的播放列表只在本机，没有可分享的页面；
    /// 从目录加进来的、账号同步来的那两种指向音源歌单，分享的是那一份。
    var webShareURL: URL? { source?.webShareURL }
}
