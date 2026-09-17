import AppKit
import Combine

/// 侧栏「播放列表」面板（Music 的 `NativePlayQueueViewController`）。
///
/// 规格：playqueue 规格 §3（27 基线）。视图零件在
/// `PlayQueueCells.swift`，数据由批次 A 的`PlayQueueModel` 给。
///
/// 铁律：滚动容器里一个 `NSHostingView` 都没有；悬浮态由表格一处 tracking area 分发给行
/// （照 `SongsTableView.swift` 的`TrackDisplayTableView`——滚轮不发`mouseMoved`，
/// 所以不能每个 cell 各挂一个 tracking area）。
/// [实测] playqueue spec §3.1/§3.3：面板的**重入保护**。
///
/// Music 的面板自己带这一对字段：`updateLock`（+72，重入计数，`loadView` 里
/// `bind("updateLock", toObject: self, withKeyPath: "viewModel.updateLockCount")`）与
/// `updatesPending`（+65）。`kViewModelDataObservationContext` 那条的第一句判的就是
/// 「`updateLock != 0` → 只置`updatesPending = true`」，等这一轮更新做完再补跑。
///
/// 为什么值得单独抽一个类型：这是纯状态机，不碰 AppKit，能不起 App 就单测
/// （见 `AmberTests/PlayQueueLayoutTests.swift`）。而它要挡的正是实机那次栈溢出
/// （`Amber-2026-09-09-042558.ips`）那种「更新过程中又被要求更新」的回环——
/// 用 `while` 补跑而不是递归补跑，即使将来还有别的路径回环也只会多跑一轮，不会加深栈。
final class PlayQueueUpdateGate {

    /// 两种更新各记各的账：快照重建、以及「继续播放」分区头那一行的高度/文案刷新。
    enum Kind {
        case data
        case source
    }

    /// 重入计数。> 0 表示正在做一轮更新。
    private(set) var lockCount = 0
    private(set) var dataPending = false
    private(set) var sourcePending = false

    /// 跑一轮更新。正在跑的时候再来一次，只记账（`updatesPending`），
    /// 由外层那一轮跑完之后接着补跑。
    func perform(_ kind: Kind, _ body: (Kind) -> Void) {
        guard lockCount == 0 else {
            mark(kind)
            return
        }
        var next: Kind? = kind
        while let current = next {
            clear(current)
            lockCount += 1
            body(current)
            lockCount -= 1
            next = nextPending()
        }
    }

    /// 外部（比如 KVO/订阅回调）在锁内时的记账口子。
    func mark(_ kind: Kind) {
        switch kind {
        case .data: dataPending = true
        case .source: sourcePending = true
        }
    }

    private func clear(_ kind: Kind) {
        switch kind {
        case .data: dataPending = false
        case .source: sourcePending = false
        }
    }

    /// 数据优先：快照重建会顺带把分区头重新造一遍，先做它更省一轮。
    private func nextPending() -> Kind? {
        if dataPending { return .data }
        if sourcePending { return .source }
        return nil
    }
}

/// 面板根视图。
///
/// 除了照 §3.2 第 5 条当 `headerContainer`，它还负责**在被宿主收起时自己喊停**：
/// 两个宿主收起面板的做法都是把某一层 `isHidden = true`（主窗是`NSSplitViewItem`
/// 收起分栏列，迷你窗是抽屉高度归零时收 `inspectorContainer`），而`viewDidHide()`
/// 会沿视图树往下发给每一个后代——所以这一处就同时覆盖了两条路，
/// `MainSplitViewController` 不用改。
final class PlayQueuePanelRootView: NSView {

    var onHidden: (() -> Void)?

    override func viewDidHide() {
        super.viewDidHide()
        onHidden?()
    }
}

@MainActor
final class PlayQueueViewController: NSViewController {

    private typealias M = MusicMetrics.PlayQueue

    // MARK: 三条特殊 item identifier（§3.1）

    /// [实测] §3.1 字面量照抄。**`kEmptyMessageCellIdentifier` 只有两条下划线**，
    /// 另外两条是三条——这不是笔误，是 Music 实测的样子。
    static let repeatingCellIdentifier = "___repeatingInfoCell___"
    static let moreCountCellIdentifier = "___moreCountInfoCell___"
    static let emptyMessageCellIdentifier = "__emptyMessageCell__"

    private static let trackCellIdentifier = NSUserInterfaceItemIdentifier("cell")
    private static let singleLineHeaderIdentifier = NSUserInterfaceItemIdentifier("singleLineHeader")
    private static let autoplayHeaderIdentifier = NSUserInterfaceItemIdentifier("autoplayHeader")
    private static let rowViewIdentifier = NSUserInterfaceItemIdentifier("playQueueRow")

    // MARK: 依赖

    private let appState: AppState
    let model: PlayQueueModel

    // MARK: 视图（字段名照 §3.1 的 Music 同名字段）

    private let scrollerSafeArea = NSView()
    private let scroller = NSScrollView()
    private let settings = PlayQueueSettingsExtraHeader(frame: .zero)
    private(set) var theTable: QueueTableView!
    private var dataSource: PlayQueueDataSource!

    // MARK: 状态

    private var cancellables = Set<AnyCancellable>()

