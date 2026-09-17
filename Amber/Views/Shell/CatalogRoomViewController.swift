import AppKit
import SwiftUI

// MARK: - 网格类目录二级页（房间页）—— 计划阶段 5 批 B
//
// 目录页分段那句「查看全部 ›」的落点，Music 叫 room。曲目类落点走
// `TrackListPageController(kind: .room)`（一张表格），**网格类的四种**在这里：
//
// 1. `title + albums`  「为你推荐最新作品」「本周新发行」…（副标题「N 张专辑」）
// 2. `title + playlists`「歌单已更新」「风格电台」…（副标题「N 个播放列表」）
// 3. `recentlyPlayed`  主页「最近播放 ›」（按容器收起来，页头只有大标题）
// 4. `tagGroup`        「探索更多」（大标题 + 一排标签胶囊，切标签重新向音源取）
//
// 骨架照 `CatalogPageViewController`（阶段 3 批 A）那一台引擎搭：
// `NSScrollView + NSCollectionView + NSCollectionViewCompositionalLayout`
// + `NSCollectionViewDiffableDataSource`，页头是**恒在的第 0 段的段头**
// （布局配置的全局头在 0 段快照下会被整个丢掉，见那份文件头的实测）。
//
// 卡片一张没有新写：四种形态全部复用目录页的方卡 `CatalogSquareItem` /
// `CatalogSquareCardView`（封面、悬浮暗罩、悬浮播放键、标题/副标题分区点击、
// 右键菜单都在里面），数据用 `CatalogItem` 喂。
//
// ## 网格口径
//
// 旧版这四页用的是**两套**数：网格三页 `GridItem(.adaptive(minimum: 180, maximum: 230),
// spacing: 20)` + 行距 24（凭手感），分类浏览页`MusicMetrics.Page.gridItemMinWidth /
// gridInterItemSpacing / gridLineSpacing`（[实测]`AMPGridLayoutModel.minimumItemSize` 183 /
// `minimumInterItemSpacing` 10 / `minimumLineSpacing` 6）。这次并到**有出处的那一份**：
// 四页统一走 `MusicMetrics.Page.grid*`。
//
// 行距 6 是 Music 在「格子自带底垫」的前提下量到的（[AX] `LibraryGrid.cellBottomPad` 10），
// 所以格高取 `MusicMetrics.Card.labelHeight`（[实测]`AMPGridCollectionViewItem.labelViewHeight`
// 46）而不是方卡自己那 37：方卡的两行字用掉 38，余下的 8 就是那道底垫，
// 6 + 8 ≈ Music 的 6 + 10。两条数同源，不再有第三套手感值。

@MainActor
final class CatalogRoomViewController: ContentPageController {

    private typealias P = MusicMetrics.Page

    /// 页头底 → 网格顶。旧版两处都是 18（网格页 `VStack(spacing: 18)`、
    /// 分类浏览页 `content.padding(.top, 18)`）。
    private static let headerToContent: CGFloat = 18
    /// 页底留白。旧版网格三页 `.padding(.bottom, 32)`、分类浏览页 24。
    private static let gridBottomInset: CGFloat = 32
    private static let tagBottomInset: CGFloat = 24
    /// 空态距内容顶。旧版 `RecentlyPlayedPage` 的`MusicEmptyStateContent.padding(.top, 60)`
    /// （`MusicEmptyStateContent` 自己还带 150）。
    private static let emptyExtraTop: CGFloat = 60
    /// 加载指示距内容顶。旧版分类浏览页 `ProgressView().padding(.top, 120)`。
    private static let loadingTop: CGFloat = 120

    // MARK: - 四种形态

    enum Content {
        case albums(title: String, albums: [Album])
        case playlists(title: String, playlists: [Playlist])
        /// 无载荷：格子由资料库的容器台账（`LibraryStore.recentContainers`）给。
        case recentlyPlayed
        case tagGroup(CatalogTagGroup)
    }

    private let content: Content

