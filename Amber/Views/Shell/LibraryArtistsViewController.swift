import AppKit
import SwiftUI

// MARK: - 资料库艺人页（AppKit）—— 阶段 5
//
// 替代 `LibraryViews.swift` 的`LibraryArtistsPage`。
// 对照 Music 1.7 的 `ItemTracklistSplitViewController` 与`ArtistsTracklistSplitViewController`
// （见 `artists 规格` §5 及 design-ref/ui-spec/pages/artists.json、
// library-artist-detail.{json,png}；交互与像素另经 2026-09-07 实机逐项核对）：
// 1. 双栏分栏：标准 `NSSplitView`（左 150…350，默认 298；右侧随窗口伸缩）。
// 2. 左列表：固定置顶行「所有艺人」+ 全量艺人（喜爱艺人名字尾随品牌红 ★），支持搜索过滤
//    与仅喜爱筛选，异步获取头像；行底分割线从文字列起到行右沿，选中底盖住它。
// 3. 右详情：
//    - 未选时居中展示「选择艺人」[AX]。
//    - 选中某位艺人：顶部固定头＝艺人标题（26 bold）+ 副标题「N张专辑，M首歌曲」，
//      右上 ▶ / ⤨ / ★ / ⋯ 四枚 25pt 圆钮（悬 [AX] 播放 / 随机播放 / 喜爱 / 更多），
//      标题与副标题之间一条细线（y=117 [PX]）。
//    - 选「所有艺人」：**没有**叫「所有艺人」的大标题，而是按艺人分组——每位艺人一行
//      组头（同一份 `LibraryArtistHeaderView`，标题＝艺人名、四枚圆钮、细线，但**无副标题**），
//      组头下面是他自己的专辑块，专辑信息行也不再重复艺人名。2026-09-07 据 Music 实拍更正。
//    - 下方为专辑块列表（`NSTableView` 虚拟化）：大封面（详情宽 0.371，夹 200…360，
//      左内缩 30）+ 标题（22 bold，尾随专辑 ★）+ 风格/年份/星级；标题组右端 ↓ / ⋯ 两枚
//      圆钮（入库 / 更多菜单）；块间距 120。
//    - 音轨行（块内，宽恒 511 [AX]）：心水星、序号（悬浮换红 ▶）、歌名、五星评分、时长、
//      ⋯ 菜单；行底 1pt 分割线（+24 起）；单击选中＝整行圆角 5 品牌红底白字（当前播放同款），
//      双击或点 ▶ 起播，右键走 `TrackActions.libraryRow()`。

