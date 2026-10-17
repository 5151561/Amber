import Foundation
import SwiftUI

// MARK: - 目录页三页的数据模型（主页 / 新发现 / 广播）

/// Music 的三个顶级页面共用一套目录页引擎（`catalogpage 规格` §1：
/// ListenNow/Browse/Radio 三个 intent 分派进同一个 `CatalogPagePresenter`）。
/// Amber 同构：栏目名、卡型、顺序照 Apple Music 写死在 `CatalogPages`，
/// 这一层并发向音源要每一格的数据，交不出来的段整段省掉。
///
/// 这就是原 `CatalogFeedPage`（SwiftUI View）里的`reload()` 与「段 → 卡片」两块，
/// 搬到一个 `@Observable` 的状态对象上（计划 §2：状态层原样保留，
/// AppKit 侧显式订阅 `state`）。视图由 `CatalogPageViewController` 负责。
@MainActor
@Observable
final class CatalogFeedModel {

    private(set) var state: CatalogPageState = .loading

    let title: String
    /// 这一页在路由身份里的名字（`listen-now` / `browse` / `radio`）。
    /// 标题是给人看的、会随本地化改，`key` 是给 `Route` 认页面用的，两者分开。
    let pageKey: String
    let emptyMessage: String
    let emptyImage: String
    let page: CatalogFeedPage

    private let appState: AppState
    private var player: PlayerController { appState.player }
    private var library: LibraryStore { appState.library }
    private var reloadTask: Task<Void, Never>?

    init(appState: AppState, title: String, pageKey: String,
         emptyMessage: String, emptyImage: String, page: CatalogFeedPage) {
        self.appState = appState
        self.title = title
        self.pageKey = pageKey
        self.emptyMessage = emptyMessage
        self.emptyImage = emptyImage
        self.page = page
    }

    // MARK: - 三页入口

    static func home(appState: AppState) -> CatalogFeedModel {
        CatalogFeedModel(appState: appState, title: "主页", pageKey: "listen-now",
                         emptyMessage: "当前音乐源暂无推荐内容。",
                         emptyImage: "house", page: .home)
    }

    static func discover(appState: AppState) -> CatalogFeedModel {
        CatalogFeedModel(appState: appState, title: "新发现", pageKey: "browse",
                         emptyMessage: "当前音乐源暂无新发现内容。",
                         emptyImage: "square.grid.2x2", page: .browse)
    }

    static func radio(appState: AppState) -> CatalogFeedModel {
        CatalogFeedModel(appState: appState, title: "广播", pageKey: "radio",
                         emptyMessage: "当前音乐源暂未提供广播内容。",
                         emptyImage: "dot.radiowaves.left.and.right", page: .radio)
    }

    // MARK: - 取数

    /// 换音源 / 首次上屏 / 错误页点「重试」都走这条。上一轮还没跑完就取消，
    /// 与原来 `.task(id: appState.selectedProvider)` 的语义相同。
    ///
    /// **本地那两段先上屏**（审查单 §2.6-1）：「最近播放」与「音乐回忆」由
    /// `LibraryStore` **同步**算出，一条音源请求都不发，
    /// 所以这里**同步**先发一份只有本地段的 `.content`，
    /// 网络段到货再整份补上。本地一段都交不出来（新装、台账还是空的）才照旧打菊花。
    func reload() {
        reloadTask?.cancel()
        let local = localSections()
        state = local.isEmpty ? .loading : .content(title: title, sections: local)
        reloadTask = Task { [weak self] in await self?.performReload() }
    }

    /// 主页里由本地资料库现算的那两段（「最近播放」「音乐回忆」）。整段交不出来
    /// （台账是空的、上个月没听够 5 首）的省掉，与网络段「交不出来就整段省掉」同一条规矩。
    private func localSections() -> [CatalogSection] {
        guard page == .home else { return [] }
        return [recentlyPlayedSection(), musicMemoriesSection()].compactMap { $0 }
    }