    private let observers = TaskBag()
    /// identifier → item，快照重建时一起刷新（cellProvider 与交互都要按 identifier 回查）。
    private var itemsByIdentifier: [String: PlayQueueItem] = [:]
    /// [实测] §3.11 `needsToScrollToIdealRow`
    private var needsToScrollToIdealRow = false
    /// [实测] §3.11 `scrollBackTimer`：5 秒不动就滑回正在播的那一行。
    private var scrollBackTimer: Timer?
    /// [实测] §3.5 `$__lazy_storage_$_autoplayHeaderHeight`
    private var cachedAutoplayHeaderHeight: CGFloat?
    /// 空状态行的高度跟着可视高走，变了要重新问一次 `heightOfRow`。
    private var lastEmptyRowHeight: CGFloat = -1
    /// [实测] §3.1/§3.3 `updateLock` + `updatesPending` 的重入保护，见`PlayQueueUpdateGate`。
    private let updateGate = PlayQueueUpdateGate()
    /// [实测] §3.11 网格线：只在「应有状态」与当前不一致时才写。
    private var lastGridStyleMask: NSTableView.GridLineStyle?
    private var lastPocketHeight: CGFloat = -1

    /// [实测] §3.1 的 `displayStyle` 字段（默认 0）。写入侧只有一处：
    /// `MPContentView` 的状态落地尾段按形态写**三档**——全窗口`{6,7,8}` → 3、
    /// 窗口化 `{3,4,5}` → 1、迷你横条`{0,1,2}` → 2（miniplayer spec §11.7 ★）。
    /// 主窗那条路从来不写，所以保持默认 0。
    ///
    /// **三档各自改了什么外观，规格没坐实**：`playqueue 规格` §3 通篇
    /// 没有读到面板内部哪一处读它。所以这里**只把写入侧接上、不改任何渲染**——
    /// 凭空发明三种外观比留一条空属性更糟。以后挖到读取点，直接在这里的 didSet
    /// 或各 cell 里补差异即可。
    var displayStyle: Int = 0

    // MARK: - 生命周期

    init(appState: AppState) {
        self.appState = appState
        self.model = PlayQueueModel(appState: appState)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// [实测] §3.2 `loadView`：一条 scroller ＋ 一个顶部 pocket 头。
    ///
    /// **pocket 是替代实现**：Music 走 Music 的桌面界面层私有的
    /// `scroller.registerPocketContainer(settings, onEdge: 0)`——把一个视图登记成滚动视图
    /// 顶边的「口袋」，由那套机制去调安全区、让内容从它底下滚过去。没有公开等价物。
    /// 这里用「`settings` 浮在滚动视图之上 ＋`automaticallyAdjustsContentInsets = false`
    /// ＋ `contentInsets.top = 安全区顶 + settings 高」实现同一件事：
    /// - 选它而不是 `additionalSafeAreaInsets`，是因为后者会连带影响表格自身的
    ///   `safeAreaRect`，而 §3.5 的空状态行高正是拿 scroller 的可视高算的，两边会互相咬；
    /// - 选它而不是「把 settings 塞进表格第 0 行」，是因为那样它会跟着滚走，
    ///   而 Music 的 pocket 是钉住不动的。
    /// `settings` 的高由它自己的内容决定，变了从`heightChangedBlock` 回来（§3.9）。
    override func loadView() {
        // [实测] §3.2 第 5 条：根视图（Music 叫 `headerContainer`）的子视图 =
        // [scrollerSafeArea, settings]，顺序即层次，settings 在上面。
        let root = PlayQueuePanelRootView()
        root.translatesAutoresizingMaskIntoConstraints = false
        // 宿主把面板收起时（主窗收分栏列 / 迷你窗抽屉归零）自己把 5 秒回滚停掉，
        // 见 `PlayQueuePanelRootView` 的注释。
        root.onHidden = { [weak self] in self?.panelDidBecomeHidden() }

        // [实测] §3.2 第 7 条：无障碍。文案实测自 Music zh_CN 的 `AX_PLAYQUEUE_CONTAINER`。
        root.setAccessibilityRole(.group)
        root.setAccessibilityElement(true)
        root.setAccessibilityLabel(PlayQueueStrings.containerAXLabel)

        theTable = QueueTableView()
        theTable.controller = self

        // [实测] §3.2 第 2 条：一条空 identifier 的列，autoresizing。
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(""))
        column.resizingMask = .autoresizingMask
        theTable.addTableColumn(column)

        // [实测] §3.2 第 3 条。
        theTable.gridColor = .quaternaryLabelColor
        theTable.gridStyleMask = .solidHorizontalGridLineMask
        theTable.headerView = nil
        theTable.floatsGroupRows = true
        theTable.draggingDestinationFeedbackStyle = .gap
        theTable.allowsMultipleSelection = true
        theTable.backgroundColor = .clear
        theTable.rowHeight = M.fallbackRowHeight
        theTable.style = .inset
        theTable.usesAutomaticRowHeights = false
        theTable.target = self
        theTable.doubleAction = #selector(tableDoubleClicked)
        theTable.delegate = self
        // 曲目拖拽类型直接用 Amber 现成的那一份（`Models/TrackTransfer.swift`，歌曲表起拖时
        // 写的就是它）；另一条是面板内部重排用的私有类型（见 `PlayQueueDataSource`）。
        theTable.registerForDraggedTypes([TrackTransfer.pasteboardType,
                                          PlayQueueDataSource.reorderType])

        // [实测] §3.2 第 1 条。
        scroller.drawsBackground = false
        scroller.hasHorizontalScroller = false
        scroller.hasVerticalScroller = true
        scroller.autohidesScrollers = true
        scroller.automaticallyAdjustsContentInsets = false
        scroller.documentView = theTable
        scroller.translatesAutoresizingMaskIntoConstraints = false

        scrollerSafeArea.translatesAutoresizingMaskIntoConstraints = false
        scrollerSafeArea.addSubview(scroller)
        settings.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollerSafeArea)
        root.addSubview(settings)

