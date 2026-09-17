import AppKit

/// 资料库「所有播放列表」页（阶段 5 批 A）。
///
/// 形态与专辑页同一台引擎：`NSCollectionView` 流式网格 + `LibraryGridSizing` 的列宽换算，
/// 标题栏三件（标题 / 筛选 ☰ / 搜索）归 `LibraryPageController`。
/// 卡片有两种：「心水歌曲」那张（`LibraryFavoritesCardView`，浅底渐变 + 居中大红星）
/// 与普通歌单卡（`LibraryPlaylistCardView`）。
@MainActor
final class LibraryAllPlaylistsViewController: LibraryPageController,
                                               NSCollectionViewDelegate,
                                               NSCollectionViewDelegateFlowLayout {

    /// 网格里一格的**身份**（正本与原委在 `LibraryGridIdentity.PlaylistEntry`，
    /// 用例钉在那儿）。「心水歌曲」永远排头（Music 的这张卡不参与排序）。
    private typealias EntryID = LibraryGridIdentity.PlaylistEntry

    /// 这一页只有一段，段身份是个定值（不是段序号）。
    private static let gridSectionID = "library-all-playlists"

    private var collectionView: LibraryGridCollectionView!
    private var dataSource: NSCollectionViewDiffableDataSource<String, EntryID>!
    private var entryIDs: [EntryID] = []
    /// 身份 → 此刻该画成什么。`.favorites` 那张卡没有模型，画的是资料库的现值，
    /// 所以只有歌单进这张表。
    private var playlistsByID: [String: LibraryPlaylist] = [:]
    private var laidOutItemWidth: CGFloat = 0
    /// 同一轮 runloop 里的多次请求合并成一次（见 `setNeedsRefresh`）。
    private var pendingRefresh = false
    /// 合批期间攒下的「这一批该不该动画」，取最保守的那一声（见 `setNeedsRefresh`）。
    private var pendingAnimated = true
    /// 被 `isHidden` 收着期间攒下的刷新，等 `pageDidAppear()` 补。
    private var needsRefreshWhenShown = false

    init(appState: AppState) {
        super.init(nativePage: appState, model: LibraryPageModel(),
                   title: "所有播放列表", allItemsTitle: "所有播放列表",
                   placeholder: "在所有播放列表中查找", hasSort: false)
    }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let layout = NSCollectionViewFlowLayout()
        // 内容列宽还没定（这一刻 bounds 是 0）时先用占位尺寸，真实列宽等 `viewDidLayout`。
        layout.itemSize = LibraryGridSizing.placeholder
        layout.minimumInteritemSpacing = MusicMetrics.LibraryGrid.gutter
        layout.minimumLineSpacing = MusicMetrics.LibraryGrid.rowSpacing
        // 旧 SwiftUI 版这一页底垫是 32（专辑页 24），照搬。
        layout.sectionInset = NSEdgeInsets(top: MusicMetrics.LibraryGrid.topPadding,
                                           left: MusicMetrics.LibraryGrid.margin,
                                           bottom: 32,
                                           right: MusicMetrics.LibraryGrid.margin)
        collectionView = LibraryGridCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        // 少了这一句，`sizeForItemAt` 根本不会被问，flow layout 就退回默认的 50×50 槽。
        collectionView.delegate = self
        collectionView.register(LibraryFavoritesCollectionItem.self,
                                forItemWithIdentifier: LibraryFavoritesCollectionItem.identifier)
        collectionView.register(LibraryPlaylistCollectionItem.self,
                                forItemWithIdentifier: LibraryPlaylistCollectionItem.identifier)
        // `dataSource` 由 diffable 自己接上（它在 init 里就指向自己），所以不再写
        // `collectionView.dataSource = self`。
        makeDataSource()
        scroll.documentView = collectionView
        view = scroll
        // 首次填充：没有「从哪儿变到哪儿」可言，不动画。
        refresh(animated: false)
        // 这一页读的是播放列表集合；另加心水这一位，因为置顶那张「心水歌曲」卡上
        // 印的是 `favoriteTracks.count`（见下面的数据源）。除此之外的资料库改动
        // 与它无关——从前订 `library.objectWillChange`，入库一首歌也要重灌一次网格。
        let changes = appState.library.changes(affecting: [.playlists, .favorites])
        observers.add(Task { @MainActor [weak self] in
            for await _ in changes {
                self?.setNeedsRefresh(animated: true)
            }
        })
        // `@Observable` 没有 `objectWillChange` 那条「随便什么变了」的信号——这是好事，
        // 它正是「一次入库把资料库四页全量重算一遍」的由来。这里把本页真读的三项装成
        // 一个快照：与原来等价，而与它们无关的写入不再把这一页叫醒。
        observers.observeAny({ [model] in (model.favoritesOnly, model.search, model.sort) }) { [weak self] in
            self?.setNeedsRefresh(animated: false)
        }
    }

    /// 刷新入口：合批 + 可见性闸 + 动画判据，三条的原委都在
    /// `LibraryAlbumsViewController.setNeedsRefresh` 上（那一份是三页的正本）。
    private func setNeedsRefresh(animated: Bool) {
        guard let view = viewIfLoaded, !view.isHiddenOrHasHiddenAncestor else {
            needsRefreshWhenShown = true
            return
        }
        guard !pendingRefresh else {
            pendingAnimated = pendingAnimated && animated
            return
        }
        pendingRefresh = true
        pendingAnimated = animated
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingRefresh = false
            self.refresh(animated: self.pendingAnimated)
        }
    }

    /// 切回来：被压住期间攒下的那次变动在这里补上。
    override func pageDidAppear() {
        super.pageDidAppear()
        guard needsRefreshWhenShown else { return }
        needsRefreshWhenShown = false
        refresh(animated: false)
    }

    /// 规则与旧 `LibraryAllPlaylistsPage` 一字不差：
    /// 搜索匹配歌单名与创建者名；「心水歌曲」那张卡只被搜索词过滤，
    /// 筛选「仅喜爱」时它还在、其余歌单让位。
    private func refresh(animated: Bool) {
        let keyword = model.search.trimmingCharacters(in: .whitespaces)
        var result: [EntryID] = []
        // 「心水歌曲」是**合成**的一张卡，库里没有它的行，索引也就没有它的 id——
        // 这条特判只能留在内存里按字面匹配。代价是它与下面那批走的不是同一套规则
        //（比如拼音 `xinshui` 搜得到别的歌单、搜不到这张卡），但给一张合成卡
        // 在索引里塞一个假 id 更糟：那个 id 会从搜索结果里漏到别处去。
        if keyword.isEmpty || "心水歌曲".localizedCaseInsensitiveContains(keyword) {
            result.append(.favorites)
        }
        var playlists: [LibraryPlaylist] = []
        if !model.favoritesOnly {
            let matches = appState.library.searchFilter(keyword, kind: .playlist)
            // 去重的原委见 `LibraryGridIdentity.deduplicated`。
            playlists = LibraryGridIdentity.deduplicated(appState.library.playlists.filter {
                matches.keeps($0.id, [$0.name, $0.source?.creatorName ?? ""])
            })
            result.append(contentsOf: playlists.map { EntryID.playlist($0.id) })
        }
        entryIDs = result
        playlistsByID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        apply(animated: animated)
    }

    private func makeDataSource() {
        dataSource = NSCollectionViewDiffableDataSource<String, EntryID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, identifier in
            guard let self else { return NSCollectionViewItem() }
            let width = LibraryGridSizing.itemSize(in: collectionView).width
            switch identifier {
            case .favorites:
                let item = collectionView.makeItem(
                    withIdentifier: LibraryFavoritesCollectionItem.identifier, for: indexPath)
                (item as? LibraryFavoritesCollectionItem)?.configure(
                    favoriteCount: self.appState.library.favoriteTracks.count,
                    width: width, appState: self.appState)
                return item
            case .playlist(let id):
                let item = collectionView.makeItem(
                    withIdentifier: LibraryPlaylistCollectionItem.identifier, for: indexPath)
                guard let playlist = self.playlistsByID[id] else { return item }
                (item as? LibraryPlaylistCollectionItem)?.configure(
                    playlist: playlist, width: width, appState: self.appState)
                return item
            }
        }
    }

    private func apply(animated: Bool) {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<String, EntryID>()
        snapshot.appendSections([Self.gridSectionID])
        snapshot.appendItems(entryIDs, toSection: Self.gridSectionID)
        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            self?.reconfigureVisibleItems()
        }
    }

    /// 身份没变、内容变了的那几件就地重配（AppKit 没有 `reconfigureItems`，
    /// 原委见 `LibraryAlbumsViewController.reconfigureVisibleItems`）。
    ///
    /// 这一页有两处非它不可：
    /// - 置顶那张「心水歌曲」卡印的是 `favoriteTracks.count`，而心水一首歌不改它的身份
    ///   （身份就是 `.favorites` 这一个常量），光靠 diff 那张卡一个字都不会重画；
    /// - 歌单改名 / 换封面 / 增删曲目都不改 `playlist.id`，卡上的名字与副标题同理。
    private func reconfigureVisibleItems() {
        guard let collectionView, let dataSource else { return }
        let width = LibraryGridSizing.itemSize(in: collectionView).width
        for item in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: item),
                  let id = dataSource.itemIdentifier(for: indexPath) else { continue }
            switch id {
            case .favorites:
                (item as? LibraryFavoritesCollectionItem)?.configure(
                    favoriteCount: appState.library.favoriteTracks.count,
                    width: width, appState: appState)
            case .playlist(let playlistID):
                guard let playlist = playlistsByID[playlistID] else { continue }
                (item as? LibraryPlaylistCollectionItem)?.configure(
                    playlist: playlist, width: width, appState: appState)
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        LibraryGridSizing.reflow(collectionView, lastWidth: &laidOutItemWidth)
    }

    /// 切走：导航容器只把视图 `isHidden` 掉，鼠标不会再发 exited。
    override func pageDidDisappear() {
        super.pageDidDisappear()
        collectionView?.clearHover()
    }

    // MARK: - 布局

    func collectionView(_ collectionView: NSCollectionView,
                        layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        LibraryGridSizing.itemSize(in: collectionView)
    }
}