@MainActor
final class LibraryArtistsViewController: ContentPageController, NSSplitViewDelegate,
                                          LibraryArtistSelecting {

    private typealias M = MusicMetrics.LibraryArtists

    private let model: LibraryPageModel
    private static let allArtistsID = "all"

    // 核心视图
    private var splitView: NSSplitView!
    private var leftTableView: NSTableView!
    private var emptyLibraryHost: NSView?

    // 右侧视图
    private var rightContainer: NSView!
    private var emptyDetailLabel: NSTextField!
    private var detailContainer: NSView!
    private var headerView: LibraryArtistHeaderView!
    /// 「所有艺人」时固定头收掉（组头改由表格的行来出），所以高度要可变。
    private var headerHeightConstraint: NSLayoutConstraint!
    private var detailTableView: NSTableView!

    // 数据缓存
    /// 左列真正在列的那份：`allLibraryArtists` 过了「仅喜爱」与搜索、再排序。
    private var artists: [Artist] = []
    /// 资料库里全部的艺人，**一次 refresh 现算一次、这一页全程复用**。
    ///
    /// `LibraryStore.libraryArtists()` 是现算的派生量（从入库专辑与曲目的艺人名去重
    /// 派生），而这一页从前一轮刷新里要问它 **6 次**：`refreshData()` 自己一次、
    /// `updateDetailContent()` 按 id 找当前那位一次、`resolveAvatars()` 一次，
    /// 外加播放、切喜爱、弹 ⋯ 菜单三处各一次。它下沉到 SQL 之后，那就是 6 次查询。
    ///
    /// 按 id 找人的那四处用这份缓存而不是现问，还顺带把一致性钉死了：用户点的是
    /// **屏幕上这一份**，动作落到的也就该是这一份，而不是「点下去那一刹那库里的那一份」。
    private var allLibraryArtists: [Artist] = []
    private var selectedID: String?
    /// 我们自己往左列写选中时置位，免得代理回调把这一下再回灌进 `selectedID`
    /// （照侧栏 `SidebarOutlineController.isSyncing` 的写法）。
    ///
    /// 缺了它，`restoreSelection()` 里那句`deselectAll(nil)` 会经代理把`selectedID`
    /// 清成 nil，与它自己那句注释「保持 selectedID 但表格无选中」正相反：
    /// 搜一个不匹配当前艺人的词就**永久**丢掉选中，清空搜索也回不来
    /// （nil 会被 `refreshData()` 兜成「所有艺人」）。
    private var isSyncing = false
    /// 同一轮 runloop 里的多次刷新请求合并成一次（见 `setNeedsRefresh`）。
    private var pendingRefresh = false
    /// 被 `isHidden` 收着期间攒下的刷新，等 `pageDidAppear()` 补。
    private var needsRefreshWhenShown = false

    /// 左列的行构成：第 0 行固定是「所有艺人」，其后依次是 `artists`。
    /// 行号换算只此一处——从前是四处各写一个字面量 `+1`，置顶行一加减就集体错位。
    private enum LeftRow {
        /// 固定置顶行占掉的行数。
        static let fixedCount = 1
        /// 「所有艺人」那一行。
        static let allArtists = 0
    }

    /// 艺人下标 → 左列行号。
    private func leftRow(forArtistAt index: Int) -> Int { index + LeftRow.fixedCount }

    /// 左列行号 → 艺人下标；落在固定置顶行上（或越界）时给 nil。
    private func artistIndex(forLeftRow row: Int) -> Int? {
        let index = row - LeftRow.fixedCount
        return artists.indices.contains(index) ? index : nil
    }
    /// 详情面的行。选中某位艺人时全是 `.album`；「所有艺人」时按艺人分组，
    /// 每组前插一行 `.artistHeader`（Music 实拍就是这么排的）。
    private enum DetailRow {
        case artistHeader(Artist)
        case album(Album)
    }
    private var detailRows: [DetailRow] = []
    /// 详情面当前呈现的是哪个对象，用来判断这次刷新要不要把滚动拉回顶部。
    private var presentedID: String?
    private var currentAlbums: [Album] = []
    private var resolvedAvatars: [String: String] = [:]
    /// 头像解析的排队作业。见 `resolveAvatars()`：在飞的那一轮不重启，只往队列里补人。
    private var avatarTask: Task<Void, Never>?
    private var avatarQueue: [Artist] = []
    /// 已经排在队列里或正在飞的艺人名，防止同一个人被排两次。
    /// 处理完就摘掉——这一轮没搜到头像的，下一次 `refreshData()` 还会重新排上。
    private var avatarQueuedNames: Set<String> = []
    /// 详情面用来算封面边长的宽度。**行高与专辑块必须读同一个数**：
    /// 行高是 `reloadData` 当场问出来的（那一刻表格可能还没铺开、`bounds.width`
    /// 还是列的最小宽 200），块视图却要等这一轮布局才建（那时已是真宽），
    /// 两边各读各的 `tableView.bounds.width` 就会「行按 200 的封面算高、
    /// 块按真宽排 360 的封面」，封面被行下沿裁掉一截。曲目多的专辑行高由曲目列定，
    /// 盖得住这个差；曲目少的（本地单曲居多）行高正好由封面定，于是只有它们露馅。
    private var detailLayoutWidth: CGFloat = 0
    /// 详情表 frame 变更的观察者令牌（见 `buildSplitView()` 里挂的那条）。
    private var detailFrameObserver: (any NSObjectProtocol)?

    /// 音轨行的选中（Music：单击行＝选中，红底跟选中走，与播放态同一套红）。
    /// 音轨不是 `NSTableView` 的行（表格一行 = 一张专辑块），所以自己记 id。
    private var selectedTrackID: String?

    // 工具栏
    private lazy var binder = SearchFieldBinder(text: { [model] in model.search }) { [weak self] text in
        self?.model.search = text
    }
    private lazy var filterMenuController = LibraryArtistFilterMenuController(model: model)

    init(appState: AppState, model: LibraryPageModel) {
        self.model = model
        super.init(nativePage: appState)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 观察者令牌不是 `Sendable`，非隔离的 `deinit` 取不到它。标 `isolated`：
    /// 主线程上释放时照旧同步跑完，注销时机不变（同 `CatalogPageViewController`）。
    isolated deinit {
        avatarTask?.cancel()
        if let detailFrameObserver {
            NotificationCenter.default.removeObserver(detailFrameObserver)
        }
    }

    // MARK: - 工具栏

    override var pageToolbarItemIdentifiers: [NSToolbarItem.Identifier] {
        [.amberPageTitle, .flexibleSpace, .amberFilter, .amberSearch]
    }

    /// **不摆。** 显式写在这里而不是靠基类默认值，是要把这条反例留在代码里：
    /// [AX] `library-artist-detail.json` 实测这一页**有返回键（x=206.5）却两件都没有**，
    /// 右端只有排序选项 x=1208 与搜索 x=1255。它是「按栈深判就会想当然加上」的那一页
    /// ——和心水歌曲（没有返回键却有「更多」）正好是一对反例，
    /// 两条一起钉死「右端两件是页面自己的属性，不是导航深度的函数」
    /// （[实测] §10.1，macOS 27 / 26A5425a 基线）。
    override var pageShowsToolbarActions: Bool { false }

    override func makePageToolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case .amberPageTitle:
            return ContentToolbarItems.title("艺人")
        case .amberFilter:
            return ContentToolbarItems.filter(menu: filterMenuController.menu)
        case .amberSearch:
            return ContentToolbarItems.search(placeholder: "在艺人中查找", binder: binder)
        default:
            return nil
        }
    }

    // MARK: - 生命周期

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        container.wantsLayer = true
        view = container

        buildSplitView()
        bind()
        refreshData()
    }

    override func pageDidAppear() {
        super.pageDidAppear()
        // 切回来：被压住期间攒下的那次资料库变动在这里补上（见 `setNeedsRefresh`）。
        if needsRefreshWhenShown {
            needsRefreshWhenShown = false
            refreshData()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let leftWidth = leftTableView?.bounds.width, leftWidth > 0 {
            leftTableView?.tableColumns.first?.width = leftWidth
        }
        syncDetailWidth()
    }

    /// 详情面宽度变了：记下来、列宽跟上，并让**行高与在场的专辑块**按同一个宽度重排。
    /// 两条路驱动：`viewDidLayout`，以及表格自己的 frame 变更通知——页面被
    /// `isHidden` 收着时不走布局回调（`ContentNavigationController` 切页只切
    /// `isHidden`），只有通知这条还在。
    private func syncDetailWidth() {
        guard let table = detailTableView else { return }
        let width = table.bounds.width
        guard width > 0, abs(width - detailLayoutWidth) > 1 else { return }
        detailLayoutWidth = width
        table.tableColumns.first?.width = width
        // 分组视图里行不只是专辑（还有艺人组头），范围要按 detailRows 来
        if !detailRows.isEmpty {
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<detailRows.count))
        }
        for case let cell as LibraryArtistAlbumBlockCell in table.subviews(ofType: LibraryArtistAlbumBlockCell.self) {
            cell.updateLayout(forWidth: width)
        }
    }

    // MARK: - 搭建 SplitView

    private func buildSplitView() {
        splitView = NSSplitView(frame: view.bounds)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = NSSplitView.AutosaveName("listAndDetailsSplitView")
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false

        // 左侧栏
        let leftContainer = NSView(frame: NSRect(x: 0, y: 0, width: M.listWidth, height: view.bounds.height))
        leftContainer.translatesAutoresizingMaskIntoConstraints = false

        let leftScrollView = NSScrollView()
        leftScrollView.drawsBackground = false
        leftScrollView.hasVerticalScroller = true
        leftScrollView.autohidesScrollers = true
        leftScrollView.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("artist"))
        col.resizingMask = .autoresizingMask
        col.minWidth = 100
        col.maxWidth = .greatestFiniteMagnitude
        col.width = M.listWidth

        leftTableView = NSTableView()
        leftTableView.headerView = nil
        leftTableView.backgroundColor = .clear
        leftTableView.style = .plain
        leftTableView.rowHeight = M.rowHeight
        leftTableView.intercellSpacing = .zero
        leftTableView.addTableColumn(col)
        leftTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        leftTableView.dataSource = self
        leftTableView.delegate = self
        leftTableView.selectionHighlightStyle = .regular
        leftTableView.allowsMultipleSelection = false

        leftScrollView.documentView = leftTableView
        leftScrollView.additionalSafeAreaInsets = NSEdgeInsets(
            top: 0, left: 0, bottom: MusicMetrics.MiniPlayer.scrollReserve, right: 0)
        leftContainer.addSubview(leftScrollView)

        NSLayoutConstraint.activate([
            leftScrollView.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor),
            leftScrollView.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor),
            leftScrollView.topAnchor.constraint(equalTo: leftContainer.topAnchor),
            leftScrollView.bottomAnchor.constraint(equalTo: leftContainer.bottomAnchor),
        ])

        // 右侧栏
        rightContainer = NSView(frame: NSRect(x: M.listWidth + 1, y: 0, width: max(0, view.bounds.width - M.listWidth - 1), height: view.bounds.height))
        rightContainer.translatesAutoresizingMaskIntoConstraints = false

        emptyDetailLabel = NSTextField(labelWithString: M.emptyDetailTitle)
        emptyDetailLabel.font = .systemFont(ofSize: 22, weight: .medium)
        emptyDetailLabel.textColor = .secondaryLabelColor
        emptyDetailLabel.alignment = .center
        emptyDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        rightContainer.addSubview(emptyDetailLabel)

        detailContainer = NSView()
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.isHidden = true
        rightContainer.addSubview(detailContainer)

        headerView = LibraryArtistHeaderView()
        headerHeightConstraint = headerView.heightAnchor.constraint(equalToConstant: M.headerHeight)
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.onPlay = { [weak self] in self?.play(shuffled: false) }
        headerView.onShuffle = { [weak self] in self?.play(shuffled: true) }
        headerView.onToggleFavorite = { [weak self] in self?.toggleFavoriteArtist() }
        headerView.onMore = { [weak self] anchor in self?.showHeaderMoreMenu(anchor: anchor) }
        detailContainer.addSubview(headerView)

        let detailScrollView = NSScrollView()
        detailScrollView.drawsBackground = false
        detailScrollView.hasVerticalScroller = true
        detailScrollView.autohidesScrollers = true
        detailScrollView.automaticallyAdjustsContentInsets = false
        detailScrollView.additionalSafeAreaInsets = NSEdgeInsets(
            top: 0, left: 0, bottom: MusicMetrics.MiniPlayer.scrollReserve, right: 0)
        detailScrollView.translatesAutoresizingMaskIntoConstraints = false

        let detailCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("albumBlock"))
        detailCol.resizingMask = .autoresizingMask
        detailCol.minWidth = 200
        detailCol.maxWidth = .greatestFiniteMagnitude

        detailTableView = NSTableView()
        detailTableView.headerView = nil
        detailTableView.backgroundColor = .clear
        detailTableView.style = .plain
        detailTableView.selectionHighlightStyle = .none
        detailTableView.intercellSpacing = .zero
        detailTableView.addTableColumn(detailCol)
        detailTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        detailTableView.dataSource = self
        detailTableView.delegate = self

        detailScrollView.documentView = detailTableView
        detailContainer.addSubview(detailScrollView)

        // 表格被滚动容器铺开／窗口拉宽都会改它的 frame，而这时页面不一定走布局回调。
        // 宽度是行高的入参（见 `detailLayoutWidth`），所以直接盯着它变。
        //
        // 块式观察者而不是 `for await`：拉窗框是**每帧**发一条，而 `syncDetailWidth()`
        // 当场要 `noteHeightOfRows` 并把在场的专辑块按新宽度重排。多绕一跳 await
        // 就成了「列已经宽了、行高与封面慢一帧」，拖动边框时看得见抖。
        // 闭包是 `@Sendable`；`queue: .main` 把投递线程钉死在主线程，
        // 所以用 `assumeIsolated` 接回主 actor 隔离的自己。
        detailTableView.postsFrameChangedNotifications = true
        detailFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: detailTableView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.syncDetailWidth() } }

        NSLayoutConstraint.activate([
            emptyDetailLabel.centerXAnchor.constraint(equalTo: rightContainer.centerXAnchor),
            emptyDetailLabel.centerYAnchor.constraint(equalTo: rightContainer.centerYAnchor),

            detailContainer.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            detailContainer.topAnchor.constraint(equalTo: rightContainer.topAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor),

            headerView.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: detailContainer.safeAreaLayoutGuide.topAnchor),
            headerHeightConstraint,

            detailScrollView.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detailScrollView.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            detailScrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            detailScrollView.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])

        splitView.addArrangedSubview(leftContainer)
        splitView.addArrangedSubview(rightContainer)

        view.addSubview(splitView)

        let leftWidthConstraint = leftContainer.widthAnchor.constraint(equalToConstant: M.listWidth)
        leftWidthConstraint.priority = NSLayoutConstraint.Priority(499)

        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            leftContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            leftContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 350),
            leftWidthConstraint,
        ])

        splitView.adjustSubviews()
    }

    // MARK: - 数据绑定与刷新

    private func bind() {
        let library = appState.library
        // 这一页真正读的：曲目与专辑（`libraryArtists()` / `albums(byArtist:)` /
        // `tracks(in:)` 都从这两份派生）、艺人喜爱（左列尾随 ★ 与头部那枚）、
        // 专辑喜爱（「仅喜爱」筛的正是「这位艺人有没有被喜爱的碟」）、
        // 评分（专辑块与音轨行的五星是 `configure` 时读进去的，星控件自己不写回）。
        // 从前订的是 `library.objectWillChange` ——记一次播放、改一条勾选
        // 都会让左表与右表各重灌一遍。
        let changes = library.changes(affecting: [.tracks, .albums, .favoriteArtists,
                                    .favoriteAlbums, .ratings])
        observers.add(Task { @MainActor [weak self] in
            for await _ in changes {
                self?.setNeedsRefresh()
            }
        })

        // `@Observable` 没有 `objectWillChange` 那条「随便什么变了」的信号——这是好事，
        // 它正是「一次入库把资料库四页全量重算一遍」的由来。这里把本页真读的三项装成
        // 一个快照：与原来等价，而与它们无关的写入不再把这一页叫醒。
        observers.observeAny({ [model] in (model.favoritesOnly, model.search, model.sort) }) { [weak self] in self?.setNeedsRefresh() }

        // 这一页真读的只有「哪首在播、播没播」，不是整台播放器。
        observers.observeAny({ [appState] in
            (appState.player.currentIndex, appState.player.queue, appState.player.isPlaying)
        }) { [weak self] in
            self?.refreshTrackStates()
        }

        // 下载列要跟着进度走：`DownloadStore.states` 每整百分点发一次
        observers.observe({ [appState] in appState.downloads.states }) { [weak self] _ in
            self?.refreshTrackStates()
        }
    }

    /// 刷新入口：合批 + 可见性闸。
    ///
    /// **合批**照歌曲页那条（`LibrarySongsViewController.setNeedsRefresh`）：这一页一次
    /// `refreshData()` 是左表 + 右表**各一遍** `reloadData()`，来几声就刷几遍代价最大。
    /// （推迟到下一轮那半条理由已经没了：`model` 那几项走`Observations`，值落定之后
    /// 才发；合批留着是为了「一轮里来几声只刷一遍」。）
    ///
    /// **可见性闸**：导航容器把访问过的根页全缓存着、切页只切 `isHidden`，
    /// 隐藏的页重排一遍没人看得见，只记一笔等 `pageDidAppear()` 补。
    private func setNeedsRefresh() {
        guard let view = viewIfLoaded, !view.isHiddenOrHasHiddenAncestor else {
            needsRefreshWhenShown = true
            return
        }
        guard !pendingRefresh else { return }
        pendingRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingRefresh = false
            self.refreshData()
        }
    }

    private func refreshData() {
        let library = appState.library
        // 这一轮刷新的那一份，下面与几处动作路径全用它（见 `allLibraryArtists`）。
        allLibraryArtists = library.libraryArtists()

        if allLibraryArtists.isEmpty {
            splitView.isHidden = true
            showEmptyLibraryView()
            return
        }

        splitView.isHidden = false
        emptyLibraryHost?.isHidden = true

        var list = allLibraryArtists
        if model.favoritesOnly {
            list = list.filter { artist in
                library.albums(byArtist: artist.name).contains { !library.tracks(in: $0).isEmpty && library.isFavoriteAlbum($0) }
            }
        }
        // 索引里艺人那一档的 id 与这里派生出来的是同一批（都出自
        // `LibraryStore.artists(from:)`，见 `LibrarySearchIndex.derivedArtists`）。
        let matches = library.searchFilter(model.search, kind: .artist)
        list = list.filter { matches.keeps($0.id, [$0.name]) }
        list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        artists = list
        leftTableView.reloadData()

        // 重新核对选中态：首次若无选中则默认选中「所有艺人」，保证首屏有内容呈现
        if selectedID == nil && !artists.isEmpty {
            selectedID = Self.allArtistsID
        }
        restoreSelection()
        updateDetailContent()
        resolveAvatars()
    }

    private func showEmptyLibraryView() {
        if emptyLibraryHost == nil {
            let host = appState.hostingView {
                MusicEmptyStateContent(message: "资料库中的艺人会显示在这里。", systemImage: "music.mic")
            }
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.topAnchor.constraint(equalTo: view.topAnchor),
                host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            emptyLibraryHost = host
        }
        emptyLibraryHost?.isHidden = false
    }

    /// 把 `selectedID` 回灌到左列的选中上。**这是程序化写选中**，
    /// 所以整段罩在 `isSyncing` 里：代理不该把我们自己写的这一下再解释成
    /// 「用户改了选中」，尤其是下面那句 `deselectAll(nil)`（见`isSyncing` 的注释）。
    private func restoreSelection() {
        isSyncing = true
        defer { isSyncing = false }
        guard let selectedID else {
            leftTableView.deselectAll(nil)
            return
        }
        if selectedID == Self.allArtistsID {
            leftTableView.selectRowIndexes(IndexSet(integer: LeftRow.allArtists),
                                           byExtendingSelection: false)
            return
        }
        if let idx = artists.firstIndex(where: { $0.id == selectedID }) {
            leftTableView.selectRowIndexes(IndexSet(integer: leftRow(forArtistAt: idx)),
                                           byExtendingSelection: false)
        } else {
            // 搜索过滤后当前选中者被移除了，保持 selectedID 但表格无选中
            leftTableView.deselectAll(nil)
        }
    }

    /// 「跳到这位艺人」。由 `ContentNavigationController` 沿导航意图交下来
    /// （`AGENTS.md` 界面层铁律 4；从前是 `AppState.pendingLibraryArtistID` 那只信箱，
    /// 页面自己订着它、收到再写回 nil）。
    ///
    /// 交下来的时机由导航控制器保证：它先 `setRoot(for: .artists)` 把这一页装上，
    /// 换根路过 `loadView` / `pageDidAppear`，`artists` 已经是现算好的那一份，
    /// 下面 `restoreSelection()` 立刻就能按 id 找到行。
    func selectLibraryArtist(id: String) {
        selectedID = id
        restoreSelection()
        if let selectedRow = leftTableView.selectedRowIndexes.first {
            leftTableView.scrollRowToVisible(selectedRow)
        }
        updateDetailContent()
    }

    // MARK: - 详情面呈现

    private func updateDetailContent() {
        guard let selectedID else {
            emptyDetailLabel.isHidden = false
            detailContainer.isHidden = true
            return
        }

        emptyDetailLabel.isHidden = true
        detailContainer.isHidden = false

        let library = appState.library
        let isAll = selectedID == Self.allArtistsID

        if isAll {
            // Music 的「所有艺人」是**分组视图**：每位艺人一个组头（名字 + 四枚钮 +
            // 细线，无副标题），组头下面是他自己的专辑块。没有一个叫「所有艺人」的大标题，
            // 所以固定头整个收掉，组头由表格的行出。
            headerView.isHidden = true
            headerHeightConstraint.constant = 0
            var rows: [DetailRow] = []
            var albums: [Album] = []
            for artist in artists {
                let owned = library.albums(byArtist: artist.name).filter { !library.tracks(in: $0).isEmpty }
                guard !owned.isEmpty else { continue }
                rows.append(.artistHeader(artist))
                rows.append(contentsOf: owned.map { DetailRow.album($0) })
                albums.append(contentsOf: owned)
            }
            detailRows = rows
            currentAlbums = albums
        } else {
            headerView.isHidden = false
            headerHeightConstraint.constant = M.headerHeight
            let artist = allLibraryArtists.first(where: { $0.id == selectedID })
            let artistName = artist?.name ?? ""
            currentAlbums = library.albums(byArtist: artistName).filter { !library.tracks(in: $0).isEmpty }
            detailRows = currentAlbums.map { DetailRow.album($0) }
            let trackCount = currentAlbums.reduce(0) { $0 + library.tracks(in: $1).count }
            headerView.configure(title: artistName,
                                 subtitle: "\(currentAlbums.count)张专辑，\(trackCount)首歌曲")
            headerView.setFavorite(visible: artist != nil,
                                   isFavorite: artist.map(library.isFavoriteArtist) ?? false)
        }
        // 换没换呈现对象，决定「清音轨选中」与「滚回顶部」这两件；留在同一位艺人上时
        // 两件都不做。音轨行的红底从前是无条件清的（写在这个方法开头），于是任何一次
        // 资料库变动——这一页还订着曲目/专辑/喜爱/评分——都会把用户刚点亮的那一行抹掉。
        let switchedTarget = presentedID != selectedID
        // 清在 reloadData 之前：行是靠 `configure(selectedTrackID:)` 把红底吃进去的。
        if switchedTarget { selectedTrackID = nil }
        detailTableView.reloadData()
        if switchedTarget {
            presentedID = selectedID
            if !detailRows.isEmpty { detailTableView.scrollRowToVisible(0) }
        }
    }

    /// `artist` 为 nil ＝对整个详情面（选中某位艺人时就是他自己）；
    /// 「所有艺人」的分组头传各自那位。
    private func play(shuffled: Bool, artist: Artist? = nil) {
        let library = appState.library
        let albums = artist.map { library.albums(byArtist: $0.name).filter { !library.tracks(in: $0).isEmpty } } ?? currentAlbums
        let allTracks = albums.flatMap { library.tracks(in: $0) }
        guard !allTracks.isEmpty else {
            appState.showToast("该艺人暂无可播放的歌曲")
            return
        }
        // 队列面板「继续播放」分区头的「来自《…》」＝这位艺人，点它回艺人页。
        // 对整个详情面（没指定艺人）时落到当前选中的那位；「所有艺人」那档没有单一落点。
        let selected = selectedID.flatMap { id in
            id == Self.allArtistsID ? nil : allLibraryArtists.first { $0.id == id }
        }
        let source = (artist ?? selected).map {
            PlayerController.QueueSource(title: $0.name, route: .artist($0))
        }
        if shuffled {
            appState.player.play(allTracks.shuffled(), source: source)
        } else {
            appState.player.play(allTracks, startAt: 0, source: source)
        }
    }

    private func toggleFavoriteArtist(_ artist: Artist? = nil) {
        let library = appState.library
        let target: Artist?
        if let artist {
            target = artist
        } else {
            guard let selectedID, selectedID != Self.allArtistsID else { return }
            target = allLibraryArtists.first(where: { $0.id == selectedID })
        }
        guard let target else { return }
        library.toggleFavoriteArtist(target)

        // 左列那一行的尾随 ★
        if let index = artists.firstIndex(where: { $0.id == target.id }) {
            leftTableView.reloadData(forRowIndexes: IndexSet(integer: leftRow(forArtistAt: index)),
                                     columnIndexes: IndexSet(integer: 0))
        }
        // 详情面的 ★：固定头直接改，分组头只重配那一行
        if selectedID == Self.allArtistsID {
            if let row = detailRows.firstIndex(where: {
                if case .artistHeader(let a) = $0 { return a.id == target.id }
                return false
            }) {
                detailTableView.reloadData(forRowIndexes: IndexSet(integer: row),
                                           columnIndexes: IndexSet(integer: 0))
            }
        } else {
            headerView.setFavorite(visible: true, isFavorite: library.isFavoriteArtist(target))
        }
    }

    /// 头部 ⋯：播放 / 随机播放 / 喜爱（与圆钮同集，照 Music 的「更多」语义）。
    /// 项序走 `CollectionActions`——这里只报「这位艺人能做什么」。
    ///
    /// 从前菜单项走 target-action，得先把「这次是对哪位艺人」记进 `menuArtist` 再弹；
    /// 现在闭包自己捕获 `artist`，那份状态连同三个`@objc` 桩一起没了。
    private func showHeaderMoreMenu(anchor: NSView, artist: Artist? = nil) {
        let library = appState.library
        var actions = CollectionActions()
        actions.play = { [weak self] in self?.play(shuffled: false, artist: artist) }
        actions.shuffle = { [weak self] in self?.play(shuffled: true, artist: artist) }

        let target = artist ?? allLibraryArtists.first(where: { $0.id == selectedID })
        if let target, selectedID != Self.allArtistsID || artist != nil {
            if library.isFavoriteArtist(target) {
                actions.undoFavorite = { [weak self] in self?.toggleFavoriteArtist(target) }
            } else {
                actions.favorite = { [weak self] in self?.toggleFavoriteArtist(target) }
            }
            actions.shareURL = target.webShareURL
            // 「减少推荐」只对音源里的艺人成立：资料库这一页大多是按名字归出来的
            // 派生艺人（`library-artist:`），那种`canSuggestLess` 报 false，整对不摆。
            if appState.canSuggestLess(artist: target, less: true) {
                actions.suggestLess = { [weak self] in
                    self?.appState.suggestLess(artist: target, less: true)
                }
            }
            if appState.canSuggestLess(artist: target, less: false) {
                actions.undoSuggestLess = { [weak self] in
                    self?.appState.suggestLess(artist: target, less: false)
                }
            }
        }
        guard let menu = actions.makeMenu() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.midX, y: anchor.bounds.height + 2),
                   in: anchor)
    }

    /// 当前高亮的那一首。`selectedTrackID` 记的是 id，而「显示简介」要的是整条曲目——
    /// 回资料库那份内存快照里取（这一页的行本来就全部出自它，`tracks(in:)` 也是从它派生）。
    private func selectedTrack() -> Track? {
        guard let selectedTrackID else { return nil }
        return appState.library.libraryTracks.first { $0.id == selectedTrackID }
    }

    /// 「文件 ▸ 显示简介」（⌘I）。选择器与 `TrackTableViewController.amberGetInfo(_:)`
    /// 同名，走的是同一条响应链——哪一页在前面就由哪一页接。
    ///
    /// 这一页从前没实现它，于是 ⌘I 在「资料库 › 艺人」上恒灰，而同一行右键里的
    /// 「显示简介」是亮的（行菜单走 `TrackActions.libraryRow()`，不经响应链）
    /// ——同一件事两个答案。
    ///
    /// **作用集是当前高亮的那一行**：这一页的音轨行同时只有一行选中
    /// （`selectTrack(_:)` 一进一出），没有多选态要考虑，也就不必像
    /// `TrackTableViewController` 那样为多选留一句「先只开第一首」。
    @objc func amberGetInfo(_ sender: Any?) {
        guard let track = selectedTrack() else { return }
        AuxiliaryWindows.shared.showInfoPanel(tracks: [track])
    }

    /// 音轨行的选中落点：整页同时只有一行选中，刷新所有可见块。
    func selectTrack(_ id: String?) {
        guard selectedTrackID != id else { return }
        selectedTrackID = id
        refreshTrackStates()
    }

    private func refreshTrackStates() {
        for case let cell as LibraryArtistAlbumBlockCell in detailTableView.subviews(ofType: LibraryArtistAlbumBlockCell.self) {
            cell.setSelectedTrack(selectedTrackID)
            cell.refreshPlayingState()
            cell.refreshDownloadState()
        }
    }

    // MARK: - 头像异步解析

    /// 把还没有头像的艺人排进解析队列，**已经在跑就别重启**。
    ///
    /// 从前这里是 `avatarTask?.cancel()` 后整批重来，而它由每次`refreshData()` 尾部调用：
    /// 资料库连续变动（导入、账号同步、回填）期间每一声都把在飞的那次搜索砍掉重排，
    /// 队伍永远从头开始——头像一个都解析不出来。改成「一条队伍、一个消费者」之后，
    /// 新增的艺人只是接在队尾，已经搜到的那些不会被重搜。
    ///
    /// 这一轮没搜到头像的（音源查无此人、或者网络当时不通）会在处理完时从
    /// `avatarQueuedNames` 里摘掉，下一次`refreshData()` 还会重新排上——与从前同。
    private func resolveAvatars() {
        let pending = allLibraryArtists.filter {
            resolvedAvatars[$0.name] == nil && !avatarQueuedNames.contains($0.name)
        }
        guard !pending.isEmpty else { return }
        avatarQueue.append(contentsOf: pending)
        for artist in pending { avatarQueuedNames.insert(artist.name) }
        // 已经有消费者在跑：新人已经排进队列了，不要再起一条。
        guard avatarTask == nil else { return }
        avatarTask = Task { [weak self] in
            await self?.drainAvatarQueue()
        }
    }

    /// 队列的唯一消费者。整个方法是主线程隔离的（类上 `@MainActor`），
    /// `await` 挂起后回到主线程继续，所以读写`avatarQueue` / `resolvedAvatars`
    /// 不再需要往 `MainActor.run` 里塞。
    private func drainAvatarQueue() async {
        defer { avatarTask = nil }
        while !avatarQueue.isEmpty {
            guard !Task.isCancelled else { return }
            let artist = avatarQueue.removeFirst()
            let hits = (try? await appState.provider(artist.kind)
                .searchArtists(keyword: artist.name, limit: 3, offset: 0)) ?? []
            avatarQueuedNames.remove(artist.name)
            let match = hits.first { $0.name == artist.name } ?? hits.first
            guard let avatar = match?.avatarURL else { continue }
            resolvedAvatars[artist.name] = avatar
            guard let index = artists.firstIndex(where: { $0.name == artist.name }) else { continue }
            leftTableView.reloadData(forRowIndexes: IndexSet(integer: leftRow(forArtistAt: index)),
                                     columnIndexes: IndexSet(integer: 0))
        }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        150
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        350
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        if view === splitView.arrangedSubviews.first, view.bounds.width < 150 {
            return true
        }
        return view === rightContainer
    }
}

