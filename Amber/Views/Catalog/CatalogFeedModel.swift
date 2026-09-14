import Foundation
import SwiftUI

// MARK: - 目录页三页的数据模型（主页 / 新发现 / 广播）

/// Music 的三个顶级页面共用一套目录页引擎（`catalogpage 规格` §1：
/// ListenNow/Browse/Radio 三个 intent 分派进同一个 `CatalogPagePresenter`）。
/// Amber 同构：栏目名、卡型、顺序照 Apple Music 写死在 `CatalogPages`，
/// 这一层并发向音源要每一格的数据，交不出来的段整段省掉。
///
/// 这就是原 `CatalogFeedPage`（SwiftUI View）里的`reload()` 与「段 → 卡片」两块，
/// **逻辑一字不改**地搬到一个 `ObservableObject` 上（计划 §2：状态层原样保留，
/// AppKit 侧用 Combine 显式订阅）。视图由 `CatalogPageViewController` 负责。
@MainActor
final class CatalogFeedModel: ObservableObject {

    @Published private(set) var state: CatalogPageState = .loading

    let title: String
    let emptyMessage: String
    let emptyImage: String
    /// 页面结构；用最近播放当种子的段（「<歌名> ›」）要看资料库，所以是个函数
    let sections: (AppState) -> [CatalogPageSection]

    private let appState: AppState
    private var player: PlayerController { appState.player }
    private var library: LibraryStore { appState.library }
    private var reloadTask: Task<Void, Never>?

    init(appState: AppState, title: String, emptyMessage: String, emptyImage: String,
         sections: @escaping (AppState) -> [CatalogPageSection]) {
        self.appState = appState
        self.title = title
        self.emptyMessage = emptyMessage
        self.emptyImage = emptyImage
        self.sections = sections
    }

    // MARK: - 三页入口

    static func home(appState: AppState) -> CatalogFeedModel {
        CatalogFeedModel(appState: appState, title: "主页",
                         emptyMessage: "当前音乐源暂无推荐内容。",
                         emptyImage: "house",
                         // 种子货架要拿当前音源的曲目去查相似，别的源的 id 查不出东西
                         sections: { state in
                             CatalogPages.listenNow(recent: state.library.recentTracks
                                 .filter { $0.kind == state.selectedProvider })
                         })
    }

    static func discover(appState: AppState) -> CatalogFeedModel {
        CatalogFeedModel(appState: appState, title: "新发现",
                         emptyMessage: "当前音乐源暂无新发现内容。",
                         emptyImage: "square.grid.2x2",
                         sections: { _ in CatalogPages.browse })
    }

    static func radio(appState: AppState) -> CatalogFeedModel {
        CatalogFeedModel(appState: appState, title: "广播",
                         emptyMessage: "当前音乐源暂未提供广播内容。",
                         emptyImage: "dot.radiowaves.left.and.right",
                         sections: { _ in CatalogPages.radio })
    }

    // MARK: - 取数

