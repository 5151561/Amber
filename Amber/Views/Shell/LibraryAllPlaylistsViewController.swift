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
        appState.library.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)
    }

    /// 规则与旧 `LibraryAllPlaylistsPage` 一字不差：
    /// 搜索匹配歌单名与创建者名；「心水歌曲」那张卡只被搜索词过滤，
    /// 筛选「仅喜爱」时它还在、其余歌单让位。
    private func refresh() {
        let keyword = model.search.trimmingCharacters(in: .whitespaces)
        var result: [Entry] = []
        if keyword.isEmpty || "心水歌曲".localizedCaseInsensitiveContains(keyword) {
            result.append(.favorites)
        }
        if !model.favoritesOnly {
            let playlists = keyword.isEmpty ? appState.library.playlists
                : appState.library.playlists.filter {
                    $0.name.localizedCaseInsensitiveContains(keyword)
                        || ($0.source?.creatorName ?? "").localizedCaseInsensitiveContains(keyword)
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