    private func performReload() async {
        let provider = appState.provider(appState.selectedProvider)
        let recent = library.recentTracks.filter { $0.kind == appState.selectedProvider }
        let feed = await provider.catalogFeed(for: page, recentTracks: recent)
        guard !Task.isCancelled else { return }

        var rendered = feed.shelves
            .filter { !$0.result.items.isEmpty }
            .map { section($0) }

        if page == .home {
            if let recentSection = recentlyPlayedSection() {
                let insertIndex = rendered.isEmpty ? 0 : 1
                rendered.insert(recentSection, at: insertIndex)
            }
            if let memoriesSection = musicMemoriesSection() {
                rendered.append(memoriesSection)
            }
        }

        guard rendered.isEmpty else {
            // 本地段先上屏那一份与这一份形状相同时，页面那边是零差异 diff、
            // 版式指纹也不变，一次 `invalidateLayout()` 都不会发生（见
            // `CatalogPageViewController.apply(sections:)` 末尾）——断网就是这一支。
            state = .content(title: title, sections: rendered)
            return
        }
        // 一段都摆不出来：断网与「音源真的没有内容」在界面上必须分得开（§2.6-8）。
        let offline = feed.failure != nil
        state = offline ? .error(Self.offlineMessage) : .content(title: title, sections: [])
    }

    /// 断网时的那句话。配套的图标（`wifi.exclamationmark`）与「重试」键页面早就铺好了，
    /// 只是从前没人发 `.error`，取不到就一律落到「当前音乐源暂无推荐内容。」。
    static let offlineMessage = "网络不可用"

    /// 只重算**本地资料库来的那两段**（最近播放 / 音乐回忆），一条音源请求都不发。
    func refreshLocalSections() {
        guard page == .home else { return }
        if case .error = state {
            if !localSections().isEmpty { reload() }
            return
        }
        guard case .content(let title, var rendered) = state else { return }
        let updates: [(String, CatalogSection?)] = [
            ("recently-played", recentlyPlayedSection()),
            ("music-memories", musicMemoriesSection()),
        ]
        for (id, fresh) in updates {
            switch (rendered.firstIndex { $0.id == id }, fresh) {
            case (let index?, let fresh?):
                guard rendered[index].items.map(\.id) != fresh.items.map(\.id) else { continue }
                rendered[index] = fresh
            case (let index?, nil):
                rendered.remove(at: index)
            case (nil, .some):
                reload()
                return
            case (nil, nil):
                break
            }
        }
        state = .content(title: title, sections: rendered)
    }

    // MARK: 段 → 卡片

    /// 「查看全部」那三条路由的身份（见 `RouteCargo`）。
    private func sectionKey(_ shelfID: String) -> String {
        "\(appState.selectedProvider.rawValue)/\(pageKey)/\(shelfID)"
    }

    private func section(_ shelf: CatalogShelf) -> CatalogSection {
        let result = shelf.result
        var section = CatalogSection(id: shelf.id, layout: layout(shelf.style),
                                     title: result.title ?? shelf.title,
                                     headline: result.headline,
                                     seedArtworkURL: result.seedArtworkURL)
        if let seeAll = result.seeAll {
            section.destination = .playlist(seeAll)
            section.showsChevron = true
        } else if let seedAlbum = result.seedAlbum {
            section.destination = .album(seedAlbum)
            section.showsChevron = true
        } else if shelf.showsChevron {
            let title = section.title ?? shelf.title ?? ""
            let key = sectionKey(shelf.id)
            switch result.items {
            case .albums(let albums):
                if !albums.isEmpty {
                    section.destination = .albumGrid(key: key, title: title,
                                                     albums: RouteCargo(albums))
                    section.showsChevron = true
                }
            case .playlists(let playlists):
                if !playlists.isEmpty {
                    section.destination = .playlistGrid(key: key, title: title,
                                                        playlists: RouteCargo(playlists))
                    section.showsChevron = true
                }
            case .tracks(let tracks):
                if !tracks.isEmpty {
                    section.destination = .trackGrid(key: key, title: title,
                                                     tracks: RouteCargo(tracks))
                    section.showsChevron = true
                }
            case .mixed(let entries):
                let playlists = entries.compactMap { entry -> Playlist? in
                    if case .playlist(let p) = entry { return p }
                    return nil
                }
                if !playlists.isEmpty {
                    section.destination = .playlistGrid(key: key, title: title,
                                                        playlists: RouteCargo(playlists))
                    section.showsChevron = true
                }
            default:
                break
            }
        }
        switch result.items {
        case .none:
            break
        case .playlists(let playlists):
            section.items = playlists.map { item($0, shelf.style, result.eyebrows[$0.id]) }
        case .albums(let albums):
            section.items = albums.map { item($0, shelf.style, result.eyebrows[$0.id]) }
        case .artists(let artists):
            section.items = artists.map { item($0, shelf.style) }
        case .mvs(let mvs):
            section.items = mvs.map(videoItem)
        case .tagGroups(let groups):
            section.items = groups.map { groupItem($0, shelf.style) }
        case .mixed(let entries):
            section.items = entries.map { entry in
                switch entry {
                case .trackPack(let pack): return item(pack, shelf.style)
                case .playlist(let p): return item(p, shelf.style, result.eyebrows[p.id])
                case .album(let a): return item(a, shelf.style, result.eyebrows[a.id])
                case .artist(let a): return item(a, shelf.style)
                }
            }
        case .tracks(let tracks):
            if case .trackColumns = shelf.style {
                section.tracks = tracks
            } else {
                section.items = tracks.map(episodeItem)
            }
        }
        return section
    }

