import AppKit
import Combine
import SwiftUI

// MARK: - 资料库歌曲页（AppKit）—— 阶段 5

/// 资料库「歌曲」页。标题栏形态同资料库四页，筛选菜单多一条「查看显示选项」。
///
/// Music.app 这一页（`AMPTrackDisplayController` + `TrackDisplayTableView`）就是一张
/// **NSTableView**：紧凑 22pt 行、斑马纹底色、常驻列头；列宽拖分隔线可调、
/// 列头右键可增删列、拖列头能整列换位，度量里的宽度只是默认值。
/// 页面自身没有大标题——标题在标题栏，表格从内容列顶端直接铺开。
///
/// 骨架（行、列、选择、键盘、拖放）在 `SongsTableView.swift` 里交给 AppKit；
/// 这一页只留「表格之外」的那几件：工具栏、筛选/搜索/排序的取值、空态与刷新驱动。
///
/// 与专辑页音轨行的行为差异（2026-08-15 实机采样，度量见 MusicMetrics.SongsTable）：
/// - 悬浮**不改行底色**，只让云端下载键、空心心水星、空心评分星显形；
/// - ••• 常显且常为品牌红（专辑页是灰色、悬浮才转红）；
/// - 正在播放的曲目不把标题染红，而是在最左那条独立空栏里画一个纯白喇叭；
///   这条栏永远占位，出现喇叭时不会把歌名往右顶。
@MainActor
final class LibrarySongsViewController: ContentPageController {

    private let model = SongsPageModel()
    private lazy var binder = SearchFieldBinder(text: { [model] in model.search }) { [weak self] text in
        self?.model.search = text
    }
    private lazy var menuController = SongsFilterMenuController(settings: appState.songsTable)

    private var scrollView: NSScrollView!
    private var tableView: TrackDisplayTableView!
    private var controller: SongsTableController!
    /// 空态那片叶子。**一片，不是三片**：三个空态分支只换 `rootView`，不拆视图重建。
    private var emptyStateHost: NSHostingView<AnyView>?

    /// 同一轮 runloop 里的多次刷新请求合并成一次（见 `setNeedsRefresh`）。
    private var pendingRefresh = false
    /// 被 `isHidden` 收着期间攒下的刷新，等 `pageDidAppear()` 补。
    private var needsRefreshWhenShown = false

    /// 这一页此刻是什么形态。**表格显不显示、空态显不显示、空态说什么**三件事
    /// 由它一处决定：从前是两个手工保持相反的 `isHidden`，而且空态判据是
    /// 「全库空不空」而不是「这一屏空不空」——搜一个库里没有的词、或者开了「仅喜爱」
    /// 而一首都没心水时，用户看到的是带列头的一片纯空白、零文案（§1 故障 18）。
    /// 形状照 `TrackTableViewController.PageState`（仓库里这件事的正确形状）。
    private enum PageState: Equatable {
        /// 资料库里一首歌都没有。
        case emptyLibrary
        /// 库里有歌，是筛选（仅喜爱 / 重复项）把它们全挡掉了。
        case noFilterMatches
        /// 库里有歌、筛选后也还有货，是搜索词一条都没留下。
        case noSearchMatches
        case content
    }

    /// 「显示重复项目」的页面态：nil ＝ 不在重复视图，非 nil ＝ 正在看哪一档（spec §10.3）。
    ///
    /// **不落盘**，理由照 Music：那边它是内容控制器上的一个位
    /// （原版用一个布尔位记这个状态，spec §10.3.1 `[实测]`）＋一个只读属性
    /// `contentIsShowingDuplicates`，不是偏好。所以这里也只是个实例变量，重启就回常态。
    ///
    /// 切到别的页再回来时**仍留在重复视图**：导航容器把这一页的 VC 留着（见
    /// `ContentNavigationController.install`），这个位也就跟着留着，与 Music 那边
    /// 「位挂在内容控制器上、控制器还活着」同构。
    private var duplicatesMatch: DuplicateMatch?

