import AppKit
import Combine
import SwiftUI

// MARK: - SwiftUI 叶子的宿主

extension AppState {

    /// 把一棵 SwiftUI 子树装进 `NSHostingView`，并补齐全套`environmentObject`。
    ///
    /// 过渡期专用（design-ref/appkit-rewrite-plan.md 阶段 1）：内容页、迷你播放器、
    /// 整窗播放器、右侧面板现在都还是 SwiftUI，各自被包成一片叶子挂在 AppKit 树上。
    /// 注入的这一串与旧 `AmberApp.swift` 里那串**一个不差**——少一个就是运行时崩溃，
    /// 因为页面里用的是 `@EnvironmentObject`。各页在后续阶段换成 AppKit 时，
    /// 对应的注入项跟着一起删。
    ///
    /// `sizingOptions = []` 是计划 §2 铁律 2：宿主不再反过来提自己的固有尺寸，
    /// 布局由外面的 AppKit 槽说了算（Apple 文档：减少布局测量、提升性能）。
    @MainActor
    func hostingView(bottomReserve: Bool = false,
                     @ViewBuilder content: () -> some View) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: environmentInjected(content(),
                                                               bottomReserve: bottomReserve))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        return host
    }

    @MainActor
    func hostingController(bottomReserve: Bool = false,
                           @ViewBuilder content: () -> some View) -> NSHostingController<AnyView> {
        let controller = NSHostingController(
            rootView: environmentInjected(content(), bottomReserve: bottomReserve))
        controller.sizingOptions = []
        return controller
    }

    /// 同一串注入，但把根视图**交出来**：宿主已经建好、要换里面那棵子树时用它
    /// （`NSHostingController.rootView = …`）。换 rootView 是 AppKit 主动推一次状态，
    /// 不受「宿主正被 `NSSplitViewItem` 收起而隐藏、SwiftUI 停更新」的影响。
    @MainActor
    func hostingRoot(bottomReserve: Bool = false,
                     @ViewBuilder content: () -> some View) -> AnyView {
        environmentInjected(content(), bottomReserve: bottomReserve)
    }

    @MainActor
    private func environmentInjected(_ view: some View, bottomReserve: Bool) -> AnyView {
        // 内容页底部要给迷你播放器让出位置。原先是 MainView 在 NavigationStack 上挂的
        // 那一句 `safeAreaInset`；胶囊本身已经改成 AppKit 覆盖层，但「滚到底不被盖住」
        // 这件事还得由页面自己留白，所以过渡期把同一句补在每个宿主页上。
        let base = Group {
            if bottomReserve {
                view.safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: MusicMetrics.MiniPlayer.scrollReserve)
                }
            } else {
                view
            }
        }
        return AnyView(base
            .environmentObject(self)
            .environmentObject(player)
            .environmentObject(library)
            .environmentObject(downloads)
            .environmentObject(qqLogin)
            .environmentObject(neteaseLogin)
            .environmentObject(providerSettings)
            .environmentObject(player.clock)
            .environmentObject(songsTable)
            .environmentObject(listViewSize)
            .environmentObject(AppSettings.shared))
    }
}

// MARK: - 页面 VC

/// 页面 VC 报自己要在标题栏上摆哪些件、以及怎么造出来。
///
/// 对应 Music 的做法：工具栏归窗口，具体摆什么由导航栈**栈顶**那一页说了算
/// （[AX] 歌曲/专辑/艺人/最近添加四页是「标题 + 筛选 + 搜索」同一形态，
/// 搜索页是「居中搜索框 + 范围分段控件」，目录页什么都不摆）。
@MainActor
protocol ContentPageToolbarProviding: AnyObject {
    /// 这一页要的工具栏项，按从左到右的顺序。可以含 `.flexibleSpace` 之类的系统项。
    var pageToolbarItemIdentifiers: [NSToolbarItem.Identifier] { get }
    /// 造一件。返回 nil 表示「这一件不归我」，由窗口那边兜底。
    func makePageToolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem?

    /// 二级页右端那颗「共享」交给系统共享面板的东西——通常是这一页那个对象在音源网页版的
    /// 公开页面（`ProviderWebLink` 那一族）。空 = 这一页没有可分享的东西，那一件整件不摆
    /// （本地导入的专辑、Amber 自己建的列表，网上本来就没有这一页）。
    var pageShareItems: [Any] { get }

