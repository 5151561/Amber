import Combine
import Foundation

// MARK: - 搜索页的状态机（计划 design-ref/appkit-rewrite-plan.md 阶段 5 批 C）
//
// 这是原 `SearchView`（SwiftUI）里那套提交链、最近搜索、资料库检索、在线检索**原样**
// 搬到一个 `ObservableObject` 上的结果——形态与`CatalogFeedModel` 一致（计划 §1.4：
// 状态层不动，AppKit 侧用 Combine 显式订阅）。视图那边分两块：
// 词条为空时是落地页 `SearchLandingViewController`，否则是结果页
// `SearchResultsViewController`（= 目录页那台引擎吃这个模型），两者由
// `SearchPageController` 按`showsLanding` 切显隐。
//
// 规格出处沿用 `SearchView` 的注释（`search 规格`）：
// - 提交链 §4.1.4 `searchFieldDidCommitString:modifiers:`（去抖、同词去重`sameSearchString:`、
//   Option 修饰位的 `searchFieldSwitchToStoreAndSearch:`）；
// - 换范围重新分派 §4.1.7 `segmentedControlChanged:`；
// - 资料库范围「词条即搜」§4.1.4/§6.5（`sendsSearchStringImmediately` + `LibrarySearchTermStream`）；
// - 最近搜索 `MusicUIShimRecentLibrarySearchesProvider` / `ClearRecentSearchesAction` §5；
// - Esc 取消 §2.3 `cancelOperation:`。
//
// 词条与范围仍归工具栏那份 `SearchPageModel`（`PageHosting.swift`）持有——搜索框与范围
// 分段控件都在标题栏上。本模型**只读**它，外加装一个 `onCancel`。

/// 结果页的数据源：把 `SearchResults` 折成目录页引擎认的分区。
@MainActor
@Observable
final class SearchResultsModel: CatalogPageModelProviding {

    // MARK: 对外（结果页引擎 + 落地页看这三条）

    /// 目录页引擎的三态。搜索页**从不摆加载态**：新词条提交后旧结果原地留着，
    /// 等新结果到了再换（与 SwiftUI 版 `results` 只在拿到数据时赋值同一语义）。
    private(set) var state: CatalogPageState = .content(title: "搜索", sections: [])
    /// 词条为空 = 落地页（SwiftUI 版 `committedTerm.isEmpty` 那一支）。
    private(set) var showsLanding = true
    /// 最近搜索（落地页那一段）。
    private(set) var recentSearches: [String] = []

    /// 结果页不摆页面大标题（`SearchResultsViewController.showsPageTitle` 给 false），
    /// 这一条只是让协议有个说得通的值。
    let title = "搜索"
    /// 无结果时的居中空态（Music 实测「无结果 / 检查拼写或尝试新搜索词。」）。
    let emptyMessage = "无结果\n检查拼写或尝试新搜索词。"
    let emptyImage = "magnifyingglass"

    // MARK: 内部状态（原来是 `SearchView` 的 @State，一条不多一条不少）

    private let appState: AppState
    private let page: SearchPageModel
    private var library: LibraryStore { appState.library }

    private var committedTerm = ""
    /// 已提交词条对应的范围——`sameSearchString:`（§4.1.4）按 tab 各取参照串，
    /// 换范围即使同词也必须重新分派，否则切「资料库」会停留在在线结果上。
    private var committedScope: SearchScopeTab?
    private var results = SearchResults()
    /// 去抖与竞态的世代号。语义与 SwiftUI 版的 `searchGeneration` 完全一致：
    /// 每次词条变动 +1，去抖醒来时对不上就丢弃。
    private var searchGeneration = 0
    /// 上一次在线检索**五路全败**时的提示；非 nil = 页面停在 `.error` 上。
    /// 从前五路一律 `try?`，「真的没有」与「一条都没打通」混成同一个空结果，
    /// 断网时页面显示「无结果」，而那一页没有「重试」——用户唯一的出路是改词或切范围。
    private var failureMessage: String?
    /// 资料库派生艺人的真实头像缓存（艺人名 → 头像地址）。
    private var resolvedArtistAvatars: [String: String] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let observers = TaskBag()

