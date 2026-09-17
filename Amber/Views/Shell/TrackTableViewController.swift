import AppKit

// MARK: - 详情页表格（歌单 / 专辑 / 本地列表）—— 计划阶段 4 批 B
//
// 一页 = 一张 `NSTableView`：第 0 行是页头，中间是曲目行，末行是页脚
// （歌单形态在曲目行之前还有一条 32pt 的浮动列头）。行本身与右键菜单归批 A，
// 这里只通过 `TrackTableContract.swift` 那几个口子拿：`makeRow(in:)` / `rowHeight(for:)` /
// `playlistHeaderHeight` / `makePlaylistHeader(isChart:)` / `menu(for:…)`。
//
// ## 为什么头部能不再回环
//
// 旧版（`DetailViews.swift`）判横竖排要在页面外面套一层`GeometryReader` 量容器宽：
// 量头部自己会形成「量宽 → 改状态 → 换排布 → 再量宽」的回环（计划 §1.1）。
// 表格里这件事不存在：`heightOfRow` 拿**表宽**问头部一次`fittingHeight(forWidth:)`，
// 头部再在 `layout()` 里按同一个`bounds.width` 排一遍。判据是入参，不是排布结果。
//
// ## 左右内缩走安全区，不走 contentInsets
//
// [实测 2026-09-05，probe.swift，macOS 27.0 build 26A5425a]
// `scrollView.additionalSafeAreaInsets = (0, 40, reserve, 40)` 之后：
// `contentInsets == (top: 32, left: 40, bottom: reserve, right: 40)`、
// `automaticallyAdjustsContentInsets` 仍为 true（顶部那一档照旧由系统按标题栏补）、
// 表格 frame 宽 = 可视宽 − 80 且整块右移 40。直接写 `contentInsets` 会把自动调整关掉、
// 连顶部那一档一起丢（与 `CatalogPageViewController` 里那条注释同源）。
//
// 同一次实测还确认了两件事：
// 1. 第 0 行是变高行时，`floatsGroupRows` 照常工作（列头滚到顶会吸住，
//    落在 `_NSScrollViewFloatingSubviewsContainerView` 里）。
// 2. `reloadData(forRowIndexes:columnIndexes:)` **不会**重新问`rowViewForRow`
//    （实测 rowViews +0）。曲目的一切都画在**行视图**里（契约：行只在 `configure` 时读一次），
//    所以播放态/心水/入库/评分变化时这里直接对可见行重调 `configure`，
//    那才是真正会生效的那条路。

// MARK: - 头部视图的口子

/// 第 0 行那块头部：只要能按给定宽度报高度就行。
@MainActor
protocol TrackTableHeaderView: NSView {
    /// 给定宽度下的高度。**只看入参**，不看自己现在多宽。
    func fittingHeight(forWidth width: CGFloat) -> CGFloat
    /// 资料库状态（喜爱 / 入库 / 评分）变了，重画依赖它的那几件。
    func refreshLibraryState()
}

extension TrackTableHeaderView {
    func refreshLibraryState() {}
}

extension DetailHeaderView: TrackTableHeaderView {}

// MARK: - 页面基类

@MainActor
class TrackTableViewController: ContentPageController, NSTableViewDataSource, NSTableViewDelegate {

    enum PageState {
        case loading
        case error(String)
        case content
    }

    /// 表里一行是什么。
    private enum RowKind {
        case header
        /// 歌单形态那条 32pt 列头（浮动 group row）
        case columnHeader
        case track(Int)
        /// 已加载但一首都没有：头部照常在，下面摆空态文案
        case empty
        case footer
    }

    // MARK: 子类的口子