    /// 这一页在标题栏右端摆不摆那颗「•••」。
    ///
    /// **这是页面自己的属性，不是导航深度的函数。** 曾经按「栈深 > 1」判过，
    /// 结果侧栏点开的歌单（根页）右端空空如也。[AX] `design-ref/ui-spec/pages/*.json`
    /// 五页量下来是这样：
    ///
    /// | 页（json） | 返回 | 共享 | 更多 |
    /// | --- | --- | --- | --- |
    /// | `playlist-detail` | 有 206.5 | 有 1388 | 有 1424 |
    /// | `album-detail` | 有 206.5 | 有 1171 | 有 1207（另有搜索 1255） |
    /// | `catalog-artist` | 有 206.5 | 有 1388 | 有 1424 |
    /// | `favorite-songs` | **无** | 无 | **有 1170**（另有排序 1206、搜索 1255） |
    /// | `library-artist-detail` | **有 206.5** | **无** | **无**（只有排序 1208、搜索 1255） |
    ///
    /// 后两行是钉死「按栈深」那条判据的两个反例，别再把它改回去：
    /// **心水歌曲没有返回键却有「更多」**（它是侧栏根页），
    /// **资料库艺人详情有返回键却两件都没有**。
    ///
    /// [实测] 与 Music 同构（`playlists 规格` §10.1，
    /// macOS 27 / 26A5425a 基线，见规格笔记）：
    /// `-[PlaylistAlbumToolbarModel hasActionMenu]` 只有一条尾调，
    /// 打到 `playlistShowsToolbarActions`——**工具条模型上一个独立的布尔**，
    /// 与菜单内容（`actionMenuFromSender:` 现场构建）是两件事。
    ///
    /// 与 `pageMoreEntries` 的分工照抄这一对：这道门管**摆不摆那一件**，
    /// `pageMoreEntries` 管**弹什么**。所以详情页还在加载、`pageMoreEntries` 暂时给空表时，
    /// 那一件照样在（不会闪进闪出）。
    var pageShowsToolbarActions: Bool { get }

    /// 二级页右端那颗「•••」弹的项。给的是**表**不是菜单：项序、摘项、分隔线折叠一律走
    /// `MenuSpec`，与同一页页头的右键菜单是同一张表、同一批闭包（`CollectionActions`）。
    ///
    /// 每次弹之前现取：内容跟着资料库状态变（喜爱 / 已入库 / 下载完没有），
    /// 建工具栏那一刻的快照活不到用户点它的时候。空 = 这一页没有自己的菜单，退回窗口那份。
    var pageMoreEntries: [MenuSpec.Entry] { get }

    /// 排在「共享 / 更多」**右边**的那几件（筛选与排序 ☰、页内搜索框）。
    ///
    /// [AX] Music 的右端顺序是「共享 → 更多 → 排序选项 → 搜索」：
    /// `favorite-songs` 更多 1170 / 排序 1206 / 搜索 1255、
    /// `album-detail` 共享 1171 / 更多 1207 / 搜索 1255。
    /// `pageToolbarItemIdentifiers` 那一组是排在**左边**的（页面标题一族），
    /// 两组不能混：混了就会排成「排序 → 搜索 → 更多」，与实测反过来。
    var pageToolbarTrailingItemIdentifiers: [NSToolbarItem.Identifier] { get }
}

/// 内容导航栈里的一页。过渡期里绝大多数页面就是「一片 SwiftUI 叶子」，
/// 所以基类直接持有宿主视图；带标题栏件的那几页派生出子类补上工具栏。
@MainActor
class ContentPageController: NSViewController, ContentPageToolbarProviding {
    let appState: AppState
    /// nil = 这一页是 AppKit 原生的，视图由子类 `loadView` 自己搭。
    private let makeContent: (() -> AnyView)?
    /// 内容页要给底部迷你播放器留白；二级页、空态页同样要（胶囊一直都在）。
    private let bottomReserve: Bool
    var cancellables = Set<AnyCancellable>()

    init(appState: AppState, bottomReserve: Bool = true,
         @ViewBuilder content: @escaping () -> some View) {
        self.appState = appState
        self.bottomReserve = bottomReserve
        let builder = content
        self.makeContent = { AnyView(builder()) }
        super.init(nibName: nil, bundle: nil)
    }