        NSLayoutConstraint.activate([
            // scrollerSafeArea 四边贴根，scroller 四边贴 scrollerSafeArea
            scrollerSafeArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollerSafeArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollerSafeArea.topAnchor.constraint(equalTo: root.topAnchor),
            scrollerSafeArea.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroller.leadingAnchor.constraint(equalTo: scrollerSafeArea.leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: scrollerSafeArea.trailingAnchor),
            scroller.topAnchor.constraint(equalTo: scrollerSafeArea.topAnchor),
            scroller.bottomAnchor.constraint(equalTo: scrollerSafeArea.bottomAnchor),
            // [实测] §3.2：settings 水平贴根、顶部贴根的 safeAreaLayoutGuide
            settings.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            settings.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            settings.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        dataSource = makeDataSource()
        theTable.dataSource = dataSource

        settings.heightChangedBlock = { [weak self] _ in self?.updatePocketInsets() }
        settings.onAutoplayToggled = { [weak self] on in self?.model.autoplayEnabled = on }
        settings.onMixingToggled = { [weak self] on in self?.model.mixingEnabled = on }

        // [实测] §3.3 末的**两个** KVO context，一一对位成两条订阅。
        // 合成一条是上一轮那次栈溢出的根因：分不开就只能每次 apply 完对全部行重问高度，
        // 而 `noteHeightOfRows` 内部走`endUpdates`，`endUpdates` 又把 apply 的
        // completion 再打一遍，自己喂自己。
        //
        // ① `kViewModelDataObservationContext`：只重建快照并 apply，**不碰行高**。
        //    行高本来就由 delegate 的 `tableView:heightOfRow:` 在 apply 过程中逐行问。
        observers.add(Task { @MainActor [weak self, model] in
            for await _ in model.dataDidChange.stream() { self?.reload(animated: true) }
        })

        // ② `kViewModelSourceObservationContext`：**只**对「继续播放」那一条分区头行发
        //    `noteHeightOfRowsWithIndexesChanged:`（那行有没有「来自…」决定它 58 还是 44，
        //    §3.5），且这一步在 apply **之外**发。
        observers.add(Task { @MainActor [weak self, model] in
            for await _ in model.sourceDidChange.stream() { self?.reloadContinuePlayingSource() }
        })

        // [实测] §3.11：滚动结束是「5 秒回滚」三个重置点之一。Music 走的是 AMP 滚动视图的
        // `didEndScrollInScrollView:` 回调（`NSScrollView` 没有公开 delegate），
        // 这里用公开的 `didEndLiveScrollNotification` 代替——语义是「用户这一下滑完了」。
        NotificationCenter.default.publisher(for: NSScrollView.didEndLiveScrollNotification,
                                             object: scroller)
            .sink { [weak self] _ in self?.resetScrollBackTimer() }
            .store(in: &cancellables)

        reload(animated: false)
        needsToScrollToIdealRow = true
    }

    override func viewWillLayout() {
        super.viewWillLayout()
        // [实测] §3.11 网格线随宽度：`w > 600` 才画，且只在应有状态与当前不一致时才写。
        // 面板列恒 258 宽，所以实际恒无网格线——照做是为了宽度真变时行为一致。
        //（Music 外面还包了个 feature flag `use_dynamic_queue_grid_lines`，Amber 不需要。）
        let expected: NSTableView.GridLineStyle =
            view.frame.width > M.gridLineWidthThreshold ? .solidHorizontalGridLineMask : []
        if lastGridStyleMask != expected {
            lastGridStyleMask = expected
            theTable.gridStyleMask = expected
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updatePocketInsets()
        updateEmptyRowHeightIfNeeded()
        // [实测] §3.11：`viewDidLayout` 里若`needsToScrollToIdealRow` 且视图有高度，
        // 以 `animated: false` 走一次。
        if needsToScrollToIdealRow, view.frame.height > 0 {
            needsToScrollToIdealRow = false
            scrollToIdealRow(animated: false)
        }
    }

    // MARK: - pocket（§3.2 的替代实现）

    private func updatePocketInsets() {
        guard isViewLoaded else { return }
        let settingsHeight = settings.frame.height > 0 ? settings.frame.height
                                                      : settings.fittingSize.height
        let top = view.safeAreaInsets.top + settingsHeight
        guard abs(top - lastPocketHeight) > 0.5 else { return }
        lastPocketHeight = top
        scroller.contentInsets = NSEdgeInsets(top: top, left: 0,
                                              bottom: MusicMetrics.MiniPlayer.scrollReserve,
                                              right: 0)
        scroller.scrollerInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
    }

    // MARK: - 数据源与快照

    private func makeDataSource() -> PlayQueueDataSource {
        let source = PlayQueueDataSource(tableView: theTable) { [weak self] _, _, _, identifier in
            guard let self else { return NSView() }
            return self.makeCell(for: identifier)
        }
        source.controller = self

        // [实测] §3.3 `rowViewProvider`：复用同一个行视图。Music 用的是
        // `AMPAdjustableDividerTableRow`（AMP 统一画分隔线），Amber 这边不自绘，
        // 让 `.inset` 样式的系统默认选中态/分隔线照常来。
        source.rowViewProvider = { [weak self] table, _, _ in
            guard let self else { return NSTableRowView() }
            if let reused = table.makeView(withIdentifier: Self.rowViewIdentifier, owner: self)
                as? PlayQueueRowView { return reused }
            let row = PlayQueueRowView()
            row.identifier = Self.rowViewIdentifier
            return row
        }

        // [实测] §3.3：分区头走 diffable 的 `sectionHeaderViewProvider`
        //（Music 那个闭包的注册点没坐实，按形状判断就是它，spec 标 [推]）。
        source.sectionHeaderViewProvider = { [weak self] table, _, section in
            guard let self else { return NSView() }
            return self.makeSectionHeader(for: section, in: table)
        }
        return source
    }

    private func makeCell(for identifier: String) -> NSView {
        switch identifier {
        case Self.repeatingCellIdentifier:
            let cell = PlayQueueRepeatingInfoCell(frame: .zero)
            cell.configure(source: model.continuePlayingSource)
            return cell
        case Self.moreCountCellIdentifier:
            let cell = PlayQueueMoreCountInfoCell(frame: .zero)
            cell.configure(count: model.continuePlayingMoreCount)
            return cell
        case Self.emptyMessageCellIdentifier:
            return PlayQueueEmptyMessageCell(frame: .zero)
        default:
            // [实测] §3.3 第 4 支：先复用，复用不到才新建。
            let cell: PlayQueueCell
            if let reused = theTable.makeView(withIdentifier: Self.trackCellIdentifier, owner: self)
                as? PlayQueueCell {
                cell = reused
            } else {
                cell = PlayQueueCell(frame: .zero)
                cell.identifier = Self.trackCellIdentifier
                cell.onMoreClicked = { [weak self] cell in self?.showActionMenu(from: cell) }
            }
            guard let item = itemsByIdentifier[identifier] else { return cell }
            cell.configure(with: item)
            return cell
        }
    }

    private func makeSectionHeader(for section: PlayQueueSection, in table: NSTableView) -> NSView {
        if section == .autoplay {
            if let reused = table.makeView(withIdentifier: Self.autoplayHeaderIdentifier, owner: self) {
                return reused
            }
            let header = PlayQueueAutoplayHeaderCell(frame: .zero)
            header.identifier = Self.autoplayHeaderIdentifier
            return header
        }

        let header: PlayQueueSingleLineHeaderCell
        if let reused = table.makeView(withIdentifier: Self.singleLineHeaderIdentifier, owner: self)
            as? PlayQueueSingleLineHeaderCell {
            header = reused
        } else {
            header = PlayQueueSingleLineHeaderCell(frame: .zero)
            header.identifier = Self.singleLineHeaderIdentifier
        }
        header.fromBlock = nil
        header.actionBlock = nil

        switch section {
        case .history:
            header.configure(title: PlayQueueStrings.historyTitle, source: nil,
                             sourceIsActionable: false, showsClear: false, clearEnabled: false)
        case .upNext:
            header.configure(title: PlayQueueStrings.upNextTitle, source: nil,
                             sourceIsActionable: false, showsClear: false, clearEnabled: false)
        case .continuePlaying:
            configureContinuePlayingHeader(header)
        case .autoplay:
            break
        }
        return header
    }

    /// [实测] §3.6：「清除」的可用性 = `continuePlayingItems` 非空。
    ///
    /// 单独抽出来，是因为「来源变了」那条（§3.3 末第二个 context）要就地把已经在屏上的
    /// 那个头重配一次——Music 的头是 `bind(.viewModel, …)` 自动跟的，Amber 的头是配置式的。
    private func configureContinuePlayingHeader(_ header: PlayQueueSingleLineHeaderCell) {
        header.configure(title: PlayQueueStrings.continuePlayingTitle,
                         source: model.continuePlayingSource,
                         sourceIsActionable: model.continuePlayingSourceIsActionable,
                         showsClear: true,
                         clearEnabled: !model.continuePlayingItems.isEmpty)
        header.fromBlock = { [weak self] in self?.model.doContinuePlayingSourceClicked() }
        header.actionBlock = { [weak self] in self?.model.doClearContinuePlaying() }
    }

    /// [实测] §3.4 快照。对位 `kViewModelDataObservationContext`。
    private func reload(animated: Bool) {
        updateGate.perform(.data) { _ in applySnapshot(animated: animated) }
    }

    private func applySnapshot(animated: Bool) {
        guard isViewLoaded, let dataSource else { return }

        let history = model.historyItems
        let upNext = model.upNextItems
        let continuePlaying = model.continuePlayingItems
        let autoplay = model.autoplayItems

        var lookup: [String: PlayQueueItem] = [:]
        for item in history + upNext + continuePlaying + autoplay {
            lookup[item.identifier] = item
        }
        itemsByIdentifier = lookup

        var snapshot = NSDiffableDataSourceSnapshot<PlayQueueSection, String>()
        if upNext.isEmpty, continuePlaying.isEmpty, autoplay.isEmpty {
            // [实测] §3.4 空状态：**复用「继续播放」这个分区**装一条空状态行，
            // 不另开空状态分区，历史那一段也不装。这个怪法照抄。
            snapshot.appendSections([.continuePlaying])
            snapshot.appendItems([Self.emptyMessageCellIdentifier], toSection: .continuePlaying)
        } else {
            // [实测] §3.4：四对 (分区, 数组) 逐对判空，**空数组的分区不 append**。
            let pairs: [(PlayQueueSection, [PlayQueueItem])] = [
                (.history, history), (.upNext, upNext),
                (.continuePlaying, continuePlaying), (.autoplay, autoplay),
            ]
            for (section, items) in pairs where !items.isEmpty {
                snapshot.appendSections([section])
                snapshot.appendItems(items.map(\.identifier), toSection: section)
                guard section == .continuePlaying else { continue }
                // [实测] §3.4：分区末尾二选一追加一条信息行，互斥，**先判循环**。
                if model.continuePlayingIsRepeating {
                    snapshot.appendItems([Self.repeatingCellIdentifier], toSection: .continuePlaying)
                } else if model.continuePlayingMoreCount >= 1 {
                    snapshot.appendItems([Self.moreCountCellIdentifier], toSection: .continuePlaying)
                }
            }
        }

        // **completion 里什么都不做**：这里原先补了一发「对全部行重问高度」，
        // 而 `noteHeightOfRows` → `endUpdates` → 又打一次本 completion，栈溢出就是这么来的
        // （`Amber-2026-09-09-042558.ips`，第 28–74 帧同一段在循环）。
        // 行高不需要这一发：新插入/被替换的行，`apply` 过程中表格自己会向 delegate 逐行问；
        // 唯一「行没变但高度会变」的是分区头的「来自…」，由 `reloadContinuePlayingSource()`
        // 单独负责（§3.3 末的第二个 context）。
        dataSource.apply(snapshot, animatingDifferences: animated)

        settings.update(autoplayAvailable: model.autoplayAvailable,
                        autoplayEnabled: model.autoplayEnabled,
                        mixingAvailable: model.mixingAvailable,
                        mixingEnabled: model.mixingEnabled,
                        mixingType: model.mixingType)
    }

    /// [实测] §3.3 末 `kViewModelSourceObservationContext`：`continuePlayingSource` 变了。
    ///
    /// **只**碰「继续播放」那一条分区头行——先把它的「来自…」重配一次，再对**这一行**
    /// 发 `noteHeightOfRowsWithIndexesChanged:`（它有没有「来自…」决定 58 还是 44，§3.5）。
    /// 关键在于这一发是在 `apply` **之外**：塞进 apply 的 completion 就会
    /// `endUpdates → completion → endUpdates …` 无限回环。
    private func reloadContinuePlayingSource() {
        updateGate.perform(.source) { _ in applyContinuePlayingSourceChange() }
    }

    private func applyContinuePlayingSourceChange() {
        guard isViewLoaded, let dataSource,
              let row = dataSource.row(forSectionIdentifier: .continuePlaying),
              row >= 0, row < theTable.numberOfRows
        else { return }

        // 头已经在屏上就就地重配；不在屏上不用管，下次 `viewFor` 会带着新值造。
        if let rowView = theTable.rowView(atRow: row, makeIfNecessary: false),
           let header = rowView.subviews.compactMap({ $0 as? PlayQueueSingleLineHeaderCell }).first {
            configureContinuePlayingHeader(header)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            theTable.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
    }

    // MARK: - 行高（§3.5）

    /// 空状态行高：`max(可视高 − 表格上下内缩 − 58, 55)`。
    ///
    /// Music 读的是 `scroller.safeAreaRect.height`；这里的 pocket 是拿`contentInsets`
    /// 做的（见 `loadView` 的注释），所以对应的量是**扣掉内缩之后的可视高**，
    /// 即 clip view 的 bounds 高。
    var emptyRowHeight: CGFloat {
        let visible = scroller.contentView.bounds.height
        let insets = M.insetStyleVerticalInset * 2
        return max(visible - insets - M.emptyRowHeightInset, M.emptyRowMinHeight)
    }

    /// [实测] §3.5 自动连播分区头的懒测量：现造一个 cell，宽 = **控制器根视图**的宽
    /// 减去表格左右内缩（根视图没载入时兜底 270），`layoutSubtreeIfNeeded` 后取
    /// `fittingSize.height`。**量的是根视图的宽，不是表格自身的宽**。
    var autoplayHeaderHeight: CGFloat {
        if let cachedAutoplayHeaderHeight { return cachedAutoplayHeaderHeight }
        let rootWidth = viewIfLoaded.map(\.frame.width) ?? 0
        let base = rootWidth > 0 ? rootWidth : M.autoplayHeaderFallbackWidth
        let width = max(1, base - M.insetStyleHorizontalInset * 2)
        let probe = PlayQueueAutoplayHeaderCell(frame: .zero)
        probe.translatesAutoresizingMaskIntoConstraints = false
        probe.widthAnchor.constraint(equalToConstant: width).isActive = true
        probe.layoutSubtreeIfNeeded()
        let height = probe.fittingSize.height
        cachedAutoplayHeaderHeight = height
        return height
    }

    private func updateEmptyRowHeightIfNeeded() {
        guard let dataSource,
              let row = dataSource.row(forItemIdentifier: Self.emptyMessageCellIdentifier)
        else { return }
        let height = emptyRowHeight
        guard abs(height - lastEmptyRowHeight) > 0.5 else { return }
        // 正在 apply 的时候不要插一发 `noteHeightOfRows`（同 §3.3 那条回环的成因）：
        // 记账留到这一轮更新做完再补，`lastEmptyRowHeight` 也一起留着不写。
        guard updateGate.lockCount == 0 else {
            DispatchQueue.main.async { [weak self] in self?.updateEmptyRowHeightIfNeeded() }
            return
        }
        lastEmptyRowHeight = height
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            theTable.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
    }

    // MARK: - 行 ↔ 模型

    func item(forRow row: Int) -> PlayQueueItem? {
        guard let identifier = dataSource?.itemIdentifier(forRow: row) else { return nil }
        return itemsByIdentifier[identifier]
    }

    /// 行属于哪个分区。分区头行有 section identifier，普通行没有（§3.5），
    /// 所以普通行要往上找最近的那个分区头。
    func section(forRow row: Int) -> PlayQueueSection? {
        guard let dataSource else { return nil }
        if let section = dataSource.sectionIdentifier(forRow: row) { return section }
        var best: (row: Int, section: PlayQueueSection)?
        for section in PlayQueueSection.allCases {
            guard let headerRow = dataSource.row(forSectionIdentifier: section),
                  headerRow <= row else { continue }
            if best == nil || headerRow > best!.row { best = (headerRow, section) }
        }
        return best?.section
    }

    private var selectedItems: [PlayQueueItem] {
        theTable.selectedRowIndexes.compactMap { item(forRow: $0) }
    }

    // MARK: - 交互（§3.10）

    @objc private func tableDoubleClicked() {
        doDoubleClickAction(forRow: theTable.clickedRow)
    }

    private func doDoubleClickAction(forRow row: Int) {
        guard let item = item(forRow: row) else { return }
        model.doDoubleClickAction(for: item)
    }

    /// [实测] §3.10 `keyUp:`。表格把事件转过来（`QueueTableView.keyUp`）。
    func handleKeyUp(_ event: NSEvent) {
        let selected = theTable.selectedRowIndexes
        switch event.keyCode {
        case 0x24:  // Return
            if let row = selected.first { doDoubleClickAction(forRow: row) }
        case 0x33, 0x75:  // Delete / 前向 Delete
            let items = selected.compactMap { item(forRow: $0) }
            if !items.isEmpty {
                model.doDeleteAction(for: items)
                // 删完选区落回夹到 `numberOfRows − 1` 的那一行。
                if let first = selected.first {
                    let target = min(first, theTable.numberOfRows - 1)
                    if target >= 0 {
                        theTable.selectRowIndexes(IndexSet(integer: target),
                                                  byExtendingSelection: false)
                    }
                }
            }
        default:
            break
        }
        // [实测] §3.10：函数尾部重置 5 秒回滚定时器。
        resetScrollBackTimer()
    }

    /// [实测] §3.10 右键菜单：与行内 ••• 共用同一份 `actionMenu(for:)`。
    func menu(forRow row: Int) -> NSMenu? {
        var items = selectedItems
        if !theTable.selectedRowIndexes.contains(row), let clicked = item(forRow: row) {
            items = [clicked]
        }
        guard !items.isEmpty else { return nil }
        return model.actionMenu(for: items)
    }

    private func showActionMenu(from cell: PlayQueueCell) {
        guard let item = cell.item, let menu = model.actionMenu(for: [item]) else { return }
        let button = cell.moreButtonAnchor
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height),
                   in: button)
    }

    // MARK: - 滚动（§3.11）

    /// [实测] §3.11「理想行」：按 upNext → continuePlaying → autoplay 的顺序找第一个
    /// 「存在且非空」的分区，滚到 `分区头行 + 1`——**+1 正是跳过分区头那一行**。
    func idealRow() -> Int? {
        guard let dataSource else { return nil }
        let snapshot = dataSource.snapshot()
        for section in [PlayQueueSection.upNext, .continuePlaying, .autoplay] {
            guard snapshot.sectionIdentifiers.contains(section),
                  snapshot.numberOfItems(inSection: section) > 0,
                  let headerRow = dataSource.row(forSectionIdentifier: section) else { continue }
            return headerRow + 1
        }
        return nil
    }

    /// Music 用的是 AMP 表格的 `scrollRowToTop(_:animated:)`（没有公开等价物）。
    /// 这里直接算 clip view 的 bounds 原点：pocket 是用 `contentInsets` 做的，
    /// 所以「顶」= `rect.minY − contentInsets.top`。
    func scrollToIdealRow(animated: Bool) {
        guard let row = idealRow(), row >= 0, row < theTable.numberOfRows else { return }
        let rect = theTable.rect(ofRow: row)
        let clip = scroller.contentView
        let topInset = scroller.contentInsets.top
        let documentHeight = theTable.frame.height + scroller.contentInsets.bottom
        let maxY = max(-topInset, documentHeight - clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y = min(max(rect.minY - topInset, -topInset), maxY)
        if animated {
            NSAnimationContext.runAnimationGroup { _ in
                clip.animator().setBoundsOrigin(origin)
            }
        } else {
            clip.setBoundsOrigin(origin)
        }
        scroller.reflectScrolledClipView(clip)
    }

    // TODO: [实测] §3.11 惯性滚动吸附还没做。Music 挂的是
    // `scrollViewBeganMomentum:withVelocity:targetContentOffset:`——那是 Music 的桌面界面层自己的
    // 滚动视图回调，`NSScrollView` 既没有 delegate 也没有等价通知（`willStartLiveScroll` /
    // `didEndLiveScroll` 都拿不到惯性落点，改不了它）。要做只能自己接管
    // `scrollWheel(with:)` 的 momentum 阶段推算落点，风险比收益大，先记着：
    // 候选点是三个分区头行，阈值 `thr = min(rowHeight × N, 200)`；
    // `velocity > 0` 判`0 < (minY − t) < thr`（单侧），`velocity ≤ 0` 判
    // `−thr < (t − minY) < thr`（双侧）。少了它只是「滑完不吸附到分区头」，
    // 下面这条 5 秒回滚仍会把面板带回正在播的位置。

    /// 面板被宿主收起（或宿主窗口关掉）时的收尾口子。
    ///
    /// 为什么需要它：迷你播放器窗是 `window.contentView = contents`、**没有
    /// `contentViewController`**（见`MiniPlayerWindowController.buildWindow`），
    /// 所以装在抽屉里的本控制器拿不到 `viewWillAppear` / `viewDidDisappear` 那条链
    /// （`viewDidLoad` / `viewWillLayout` / `viewDidLayout` 照常来）。收起之后
    /// 上面那条 5 秒回滚仍会到点，回滚一片看不见的表格没有意义。
    ///
    /// 定时器本身是 `[weak self]`，不会把控制器吊住；这一句只是别让它空转。
    ///
    /// **驱动只有两处**：
    /// - 「被收起」——`PlayQueuePanelRootView.viewDidHide()`。两个宿主收面板都是把某一层
    ///   `isHidden = true`（主窗是`NSSplitViewItem` 收分栏列，迷你窗是抽屉高度归零时收
    ///   `inspectorContainer`），`viewDidHide()` 沿视图树往下发，一处就覆盖两条路，
    ///   `MainSplitViewController` 不用改；
    /// - 「窗口没了」——`MiniPlayerContentView.viewDidMoveToWindow` 走到`window == nil`。
    ///   这一条 `viewDidHide()` 收不到（移出窗口不算 hidden），所以单独留着。
    func panelDidBecomeHidden() {
        scrollBackTimer?.invalidate()
        scrollBackTimer = nil
    }

    /// 5 秒回滚定时器还在不在。只给单测用——「收起面板要把它停掉」这条
    /// 光看 `-dumpviews` 的 frame 看不出来。
    var isScrollBackTimerArmed: Bool { scrollBackTimer != nil }

    /// [实测] §3.11 ★ 5 秒回滚：选区变化 / keyUp / 滚动结束三处都重置它。
    func resetScrollBackTimer() {
        scrollBackTimer?.invalidate()
        scrollBackTimer = Timer.scheduledTimer(withTimeInterval: M.scrollBackInterval,
                                               repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollToIdealRow(animated: true) }
        }
    }

    // MARK: - 拖拽落点

    /// 外部拖进来的曲目（从歌曲表、专辑页、歌单页的行拖到面板上）。
    /// 换成 AppKit 之后这条要在表格上重接：原先挂在面板那片 SwiftUI 叶子的
    /// `.amberTrackDrop` 上（见`MainView.swift`），那是 SwiftUI 的落点，AppKit 面板收不到。
    func acceptTracks(_ tracks: [Track], before target: PlayQueueItem?) -> Bool {
        guard !tracks.isEmpty else { return false }
        model.acceptDrop(tracks, before: target)
        appState.showToast(tracks.count > 1 ? "已加入待播清单 \(tracks.count) 首"
                                            : "已加入待播清单")
        return true
    }

    func acceptReorder(_ items: [PlayQueueItem], before target: PlayQueueItem?) -> Bool {
        guard !items.isEmpty else { return false }
        model.doReorder(items, before: target)
        return true
    }
}

// MARK: - NSTableViewDelegate

extension PlayQueueViewController: NSTableViewDelegate {