    /// 曲目行形态（决定行高与列）。
    var trackStyle: TrackListStyle { .playlist }
    /// 榜单：列头与行的名次列形态不同。
    var isChart: Bool { false }
    /// 行与列头的左右留白（批 A 的 `TrackRowContentInsetProviding`：表整宽，留白由行自己让）。
    ///
    /// 歌单形态给 **0**：歌单行的第一格就是 40pt 的心水槽，页面留白已经在那 40 里
    /// （旧版 `TrackList` 在歌单页没有任何`padding`；[AX] Music 的行铺满内容列
    /// `[202.5, …, 1267.5]`，小封面 249.5 与头部 270 大封面 242.5 基本齐平）。
    /// 专辑页给 40（行体在留白之内、心水星挂在留白里），本地列表给 34（与页面大标题同一左沿）。
    var trackRowContentInset: CGFloat { 0 }
    /// 头部与下一行之间的空白（算进第 0 行的行高里）。
    var headerBottomSpacing: CGFloat { 0 }
    /// 歌单形态才有 32pt 列头。
    var showsColumnHeader: Bool { false }
    /// 行菜单里的「移除」项标题（资料库播放列表用「从播放列表中删除」），nil 不摆。
    var trackRemoveTitle: String? { nil }
    /// 从这一页起播时，队列面板「继续播放」分区头要显示的「来自《…》」
    /// （[实测] playqueue spec §2.1 `continuePlayingSource` / §2.4 的可点击判定）。
    /// 子类给页面自己的名字与落点；返回 nil 就不摆那一行。
    var queueSource: PlayerController.QueueSource? { nil }
    /// 「从播放列表中删除」。收的是**曲目**不是下标：菜单对整份选中集生效，
    /// 而下标一边删一边往前滑，逐个删会删错位（子类按 id 一次定位一批）。
    func removeTracks(_ tracks: [Track]) {}
    /// 页脚与它距末行的空白；nil = 不摆页脚。
    func makeFooterView() -> NSView? { nil }
    var footerTopSpacing: CGFloat { 0 }
    /// 空态文案（已加载但一首都没有时摆在头部下面）。
    var emptyMessage: String { "这份列表现在是空的。" }
    var emptyImage: String { "music.note.list" }
    /// 子类在数据到位时调 `apply(header:tracks:)` 交这三样。
    private(set) var tracks: [Track] = []

    /// 页底留白（旧版每页都是 `.padding(.bottom, 32)`）。
    private static let pageBottomInset: CGFloat = 32
    /// 加载 / 出错块距页顶的距离（与 `CatalogPageViewController` 同一句）。
    private static let stateTopPadding: CGFloat = 160

    // MARK: 视图