    /// AppKit 原生页的入口（计划阶段 3 起的常态）：不建 `NSHostingView`，
    /// 子类自己 `loadView` 搭视图、自己给滚动容器留迷你播放器的位置。
    ///
    /// 参数标签不叫 `appState:` 是因为`SearchPageController` 这类宿主 SwiftUI 的子类
    /// 已经各有一个 `init(appState:)`，同名会变成「重写」。
    init(nativePage appState: AppState) {
        self.appState = appState
        self.bottomReserve = false
        self.makeContent = nil
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        // 页面自己不画背景：玻璃只有窗口根那一层（见 RootViewController）。
        let container = NSView()
        guard let makeContent else { view = container; return }
        let host = appState.hostingView(bottomReserve: bottomReserve) { makeContent() }
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    // MARK: 显隐

    /// 导航容器把这一页显 / 隐时调（`ContentNavigationController.install`）。
    ///
    /// 容器不摘视图、只切 `isHidden`——`NSCollectionView` 一离开视图树就把可见 item
    /// 全卸了，切回来要重排一帧。代价是 `viewDidAppear()` / `viewWillDisappear()`
    /// 不保证还会来第二次，所以要跟着显隐做事的页面重写这两个。
    func pageDidAppear() {}

    func pageDidDisappear() {}

    var pageToolbarItemIdentifiers: [NSToolbarItem.Identifier] { [] }

    func makePageToolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? { nil }

    var pageShareItems: [Any] { [] }

    /// 默认不摆。[AX] 资料库那几张网格页（`all-playlists` / `albums` / `artists` /
    /// `recently-added` / `songs`）与搜索页、目录页右端都只有各自的排序选项 / 搜索，
    /// 没有「•••」；要摆的页面自己覆写成 `true`。
    var pageShowsToolbarActions: Bool { false }

    var pageMoreEntries: [MenuSpec.Entry] { [] }

    var pageToolbarTrailingItemIdentifiers: [NSToolbarItem.Identifier] { [] }
}

// MARK: - 页模型

/// 资料库四页（专辑 / 最近添加 / 艺人 / 所有播放列表）标题栏三件套的取值。
///
/// 这几项以前是各页自己的 `@State`。工具栏搬到 AppKit 之后两边要看同一份，
/// 所以提成一个小 `ObservableObject`：页面 VC 建一份，交给 SwiftUI 页与工具栏两边。
/// （这是过渡形态；各页换成 `NSCollectionView` 时它就成了那一页的视图模型。）
@MainActor
final class LibraryPageModel: ObservableObject {
    @Published var favoritesOnly = false
    @Published var search = ""
    @Published var sort = LibraryGridSort()
    /// 标题栏标题的覆盖值。只有「最近添加」用：它的标题跟着滚动联动当前段名
    /// （nil = 用页名）。
    @Published var displayTitle: String?

    /// 专辑页的排序是持久化的（原先两个 `@AppStorage`）。键名一字不改，旧偏好照读。
    let sortDefaultsKey: String?

    init(sortDefaultsKey: String? = nil) {
        self.sortDefaultsKey = sortDefaultsKey
        guard let sortDefaultsKey else { return }
        let defaults = UserDefaults.standard
        let raw = defaults.object(forKey: "\(sortDefaultsKey)-key") as? Int
        let ascending = defaults.object(forKey: "\(sortDefaultsKey)-ascending") as? Bool
        sort = LibraryGridSort(key: raw.flatMap(LibraryGridSortKey.init(rawValue:)) ?? .title,
                               ascending: ascending ?? true)
    }

    func persistSort() {
        guard let sortDefaultsKey else { return }
        let defaults = UserDefaults.standard
        defaults.set(sort.key.rawValue, forKey: "\(sortDefaultsKey)-key")
        defaults.set(sort.ascending, forKey: "\(sortDefaultsKey)-ascending")
    }
}

/// 歌曲页标题栏的取值。筛选与排序本来就在 `AppState.songsTable`（跟「显示选项」窗共享），
/// 这里只多一个搜索词。
@MainActor
final class SongsPageModel: ObservableObject {
    @Published var search = ""
}

/// 搜索页标题栏的取值：词条与范围。
///
/// 这两项原先是 `SearchView` 的`@State`，而搜索框与范围分段控件都在标题栏上，
/// 换成 AppKit 工具栏之后必须提到页面外面。词条的**提交**逻辑仍在 SwiftUI 页里
/// （去抖、同词去重、最近搜索），这里只负责传值和「取消」这一个动作。
@MainActor
final class SearchPageModel: ObservableObject {
    @Published var query = ""
    @Published var scope: SearchScopeTab
    /// 「把焦点放回搜索框」的信号（Esc 之后、上屏时）。
    @Published var focusToken = 0
    /// 「立刻搜，别等去抖」的信号（回车提交，§4.1.4 searchFieldDidCommitString:）。
    @Published var submitToken = 0
    /// Option-Enter 切换在线音源并提交的信号（§4.1.4 searchFieldSwitchToStoreAndSearch: 的 Amber 映射）。
    @Published var submitOptionToken = 0
    /// Esc / ⓧ 清除：清词条回落地页。由 SwiftUI 页安装。
    var onCancel: () -> Void = {}