    /// 换音源 / 首次上屏 / 错误页点「重试」都走这条。上一轮还没跑完就取消，
    /// 与原来 `.task(id: appState.selectedProvider)` 的语义相同。
    func reload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in await self?.performReload() }
    }

    private func performReload() async {
        state = .loading
        let provider = appState.provider(appState.selectedProvider)
        let plan = sections(appState)

        // 各段互不依赖，并发拉；但一页十几段、有的段自己还要并发好几条请求，
        // 全放出去会被音源限流（网易云实测会静默丢几条），所以限到 4 条同时在跑。
        let pending = plan.enumerated().filter {
            switch $0.element.slot {
            case .recentlyPlayed, .musicMemories: return false   // 本地资料库来的，不问音源
            default: return true
            }
        }
        let results: [Int: CatalogSlotResult] = await withTaskGroup(
            of: (Int, CatalogSlotResult).self
        ) { group in
            var next = pending.startIndex
            var running = 0
            var out: [Int: CatalogSlotResult] = [:]
            while next < pending.endIndex, running < 4 {
                let (index, section) = pending[next]
                group.addTask { (index, await provider.catalogItems(section.slot)) }
                next += 1; running += 1
            }
            while let (index, result) = await group.next() {
                out[index] = result
                if next < pending.endIndex {
                    let (nextIndex, section) = pending[next]
                    group.addTask { (nextIndex, await provider.catalogItems(section.slot)) }
                    next += 1
                }
            }
            return out
        }

        var rendered: [CatalogSection] = []
        for (index, plan) in plan.enumerated() {
            switch plan.slot {
            case .recentlyPlayed:
                if let local = recentlyPlayedSection(plan) { rendered.append(local) }
                continue
            case .musicMemories:
                if let local = musicMemoriesSection(plan) { rendered.append(local) }
                continue
            default:
                break
            }
            guard let result = results[index], !result.items.isEmpty else { continue }
            rendered.append(section(plan, result))
        }
        guard !Task.isCancelled else { return }
        state = .content(title: title, sections: rendered)
    }

    // MARK: 段 → 卡片

    private func section(_ plan: CatalogPageSection, _ result: CatalogSlotResult) -> CatalogSection {
        var section = CatalogSection(id: plan.id, layout: layout(plan.style),
                                     title: result.title ?? plan.title,
                                     headline: result.headline,
                                     seedArtworkURL: result.seedArtworkURL)
        if let seeAll = result.seeAll {
            section.destination = .playlist(seeAll)
            section.showsChevron = true
        } else if let seedAlbum = result.seedAlbum {
            section.destination = .album(seedAlbum)
            section.showsChevron = true
        } else if plan.showsChevron {
            let title = section.title ?? plan.title ?? ""
            switch result.items {
            case .albums(let albums):
                if !albums.isEmpty {
                    section.destination = .albumGrid(title: title, albums: albums)
                    section.showsChevron = true
                }
            case .playlists(let playlists):
                if !playlists.isEmpty {
                    section.destination = .playlistGrid(title: title, playlists: playlists)
                    section.showsChevron = true
                }
            case .tracks(let tracks):
                if !tracks.isEmpty {
                    section.destination = .trackGrid(title: title, tracks: tracks)
                    section.showsChevron = true
                }
            case .mixed(let entries):
                let playlists = entries.compactMap { entry -> Playlist? in
                    if case .playlist(let p) = entry { return p }
                    return nil
                }
                if !playlists.isEmpty {
                    section.destination = .playlistGrid(title: title, playlists: playlists)
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
            section.items = playlists.map { item($0, plan.style, result.eyebrows[$0.id]) }
        case .albums(let albums):
            section.items = albums.map { item($0, plan.style, result.eyebrows[$0.id]) }
        case .artists(let artists):
            section.items = artists.map { item($0, plan.style) }
        case .mvs(let mvs):
            section.items = mvs.map(videoItem)
        case .tagGroups(let groups):
            section.items = groups.map(linkItem)
        case .mixed(let entries):
            section.items = entries.map { entry in
                switch entry {
                case .playlist(let p): return item(p, plan.style, result.eyebrows[p.id])
                case .album(let a): return item(a, plan.style, result.eyebrows[a.id])
                case .artist(let a): return item(a, plan.style)
                }
            }
        case .tracks(let tracks):
            if case .trackColumns = plan.style {
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

    private func item(_ playlist: Playlist, _ style: CatalogStyle, _ eyebrow: String?) -> CatalogItem {
        CatalogItem(id: "\(playlist.id)-\(playlist.name)", kind: kind(style),
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

    /// 「探索更多」的一条链接。Music 那 5 条落到 Apple 的编辑分类页（`/room/`），
    /// Amber 落到音源分类分组的浏览页。
    private func linkItem(_ group: CatalogTagGroup) -> CatalogItem {
        CatalogItem(id: "group-\(group.id)", kind: .link,
                    title: group.name,
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
    private func recentlyPlayedSection(_ plan: CatalogPageSection) -> CatalogSection? {
        let recents = library.recentTracks
        guard !recents.isEmpty else { return nil }
        let list = LocalTrackList(id: "recently-played", title: "最近播放", tracks: recents)
        return CatalogSection(
            id: plan.id, layout: layout(plan.style), title: plan.title,
            destination: .localTracks(list),
            showsChevron: true,
            items: Self.recentGroups(recents).prefix(12).map(recentItem))
    }

    /// 「最近播放」的一格是一张**专辑**（Music 同）：同一张碟里连着听的几首收成一格，
    /// 按首次出现的顺序排；没有专辑 id 的曲目（电台单集、散曲）各自一格。
    static func recentGroups(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        var heads: [Track] = []
        for track in tracks {
            let key: String
            if let albumId = track.albumId, !albumId.isEmpty {
                key = "album:\(albumId)"
            } else {
                key = "track:\(track.id)"
            }
            guard seen.insert(key).inserted else { continue }
            heads.append(track)
        }
        return heads
    }

    private func recentItem(_ track: Track) -> CatalogItem {
        let albumRoute = Route.album(of: track)
        let artistRoute = Route.artist(of: track)
        // 卡上写专辑名；专辑名空（散曲）才退回歌名。
        let title = track.albumName.isEmpty ? track.title : track.albumName
        let onPlay: () -> Void
        if case .album(let album) = albumRoute {
            onPlay = { [appState] in Task { await appState.playAlbum(album) } }
        } else if case .playlist(let playlist) = albumRoute {
            onPlay = { [appState] in Task { await appState.playPlaylist(playlist) } }
        } else {
            onPlay = { [appState] in appState.playNow(track) }
        }
        return CatalogItem(id: "recent-\(track.albumId ?? track.id)", kind: .square,
                           title: title,
                           artworkURL: track.artworkURL,
                           subtitle: track.artistName,
                           route: albumRoute,
                           subtitleRoute: artistRoute,
                           onPlay: onPlay,
                           // 有专辑就按专辑走（右键是专辑菜单）；散曲才带曲目上下文
                           track: albumRoute == nil ? track : nil,
                           isFavorite: albumRoute == nil && library.isFavorite(track))
    }

    /// 「音乐回忆：你的热门音乐」。Music 那张卡落点是服务端每月生成的歌单
    /// （网页实测 href 是 replay.music.apple.com），卡上两行 [WEB] 标题 13/600
    /// 「每月音乐回忆」+ 描述 11/400「重温上个月陪伴你的艺人、歌曲和专辑」，没有 eyebrow。
    /// Amber 没有服务端，用本地资料库上个月的播放记录现拼一张本地列表；
    /// 上个月没听够 5 首就整段省掉（同「交不出来就不显示」的规矩）。
    private func musicMemoriesSection(_ plan: CatalogPageSection) -> CatalogSection? {
        let tracks = library.topTracksLastMonth()
        guard tracks.count >= 5 else { return nil }
        let list = LocalTrackList(id: "memories", title: "上个月的热门音乐", tracks: tracks)
        let card = CatalogItem(
            id: "memories", kind: kind(plan.style),
            title: "每月音乐回忆",
            artworkURL: tracks.first?.artworkURL,
            description: "重温上个月陪伴你的艺人、歌曲和专辑",
            route: .localTracks(list),
            onPlay: { [player] in player.play(tracks) })
        return CatalogSection(id: plan.id, layout: layout(plan.style), title: plan.title,
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