    private let scrollView = NSScrollView()
    let tableView = TrackTableView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("track"))

    private var rows: [RowKind] = []
    private var headerView: (any TrackTableHeaderView)?
    private var columnHeaderView: NSView?
    private var footerView: NSView?
    private var footerContainer: NSView?
    private var emptyView: TrackTableEmptyStateView?
    private var lastLaidOutWidth: CGFloat = 0

    // 三态覆盖层（照 `CatalogPageViewController`：spinner / 图标 + 文案 + 重试）
    private let overlay = TrackTableOverlayView()
    private let spinner = NSProgressIndicator()
    private let errorBox = NSStackView()
    private let errorLabel = NSTextField(labelWithString: "")

    private var state: PageState = .loading

    // MARK: - 生命周期

    override func loadView() {
        // 页面自己不画背景：玻璃只有窗口根那一层（见 RootViewController）。
        let container = NSView()

        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsColumnSelection = false
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.intercellSpacing = .zero
        tableView.rowSizeStyle = .custom
        tableView.usesAutomaticRowHeights = false
        tableView.floatsGroupRows = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        column.minWidth = 1
        column.maxWidth = .greatestFiniteMagnitude
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.trackRowContentInset = trackRowContentInset
        tableView.onActivate = { [weak self] row in self?.playRow(row) }
        tableView.onContextMenu = { [weak self] row in self?.contextMenu(forRow: row) }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        // 顶部内缩交给系统（窗口是 fullSizeContentView，`automaticallyAdjustsContentInsets`
        // 自己按标题栏补 52）；底部给迷你播放器让位——从**安全区**加，自动调整照旧生效
        // （直接写 `contentInsets` 会把自动调整连同顶部那一档一起关掉，见文件头实测）。
        scrollView.additionalSafeAreaInsets = NSEdgeInsets(
            top: 0, left: 0, bottom: MusicMetrics.MiniPlayer.scrollReserve, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        buildOverlay()
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        subscribeRowState()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = tableView.bounds.width
        guard width > 0 else { return }
        // 单列表：列宽跟着表宽走（否则格子视图只有 minWidth 那么宽）。
        if column.width != width { tableView.sizeLastColumnToFit() }
        guard width != lastLaidOutWidth else { return }
        lastLaidOutWidth = width
        // 变高的那几行（头部按宽度判横竖排、页脚按宽度折行）重问一次高度。
        noteVariableRowHeights()
    }

    // MARK: - 数据

    /// 子类拿到数据后调这一句：换头部、换曲目，重建行结构。
    func apply(header: (any TrackTableHeaderView)?, tracks: [Track]) {
        let selection = selectedTrackIDs()
        if let header, header !== headerView {
            headerView?.removeFromSuperview()
            headerView = header
            (header as? DetailHeaderView)?.onHeightChanged = { [weak self] in
                self?.headerHeightChanged()
            }
        } else if header == nil {
            headerView?.removeFromSuperview()
            headerView = nil
        }
        self.tracks = tracks
        state = .content
        rebuildRows(restoringSelection: selection)
    }

    func apply(state: PageState) {
        let selection = selectedTrackIDs()
        self.state = state
        if case .content = state {} else {
            tracks = []
            headerView?.removeFromSuperview()
            headerView = nil
        }
        rebuildRows(restoringSelection: selection)
    }

    /// 曲目变了但头部那块还是同一件（本地播放列表增删歌、心水歌曲变化）。
    func apply(tracks: [Track]) {
        let selection = selectedTrackIDs()
        self.tracks = tracks
        state = .content
        rebuildRows(restoringSelection: selection)
    }

    /// 空态与曲目表 / 页脚是**互斥**的三块，一条布尔管全部。
    ///
    /// [实测] `playlists 规格` §2.1.1（macOS 27 26A5425a 基线）实测 Music 的做法：
    /// 空态 `AMPEmptyStateLockup` **不是覆盖层**，而是`docStack` 竖直栈的第三个
    /// arranged subview（头部照常在第一位）；曲目表 `trackTable`、空态、`footerMargins`
    /// 三者各自 `bind:toObject:withKeyPath:options:` 到同一条 KVO keyPath
    /// **`"playlistIsEmpty"`**（CFString）的`NSHiddenBinding`，
    /// 只有空态那条多带一个 `NSValueTransformerNameBindingOption: NSNegateBooleanTransformerName`
    /// 取反。即**一条布尔同时决定三者显隐**。
    ///
    /// Amber 这里用「摆不摆行」代替 KVO 显隐，语义等价：`tracks.isEmpty` 为真只摆 header + empty，
    /// 列头 / 曲目 / 页脚一个都不摆；为假则反过来不摆空态。不需要为此改成绑定。
    ///
    /// 选区在这里**按身份存取**：`rows` 里的`.track(Int)` 带的是下标，
    /// 换一个排序键、在搜索框里敲一个字之后同一个下标已经是另一首歌，
    /// `reloadData()` 之后照下标恢复等于把高亮指到别的歌上（⌘I、回车播放、右键菜单随之全错）。
    /// 与歌曲表 `SongsTableController.selectedTrackIDs()` /`restore(selection:)` 同一条。
    private func rebuildRows(restoringSelection selection: Set<String>) {
        var rows: [RowKind] = []
        if headerView != nil { rows.append(.header) }
        switch state {
        case .loading, .error:
            break
        case .content:
            if tracks.isEmpty {
                rows.append(.empty)
            } else {
                if showsColumnHeader { rows.append(.columnHeader) }
                rows.append(contentsOf: tracks.indices.map { RowKind.track($0) })
                if footerView == nil { footerView = makeFooterView() }
                if footerView != nil { rows.append(.footer) }
            }
        }
        self.rows = rows
        updateOverlay()
        tableView.reloadData()
        restore(selection: selection)
    }

    /// 当前选中的是哪几首（按 id）。重建行结构**之前**取。
    private func selectedTrackIDs() -> Set<String> {
        Set(selectedTracks().map(\.id))
    }

    /// 按 id 把选区找回来。找不到的（被筛掉了、被删了）自然就不选了。
    private func restore(selection ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var found = IndexSet()
        for (row, kind) in rows.enumerated() {
            guard case .track(let index) = kind, tracks.indices.contains(index),
                  ids.contains(tracks[index].id) else { continue }
            found.insert(row)
        }
        guard !found.isEmpty else { return }
        tableView.selectRowIndexes(found, byExtendingSelection: false)
    }

    /// 页脚文案变了（曲目增删）时子类调它重造。
    func invalidateFooter() {
        footerView = nil
        footerContainer = nil
    }

    // MARK: - 三态

    private func updateOverlay() {
        switch state {
        case .loading:
            overlay.isHidden = false
            spinner.isHidden = false
            spinner.startAnimation(nil)
            errorBox.isHidden = true
        case .error(let message):
            overlay.isHidden = false
            spinner.isHidden = true
            spinner.stopAnimation(nil)
            errorLabel.stringValue = message
            errorBox.isHidden = false
        case .content:
            overlay.isHidden = true
            spinner.stopAnimation(nil)
        }
    }

    private func buildOverlay() {
        overlay.isHidden = true

        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(spinner)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 40, weight: .regular))
        icon.contentTintColor = .tertiaryLabelColor
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        let retry = NSButton(title: "重试", target: self, action: #selector(retryTapped))
        retry.bezelStyle = .push
        errorBox.orientation = .vertical
        errorBox.alignment = .centerX
        errorBox.spacing = 12
        errorBox.setViews([icon, errorLabel, retry], in: .top)
        errorBox.translatesAutoresizingMaskIntoConstraints = false
        errorBox.isHidden = true
        overlay.addSubview(errorBox)

        let top = overlay.safeAreaLayoutGuide.topAnchor
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: top, constant: Self.stateTopPadding),
            errorBox.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            errorBox.topAnchor.constraint(equalTo: top, constant: Self.stateTopPadding),
        ])
    }

    /// 重试。子类覆写成自己的加载入口。
    @objc func retryTapped() {}

    // MARK: - 行高

    /// 空态那块的高。这个数照旧版 `MusicEmptyStateContent` 的排版算死
    /// （顶留白 + 45pt 图标的字形高 ≈ 54 + 间距 + 两行 13pt ≈ 40），
    /// 与 `CatalogPageViewController` / `LibraryAlbumsViewController` 同一句。
    /// 内容比它矮时由 `TrackTableEmptyStateView` 自己在这个高里竖直居中。
    private static let emptyHeight = MusicMetrics.EmptyState.topPadding + 54
        + MusicMetrics.EmptyState.spacing + 40

    private func height(of kind: RowKind, width: CGFloat) -> CGFloat {
        switch kind {
        case .header:
            guard let headerView else { return 0 }
            return headerView.fittingHeight(forWidth: width) + headerBottomSpacing
        case .columnHeader:
            return TrackRowRegistry.playlistHeaderHeight
        case .track:
            return TrackRowRegistry.rowHeight(for: trackStyle)
        case .empty:
            return Self.emptyHeight
        case .footer:
            if footerView == nil { footerView = makeFooterView() }
            let height = footerView.map { ceil($0.fittingSize.height) } ?? 0
            return footerTopSpacing + height + Self.pageBottomInset
        }
    }

    /// 变高的行（头部与页脚）在表宽变化、简介展开时重问。
    private func noteVariableRowHeights() {
        var indexes = IndexSet()
        for (offset, kind) in rows.enumerated() {
            switch kind {
            case .header, .footer: indexes.insert(offset)
            default: break
            }
        }
        guard !indexes.isEmpty else { return }
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
    }

    private func headerHeightChanged() {
        guard let index = rows.firstIndex(where: { if case .header = $0 { return true }; return false })
        else { return }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
    }

    // MARK: - 数据源

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 1 }
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : column.width
        return max(1, height(of: rows[row], width: width))
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        if case .columnHeader = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        if case .track = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .track(let index):
            let rowView = TrackRowRegistry.makeRow(in: tableView)
            rowView.configure(configuration(at: index), appState: appState)
            return rowView
        case .columnHeader:
            return TrackTableGroupRowView()
        case .header, .empty, .footer:
            return TrackTablePlainRowView()
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .header:
            return headerView
        case .columnHeader:
            if columnHeaderView == nil {
                let header = TrackRowRegistry.makePlaylistHeader(isChart: isChart)
                // 列头的左右留白得与行同一条。契约只给了 `makePlaylistHeader(isChart:)`，
                // 没有内缩参数，所以拿到批 A 那件时按页面的值改一次
                // （它自己的默认值是 40，歌单页要的是 0——见 `trackRowContentInset`）。
                (header as? TrackPlaylistHeaderView)?.contentInset = trackRowContentInset
                columnHeaderView = header
            }
            return columnHeaderView
        case .track:
            // 曲目的一切都画在行视图里（契约：`TrackRowViewConfigurable`），格子不摆。
            return nil
        case .empty:
            if emptyView == nil {
                let view = TrackTableEmptyStateView()
                view.translatesAutoresizingMaskIntoConstraints = true
                emptyView = view
            }
            emptyView?.configure(message: emptyMessage, systemImage: emptyImage)
            return emptyView
        case .footer:
            if footerContainer == nil {
                if footerView == nil { footerView = makeFooterView() }
                footerContainer = footerView.map {
                    FooterContainerView(content: $0, topSpacing: footerTopSpacing)
                }
            }
            return footerContainer
        }
    }

    private func configuration(at index: Int) -> TrackRowConfiguration {
        TrackRowConfiguration(
            track: tracks[index],
            index: index + 1,
            style: trackStyle,
            isChart: isChart,
            playContext: TrackPlayContext(tracks: tracks, index: index),
            removeTitle: trackRemoveTitle,
            // 契约里这一对只剩「行自己兜底造菜单」那条路在用（表格不认菜单时），
            // 所以它天然只管这一行。页面上真正弹出来的那份由 `contextMenu(forRow:)` 造，
            // 作用集是整份选中集。
            remove: trackRemoveTitle == nil ? nil : { [weak self] in
                guard let self, tracks.indices.contains(index) else { return }
                removeTracks([tracks[index]])
            },
            showsDivider: index < tracks.count - 1)
    }

    // MARK: - 播放与菜单

    @objc private func tableDoubleClicked() {
        playRow(tableView.clickedRow)
    }

    private func playRow(_ row: Int) {
        guard row >= 0, row < rows.count, case .track(let index) = rows[row] else { return }
        appState.player.play(tracks, startAt: index, source: queueSource)
    }

    /// 行的右键 / ••• 菜单**只在这一处造**。
    ///
    /// 「作用集是哪几首」与「右键先预选」都是页面级事实——只有页面同时看得见
    /// 选中集与行↔曲目的对应关系。从前这件事有两份实现：行视图那份自己按
    /// 行号差推下标算整份选中集，页面这份却在多选时把「从播放列表中删除」整条摘掉，
    /// 于是选 5 首右键，播放/下载/删库作用于 5 首、唯独删除只删被点的那一首。
    /// 现在行视图只把事件转上来（`TrackRowMenuProviding`），这里一处说了算。
    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard row >= 0, row < rows.count, case .track(let index) = rows[row] else { return nil }
        let selected = tableView.selectedRowIndexes
        let indexes: [Int]
        if selected.contains(row) {
            indexes = selected.compactMap { row in
                if case .track(let index) = rows[row] { return index }
                return nil
            }
        } else {
            // 与 Music 一致：右键落在选区之外先把这一行预选上，菜单作用的就是眼前高亮的那些。
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            indexes = [index]
        }
        let picked = indexes.compactMap { tracks.indices.contains($0) ? tracks[$0] : nil }
        guard !picked.isEmpty else { return nil }
        return TrackRowRegistry.menu(
            for: picked,
            playContext: TrackPlayContext(tracks: tracks, index: index),
            removeTitle: trackRemoveTitle,
            remove: trackRemoveTitle == nil ? nil : { [weak self] in self?.removeTracks(picked) },
            appState: appState)
    }

    /// 当前选中的曲目（按行序）。选中集里混着的分组头之类的非曲目行自动滤掉。
    func selectedTracks() -> [Track] {
        tableView.selectedRowIndexes.compactMap { row in
            guard row < rows.count, case .track(let index) = rows[row],
                  tracks.indices.contains(index) else { return nil }
            return tracks[index]
        }
    }

    // MARK: - 「文件 ▸ 显示简介」（⌘I）

    /// 页面级命令，走响应链：不在曲目表页时没人响应，AppKit 自动把菜单项变灰
    /// （与「显示重复项目」同解，见 `MainMenu.Action` 那段注释）。
    ///
    /// 多选先只开第一首——多选态那一套没采过（getinfo spec §5 整节 `[推]`），
    /// 理由同 `TrackActions.getInfoEntry`。
    @objc func amberGetInfo(_ sender: Any?) {
        let picked = selectedTracks()
        guard !picked.isEmpty else { return }
        AuxiliaryWindows.shared.showInfoPanel(tracks: picked)
    }

    // MARK: - 订阅

    /// 播放态 / 心水 / 入库 / 评分变了，重调一遍可见行的 `configure`。
    ///
    /// 用不了 `reloadData(forRowIndexes:columnIndexes:)`：它只重取**格子**，
    /// 而曲目的一切都在行视图里（实测见文件头）。订阅从前一律
    /// `.removeDuplicates().receive(on: DispatchQueue.main)`——`@Published` 在 willSet 发布，
    /// 不落到下一轮读属性会慢一拍；`Observations` 自带相邻去重、又在值落定之后才发，
    /// 两样都不需要了。
    private func subscribeRowState() {
        let player = appState.player
        let library = appState.library

        // 原来是六条 publisher 各自 sink，现在两条 observeAny：播放器那三项一条、
        // 资料库那三项一条。分两条是因为元组元数有上限，也因为两边本来就是两个来源。
        observers.observeAny({ [player] in (player.currentIndex, player.queue, player.isPlaying) }) {
            [weak self] in self?.refreshVisibleRows()
        }
        observers.observeAny({ [library] in (library.favoriteTracks, library.libraryTracks, library.ratings) }) {
            [weak self] in self?.refreshVisibleRows()
        }
    }

    /// 在场的曲目行重配一遍；头部那几件（喜爱星、入库键、星级）也跟着刷。
    ///
    /// 走 `enumerateAvailableRowViews` 而不是按`visibleRect` 算行号：可视区之外表格还留着
    /// 一圈已装配好的行，滚回来时**不会**再问一次`rowViewForRow`，漏掉它们就会看到
    /// 旧状态滚进视野（专辑页入库换形态那一路尤其明显——那一整列星级就是这么补上的）。
    func refreshVisibleRows() {
        headerView?.refreshLibraryState()
        tableView.enumerateAvailableRowViews { rowView, row in
            guard row >= 0, row < rows.count, case .track(let index) = rows[row],
                  let configurable = rowView as? any TrackRowViewConfigurable else { return }
            configurable.configure(configuration(at: index), appState: appState)
        }
    }
}