// MARK: - NSTableViewDataSource & NSTableViewDelegate

extension LibraryArtistsViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === leftTableView {
            return LeftRow.fixedCount + artists.count
        } else {
            return detailRows.count
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView === leftTableView {
            return M.rowHeight
        } else {
            guard case .album(let album) = detailRows[row] else { return M.groupHeaderHeight }
            let tracks = appState.library.tracks(in: album)
            let artworkWidth = LibraryArtistAlbumBlockCell.artworkWidth(forDetailWidth: detailLayoutWidth)
            let rightContentHeight = M.blockTopPadding + M.blockArtworkTopToTracks + CGFloat(tracks.count) * M.trackRowHeight
            return max(M.blockTopPadding + artworkWidth, rightContentHeight) + M.blockSpacing
        }
    }

    /// 左列的行底分割线画在行视图里（选中填充之下，见 `LibraryArtistRowView`）。
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView === leftTableView ? LibraryArtistRowView() : nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === leftTableView {
            let identifier = NSUserInterfaceItemIdentifier("LibraryArtistRowCellView")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? LibraryArtistRowCellView
                ?? LibraryArtistRowCellView(identifier: identifier)

            // 落不到艺人下标上的就是固定置顶那一行（见 `LeftRow`）。
            if let index = artistIndex(forLeftRow: row) {
                let artist = artists[index]
                cell.configure(title: artist.name,
                               avatarURL: resolvedAvatars[artist.name],
                               isAll: false,
                               isFavorite: appState.library.isFavoriteArtist(artist))
            } else {
                cell.configure(title: M.allArtistsRowTitle, avatarURL: nil, isAll: true, isFavorite: false)
            }
            return cell
        }

        switch detailRows[row] {
        case .artistHeader(let artist):
            let identifier = NSUserInterfaceItemIdentifier("LibraryArtistGroupHeaderCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? LibraryArtistGroupHeaderCell
                ?? LibraryArtistGroupHeaderCell(identifier: identifier)
            cell.configure(artist: artist,
                           isFavorite: appState.library.isFavoriteArtist(artist),
                           onPlay: { [weak self] in self?.play(shuffled: false, artist: artist) },
                           onShuffle: { [weak self] in self?.play(shuffled: true, artist: artist) },
                           onToggleFavorite: { [weak self] in self?.toggleFavoriteArtist(artist) },
                           onMore: { [weak self] anchor in
                               self?.showHeaderMoreMenu(anchor: anchor, artist: artist)
                           })
            return cell

        case .album(let album):
            let identifier = NSUserInterfaceItemIdentifier("LibraryArtistAlbumBlockCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? LibraryArtistAlbumBlockCell
                ?? LibraryArtistAlbumBlockCell(identifier: identifier)

            let tracks = appState.library.tracks(in: album)
            // 分组视图里艺人名已经写在组头上了，信息行就不再重复（Music：「Mandopop · 2020」）
            cell.configure(album: album,
                           tracks: tracks,
                           showsArtistName: false,
                           tableWidth: detailLayoutWidth,
                           selectedTrackID: selectedTrackID,
                           onSelectTrack: { [weak self] id in self?.selectTrack(id) },
                           appState: appState)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView, tableView === leftTableView else { return }
        // 我们自己写进去的那一下不回灌（见 `isSyncing`）。
        guard !isSyncing else { return }
        let row = tableView.selectedRow
        if row < 0 {
            selectedID = nil
        } else if row == LeftRow.allArtists {
            selectedID = Self.allArtistsID
        } else if let index = artistIndex(forLeftRow: row) {
            selectedID = artists[index].id
        } else {
            return
        }
        updateDetailContent()
    }
}

// MARK: - 圆钮

/// 资料库艺人页的圆钮（头部 ▶/⤨/★/⋯、专辑块 ↓/⋯ 共用）。
/// 与目录页的 `ArtistCircleButton` 同一手法，但底是这一页实测的 5% 白
/// （`circleButtonFillAlpha`，PNG 43 → 53），目录页那档 20% secondary 在这里太亮。
/// `.brand` 档给收藏态：品牌红实心圆 + 黑字形。
@MainActor
private final class LibraryCircleButton: NSButton {

    enum Style {
        /// 5% 白圆底 + 着色字形
        case subtle
        /// 品牌红实心圆 + 黑字形（头部收藏态）
        case brand
        /// 透底 + 品牌红描边圆 + 红字形（专辑块「停止下载」那枚）
        case ring
    }

    var onClick: (() -> Void)?
    /// 悬浮反馈只用整体透明度（与目录卡同一档轻反馈），不改色不缩放。
    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?
    /// 收藏态整枚换底色（品牌红圆 + 黑星），所以 style 要可变。
    var style: Style {
        didSet { applyColors() }
    }
    private let glyphSize: CGFloat
    private let glyph = NSImageView()

    init(style: Style, diameter: CGFloat, symbol: String, glyphSize: CGFloat,
         weight: NSFont.Weight = .semibold) {
        self.style = style
        self.glyphSize = glyphSize
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        // 两处宿主（头部 / 专辑块）都用约束摆位；不关掉自动尺寸约束，
        // AppKit 会按 frame 生成一组必需约束，把整枚钉在容器原点，
        // 并顺带把与它相关的标题、细线、标题组挤成 0 宽 / 0 高。
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .shadowlessSquare
        title = ""
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.masksToBounds = true
        target = self
        action = #selector(clicked)

        glyph.imageScaling = .scaleNone
        glyph.frame = bounds
        glyph.autoresizingMask = [.width, .height]
        addSubview(glyph)
        setSymbol(symbol, weight: weight)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: bounds.width, height: bounds.height) }

    func setSymbol(_ name: String, weight: NSFont.Weight = .semibold) {
        glyph.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: glyphSize, weight: weight))
        glyph.contentTintColor = glyphColor
    }

    var glyphColor: NSColor = .labelColor {
        didSet { glyph.contentTintColor = glyphColor }
    }

    @objc private func clicked() { onClick?() }

    // MARK: 悬浮 / 按下

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyFeedback() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyFeedback() }

    /// `super.mouseDown` 自带跟踪循环（抬手仍在盒内才发 action），按下态在它前后各刷一次。
    override func mouseDown(with event: NSEvent) {
        pressed = true
        applyFeedback()
        super.mouseDown(with: event)
        pressed = false
        applyFeedback()
    }

    private func applyFeedback() {
        alphaValue = pressed ? 0.6 : (hovering ? 0.85 : 1)
    }

    // MARK: 底色

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            switch style {
            case .subtle:
                layer?.backgroundColor = NSColor.white.withAlphaComponent(
                    MusicMetrics.LibraryArtists.circleButtonFillAlpha).cgColor
                layer?.borderWidth = 0
            case .brand:
                layer?.backgroundColor = NSColor(Color.amberKey).cgColor
                layer?.borderWidth = 0
            case .ring:
                layer?.backgroundColor = NSColor.clear.cgColor
                layer?.borderColor = NSColor(Color.amberKey).cgColor
                layer?.borderWidth = MusicMetrics.LibraryArtists.circleButtonRingWidth
            }
        }
    }
}

