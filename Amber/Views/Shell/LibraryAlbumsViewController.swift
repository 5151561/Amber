import AppKit
import SwiftUI

/// 阶段 5：资料库专辑页的 AppKit 网格。
///
/// Music 的这一页没有页内大标题（标题在标题栏），网格从内容列顶端铺开；
/// 卡片是纯 AppKit 的 `LibraryAlbumCardView`（见 `LibraryGridCards.swift`），
/// 列宽换算与「最近添加」共用 `LibraryGridSizing`。
@MainActor
final class LibraryAlbumsViewController: LibraryPageController,
                                         NSCollectionViewDelegate,
                                         NSCollectionViewDelegateFlowLayout {

    /// 这一页只有一段，段身份是个定值。**不是段序号**——身份里掺下标，插一段就把后面
    /// 每一段判成「删了再加」（`reactive-ui-review.md §2.2` 点名的第一类坑）。
    private static let gridSectionID = "library-albums"

    private var collectionView: LibraryGridCollectionView!
    private var dataSource: NSCollectionViewDiffableDataSource<String, String>!
    private var albums: [Album] = []
    /// 身份 → 此刻该画成什么。item provider 与就地重配都问它。
    private var albumsByID: [String: Album] = [:]
    private var laidOutItemWidth: CGFloat = 0
    /// 一张专辑都没有时那片空态（懒建，建好就留着，只切显隐）。
    private var emptyHost: NSView?
    /// 同一轮 runloop 里的多次请求合并成一次（见 `setNeedsRefresh`）。
    private var pendingRefresh = false
    /// 合批期间攒下的「这一批该不该动画」，取最保守的那一声（见 `setNeedsRefresh`）。
    private var pendingAnimated = true
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
        // 少了这一句，`sizeForItemAt` 根本不会被问，flow layout 就退回默认的 50×50 槽。
        collectionView.delegate = self
        collectionView.register(LibraryAlbumCollectionItem.self,
                                forItemWithIdentifier: LibraryAlbumCollectionItem.identifier)
        // `dataSource` 由 diffable 自己接上（它在 init 里就把 `collectionView.dataSource`
        // 指向自己），所以这里不再写 `collectionView.dataSource = self`。
        makeDataSource()
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
        // 首次填充：没有「从哪儿变到哪儿」可言，不动画。
        refresh(animated: false)
        // 这一页真正读的只有四份：专辑集合、曲目（判空专辑用）、专辑喜爱（仅喜爱筛选）、
        // 评分（按星级排序）。从前订的是 `library.objectWillChange` ——
        // 心水一首歌、记一次播放、改一条勾选都会把这一页整个重排一遍。
        let changes = appState.library.changes(affecting: [.albums, .tracks, .favoriteAlbums, .ratings])
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

    /// 刷新入口：合批 + 可见性闸 + 这一批**该不该动画**。
    ///
    /// **合批**照歌曲页那条（`LibrarySongsViewController.setNeedsRefresh`）：同一次用户操作
    /// 常常连着改好几项（改筛选顺带改排序、一次入库同时动专辑与曲目两位），
    /// 一轮 runloop 里来 N 声只重排一次。
    ///
    /// **动画判据按变更的「来由」给，不看差异有多大**——数件数就成了拿样本调阈值
    /// （记忆 `am-no-per-song-tuning`）。来由只有三类：
    /// - 资料库变了（入库 / 退库 / 喜爱 / 星级）：用户刚做完一件事，落到这一页通常是
    ///   一两张碟的增删或挪位，**动画**正是 Music 的样子；
    /// - 搜索词 / 筛选 / 排序变了：一次换掉一大片（每敲一个字都来一次），动起来是满屏乱飞，
    ///   **不动画**；
    /// - 首次填充与切回本页补刷：用户不在场时攒下的差异，**不动画**。
    ///
    /// 合批期间来的几声取最保守的那一声：同一轮里既有资料库变更又有搜索词变更时不动画。
    ///
    /// **可见性闸**：导航容器把访问过的根页全缓存着、切页只切 `isHidden`
    /// （`ContentNavigationController.install`），隐藏的页重排一遍没人看得见，
    /// 只记一笔等 `pageDidAppear()` 补。
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

    /// 筛选（仅喜爱）→ 搜索（专辑名 / 艺人名）→ 排序。规则与旧 `LibraryAlbumsPage` 一字不差。
    private func refresh(animated: Bool) {
        let library = appState.library
        var result = library.libraryAlbums.filter { !library.tracks(in: $0).isEmpty }
        if model.favoritesOnly { result = result.filter { library.isFavoriteAlbum($0) } }
        let matches = library.searchFilter(model.search, kind: .album)
        result = result.filter { matches.keeps($0.id, [$0.name, $0.artistName]) }
        // 身份是 `Album.id`：**不含下标**（插一张碟不会动到其余各件的身份），
        // **不含会变的内容**（碟名、艺人、封面、星级改了仍是同一张碟，只重配不重建）。
        // 唯一一处「内容进了 id」是本地导入碟的 `local:album:<sha1(碟名+艺人)>`——那是
        // 整个 App 的身份口径（`library_album.id` 主键、`albumAddedAt` 的键都是它），
        // 换了名字在库里本来就是另一张碟，不是这里的临时拼接。
        // 去重的原委见 `LibraryGridIdentity.deduplicated`。
        albums = LibraryGridIdentity.deduplicated(sorted(result))
        albumsByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        apply(animated: animated)
        updateEmptyState()
    }

    private func makeDataSource() {
        dataSource = NSCollectionViewDiffableDataSource<String, String>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, identifier in
            let item = collectionView.makeItem(withIdentifier: LibraryAlbumCollectionItem.identifier,
                                               for: indexPath)
            guard let self, let cell = item as? LibraryAlbumCollectionItem,
                  let album = self.albumsByID[identifier] else { return item }
            cell.configure(album: album,
                           width: LibraryGridSizing.itemSize(in: collectionView).width,
                           appState: self.appState)
            return cell
        }
    }

    private func apply(animated: Bool) {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        snapshot.appendSections([Self.gridSectionID])
        snapshot.appendItems(albums.map(\.id), toSection: Self.gridSectionID)
        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            self?.reconfigureVisibleItems()
        }
    }

    /// 身份没变、内容变了的那几件：**复用原来那张卡再装一遍数据**。
    ///
    /// AppKit 的 `NSDiffableDataSourceSnapshot` **没有** `reconfigureItems(_:)`（那是 UIKit
    /// 独有的，原委与做法见 `CatalogPageViewController.reconfigure`），所以这件事只能手写。
    /// 这一页非要它不可的是标题后那颗红 ★：心水一张碟不改专辑的身份，光靠 diff
    /// 那张卡一个字都不会重画，星就亮不起来——从前 `reloadData()` 是顺手全画一遍的。
    /// 同理还有补封面那一路（`LibraryStore.addAlbumToLibrary` 会给已在库的碟回填
    /// `artworkURL`，id 一个字不变）。
    ///
    /// 只走在屏的那几件（`visibleItems()` 本身就是这个界）；没在屏的等下次出队，
    /// item provider 装的就已经是新值。重配不会让封面重取：
    /// `CatalogArtworkView.setArtwork` 对同一个地址原地返回（那一句的注释写了原委）。
    private func reconfigureVisibleItems() {
        guard let collectionView, let dataSource else { return }
        let width = LibraryGridSizing.itemSize(in: collectionView).width
        for case let item as LibraryAlbumCollectionItem in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: item),
                  let id = dataSource.itemIdentifier(for: indexPath),
                  let album = albumsByID[id] else { continue }
            item.configure(album: album, width: width, appState: appState)
        }
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

    // MARK: - 布局

    func collectionView(_ collectionView: NSCollectionView,
                        layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        LibraryGridSizing.itemSize(in: collectionView)
    }
}