    private func layout(_ style: CatalogStyle) -> CatalogSection.Layout {
        switch style {
        case .poster: return .posters
        case .hero: return .heroes
        case .superHero: return .banner
        case .squares(let rows): return .squares(rows: rows)
        case .stations: return .stations
        case .trackColumns(let rows): return .trackColumns(rows: rows)
        case .episodes(let rows): return .episodes(rows: rows)
        case .videos: return .videos
        case .links: return .links
        }
    }

    private func kind(_ style: CatalogStyle) -> CatalogItem.Kind {
        switch style {
        case .poster: return .poster
        case .hero: return .hero
        case .superHero: return .banner
        case .stations: return .station
        case .episodes: return .episode
        case .videos: return .video
        case .links: return .link
        case .squares, .trackColumns: return .square
        }
    }

    /// 曲目包卡片（日推 / 私人雷达 / 猜你喜欢）：点开进入完整曲目列表页，点播放键直接开播。
    private func item(_ pack: CatalogTrackPack, _ style: CatalogStyle) -> CatalogItem {
        let route = Route.trackGrid(
            key: "\(appState.selectedProvider.rawValue)/\(pageKey)/\(pack.id)",
            title: pack.title,
            tracks: RouteCargo(pack.tracks))
        return CatalogItem(
            id: pack.id, kind: kind(style),
            title: pack.title,
            artworkURL: pack.artworkURL,
            eyebrow: pack.eyebrow,
            subtitle: pack.subtitle,
            description: pack.description,
            fallbackColors: Self.fallbackColors(pack.id),
            route: route,
            onPlay: { [player] in
                player.play(pack.tracks, source: .init(title: pack.title, route: route))
            })
    }

    /// 身份只取 `playlist.id`：**标题不进身份**。音源的每日/每周歌单标题常带日期
    /// （「每日30首 · 3月9日」），带上名字就意味着换了个日期＝换了一件，
    /// diff 判成 delete + insert，卡整张重建、封面重新异步取。段内同一份歌单摆两次
    /// 本来就有 `CatalogEntryID.occurrence` 兜底，这个`-name` 后缀是多余的。
    private func item(_ playlist: Playlist, _ style: CatalogStyle, _ eyebrow: String?) -> CatalogItem {
        CatalogItem(id: playlist.id, kind: kind(style),
                    title: playlist.name,
                    artworkURL: playlist.coverURL,
                    eyebrow: eyebrow,
                    subtitle: playlist.creatorName ?? eyebrow,
                    description: playlist.description,
                    fallbackColors: Self.fallbackColors(playlist.id),
                    route: .playlist(playlist),
                    onPlay: { [appState] in Task { await appState.playPlaylist(playlist) } })
    }

    private func item(_ album: Album, _ style: CatalogStyle, _ eyebrow: String?) -> CatalogItem {
        let artistRoute = Route.artist(of: album)
        return CatalogItem(id: album.id, kind: kind(style),
                    title: album.name,
                    artworkURL: album.artworkURL,
                    eyebrow: eyebrow,
                    subtitle: album.artistName,
                    route: .album(album),
                    subtitleRoute: artistRoute,
                    onPlay: { [appState] in Task { await appState.playAlbum(album) } })
    }

    /// 「瞩目之星」是艺人卡：Music 那排是「XX 代表作」编辑歌单，Amber 没有这种编辑内容，
    /// 直接落成艺人卡，点开进艺人页（[推]）。
    private func item(_ artist: Artist, _ style: CatalogStyle) -> CatalogItem {
        CatalogItem(id: artist.id, kind: kind(style),
                    title: artist.name,
                    artworkURL: artist.avatarURL,
                    subtitle: "艺人",
                    route: .artist(artist),
                    onPlay: { [appState] in Task { await appState.playArtistHotTracks(artist) } })
    }