    /// [实测] §3.5 行高。
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let dataSource else { return M.rowHeight }
        // 分区头行才有 section identifier，普通数据行是 nil。
        if let section = dataSource.sectionIdentifier(forRow: row) {
            switch section {
            case .autoplay:
                return autoplayHeaderHeight
            case .continuePlaying:
                return model.continuePlayingSource != nil ? M.headerWithSourceHeight : M.headerHeight
            case .history, .upNext:
                return M.headerHeight
            }
        }
        if dataSource.itemIdentifier(forRow: row) == Self.emptyMessageCellIdentifier {
            return emptyRowHeight
        }
        // 曲目行 ＋ 两条信息行都是 48。
        return M.rowHeight
    }

    /// [实测] §3.10 左右滑动动作：**`edge` 直接忽略，两边同一个「移除」**。
    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int,
                   edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        guard let item = item(forRow: row) else { return [] }
        let action = NSTableViewRowAction(style: .destructive,
                                          title: PlayQueueStrings.removeSwipeAction) {
            [weak self] _, _ in
            self?.model.doDeleteAction(for: [item])
        }
        action.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        return [action]
    }

    /// [实测] §3.10 选区拦截：
    /// ① 两条信息行 ＋ 空状态行不进选区；
    /// ② 多选被限制在同一分区内（spec 里这条标 `[部分]`，
    ///    这里按「新选区里凡是与首个已选行不同分区的都剔掉」实现）。[推]
    func tableView(_ tableView: NSTableView,
                   selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        guard let dataSource else { return proposedSelectionIndexes }
        var result = IndexSet()
        var anchor: PlayQueueSection?
        for row in proposedSelectionIndexes.sorted() {
            guard let identifier = dataSource.itemIdentifier(forRow: row) else { continue }
            guard identifier != Self.repeatingCellIdentifier,
                  identifier != Self.moreCountCellIdentifier,
                  identifier != Self.emptyMessageCellIdentifier else { continue }
            let section = self.section(forRow: row)
            if anchor == nil { anchor = section }
            guard section == anchor else { continue }
            result.insert(row)
        }
        return result
    }

    /// [实测] §3.10：选区变化自己不改模型，只重置 5 秒回滚定时器。
    func tableViewSelectionDidChange(_ notification: Notification) {
        resetScrollBackTimer()
    }
}

