import AppKit

/// 阶段 5：资料库「最近添加」的 AppKit 分段网格。
/// 与专辑页共用同一套 cell（`LibraryAlbumCollectionItem`）与列宽换算（`LibraryGridSizing`），
/// 多出来的只是按添加日期分段和段头。
/// 无排序菜单（[实测] 旧栈 `supportedSortOptions` → nil，`recents 规格` §2.2）。
@MainActor
final class LibraryRecentlyAddedViewController: LibraryPageController,
                                                NSCollectionViewDelegate,
                                                NSCollectionViewDelegateFlowLayout {

    private var collectionView: LibraryGridCollectionView!
    private var dataSource: NSCollectionViewDiffableDataSource<RecentAddedBucket, String>!
    /// 分好的段。**段身份是 `RecentAddedBucket` 这一位语义键，不是段序号**——
    /// 序号进身份，一次入库把「今天」这一段插到最前面，下面每一段都会被判成
    /// 「删了再加」，整页重建（`reactive-ui-review.md §2.2` 与 §3 第 14 条同一条理由：
    /// 货架横滚位置也是按 `section.id` 存而不是按段序号）。
    /// 段名只是这一位的一个显示形态（`RecentAddedBucket.title`），不再单独存一份。
    private var sections: [(RecentAddedBucket, [Album])] = []
    /// 身份 → 此刻该画成什么。
    private var albumsByID: [String: Album] = [:]
    private var laidOutItemWidth: CGFloat = 0
    /// 同一轮 runloop 里的多次请求合并成一次（见 `setNeedsRefresh`）。
    private var pendingRefresh = false
    /// 合批期间攒下的「这一批该不该动画」，取最保守的那一声（见 `setNeedsRefresh`）。
    private var pendingAnimated = true
    /// 被 `isHidden` 收着期间攒下的刷新，等 `pageDidAppear()` 补。
    private var needsRefreshWhenShown = false
    /// 标题栏标题跟着滚动联动当前段名时的迟滞。
    /// [推] 刚进页面时第一段头还完整可见，这时标题该还是页名「最近添加」——
    /// 旧 SwiftUI 版同样留了 8pt（`displayTitle` 那段注释）。
    private static let titleHysteresis: CGFloat = 8

    init(appState: AppState, model: LibraryPageModel) {
        super.init(nativePage: appState, model: model,
                   title: "最近添加", allItemsTitle: "所有专辑",
                   placeholder: "在最近添加中查找", hasSort: false)
    }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = LibraryGridSizing.placeholder
        layout.headerReferenceSize = NSSize(width: 0, height: RecentSectionHeader.height)
        layout.minimumInteritemSpacing = MusicMetrics.LibraryGrid.gutter
        layout.minimumLineSpacing = MusicMetrics.LibraryGrid.rowSpacing
        // 段头整带 60 已经把段与段之间的留白包在里面了，所以 top 给 0（见 insetForSectionAt）。
        layout.sectionInset = NSEdgeInsets(top: 0,
                                           left: MusicMetrics.LibraryGrid.margin,
                                           bottom: MusicMetrics.LibraryGrid.rowSpacing,
                                           right: MusicMetrics.LibraryGrid.margin)
        collectionView = LibraryGridCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        // 少了这一句，`sizeForItemAt` 根本不会被问，flow layout 就退回默认的 50×50 槽，
        // 卡片按真实列宽画出来就层层叠在一起。
        collectionView.delegate = self
        collectionView.register(LibraryAlbumCollectionItem.self,
                                forItemWithIdentifier: LibraryAlbumCollectionItem.identifier)
        collectionView.register(RecentSectionHeader.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: RecentSectionHeader.identifier)
        // `dataSource` 由 diffable 自己接上（它在 init 里就指向自己），段头也归它的
        // `supplementaryViewProvider`，所以 delegate 那两条数据源方法一并撤了。
        makeDataSource()
        scroll.documentView = collectionView
        view = scroll
        // 标题联动要按滚动位置算当前段：让 clip view 每帧发 bounds 变更。
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        // 首次填充：没有「从哪儿变到哪儿」可言，不动画。
        refresh(animated: false)
        // 这一页读的是：专辑集合与 `albumAddedAt`（分段键）、专辑喜爱（仅喜爱筛选），
        // 外加曲目——`albumAddedDate(for:)` 在旧存档没有 albumAddedAt 时回落取
        // 这张碟里曲目 `addedAt` 的最大值，所以入库/退库一首歌也可能改分段。
        let changes = appState.library.changes(affecting: [.albums, .tracks, .favoriteAlbums])
        observers.add(Task { @MainActor [weak self] in
            for await _ in changes {
                self?.setNeedsRefresh(animated: true)
            }
        })
        // **只订这一页真读的那两项**，不要把整个 `model` 装进一次 `observeAny`：
        // 标题栏标题跟着滚动联动是靠 `updateDisplayTitle()` 写基类的 `displayTitle`，
        // 那一位从前也长在这个共用模型上（`@Published displayTitle`），
        // 接「模型随便哪项变了」就成了自激——滚过一个段头 = 整页重分组 +
        // `reloadData()` 一次。现在那一位已经搬回页控制器自己身上，标题件由基类就地改
        // （`ContentToolbar`），中间不经任何广播，页面这条订阅本来就是多余的。
        // 这一页没有排序菜单（`hasSort: false`），所以 `sort` 也不订。
        observers.observeNow({ [model] in model.search }) { [weak self] _ in
            self?.setNeedsRefresh(animated: false)
        }
        observers.observeNow({ [model] in model.favoritesOnly }) { [weak self] _ in
            self?.setNeedsRefresh(animated: false)
        }
    }

    /// 刷新入口：合批 + 可见性闸 + 动画判据，三条的原委都在
    /// `LibraryAlbumsViewController.setNeedsRefresh` 上（那一份是三页的正本）。
    /// 这一页多一条：段有增删（入库第一张碟开出「今天」这一段）时也不动画，
    /// 与目录页「版式指纹」那条同一口径——整段飞进来比直接换上去更吵。
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

    override func viewDidLayout() {
        super.viewDidLayout()
        LibraryGridSizing.reflow(collectionView, lastWidth: &laidOutItemWidth)
        updateDisplayTitle()
    }

    /// 切回来时视图没被摘过，`viewDidLayout` 不一定还会来，标题得自己补一次；
    /// 被压住期间攒下的那次资料库变动也在这里补。
    override func pageDidAppear() {
        super.pageDidAppear()
        if needsRefreshWhenShown {
            needsRefreshWhenShown = false
            refresh(animated: false)
        }
        updateDisplayTitle()
    }

    @objc private func scrollBoundsChanged() { updateDisplayTitle() }

    /// 滚动联动标题栏标题：显示最后一个「段头已经滚过内容列顶」的段名，
    /// 一段都没滚过时交 nil（基类拿它回落到页名）。Music 同（`recents 规格` §2.1），
    /// 旧 SwiftUI 版是 preference key 收各段头 minY 再挑，这里直接问布局要段头的 frame。
    ///
    /// 写的是**基类页控制器自己的** `displayTitle`，不是四页共用的 `LibraryPageModel`：
    /// 这一位是这一页的一次性显示态，摆进共享模型里迟早又会被谁接成整页刷新
    /// （§5「滚过段头 = 整页重灌」）。滚动每帧都会来一次，只在段名真的换了时才动标题件
    /// ——去重在基类那一处（`displayTitle` 的 `didSet`）。
    private func updateDisplayTitle() {
        guard let collectionView, let layout = collectionView.collectionViewLayout else { return }
        let top = collectionView.visibleRect.minY
        var title: String?
        for index in sections.indices {
            let path = IndexPath(item: 0, section: index)
            guard let header = layout.layoutAttributesForSupplementaryView(
                ofKind: NSCollectionView.elementKindSectionHeader, at: path) else { continue }
            // 段是按先后排的，一旦有一段还没滚过顶，后面的更不可能滚过。
            guard header.frame.minY - top <= Self.titleHysteresis else { break }
            title = sections[index].0.title
        }
        displayTitle = title
    }

    /// 切走：导航容器只把视图 `isHidden` 掉，鼠标不会再发 exited。
    override func pageDidDisappear() {
        super.pageDidDisappear()
        collectionView?.clearHover()
    }

    private func refresh(animated: Bool) {
        var albums = appState.library.libraryAlbums
        if model.favoritesOnly { albums = albums.filter { appState.library.isFavoriteAlbum($0) } }
        let matches = appState.library.searchFilter(model.search, kind: .album)
        albums = albums.filter { matches.keeps($0.id, [$0.name, $0.artistName]) }
        // 分段与身份的正本在 `LibraryGridIdentity.recentSections`（用例钉在那儿）：
        // 段身份是 `RecentAddedBucket` 这一位语义键、不是段序号；件身份是 `Album.id`。
        // 从前这里先把档换成段名再按字符串分组，中间那张 switch 表就是
        // `RecentAddedBucket.title` 自己。
        sections = LibraryGridIdentity.recentSections(albums) { [library = appState.library] in
            library.albumAddedDate(for: $0)
        }
        albumsByID = Dictionary(uniqueKeysWithValues:
            sections.flatMap(\.1).map { ($0.id, $0) })
        apply(animated: animated)
        updateDisplayTitle()
    }

    private func makeDataSource() {
        dataSource = NSCollectionViewDiffableDataSource<RecentAddedBucket, String>(
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
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard kind == NSCollectionView.elementKindSectionHeader else { return nil }
            let header = collectionView.makeSupplementaryView(
                ofKind: kind, withIdentifier: RecentSectionHeader.identifier,
                for: indexPath) as? RecentSectionHeader
            // 段名按**段序**查自己那份 `sections`（它在 `apply` 之前就已经换成新的了，
            // 与目录页 `CatalogPageViewController.layoutSection(at:)` 同一条）。
            // 进快照的身份仍然是 `RecentAddedBucket`，这里只是把它显示出来。
            guard let sections = self?.sections, indexPath.section < sections.count else {
                return header
            }
            header?.title = sections[indexPath.section].0.title
            return header
        }
    }

    private func apply(animated: Bool) {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<RecentAddedBucket, String>()
        for (bucket, albums) in sections {
            snapshot.appendSections([bucket])
            snapshot.appendItems(albums.map(\.id), toSection: bucket)
        }
        // 段有增删就不动画（见 `setNeedsRefresh` 的第二条）。
        let sameSections = dataSource.snapshot().sectionIdentifiers == sections.map(\.0)
        dataSource.apply(snapshot, animatingDifferences: animated && sameSections) { [weak self] in
            self?.reconfigureVisibleItems()
        }
    }

    /// 身份没变、内容变了的那几件就地重配（AppKit 没有 `reconfigureItems`，
    /// 原委见 `LibraryAlbumsViewController.reconfigureVisibleItems`）。
    /// 这一页要它的同样是标题后那颗红 ★。
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

    // MARK: - 布局

    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        LibraryGridSizing.itemSize(in: collectionView)
    }
    /// 段间距全部由段头那 60 的整带给（[AX] 上一段末行底 400 → 下一段顶 406 → 首行 cell 顶 466），
    /// 所以每段上内缩 0；只有最后一段底下多留一点，别让末行贴着迷你播放器。
    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout, insetForSectionAt section: Int) -> NSEdgeInsets {
        NSEdgeInsets(top: 0,
                     left: MusicMetrics.LibraryGrid.margin,
                     bottom: section == sections.count - 1 ? 24 : MusicMetrics.LibraryGrid.rowSpacing,
                     right: MusicMetrics.LibraryGrid.margin)
    }
}

/// 分段头：段名（22 半粗）左沿与网格同在 margin 上，底部留 14 到首行封面。
/// [AX] 「本周」段整带 60（分区顶 406 → 首行 cell 顶 466）。
@MainActor private final class RecentSectionHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("RecentSectionHeader")
    static let height: CGFloat = 60
    var title: String = "" { didSet { label.stringValue = title } }
    private let label = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: MusicMetrics.LibraryGrid.sectionHeaderSize, weight: .bold)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MusicMetrics.LibraryGrid.margin),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MusicMetrics.LibraryGrid.sectionHeaderToGrid),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