    /// 分类分组项：`.links` 样式画成「探索更多」胶囊链接，其余样式（曲风馆等带图分组）画成图文方卡。
    private func groupItem(_ group: CatalogTagGroup, _ style: CatalogStyle) -> CatalogItem {
        if case .links = style {
            return CatalogItem(id: "group-\(group.id)", kind: .link,
                               title: group.name,
                               route: .tagGroup(group))
        }
        return CatalogItem(id: "group-\(group.id)", kind: kind(style),
                           title: group.name,
                           artworkURL: group.coverURL,
                           subtitle: group.subtitle,
                           fallbackColors: Self.fallbackColors(group.id),
                           route: .tagGroup(group))
    }

    /// MV / 访谈卡。点击在 App 内开视频窗播（同搜索里的 MV 卡）；
    /// 网页那条老路挪进右键菜单（见 `CatalogCardActions`）。
    /// 第二行照 Music：有艺人写艺人，没有（访谈那种）写时长。
    private func videoItem(_ mv: MV) -> CatalogItem {
        CatalogItem(id: "mv-\(mv.id)", kind: .video,
                    title: mv.title,
                    artworkURL: mv.coverURL,
                    subtitle: mv.artistName.isEmpty ? Self.durationText(mv.duration) : mv.artistName,
                    onPlay: { [appState] in appState.playMV(mv) },
                    mv: mv)
    }