    private static let recentSearchesKey = "Amber.recentSearches"
    private static let recentSearchesLimit = 8

    private var query: String { page.query }
    private var scope: SearchScopeTab { page.scope }

    init(appState: AppState, page: SearchPageModel) {
        self.appState = appState
        self.page = page
        recentSearches = Self.loadRecentSearches()
        // 工具栏那颗 ⓧ 与 Esc 走同一条（§2.3 cancelOperation:）。
        page.onCancel = { [weak self] in self?.cancelSearch() }

        // 下面四条 = SwiftUI 版那几个 `.onChange`。
        //
        // 原先每条都挂 `.receive(on:)`：`@Published` 在 **willSet** 发布，订阅方当场读
        // `page.scope` 会读到旧值，得落到下一轮再读。换成 `Observations` 之后事件在值
        // **落定之后**才到，回读就是新值，那一跳不需要了。
        // `removeDuplicates()` 也不用写——Equatable 自带相邻去重。
        observers.observe({ [page] in page.query }) { [weak self] value in self?.queryChanged(value) }
        observers.observe({ [page] in page.scope }) { [weak self] _ in self?.segmentedControlChanged() }

        // 回车：不等 450ms 的去抖，立刻按当前词条提交。
        // token 是只增的计数信号，相邻去重咬不到它。
        observers.observe({ [page] in page.submitToken }) { [weak self] _ in
            guard let self else { return }
            self.searchGeneration += 1
            self.commit(term: self.query, switchingScope: false)
        }

        // Option-Enter：切换在线音乐源并立刻提交（§4.1.4 searchFieldSwitchToStoreAndSearch: 的 Amber 映射）。
        observers.observe({ [page] in page.submitOptionToken }) { [weak self] _ in
            guard let self else { return }
            self.searchGeneration += 1
            self.commit(term: self.query, switchingScope: true)
        }

        observers.observe({ [appState] in appState.selectedProvider }) { [weak self] _ in
            guard let self, self.scope == .online, !self.committedTerm.isEmpty else { return }
            Task { await self.searchOnline(term: self.committedTerm) }
        }
    }

    // MARK: - 目录页引擎的口子

    /// 引擎在 `viewDidLoad` 与出错页的「重试」上调这条。搜索页没有「整页重拉」这回事，
    /// 就把当前已提交的那一次按当前范围再跑一遍；没提交过词条则只是把落地态发一次。
    func reload() {
        guard !committedTerm.isEmpty else { publish(); return }
        if committedScope == .library {
            commitLibrarySearch(term: committedTerm)
        } else {
            Task { await searchOnline(term: committedTerm) }
        }
    }

    // MARK: - 提交链（§4.1.4）