// MARK: - 数据源子类（拖拽三件套挂这里）

/// Music 的 `QueueDiffableDataSource`（§3.3）。
///
/// 拖拽是 `NSTableViewDataSource` 的活，而表格的 dataSource 必须是 diffable 那一份，
/// 所以照 Music 一样开一个子类，把三个方法实现在这里、转交给控制器。
@MainActor
final class PlayQueueDataSource: NSTableViewDiffableDataSource<PlayQueueSection, String> {

    weak var controller: PlayQueueViewController?

    /// 面板内部重排用的私有剪贴板类型。**不与曲目拖拽类型混用**：外部拖进来的是
    /// `TrackTransfer`（加入队列），面板内部拖的是「这一项换个位置」，落点动作不一样。
    static let reorderType = NSPasteboard.PasteboardType("com.changlepan.Amber.playqueue.item")

    /// 面板内部重排：只有 `canReorder(_:)` 认的分区才起拖。
    @objc func tableView(_ tableView: NSTableView,
                         pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let controller,
              let item = controller.item(forRow: row),
              let section = controller.section(forRow: row),
              controller.model.canReorder(section)
        else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.identifier,
                                 forType: PlayQueueDataSource.reorderType)
        return pasteboardItem
    }

    @objc func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                         proposedRow row: Int,
                         proposedDropOperation dropOperation: NSTableView.DropOperation)
        -> NSDragOperation {
        // `draggingDestinationFeedbackStyle = .gap`（§3.2）：拖拽时开缝，不高亮整行，
        // 所以落点一律钉成「插在这一行之前」。
        tableView.setDropRow(row, dropOperation: .above)
        let types = info.draggingPasteboard.types ?? []
        if types.contains(PlayQueueDataSource.reorderType) { return .move }
        if types.contains(TrackTransfer.pasteboardType) { return .copy }
        return []
    }

    @objc func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                         row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let controller else { return false }
        let target = controller.item(forRow: row)
        let items = info.draggingPasteboard.pasteboardItems ?? []

        let reordered = items.compactMap {
            $0.string(forType: PlayQueueDataSource.reorderType)
        }.compactMap { identifier in
            controller.itemForIdentifier(identifier)
        }
        if !reordered.isEmpty {
            return controller.acceptReorder(reordered, before: target)
        }

        let tracks = items.flatMap { item -> [Track] in
            guard let data = item.data(forType: TrackTransfer.pasteboardType),
                  let payload = try? JSONDecoder().decode(TrackTransfer.self, from: data)
            else { return [] }
            return payload.tracks
        }
        return controller.acceptTracks(tracks, before: target)
    }

}