    init(scope: SearchScopeTab) {
        self.scope = scope
    }
}

// MARK: - 页面工厂

/// `MainView.detailRoot` / `routeView(_:)` 那两组 switch 搬过来的结果。
@MainActor
enum ContentPageFactory {

    /// 侧栏选中项 → 导航栈的根页。
    static func rootPage(for item: SidebarItem, appState: AppState) -> ContentPageController {
        switch item {
        case .search:
            return SearchPageController(appState: appState)
        case .home:
            return CatalogPageViewController(appState: appState,
                                             model: CatalogFeedModel.home(appState: appState))
        case .discovery:
            return CatalogPageViewController(appState: appState,
                                             model: CatalogFeedModel.discover(appState: appState))
        case .favorites:
            // Music 把心水歌曲做成一张播放列表，版式与歌单详情页完全相同（[AX] favorite-songs）。
            return PlaylistDetailViewController(favoritesOf: appState)
        case .radio:
            return CatalogPageViewController(appState: appState,
                                             model: CatalogFeedModel.radio(appState: appState))
        case .recentlyAdded:
            // 按添加日期分段（今天/昨天/本周…），标题栏标题滚动联动当前段名。
            let model = LibraryPageModel()
            return LibraryRecentlyAddedViewController(appState: appState, model: model)
        case .artists:
            // 分栏浏览：左列表 + 右详情（Music 1.7 的「艺人」页就是这一形态）。
            let model = LibraryPageModel()
            return LibraryArtistsViewController(appState: appState, model: model)
        case .albums:
            let model = LibraryPageModel(sortDefaultsKey: "library-albums-sort")
            return LibraryAlbumsViewController(appState: appState, model: model)
        case .songs:
            return LibrarySongsViewController(appState: appState)
        case .store:
            return ContentPageController(appState: appState) {
                MusicEmptyState(title: "iTunes Store", message: "Amber 不连接 iTunes Store。",
                                systemImage: "bag")
            }
        case .allPlaylists:
            return LibraryAllPlaylistsViewController(appState: appState)
        case .playlist(let id, _):
            return PlaylistDetailViewController(appState: appState, libraryPlaylistID: id)
        }
    }

    /// 推进来的一层。
    static func page(for route: Route, appState: AppState) -> ContentPageController {
        switch route {
        case .playlist(let playlist):
            return PlaylistDetailViewController(appState: appState, playlist: playlist)
        case .libraryPlaylist(let id):
            return PlaylistDetailViewController(appState: appState, libraryPlaylistID: id)
        case .album(let album):
            return AlbumDetailViewController(appState: appState, album: album)
        case .artist(let artist):
            return ArtistDetailViewController(appState: appState, artist: artist)
        case .localTracks(let list):
            // 心水歌曲从别处（「所有播放列表」的那张卡、搜索结果）推进来时也是同一页。
            if list.id == "favorites" {
                return PlaylistDetailViewController(favoritesOf: appState)
            }
            return TrackListPageController(appState: appState, title: list.title,
                                           tracks: list.tracks,
                                           emptyMessage: "这份列表现在是空的。",
                                           emptyImage: "music.note.list")
        case .recentlyPlayed:
            // 「最近播放」是网格形态的二级页，与专辑/歌单网格同一台引擎。
            return CatalogRoomViewController(recentlyPlayedIn: appState)
        case .tagGroup(let group):
            return CatalogRoomViewController(appState: appState, tagGroup: group)
        case .albumGrid(let title, let albums):
            return CatalogRoomViewController(appState: appState, title: title, albums: albums)
        case .playlistGrid(let title, let playlists):
            return CatalogRoomViewController(appState: appState, title: title, playlists: playlists)
        case .trackGrid(let title, let tracks):
            return TrackListPageController(appState: appState, title: title, tracks: tracks,
                                           style: .playlist, kind: .room,
                                           emptyMessage: "暂无曲目。",
                                           emptyImage: "music.note.list")
        }
    }
}