    init(appState: AppState) {
        super.init(nativePage: appState)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 工具栏

    override var pageToolbarItemIdentifiers: [NSToolbarItem.Identifier] {
        [.amberPageTitle, .flexibleSpace, .amberFilter, .amberSearch]
    }

    override func makePageToolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case .amberPageTitle:
            return ContentToolbarItems.title("歌曲")
        case .amberFilter:
            return ContentToolbarItems.filter(menu: menuController.menu)
        case .amberSearch:
            return ContentToolbarItems.search(placeholder: "在歌曲中查找", binder: binder)
        default:
            return nil
        }
    }

    // MARK: - 生命周期

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))

        let controller = SongsTableController(settings: appState.songsTable,
                                              listSize: appState.listViewSize,
                                              appState: appState)
        self.controller = controller

        let table = TrackDisplayTableView()
        table.controller = controller
        table.dataSource = controller
        table.delegate = controller
        // 内容底色就是窗口背景（实测 rgb(43,43,43)），条纹自己画在它上面
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.style = .plain
        table.gridStyleMask = []
        table.intercellSpacing = .zero
        table.rowSizeStyle = .custom
        table.rowHeight = appState.songsTable.columns.rowHeight(base: appState.listViewSize.rowHeight)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsColumnSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.selectionHighlightStyle = .regular
        table.target = controller
        table.doubleAction = #selector(SongsTableController.tableDoubleClicked(_:))
        // 拖曲目到播放队列：SwiftUI 那边的 dropDestination 是本进程内的落点
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        // 旧 SwiftUI 壳是在外面挂 `.accessibilityElement(children: .contain)`
        // + `.accessibilityLabel("歌曲表格")`，去壳之后由表格自己报这个名字。
        table.setAccessibilityLabel("歌曲表格")
        self.tableView = table

        let header = TrackDisplayNSHeader()
        header.controller = controller
        header.frame = NSRect(x: 0, y: 0, width: 0, height: MusicMetrics.SongsTable.headerHeight)
        table.headerView = header

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        // 顶部内缩交给系统（窗口是 fullSizeContentView，`automaticallyAdjustsContentInsets`
        // 自己按标题栏补 52）；底部给迷你播放器让位——从**安全区**加，自动调整照旧生效
        // （直接写 `contentInsets` 会把自动调整连同顶部那一档一起关掉）。
        // 这一条顶掉旧的 `bottomReserve`：那是`PageHosting.environmentInjected`
        // 给 SwiftUI 宿主挂的 `safeAreaInset`，原生页没有那层了。
        scrollView.additionalSafeAreaInsets = NSEdgeInsets(
            top: 0, left: 0, bottom: MusicMetrics.MiniPlayer.scrollReserve, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        self.scrollView = scrollView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        controller.tableView = table
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bind()
        refresh()
    }

    override func pageDidAppear() {
        super.pageDidAppear()
        // 切回来：被压住期间攒下的那次变动在这里补上（见 `setNeedsRefresh`）。
        if needsRefreshWhenShown {
            needsRefreshWhenShown = false
            refresh()
        }
        // 每次进这一页都滚回第 0 行（Music 的 viewWillAppear 就是无条件
        // `scrollRowToVisible:0`，`[实测]`）。
        // 旧的 SwiftUI 宿主把这一句写在 `makeNSView` 里，只在建视图那一次生效；
        // 导航容器把根页 VC 留着、切页只切 `isHidden`（见`ContentNavigationController.install`
        // 与 `ContentPageController.pageDidAppear`），所以挪到这里，语义反而与 Music 一致。
        tableView.scrollRowToVisible(0)
        // 进页面就把焦点给表格，不用先点一下才能用键盘
        DispatchQueue.main.async { [weak tableView] in
            guard let tableView, tableView.window?.firstResponder !== tableView else { return }
            tableView.window?.makeFirstResponder(tableView)
        }
    }

    // MARK: - 刷新驱动

    /// SwiftUI 那边靠 `updateNSView` 被动重跑，AppKit 侧要显式订阅。
    ///
    /// 每一路都只调 `setNeedsRefresh()`：**`objectWillChange` 是在值变之前发的，
    /// 必须推迟到下一轮 runloop 再读值**，否则读到的还是旧的。
    private func bind() {
        // 这一页读得最宽：曲目集合、心水（筛选）、评分 / 播放次数 / 加入日期（既进筛选
        // 也进排序）、专辑（类型 / 专辑艺人 / 年份几列回查专辑）、勾选列与失联感叹号。
        // 但**不**读播放列表、艺人喜爱、减少推荐——那三位不该把整张表重排一遍。
        appState.library.changes(affecting: [.tracks, .albums, .favorites, .ratings,
                                             .playbackStats, .checkmarks, .fileMissing])
            .sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)

        // 下载态同理（云端列按它排序），否则下完一首、按云端列排的表不会重排
        observers.observe({ [appState] in appState.downloads.states }) { [weak self] _ in
            self?.setNeedsRefresh()
        }

        // 列、排序、筛选、显示插图、始终显示插图都在这里
        observers.observeAny({ [appState] in
            let t = appState.songsTable
            return (t.columns, t.sort, t.filter, t.showArtwork,
                    t.alwaysShowArtwork, t.artworkSize, t.showTrackArtwork)
        }) { [weak self] in self?.setNeedsRefresh() }

        // 行高与字号跟全局的列表尺寸偏好走（Music 的 setupListFontFromPrefs: 每次都去问 prefs）
        observers.observe({ [appState] in appState.listViewSize.size }) { [weak self] _ in
            self?.setNeedsRefresh()
        }

        // 搜索词由标题栏那颗搜索框给（`SongsPageModel` + `SearchFieldBinder`）。
        // 改搜索词是**用户主动换了看法**，这一类才滚回选中行——排序与筛选那两条
        // `SongsTableController` 自己看得见，搜索词它够不着，由这里置位
        // （见 `SongsTableController.scrollsToSelectionOnNextUpdate`）。
        observers.observeNow({ [model] in model.search }) { [weak self] _ in
            self?.controller.scrollsToSelectionOnNextUpdate = true
            self?.setNeedsRefresh()
        }
    }

    /// 合批 + 可见性闸。导航容器把访问过的根页全缓存着、切页只切 `isHidden`
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

    private func refresh() {
        let rows = visibleTracks()
        render(pageState(rows: rows))
        controller.update(rows: rows)
    }

    /// 判据是**这一屏**空不空（`rows`），不是全库空不空——见 `PageState` 上的原委。
    private func pageState(rows: [Track]) -> PageState {
        guard !appState.library.libraryTracks.isEmpty else { return .emptyLibrary }
        guard rows.isEmpty else { return .content }
        // 有搜索词就归给搜索：搜索排在筛选之后，能走到这儿说明筛选那一步还有货。
        return model.search.trimmingCharacters(in: .whitespaces).isEmpty
            ? .noFilterMatches : .noSearchMatches
    }

    /// 表格与空态的显隐**只在这一处一起给**。从前是两个各写各的 `isHidden`，
    /// 靠人保持相反。
    private func render(_ state: PageState) {
        scrollView.isHidden = state != .content
        guard state != .content else {
            emptyStateHost?.isHidden = true
            return
        }
        showEmptyState(state)
    }

    private func showEmptyState(_ state: PageState) {
        if let host = emptyStateHost {
            // 换分支只换 rootView，不拆视图重建（§2.4 就地复用）。
            host.rootView = appState.hostingRoot { emptyStateContent(state) }
        } else {
            let host = appState.hostingView { emptyStateContent(state) }
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.topAnchor.constraint(equalTo: view.topAnchor),
                host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            emptyStateHost = host
        }
        emptyStateHost?.isHidden = false
    }

    /// 三档文案。空库那一档一个像素没动（页内大标题「歌曲」+ 图标 + 原文案）；
    /// 另外两档从前**根本不存在**，用户看到的是一片纯空白。
    @ViewBuilder
    private func emptyStateContent(_ state: PageState) -> some View {
        switch state {
        case .noSearchMatches:
            // [实测] 与搜索结果页同一句（`SearchResultsModel.emptyMessage`，
            // 那句是对着 Music 抄下来的）：同一件事在两页说同一句话。
            topAligned(MusicEmptyStateContent(message: "无结果\n检查拼写或尝试新搜索词。",
                                              systemImage: "magnifyingglass"))
        case .noFilterMatches:
            // Amber 自拟：手头没有 Music 这一档的实测文案。句式跟着上面那句走。
            topAligned(MusicEmptyStateContent(message: "没有符合筛选条件的歌曲。",
                                              systemImage: "line.3.horizontal.decrease.circle"))
        case .emptyLibrary, .content:
            MusicEmptyState(title: "歌曲",
                            message: "添加到资料库的歌曲会显示在这里。",
                            systemImage: "music.note")
        }
    }

    /// 空态的槽是四边钉死整页的，而 `MusicEmptyStateContent` 自己只有内容高——
    /// 不垫这一下 SwiftUI 会把它在整页里竖直居中，与资料库其余几页
    /// （专辑页给的是定高槽，见 `LibraryAlbumsViewController.updateEmptyState`）不一致。
    /// 空库那一档不走这里：`MusicEmptyState` 自带`ScrollView` + 顶对齐的`VStack`。
    private func topAligned(_ content: some View) -> some View {
        VStack(spacing: 0) {
            content
            Spacer(minLength: 0)
        }
    }

    // MARK: - 显示重复项目（spec §10.3）

    /// 一项三态的那颗菜单项（「显示 ▸ 显示重复项目」，选择器见 `MainMenu.Action`）。
    ///
    /// 正在看重复项就退出；否则按**按下这一刻**的 Option 键进宽松/严格档——Music 在
    /// `doShowHideDuplicates:` 里也是现问一次修饰键（`CGSInputModifierKeyState(0, 3)`，
    /// 3 号修饰键 = Option 由 spec §10.10.3 坐实），我们用系统的 `NSEvent.modifierFlags`
    /// 问同一件事。
    @objc func amberShowHideDuplicates(_ sender: Any?) {
        if duplicatesMatch != nil {
            duplicatesMatch = nil
        } else {
            duplicatesMatch = NSEvent.modifierFlags.contains(.option) ? .exact : .loose
        }
        // Music 这时会在状态栏点亮「显示重复项目」（res 163 idx 39 / res 9008 idx 94）。
        // Amber 没有状态栏，这一处照实省掉——不自己发明一条状态栏，也不去改标题栏文案。
        // 与改搜索词同类：这是用户主动换看法，滚回选中行。
        controller.scrollsToSelectionOnNextUpdate = true
        setNeedsRefresh()
    }

    /// 「文件 ▸ 显示简介」（⌘I）。选择器与 `TrackTableViewController.amberGetInfo(_:)` 同名，
    /// 走的是同一条响应链——哪一页在前面就由哪一页接。
    @objc func amberGetInfo(_ sender: Any?) {
        let picked = controller.selectedTracks()
        guard !picked.isEmpty else { return }
        AuxiliaryWindows.shared.showInfoPanel(tracks: picked)
    }

    // MARK: - 筛选 → 重复项 → 搜索 → 排序

    /// 筛选 → 重复项 → 搜索 → 排序，与 Music 工具栏那颗菜单的语义一致。
    private func visibleTracks() -> [Track] {
        compute(tracks: appState.library.libraryTracks,
                filter: appState.songsTable.filter,
                sort: appState.songsTable.sort,
                search: model.search)
    }

    private func compute(tracks: [Track], filter: SongsTableFilter,
                         sort: SongsTableSort, search: String) -> [Track] {
        let library = appState.library
        var result = tracks
        if filter == .favorites {
            result = result.filter { library.isFavorite($0) }
        }
        // 重复项判定排在搜索**之前**：搜索会把一个重复组拆散，先搜后判的话
        // 「搜得到的那一首」在剩下的行里不再有同伴，于是整片消失——用户看到的就是
        // 「一搜重复项就空了」。先在筛选后的全集上判重，再让搜索去缩小结果。
        if let duplicatesMatch {
            result = DuplicateTracksFilter.duplicates(in: result, match: duplicatesMatch)
        }
        // 搜索走 `LibrarySearch`（七处同一个口，见 `LibraryStore.searchFilter`）：
        // 拿回命中的 id，筛的仍是手里这份数组，上面判重、下面排序都不受影响。
        let matches = library.searchFilter(search, kind: .track)
        result = result.filter {
            matches.keeps($0.id, [$0.title, $0.artistName, $0.albumName])
        }
        // 开插图列**不改行序**：插图那一列是「本行与上一行是不是同一张专辑」逐行切出来的
        // （见 SongsAlbumArt / `rebuildAlbumArtTypes`），按标题排就是一首一块，
        // 「始终显示」正是为一行一块准备的。要一张碟连成一块，靠的是把排序列选成专辑
        // （插图列头那三档就是专辑列的排序模式，见 SongsTableSort.AlbumSortMode），
        // 而不是在排完之后再强行并一次组。
        return sort.apply(to: result, library: library, downloads: appState.downloads)
    }
}