    init(appState: AppState, content: Content) {
        self.content = content
        super.init(nativePage: appState)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    convenience init(appState: AppState, title: String, albums: [Album]) {
        self.init(appState: appState, content: .albums(title: title, albums: albums))
    }

    convenience init(appState: AppState, title: String, playlists: [Playlist]) {
        self.init(appState: appState, content: .playlists(title: title, playlists: playlists))
    }

    convenience init(recentlyPlayedIn appState: AppState) {
        self.init(appState: appState, content: .recentlyPlayed)
    }

    convenience init(appState: AppState, tagGroup group: CatalogTagGroup) {
        self.init(appState: appState, content: .tagGroup(group))
    }

    // MARK: - 状态

    private let scrollView = NSScrollView()
    private let collectionView = RoomCollectionView()
    private var dataSource: NSCollectionViewDiffableDataSource<String, RoomEntryID>!

    /// 量页头高用的那一份：段头是复用视图，布局求解时手上未必有实例。
    private let headerPrototype = CatalogRoomHeaderView(frame: .zero)
    /// 当前在屏的那个段头（换标签时直接改它的选中态，横滚位置不丢）。
    private weak var liveHeader: CatalogRoomHeaderView?

    private var items: [CatalogItem] = []
    private var itemsByID: [RoomEntryID: CatalogItem] = [:]
    /// 宽度还没落定时挡下来的那一份快照，等 `viewDidLayout` 补灌。
    private var pendingItems: [CatalogItem]?
    /// 上一份快照的**版式指纹**，见 `apply(items:)` 末尾。
    private var lastLayoutSignature: String?

    // 分类浏览页专用
    private var selectedTag: CatalogTagRef?
    private var isLoading = false
    private var loadTask: Task<Void, Never>?
    /// 上一次取数是断网收的场（§2.6-8）：这一页原本只有 loading / empty 两档，
    /// 断网与「这个分类真的没有内容」在界面上分不开，也没有重试的口子。
    private var isOffline = false

    // 覆盖层（加载 / 出错 / 空态）
    private let overlay = RoomOverlayView()
    private let spinner = NSProgressIndicator()
    private let errorBox = NSStackView()
    private let errorLabel = NSTextField(labelWithString: "")
    private var emptyHost: NSView?
    private var overlayTop: NSLayoutConstraint!

    private weak var hoveredCard: (any CatalogHoverTarget)?

    /// 一件的身份。**不带位置**：位置一旦进来，在网格头上插一张卡就会让后面每一件的
    /// 身份全变，整页被判成「删光重加」——全部重建（封面重取、看得见闪动），
    /// 也没有 Music 那种「新卡从左边长出来」的插入动画。照目录页
    /// `CatalogPageViewController.CatalogEntryID` 那份写法，同一个 id 在本段里
    /// **重复出现**第几次才靠 `occurrence` 区分，第一件永远是 0。
    /// 这一页只有一个网格段，所以不必像目录页那样再带段 id。
    private struct RoomEntryID: Hashable {
        let id: String
        let occurrence: Int
    }

    private static let headerSectionID = "__room-header__"
    private static let gridSectionID = "__room-grid__"
    private static let headerIdentifier = NSUserInterfaceItemIdentifier("CatalogRoomHeaderView")

    /// 滚动 clip view 的 bounds 观察者（见 `viewDidLoad`）。
    private var boundsObserver: (any NSObjectProtocol)?

    /// 观察者令牌不是 `Sendable`，非隔离的 `deinit` 取不到它。标 `isolated`：
    /// 主线程上释放时照旧同步跑完，注销时机不变（同 `CatalogPageViewController`）。
    isolated deinit {
        loadTask?.cancel()
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    // MARK: - 视图

    override func loadView() {
        // 页面自己不画背景：玻璃只有窗口根那一层（见 RootViewController）。
        let container = NSView()

        collectionView.collectionViewLayout = makeLayout()
        collectionView.backgroundColors = [.clear]
        // 对键盘开放（审查单 §2.5-1，与目录页同一条）：方向键选、回车打开。
        // 鼠标行为一个字不变——卡片根视图自己接了 `mouseDown`（空实现、不调 super，
        // 见 `CatalogCardContentView`），事件到不了 `NSCollectionView.mouseDown`，
        // 单击仍旧是「直接打开」。多选保持关着，免得空白处一拖就画出框选矩形。
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.delegate = self
        collectionView.onActivateSelection = { [weak self] in self?.activateSelection() }
        CatalogCardRegistry.register(in: collectionView)
        collectionView.register(CatalogRoomHeaderView.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: Self.headerIdentifier)
        collectionView.onMouseMoved = { [weak self] point in self?.updateCardHover(at: point) }
        collectionView.onMouseExited = { [weak self] in self?.setHoveredCard(nil) }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        // 顶部那 52 交给系统（`automaticallyAdjustsContentInsets`）；底部给迷你播放器
        // 让位只能从**安全区**加——`contentInsets` 的 setter 会把自动调整一起关掉。
        // 与 `CatalogPageViewController` 同一条。
        scrollView.additionalSafeAreaInsets = NSEdgeInsets(
            top: 0, left: 0, bottom: MusicMetrics.MiniPlayer.scrollReserve, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)

        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .regular
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(spinner)

        // 出错块照目录页那台引擎铺（`CatalogPageViewController.buildOverlay`）：
        // wifi 图标 + 一行说明 + 「重试」，竖排居中，与加载/空态共用同一条「内容顶」。
        let errorIcon = NSImageView()
        errorIcon.image = NSImage(systemSymbolName: "wifi.exclamationmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 40, weight: .regular))
        errorIcon.contentTintColor = .tertiaryLabelColor
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        let retry = NSButton(title: "重试", target: self, action: #selector(retryTapped))
        retry.bezelStyle = .push
        errorBox.orientation = .vertical
        errorBox.alignment = .centerX
        errorBox.spacing = 12
        errorBox.setViews([errorIcon, errorLabel, retry], in: .top)
        errorBox.translatesAutoresizingMaskIntoConstraints = false
        errorBox.isHidden = true
        overlay.addSubview(errorBox)

        overlayTop = spinner.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            errorBox.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            errorBox.topAnchor.constraint(equalTo: spinner.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            overlayTop,
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        makeDataSource()
        if case .tagGroup(let group) = content { selectedTag = group.tags.first }
        configure(headerPrototype)

        // 滚轮滚动不产生 mouseMoved：不跟的话悬浮态会留在滚走的那张卡上。
        //
        // 块式观察者而不是 `for await`：bounds 是每帧发的，悬浮态必须与当前这一帧
        // 对齐，多绕一跳 await 就慢一帧。闭包是 `@Sendable`；`queue: .main` 把投递
        // 线程钉死在主线程，所以用 `assumeIsolated` 接回主 actor 隔离的自己
        //（与 `CatalogPageViewController`、`LibraryGridCards` 同一写法）。
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshHover() } }

        switch content {
        case .albums(_, let albums):
            apply(items: albums.map(albumItem))
        case .playlists(_, let playlists):
            apply(items: playlists.map(playlistItem))
        case .recentlyPlayed:
            // 与货架同一份实现、同一批格子（`CatalogFeedModel.recentItems`）。
            // 实时性照旧：上屏时读一次，不订阅。
            apply(items: CatalogFeedModel.recentItems(appState.library.recentContainers,
                                                      appState: appState))
        case .tagGroup:
            reloadTag()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let pending = pendingItems, collectionView.bounds.width > 0 {
            pendingItems = nil
            apply(items: pending)
        }
        refreshHover()
    }

    /// 切走：导航容器只把视图 `isHidden` 掉，鼠标不会再发 exited。
    override func pageDidDisappear() {
        super.pageDidDisappear()
        setHoveredCard(nil)
    }

    // MARK: - 卡片数据（一律是目录页那张方卡）

    private func albumItem(_ album: Album) -> CatalogItem {
        let appState = appState
        return CatalogItem(id: album.id, kind: .square, title: album.name,
                           artworkURL: album.artworkURL,
                           subtitle: album.artistName,
                           route: .album(album),
                           subtitleRoute: Route.artist(of: album),
                           onPlay: { Task { await appState.playAlbum(album) } })
    }

    private func playlistItem(_ playlist: Playlist) -> CatalogItem {
        let appState = appState
        return CatalogItem(id: playlist.id, kind: .square, title: playlist.name,
                           artworkURL: playlist.coverURL,
                           subtitle: playlist.creatorName,
                           // 没有封面地址时才顶上（与旧版 `CatalogGridCard` 同）
                           fallbackColors: CatalogFeedModel.fallbackColors(playlist.id),
                           route: .playlist(playlist),
                           onPlay: { Task { await appState.playPlaylist(playlist) } })
    }

    // MARK: - 页头

    private func configure(_ header: CatalogRoomHeaderView) {
        switch content {
        case .albums(let title, let albums):
            header.configure(title: title, subtitle: "\(albums.count) 张专辑",
                             onPlay: nil, onShuffle: nil)
        case .playlists(let title, let playlists):
            header.configure(title: title, subtitle: "\(playlists.count) 个播放列表",
                             onPlay: nil, onShuffle: nil)
        case .recentlyPlayed:
            // 这一页收的是格子，不是一条播放队列：没有整页的播放 / 随机播放，
            // 大标题下面也不摆计数。
            header.configure(title: "最近播放", subtitle: nil, onPlay: nil, onShuffle: nil)
        case .tagGroup(let group):
            header.configure(title: group.name, tags: group.tags, selected: selectedTag) {
                [weak self] tag in self?.select(tag)
            }
        }
    }

    private var headerHeight: CGFloat {
        headerPrototype.fittingHeight(forWidth: max(1, collectionView.bounds.width - P.leadingMargin * 2))
    }

    // MARK: - 分类浏览：换标签就重新取

    /// 「选中哪个标签」的**唯一真相是 `selectedTag`**。页头（在屏的那个、量高的那个）
    /// 都只是按它渲染的视图，所以这里只改它、再让在屏那个页头照它重渲染一遍。
    /// `configure` 现在只改胶囊的选中态、不重建整条排（见`TagStripView.setTags`），
    /// 横滚位置照旧；量高那份影子实例与选中态无关（选中只换填色，不改尺寸），不用碰。
    private func select(_ tag: CatalogTagRef) {
        guard tag != selectedTag else { return }
        selectedTag = tag
        if let liveHeader { configure(liveHeader) }
        reloadTag()
    }

    /// 切标签时上一次的请求要能被丢掉：`Task` 取消之后回来的结果一律不认。
    private func reloadTag() {
        guard case .tagGroup(let group) = content else { return }
        loadTask?.cancel()
        guard let tag = selectedTag, !tag.id.isEmpty else {
            isLoading = false
            isOffline = false
            apply(items: [])
            return
        }
        isLoading = true
        isOffline = false
        // **旧结果原地留着**，只把 spinner 叠上去（同 `SearchResultsModel`：新词条提交后
        // 旧结果不撤、等新结果到了再换）。从前这里先 `apply(items: [])` 再等网络，
        // 于是换一次标签整片网格先消失变 spinner、滚动位置归零；两个标签共有的歌单
        //（分类之间重叠很常见）也跟着闪掉，回来还是同一张卡。
        //
        // 重灌**同一份** items 而不是只 `updateOverlay()`：首次进这一页时`items` 还是空的，
        // 这一句同时负责把「只有页头那一段」的首份快照灌下去——页头是恒在的第 0 段的段头，
        // 一次快照都没灌过的话它一个像素都不画。旧结果那一路走的是零差异 diff，不重建卡。
        apply(items: items)
        let appState = appState
        loadTask = Task { [weak self] in
            let result = await appState.provider(group.kind).playlists(tag: tag)
            guard !Task.isCancelled, let self, self.selectedTag == tag else { return }
            // 一个也没交出来时才去问「是不是断网」（§2.6-8；`playlists(tag:)` 不抛错，
            // 判据只能来自系统，理由见 `CatalogFeedModel.isNetworkUnavailable`）。
            let offline = result.isEmpty ? await CatalogFeedModel.isNetworkUnavailable() : false
            guard !Task.isCancelled, self.selectedTag == tag else { return }
            self.isLoading = false
            self.isOffline = offline
            self.apply(items: result.map(self.playlistItem))
        }
    }

    /// 出错块上那颗「重试」。只有分类浏览页会走到出错态，其余三种形态的内容
    /// 要么是路由带进来的、要么是本地台账，压根不发请求。
    @objc private func retryTapped() {
        reloadTag()
    }

    // MARK: - 数据源与快照

    private func makeDataSource() {
        dataSource = NSCollectionViewDiffableDataSource<String, RoomEntryID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, identifier in
            guard let self, let model = self.itemsByID[identifier] else { return NSCollectionViewItem() }
            let item = collectionView.makeItem(
                withIdentifier: CatalogCardRegistry.identifier(for: model.kind), for: indexPath)
            (item as? any CatalogCardConfigurable)?.configure(with: model, appState: self.appState)
            return item
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard let self, kind == NSCollectionView.elementKindSectionHeader,
                  indexPath.section == 0 else { return nil }
            let header = collectionView.makeSupplementaryView(
                ofKind: kind, withIdentifier: Self.headerIdentifier,
                for: indexPath) as? CatalogRoomHeaderView
            if let header {
                self.configure(header)
                self.liveHeader = header
            }
            return header
        }
    }

    private func apply(items: [CatalogItem]) {
        // 硬闸：**已经在窗口里、宽度却还是 0** 时不许灌快照。组合布局在 0 宽容器里
        // 求解会无限生成 item，实测几秒吃掉几十 GB（与 `CatalogPageViewController` 同一条）。
        if view.amberWindow != nil, collectionView.bounds.width <= 0 {
            pendingItems = items
            return
        }
        pendingItems = nil

        self.items = items
        itemsByID.removeAll()
        var snapshot = NSDiffableDataSourceSnapshot<String, RoomEntryID>()
        snapshot.appendSections([Self.headerSectionID])
        if !items.isEmpty {
            snapshot.appendSections([Self.gridSectionID])
            var ids: [RoomEntryID] = []
            var occurrences: [String: Int] = [:]
            for item in items {
                let occurrence = occurrences[item.id, default: 0]
                occurrences[item.id] = occurrence + 1
                let id = RoomEntryID(id: item.id, occurrence: occurrence)
                itemsByID[id] = item
                ids.append(id)
            }
            snapshot.appendItems(ids, toSection: Self.gridSectionID)
        }
        setHoveredCard(nil)
        dataSource.apply(snapshot, animatingDifferences: false)
        // **版式没变就别重解布局**（照目录页 `CatalogPageViewController.apply(sections:)`
        // 末尾那条）：组合布局一 `invalidateLayout()`，网格里的 cell 会被整批重建、
        // 封面重新异步取，界面上就是闪一下。换了哪几张卡由上面那次 diffable apply 负责。
        let signature = layoutSignature(itemCount: items.count)
        if signature != lastLayoutSignature {
            lastLayoutSignature = signature
            collectionView.collectionViewLayout?.invalidateLayout()
        }
        updateOverlay()
    }

    /// 版式指纹：只认**影响布局解**的那两样——有没有网格段，以及页头多高。
    ///
    /// 网格段的解与卡数无关（列宽按容器宽算、每行列数固定、行高定值），所以卡片换了几张、
    /// 换了内容都不必重解；段的**有无**会改段序，必须重解。
    ///
    /// **不含容器宽**（同目录页那条）：改窗口宽／开合侧栏不走`apply(items:)`，
    /// 段布局由组合布局自己按新容器重求解。页头高也与容器宽无关——大标题与副标题都是
    /// 单行标签（`fittingSize` 不随宽变），标签排的高是胶囊自己的固有高。
    private func layoutSignature(itemCount: Int) -> String {
        "\(itemCount > 0)|\(headerHeight)"
    }

    // MARK: - 加载 / 空态

    private func updateOverlay() {
        let showsLoading = isLoading
        // 断网优先于空态：三档互斥，一件都没摆出来时「网络不可用 + 重试」盖过
        // 「这个分类暂时没有内容。」——两者从前混成一句，用户看不出该开 Wi-Fi 还是换分类。
        let showsError = !isLoading && items.isEmpty && isOffline
        var emptyMessage: String?
        if !isLoading, !showsError, items.isEmpty {
            switch content {
            case .recentlyPlayed: emptyMessage = "最近播放的音乐会显示在这里。"
            case .tagGroup: emptyMessage = "这个分类暂时没有内容。"
            // 专辑 / 歌单网格页旧版没有空态：交不出内容就只剩一行大标题。
            case .albums, .playlists: emptyMessage = nil
            }
        }

        spinner.isHidden = !showsLoading
        if showsLoading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        errorLabel.stringValue = showsError ? CatalogFeedModel.offlineMessage : ""
        errorBox.isHidden = !showsError

        if let emptyMessage {
            installEmptyHost(message: emptyMessage,
                             image: emptyGlyph(for: content))
        }
        emptyHost?.isHidden = emptyMessage == nil
        overlay.isHidden = !showsLoading && !showsError && emptyMessage == nil

        // 出错块与加载指示同一档落点（都从「内容顶 + loadingTop」开始），
        // 空态那档照旧（最近播放页多让 60）。
        let extra = showsLoading || showsError ? Self.loadingTop
            : (isRecentlyPlayed ? Self.emptyExtraTop : 0)
        overlayTop.constant = headerHeight + Self.headerToContent + extra
    }

    private var isRecentlyPlayed: Bool {
        if case .recentlyPlayed = content { return true }
        return false
    }

    private func emptyGlyph(for content: Content) -> String {
        if case .recentlyPlayed = content { return "clock" }
        return "square.grid.2x2"
    }

    /// 空态沿用 SwiftUI 的 `MusicEmptyStateContent`（它是叶子，不重写）。
    /// 铁律 2：宿主要有定尺寸的槽，高度按它自己的排版算死
    /// （topPadding 150 + 45pt 图标的字形高 ≈ 54 + 间距 12 + 两行 13pt ≈ 40），
    /// 与 `CatalogPageViewController` 里那一份同一条。
    private func installEmptyHost(message: String, image: String) {
        guard emptyHost == nil else { return }
        let host = appState.hostingView {
            MusicEmptyStateContent(message: message, systemImage: image)
        }
        overlay.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            // 空态与加载指示共用同一条「内容顶」（`overlayTop` 那一条）。
            host.topAnchor.constraint(equalTo: spinner.topAnchor),
            host.heightAnchor.constraint(
                equalToConstant: MusicMetrics.EmptyState.topPadding + 54
                    + MusicMetrics.EmptyState.spacing + 40),
        ])
        emptyHost = host
    }

    // MARK: - 组合布局

    private func makeLayout() -> NSCollectionViewLayout {
        NSCollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self else { return CatalogRoomViewController.blankSection() }
            let width = environment.container.contentSize.width
            return index == 0 ? self.headerLayoutSection(containerWidth: width)
                              : self.gridLayoutSection(containerWidth: width)
        }
    }