    /// Music 的视频卡第二行写成「25 分钟 41 秒」，这里照抄那个中文写法。
    private static func durationText(_ seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }
        let total = Int(seconds)
        let (minutes, rest) = (total / 60, total % 60)
        return minutes > 0 ? "\(minutes) 分钟 \(rest) 秒" : "\(rest) 秒"
    }

    /// 单集本身就是一条可播曲目，播放/心水/加入待播都走 ••• 的 `TrackActions`。
    private func episodeItem(_ episode: Track) -> CatalogItem {
        let artistRoute = Route.artist(of: episode)
        return CatalogItem(id: "ep-\(episode.id)", kind: .episode,
                    title: episode.title,
                    artworkURL: episode.artworkURL,
                    subtitle: episode.artistName,
                    subtitleRoute: artistRoute,
                    onPlay: { [appState] in appState.playNow(episode) },
                    track: episode)
    }

    /// 「最近播放」在 Music 里也是服务端下发的一段，Amber 的最近播放记在本地资料库。
    /// 读的是**容器台账**而不是逐曲历史：分哪个格子在记账那一刻就定了（见`RecentContainer`），
    /// 这一层只负责把格子画成卡。
    private func recentlyPlayedSection() -> CatalogSection? {
        let containers = library.recentContainers
        guard !containers.isEmpty else { return nil }
        return CatalogSection(
            id: "recently-played", layout: .squares(rows: 1), title: "最近播放",
            destination: .recentlyPlayed,
            showsChevron: true,
            items: Self.recentItems(Array(containers.prefix(12)), appState: appState))
    }

    /// 最近播放的格子 → 方卡。**唯一实现**：货架与二级页（`CatalogRoomViewController`）
    /// 共用这一份，别再各抄一份（静态工具给房间页共用，同 `fallbackColors`）。
    /// 卡型一律 `.square`，不新增卡型。
    static func recentItems(_ containers: [RecentContainer], appState: AppState) -> [CatalogItem] {
        containers.compactMap { recentItem($0, appState: appState) }
    }

    private static func recentItem(_ container: RecentContainer,
                                   appState: AppState) -> CatalogItem? {
        switch container {
        case .album(let album):
            return CatalogItem(id: container.id, kind: .square,
                               title: album.name,
                               artworkURL: album.artworkURL,
                               subtitle: album.artistName,
                               route: .album(album),
                               subtitleRoute: Route.artist(of: album),
                               onPlay: { Task { await appState.playAlbum(album) } })
        case .playlist(let playlist):
            return CatalogItem(id: container.id, kind: .square,
                               title: playlist.name,
                               artworkURL: playlist.coverURL,
                               subtitle: playlist.creatorName,
                               // 没有封面地址时才顶上（同目录页的歌单卡）
                               fallbackColors: fallbackColors(playlist.id),
                               route: .playlist(playlist),
                               onPlay: { Task { await appState.playPlaylist(playlist) } })
        case .libraryPlaylist(let id):
            // 这份资料库歌单可能已经被删了：整张卡丢掉，货架上不留空位。
            // 不在载入时清理台账——删除发生在运行期，这道 guard 本来就必须有。
            guard let playlist = appState.library.playlist(id: id) else { return nil }
            return CatalogItem(id: container.id, kind: .square,
                               title: playlist.name,
                               artworkURL: playlist.artworkURL,
                               subtitle: playlist.subtitle,
                               route: .libraryPlaylist(id: id),
                               onPlay: { Task { await appState.playLibraryPlaylist(playlist) } })
        case .favorites:
            let tracks = appState.library.favoriteTracks
            // 与 `LibraryGridCards` 的心水卡逐字相同的落点：多入口共用同一份虚拟列表。
            let list = LocalTrackList(id: "favorites", title: "心水歌曲", tracks: tracks)
            return CatalogItem(id: container.id, kind: .square,
                               title: "心水歌曲",
                               artworkURL: tracks.first?.artworkURL,
                               subtitle: "\(tracks.count) 首歌曲",
                               route: .localTracks(list),
                               onPlay: {
                                   appState.player.play(tracks, source: .init(title: "心水歌曲",
                                                                              route: .localTracks(list)))
                               })
        case .artist(let id, let kind, let name, let avatarURL):
            // 台账只存了四个字段，艺人页要的 `Artist` 在这里现造（同 `Components.swift` 的做法）。
            let artist = Artist(id: id, kind: kind, name: name,
                                avatarURL: avatarURL, description: nil)
            return CatalogItem(id: container.id, kind: .square,
                               title: name,
                               artworkURL: avatarURL,
                               isCircularArtwork: true,
                               // 艺人卡本来就不摆播放键（见 `CatalogItem.onOpen` 那条注释）
                               route: .artist(artist))
        case .track(let track):
            return CatalogItem(id: container.id, kind: .square,
                               title: track.title,
                               artworkURL: track.artworkURL,
                               subtitle: track.artistName,
                               subtitleRoute: Route.artist(of: track),
                               onPlay: { appState.playNow(track) },
                               // 构造上就没有专辑可去，右键走曲目菜单
                               track: track,
                               isFavorite: appState.library.isFavorite(track))
        }
    }

    /// 「音乐回忆：你的热门音乐」。Music 那张卡落点是服务端每月生成的歌单
    /// （网页实测 href 是 replay.music.apple.com），卡上两行 [WEB] 标题 13/600
    /// 「每月音乐回忆」+ 描述 11/400「重温上个月陪伴你的艺人、歌曲和专辑」，没有 eyebrow。
    /// Amber 没有服务端，用本地资料库上个月的播放记录现拼一张本地列表；
    /// 上个月没听够 5 首就整段省掉（同「交不出来就不显示」的规矩）。
    private func musicMemoriesSection() -> CatalogSection? {
        let tracks = library.topTracksLastMonth()
        guard tracks.count >= 5 else { return nil }
        let list = LocalTrackList(id: "memories", title: "上个月的热门音乐", tracks: tracks)
        let card = CatalogItem(
            id: "memories", kind: .poster,
            title: "每月音乐回忆",
            artworkURL: tracks.first?.artworkURL,
            description: "重温上个月陪伴你的艺人、歌曲和专辑",
            route: .localTracks(list),
            onPlay: { [player] in player.play(tracks) })
        return CatalogSection(id: "music-memories", layout: .posters, title: "音乐回忆：你的热门音乐",
                              items: [card])
    }

    /// 没有封面时的色块渐变（按 id 稳定取色，同 SearchLandingView 的色块思路）。
    /// `CatalogGridPages` 也在用，所以留在这里当静态表。
    static func fallbackColors(_ id: String) -> [Color] {
        let palette: [[Color]] = [
            [Color(red: 0.94, green: 0.35, blue: 0.38), Color(red: 0.72, green: 0.16, blue: 0.28)],
            [Color(red: 0.85, green: 0.45, blue: 0.18), Color(red: 0.70, green: 0.26, blue: 0.10)],
            [Color(red: 0.24, green: 0.62, blue: 0.48), Color(red: 0.10, green: 0.42, blue: 0.34)],
            [Color(red: 0.36, green: 0.55, blue: 0.90), Color(red: 0.18, green: 0.30, blue: 0.68)],
            [Color(red: 0.55, green: 0.45, blue: 0.82), Color(red: 0.34, green: 0.26, blue: 0.60)],
            [Color(red: 0.42, green: 0.72, blue: 0.78), Color(red: 0.22, green: 0.50, blue: 0.60)],
        ]
        return palette[abs(id.hashValue) % palette.count]
    }
}