// MARK: - 左侧行视图（行底分割线）

/// 分割线画在行视图而不是 cell：这样画线时看得到 `isHighlighted`，
/// 选中填充（NSTableRowView 自己画）把线盖住——Music 里选中行看不见分割线。
@MainActor
private final class LibraryArtistRowView: NSTableRowView {

    private typealias M = MusicMetrics.LibraryArtists

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !isSelected else { return }
        // [PX] 从文字列起到行右沿（rowSeparatorLeading），1pt。
        let line = NSRect(x: M.rowSeparatorLeading, y: bounds.height - 1,
                          width: max(0, bounds.width - M.rowSeparatorLeading), height: 1)
        NSColor.separatorColor.setFill()
        line.fill()
    }
}

// MARK: - 左侧艺人单元格

@MainActor
private final class LibraryArtistRowCellView: NSTableCellView {

    private typealias M = MusicMetrics.LibraryArtists

    private let avatarContainer = NSView()
    private let avatarArtwork = CatalogArtworkView()
    private let placeholderIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let favoriteStar = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        avatarContainer.wantsLayer = true
        avatarContainer.layer?.cornerRadius = M.avatarSize / 2
        avatarContainer.layer?.masksToBounds = true
        avatarContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(avatarContainer)

        avatarArtwork.cornerRadius = M.avatarSize / 2
        avatarArtwork.translatesAutoresizingMaskIntoConstraints = false
        avatarContainer.addSubview(avatarArtwork)