    /// 词条变了。资料库范围「词条即搜」（sendsSearchStringImmediately + AsyncStream
    /// sendValue:，§4.1.4/§6.5）；在线范围走去抖提交（ResultsResolver 异步建议的时序，§4.2）；
    /// 词条清空时立即回退到落地页。
    private func queryChanged(_ newValue: String) {
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            commit(term: "", switchingScope: false)
        } else if scope == .library {
            commitLibrarySearch(term: trimmed)
        } else {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, generation == self.searchGeneration else { return }
                self.commit(term: newValue, switchingScope: false)
            }
        }
    }

    /// segmentedControlChanged:（§4.1.7）——「[tab名]」偏好串由工具栏那颗分段控件自己回写
    /// （§4.1.3），这里只管「换了范围就按新范围重搜」。
    private func segmentedControlChanged() {
        if !query.isEmpty { commit(term: query, switchingScope: false) }
    }

    /// 落地页点了最近搜索卡 / 浏览类别砖：词条落进搜索框并立刻提交。
    func selectTerm(_ term: String) {
        page.query = term
        commit(term: term, switchingScope: false)
    }

    /// searchFieldDidCommitString:modifiers:（§4.1.4）。`switchingScope` 对应 Option 修饰位
    /// （bit 0xb）命中后的 searchFieldSwitchToStoreAndSearch:——Amber 映射为切换在线音乐源。
    private func commit(term rawTerm: String, switchingScope: Bool) {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        if switchingScope {
            switchOnlineProvider()
            if scope != .online { page.scope = .online }
        }
        guard !term.isEmpty else {
            // 词条清空 → 回落地页（updateChildSearchController:YES，§4.1.4）。
            committedTerm = ""
            committedScope = nil
            results = SearchResults()
            failureMessage = nil
            publish()
            return
        }
        // 同词去重（sameSearchString: §4.1.4）：同词同范围才跳过；
        // 换范围（segmentedControlChanged → 这里）即使同词也要按新范围重新分派。
        //
        // **上一次是整批失败时这道闸要放行**：断网那一下停在 `.error` 上，
        // 用户对着同一个词按回车必须能重发——否则回车毫无反应，而「重试」按钮
        // 只在 `.error` 态出现、页面又还停在那儿，两条路互相指望着对方。
        guard term != committedTerm || scope != committedScope || failureMessage != nil
        else { return }
        committedTerm = term
        committedScope = scope
        recordRecentSearch(term)
        if scope == .library {
            commitLibrarySearch(term: term)
        } else {
            publish()
            Task { await searchOnline(term: term) }
        }
    }

    private func switchOnlineProvider() {
        let enabled = appState.providerSettings.orderedEnabled
        guard enabled.count > 1 else { return }
        if let index = enabled.firstIndex(of: appState.selectedProvider) {
            appState.selectedProvider = enabled[(index + 1) % enabled.count]
        } else {
            appState.selectedProvider = enabled[0]
        }
    }

    /// Esc 取消（§2.3 cancelOperation: / §2.10 _searchFieldCancel:）：
    /// 清词条回落地页，焦点留在搜索框（viewDidAppear §4.1.7 的回焦行为）。
    func cancelSearch() {
        page.query = ""
        committedTerm = ""
        committedScope = nil
        results = SearchResults()
        failureMessage = nil
        publish()
        page.focusToken += 1
    }

    // MARK: - 检索

    /// 资料库本地过滤（词条流 sendValue: 即时投递的映射 §4.1.4/§6.5）。
    /// 只查 LibraryStore 里的用户数据：libraryTracks / libraryAlbums / 心水，
    /// 艺人从命中的专辑/单曲去重派生；派生艺人没有本地头像，
    /// 由 resolveLibraryArtistAvatars 按艺人名向音源解析，不用专辑封面顶替。
    private func commitLibrarySearch(term: String) {
        var tracks = library.libraryTracks
        // 心水歌曲是用户数据的一部分（Music 资料库搜索同样能搜到已心水但未入库的歌）。
        for favorite in library.favoriteTracks
        where !tracks.contains(where: { $0.id == favorite.id }) {
            tracks.append(favorite)
        }
        // 曲目与专辑各问一次（七处同一个口，见 `LibraryStore.searchFilter`）。
        // 艺人不单独问：这一页的艺人是从**命中的**专辑与曲目现派生的，
        // 而不是「资料库里叫这个名字的艺人」——下面那两段就是它的定义。
        let trackMatches = library.searchFilter(term, kind: .track)
        let matchedTracks = tracks.filter {
            trackMatches.keeps($0.id, [$0.title, $0.artistName, $0.albumName])
        }
        let albumMatches = library.searchFilter(term, kind: .album)
        let matchedAlbums = library.libraryAlbums.filter {
            albumMatches.keeps($0.id, [$0.name, $0.artistName])
        }
        var artists: [Artist] = []
        for album in matchedAlbums where !artists.contains(where: { $0.name == album.artistName }) {
            artists.append(Artist(id: Artist.libraryIDPrefix + album.artistName,
                                  kind: album.kind,
                                  name: album.artistName,
                                  avatarURL: nil,
                                  description: nil))
        }
        for track in matchedTracks
        where !artists.contains(where: { $0.name == track.artistName }) {
            artists.append(Artist(id: Artist.libraryIDPrefix + track.artistName,
                                  kind: track.kind,
                                  name: track.artistName,
                                  avatarURL: nil,
                                  description: nil))
        }
        results = SearchResults(tracks: matchedTracks, albums: matchedAlbums, artists: artists)
        committedTerm = term
        committedScope = .library
        // 本地过滤不会失败：上一次在线检索留下的错误态到这里就算翻篇。
        failureMessage = nil
        publish()
        Task { await resolveLibraryArtistAvatars(artists) }
    }

    /// 资料库派生艺人没有本地艺人照；按艺人名向所属音源搜一次，
    /// 取精确同名（退而求其次第一条）的头像回填，搜不到就保持空占位。
    private func resolveLibraryArtistAvatars(_ artists: [Artist]) async {
        for artist in artists where resolvedArtistAvatars[artist.name] == nil {
            let hits = (try? await appState.provider(artist.kind)
                .searchArtists(keyword: artist.name, limit: 3, offset: 0)) ?? []
            let match = hits.first { $0.name == artist.name } ?? hits.first
            if let avatar = match?.avatarURL {
                resolvedArtistAvatars[artist.name] = avatar
            }
        }
        // 词条或范围已变则不回填（sameSearchString: 的去重语义）。
        guard scope == .library, !committedTerm.isEmpty else { return }
        results.artists = results.artists.map { artist in
            guard let avatar = resolvedArtistAvatars[artist.name] else { return artist }
            return Artist(id: artist.id, kind: artist.kind, name: artist.name,
                          avatarURL: avatar, description: artist.description)
        }
        publish()
    }

    /// 在线搜索：Music 的结果页各分区同时呈现，五路并发拉取
    /// （updateAppleMusicResults §4.1.5 一次分派，各分区独立填充）。
    private func searchOnline(term: String) async {
        let providerKind = appState.selectedProvider
        let provider = appState.provider(providerKind)
        async let tracks = try? provider.searchTracks(keyword: term, limit: 24, offset: 0)
        async let albums = try? provider.searchAlbums(keyword: term, limit: 12, offset: 0)
        async let artists = try? provider.searchArtists(keyword: term, limit: 8, offset: 0)
        async let playlists = try? provider.searchPlaylists(keyword: term, limit: 12, offset: 0)
        async let mvs = try? provider.searchMVs(keyword: term, limit: 10, offset: 0)
        let fetched = await (tracks, albums, artists, playlists, mvs)
        // 竞态防护：词条、范围或音乐源已变则丢弃（sameSearchString: 的去重语义）。
        guard scope == .online,
              providerKind == appState.selectedProvider,
              term == committedTerm else { return }
        // `try?` 的 nil 与 `.some([])` 是两件事：前者是这一路**抛了**（断网、限流、
        // 接口挂了），后者是音源明说「没有」。
        //
        // **五路全抛才算这一页失败。** 只挂一两路时照旧把拿到的那几段摆出来——
        // 音源经常有某一路长期 400（网易的 MV、QQ 的歌单），为那一路把整页换成
        // 错误页反而更糟；而断网时五路必定一起抛，那正是要出「重试」的时刻。
        let failures = [fetched.0 == nil, fetched.1 == nil, fetched.2 == nil,
                        fetched.3 == nil, fetched.4 == nil]
        if failures.allSatisfy({ $0 }) {
            // 结果原样留着（下一次成功时整份替换）：这一页现在由 `failureMessage` 说了算。
            failureMessage = "无法连接到「\(providerKind.shortName)」，请检查网络后重试。"
            publish()
            return
        }
        failureMessage = nil
        results = SearchResults(tracks: fetched.0 ?? [], albums: fetched.1 ?? [],
                                artists: fetched.2 ?? [], playlists: fetched.3 ?? [],
                                mvs: fetched.4 ?? [])
        publish()
    }

    // MARK: - 最近搜索（RecentLibrarySearchesProvider / ClearRecentSearchesAction 的映射）

    private func recordRecentSearch(_ term: String) {
        var items = recentSearches.filter { $0 != term }
        items.insert(term, at: 0)
        if items.count > Self.recentSearchesLimit {
            items = Array(items.prefix(Self.recentSearchesLimit))
        }
        recentSearches = items
        Self.saveRecentSearches(items)
    }

    /// 「清除」是独立动作（ClearRecentSearchesAction §5），不牵动当前结果。
    func clearRecentSearches() {
        recentSearches = []
        Self.saveRecentSearches([])
    }

    private static func loadRecentSearches() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentSearchesKey) ?? []
    }

    private static func saveRecentSearches(_ items: [String]) {
        UserDefaults.standard.set(items, forKey: recentSearchesKey)
    }

    // MARK: - 结果 → 目录段

    /// 每次 `results` / `committedTerm` 变动之后都要走这一句：状态机的输出只有这两条。
    private func publish() {
        showsLanding = committedTerm.isEmpty
        if let failureMessage, !committedTerm.isEmpty {
            // 目录页引擎的错误页自带「重试」，点它走 `reload()`——那条不经过上面的
            // 同词去重闸，重跑的就是当前这个词。
            state = .error(failureMessage)
            return
        }
        state = .content(title: title, sections: committedTerm.isEmpty ? [] : sections())
    }

    /// **两个范围共用同一套分区货架**（实测 Music 的资料库结果同款版式）：
    /// 在线是热门搜索结果 → 艺人 → 专辑 → 歌曲 → 播放列表 → MV；
    /// 资料库无热门、无播放列表/MV（Music 多出作曲者分区，Amber 无作曲者数据），
    /// 分区内容来自本地过滤。
    private func sections() -> [CatalogSection] {
        var out: [CatalogSection] = []
        if scope == .online {
            let hits = topHits()
            if !hits.isEmpty {
                out.append(CatalogSection(id: "search-top", layout: .topResults,
                                          title: "热门搜索结果", items: hits))
            }
        }
        if !results.artists.isEmpty {
            out.append(CatalogSection(id: "search-artists", layout: .squares(rows: 1),
                                      title: "艺人",
                                      // 在线艺人段无 ›，资料库那份有（与 SwiftUI 版一致）
                                      showsChevron: scope == .library,
                                      items: results.artists.map(artistItem)))
        }
        if !results.albums.isEmpty {
            out.append(CatalogSection(id: "search-albums", layout: .squares(rows: 1),
                                      title: "专辑", showsChevron: true,
                                      items: results.albums.map(albumItem)))
        }
        if !results.tracks.isEmpty {
            // 歌曲货架是横向滚动的多列行表，**每列 3 行**（Music 实测）。
            out.append(CatalogSection(id: "search-tracks", layout: .trackColumns(rows: 3),
                                      title: "歌曲", showsChevron: true,
                                      tracks: results.tracks))
        }
        guard scope == .online else { return out }
        if !results.playlists.isEmpty {
            out.append(CatalogSection(id: "search-playlists", layout: .squares(rows: 1),
                                      title: "播放列表", showsChevron: true,
                                      items: results.playlists.map(playlistItem)))
        }
        if !results.mvs.isEmpty {
            out.append(CatalogSection(id: "search-mvs", layout: .videos,
                                      title: "MV", items: results.mvs.map(mvItem)))
        }
        return out
    }

    /// 热门搜索结果的前 8 项：艺人卡打头，其余是歌曲卡（Music 实测的卡片排序）。
    /// 卡型是横卡（`.topResult`）、段是横卡网格（`.topResults`）——就是 Music 的
    /// `TopSearchLockupComponentItem` + `TopSearchGridLayoutConfiguration`
    /// （`search-musicui 规格` §2，4 列 × 278×77）。
    private func topHits() -> [CatalogItem] {
        var items: [CatalogItem] = []
        if let artist = results.artists.first {
            items.append(topArtistItem(artist))
        }
        items += results.tracks.prefix(8 - items.count).map(topTrackItem)
        return items
    }

    /// 热门搜索结果里的艺人卡：圆头像 + 名字 + 副标题「艺人」，尾标 ›（旧版 `TopResultsCard`）。
    /// 只有在线范围才有这一段，所以不必管资料库派生的那种艺人。
    private func topArtistItem(_ artist: Artist) -> CatalogItem {
        CatalogItem(id: "top-artist-\(artist.id)", kind: .topResult, title: artist.name,
                    artworkURL: artist.avatarURL,
                    subtitle: "艺人",
                    isCircularArtwork: true,
                    route: .artist(artist))
    }

    /// 艺人卡：圆头像 + 名字（Music 的艺人一律圆头像，`CatalogItem.isCircularArtwork`）。
    ///
    /// 资料库范围的艺人是**本地歌曲按艺人名分的类**（`Artist.libraryIDPrefix`，冒号后面
    /// 是名字不是 mid），音源那边没有对应的人。Music 实测这类卡点了不推艺人详情页，
    /// 而是**跳回资料库的「艺人」目录并选中那一行**，所以它没有 `route`，落点挂在
    /// `onOpen` 上（主点击 = route → onOpen → onPlay，见`CatalogCardContentView.activatePrimary`）。
    /// 从前它挂在 `onPlay` 上，副作用是悬浮时浮出一颗播放键、按下去执行的却是跳转——
    /// 艺人卡本来就不该有播放键，`onOpen` 这一路只发跳转、不给播放键。
    /// （更早前推的是在线艺人页：拿艺人名当 mid 去打 QQ 的 `GetAlbumList` 回 104400。）
    private func artistItem(_ artist: Artist) -> CatalogItem {
        if artist.isLibraryDerived {
            return CatalogItem(id: "artist-\(artist.id)", kind: .square, title: artist.name,
                               artworkURL: artist.avatarURL,
                               isCircularArtwork: true,
                               onOpen: { [appState] in appState.openLibraryArtist(named: artist.name) },
                               openMenuTitle: "前往艺人")
        }
        return CatalogItem(id: "artist-\(artist.id)", kind: .square, title: artist.name,
                           artworkURL: artist.avatarURL,
                           isCircularArtwork: true,
                           route: .artist(artist))
    }

    private func albumItem(_ album: Album) -> CatalogItem {
        CatalogItem(id: "album-\(album.id)", kind: .square, title: album.name,
                    artworkURL: album.artworkURL,
                    subtitle: album.artistName,
                    route: .album(album),
                    subtitleRoute: Route.artist(of: album),
                    onPlay: { [appState] in Task { await appState.playAlbum(album) } })
    }

    private func playlistItem(_ playlist: Playlist) -> CatalogItem {
        CatalogItem(id: "playlist-\(playlist.id)", kind: .square, title: playlist.name,
                    artworkURL: playlist.coverURL,
                    subtitle: playlist.creatorName ?? "播放列表",
                    route: .playlist(playlist),
                    onPlay: { [appState] in Task { await appState.playPlaylist(playlist) } })
    }

    /// 热门搜索结果里的歌曲卡：点击即播（旧版 `TopResultsCard` 的 Button），
    /// 副标题「歌曲 · 艺人」照旧，右键是曲目菜单（旧版尾标那颗 ••• 的落点）。
    private func topTrackItem(_ track: Track) -> CatalogItem {
        CatalogItem(id: "top-\(track.id)", kind: .topResult, title: track.title,
                    artworkURL: track.artworkURL,
                    subtitle: "歌曲 · \(track.artistName)",
                    subtitleRoute: Route.artist(of: track),
                    onPlay: { [appState] in appState.playNow(track) },
                    track: track)
    }

    /// MV 卡：点击在 App 内开视频窗播（`AppState.playMV`）；
    /// 「下载」「在网页中打开」在右键菜单里（`CatalogCardActions` 见`item.mv`）。
    /// 第二行照目录页那条：有艺人写艺人，没有写时长。
    /// `badge` 是缩略图右下角那颗时长角标（旧版`MVCard` 有、目录页的视频卡没有），
    /// 拿不到时长就不给——卡片那边 `badge == nil` 一笔都不画。
    private func mvItem(_ mv: MV) -> CatalogItem {
        CatalogItem(id: "mv-\(mv.id)", kind: .video, title: mv.title,
                    artworkURL: mv.coverURL,
                    subtitle: mv.artistName.isEmpty ? Self.durationText(mv.duration) : mv.artistName,
                    onPlay: { [appState] in appState.playMV(mv) },
                    mv: mv,
                    badge: Self.durationBadge(mv.duration))
    }

    private static func durationText(_ seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }
        let total = Int(seconds)
        let (minutes, rest) = (total / 60, total % 60)
        return minutes > 0 ? "\(minutes) 分钟 \(rest) 秒" : "\(rest) 秒"
    }

    /// 角标里的时长写法「m:ss」（旧版 `MVCard.durationText`）。
    private static func durationBadge(_ seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }
        let total = Int(seconds)
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