// MARK: - 表格

/// 回车播放选中行；右键把行号交给页面拿菜单。
/// ⌘A 走响应链（`NSTableView.selectAll(_:)` 本来就在，且会问`shouldSelectRow`，
/// 头部与页脚不会被选上）。
///
/// 空格归「控制 ▸ 播放/暂停」，由 `AmberApplication.sendEvent` 抢在响应链之前送进主菜单
/// （无修饰等价键在 AppKit 里排在第一响应者之后，表格会先把它吃掉——实测见
/// `AmberApplication` 的类型注释）。落到这里的空格只剩一档：**没有正在播的曲目**时
/// 那条菜单项是禁用的，`performKeyEquivalent` 返回 false，事件才回到响应链——
/// 这时按回车的语义办，播选中的这一首。
final class TrackTableView: NSTableView, TrackRowContentInsetProviding, TrackRowMenuProviding {

    /// 页面左右留白，交给批 A 的行（`TrackRowRegistry.makeRow(in:)` 会来读）。
    var trackRowContentInset: CGFloat = 0

    var onActivate: ((Int) -> Void)?
    var onContextMenu: ((Int) -> NSMenu?)?

    /// 行视图（右键与 •••）把事件转上来，菜单由页面一处造。
    func trackRowMenu(forRow row: Int) -> NSMenu? { onContextMenu?(row) }

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        if characters == "\r" || characters == "\u{3}" || characters == " ",
           event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
           selectedRow >= 0 {
            onActivate?(selectedRow)
            return
        }
        super.keyDown(with: event)
    }

    /// 右键落在行视图之外（列头、页脚、表底空白）时才走这条；落在曲目行上时
    /// 命中测试先到行视图，由它经 `trackRowMenu(forRow:)` 转回来（见`TrackRowView.menu(for:)`）。
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return super.menu(for: event) }
        return trackRowMenu(forRow: row)
    }
}