        placeholderIcon.imageScaling = .scaleNone
        placeholderIcon.contentTintColor = .secondaryLabelColor
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        avatarContainer.addSubview(placeholderIcon)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // 喜爱艺人的尾星（品牌红实心，跟在名字后；Music 左列同款）
        favoriteStar.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "已喜爱")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        favoriteStar.contentTintColor = NSColor(Color.amberKey)
        favoriteStar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(favoriteStar)

        NSLayoutConstraint.activate([
            avatarContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.rowHorizontalInset),
            avatarContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarContainer.widthAnchor.constraint(equalToConstant: M.avatarSize),
            avatarContainer.heightAnchor.constraint(equalToConstant: M.avatarSize),

            avatarArtwork.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
            avatarArtwork.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
            avatarArtwork.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
            avatarArtwork.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),

            placeholderIcon.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),

            // [AX] 文字左沿 = 行左 + 54（头像 +10…+50）
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.rowTitleLeading),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: favoriteStar.leadingAnchor, constant: -6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            favoriteStar.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            favoriteStar.centerYAnchor.constraint(equalTo: centerYAnchor),
            favoriteStar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -M.rowHorizontalInset),
        ])
    }

    func configure(title: String, avatarURL: String?, isAll: Bool, isFavorite: Bool) {
        titleLabel.stringValue = title
        favoriteStar.isHidden = isAll || !isFavorite
        if isAll {
            avatarContainer.layer?.backgroundColor = NSColor.clear.cgColor
            avatarArtwork.isHidden = true
            placeholderIcon.isHidden = false
            placeholderIcon.image = NSImage(systemSymbolName: "music.mic", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        } else if let avatarURL {
            avatarContainer.layer?.backgroundColor = NSColor.clear.cgColor
            placeholderIcon.isHidden = true
            avatarArtwork.isHidden = false
            avatarArtwork.setArtwork(url: avatarURL, points: M.avatarSize)
        } else {
            avatarContainer.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            avatarArtwork.isHidden = true
            placeholderIcon.isHidden = false
            placeholderIcon.image = NSImage(systemSymbolName: "music.mic", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        }
    }
}

// MARK: - 详情顶部固定头

/// 标题 + 副标题 + 右上四枚圆钮（▶ / ⤨ / ★ / ⋯）+ 标题行下的细线。
/// [PX] 圆钮 25、间距 11、末枚右沿距详情右沿 32，与标题行居中；
/// 细线左与标题对齐、右与按钮对齐，落在标题与副标题之间（字段底往下 10 ＝窗口 y 117）。
@MainActor
private final class LibraryArtistHeaderView: NSView {

    private typealias M = MusicMetrics.LibraryArtists

    var onPlay: (() -> Void)?
    var onShuffle: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    /// ⋯ 由宿主摆菜单（菜单项要看收藏态），把按钮递过去当锚点。
    var onMore: ((NSView) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let playButton = LibraryCircleButton(style: .subtle, diameter: M.headerButtonDiameter,
                                                 symbol: "play.fill",
                                                 glyphSize: M.headerButtonDiameter * 0.44)
    private let shuffleButton = LibraryCircleButton(style: .subtle, diameter: M.headerButtonDiameter,
                                                    symbol: "shuffle",
                                                    glyphSize: M.headerButtonDiameter * 0.46)
    private let favoriteButton = LibraryCircleButton(style: .subtle, diameter: M.headerButtonDiameter,
                                                     symbol: "star",
                                                     glyphSize: M.headerButtonDiameter * 0.46)
    private let moreButton = LibraryCircleButton(style: .subtle, diameter: M.headerButtonDiameter,
                                                 symbol: "ellipsis",
                                                 glyphSize: M.headerButtonDiameter * 0.42)
    private let hairline = NSBox()
    /// 四枚圆钮装在 `NSStackView` 里：它对`isHidden` 的子视图是**收拢**的
    /// （文档原话：隐藏的排布视图不占位），藏掉 ★ 不会在原地留一个 36pt 的洞。
    /// 早先四枚是 trailing 一枚接一枚手串的，藏一枚就空出一格。
    private let buttonStack = NSStackView()

    private var isFavorite = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    override var isFlipped: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        titleLabel.font = .systemFont(ofSize: M.detailTitleSize, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: M.detailSubtitleSize)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        let red = NSColor(Color.amberKey)
        playButton.glyphColor = red
        playButton.toolTip = "播放"
        playButton.setAccessibilityLabel("播放")
        playButton.onClick = { [weak self] in self?.onPlay?() }
        buttonStack.addArrangedSubview(playButton)

        shuffleButton.glyphColor = red
        shuffleButton.toolTip = "随机播放"
        shuffleButton.setAccessibilityLabel("随机播放")
        shuffleButton.onClick = { [weak self] in self?.onShuffle?() }
        buttonStack.addArrangedSubview(shuffleButton)

        favoriteButton.toolTip = "喜爱"
        favoriteButton.onClick = { [weak self] in self?.onToggleFavorite?() }
        buttonStack.addArrangedSubview(favoriteButton)

        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = M.headerButtonGap
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttonStack)

        moreButton.glyphColor = red
        moreButton.toolTip = "更多"
        moreButton.setAccessibilityLabel("更多")
        moreButton.onClick = { [weak self] in
            guard let self else { return }
            self.onMore?(self.moreButton)
        }
        buttonStack.addArrangedSubview(moreButton)

        hairline.boxType = .custom
        hairline.borderType = .noBorder
        hairline.fillColor = .separatorColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        let diameter = M.headerButtonDiameter
        let buttonSizing = [playButton, shuffleButton, favoriteButton, moreButton].flatMap {
            [$0.widthAnchor.constraint(equalToConstant: diameter),
             $0.heightAnchor.constraint(equalToConstant: diameter)]
        }

        NSLayoutConstraint.activate(buttonSizing + [
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.detailHorizontal),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: M.detailTopPadding),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -16),

            // 四枚圆钮右对齐成一列，与标题行居中；⤨ 的字形比 ▶ 宽，间距由固定的圆心距保证
            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -M.headerButtonTrailing),
            buttonStack.topAnchor.constraint(equalTo: topAnchor, constant: M.headerButtonTop),

            // [PX] 细线：左与标题对齐、右与按钮末枚对齐，落在标题与副标题**之间**
            hairline.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: buttonStack.trailingAnchor),
            hairline.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: M.headerHairlineGapBelowTitle),
            hairline.heightAnchor.constraint(equalToConstant: 1),

            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.detailHorizontal),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: M.detailTitleToSubtitle),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -M.detailHorizontal),
        ])
    }

    /// `subtitle` 传 nil ＝分组头形态：只有标题、四枚钮与细线，不摆副标题
    /// （Music「所有艺人」里每位艺人的组头就是这个样子）。
    func configure(title: String, subtitle: String?) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = subtitle == nil
    }

    /// 收藏态：品牌红实心圆 + 黑星；未收藏：白 5% 圆底 + 品牌红星。
    /// 没有可收藏对象（「所有艺人」）时整枚藏掉。
    func setFavorite(visible: Bool, isFavorite: Bool) {
        self.isFavorite = isFavorite
        favoriteButton.isHidden = !visible
        favoriteButton.setSymbol(isFavorite ? "star.fill" : "star", weight: .semibold)
        if isFavorite {
            favoriteButton.style = .brand
            favoriteButton.glyphColor = .black
        } else {
            favoriteButton.style = .subtle
            favoriteButton.glyphColor = NSColor(Color.amberKey)
        }
        let label = isFavorite ? "取消喜爱" : "喜爱"
        favoriteButton.setAccessibilityLabel(label)
        favoriteButton.toolTip = label
    }
}

// MARK: - 「所有艺人」的艺人分组头

/// Music 的「所有艺人」详情面是按艺人分组的：每位艺人一行组头（名字 + ▶ ⤨ ★ ⋯ + 细线，
/// **无副标题**），组头下面才是他自己的专辑块。组头复用固定头那份 `LibraryArtistHeaderView`
/// ——同一套字号、圆钮、细线，只是 `subtitle` 传 nil。
@MainActor
private final class LibraryArtistGroupHeaderCell: NSTableCellView {

    private let header = LibraryArtistHeaderView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func configure(artist: Artist, isFavorite: Bool,
                   onPlay: @escaping () -> Void,
                   onShuffle: @escaping () -> Void,
                   onToggleFavorite: @escaping () -> Void,
                   onMore: @escaping (NSView) -> Void) {
        header.configure(title: artist.name, subtitle: nil)
        header.setFavorite(visible: true, isFavorite: isFavorite)
        header.onPlay = onPlay
        header.onShuffle = onShuffle
        header.onToggleFavorite = onToggleFavorite
        header.onMore = onMore
    }
}

// MARK: - 专辑块单元格

@MainActor
private final class LibraryArtistAlbumBlockCell: NSTableCellView {

    private typealias M = MusicMetrics.LibraryArtists

    private var album: Album?
    private var tracks: [Track] = []
    private weak var appState: AppState?
    private var onSelectTrack: ((String?) -> Void)?
    private var selectedTrackID: String?

    private let artworkButton = NSButton()
    private let artworkView = CatalogArtworkView()
    private let headerContainer = NSView()
    private let titleButton = NSButton()
    private let favoriteStar = NSImageView()
    private let metaLabel = NSTextField(labelWithString: "")
    private let ratingView = LibraryArtistRatingView()
    private let addButton = LibraryCircleButton(style: .subtle, diameter: M.blockButtonDiameter,
                                                symbol: "plus",
                                                glyphSize: M.blockButtonDiameter * 0.46)
    private let moreButton = LibraryCircleButton(style: .subtle, diameter: M.blockButtonDiameter,
                                                 symbol: "ellipsis",
                                                 glyphSize: M.blockButtonDiameter * 0.42)
    private let blockButtonStack = NSStackView()
    private var trackRows: [LibraryArtistTrackRowView] = []

