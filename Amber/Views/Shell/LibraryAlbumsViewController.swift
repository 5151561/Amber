import AppKit
import Combine
import SwiftUI

/// 阶段 5：资料库专辑页的 AppKit 网格。
///
/// Music 的这一页没有页内大标题（标题在标题栏），网格从内容列顶端铺开；
/// 卡片是纯 AppKit 的 `LibraryAlbumCardView`（见 `LibraryGridCards.swift`），
/// 列宽换算与「最近添加」共用 `LibraryGridSizing`。
@MainActor
final class LibraryAlbumsViewController: LibraryPageController,
                                         NSCollectionViewDataSource,
                                         NSCollectionViewDelegate,
                                         NSCollectionViewDelegateFlowLayout {

    private var collectionView: LibraryGridCollectionView!
    private var albums: [Album] = []
    private var laidOutItemWidth: CGFloat = 0
    /// 一张专辑都没有时那片空态（懒建，建好就留着，只切显隐）。
    private var emptyHost: NSView?
    /// 同一轮 runloop 里的多次请求合并成一次（见 `setNeedsRefresh`）。
    private var pendingRefresh = false
    /// 被 `isHidden` 收着期间攒下的刷新，等 `pageDidAppear()` 补。
    private var needsRefreshWhenShown = false

    init(appState: AppState, model: LibraryPageModel) {
        super.init(nativePage: appState, model: model,
                   title: "专辑", allItemsTitle: "所有专辑",
                   placeholder: "在专辑中查找", hasSort: true)
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
        layout.sectionInset = NSEdgeInsets(top: MusicMetrics.LibraryGrid.topPadding,
                                           left: MusicMetrics.LibraryGrid.margin,
                                           bottom: 24,
                                           right: MusicMetrics.LibraryGrid.margin)
        collectionView = LibraryGridCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.dataSource = self
        // 少了这一句，`sizeForItemAt` 根本不会被问，flow layout 就退回默认的 50×50 槽。
        collectionView.delegate = self
        collectionView.register(LibraryAlbumCollectionItem.self,
                                forItemWithIdentifier: LibraryAlbumCollectionItem.identifier)
        scroll.documentView = collectionView
        // 空态要盖在网格上，所以外面套一层容器。
        let container = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        bind()
    }

    private func bind() {
        refresh()
        // 这一页真正读的只有四份：专辑集合、曲目（判空专辑用）、专辑喜爱（仅喜爱筛选）、
        // 评分（按星级排序）。从前订的是 `library.objectWillChange` ——
        // 心水一首歌、记一次播放、改一条勾选都会把这一页整个重排一遍。
        appState.library.changes(affecting: [.albums, .tracks, .favoriteAlbums, .ratings])
            .sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        model.objectWillChange
            .sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
    }

    /// 刷新入口：合批 + 可见性闸。
    ///
    /// **合批**照歌曲页那条（`LibrarySongsViewController.setNeedsRefresh`）：一轮 runloop
    /// 里来 N 声只重排一次，而且推迟到下一轮再读值——`model` 那几项是`@Published`，
    /// 在 willSet 发布，当场读到的还是旧值。
    ///
    /// **可见性闸**：导航容器把访问过的根页全缓存着、切页只切 `isHidden`
    /// （`ContentNavigationController.install`），隐藏的页重排一遍没人看得见，
    /// 只记一笔等 `pageDidAppear()` 补。
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

    /// 筛选（仅喜爱）→ 搜索（专辑名 / 艺人名）→ 排序。规则与旧 `LibraryAlbumsPage` 一字不差。
    private func refresh() {
        let library = appState.library
        var result = library.libraryAlbums.filter { !library.tracks(in: $0).isEmpty }
        if model.favoritesOnly { result = result.filter { library.isFavoriteAlbum($0) } }
        let keyword = model.search.trimmingCharacters(in: .whitespaces)
        if !keyword.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(keyword)
                    || $0.artistName.localizedCaseInsensitiveContains(keyword)
            }
        }
        albums = sorted(result)
        collectionView?.reloadData()
        updateEmptyState()
    }

    /// 主排序 + 方向。降序＝升序结果整体反转（与歌曲页 `SongsTableSort` 同法）。
    private func sorted(_ albums: [Album]) -> [Album] {
        let library = appState.library
        let ascending = albums.sorted { lhs, rhs in
            switch model.sort.key {
            case .title: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .year: return (lhs.publishDate ?? "") < (rhs.publishDate ?? "")
            case .genre: return (lhs.genre ?? "") < (rhs.genre ?? "")
            case .rating: return library.rating(for: lhs.id) < library.rating(for: rhs.id)
            }
        }
        return model.sort.ascending ? ascending : ascending.reversed()
    }

    /// 空态沿用 SwiftUI 的 `MusicEmptyStateContent`（它是叶子，不重写）。
    /// 铁律 2：宿主要有定尺寸的槽，高度按它自己的排版算死——与目录页那份同一算法
    /// （topPadding + 45pt 图标字形高 ≈ 54 + 间距 + 两行 13pt ≈ 40）。
    private func updateEmptyState() {
        guard albums.isEmpty else { emptyHost?.isHidden = true; return }
        if emptyHost == nil {
            let host = appState.hostingView {
                MusicEmptyStateContent(message: "添加到资料库的专辑会显示在这里。",
                                       systemImage: "square.stack")
            }
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                host.heightAnchor.constraint(
                    equalToConstant: MusicMetrics.EmptyState.topPadding + 54
                        + MusicMetrics.EmptyState.spacing + 40),
            ])
            emptyHost = host
        }
        emptyHost?.isHidden = false
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        LibraryGridSizing.reflow(collectionView, lastWidth: &laidOutItemWidth)
    }

    /// 切走：导航容器只把视图 `isHidden` 掉，鼠标不会再发 exited，
    /// 不清的话那张卡的悬浮态会原样留到下次切回来。
    override func pageDidDisappear() {
        super.pageDidDisappear()
        collectionView?.clearHover()
    }

    // MARK: - 数据源

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView,
                        numberOfItemsInSection section: Int) -> Int { albums.count }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: LibraryAlbumCollectionItem.identifier,
                                           for: indexPath) as! LibraryAlbumCollectionItem
        item.configure(album: albums[indexPath.item],
                       width: LibraryGridSizing.itemSize(in: collectionView).width,
                       appState: appState)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView,
                        layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        LibraryGridSizing.itemSize(in: collectionView)
    }
}