/// 头部 / 空态 / 页脚那几行：不选中、不悬浮、不画底色。
private final class TrackTablePlainRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// 歌单列头那一行。吸顶（`isFloating`）时才铺一层不透明底，
/// 否则底下滚过去的曲目行会透出来；平铺时保持透明，让窗口那层玻璃照常透上来。
private final class TrackTableGroupRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        guard isFloating else { return }
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

/// 页脚：内容贴在行的上边距之下，行的其余高度是页底留白。
private final class FooterContainerView: NSView {
    private let content: NSView

    override var isFlipped: Bool { true }

    private let topSpacing: CGFloat

    init(content: NSView, topSpacing: CGFloat) {
        self.content = content
        self.topSpacing = topSpacing
        super.init(frame: .zero)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let height = ceil(content.fittingSize.height)
        content.frame = NSRect(x: 0, y: topSpacing, width: bounds.width, height: height)
    }
}

/// 空态那一块：旧版 SwiftUI `MusicEmptyStateContent` 的 AppKit 版。
///
/// 铁律 2 不许在滚动容器的格子里挂 `NSHostingView`，而这块只是一个图标 + 一行字，
/// 占不上「里面真有 SwiftUI 才能做的控件」那条例外。
///
/// **位置一个像素不动**：它仍然是表格的一行，不是覆盖层——[实测] `playlists 规格`
/// §2.1.1 记的就是 Music 把 `AMPEmptyStateLockup` 摆在`docStack` 里（见`rebuildRows`
/// 的头注），页头在它上面，两件一起滚。行高仍是 `emptyHeight`。
///
/// 排版照 `MusicEmptyStateContent` 逐条搬：
/// - 图标 `EmptyState.iconSize`（45）、`.light`、`tertiaryLabelColor`（＝ SwiftUI 的`.tertiary`）；
/// - 文字 `NSFont.systemFontSize`（实测 13）、`secondaryLabelColor`、居中、
///   最宽 `EmptyState.maxTextWidth`；
/// - 两件之间 `EmptyState.spacing`，整组头上还有`EmptyState.topPadding`；
/// - 整组在行高里**竖直居中**——原先那个宿主就是这么摆的（`NSHostingView` 文档原话：
///   帧与内容不一样大时内容在帧里居中，`LibrarySongsViewController.topAligned`
///   那段注释记的是同一件事）。单行文案时这一居中恰好把整组往下推 12。
private final class TrackTableEmptyStateView: NSView {
    private typealias M = MusicMetrics.EmptyState

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleNone
        icon.imageAlignment = .alignCenter
        icon.contentTintColor = .tertiaryLabelColor
        addSubview(icon)