    private var artworkWidthConstraint: NSLayoutConstraint?
    private var artworkHeightConstraint: NSLayoutConstraint?
    private var rightContainerLeadingConstraint: NSLayoutConstraint?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }

    override var isFlipped: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        artworkButton.isBordered = false
        artworkButton.title = ""
        artworkButton.target = self
        artworkButton.action = #selector(openAlbum)
        artworkButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(artworkButton)

        artworkView.cornerRadius = MusicMetrics.Detail.artworkCornerRadius
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkButton.addSubview(artworkView)

        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerContainer)

        titleButton.isBordered = false
        titleButton.bezelStyle = .shadowlessSquare
        titleButton.alignment = .left
        titleButton.font = .systemFont(ofSize: M.blockTitleSize, weight: .bold)
        titleButton.target = self
        titleButton.action = #selector(openAlbum)
        titleButton.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(titleButton)

        favoriteStar.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "喜爱")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        favoriteStar.contentTintColor = NSColor(Color.amberKey)
        favoriteStar.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(favoriteStar)

        metaLabel.font = .systemFont(ofSize: M.blockMetaSize)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(metaLabel)

        ratingView.translatesAutoresizingMaskIntoConstraints = false
        ratingView.onRate = { [weak self] newRating in
            guard let album = self?.album else { return }
            self?.appState?.library.setRating(newRating, for: album.id)
        }
        headerContainer.addSubview(ratingView)

        let red = NSColor(Color.amberKey)
        addButton.glyphColor = red
        addButton.onClick = { [weak self] in self?.addTapped() }
        headerContainer.addSubview(addButton)

        moreButton.glyphColor = red
        moreButton.onClick = { [weak self] in self?.showMoreMenu() }

        // 两枚钮进 stack：整张下完后 ↓ 收掉，⋯ 不会在原地留一个空格
        blockButtonStack.orientation = .horizontal
        blockButtonStack.alignment = .centerY
        blockButtonStack.spacing = M.blockButtonGap
        blockButtonStack.addArrangedSubview(addButton)
        blockButtonStack.addArrangedSubview(moreButton)
        blockButtonStack.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(blockButtonStack)

        let aw = artworkButton.widthAnchor.constraint(equalToConstant: 240)
        let ah = artworkButton.heightAnchor.constraint(equalToConstant: 240)
        let rc = headerContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.blockArtworkInset + 240 + M.blockArtworkToColumn)
        artworkWidthConstraint = aw
        artworkHeightConstraint = ah
        rightContainerLeadingConstraint = rc

        let headerTrailing = headerContainer.trailingAnchor.constraint(equalTo: trailingAnchor)
        headerTrailing.priority = .defaultHigh

        NSLayoutConstraint.activate([
            artworkButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.blockArtworkInset),
            artworkButton.topAnchor.constraint(equalTo: topAnchor, constant: M.blockTopPadding),
            aw, ah,

            artworkView.leadingAnchor.constraint(equalTo: artworkButton.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkButton.trailingAnchor),
            artworkView.topAnchor.constraint(equalTo: artworkButton.topAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkButton.bottomAnchor),

            rc,
            headerTrailing,
            headerContainer.topAnchor.constraint(equalTo: artworkButton.topAnchor),
            // 高度由内容定，别再用「字号 + 间距 + 字号」那摞去凑：标题按钮实际 26 高、
            // 信息行 16 高，凑出来的 46 比真实内容（26+11+16 = 53）矮 7，
            // 圆钮又是按这个容器的中线摆的，于是整对偏高。
            headerContainer.bottomAnchor.constraint(equalTo: metaLabel.bottomAnchor),

            titleButton.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: M.blockTitleIndent),
            titleButton.topAnchor.constraint(equalTo: headerContainer.topAnchor),

            favoriteStar.leadingAnchor.constraint(equalTo: titleButton.trailingAnchor, constant: MusicMetrics.Detail.albumFavoriteGap),
            favoriteStar.centerYAnchor.constraint(equalTo: titleButton.centerYAnchor),
            favoriteStar.trailingAnchor.constraint(lessThanOrEqualTo: blockButtonStack.leadingAnchor, constant: -12),

            metaLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: M.blockTitleIndent),
            metaLabel.topAnchor.constraint(equalTo: titleButton.bottomAnchor, constant: M.blockTitleToMeta),

            ratingView.leadingAnchor.constraint(equalTo: metaLabel.trailingAnchor, constant: MusicMetrics.Detail.albumMetaSpacing),
            ratingView.centerYAnchor.constraint(equalTo: metaLabel.centerYAnchor),

            // [PX] 圆钮对挂在标题组右端：竖直居中于「标题 + 信息行」组，右沿距格右 34
            blockButtonStack.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor,
                                                       constant: -M.blockButtonTrailing),
            blockButtonStack.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: M.blockButtonDiameter),
            addButton.heightAnchor.constraint(equalToConstant: M.blockButtonDiameter),
            moreButton.widthAnchor.constraint(equalToConstant: M.blockButtonDiameter),
            moreButton.heightAnchor.constraint(equalToConstant: M.blockButtonDiameter),
        ])
    }

    func configure(album: Album, tracks: [Track], showsArtistName: Bool, tableWidth: CGFloat,
                   selectedTrackID: String?, onSelectTrack: @escaping (String?) -> Void,
                   appState: AppState) {
        self.album = album
        self.tracks = tracks
        self.appState = appState
        self.onSelectTrack = onSelectTrack
        self.selectedTrackID = selectedTrackID

        updateLayout(forWidth: tableWidth)

        artworkView.setArtwork(url: album.artworkURL, points: artworkWidthConstraint?.constant ?? 240)

        // 标题与字体
        titleButton.font = .systemFont(ofSize: M.blockTitleSize, weight: .bold)
        let attrTitle = NSMutableAttributedString(
            string: album.name,
            attributes: [
                .font: NSFont.systemFont(ofSize: M.blockTitleSize, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        titleButton.attributedTitle = attrTitle

        favoriteStar.isHidden = !appState.library.isFavoriteAlbum(album)

        // 信息行
        var metaParts: [String] = []
        if showsArtistName && !album.artistName.isEmpty { metaParts.append(album.artistName) }
        if let genre = album.genre, !genre.isEmpty { metaParts.append(genre) }
        if let year = album.publishDate?.prefix(4), !year.isEmpty { metaParts.append(String(year)) }
        metaLabel.stringValue = metaParts.joined(separator: " · ")

        ratingView.rating = appState.library.rating(for: album.id)
        refreshLibraryState()

        // 音轨行布局
        let neededCount = tracks.count
        while trackRows.count < neededCount {
            let row = LibraryArtistTrackRowView()
            addSubview(row)
            trackRows.append(row)
        }

        for (index, track) in tracks.enumerated() {
            let rowView = trackRows[index]
            rowView.isHidden = false
            rowView.configure(track: track,
                              number: track.trackNumber ?? (index + 1),
                              tracks: tracks,
                              index: index,
                              appState: appState,
                              isSelected: selectedTrackID == track.id,
                              onSelect: { [weak self] in
                                  self?.onSelectTrack?(track.id)
                              })
        }

        for index in neededCount..<trackRows.count {
            trackRows[index].isHidden = true
        }

        layoutTrackRows()
    }

    /// 换选中行 / 播放态变了：不重配置，只刷新各行状态。
    func setSelectedTrack(_ id: String?) {
        selectedTrackID = id
        for (index, row) in trackRows.enumerated() where !row.isHidden {
            row.setSelected(index < tracks.count ? tracks[index].id == id : false)
        }
    }

    /// 封面边长：详情宽的 0.371、夹 200…360 [PX]。**行高与块视图共用这一份**，
    /// 见 `LibraryArtistsViewController.detailLayoutWidth`。
    static func artworkWidth(forDetailWidth width: CGFloat) -> CGFloat {
        let w = max(width, 400)
        return min(max(w * M.blockArtworkFraction, M.blockArtworkMin), M.blockArtworkMax)
    }

    func updateLayout(forWidth width: CGFloat) {
        let artworkWidth = Self.artworkWidth(forDetailWidth: width)
        artworkWidthConstraint?.constant = artworkWidth
        artworkHeightConstraint?.constant = artworkWidth
        rightContainerLeadingConstraint?.constant = M.blockArtworkInset + artworkWidth + M.blockArtworkToColumn
        layoutTrackRows()
    }

    private func layoutTrackRows() {
        guard let rightLeading = rightContainerLeadingConstraint?.constant else { return }
        let tracksTop = M.blockTopPadding + M.blockArtworkTopToTracks
        // [AX] 曲目列宽恒 511，不随详情拉伸；窗口不够宽时才收缩
        let rightWidth = max(0, min(M.trackCellWidth, bounds.width - rightLeading))

        for (index, track) in tracks.enumerated() {
            guard index < trackRows.count else { break }
            let rowView = trackRows[index]
            let y = tracksTop + CGFloat(index) * M.trackRowHeight
            rowView.frame = NSRect(x: rightLeading, y: y, width: rightWidth, height: M.trackRowHeight)
        }
    }

    override func layout() {
        super.layout()
        layoutTrackRows()
    }

    func refreshPlayingState() {
        for row in trackRows where !row.isHidden {
            row.refreshPlayingState()
        }
    }

    // MARK: ↓ 入库 / 下载

    /// 这一枚键的形态走 `DownloadStore.action(inLibrary:tracks:)`——与专辑页头、
    /// 播放列表页头、艺人目录页的 release 卡同一套词汇。
    /// 只有「停止」那一档换成红描边圆（Music 实拍：红圈里一个红方块），其余都是 5% 白底。
    private var blockAction: LibraryDownloadAction = .addToLibrary

    private func refreshLibraryState() {
        guard let album, let appState else { return }
        let action = appState.downloads.action(
            inLibrary: appState.library.isAlbumInLibrary(album), tracks: tracks)
        blockAction = action
        addButton.style = action == .stop ? .ring : .subtle
        addButton.setSymbol(action.symbol)
        addButton.setAccessibilityLabel(action.label)
        addButton.toolTip = action.label
    }

    /// 下载状态变了只刷这一枚，不重配整块。
    func refreshDownloadState() {
        refreshLibraryState()
    }

    /// 入库走目录卡专辑段同一条路（toast 文案一致）；
    /// 下载/停止走 `DownloadStore`——`remove(ids:)` 会先`cancel()` 再清索引，就是「停止」。
    private func addTapped() {
        guard let album, let appState else { return }
        if blockAction == .addToLibrary {
            Task { @MainActor [weak self] in
                do {
                    let detail = try await appState.provider(album.kind).albumDetail(album)
                    appState.library.addAlbumToLibrary(album, tracks: detail.tracks)
                    appState.showToast("已将《\(album.name)》添加到资料库")
                    if self?.album?.id == album.id { self?.refreshLibraryState() }
                } catch {
                    appState.showToast("拿不到专辑曲目：\(error.localizedDescription)")
                }
            }
        } else if blockAction == .done {
            // 点 ✓ ＝移除整张碟的下载，先问一句（`DownloadRemovalAlert`）
            let tracks = self.tracks
            DownloadRemovalAlert.confirm(count: tracks.count, in: amberWindow) { [weak self] in
                appState.downloads.removeDownload(tracks)
                self?.refreshLibraryState()
            }
            return
        } else {
            appState.downloads.perform(blockAction, tracks: tracks)
        }
        refreshLibraryState()
    }

    // MARK: ⋯ 专辑菜单

    /// 与目录卡的专辑段同一集：播放 / 前往专辑 / 喜爱 / 入库 / 下载·移除下载。
    /// 项序走 `CollectionActions`——这里只报「这张碟能做什么」，不再手拼`NSMenu`。
    private func showMoreMenu() {
        guard let album, let appState else { return }
        let library = appState.library
        let downloads = appState.downloads
        let tracks = self.tracks
        var actions = CollectionActions()

        if !tracks.isEmpty {
            actions.play = {
                appState.player.play(tracks, startAt: 0,
                                     source: .init(title: album.name, route: .album(album)))
            }
        }
        actions.goTo = (title: "前往专辑", run: { appState.push(.album(album)) })
        actions.shareURL = album.webShareURL

        if library.isFavoriteAlbum(album) {
            actions.undoFavorite = { [weak self] in
                library.toggleFavoriteAlbum(album)
                self?.favoriteStar.isHidden = !library.isFavoriteAlbum(album)
            }
        } else {
            actions.favorite = { [weak self] in
                library.toggleFavoriteAlbum(album)
                self?.favoriteStar.isHidden = !library.isFavoriteAlbum(album)
            }
        }

        guard library.isAlbumInLibrary(album) else {
            actions.addToLibrary = { [weak self] in self?.addTapped() }
            return popUpMoreMenu(actions)
        }
        // 块里那份 `tracks` 是资料库侧的快照，删库要整张碟的曲目，拉一次详情再写库。
        actions.deleteFromLibrary = {
            Task { @MainActor in
                do {
                    let detail = try await appState.provider(album.kind).albumDetail(album)
                    library.removeAlbumFromLibrary(album, tracks: detail.tracks)
                    appState.showToast("已将《\(album.name)》从资料库中删除")
                } catch {
                    appState.showToast("拿不到专辑曲目：\(error.localizedDescription)")
                }
            }
        }
        // 「下载 / 移除下载」是 Music ••• 菜单的第二栏，且只对已入库的专辑出现
        // （见 DownloadStore 头注：`doDownloadCloudTrackSelection:` 的 validateMenuItem: 就这么摘的）。
        // 整张下完后 ↓ 那一枚会收起来，没有这一项就再也删不掉本地那份了。
        if !tracks.isEmpty {
            if tracks.allSatisfy({ downloads.isDownloaded($0.id) }) {
                actions.removeDownload = { [weak self] in
                    downloads.removeDownload(tracks)
                    self?.refreshLibraryState()
                }
            } else {
                actions.download = { [weak self] in
                    downloads.download(tracks)
                    self?.refreshLibraryState()
                }
            }
        }
        popUpMoreMenu(actions)
    }

    private func popUpMoreMenu(_ actions: CollectionActions) {
        guard let menu = actions.makeMenu() else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: moreButton.bounds.midX, y: moreButton.bounds.height + 2),
                   in: moreButton)
    }

    /// 封面与标题两枚按钮的落点（`artworkButton` / `titleButton` 的 action），
    /// 菜单里那条「前往专辑」在 `showMoreMenu()` 的闭包里另走一份。
    @objc private func openAlbum() {
        guard let album else { return }
        appState?.push(.album(album))
    }
}