    private static func blankSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                          heightDimension: .absolute(1))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        return NSCollectionLayoutSection(group: group)
    }

    /// 第 0 段：恒在、没有 item，只把页头那一块摆出来。
    /// **不设 `interGroupSpacing`**——0 个 group 时它会按 −spacing 记进段高。
    private func headerLayoutSection(containerWidth: CGFloat) -> NSCollectionLayoutSection {
        let inner = max(1, containerWidth - P.leadingMargin * 2)
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                          heightDimension: .absolute(1))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: P.leadingMargin,
                                                        bottom: 0, trailing: P.leadingMargin)
        section.boundarySupplementaryItems = [
            NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .absolute(headerPrototype.fittingHeight(forWidth: inner))),
                elementKind: NSCollectionView.elementKindSectionHeader, alignment: .top)
        ]
        return section
    }

    /// 网格段：列宽自适应（下限 `Page.gridItemMinWidth`），列间`gridInterItemSpacing`、
    /// 行间 `gridLineSpacing`，格高 = 列宽（1:1 封面）+`Card.labelHeight`。
    private func gridLayoutSection(containerWidth: CGFloat) -> NSCollectionLayoutSection {
        let inner = max(1, containerWidth - P.leadingMargin * 2)
        let gap = P.gridInterItemSpacing
        // `.adaptive(minimum:)` 的算法：塞得下几列就几列，剩下的宽平摊给各列。
        let columns = max(1, Int((inner + gap) / (P.gridItemMinWidth + gap)))
        let itemWidth = (inner - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (itemWidth + MusicMetrics.Card.labelHeight).rounded()

        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                               heightDimension: .absolute(cellHeight)),
            subitem: item, count: columns)
        group.interItemSpacing = .fixed(gap)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = P.gridLineSpacing
        let bottom: CGFloat
        if case .tagGroup = content { bottom = Self.tagBottomInset } else { bottom = Self.gridBottomInset }
        section.contentInsets = NSDirectionalEdgeInsets(top: Self.headerToContent,
                                                        leading: P.leadingMargin,
                                                        bottom: bottom,
                                                        trailing: P.leadingMargin)
        return section
    }

    // MARK: - 悬浮

    private func refreshHover() {
        guard let window = view.amberWindow, window.isKeyWindow else { setHoveredCard(nil); return }
        updateCardHover(at: collectionView.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// `point` 是 collection view（文稿）坐标。与目录页同一条：由页面在一处 hitTest
    /// 找到鼠标下面那张卡再分发，卡片自己持有悬浮态（铁律 3）。
    private func updateCardHover(at point: NSPoint) {
        guard let superview = collectionView.amberSuperview else { return }
        let inScroll = scrollView.convert(point, from: collectionView)
        guard scrollView.bounds.contains(inScroll) else { setHoveredCard(nil); return }
        var hit = collectionView.hitTest(collectionView.convert(point, to: superview))
        var target: (any CatalogHoverTarget)?
        while let candidate = hit, candidate !== collectionView {
            if let card = candidate as? any CatalogHoverTarget { target = card; break }
            hit = candidate.amberSuperview
        }
        setHoveredCard(target)
    }

    private func setHoveredCard(_ card: (any CatalogHoverTarget)?) {
        guard card !== hoveredCard else { return }
        hoveredCard?.setHovering(false)
        hoveredCard = card
        card?.setHovering(true)
    }

    // MARK: - 键盘（审查单 §2.5-1）

    /// 回车打开选中那一件。落点不在这里另写一份，一律调那一件视图自己的
    /// `accessibilityPerformPress()`——理由与目录页那份逐字相同
    /// （见 `CatalogPageViewController.activateSelection`）。
    private func activateSelection() {
        guard let indexPath = collectionView.selectionIndexPaths.first,
              let item = collectionView.item(at: indexPath) else { return }
        _ = item.view.accessibilityPerformPress()
    }
}

// MARK: - 键盘选择

extension CatalogRoomViewController: NSCollectionViewDelegate {

    /// 选中挪到一件上就把它滚进可视区（这一页只有纵向网格一种段，
    /// 但写法与目录页同一句，那边还要管横向货架）。
    func collectionView(_ collectionView: NSCollectionView,
                        didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first,
              let item = collectionView.item(at: indexPath) else { return }
        _ = item.view.scrollToVisible(item.view.bounds)
    }
}

// MARK: - 覆盖层

/// 盖在 collection view 上的一层，但**不吃点击**：页头在下面，空态期间照样要能点。
private final class RoomOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

// MARK: - 收悬浮的 collection view

private final class RoomCollectionView: NSCollectionView {

    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    /// 回车 / Enter（以及没在播时的空格）落在选中那一件上：打开它。
    var onActivateSelection: (() -> Void)?

    private var hoverArea: NSTrackingArea?

    /// 与目录页 `CatalogShelfCollectionView.keyDown` 同一份（键码、空格那一档的
    /// 判据与理由都在那边写全了）。
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:                                    // Return / Enter
            if activateSelection() { return }
        case 49:                                        // Space
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.isDisjoint(with: [.command, .option, .control]), activateSelection() { return }
        default: break
        }
        super.keyDown(with: event)
    }

    private func activateSelection() -> Bool {
        guard !selectionIndexPaths.isEmpty, let onActivateSelection else { return false }
        onActivateSelection()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // 鼠标仍在可视区域（例如落在卡片上）时不算真的退出。
        if visibleRect.contains(convert(event.locationInWindow, from: nil)) { return }
        onMouseExited?()
    }
}
