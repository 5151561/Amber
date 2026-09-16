import AppKit
import Combine
import SwiftUI

// MARK: - 歌单详情页（AppKit）—— 计划阶段 4 批 B
//
// 替代 `DetailViews.swift` 的`PlaylistDetailView` 与`LibraryPlaylistViews.swift` 的
// `LibraryPlaylistDetailView`：两者的版式一模一样，差别只在**曲目从哪来**与**第三枚键**，
// 所以合成一个控制器、用 `Source` 分流。
//
// 加载逻辑（`load()` / `curatorName` / `playlistCallout` / `playlistMetadata` / 页脚文案）
// 从旧版原样搬，一字不改。

/// 歌单页 ☰ 里那一列排序键。
///
/// [实机截图 2026-09-09 23:49]（心水歌曲页）那份菜单是**平的**——没有资料库网格页那种
/// 「全部 / 仅喜爱」两行，也没有「排序选项 ▸」子菜单，直接是七个键 + 分隔 + 升序/降序：
/// 喜爱日期(✓) / 标题 / 类型 / 年份 / 艺人 / 专辑 / 时长，方向那一段选中的是「降序」。
///
/// `rawValue` 用的是 [实测]`playlists 规格` §2.6.1 两跳查表法解出的
/// Music 自己那套排序枚举（`LocalizableStringsMap.plist` → `Localizable.strings`）：
/// Playlist Order(1) / Title(2) / Album(3) / Artist(4) / Year(7) / Genre(8) / Time(13) /
/// Date Favorited(**183**，Music 里只在心水歌曲这类智能歌单上出现——截图正是这一页)。
/// 存进偏好的就是这个数，日后要对 Music 的行为不用再换算一次。
enum PlaylistSortKey: Int, CaseIterable {
    case playlistOrder = 1
    case title = 2
    case genre = 8
    case year = 7
    case artist = 4
    case album = 3
    case time = 13
    /// 心水歌曲页把首项换成这一个（183），其余六项与普通歌单一样。
    case dateFavorited = 183

    /// 截图里的**显示顺序**（不是 rawValue 的大小序）：首项 / 标题 / 类型 / 年份 / 艺人 / 专辑 / 时长。
    static func order(favorites: Bool) -> [PlaylistSortKey] {
        [favorites ? .dateFavorited : .playlistOrder, .title, .genre, .year, .artist, .album, .time]
    }

    var title: String {
        switch self {
        case .playlistOrder: return "播放列表顺序"
        case .dateFavorited: return "喜爱日期"
        case .title: return "标题"
        case .genre: return "类型"
        case .year: return "年份"
        case .artist: return "艺人"
        case .album: return "专辑"
        case .time: return "时长"
        }
    }
}

@MainActor
final class PlaylistDetailViewController: TrackTableViewController {

    /// 曲目从哪来。
    enum Source {
        /// 目录里的歌单（榜单也走这条）：每次打开向音源取。
        case catalog(Playlist)
        /// 资料库里的播放列表：本地自建的直接读库，音源镜像的照样向音源取。
        case library(String)
        /// 心水歌曲：Music 把它也做成一张播放列表（[AX] `favorite-songs.json`
        /// 与 `playlist-detail.json` 的头部、列头、行、页脚一模一样），曲目直接跟着资料库走。
        case favorites
    }

    private typealias M = MusicMetrics.Detail

    private let source: Source
    private var detail: PlaylistDetail?
    private var loadTask: Task<Void, Never>?
    private var header: PlaylistHeaderView?
    private var chart = false
    /// 可编辑的本地播放列表才有「从播放列表中删除」。
    private var editablePlaylistID: String?

    init(appState: AppState, playlist: Playlist) {
        source = .catalog(playlist)
        super.init(nativePage: appState)
    }

    init(appState: AppState, libraryPlaylistID: String) {
        source = .library(libraryPlaylistID)
        super.init(nativePage: appState)
    }