// MARK: - 艺人详情内嵌音轨行

/// 一条音轨（宽恒 `trackCellWidth` = 511 [AX]，手排 frame）：
/// 心水星 +4、序号 +22（悬浮换成红 ▶）、歌名 +58、五星评分 +269（共 71）、
/// 下载列圆心距格右 122、时长右沿距格右 59.5、⋯ 贴格右宽 50；
/// 行**顶** 1pt 分割线从 +24 起。
/// 单击选中（整行圆角 5 品牌红底白字，与播放态同款）、双击或点 ▶ 起播、右键曲目菜单。
@MainActor
private final class LibraryArtistTrackRowView: NSView {

    private typealias M = MusicMetrics.LibraryArtists

    private var track: Track?
    private var tracks: [Track] = []
    private var index: Int = 0
    private weak var appState: AppState?
    private var onSelect: (() -> Void)?

    private var isHovering = false
    private var isSelected = false
    private var trackingArea: NSTrackingArea?

    private let bgView = NSBox()
    private let separatorView = NSBox()
    private let favoriteButton = NSButton()
    private let numberLabel = NSTextField(labelWithString: "")
    private let playGlyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let ratingView = LibraryArtistRatingView(starSize: M.trackStarSize,
                                                     starSpacing: 2.2)
    private let cloudView = LibraryArtistCloudView()
    private let durationLabel = NSTextField(labelWithString: "")
    private let moreButton = NSButton()
    /// 歌名右界的两套约束：评分列放得下时让到评分前，放不下时让到时长前。
    private var titleToRating: NSLayoutConstraint!
    private var titleToDuration: NSLayoutConstraint!

    private let brandRed = NSColor(Color.amberKey)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    override var isFlipped: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        wantsLayer = true

        // [PX] 行**顶**分割线：+24 起到格右。画在顶边而不是底边，信息行与曲目首行
        // 之间才会有那一条（Music 块 2 y=714 ＝首行顶），末行下面才不会多出一条。
        // 先加（垫底），选中/播放的红底盖住本行这条。
        separatorView.boxType = .custom
        separatorView.borderType = .noBorder
        separatorView.fillColor = .separatorColor
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separatorView)

        bgView.boxType = .custom
        bgView.borderType = .noBorder
        bgView.cornerRadius = M.trackHighlightCornerRadius
        bgView.fillColor = .clear
        bgView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bgView)

        favoriteButton.isBordered = false
        favoriteButton.imagePosition = .imageOnly
        favoriteButton.bezelStyle = .shadowlessSquare
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite)
        favoriteButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(favoriteButton)

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        numberLabel.alignment = .left
        numberLabel.textColor = .secondaryLabelColor
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(numberLabel)

        playGlyph.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        playGlyph.contentTintColor = brandRed
        playGlyph.isHidden = true
        playGlyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playGlyph)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        ratingView.onRate = { [weak self] value in
            guard let track = self?.track, let appState = self?.appState else { return }
            appState.library.setRating(value, for: track.id)
        }
        ratingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ratingView)

        cloudView.onClick = { [weak self] in self?.cloudClicked() }
        cloudView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cloudView)

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        durationLabel.textColor = .secondaryLabelColor
        durationLabel.alignment = .right
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(durationLabel)

        moreButton.isBordered = false
        moreButton.imagePosition = .imageOnly
        moreButton.bezelStyle = .shadowlessSquare
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多操作")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        moreButton.contentTintColor = brandRed
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(moreButton)

        titleToRating = titleLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: ratingView.leadingAnchor, constant: -12)
        titleToDuration = titleLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: cloudView.leadingAnchor, constant: -12)

        NSLayoutConstraint.activate([
            bgView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bgView.topAnchor.constraint(equalTo: topAnchor),
            bgView.bottomAnchor.constraint(equalTo: bottomAnchor),

            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.trackSeparatorLeading),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorView.topAnchor.constraint(equalTo: topAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 1),

            favoriteButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.trackStarLeading - 2),
            favoriteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            favoriteButton.widthAnchor.constraint(equalToConstant: 16),
            favoriteButton.heightAnchor.constraint(equalToConstant: 16),

            numberLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.trackNumberLeading),
            numberLabel.widthAnchor.constraint(equalToConstant: M.trackNumberWidth),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            playGlyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.trackNumberLeading),
            playGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.trackTitleLeading),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            ratingView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.trackRatingLeading),
            ratingView.centerYAnchor.constraint(equalTo: centerYAnchor),

            // [PX] 下载列：圆心距格右 122，夹在评分与时长之间
            cloudView.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -M.trackCloudTrailing),
            cloudView.centerYAnchor.constraint(equalTo: centerYAnchor),
            cloudView.widthAnchor.constraint(equalToConstant: M.trackCloudWidth),
            cloudView.heightAnchor.constraint(equalToConstant: M.trackRowHeight),

            durationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -M.trackDurationTrailing),
            durationLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // [AX] ⋯ 的命中区贴着格右、宽 50，字形自然居中在距格右 25
            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: M.trackMoreWidth),
            moreButton.heightAnchor.constraint(equalToConstant: M.trackRowHeight),

            titleToRating,
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateVisualState()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateVisualState()
    }

    /// 悬浮时序号位换成 ▶，点它起播；行宽不够放评分列时把评分让给歌名。
    override func layout() {
        super.layout()
        let ratingFits = bounds.width >= M.trackRatingLeading + M.trackRatingWidth + M.trackDurationTrailing + 40
        ratingView.isHidden = !ratingFits
        if titleToRating.isActive == ratingFits { return }
        titleToRating.isActive = ratingFits
        titleToDuration.isActive = !ratingFits
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 双击整行起播；悬浮时点 ▶ 那一格也直接播；其余单击＝选中
        if event.clickCount >= 2 {
            playFromHere()
        } else if isHovering, playGlyph.isHidden == false,
                  point.x >= M.trackNumberLeading - 2, point.x <= M.trackNumberLeading + M.trackNumberWidth + 2 {
            playFromHere()
        } else {
            onSelect?()
        }
    }

    private func playFromHere() {
        guard let appState else { return }
        // 这一段是某张专辑的曲目，「来自《…》」就是那张专辑（曲目自己带得回落点）。
        let source = track.map {
            PlayerController.QueueSource(title: $0.albumName, route: Route.album(of: $0))
        }
        appState.player.play(tracks, startAt: index, source: source)
        onSelect?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let track, let appState else { return nil }
        return MenuSpec.makeMenu(
            TrackActions(tracks: [track], appState: appState,
                         playContext: TrackPlayContext(tracks: tracks, index: index)).libraryRow())
    }

    func configure(track: Track, number: Int, tracks: [Track], index: Int, appState: AppState,
                   isSelected: Bool, onSelect: @escaping () -> Void) {
        self.track = track
        self.tracks = tracks
        self.index = index
        self.appState = appState
        self.onSelect = onSelect
        self.isSelected = isSelected

        numberLabel.stringValue = "\(number)"
        titleLabel.stringValue = track.title
        durationLabel.stringValue = track.duration.mmss
        ratingView.rating = appState.library.rating(for: track.id)

        updateVisualState()
    }

    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        updateVisualState()
    }

    func refreshPlayingState() {
        updateVisualState()
    }

    // MARK: 状态

    private var isCurrentTrack: Bool {
        guard let track, let player = appState?.player else { return false }
        return player.currentTrack?.id == track.id
    }

    /// 红底 ＝ 选中或正在播放（同一套红 [AX]：单击行也整行品牌红白字）。
    /// 悬浮（非红底行）不画底，只把序号换成红 ▶。
    private func updateVisualState() {
        let highlighted = isSelected || isCurrentTrack

        bgView.fillColor = highlighted ? brandRed : .clear

        // 悬浮把序号换成 ▶；红底行里 ▶ 是白，普通行是品牌红
        numberLabel.isHidden = isHovering
        playGlyph.isHidden = !isHovering
        playGlyph.contentTintColor = highlighted ? .white : brandRed

        if highlighted {
            favoriteButton.contentTintColor = .white
            numberLabel.textColor = NSColor.white.withAlphaComponent(0.85)
            titleLabel.textColor = .white
            durationLabel.textColor = NSColor.white.withAlphaComponent(0.85)
            moreButton.contentTintColor = .white
            refreshRatingColors(highlighted: true)
        } else {
            favoriteButton.contentTintColor = brandRed
            numberLabel.textColor = .secondaryLabelColor
            titleLabel.textColor = .labelColor
            durationLabel.textColor = .secondaryLabelColor
            moreButton.contentTintColor = brandRed
            refreshRatingColors(highlighted: false)
        }
        refreshFavoriteGlyph()
        refreshCloudState(highlighted: highlighted)
    }

    /// 下载列：四种状态与歌曲表（`SongsTableCells.cloudCell`）同一套词汇，
    /// 未下载的 ↓ 只在悬浮/选中时显形（与 Music 一致：静态行这一列是空的）。
    private func refreshCloudState(highlighted: Bool) {
        guard let track, let appState else { return }
        cloudView.tint = highlighted ? .white : brandRed
        cloudView.downloadedTint = highlighted
            ? NSColor.white.withAlphaComponent(0.85)
            : .secondaryLabelColor
        // Music 里心水星 / 评分星 / ↓ 三列是一起靠**块级悬浮**显形的（参照图里静态行
        // 这三列全空）。这一页的心水星与评分星现在是常显的，↓ 跟着它们走，
        // 免得同一行里三列各显各的。块级悬浮显形另记 TODO，要改就三列一起改。
        cloudView.revealed = true
        cloudView.state = appState.downloads.state(for: track.id)
    }

    private func cloudClicked() {
        guard let track, let appState else { return }
        switch appState.downloads.state(for: track.id) {
        case .none, .failed:
            appState.downloads.download([track])
        case .downloaded:
            // 点已完成的图标＝删除下载，先问一句（`DownloadRemovalAlert`）
            DownloadRemovalAlert.confirm(count: 1, in: amberWindow) {
                appState.downloads.removeDownload([track])
            }
        case .downloading:
            break
        }
    }

    private func refreshRatingColors(highlighted: Bool) {
        ratingView.filledColor = highlighted ? .white : brandRed
        ratingView.emptyColor = highlighted
            ? NSColor.white.withAlphaComponent(0.6)
            : brandRed.withAlphaComponent(MusicMetrics.Rating.emptyOpacity)
    }

    /// 心水星：已心水实心常显；未心水空心也常显（这一页与歌曲表不同，
    /// Music 实机里空心星不参与悬浮显形）。
    private func refreshFavoriteGlyph() {
        guard let track, let appState else { return }
        let isFavorite = appState.library.isFavorite(track)
        favoriteButton.image = NSImage(systemSymbolName: isFavorite ? "star.fill" : "star",
                                       accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: M.trackStarSize, weight: .regular))
        let label = isFavorite ? "取消心水" : "心水"
        favoriteButton.setAccessibilityLabel(label)
        favoriteButton.toolTip = label
    }

    @objc private func toggleFavorite() {
        guard let track, let appState else { return }
        appState.library.toggleFavorite(track)
        refreshFavoriteGlyph()
    }

    @objc private func moreClicked() {
        guard let track, let appState else { return }
        let menu = MenuSpec.makeMenu(
            TrackActions(tracks: [track], appState: appState,
                         playContext: TrackPlayContext(tracks: tracks, index: index)).libraryRow())
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height), in: moreButton)
    }
}

