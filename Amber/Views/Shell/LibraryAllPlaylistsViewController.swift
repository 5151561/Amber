import AppKit
import Combine

/// 资料库「所有播放列表」页（阶段 5 批 A）。
///
/// 形态与专辑页同一台引擎：`NSCollectionView` 流式网格 + `LibraryGridSizing` 的列宽换算，
/// 标题栏三件（标题 / 筛选 ☰ / 搜索）归 `LibraryPageController`。
/// 卡片有两种：「心水歌曲」那张（`LibraryFavoritesCardView`，浅底渐变 + 居中大红星）
/// 与普通歌单卡（`LibraryPlaylistCardView`）。
@MainActor
final class LibraryAllPlaylistsViewController: LibraryPageController,
                                               NSCollectionViewDataSource,
                                               NSCollectionViewDelegate,
                                               NSCollectionViewDelegateFlowLayout {

    /// 网格里的一格。「心水歌曲」永远排头（Music 的这张卡不参与排序）。
    private enum Entry {
        case favorites
        case playlist(LibraryPlaylist)
    }

    private var collectionView: LibraryGridCollectionView!
    private var entries: [Entry] = []
    private var laidOutItemWidth: CGFloat = 0
    /// 同一轮 runloop 里的多次请求合并成一次（见 `setNeedsRefresh`）。
    private var pendingRefresh = false
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
        collectionView.dataSource = self
        // 少了这一句，`sizeForItemAt` 根本不会被问，flow layout 就退回默认的 50×50 槽。
        collectionView.delegate = self
        collectionView.register(LibraryFavoritesCollectionItem.self,
                                forItemWithIdentifier: LibraryFavoritesCollectionItem.identifier)
        collectionView.register(LibraryPlaylistCollectionItem.self,
                                forItemWithIdentifier: LibraryPlaylistCollectionItem.identifier)
        scroll.documentView = collectionView
        view = scroll
        refresh()
        // 这一页读的是播放列表集合；另加心水这一位，因为置顶那张「心水歌曲」卡上
        // 印的是 `favoriteTracks.count`（见下面的数据源）。除此之外的资料库改动
        // 与它无关——从前订 `library.objectWillChange`，入库一首歌也要重灌一次网格。
        appState.library.changes(affecting: [.playlists, .favorites])
            .sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        model.objectWillChange
            .sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
    }

    /// 刷新入口：合批 + 可见性闸，写法与其余四页同一条
    /// （见 `LibraryAlbumsViewController.setNeedsRefresh` 上的原委）。
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
            self.refresh()
        }
    }

    /// 切回来：被压住期间攒下的那次变动在这里补上。
    override func pageDidAppear() {
        super.pageDidAppear()
        guard needsRefreshWhenShown else { return }
        needsRefreshWhenShown = false
        refresh()
    }

    /// 规则与旧 `LibraryAllPlaylistsPage` 一字不差：
    /// 搜索匹配歌单名与创建者名；「心水歌曲」那张卡只被搜索词过滤，
    /// 筛选「仅喜爱」时它还在、其余歌单让位。
    private func refresh() {
        let keyword = model.search.trimmingCharacters(in: .whitespaces)
        var result: [Entry] = []
        // 「心水歌曲」是**合成**的一张卡，库里没有它的行，索引也就没有它的 id——
        // 这条特判只能留在内存里按字面匹配。代价是它与下面那批走的不是同一套规则
        //（比如拼音 `xinshui` 搜得到别的歌单、搜不到这张卡），但给一张合成卡
        // 在索引里塞一个假 id 更糟：那个 id 会从搜索结果里漏到别处去。
        if keyword.isEmpty || "心水歌曲".localizedCaseInsensitiveContains(keyword) {
            result.append(.favorites)
        }
        if !model.favoritesOnly {
            let matches = appState.library.searchFilter(keyword, kind: .playlist)
            let playlists = appState.library.playlists.filter {
                matches.keeps($0.id, [$0.name, $0.source?.creatorName ?? ""])
            }
            result.append(contentsOf: playlists.map { Entry.playlist($0) })
        }
        entries = result
        collectionView?.reloadData()
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

    // MARK: - 数据源

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView,
                        numberOfItemsInSection section: Int) -> Int { entries.count }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let width = LibraryGridSizing.itemSize(in: collectionView).width
        switch entries[indexPath.item] {
        case .favorites:
            let item = collectionView.makeItem(
                withIdentifier: LibraryFavoritesCollectionItem.identifier,
                for: indexPath) as! LibraryFavoritesCollectionItem
            item.configure(favoriteCount: appState.library.favoriteTracks.count,
                           width: width, appState: appState)
            return item
        case .playlist(let playlist):
            let item = collectionView.makeItem(
                withIdentifier: LibraryPlaylistCollectionItem.identifier,
                for: indexPath) as! LibraryPlaylistCollectionItem
            item.configure(playlist: playlist, width: width, appState: appState)
            return item
        }
    }

    func collectionView(_ collectionView: NSCollectionView,
                        layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        LibraryGridSizing.itemSize(in: collectionView)
    }
}