@MainActor
extension LibrarySongsViewController: NSMenuItemValidation {
    /// 三态标题在这里现算，照 Music：`-[NativeContentController validateMenuItem:]`
    /// 每次都重新算一次序号（spec §10.3.1 `[实测]`），菜单项本身只有一个动作
    /// `doShowHideDuplicates:`。三条分支与那边的三支一一对应：
    ///
    /// - 正在看重复项（那边的 bit7）→ idx 18 `显示所有项目`，**此时不再看 Option**；
    /// - 否则按住 Option → idx 17 `显示完全重复的项目`（`cinc`：宽松档序号 + 1）；
    /// - 否则 → idx 16 `显示重复项目`。
    ///
    /// 修饰键只在菜单打开的这一刻问一次；菜单已经拉开之后再按 Option 不会当场换标题，
    /// 与 Music 一样——它那边同样是 validate 时问一次 `CGSInputModifierKeyState`。
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // 「文件 ▸ 显示简介」：选中了才可用。这一页不是 `TrackTableViewController` 的子类
        // （它走 `SongsTableController` 那套），所以命令要在这里单独接一份。
        if item.action == MainMenu.Action.getInfo { return !controller.selectedTracks().isEmpty }
        guard item.action == MainMenu.Action.showHideDuplicates else { return true }
        item.title = DuplicatesMenuItem.title(
            showingDuplicates: duplicatesMatch != nil,
            optionDown: NSEvent.modifierFlags.contains(.option))
        // 空资料库里没有「重复」可言，连进都不用进。
        return !appState.library.libraryTracks.isEmpty
    }
}