// MARK: - 曲目行的下载列

/// 曲目行「下载」那一列，四种状态照 `DownloadState` 画，与歌曲表
/// （`SongsTableCells.cloudCell`）同一套词汇：
/// - `.none`：`arrow.down`，**只在悬浮/选中时显形**——Music 里静态行这一列是空的，
///   把指针移进专辑块（或选中行）才会连同心水星、评分星一起露出来；
/// - `.downloading`：一圈进度环，常显、点不动。起步留 2% 弧，0% 画出来是个点像卡住；
/// - `.downloaded`：**灰色实心圆 + 挖空的下箭头**（`arrow.down.circle.fill` 的观感，
///   Music 实拍就是这样：圆是次级灰，箭头是透出来的行底色）。常显，不是空白；
///   点它＝删掉本地那份（回到 `.none`）；
/// - `.failed`：常显`exclamationmark.icloud`，tooltip 给错误文案，点了重试。
@MainActor
private final class LibraryArtistCloudView: NSView {

    private typealias M = MusicMetrics.LibraryArtists

    var onClick: (() -> Void)?

    var state: DownloadState = .none {
        didSet { if state != oldValue { apply() } }
    }
    /// 红底行里字形转白，与同行的心水星、时长同步。
    var tint: NSColor = .labelColor {
        didSet { if tint != oldValue { apply() } }
    }
    /// 「已下载」那枚圆是次级灰，不跟品牌红走（Music 实拍：与时长同一档灰）。
    var downloadedTint: NSColor = .secondaryLabelColor {
        didSet { if downloadedTint != oldValue { apply() } }
    }
    /// 悬浮/选中才显形——只作用于 `.none`，下载中与失败态是常显的。
    var revealed: Bool = false {
        didSet { if revealed != oldValue { apply() } }
    }

    private let glyph = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyph.imageScaling = .scaleNone
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private func apply() {
        if case .downloaded = state {
            glyph.contentTintColor = downloadedTint
        } else {
            glyph.contentTintColor = tint
        }
        switch state {
        case .none:
            setGlyph("arrow.down", visible: revealed, help: "下载")
        case .downloading:
            setGlyph(nil, visible: false, help: "正在下载")
        case .downloaded:
            setGlyph("arrow.down.circle.fill", visible: true, help: "已下载")
        case .failed(let message):
            setGlyph("exclamationmark.icloud", visible: true, help: message)
        }
        needsDisplay = true
    }

    private func setGlyph(_ symbol: String?, visible: Bool, help: String?) {
        glyph.image = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: M.trackCloudIconSize, weight: .regular))
        }
        // `alphaValue = 0` 的视图照样吃点击，藏起来要用 isHidden
        glyph.isHidden = !visible || glyph.image == nil
        toolTip = help
        setAccessibilityLabel(help)
    }

    /// 进度环：`.downloading` 才画，其余状态这里什么都不落笔。
    override func draw(_ dirtyRect: NSRect) {
        guard case .downloading(let progress) = state else { return }
        let size = M.trackCloudIconSize
        let rect = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2,
                          width: size, height: size).insetBy(dx: M.trackCloudRingWidth / 2,
                                                             dy: M.trackCloudRingWidth / 2)
        let path = NSBezierPath()
        // 从 12 点起顺时针，与歌曲表那圈同向。**这是一个 `isFlipped` 视图**：y 轴翻过来
        // 之后，路径坐标里的 90°（0, +r）落在视觉的下方、`clockwise: true` 看起来是逆时针。
        // 所以起点取 −90、方向取 `false`，画出来才是「从顶上开始、顺时针涨」。
        // （离屏渲过两版对照：90/true 那版 25% 是从 3 点划到 6 点。）
        path.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY),
                       radius: rect.width / 2,
                       startAngle: -90,
                       endAngle: -90 + 360 * max(0.02, min(progress, 1)),
                       clockwise: false)
        path.lineWidth = M.trackCloudRingWidth
        path.lineCapStyle = .round
        tint.setStroke()
        path.stroke()
    }

    /// 只有画得出东西、又确实有动作的状态才接点击（未下载→下、已下载→删、失败→重试）；
    /// 下载中这一格让位给整行的选中与双击起播。
    /// （`point` 是父视图坐标系里的点，照`NSView.hitTest(_:)` 的约定换算。）
    override func hitTest(_ point: NSPoint) -> NSView? {
        switch state {
        case .none where revealed, .downloaded, .failed:
            return bounds.contains(convert(point, from: amberSuperview)) ? self : nil
        default:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - 5 星打分控件

@MainActor
private final class LibraryArtistRatingView: NSView {

    private let starSize: CGFloat
    private let starSpacing: CGFloat

    var rating: Int = 0 {
        didSet {
            guard rating != oldValue else { return }
            updateStars()
        }
    }
    var onRate: ((Int) -> Void)?
    /// 红底行里整排换白，颜色开出来由行推。
    var filledColor: NSColor = NSColor(Color.amberKey) {
        didSet { updateStars() }
    }
    var emptyColor: NSColor = NSColor(Color.amberKey).withAlphaComponent(MusicMetrics.Rating.emptyOpacity) {
        didSet { updateStars() }
    }

    private var starViews: [NSImageView] = []

    /// 专辑块头用页头的星号规格，音轨行传自己的（trackStarSize）。
    init(starSize: CGFloat = MusicMetrics.Rating.headerStarSize,
         starSpacing: CGFloat = MusicMetrics.Rating.headerStarSpacing) {
        self.starSize = starSize
        self.starSpacing = starSpacing
        super.init(frame: .zero)
        setup()
    }

    override var intrinsicContentSize: NSSize {
        let totalWidth = CGFloat(5) * starSize + CGFloat(4) * starSpacing
        return NSSize(width: totalWidth, height: starSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        var prev: NSImageView?
        for i in 0..<5 {
            let iv = NSImageView()
            iv.imageScaling = .scaleNone
            iv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iv)
            starViews.append(iv)

            NSLayoutConstraint.activate([
                iv.centerYAnchor.constraint(equalTo: centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: starSize),
                iv.heightAnchor.constraint(equalToConstant: starSize),
            ])

            if let prev {
                iv.leadingAnchor.constraint(equalTo: prev.trailingAnchor, constant: starSpacing).isActive = true
            } else {
                iv.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            }
            if i == 4 {
                iv.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
            }
            prev = iv
        }
        updateStars()
    }

    private func updateStars() {
        for (index, iv) in starViews.enumerated() {
            let val = index + 1
            let isFilled = val <= rating
            iv.image = NSImage(systemSymbolName: isFilled ? "star.fill" : "star", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: starSize, weight: .regular))
            iv.contentTintColor = isFilled ? filledColor : emptyColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        for (index, iv) in starViews.enumerated() {
            if iv.frame.contains(pt) {
                let val = index + 1
                if val == rating {
                    onRate?(0)
                } else {
                    onRate?(val)
                }
                return
            }
        }
    }
}

// MARK: - 筛选菜单

@MainActor
private final class LibraryArtistFilterMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let model: LibraryPageModel

    init(model: LibraryPageModel) {
        self.model = model
        super.init()
        menu.delegate = self
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()
        menu.addItem(check("所有艺人", on: !model.favoritesOnly, action: #selector(selectAllItems)))
        menu.addItem(check("仅喜爱", on: model.favoritesOnly, action: #selector(selectFavorites)))
    }

    private func check(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func selectAllItems() { model.favoritesOnly = false }
    @objc private func selectFavorites() { model.favoritesOnly = true }
}

// MARK: - NSView 递归查找子视图辅助

private extension NSView {
    func subviews<T: NSView>(ofType type: T.Type) -> [T] {
        var result: [T] = []
        for sub in subviews {
            if let match = sub as? T { result.append(match) }
            result.append(contentsOf: sub.subviews(ofType: type))
        }
        return result
    }
}

@MainActor
extension LibraryArtistsViewController: NSMenuItemValidation {
    /// 「文件 ▸ 显示简介」只在有高亮行时可用；没有就整条变灰。
    /// 其余菜单项这一页不接，照旧交回默认（`true`），与歌曲页同解。
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == MainMenu.Action.getInfo else { return true }
        return selectedTrack() != nil
    }
}
