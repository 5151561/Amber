import Foundation

// MARK: - 导航身份

// 这几样从 `App/AppState.swift` 搬出来（2026-09-17）。搬家的理由是**身份**：
// `Route` 是导航栈认页面的钥匙（`ContentNavigationController.push` 拿它判「栈顶是不是它」），
// 它该和 `Models` 里那些值类型放在一起，而不是长在一个 870 行的 `ObservableObject` 里。
// 行为一个字没改，只是换了文件。

/// 跟着路由走、但**不参与身份**的载荷。
///
/// 导航栈拿 `Route` 的相等性判「栈顶是不是这一页」（`ContentNavigationController.push`），
/// 而目录页那几条「查看全部」的落点原先把整份数组写进 case——每次 push 都要把
/// 上百个 `Album`/`Track` 逐个比一遍，而这些元素本来就是同一次取数的产物，
/// 比出来的结论无非是「key 相同则内容相同」。所以把数组挪进这个壳：
/// `==` 恒真、`hash` 什么都不写，身份改由同 case 里的 `key` 一个字符串说了算。
///
/// **代价说清楚**：两份内容不同、key 却相同的载荷会被判成同一页。所以每个产出点的
/// `key` 必须自己作用域化到「这一页的这一段」（见 `CatalogFeedModel.sectionKey` /
/// `ArtistPageModel.sectionKey` 上的注释），不能直接拿 `CatalogSection.id`
/// ——那个 id 只在单页内唯一。
struct RouteCargo<Element: Sendable>: Hashable, Sendable {
    let items: [Element]

    init(_ items: [Element]) { self.items = items }

    static func == (lhs: RouteCargo<Element>, rhs: RouteCargo<Element>) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

/// 本地拼出来的曲目列表。音源没有对应歌单可落的段（「音乐回忆」）用它当落点。
///
/// **身份只有 `id`**（`tracks` 是载荷）。合成的 `Hashable` 会把整份曲目算进身份，
/// 而心水卡（`LibraryGridCards`）每次求 `route` 都现拼一份全量 `favoriteTracks`：
/// 库里只要变过一首，两次取值就不相等，「栈顶是不是心水歌曲」永远判假
/// （design-ref/reactive-ui-review.md §5）。`title` 同理是显示用的文案，不是身份。
struct LocalTrackList: Hashable {
    let id: String
    let title: String
    let tracks: [Track]

    static func == (lhs: LocalTrackList, rhs: LocalTrackList) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum Route: Hashable, Sendable {
    case playlist(Playlist)
    /// 资料库里的播放列表（本地自建 / 加进来的音源歌单 / 账号同步来的）
    case libraryPlaylist(id: String)
    case album(Album)
    case artist(Artist)
    case localTracks(LocalTrackList)
    /// 「最近播放 ›」的网格二级页。**无载荷**：那一页自己去读资料库的容器台账。
    ///
    /// 早先是靠 `.localTracks` 的 id/标题字符串匹配路由的，用户新建一份叫「最近播放」的
    /// 本地列表就会被劫持；顺带也让导航栈里不用再塞一份最多 200 条 Track 的载荷
    /// （每次 `Hashable` 比较都要整份走一遍）。
    case recentlyPlayed
    /// 「探索更多」的落点：音源分类分组的浏览页
    case tagGroup(CatalogTagGroup)
    // 目录页 / 艺人页分段「查看全部」的三种二级页。
    //
    // **身份是 `key` + `title`，载荷不进身份**（见 `RouteCargo`）。`key` 由产出点
    // 作用域化，格式是「哪一页 / 哪一段」：目录页 `"<音源>/<页>/<段 id>"`、
    // 艺人页 `"artist:<音源>:<艺人 id>/<段 id>"`。别直接塞 `CatalogSection.id`
    // ——每位艺人的「专辑」段 id 都是同一个字面量 `"artist-albums"`，
    // 从前不撞纯粹是因为数组不一样。
    /// 专辑网格二级页
    case albumGrid(key: String, title: String, albums: RouteCargo<Album>)
    /// 歌单网格二级页
    case playlistGrid(key: String, title: String, playlists: RouteCargo<Playlist>)
    /// 曲目列表二级页
    case trackGrid(key: String, title: String, tracks: RouteCargo<Track>)

    /// 曲目 →「所属专辑」的落点。
    ///
    /// 网易云播客单集的 albumId 是电台节目本身（`ne:djradio:<id>`，见 parseDJProgram），
    /// 拿去打专辑接口必回 400；那个 id 归歌单详情管（NeteaseAPI.playlistDetail 认这个前缀），
    /// 所以这里改落到电台节目单。曲目没有专辑就返回 nil，调用方据此不挂链接。
    static func album(of track: Track) -> Route? {
        guard let albumId = track.albumId, !albumId.isEmpty else { return nil }
        if albumId.contains(":djradio:") {
            return .playlist(Playlist(id: albumId, kind: track.kind,
                                      name: track.albumName.isEmpty ? track.artistName : track.albumName,
                                      coverURL: track.artworkURL,
                                      creatorName: track.artistName))
        }
        return .album(Album(id: albumId, kind: track.kind, name: track.albumName,
                            artistName: track.artistName, artistId: track.artistId,
                            artworkURL: track.artworkURL, publishDate: nil,
                            trackCount: 0, description: nil))
    }
}

/// 「这一首该收进哪个格子」——最近播放台账的映射规则，见 `RecentContainer`。
///
/// 住在这里而不是 Models 层：它要认 `Route`，而`RecentContainer` 不该知道导航，
/// `Services`（`LibraryStore` 所在的那层）全层也没有一个文件引用过`Route`，
/// 别在这里破例。写成 static 纯函数、不碰 `AppState` 实例，才好单测。
extension RecentContainer {
    /// `source` 是起播那份列表的来源（队列面板「来自《…》」用的就是它）。
    /// 自动连播续上的歌不属于起播那份列表，调用处传 nil，于是走回落。
    static func resolve(track: Track, source: PlayerController.QueueSource?) -> RecentContainer {
        guard let route = source?.route else { return fallback(track: track) }
        switch route {
        case .playlist(let playlist):
            return .playlist(playlist)
        case .libraryPlaylist(let id):
            return .libraryPlaylist(id: id)
        case .localTracks(let list) where list.id == "favorites":
            return .favorites
        // 资料库派生艺人（`library-artist:` 前缀）没有艺人页可去，收成艺人卡点了没处落，回落。
        case .artist(let artist) where !artist.isLibraryDerived:
            return .artist(id: artist.id, kind: artist.kind, name: artist.name,
                           avatarURL: artist.avatarURL)
        default:
            return fallback(track: track)
        }
    }

    /// 回落：按这首歌自己的归属收。**复用 `Route.album(of:)`**——「网易播客单集的
    /// `albumId` 其实是电台节目、得落到歌单」那条特判就此只剩那一处，不再各抄一份。
    private static func fallback(track: Track) -> RecentContainer {
        switch Route.album(of: track) {
        case .album(let album)?: return .album(album)
        case .playlist(let playlist)?: return .playlist(playlist)
        default: return .track(track)
        }
    }
}