/// 歌曲页那颗漏斗。菜单结构照 2026-08-15 的 AX 实录：
/// 所有歌曲／仅喜爱 — 分隔 — 排序选项▸ — 分隔 — 查看显示选项。
@MainActor
private final class SongsFilterMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let settings: SongsTableSettings

    init(settings: SongsTableSettings) {
        self.settings = settings
        super.init()
        menu.delegate = self
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()
        for filter in SongsTableFilter.allCases {
            let item = check(filter.title, on: settings.filter == filter,
                             action: #selector(selectFilter))
            item.representedObject = filter
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let sortItem = NSMenuItem(title: "排序选项", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "排序选项")
        for key in settings.columns.sortableColumns {
            let entry = check(SongsTableColumns.title(for: key),
                              on: settings.sort.column == key, action: #selector(selectSortColumn))
            entry.representedObject = key
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(check("升序", on: settings.sort.ascending, action: #selector(selectAscending)))
        submenu.addItem(check("降序", on: !settings.sort.ascending, action: #selector(selectDescending)))
        sortItem.submenu = submenu
        menu.addItem(sortItem)
        menu.addItem(.separator())
        // 旧版是 `openWindow(id: AmberWindow.songsViewOptions)`；面板归 AuxiliaryWindows 之后
        // 走它的开合（Music 的 doShowHideViewOptions: 就是「开着就收，收着就开」）。
        let options = NSMenuItem(title: "查看显示选项", action: #selector(showViewOptions),
                                 keyEquivalent: "")
        options.target = self
        menu.addItem(options)
    }

    private func check(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func selectFilter(_ sender: NSMenuItem) {
        guard let filter = sender.representedObject as? SongsTableFilter else { return }
        settings.filter = filter
    }

    @objc private func selectSortColumn(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? SongsTableColumns.Key else { return }
        settings.sort.column = key
    }

    @objc private func selectAscending() { settings.sort.ascending = true }
    @objc private func selectDescending() { settings.sort.ascending = false }
    @objc private func showViewOptions() { AuxiliaryWindows.shared.toggleSongsViewOptions() }
}
