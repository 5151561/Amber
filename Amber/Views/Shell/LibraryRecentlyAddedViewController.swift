import AppKit
import Combine

/// 阶段 5：资料库「最近添加」的 AppKit 分段网格。
/// 与专辑页共用同一套 cell（`LibraryAlbumCollectionItem`）与列宽换算（`LibraryGridSizing`），
/// 多出来的只是按添加日期分段和段头。
/// 无排序菜单（[实测] 旧栈 `supportedSortOptions` → nil，`recents 规格` §2.2）。
@MainActor
final class LibraryRecentlyAddedViewController: LibraryPageController,
                                                NSCollectionViewDataSource,
                                                NSCollectionViewDelegate,
                                                NSCollectionViewDelegateFlowLayout {

    private var collectionView: LibraryGridCollectionView!
    private var sections: [(String, [Album])] = []
    private var laidOutItemWidth: CGFloat = 0
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
        collectionView.dataSource = self
        // 少了这一句，`sizeForItemAt` 根本不会被问，flow layout 就退回默认的 50×50 槽，
        // 卡片按真实列宽画出来就层层叠在一起。
        collectionView.delegate = self
        collectionView.register(LibraryAlbumCollectionItem.self,
                                forItemWithIdentifier: LibraryAlbumCollectionItem.identifier)
        collectionView.register(RecentSectionHeader.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: RecentSectionHeader.identifier)
        scroll.documentView = collectionView
        view = scroll
        // 标题联动要按滚动位置算当前段：让 clip view 每帧发 bounds 变更。
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        refresh()
        appState.library.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        LibraryGridSizing.reflow(collectionView, lastWidth: &laidOutItemWidth)
        updateDisplayTitle()
    }

    /// 切回来时视图没被摘过，`viewDidLayout` 不一定还会来，标题得自己补一次。
    override func pageDidAppear() {
        super.pageDidAppear()
        updateDisplayTitle()
    }

    @objc private func scrollBoundsChanged() { updateDisplayTitle() }

    /// 滚动联动标题栏标题：显示最后一个「段头已经滚过内容列顶」的段名，
    /// 一段都没滚过时交 nil（基类拿它回落到页名）。Music 同（`recents 规格` §2.1），
    /// 旧 SwiftUI 版是 preference key 收各段头 minY 再挑，这里直接问布局要段头的 frame。
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
            title = sections[index].0
        }
        // 滚动每帧都会来一次，只在段名真的换了时才写回模型。
        guard title != model.displayTitle else { return }
        model.displayTitle = title
    }

    /// 切走：导航容器只把视图 `isHidden` 掉，鼠标不会再发 exited。
    override func pageDidDisappear() {
        super.pageDidDisappear()
        collectionView?.clearHover()
    }

    private func refresh() {
        var albums = appState.library.libraryAlbums
        if model.favoritesOnly { albums = albums.filter { appState.library.isFavoriteAlbum($0) } }
        let q = model.search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { albums = albums.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.artistName.localizedCaseInsensitiveContains(q) } }
        let grouped = Dictionary(grouping: albums) { album -> String in
            guard let date = appState.library.albumAddedDate(for: album) else { return "更早" }
            switch RecentAddedBucket.bucket(of: date) { case .today: return "今天"; case .yesterday: return "昨天"; case .thisWeek: return "本周"; case .lastWeek: return "上周"; case .thisMonth: return "本月"; case .thisYear: return "今年"; case .earlier: return "更早" }
        }
        sections = RecentAddedBucket.allCases.compactMap { b in grouped[b.title].map { (b.title, $0) } }
        collectionView?.reloadData()
        updateDisplayTitle()
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].1.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: LibraryAlbumCollectionItem.identifier, for: indexPath) as! LibraryAlbumCollectionItem
        item.configure(album: sections[indexPath.section].1[indexPath.item],
                       width: LibraryGridSizing.itemSize(in: collectionView).width,
                       appState: appState)
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: RecentSectionHeader.identifier, for: indexPath) as! RecentSectionHeader
        header.title = sections[indexPath.section].0
        return header
    }
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