        // 铁律 6：字号用系统默认（`NSFont.systemFontSize`，实测 13），
        // 旧版 `MusicEmptyStateContent` 写死的`.system(size: 13)` 正是这个数。
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.cell?.usesSingleLineMode = false
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 自上而下排，坐标系跟着翻。
    override var isFlipped: Bool { true }

    func configure(message: String, systemImage: String) {
        icon.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: M.iconSize, weight: .light))
        label.stringValue = message
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // `NSTextField` 的 cell 左右各留 2pt，SwiftUI 的`Text` 没有：框要比 SwiftUI 那条
        // `maxWidth` 宽出这 4pt，折行点才落在同一个字上（`CatalogCardKit.labelInset`）。
        let inset = CatalogCardKit.labelInset
        let textWidth = min(M.maxTextWidth, max(0, bounds.width - inset * 2))
        let boxWidth = textWidth + inset * 2
        let textHeight = ceil(label.sizeThatFits(
            NSSize(width: boxWidth, height: .greatestFiniteMagnitude)).height)
        let iconSize = icon.image?.size ?? .zero
        let iconWidth = ceil(iconSize.width)
        let iconHeight = ceil(iconSize.height)
        let contentHeight = M.topPadding + iconHeight + M.spacing + textHeight
        // 居中不取整：SwiftUI 那边是几何居中，取整会在高度差是奇数时推歪 1。
        var y = (bounds.height - contentHeight) / 2 + M.topPadding
        icon.frame = NSRect(x: (bounds.width - iconWidth) / 2, y: y,
                            width: iconWidth, height: iconHeight)
        y += iconHeight + M.spacing
        label.frame = NSRect(x: (bounds.width - boxWidth) / 2, y: y,
                             width: boxWidth, height: textHeight)
    }
}

/// 覆盖层自己不吃点击（照 `CatalogOverlayView`）。
private final class TrackTableOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

@MainActor
extension TrackTableViewController: NSMenuItemValidation {
    /// 「文件 ▸ 显示简介」只在选中了曲目时可用；没选中时整条变灰
    /// （不在这一页时压根没人响应这个选择器，AppKit 自己就把它灰掉了）。
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == MainMenu.Action.getInfo else { return true }
        return !selectedTracks().isEmpty
    }
}