    /// 心水歌曲页。
    init(favoritesOf appState: AppState) {
        source = .favorites
        super.init(nativePage: appState)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { loadTask?.cancel() }

    // MARK: 形态

    override var trackStyle: TrackListStyle { .playlist }
    override var isChart: Bool { chart }
    /// Music 的歌单行铺满内容列（`playlist-detail.json`：行`[202.5, …, 1267.5]`，
    /// 行内第一列就是 40pt 的心水槽，小封面 249.5 与头部 270 大封面 242.5 基本齐平），
    /// 所以行不再另外内缩；页面留白只加在头部与页脚上。旧版 `TrackList` 在歌单页同样没有 padding。
    override var trackRowContentInset: CGFloat { 0 }
    /// [AX] 头部底 322 → 列头顶 360
    override var headerBottomSpacing: CGFloat { M.playlistTableTopSpacing }
    override var showsColumnHeader: Bool { true }
    /// [AX] 末行底 1825 → 页脚文字顶 1862（间距 37）。从前给的是通用的 `M.footerTop`（8），
    /// 差了 29——两页共用同一件页脚 lockup，量法见 `M.playlistFooterTop` 头注。
    override var footerTopSpacing: CGFloat { M.playlistFooterTop }
    override var trackRemoveTitle: String? {
        editablePlaylistID == nil ? nil : "从播放列表中删除"
    }
    override var emptyMessage: String {
        if case .favorites = source { return "添加到心水歌曲的音乐会显示在这里。" }
        guard case .library(let id) = source,
              let playlist = appState.library.playlist(id: id) else { return "这份列表现在是空的。" }
        return playlist.isEditable
            ? "用曲目右键菜单里的「添加到播放列表」往这里加歌。"
            : "这份播放列表现在是空的。"
    }
    override var emptyImage: String {
        if case .favorites = source { return "star" }
        return "music.note.list"
    }

    // MARK: - 排序与页内筛选

    /// 目录里的歌单没有这两件（[AX] `playlist-detail.json` 标题栏右端只有共享 + 更多）；
    /// 资料库歌单与心水歌曲有（[AX] `favorite-songs.json`：更多 1170、排序 1206、搜索 1255，
    /// 以及 [实机截图 2026-09-09 23:49] 那两张）。
    private var isSortable: Bool {
        if case .catalog = source { return false }
        return true
    }

    private var isFavoritesPage: Bool {
        if case .favorites = source { return true }
        return false
    }

    /// 排序键与方向。跟着这一页走，存进偏好——Music 也是记着的（换页回来还是上次那档）。
    private var sortKey: PlaylistSortKey = .playlistOrder
    private var sortAscending = true
    /// 页内筛选词（搜索框「在播放列表中查找」）。
    private var filterText = ""
    /// 音源/资料库给回来的**原始顺序**那一份。排序与筛选都从它算，
    /// 不在已排过的结果上再排——否则「播放列表顺序」这一档一旦离开就回不来了。
    private var loadedTracks: [Track] = []

    private var sortDefaultsKey: String {
        switch source {
        case .catalog(let playlist): return "playlist-sort-catalog-\(playlist.id)"
        case .library(let id): return "playlist-sort-library-\(id)"
        case .favorites: return "playlist-sort-favorites"
        }
    }

    private func loadSortPreference() {
        let defaults = UserDefaults.standard
        let raw = defaults.object(forKey: "\(sortDefaultsKey)-key") as? Int
        sortKey = raw.flatMap(PlaylistSortKey.init(rawValue:))
            ?? (isFavoritesPage ? .dateFavorited : .playlistOrder)
        // 心水歌曲默认「喜爱日期 + 降序」（[实机截图] 那一页勾的就是这两项）：
        // `library.favoriteTracks` 本来就是新心水的插在最前，所以降序＝原样。
        sortAscending = defaults.object(forKey: "\(sortDefaultsKey)-ascending") as? Bool
            ?? !isFavoritesPage
    }

    private func persistSortPreference() {
        let defaults = UserDefaults.standard
        defaults.set(sortKey.rawValue, forKey: "\(sortDefaultsKey)-key")
        defaults.set(sortAscending, forKey: "\(sortDefaultsKey)-ascending")
    }

    /// 原始顺序 → 筛选 → 排序，得到真正上屏的那一批。
    private func displayTracks() -> [Track] {
        var result = loadedTracks
        let keyword = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            // 标题 / 艺人 / 专辑三列都认——与曲目表里看得见的那几列一致。
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(keyword)
                    || $0.artistName.localizedCaseInsensitiveContains(keyword)
                    || $0.albumName.localizedCaseInsensitiveContains(keyword)
            }
        }
        let library = appState.library
        switch sortKey {
        case .playlistOrder, .dateFavorited:
            // 「播放列表顺序 / 喜爱日期」的升序就是拿到手的那一份顺序，降序是把它倒过来。
            // 心水歌曲那份数组是**新的在前**，所以它的「降序」（日期从新到旧）＝原样，
            // 于是这一路的默认方向与普通歌单相反（见 `loadSortPreference`）。
            let ordered = isFavoritesPage ? result.reversed().map { $0 } : result
            return sortAscending ? ordered : ordered.reversed()
        case .title:
            return sorted(result) { $0.title.localizedStandardCompare($1.title) }
        case .artist:
            return sorted(result) { $0.artistName.localizedStandardCompare($1.artistName) }
        case .album:
            return sorted(result) { $0.albumName.localizedStandardCompare($1.albumName) }
        case .genre:
            return sorted(result) {
                (library.genre(for: $0) ?? "").localizedStandardCompare(library.genre(for: $1) ?? "")
            }
        case .year:
            return sorted(result) {
                (library.year(for: $0) ?? "").localizedStandardCompare(library.year(for: $1) ?? "")
            }
        case .time:
            return sortAscending
                ? result.sorted { $0.duration < $1.duration }
                : result.sorted { $0.duration > $1.duration }
        }
    }

    /// 文字列一律用 `localizedStandardCompare`（数字按数值比、大小写与音标不敏感），
    /// 与资料库那几页的排序同一把尺。
    private func sorted(_ tracks: [Track],
                        by compare: (Track, Track) -> ComparisonResult) -> [Track] {
        tracks.sorted { compare($0, $1) == (sortAscending ? .orderedAscending : .orderedDescending) }
    }

    /// 排序或筛选变了：重排在场那批行，顺带把页脚那行摘要按**当前这一批**重算。
    ///
    /// [实测] `playlists 规格` §9.0（macOS 27 / 26A5425a 基线）：Music 的
    /// 搜索栏状态文案 `filterStatusString` 与页脚摘要行`PlaylistFooterModel.summaryLine`
    /// **是同一套生成器**（+），差别只在第二个参数——
    /// 页脚传 0 算全部、搜索栏传 1 只算筛选命中；`lastFilterString` 为空时状态文案返回 nil。
    /// spec 的复刻要点原话是「这两处应共用一个格式化器，不要写成两份」。
    /// Amber 这边只有页脚一处，那就让它跟着筛选结果走：不筛选＝全部，筛选中＝命中那几首。
    ///
    /// 页头也要跟着换名单：页头 ••• 里的「插播 / 加入待播 / 下载 / 移除下载 / 勾选」
    /// 与第三枚键的 ✓/↓ 图标算的都是 `Content.tracks`，那是建 Content 那一刻的**全量**。
    /// 250 首的歌单里搜「周」，页脚说 3 首、▶ 播 3 首，••• 里的下载却把 250 首全开下——
    /// 就是这一处漏掉的。只换名单、不重建页头（页头整块重 apply 会把简介的展开态、
    /// 按宽度量出来的行数一起丢掉）。
    private func reapplyOrder() {
        let tracks = displayTracks()
        rebindPlayback(to: tracks)
        header?.updateTracks(tracks)
        updateFooter(for: tracks)
        apply(tracks: tracks)
    }

    private func updateFooter(for tracks: [Track]) {
        footerLines = [footerCountText(count: tracks.count, tracks: tracks,
                                       hidesSubMinute: footerHidesSubMinute)]
        invalidateFooter()
    }

    /// 搜索框那一件要的是个 `@Published`（`SearchFieldBinder` 双向同步用），
    /// 这一页没有别的页模型，就给它一个只装一个词的小模型。
    private let pageModel = PlaylistPageModel()
    private lazy var searchBinder = SearchFieldBinder(text: pageModel.$search) { [weak self] text in
        guard let self, filterText != text else { return }
        filterText = text
        reapplyOrder()
    }

    private lazy var sortMenuController = PlaylistSortMenuController(
        keys: { [weak self] in PlaylistSortKey.order(favorites: self?.isFavoritesPage ?? false) },
        current: { [weak self] in (self?.sortKey ?? .playlistOrder, self?.sortAscending ?? true) },
        onChange: { [weak self] key, ascending in
            guard let self else { return }
            sortKey = key
            sortAscending = ascending
            persistSortPreference()
            reapplyOrder()
        })

    /// [AX] `favorite-songs.json`：更多 1170 → 排序选项 1206 → 搜索 1255，
    /// 即这两件排在「更多」**右边**（窗口那边的 `pageToolbarTrailingItemIdentifiers`）。
    /// 目录里的歌单一件都不摆（[AX] `playlist-detail.json` 右端只有共享 + 更多）。
    override var pageToolbarTrailingItemIdentifiers: [NSToolbarItem.Identifier] {
        isSortable ? [.amberFilter, .amberSearch] : []
    }

    override func makePageToolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case .amberFilter:
            return ContentToolbarItems.filter(menu: sortMenuController.menu)
        case .amberSearch:
            // 占位词照实机截图：「在播放列表中查找」。
            return ContentToolbarItems.search(placeholder: "在播放列表中查找", binder: searchBinder)
        default:
            return nil
        }
    }

    // MARK: 标题栏右端那两件

    /// [AX] `playlist-detail.json` 的标题栏右端实测两颗：「共享」x=1388、「更多」x=1424。
    ///
    /// 「共享」交出去的是这份歌单在音源网页版的公开页面（`ProviderWebLink.playlist`）。
    /// 三种来源分开取：
    /// - 目录歌单：`Playlist.webShareURL`，用 route 里那张`Playlist` 而不是`detail`，
    ///   id 与音源在推进这一页时就定了，那颗键不会等接口回来才冒出来（与专辑页同一条道理）。
    /// - 资料库歌单：`LibraryPlaylist.webShareURL`——它转发给`source?.webShareURL`，
    ///   所以 Amber 自己建的本地列表给 nil，网上本来就没有这一页，那一件自动不摆。
    /// - 心水歌曲：本机概念，没有对应网页，给空。
    override var pageShareItems: [Any] {
        switch source {
        case .catalog(let playlist):
            return [playlist.webShareURL].compactMap { $0 }
        case .library(let id):
            return [appState.library.playlist(id: id)?.webShareURL].compactMap { $0 }
        case .favorites:
            return []
        }
    }

    /// 「•••」的项由页头给（与页头右键那份同一个能力袋），页头还没建起来（加载中 / 失败）
    /// 时给空表，工具栏那边退回窗口那份。
    ///
    /// **三种来源都摆这一颗**，理由写在这里免得日后当成没出处的默认行为：
    /// [实测] `playlists 规格` §10.1（macOS 27 26A5425a 基线）本批翻案，
    /// 注意 `PlaylistAlbumToolbarModel` 该读成「**歌单页 · 按专辑分组**那一档的工具条模型」
    /// （§9.0：它的搜索占位符取的是 `FIND_IN_ALBUMS`，而普通歌单页取的是
    /// `PLAYLIST_DETAILS_FILTER_PLACEHOLDER`），不是「歌单/专辑通用工具条」——
    /// 这也解释了它那道门为什么是「普通用户歌单」：按专辑分组只对普通歌单开放。判据是
    /// `playlist != nil && playlist->magic == 'plst' && (u16)playlist[] == 0`
    /// （`-[PlaylistAlbumToolbarModel playlistShowsToolbarActions]`，
    /// `hasActionMenu` 只有一条尾调）——是歌单**类型枚举**
    /// （0 = 普通用户歌单、0x3d = 智能歌单），即只有普通用户歌单才摆工具条的 ⋯。
    /// Amber 根本没有智能歌单这个形态，这道门在 Amber 侧恒真；
    /// 且 [AX] 心水歌曲页（`favorite-songs.json`）的工具栏实测也有「更多」，
    /// 所以目录 / 资料库 / 心水三种来源一律摆。
    ///
    /// 注意别跟**头部**那颗 ⋯ 混：`-[PlaylistHeaderModel hasActionMenu]` 是
    /// ——头部那颗恒出现，无条件（§6.0）。两个 ⋯ 是两套判据。
    override var pageMoreEntries: [MenuSpec.Entry] { header?.moreMenuEntries() ?? [] }

    /// 摆。**三种来源都摆**（目录歌单 / 资料库歌单 / 心水歌曲），理由同上一条注释：
    /// [实测] §10.1（macOS 27 / 26A5425a 基线）那道门在 Amber 侧恒真，
    /// 且 [AX] `playlist-detail.json`（更多 x=1424）与`favorite-songs.json`
    /// （更多 x=1170，**这一页是侧栏根页、连返回键都没有**）实测都有这一件。
    ///
    /// 与 `pageMoreEntries` 分工：这一条只管摆不摆，页头还没建起来、上一条给空表时
    /// 这一件照样在（退回窗口那份兜底菜单），不会闪进闪出。
    override var pageShowsToolbarActions: Bool { true }

    /// 菜单交下来的是**在屏那一批**里的曲目，排过序或筛过之后它与资料库里那份数组对不上，
    /// 所以按 id 回资料库里找它们真正的位置，一次删一批
    /// （逐个删会边删边滑，第二首起就删错位）。
    ///
    /// 同一首歌在一份列表里可以出现多次：按「选中了几次就删几个」取前几个占位，
    /// 不把同名的全清掉。
    override func removeTracks(_ tracks: [Track]) {
        guard let editablePlaylistID,
              let playlist = appState.library.playlist(id: editablePlaylistID) else { return }
        var wanted: [String: Int] = [:]
        for track in tracks { wanted[track.id, default: 0] += 1 }
        var offsets = IndexSet()
        for (index, track) in playlist.tracks.enumerated() {
            guard let count = wanted[track.id], count > 0 else { continue }
            wanted[track.id] = count - 1
            offsets.insert(index)
        }
        guard !offsets.isEmpty else { return }
        appState.library.removeTracks(at: offsets, fromPlaylist: editablePlaylistID)
    }

    // MARK: 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        loadSortPreference()
        // 心水歌曲：心水一首歌这一页当场跟着变。
        if case .favorites = source {
            appState.library.$favoriteTracks
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] tracks in self?.showFavorites(tracks) }
                .store(in: &cancellables)
        }
        // 资料库播放列表：改名 / 加歌 / 删歌 / 整份被删都要跟着变。
        if case .library = source {
            appState.library.$playlists
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.libraryPlaylistsChanged() }
                .store(in: &cancellables)
        }
        reload()
    }

    override func retryTapped() { reload() }

    // MARK: - 加载

    private func reload() {
        loadTask?.cancel()
        switch source {
        case .favorites:
            showFavorites(appState.library.favoriteTracks)
        case .catalog(let playlist):
            apply(state: .loading)
            loadTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let detail = try await appState.provider(playlist.kind).playlistDetail(playlist)
                    guard !Task.isCancelled else { return }
                    self.detail = detail
                    self.showCatalog(detail, fallback: playlist)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.apply(state: .error(error.localizedDescription))
                }
            }
        case .library(let id):
            guard let playlist = appState.library.playlist(id: id) else {
                // 侧栏还停在这一项时把列表删了：给个空态，别白屏。
                apply(state: .error("这份播放列表已不在资料库中。"))
                return
            }
            guard let remote = playlist.source else {
                showLibrary(playlist, tracks: playlist.tracks, artworkURL: playlist.artworkURL,
                            curator: "由你创建", description: playlist.description)
                return
            }
            apply(state: .loading)
            loadTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let detail = try await appState.provider(remote.kind).playlistDetail(remote)
                    guard !Task.isCancelled else { return }
                    self.detail = detail
                    self.showLibrary(
                        playlist, tracks: detail.tracks,
                        artworkURL: detail.playlist.coverURL ?? playlist.artworkURL,
                        curator: detail.playlist.creatorName ?? playlist.source?.creatorName
                            ?? remote.kind.displayName,
                        description: detail.playlist.description ?? playlist.description)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.apply(state: .error(error.localizedDescription))
                }
            }
        }
    }

    /// 本地列表被改名 / 增删歌之后重排一次；镜像列表只更新头部（曲目仍归音源）。
    private func libraryPlaylistsChanged() {
        guard case .library(let id) = source else { return }
        guard let playlist = appState.library.playlist(id: id) else {
            apply(state: .error("这份播放列表已不在资料库中。"))
            return
        }
        guard playlist.source == nil else { refreshVisibleRows(); return }
        showLibrary(playlist, tracks: playlist.tracks, artworkURL: playlist.artworkURL,
                    curator: "由你创建", description: playlist.description)
    }

    // MARK: - 上屏

    private func showCatalog(_ detail: PlaylistDetail, fallback: Playlist) {
        chart = detail.isChart
        editablePlaylistID = nil
        let tracks = detail.tracks
        let content = PlaylistHeaderView.Content(
            playlist: detail.playlist,
            tracks: tracks,
            artworkURL: detail.playlist.coverURL ?? fallback.coverURL ?? tracks.first?.artworkURL,
            title: detail.playlist.name,
            curator: curatorName(detail),
            description: detail.playlist.description,
            callout: playlistCallout(detail),
            isEmpty: tracks.isEmpty,
            action: .addToLibrary)
        show(content: content, tracks: tracks, hidesSubMinute: false)
    }

    private func showLibrary(_ playlist: LibraryPlaylist, tracks: [Track], artworkURL: String?,
                             curator: String, description: String?) {
        chart = false
        editablePlaylistID = playlist.isEditable ? playlist.id : nil
        let content = PlaylistHeaderView.Content(
            playlist: playlist.source
                ?? Playlist(id: playlist.id, kind: appState.selectedProvider, name: playlist.name),
            tracks: tracks,
            artworkURL: artworkURL ?? tracks.first?.artworkURL,
            title: playlist.name,
            curator: curator,
            description: description,
            callout: nil,
            isEmpty: tracks.isEmpty,
            action: .libraryMenu(playlist))
        show(content: content, tracks: tracks, hidesSubMinute: true)
    }

    /// 心水歌曲：标题后跟一颗红星、没有策展人行，第三枚键只剩下载（[AX] 「下载」）。
    private func showFavorites(_ tracks: [Track]) {
        chart = false
        editablePlaylistID = nil
        let content = PlaylistHeaderView.Content(
            playlist: Playlist(id: "favorites", kind: appState.selectedProvider, name: "心水歌曲"),
            tracks: tracks,
            artworkURL: nil,
            artworkImage: favoritesArtwork,
            title: "心水歌曲",
            curator: "",
            description: nil,
            callout: nil,
            isEmpty: tracks.isEmpty,
            titleStar: true,
            action: .download)
        show(content: content, tracks: tracks, hidesSubMinute: true)
    }

    /// 画一次就留着：换一批曲目时头部会重新 `apply`，别每次都重画一张 270 的图。
    private lazy var favoritesArtwork = FavoriteSongsArtwork.image()

    private func show(content: PlaylistHeaderView.Content, tracks: [Track],
                      hidesSubMinute: Bool) {
        footerHidesSubMinute = hidesSubMinute
        if let header {
            header.apply(content)
        } else {
            header = PlaylistHeaderView(
                appState: appState, content: content,
                play: { [weak self] in self?.play(tracks) },
                shuffle: { [weak self] in self?.play(tracks.shuffled()) })
            // 建好那一刻先挂上一版，紧接着 `rebindPlayback` 会换成排过序的那一批。
        }
        loadedTracks = tracks
        let display = displayTracks()
        rebindPlayback(to: display)
        // 传进 `Content` 的是刚拿到的全量；页头的动作与图标要认在屏那一批，换过来。
        header?.updateTracks(display)
        updateFooter(for: display)
        apply(header: header, tracks: display)
    }

    /// 播放闭包捕获的是**当前在屏那一批**（排过序、筛过的），换内容或换排序时都要重挂——
    /// 按下播放键播的就该是眼前这个顺序。
    private func rebindPlayback(to tracks: [Track]) {
        header?.play = { [weak self] in self?.play(tracks) }
        header?.shuffle = { [weak self] in self?.play(tracks.shuffled()) }
    }

    private func play(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        appState.player.play(tracks, source: queueSource)
    }

    /// 队列面板的「来自《…》」：三种来源各自的名字与落点。
    override var queueSource: PlayerController.QueueSource? {
        switch source {
        case .catalog(let playlist):
            return .init(title: detail?.playlist.name ?? playlist.name,
                         route: .playlist(playlist))
        case .library(let id):
            guard let playlist = appState.library.playlist(id: id) else { return nil }
            return .init(title: playlist.name, route: .libraryPlaylist(id: id))
        case .favorites:
            // 与侧栏／资料库卡片同一个落点（`LibraryGridCards` 的心水卡也是这条）。
            return .init(title: "心水歌曲",
                         route: .localTracks(LocalTrackList(
                            id: "favorites", title: "心水歌曲",
                            tracks: appState.library.favoriteTracks)))
        }
    }

    // MARK: - 页脚

    private var footerLines: [String] = []
    /// 页脚那行「N 首歌曲，X 分钟」要不要省掉不足一分钟的零头（目录歌单不省）。
    private var footerHidesSubMinute = false

    /// [AX] 页脚文字左沿 **253.5**：`playlist-detail.json` 里「25个项目，1小时29分钟」那条
    /// `AXStaticText` 的 x，与`album-detail.json` 版权行的 x **一模一样**——
    /// 内容列左沿 202.5 + 内容内缩 40 + 页脚自己再缩 11。
    ///
    /// 两页同一个数不是巧合：[实测] §2.1.1 里 `footerMargins` 是 0/40/0/40
    /// （macOS 27 26A5425a 基线），那多出来的 11 在 `AMPTracklistFooterLockup` 内部，
    /// **专辑页与歌单页共用同一份页脚 lockup**，所以左沿必然一致。
    /// 专辑页早就写对了（`M.albumContentHorizontal + M.albumFooterLeading`），
    /// 歌单页从前只给了 40，少了这 11——那 11 直接复用专辑页那条常量，
    /// 就是在代码里把「同一件 lockup」这件事说出来。
    override func makeFooterView() -> NSView? {
        guard !footerLines.isEmpty else { return nil }
        return DetailFooterView(lines: footerLines,
                                leading: M.playlistContentHorizontal + M.albumFooterLeading)
    }

    // MARK: - 文案（旧版原样搬）

    private func curatorName(_ detail: PlaylistDetail) -> String {
        if let creator = detail.playlist.creatorName, !creator.isEmpty {
            return creator
        }
        return detail.playlist.kind.displayName
    }

    private func playlistCallout(_ detail: PlaylistDetail) -> String? {
        if detail.isChart {
            return "根据收听热度实时更新"
        }
        if detail.playlist.playCount > 0 {
            return "累计播放 \(detail.playlist.playCount.shortCount) 次"
        }
        return nil
    }

    private func footerCountText(count: Int, tracks: [Track], hidesSubMinute: Bool) -> String {
        MusicText.countAndDuration(count: count,
                                   seconds: tracks.reduce(0.0) { $0 + $1.duration },
                                   separator: "，", hidesSubMinute: hidesSubMinute)
    }
}