extension PlayQueueViewController {
    fileprivate func itemForIdentifier(_ identifier: String) -> PlayQueueItem? {
        itemsByIdentifier[identifier]
    }
}

// MARK: - 表格

/// [实测] §3.2 / §3.8 / §3.10：Music 的 `QueueTableView`（`AMPRolloverTableView` 子类）。
///
/// 悬浮态在表格这一处统一分发（照 `TrackDisplayTableView`：滚轮不发`mouseMoved`，
/// 所以不能每个 cell 各挂 tracking area）。
final class QueueTableView: NSTableView {

    weak var controller: PlayQueueViewController?
    private(set) var rolloverRow = -1

    /// [实测] §3.11：转 super 之后**无条件** `style = .inset` ＋ 清背景。
    ///（Music 里那段比较外观名的代码两支汇合走同一段，是留在原版里的死比较。）
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        style = .inset
        backgroundColor = .clear
    }

    override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
        controller?.handleKeyUp(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        return controller?.menu(forRow: row)
    }

    // MARK: 悬浮

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateRollover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateRollover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setRollover(-1)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        updateRollover(at: convert(event.locationInWindow, from: nil))
    }

    private func updateRollover(at point: NSPoint) {
        setRollover(row(at: point))
    }

    /// ＝ Music 的 `tableView:setRollover:forRow:`：拿到那一行的 cell 调`setRollover:`。
    private func setRollover(_ row: Int) {
        guard row != rolloverRow else { return }
        // 行号先判掉 −1：拿 −1 去问 `view(atColumn:row:)` 会把这一趟中断掉。
        if rolloverRow >= 0 {
            (view(atColumn: 0, row: rolloverRow, makeIfNecessary: false) as? PlayQueueCell)?
                .rollover = false
        }
        rolloverRow = row
        guard row >= 0, row < numberOfRows else { return }
        (view(atColumn: 0, row: row, makeIfNecessary: false) as? PlayQueueCell)?.rollover = true
    }
}

/// 行视图。Music 是 `AMPAdjustableDividerTableRow`（AMP 统一画分隔线），
/// Amber 这边不自绘——`NSTableView.style = .inset` 的系统默认选中态就是要的样子。
final class PlayQueueRowView: NSTableRowView {}