// MARK: - 页内搜索词

/// 只装一个词：`SearchFieldBinder` 要一个`Published` 才能把字段与模型双向同步。
@MainActor
final class PlaylistPageModel: ObservableObject {
    @Published var search = ""
}

// MARK: - ☰ 排序菜单

/// 歌单页那颗 ☰ 弹的菜单。**是平的**——[实机截图 2026-09-09 23:49] 里没有资料库网格页
/// 那种「全部 / 仅喜爱」两行，也没有「排序选项 ▸」子菜单，直接七个键 + 分隔 + 升序/降序。
///
/// （[实测] `playlists 规格` §2.4 说的「筛选只有全部/仅收藏二元开关」是
/// **另一件东西**——那是曲目表上方那条筛选条，不是标题栏这颗 ☰。别把两处混起来。）
///
/// 勾选态每次弹出前重建（`menuNeedsUpdate:`），与资料库那份同解。
@MainActor
private final class PlaylistSortMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let keys: () -> [PlaylistSortKey]
    private let current: () -> (key: PlaylistSortKey, ascending: Bool)
    private let onChange: (PlaylistSortKey, Bool) -> Void

    init(keys: @escaping () -> [PlaylistSortKey],
         current: @escaping () -> (key: PlaylistSortKey, ascending: Bool),
         onChange: @escaping (PlaylistSortKey, Bool) -> Void) {
        self.keys = keys
        self.current = current
        self.onChange = onChange
        super.init()
        menu.delegate = self
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()
        let now = current()
        for key in keys() {
            let item = check(key.title, on: now.key == key, action: #selector(selectKey))
            item.tag = key.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(check("升序", on: now.ascending, action: #selector(selectAscending)))
        menu.addItem(check("降序", on: !now.ascending, action: #selector(selectDescending)))
    }

    private func check(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func selectKey(_ sender: NSMenuItem) {
        guard let key = PlaylistSortKey(rawValue: sender.tag) else { return }
        onChange(key, current().ascending)
    }

    @objc private func selectAscending() { onChange(current().key, true) }
    @objc private func selectDescending() { onChange(current().key, false) }
}
