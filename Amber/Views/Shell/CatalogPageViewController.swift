import AppKit
import SwiftUI

// MARK: - 目录页（主页 / 新发现 / 广播 / 艺人）的 AppKit 页面控制器
//
// 计划 design-ref/appkit-rewrite-plan.md 阶段 3 批 A：把原来一棵 SwiftUI
// `ScrollView + LazyVStack + LazyHStack` 的目录页换成
// `NSScrollView + NSCollectionView + NSCollectionViewCompositionalLayout`。
// 卡片本身由批 B 的 `NSCollectionViewItem` 负责，本文件只碰页面骨架：
// 布局、数据源、段头、翻页箭头、三态。
//
// ## 为什么艺人页也是这台引擎（阶段 4 最后一批）
//
// Music 自己就是这么干的：艺人目录页的容器 `ArtistDetailPageView` 与主页/新发现/广播
// 共用同一个状态机 `CatalogPagePresenter<Page>`（`artistpage 规格` §0 的边界那段
// 明写「页面容器本身、状态机是 `catalogpage` scope 的题目」；`catalogpage 规格` §1
// 是那台引擎的规格）。艺人页 = 满幅 hero 段 + 「最新發行 / 熱門歌曲」并排带 + 「專輯」货架，
// 三段都是目录页的段，**不是**一张详情表格。所以 Amber 这边也同构：
// `ArtistDetailViewController` 是`CatalogPageViewController` 的子类、吃`ArtistPageModel`，
// 而不是 `TrackTableViewController` 的子类。
//
// 为此本文件做了三处泛化，都由子类开关，其它三页一个像素不动：
// 1. 数据源解耦成 `CatalogPageModelProviding`（`CatalogFeedModel` / `ArtistPageModel` 都实现）；
// 2. `showsPageTitle`：艺人页没有页面大标题（Music 的艺人页标题栏与页面里都不摆标题）；
// 3. `extendsUnderTitlebar`：艺人页要把`automaticallyAdjustsContentInsets` 关掉、
//    顶部内缩置 0，大图自己把标题栏那 52 画满。
//
// ## 翻页箭头走的是「布局内部那个横向 scroll view」这条路
//
// [实测 2026-09-05，独立探针 probe.swift / probe2.swift / probe3.swift / probe4.swift，
//  macOS 27.0 build 26A5425a]：
//
// 1. `orthogonalScrollingBehavior = .continuous` 的段，布局内部会造一个
//    `_NSCollectionScrollView`，它是 **collection view 的直接子视图**，
//    从该段任意一个可见 item 的 `view.enclosingScrollView` 就能拿到（探针里
//    `scroll.superview === collectionView` 为 true）。
// 2. `contentView.animator().setBoundsOrigin(_:)` 能驱动它，动画平滑（探针里
//    0.3 秒动画收到 17 次中间态通知），落位精确。
// 3. 给它的 clip view 打开 `postsBoundsChangedNotifications` 之后，
//    `NSView.boundsDidChangeNotification` 每一帧都到——箭头显隐可以只看真实几何，
//    跟旧 SwiftUI 版 `onScrollGeometryChange` 同一条判据。
//
// 三条都成立，所以**不需要**退回「每个货架一个 item 里套自己的横向 collection view」
// 的嵌套方案。嵌套方案要自己存每段 offset、自己做复用、还会多一层响应者树，
// 正是这次重写要消掉的东西。
//
// 4. 另一条关键实测：orthogonal 段的 `contentInsets.leading/trailing` **不缩窄裁切范围**。
//    内部 scroll view 的 frame 始终是整段宽（探针：窗宽 1000 时 `(0, y, 1000, h)`），
//    内缩是加在它的**文稿**里的（`docSize = 34 + n*卡宽 + (n-1)*20 + 34`）。
//    也就是说卡片滑出时贴着内容列边缘被裁掉，与 Music 一致，
//    等同于旧版 SwiftUI 那句 `safeAreaPadding(.horizontal, 34)`。所以照常用`contentInsets`，
//    不用把内缩挪进 group 的 leading spacing。
//
// ## 纵向节奏怎么落到布局上
//
// [实测 probe4]：`NSCollectionLayoutSection.contentInsets.top` 落在**段头与 item 之间**，
// 不在段头上方；`supplementariesFollowContentInsets` 默认开，段头自己吃掉左右 34。
// 所以「上一段卡底 → 本段标题顶」这段空白只能放进**本段段头自己的高度**里：
//
//     段头高 = topGap + 标题行高 + M.headingToContent(13)
//
// 无标题段没有段头，同一个 `topGap` 就走`contentInsets.top`。
// 空段（0 个 item）只占段头那点高（探针 probe3/probe4 实测），但**别给它设
// `interGroupSpacing`**——0 个 group 时那条间距会按 −spacing 记进段高（probe4 实测
// 段头 38 高的空段只占了 18）。
//
// ## 页面大标题为什么是「第 0 段的段头」而不是布局的全局头
//
// [实测 probe2]：`NSCollectionViewCompositionalLayoutConfiguration.boundarySupplementaryItems`
// 在快照里 **0 段时整个被丢掉**（AppKit 自己打日志：`indexPath.section (0) >= numberOfSections (0);
// ignoring them`）。加载中 / 出错 / 空态这三种状态下页面一条内容段都没有，标题行却要照常显示，
// 所以标题行做成**恒在的第 0 段的段头**：0 个 item 的段只占段头的高，三态与有内容时走同一条路。

// MARK: - 页面数据源的口子

/// 目录页引擎认的数据源。`CatalogFeedModel`（主页/新发现/广播）与
/// `ArtistPageModel`（艺人页）都实现它，页面控制器只认这个协议。
///
/// 两边都是 `@Observable`。以前这里还有一条 `statePublisher`，是因为协议里写不了
/// `@Published`、只好另开一条 `$state.eraseToAnyPublisher()` 的桥；`@Observable` 之后
/// 观察的是属性本身，那条桥连同它要求的 `receive(on:)`（`@Published` 在 willSet 发布，
/// 当场读别的属性会读到旧值）一起没了。
@MainActor
protocol CatalogPageModelProviding: AnyObject {
    /// 页面大标题（`showsPageTitle` 为假的页面不摆，只用于空态文案上下文）
    var title: String { get }
    var emptyMessage: String { get }
    var emptyImage: String { get }
    var state: CatalogPageState { get }
    /// 换音源 / 首次上屏 / 错误页点「重试」
    func reload()
    /// 本地资料库那几段（最近播放 / 音乐回忆）变了：只重算它们，不发音源请求。
    /// 只有主页那份模型有这种段，别家默认什么都不做。
    func refreshLocalSections()
}

extension CatalogPageModelProviding {
    func refreshLocalSections() {}
}

/// 钉在页面内容**底下**、不随文稿滚的背景层（艺人页的满幅封面，`ArtistBackdropView`）。
/// 页面控制器只负责把它插到 scroll view 底下、把纵向滚动位置转发给它。
@MainActor
protocol CatalogPageBackdroping: NSView {
    /// clip view 的 bounds origin.y 变了（含回到 0）。
    func catalogPageScrollOffsetDidChange(_ offset: CGFloat)
}

@MainActor
class CatalogPageViewController: ContentPageController {

    private typealias M = MusicMetrics.Catalog
    private typealias A = MusicMetrics.ArtistPage

    // MARK: 常量（都不进 MusicMetrics：要么是系统默认算出来的，要么是本页私有的）

    /// 页底留白。[AX] 主页最后一段卡底到文稿底 24。
    private static let pageBottomInset: CGFloat = 24
    /// 加载 / 出错块距标题行底的距离（旧 SwiftUI 版 `.padding(.top, 160)`，一个不改）。
    private static let stateTopPadding: CGFloat = 160
    /// 翻页胶囊 [PX] 28×52，骑在内容列边上（中心正对 leadingMargin）。
    private static let arrowSize = NSSize(width: 28, height: 52)

    /// 标题行的高 = 32pt bold 裸标签的自然高（系统默认 38；Music 的 AXHeading 报 40，
    /// 但它的**字形底** 123 与这里 85+38=123 对得上，见汇报里的预计 frame）。
    private static let titleHeight = labelHeight(for: NSFont.systemFont(ofSize: M.titleSize, weight: .bold))
    /// 段标题行高 = 15pt semibold 裸标签的自然高（系统默认 19，与 [AX] 段标题带 19 一致）。
    static let headingHeight = labelHeight(for: NSFont.systemFont(ofSize: M.headingSize, weight: .semibold))

    /// 裸标签的自然高。AGENTS「界面层」第 6 条：能靠系统默认给的就别在 MusicMetrics 立常量。
    private static func labelHeight(for font: NSFont) -> CGFloat {
        let probe = NSTextField(labelWithString: "Ag首页")
        probe.font = font
        return ceil(probe.fittingSize.height)
    }

    // MARK: 子类的口子（三个开关，默认全是主页/新发现/广播原来的行为）

    /// 是否摆恒在的第 0 段页面大标题。艺人页给 false：Music 的艺人页标题栏与页面里
    /// 都不摆标题，顶上直接就是那张满幅大图。
    var showsPageTitle: Bool { true }

    /// 内容是否要穿到标题栏底下（顶部内缩置 0）。艺人页给 true：大图从窗口顶开始画，
    /// 标题栏那 52 由图自己铺满。其余三页保持 false —— 那 52 是
    /// `automaticallyAdjustsContentInsets` 给的系统默认（AGENTS「界面层」第 6 条）。
    var extendsUnderTitlebar: Bool { false }

    /// 这一页是否跟着「当前音乐源」走（标题栏摆音乐源切换胶囊、换源就重拉）。
    /// 艺人页给 false：艺人本身属于某个音源，换源不该把这一页重拉成别人的艺人。
    var followsSelectedProvider: Bool { true }

    /// **没有页面大标题**的页面，首段上面留多少空白。默认 0（艺人页那张满幅 hero
    /// 要顶着窗口顶画，一点空白都不让）；搜索结果页拨成 14（旧版 SwiftUI 的
    /// `.padding(.top, 14)`）。摆页面大标题的三页不看这条——它们的首段空白由
    /// `titleToHeading` / `titleToContent` 定。
    var firstSectionTopGap: CGFloat { 0 }

    /// 钉在内容底下的背景层。艺人页给满幅封面（`ArtistBackdropView`）：
    /// Music 的艺人页图**不随文稿滚**（滚起来是图从清晰变糊、栏目从图上划过），
    /// 所以图不能是 collection view 里的一件，得钉在 scroll view 底下。
    func makePinnedBackdrop() -> (any CatalogPageBackdroping)? { nil }

    // MARK: 状态

    let model: any CatalogPageModelProviding

    private let scrollView = NSScrollView()
    private let collectionView = CatalogShelfCollectionView()
    private var dataSource: NSCollectionViewDiffableDataSource<String, CatalogEntryID>!

    /// 钉住的背景层（艺人页有，其余页 nil）。见 `makePinnedBackdrop()`。
    /// lazy：`makePinnedBackdrop()` 是实例方法，init 里 super.init 之前调不得。
    private lazy var pinnedBackdrop: (any CatalogPageBackdroping)? = makePinnedBackdrop()

    /// 布局按段序号分派要看的表。与快照同时更新；越界一律给一段空段兜底。
    /// 首值在 `viewDidLoad` 里按`showsPageTitle` 定（不摆标题的页面从空表起）。
    private var layoutSections: [PageLayoutSection] = []
    /// 货架段的翻页参数（按段序号）。
    private var shelfMetrics: [Int: ShelfMetrics] = [:]
    /// 上一次算过卡宽的内容列宽，用来只在真的换宽时重算（与资料库网格同一条）。
    private var laidOutWidth: CGFloat = 0
    private var itemsByID: [CatalogEntryID: CatalogItem] = [:]
    /// 宽度还没落定时挡下来的那一份快照，等 `viewDidLayout` 补灌（见`apply(sections:)`）。
    private var pendingSections: [CatalogSection]?
    /// 切走期间台账变过：这一页被压住时不灌快照（滚动位置、悬浮态都还挂在上面，
    /// 灌了也没人看），记一笔等 `pageDidAppear()` 再补。
    private var needsLocalRefresh = false
    /// 上一份快照的**版式指纹**（段序 / 每段件数 / 容器宽），见 `apply(sections:)` 末尾。
    private var lastLayoutSignature: String?
    private var tracksByID: [CatalogEntryID: Track] = [:]

    // 三态覆盖层
    private let overlay = CatalogOverlayView()
    private let spinner = NSProgressIndicator()
    private let errorBox = NSStackView()
    private let errorLabel = NSTextField(labelWithString: "")
    private var emptyHost: NSView?

    // 翻页箭头（悬浮态由 tracking area + 这几个自己持有的字段推，不经 @Published）
    private lazy var leftArrow = CatalogShelfArrowButton(direction: .left) { [weak self] in
        self?.pageHoveredShelf(by: -1)
    }
    private lazy var rightArrow = CatalogShelfArrowButton(direction: .right) { [weak self] in
        self?.pageHoveredShelf(by: 1)
    }
    private var hoveredSection: Int?
    private weak var hoveredShelf: NSScrollView?
    private weak var hoveredCard: (any CatalogHoverTarget)?
    private var shelfBoundsObserver: (any NSObjectProtocol)?
    /// 纵向 clip view 的 bounds 观察者（见 `bind()` 末尾那条）。与上面那条同族，
    /// 一样是块式令牌、一样在 `isolated deinit` 里摘。
    private var pageBoundsObserver: (any NSObjectProtocol)?
    private var arrowsShown = false
    /// 离开这一页时记下各货架横滚到哪，回来时恢复（VC 常驻，item 也不重建，
    /// 这一份只是保险：`transition(from:to:)` 会把视图整棵摘下来再挂回去）。
    private var shelfOffsets: [String: CGFloat] = [:]

    // MARK: - 生命周期

    init(appState: AppState, model: any CatalogPageModelProviding) {
        self.model = model
        super.init(nativePage: appState)
        layoutSections = showsPageTitle ? [.pageTitle] : []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 观察者令牌不是 `Sendable`，非隔离的 `deinit` 取不到它。标`isolated`：
    /// 主线程上释放时照旧同步跑完，注销时机不变。
    isolated deinit {
        if let shelfBoundsObserver {
            NotificationCenter.default.removeObserver(shelfBoundsObserver)
        }
        if let pageBoundsObserver {
            NotificationCenter.default.removeObserver(pageBoundsObserver)
        }
    }

    override func loadView() {
        // 页面自己不画背景：玻璃只有窗口根那一层（见 RootViewController）。
        // 艺人页例外：钉住的满幅封面垫在 scroll view 底下，collection view 的
        // 背景是透明的，内容直接从封面上滚过。
        let container = NSView()

        collectionView.collectionViewLayout = makeLayout()
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        CatalogCardRegistry.register(in: collectionView)
        collectionView.register(CatalogPageTitleView.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: Self.titleViewIdentifier)
        collectionView.register(CatalogSectionHeaderView.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: Self.headerViewIdentifier)
        collectionView.register(CatalogBandHeaderView.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: Self.bandHeaderViewIdentifier)
        collectionView.onMouseMoved = { [weak self] point in self?.updateHover(at: point) }
        collectionView.onMouseExited = { [weak self] in self?.clearHover() }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        // 顶部内缩交给系统：窗口是 fullSizeContentView，`automaticallyAdjustsContentInsets`
        // 会照标题栏自己把 52 补上（[实测 probe2] contentInsets.top == 52），
        // 内容因此能滚到工具栏底下。底部要给迷你播放器让位，但 `contentInsets` 的 setter
        // 会把自动调整关掉、连那 52 一起丢；改从**安全区**加，自动调整照旧生效
        // （[实测 probe2] 加 additionalSafeAreaInsets.bottom 后 contentInsets.bottom 跟着变，
        // automaticallyAdjustsContentInsets 仍为 true）。作用等同旧版的 `safeAreaInset(edge:.bottom)`。
        if extendsUnderTitlebar {
            // 艺人页：大图要从**窗口顶**开始，标题栏那 52 由图自己画满。
            // Apple 文档（`automaticallyAdjustsContentInsets`）：为 true 时滚动视图
            // 自动按重叠的标题栏/工具栏设 `contentInsets`；这里要的正是「不要那一档」，
            // 所以显式关掉再把 `contentInsets` 全套写死。底部那档迷你播放器的留白
            // 只能一起写进来——自动调整已经关了，`additionalSafeAreaInsets` 不再被折进
            // `contentInsets`（见下面那条注释的实测）。
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(
                top: 0, left: 0, bottom: MusicMetrics.MiniPlayer.scrollReserve, right: 0)
            // 滚动条位置不动系统默认（`scrollerInsets` 保持 0，条子照旧跟着
            // `contentInsets` 让位）——AGENTS「界面层」第 6 条：先用默认值。
        } else {
            scrollView.additionalSafeAreaInsets = NSEdgeInsets(
                top: 0, left: 0, bottom: MusicMetrics.MiniPlayer.scrollReserve, right: 0)
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        if let pinnedBackdrop {
            let backdropView = pinnedBackdrop
            backdropView.translatesAutoresizingMaskIntoConstraints = false
            backdropView.wantsLayer = true
            container.addSubview(backdropView, positioned: .below, relativeTo: scrollView)
            NSLayoutConstraint.activate([
                backdropView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                backdropView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                backdropView.topAnchor.constraint(equalTo: container.topAnchor),
                backdropView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            // 首次状态（offset 0）也要送一次：清晰/模糊两层的透明度由它初始化。
            backdropView.catalogPageScrollOffsetDidChange(0)
        }

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
        // 箭头加在 collectionView 上（文稿坐标），zPosition 保证浮在卡片之上，
        // 纵向滚动时随货架平滑滚动，绝不漂移。
        for arrow in [leftArrow, rightArrow] {
            arrow.alphaValue = 0
            arrow.isHidden = true
            arrow.wantsLayer = true
            arrow.layer?.zPosition = 1000
            collectionView.addSubview(arrow)
        }
        collectionView.leftArrow = leftArrow
        collectionView.rightArrow = rightArrow

        view = container
    }

    // MARK: - 工具栏：音乐源切换胶囊

    /// 音乐源切换器放标题栏右端（与搜索页的范围分段控件同一形制），不再占页面标题行。
    ///
    /// **「只剩一个源就不摆」这条判据在标识符这一层。** 从前它恒为
    /// `[.flexibleSpace, .amberProvider]`、摆不摆由`makePageToolbarItem` 返回 nil 决定；
    /// 工具栏那边按标识符比对看不出任何变化，于是设置里开关音乐源只能靠
    /// 「清空缓存、整条强拆重造」才跟得上（见 `MainWindowController.refreshPageToolbar`）。
    /// 判据挪到这里之后，标识符自己就变了，工具栏走普通那条路即可。
    override var pageToolbarItemIdentifiers: [NSToolbarItem.Identifier] {
        guard followsSelectedProvider,
              appState.providerSettings.orderedEnabled.count > 1 else { return [] }
        return [.flexibleSpace, .amberProvider]
    }

    override func makePageToolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard followsSelectedProvider, identifier == .amberProvider else { return nil }
        let kinds = appState.providerSettings.orderedEnabled
        // 只剩一个源就没得切，整件不摆（旧版 `ProviderPicker` 同）。上面那条标识符
        // 已经把这一件摘掉了，这里留着当兜底：`itemForItemIdentifier` 允许返回 nil。
        guard kinds.count > 1 else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        let control = NSSegmentedControl(labels: kinds.map(\.shortName),
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(providerChanged(_:)))
        control.segmentStyle = .automatic
        control.selectedSegment = kinds.firstIndex(of: appState.selectedProvider) ?? 0
        control.setAccessibilityLabel("音乐源")
        item.view = control
        item.label = "音乐源"
        item.paletteLabel = "音乐源"
        providerControl = control
        return item
    }

    @objc private func providerChanged(_ sender: NSSegmentedControl) {
        let kinds = appState.providerSettings.orderedEnabled
        guard sender.selectedSegment >= 0, sender.selectedSegment < kinds.count else { return }
        appState.selectedProvider = kinds[sender.selectedSegment]
    }

    /// 设置里开关了音乐源，而这一件**还该摆着**（剩的源仍多于一个）：就地改段，不换件。
    /// 剩一个源那一档由标识符负责（那一件整件撤掉），这里什么都不做。
    private func refreshProviderControl() {
        guard let control = providerControl else { return }
        let kinds = appState.providerSettings.orderedEnabled
        guard kinds.count > 1 else { return }
        control.segmentCount = kinds.count
        for (index, kind) in kinds.enumerated() {
            control.setLabel(kind.shortName, forSegment: index)
        }
        control.selectedSegment = kinds.firstIndex(of: appState.selectedProvider) ?? 0
    }

    private weak var providerControl: NSSegmentedControl?

    override func viewDidLoad() {
        super.viewDidLoad()
        makeDataSource()

        if followsSelectedProvider {
            // 设置里开关了音乐源 → 胶囊的**段**要跟着换。这里只改在场那颗控件自己
            //（`providerControl` 就在手上，改段不换件）；那一件**摆不摆**由
            // `pageToolbarItemIdentifiers` 反映，工具栏那边按标识符比对自己会重建。
            //
            // 从前这条挂的是 `refreshPageToolbar()`（清缓存、整条强拆重造），而三个目录
            // 根页都是缓存着的、永远活着，也不判自己是不是栈顶：一次开关就把整条工具栏
            // 拆光重建三遍；栈顶要是歌曲页、用户正在标题栏搜索框里打字，
            // 搜索框会被拔出来重插、焦点当场丢。那条订阅已经收到窗口去了（一份、判栈顶）。
            observers.observe({ [weak appState] in appState?.providerSettings.enabled ?? [] }) { [weak self] _ in
                self?.refreshProviderControl()
            }

            // 别处改了音乐源（设置窗、另一页）→ 胶囊的选中段跟着走。
            observers.observeNow({ [appState] in appState.selectedProvider }) { [weak self] kind in
                guard let self, let control = self.providerControl else { return }
                let kinds = self.appState.providerSettings.orderedEnabled
                if let index = kinds.firstIndex(of: kind) { control.selectedSegment = index }
            }

            // 换音源就重拉。首值由下面那句 `reload()` 负责，所以用丢首值的 `observe`。
            //（原先还要多挂一跳 `receive(on:)`，因为 `@Published` 在 willSet 发布、
            // 当场回读 `appState.selectedProvider` 还是旧值；现在不需要了。）
            observers.observe({ [appState] in appState.selectedProvider }) { [weak self] _ in
                self?.model.reload()
            }
        }

        // 听歌记账动了「最近播放」的台账 → 只重算本地那两段。根页是缓存的，
        // 不订阅的话听完一首歌货架要等到换音源或重启才变。
        // 首值由下面那句 `reload()` 负责，这里用丢首值的 `observe`。
        observers.observe({ [appState] in appState.library.recentContainers }) { [weak self] _ in
            guard let self else { return }
            guard !self.view.isHiddenOrHasHiddenAncestor else {
                self.needsLocalRefresh = true
                return
            }
            self.model.refreshLocalSections()
        }

        // 心水星：点一下改的是资料库，而卡上那颗星是**建卡那一刻**的快照
        // （`CatalogItem.isFavorite`，见 `CatalogFeedModel.recentItems`）。不订这一条，
        // 点了星库里真改了、星却原地不动，再点一次又加回去——这颗键看着完全失灵；
        // 反向（曲目右键菜单里心水）货架上的卡也不长星。
        // 台账没动，所以不重灌快照：只把受影响的那几件**就地重配**（见 `reconfigure(_:)`）。
        observers.observe({ [appState] in appState.library.favoriteTracks }) { [weak self] _ in
            self?.refreshFavoriteCards()
        }

        // 入库态 / 下载态 / 收藏这位艺人：艺人页那张「最新發行」卡的 ＋ 与 hero 上那枚 ★
        // 同样是建卡那一刻的快照，而它们各自只在自己动手之后刷新。不订这一条，
        // 在下面「專輯」货架的卡上右键入库之后，「最新發行」卡仍显示 ＋；再点它会
        // **再拉一次 `albumDetail`、再 `addAlbumToLibrary` 一次、再弹一次 toast**。
        //
        // 只挑 `.release` / `.artistHero` 两种卡型：别的卡一笔都不画入库/下载态，
        // 跟着 `downloads.$states` 走的话主页一屏几十张专辑卡会随下载进度每百分点重配一轮。
        // 原来是 Publishers.MergeMany 合三路，现在一条 observeAny 顶三条。
        observers.observeAny({ [appState] in
            (appState.downloads.states, appState.library.libraryAlbums, appState.library.favoriteArtistIDs)
        }) { [weak self] in self?.refreshLibraryStateCards() }

        observers.observeNow({ [model] in model.state }) { [weak self] state in self?.apply(state) }

        // 纵向滚动时把箭头跟着货架挪、卡片悬浮态跟着鼠标下面那张走、
        // 艺人页的钉住封面按滚动位置淡清晰层。滚轮不产生 mouseMoved，
        // 不跟的话箭头会浮在原地、悬浮态会留在滚走的那张卡上。
        //
        // 这一条**不**走 `for await`：clip view 的 bounds 是滚动时每帧发的，悬浮态与钉住
        // 封面的清晰层要跟当前这一帧的滚动位置对齐；`for await` 每条通知多绕一跳 await，
        // 就成了「画面已经滚过去、悬浮态慢一帧」。块式观察者是同步回调，时序与
        // `.sink` 一模一样。写法照本文件下面的 `observeShelf(_:)`（横向货架那条，
        // 同样每帧）与 `LibraryGridCards` 里同款的悬浮跟随。
        // 闭包是 `@Sendable`；`queue: .main` 已经把投递线程钉死在主线程，
        // 所以用 `assumeIsolated` 接回主 actor 隔离的自己。
        scrollView.contentView.postsBoundsChangedNotifications = true
        pageBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshHover()
                self.pinnedBackdrop?.catalogPageScrollOffsetDidChange(
                    self.scrollView.contentView.bounds.origin.y)
            }
        }

        apply(model.state)
        model.reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        restoreShelfOffsets()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        rememberShelfOffsets()
        clearHover()
    }

    /// 切走：导航容器只把视图 `isHidden` 掉，鼠标不会再发 exited，
    /// 不清的话箭头与那张卡的高亮会原样留到下次切回来。
    /// 切回来：被压住期间攒下的那次台账变动在这里补上。
    override func pageDidAppear() {
        super.pageDidAppear()
        guard needsLocalRefresh else { return }
        needsLocalRefresh = false
        model.refreshLocalSections()
    }

    override func pageDidDisappear() {
        super.pageDidDisappear()
        clearHover()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let pending = pendingSections, collectionView.bounds.width > 0 {
            pendingSections = nil
            apply(sections: pending)
        }
        // 内容列宽变了（改窗口宽、开合侧栏或右侧面板）：卡宽跟着换一档，
        // 翻页胶囊的 pitch 与封面中心也得跟着重算。段布局本身由组合布局自己重求解。
        if collectionView.bounds.width != laidOutWidth {
            laidOutWidth = collectionView.bounds.width
            rebuildShelfMetrics()
        }
        refreshHover()
    }

    private func rebuildShelfMetrics() {
        var metrics: [Int: ShelfMetrics] = [:]
        for (index, entry) in layoutSections.enumerated() {
            guard case .content(let section, _, _) = entry,
                  let shelf = makeShelfMetrics(for: section,
                                               containerWidth: collectionView.bounds.width)
            else { continue }
            metrics[index] = shelf
        }
        shelfMetrics = metrics
    }

    // MARK: - 数据源

    /// 快照里的一条。`CatalogItem.id` 只在段内唯一（同一张专辑会同时出现在两段里），
    /// 而 diffable 要求**全局**唯一，所以带上段 id 与下标。
    /// 一件的身份。**不带位置**：diffable 按它认「还是不是同一件」，位置一旦进来，
    /// 在货架头上插一张新卡就会让后面每一件的身份全变，12 张卡被判成「整批删掉重加」——
    /// 全部重建（封面重取、看得见闪动），也没有 Music 那种「新卡从左边长出来」的插入动画。
    private struct CatalogEntryID: Hashable {
        let section: String
        let id: String
        /// 同一段里**重复出现**的同一件（同一张碟摆两次）才靠它区分。
        /// 第一件永远是 0，所以段首插入不会动到其余各件的身份。
        let occurrence: Int
    }

    private enum PageLayoutSection {
        case pageTitle
        case content(CatalogSection, topGap: CGFloat, isLast: Bool)
    }

    private struct ShelfMetrics {
        /// 一列的 pitch（卡宽 + 20）
        let pitch: CGFloat
        /// 点一次箭头翻几列（表照旧 `CatalogShelfScrollView.step`）
        let step: Int
        /// 封面中心在货架内的 Y 偏移（若为 nil 则居中整个货架）
        let coverCenterOffsetY: CGFloat?
        /// 第一列之前先占掉的宽（只有艺人页并排带那张「最新發行」卡有），翻页时按它对齐列。
        var leadingOffset: CGFloat = 0
    }

    private static let titleSectionID = "__catalog-title__"
    private static let titleViewIdentifier = NSUserInterfaceItemIdentifier("CatalogPageTitleView")
    private static let headerViewIdentifier = NSUserInterfaceItemIdentifier("CatalogSectionHeaderView")
    private static let bandHeaderViewIdentifier =
        NSUserInterfaceItemIdentifier("CatalogBandHeaderView")

    private func makeDataSource() {
        dataSource = NSCollectionViewDiffableDataSource<String, CatalogEntryID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, identifier in
            guard let self else { return NSCollectionViewItem() }
            if let track = self.tracksByID[identifier] {
                let item = collectionView.makeItem(withIdentifier: CatalogCardRegistry.trackRowIdentifier,
                                                   for: indexPath)
                (item as? any CatalogTrackRowConfigurable)?.configure(with: track, appState: self.appState)
                return item
            }
            guard let model = self.itemsByID[identifier] else { return NSCollectionViewItem() }
            let item = collectionView.makeItem(
                withIdentifier: CatalogCardRegistry.identifier(for: model.kind), for: indexPath)
            (item as? any CatalogCardConfigurable)?.configure(with: model, appState: self.appState)
            return item
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard let self, kind == NSCollectionView.elementKindSectionHeader else { return nil }
            guard let entry = self.layoutSection(at: indexPath.section) else { return nil }
            switch entry {
            case .pageTitle:
                let view = collectionView.makeSupplementaryView(
                    ofKind: kind, withIdentifier: Self.titleViewIdentifier,
                    for: indexPath) as? CatalogPageTitleView
                view?.configure(title: self.model.title, appState: self.appState)
                return view
            case .content(let section, let topGap, _):
                let push: (Route) -> Void = { [weak self] destination in
                    self?.appState.push(destination)
                }
                // 并排带的段头是**双标题**（左「最新發行」/ 右「熱門歌曲 ›」），
                // 右标题的左沿要与右边那条曲目货架对齐，所以要知道左半有多宽。
                if case .artistBand = section.layout {
                    let view = collectionView.makeSupplementaryView(
                        ofKind: kind, withIdentifier: Self.bandHeaderViewIdentifier,
                        for: indexPath) as? CatalogBandHeaderView
                    view?.configure(section: section, topGap: topGap,
                                    hasRelease: !self.renderItems(of: section).isEmpty,
                                    push: push)
                    return view
                }
                let view = collectionView.makeSupplementaryView(
                    ofKind: kind, withIdentifier: Self.headerViewIdentifier,
                    for: indexPath) as? CatalogSectionHeaderView
                view?.configure(section: section, topGap: topGap, push: push)
                return view
            }
        }
    }

    private func layoutSection(at index: Int) -> PageLayoutSection? {
        index < layoutSections.count ? layoutSections[index] : nil
    }

    // MARK: - 三态

    private func apply(_ state: CatalogPageState) {
        switch state {
        case .loading:
            showOverlay(.loading)
            apply(sections: [])
        case .error(let message):
            errorLabel.stringValue = message
            showOverlay(.error)
            apply(sections: [])
        case .content(_, let sections):
            let rendered = sections.filter { isRenderable($0) }
            showOverlay(rendered.isEmpty ? .empty : .none)
            apply(sections: rendered)
        }
    }

    private func isRenderable(_ section: CatalogSection) -> Bool {
        !renderItems(of: section).isEmpty || !renderTracks(of: section).isEmpty
    }

    /// 一段真正会摆出来的卡。大横幅段只摆第一张（旧版 `section.items.first`）；
    /// 并排带只摆第一张（那张「最新發行」卡），右半的曲目走 `renderTracks`。
    private func renderItems(of section: CatalogSection) -> [CatalogItem] {
        switch section.layout {
        case .trackColumns: return []
        case .banner, .artistBand: return Array(section.items.prefix(1))
        default: return section.items
        }
    }

    /// 一段真正会摆出来的曲目行（只有这两种段有）。
    private func renderTracks(of section: CatalogSection) -> [Track] {
        switch section.layout {
        case .trackColumns, .artistBand: return section.tracks
        default: return []
        }
    }

    private func apply(sections: [CatalogSection]) {
        // 硬闸：**已经在窗口里、宽度却还是 0** 时不许灌快照。
        // `NSCollectionViewCompositionalLayout` 在 0 宽容器里求解会无限生成 item，
        // 实测几秒吃掉几十 GB（连只有标题段的加载态快照都会，所以这里不看段数）。
        // 不在窗口里则无所谓：那种快照不触发求解，上屏前必然先布局一次。
        // 挡下的这一份等 `viewDidLayout` 拿到宽度再灌。
        if view.window != nil, collectionView.bounds.width <= 0 {
            pendingSections = sections
            return
        }
        pendingSections = nil

        var layout: [PageLayoutSection] = showsPageTitle ? [.pageTitle] : []
        var metrics: [Int: ShelfMetrics] = [:]
        var snapshot = NSDiffableDataSourceSnapshot<String, CatalogEntryID>()
        if showsPageTitle { snapshot.appendSections([Self.titleSectionID]) }
        itemsByID.removeAll()
        tracksByID.removeAll()

        for (offset, section) in sections.enumerated() {
            let topGap: CGFloat
            if case .artistHero = section.layout {
                // 满幅 hero 顶着窗口顶画，上面一点空白都不留。
                topGap = 0
            } else if offset == 0 {
                // 没有页面大标题的页面（艺人页 0 / 搜索结果页 14），首段自己不欠标题行的那段空白。
                topGap = showsPageTitle
                    ? (section.title == nil ? M.titleToContent : M.titleToHeading)
                    : firstSectionTopGap
            } else {
                topGap = M.sectionSpacing
            }
            layout.append(.content(section, topGap: topGap, isLast: offset == sections.count - 1))
            if let shelf = makeShelfMetrics(for: section, containerWidth: collectionView.bounds.width) {
                metrics[layout.count - 1] = shelf
            }
            snapshot.appendSections([section.id])
            // 并排带一段里既有卡又有曲目：**卡在前、曲目在后**，与自定义 group 里
            // 那一串 `NSCollectionLayoutGroupCustomItem` 的顺序一一对应。
            // 数据源那边按 id 先查 `tracksByID` 再查`itemsByID`，混着放没问题。
            var ids: [CatalogEntryID] = []
            // 段内同一个 id 第二次出现才给下一个 occurrence（见 `CatalogEntryID`）。
            var occurrences: [String: Int] = [:]
            func entry(_ rawID: String) -> CatalogEntryID {
                let occurrence = occurrences[rawID, default: 0]
                occurrences[rawID] = occurrence + 1
                return CatalogEntryID(section: section.id, id: rawID, occurrence: occurrence)
            }
            for item in renderItems(of: section) {
                let id = entry(item.id)
                itemsByID[id] = withLiveFavorite(item)
                ids.append(id)
            }
            for track in renderTracks(of: section) {
                let id = entry("track-\(track.id)")
                tracksByID[id] = track
                ids.append(id)
            }
            snapshot.appendItems(ids, toSection: section.id)
        }

        layoutSections = layout
        shelfMetrics = metrics
        // 只换了内容（段与件数都没动、也不是首次灌）就**带动画**：新卡从左边长出来、
        // 其余各件平移让位，与 Music 同。首次上屏 / 换音源 / 段有增删那几次不动画，
        // 否则整页卡片会一起飞进来。
        let signature = layoutSignature(sections)
        let contentOnly = lastLayoutSignature != nil && signature == lastLayoutSignature
        dataSource.apply(snapshot, animatingDifferences: contentOnly)
        // **版式没变就别重解布局**：组合布局一 `invalidateLayout()`，横向货架
        // （orthogonal section）里的 cell 会被整批重建、封面重新异步取，
        // 界面上就是切回来时图片闪一下。换了哪几张卡由上面那次 diffable apply 负责；
        // 卡摆在哪儿是按「段序 + 每段件数」算死的（见 `makeLayout`），这几样没动，
        // 布局解就还是同一份。容器宽变了走的是 `viewDidLayout` 那条路（组合布局自己
        // 重求解），根本到不了这里，所以指纹里没有宽——理由见 `layoutSignature`。
        if signature != lastLayoutSignature {
            lastLayoutSignature = signature
            collectionView.collectionViewLayout?.invalidateLayout()
        }
        clearHover()
    }

    /// 版式指纹：只认**影响布局解**的那几样——段序、标题行的形态（有没有标题、有没有种子
    /// 那行 headline：它决定标题行高是 `headingHeight` 还是 `seedThumbSize`）、段的样式、
    /// 每段**真正摆出来**的卡数与曲目行数。数的是 `renderItems`/`renderTracks` 而不是
    /// `section.items`/`.tracks`：大横幅只摆第一张、并排带的卡与曲目分两路走，
    /// 布局解（`artistBandSection`、`linksSection(count:)`）认的也是这两个数。
    /// 卡片换了内容但这些都没动时指纹一样。
    ///
    /// **不含容器宽**：改窗口宽／开合侧栏不走 `apply(sections:)`——`viewDidLayout` 只重算
    /// `shelfMetrics`，段布局由组合布局自己按新容器重求解。宽要是进了指纹，这里存下的
    /// 就永远是上一次灌快照时那个宽，于是改过宽之后的第一次内容更新必定「指纹不一致」，
    /// 白白 `invalidateLayout()` 一次——那一下就是整页横向货架的 cell 重建、封面重取。
    private func layoutSignature(_ sections: [CatalogSection]) -> String {
        var parts = ["\(showsPageTitle)"]
        for section in sections {
            parts.append("\(section.id)|\(section.title ?? "")|\(section.headline != nil)|"
                + "\(section.layout)|"
                + "\(renderItems(of: section).count)|\(renderTracks(of: section).count)")
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - 就地重配（身份没变、内容变了）

    /// 把这几件的卡**复用原来那张**再装一遍数据。
    ///
    /// **AppKit 的 `NSDiffableDataSourceSnapshot` 没有`reconfigureItems(_:)`**——那一条是
    /// UIKit 独有的（macOS 26 目标下编译探针核过：`reloadItems` 在、`reconfigureItems` 不在），
    /// 所以这件事只能手写。两者的差别正是这里要的：
    ///
    /// - `reloadItems`：把 cell **销毁重建**（走 delete + insert），封面重新异步取、
    ///   悬浮态与滚动中的动画一起丢，界面上就是闪一下；
    /// - reconfigure：**复用已有 cell，只把数据重新装一遍**，视图一个都不拆。
    ///
    /// 做法是按身份问数据源要 indexPath、再问 collection view 要那一件。
    /// `item(at:)` 只对**已经造出来**的件给非 nil，没在屏的件不用管——`itemsByID` 已经是
    /// 新值，它下次出队时装的就是新的。
    private func reconfigure(_ ids: [CatalogEntryID]) {
        guard !ids.isEmpty, dataSource != nil else { return }
        for id in ids {
            guard let indexPath = dataSource.indexPath(for: id),
                  let model = itemsByID[id],
                  let cell = collectionView.item(at: indexPath) as? (any CatalogCardConfigurable)
            else { continue }
            cell.configure(with: model, appState: appState)
        }
    }

    /// 心水星是**资料库的当前事实**，不是建卡那一刻的快照。模型交上来的那一位可能已经
    /// 过期：`CatalogFeedModel.refreshLocalSections` 在卡片 id 没变时故意不替换整段
    ///（免得白重灌一次快照），于是段里留着的还是上一次建卡时的值。灌快照时统一对齐一次，
    /// 之后由下面那条 `refreshFavoriteCards` 增量跟着走。
    private func withLiveFavorite(_ item: CatalogItem) -> CatalogItem {
        guard let track = item.track else { return item }
        var item = item
        item.isFavorite = appState.library.isFavorite(track)
        return item
    }

    /// 资料库的心水集变了：把带曲目上下文的卡里那一位对齐，变了的就地重配。
    private func refreshFavoriteCards() {
        var changed: [CatalogEntryID] = []
        for (id, item) in itemsByID {
            guard let track = item.track,
                  item.isFavorite != appState.library.isFavorite(track) else { continue }
            changed.append(id)
        }
        guard !changed.isEmpty else { return }
        for id in changed { itemsByID[id]?.isFavorite.toggle() }
        reconfigure(changed)
    }

    /// 入库 / 下载 / 收藏艺人这三样变了：只有这两种卡会画它们。
    /// 状态由卡自己按 `DownloadStore.action(inLibrary:tracks:)` 现算（`apply` 里那一句），
    /// 所以这里不用改 `itemsByID`，把卡重配一遍就够了。
    private func refreshLibraryStateCards() {
        let ids = itemsByID.compactMap { entry -> CatalogEntryID? in
            switch entry.value.kind {
            case .release, .artistHero: return entry.key
            default: return nil
            }
        }
        reconfigure(ids)
    }

    private enum OverlayKind { case none, loading, error, empty }

    private func showOverlay(_ kind: OverlayKind) {
        overlay.isHidden = kind == .none
        spinner.isHidden = kind != .loading
        if kind == .loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        errorBox.isHidden = kind != .error
        if kind == .empty { installEmptyHostIfNeeded() }
        emptyHost?.isHidden = kind != .empty
    }

    /// 三态那几块从「标题行底下」开始摆；没有标题行的页面（艺人页）就从内容顶开始。
    private var overlayTopOffset: CGFloat { showsPageTitle ? Self.titleHeight : 0 }

    private func buildOverlay() {
        overlay.isHidden = true

        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(spinner)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "wifi.exclamationmark", accessibilityDescription: nil)?
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

        // 覆盖层从标题行底下开始：标题行照常由 collection view 画出来，不被盖住。
        let top = overlay.safeAreaLayoutGuide.topAnchor
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: top,
                                         constant: overlayTopOffset + Self.stateTopPadding),
            errorBox.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            errorBox.topAnchor.constraint(equalTo: top,
                                          constant: overlayTopOffset + Self.stateTopPadding),
        ])
    }

    /// 空态沿用 SwiftUI 的 `MusicEmptyStateContent`（它是叶子，不重写）。
    /// 铁律 2：宿主要有定尺寸的槽，所以高度按它自己的排版算死
    /// （topPadding 150 + 45pt 图标的字形高 ≈ 54 + 间距 12 + 两行 13pt ≈ 40）。
    private func installEmptyHostIfNeeded() {
        guard emptyHost == nil else { return }
        let message = model.emptyMessage
        let image = model.emptyImage
        let host = appState.hostingView {
            MusicEmptyStateContent(message: message, systemImage: image)
        }
        overlay.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            host.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor,
                                      constant: overlayTopOffset),
            host.heightAnchor.constraint(
                equalToConstant: MusicMetrics.EmptyState.topPadding + 54
                    + MusicMetrics.EmptyState.spacing + 40),
        ])
        emptyHost = host
    }

    @objc private func retryTapped() {
        model.reload()
    }

    // MARK: - 组合布局

    private func makeLayout() -> NSCollectionViewLayout {
        NSCollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, let section = self.layoutSection(at: index) else {
                return CatalogPageViewController.blankSection()
            }
            switch section {
            case .pageTitle:
                return self.titleLayoutSection(containerWidth: environment.container.contentSize.width)
            case .content(let content, let topGap, let isLast):
                // `container.contentSize` 是内容列的尺寸（内缩之前）——hero 的高按窗口高
                // 取比例就用它的 height（Apple 文档 `NSCollectionLayoutContainer`：
                // contentSize 是应用 content insets 之前的容器尺寸）。
                return self.contentLayoutSection(content, topGap: topGap, isLast: isLast,
                                                 container: environment.container.contentSize)
            }
        }
    }

    private static func blankSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                          heightDimension: .absolute(1))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        return NSCollectionLayoutSection(group: group)
    }

    /// 第 0 段：恒在、没有 item，只把页面大标题那一行摆出来。
    /// **不设 `interGroupSpacing`**——0 个 group 时它会按 −spacing 记进段高（见文件头实测）。
    private func titleLayoutSection(containerWidth: CGFloat) -> NSCollectionLayoutSection {
        let margin = M.Shelf.margin(containerWidth: containerWidth)
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                          heightDimension: .absolute(1))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: margin,
                                                        bottom: 0, trailing: margin)
        section.boundarySupplementaryItems = [
            NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                   heightDimension: .absolute(Self.titleHeight)),
                elementKind: NSCollectionView.elementKindSectionHeader, alignment: .top)
        ]
        return section
    }

    private func contentLayoutSection(_ section: CatalogSection, topGap: CGFloat, isLast: Bool,
                                      container: NSSize) -> NSCollectionLayoutSection {
        let containerWidth = container.width
        let gutter = M.Shelf.gutter(containerWidth: containerWidth)
        let bottom = isLast ? Self.pageBottomInset : 0
        // 并排带的段头两半各自可有可无（音源交不出专辑时左半那个「最新發行」就不摆），
        // 所以只要有一个标题就得有段头。
        let hasHeading: Bool
        if case .artistBand = section.layout {
            hasHeading = section.title != nil || section.trailingTitle != nil
        } else {
            hasHeading = section.title != nil
        }
        let result: NSCollectionLayoutSection

        switch section.layout {
        case .artistHero:
            result = artistHeroSection(container: container)
        case .artistBand(let rows):
            result = artistBandSection(section, rows: max(1, rows), containerWidth: containerWidth)
        case .banner:
            result = fullWidthSection(kind: .banner, containerWidth: containerWidth)
        case .links:
            result = linksSection(count: section.items.count, containerWidth: containerWidth)
        case .topResults:
            result = topResultsSection(containerWidth: containerWidth)
        case .posters:
            result = shelfSection(cardSize: cardSize(.poster, containerWidth), rows: 1,
                                  rowSpacing: gutter, containerWidth: containerWidth)
        case .heroes:
            result = shelfSection(cardSize: cardSize(.hero, containerWidth), rows: 1,
                                  rowSpacing: gutter, containerWidth: containerWidth)
        case .stations:
            result = shelfSection(cardSize: cardSize(.station, containerWidth), rows: 1,
                                  rowSpacing: gutter, containerWidth: containerWidth)
        case .videos:
            result = shelfSection(cardSize: cardSize(.video, containerWidth), rows: 1,
                                  rowSpacing: gutter, containerWidth: containerWidth)
        case .squares(let rows):
            result = shelfSection(cardSize: cardSize(.square, containerWidth),
                                  rows: max(1, rows), rowSpacing: gutter, containerWidth: containerWidth)
        case .episodes(let rows):
            result = shelfSection(cardSize: cardSize(.episode, containerWidth),
                                  rows: max(1, rows), rowSpacing: gutter, containerWidth: containerWidth)
        case .trackColumns(let rows):
            // [AX] 曲目行 pitch 56 == 行高，行与行贴着排，所以列内间距是 0。
            result = shelfSection(cardSize: CatalogCardRegistry.trackRowSize(containerWidth: containerWidth),
                                  rows: max(1, rows), rowSpacing: 0, containerWidth: containerWidth)
        }

        var insets = result.contentInsets
        insets.top = hasHeading ? 0 : topGap
        insets.bottom = bottom
        result.contentInsets = insets

        if hasHeading {
            let rowHeight = section.headline == nil ? Self.headingHeight : M.seedThumbSize
            result.boundarySupplementaryItems = [
                NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1),
                        heightDimension: .absolute(topGap + rowHeight + M.headingToContent)),
                    elementKind: NSCollectionView.elementKindSectionHeader, alignment: .top)
            ]
        }
        return result
    }

    private func cardSize(_ kind: CatalogItem.Kind, _ containerWidth: CGFloat) -> NSSize {
        CatalogCardRegistry.size(for: kind, containerWidth: containerWidth)
    }

    /// 货架段：一件一卡横排（rows = 1）或**列优先**的多行（每个 group 是一竖列 rows 张卡）。
    private func shelfSection(cardSize: NSSize, rows: Int, rowSpacing: CGFloat,
                              containerWidth: CGFloat) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(cardSize.width),
                                              heightDimension: .absolute(cardSize.height))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group: NSCollectionLayoutGroup
        if rows <= 1 {
            group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        } else {
            let height = cardSize.height * CGFloat(rows) + rowSpacing * CGFloat(rows - 1)
            let groupSize = NSCollectionLayoutSize(widthDimension: .absolute(cardSize.width),
                                                   heightDimension: .absolute(height))
            group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize,
                                                     subitem: item, count: rows)
            group.interItemSpacing = .fixed(rowSpacing)
        }
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = M.Shelf.gutter(containerWidth: containerWidth)
        // 触控板自由滑（Music 的货架不是按页吸附的）。左右内缩加在文稿里，
        // 裁切仍是整段宽——卡片贴着内容列边缘消失。
        let margin = M.Shelf.margin(containerWidth: containerWidth)
        section.orthogonalScrollingBehavior = .continuous
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: margin,
                                                        bottom: 0, trailing: margin)
        return section
    }

    /// 艺人页的满幅 hero：一件，铺满内容列整宽，**不让** `Catalog.leadingMargin`，
    /// 不横滚、无段头。这一件现在只摆艺人名与三枚圆键——封面图挪到了钉住的
    /// `ArtistBackdropView`（图不随文稿滚，滚起来从清晰变糊）。
    ///
    /// 段高 = `heroHeight(viewportHeight:)`（[PX] 0.72 × 视口高、下限 [实测] 385）。
    /// 名字与按钮锚在段底（`heroButtonsBottom` 15），骑在图底的渐糊带上——
    /// 宽幅图按内容列宽铺出来比段矮 ~80，那段差由背景层的顺延糊图补上。
    private func artistHeroSection(container: NSSize) -> NSCollectionLayoutSection {
        let height = A.heroHeight(viewportHeight: container.height + scrollView.contentInsets.bottom)
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                          heightDimension: .absolute(height))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 0)
        return section
    }

    /// 艺人页的并排带：**一段里同时有一张「最新發行」卡与 N 首曲目**，两边的宽高都不一样，
    /// 组合布局的横/竖 group 排不出来，所以用 `NSCollectionLayoutGroup.custom(layoutSize:itemProvider:)`
    /// 自己给每一件报 frame（Apple 文档：自定义 group 的 item 直接给 frame 而不是 layoutSize，
    /// 坐标以 group 自己的几何原点 {0,0} 为准）。
    ///
    /// 布局这一层拿得到段数据（`layoutSections`），所以卡的有无、曲目条数全知道，位置能算死：
    ///
    ///     x=0                    x = releaseWidth + releaseToShelfGap
    ///     ┌───────────────┐      ┌──────────┐ ┌──────────┐
    ///     │  最新發行卡    │      │ 曲目 0    │ │ 曲目 3    │  ← 列优先：先灌满一列再进下一列
    ///     │  (364 宽,      │      │ 曲目 1    │ │ 曲目 4    │     列宽 379、行高 56、行距 0
    ///     │   rows×56 高)  │      │ 曲目 2    │ │ 曲目 5    │     列间 20
    ///     └───────────────┘      └──────────┘ └──────────┘
    ///
    /// 数字出处：[PX] `ArtistPage.releaseWidth` 364 / `releaseToShelfGap` 32；
    /// 曲目列宽与列间距跟着内容列宽走（`Catalog.Shelf`，与`.trackColumns` 同一条），
    /// [AX] `trackRowHeight` 56（行 pitch 就等于行高）。
    ///
    /// 没有 release 卡时整条带退化成普通 `.trackColumns`：曲目从 x=0 起排。
    private func artistBandSection(_ section: CatalogSection, rows: Int,
                                   containerWidth: CGFloat) -> NSCollectionLayoutSection {
        let hasRelease = !renderItems(of: section).isEmpty
        let trackCount = renderTracks(of: section).count
        let rowHeight = M.trackRowHeight
        let height = rowHeight * CGFloat(rows)
        let leading = hasRelease ? A.releaseWidth + A.releaseToShelfGap : 0
        let columnWidth = CatalogCardRegistry.trackRowSize(containerWidth: containerWidth).width
        let gutter = M.Shelf.gutter(containerWidth: containerWidth)
        let columnPitch = columnWidth + gutter
        let columns = Int((Double(trackCount) / Double(rows)).rounded(.up))
        let width = leading
            + (columns > 0 ? columnWidth * CGFloat(columns) + gutter * CGFloat(columns - 1) : 0)

        let group = NSCollectionLayoutGroup.custom(
            layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(max(1, width)),
                                               heightDimension: .absolute(max(1, height)))
        ) { _ in
            var items: [NSCollectionLayoutGroupCustomItem] = []
            if hasRelease {
                items.append(.init(frame: NSRect(x: 0, y: 0,
                                                 width: A.releaseWidth, height: height)))
            }
            for index in 0..<trackCount {
                let column = index / rows
                let row = index % rows
                items.append(.init(frame: NSRect(x: leading + CGFloat(column) * columnPitch,
                                                 y: CGFloat(row) * rowHeight,
                                                 width: columnWidth, height: rowHeight)))
            }
            return items
        }

        let result = NSCollectionLayoutSection(group: group)
        // 只有一个 group，**不设** `interGroupSpacing`（文件头实测：group 数少时那条间距
        // 会按 −spacing 记进段高）。左右照旧是该档的内缩，裁切仍是整段宽。
        let margin = M.Shelf.margin(containerWidth: containerWidth)
        result.orthogonalScrollingBehavior = .continuous
        result.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: margin,
                                                       bottom: 0, trailing: margin)
        return result
    }

    /// 大横幅：整宽一张卡，不横滚。
    private func fullWidthSection(kind: CatalogItem.Kind, containerWidth: CGFloat) -> NSCollectionLayoutSection {
        let size = cardSize(kind, containerWidth)
        let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(size.width),
                                              heightDimension: .absolute(size.height))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: itemSize, subitems: [NSCollectionLayoutItem(layoutSize: itemSize)])
        let section = NSCollectionLayoutSection(group: group)
        let margin = M.Shelf.margin(containerWidth: containerWidth)
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: margin,
                                                        bottom: 0, trailing: margin)
        return section
    }

    /// 链接组：三列网格、**列优先**填（每列 ceil(count/3) 条），列间 20、行间 24，不横滚。
    /// 外层一个横向 group 装三个竖向 group，item 依次灌满第一竖列再进第二列 —— 就是列优先。
    private func linksSection(count: Int, containerWidth: CGFloat) -> NSCollectionLayoutSection {
        let cell = cardSize(.link, containerWidth)
        let perColumn = max(1, Int((Double(count) / Double(M.linkColumns)).rounded(.up)))
        let columnHeight = cell.height * CGFloat(perColumn) + M.linkRowGap * CGFloat(perColumn - 1)
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .absolute(cell.width), heightDimension: .absolute(cell.height)))
        let column = NSCollectionLayoutGroup.vertical(
            layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(cell.width),
                                               heightDimension: .absolute(columnHeight)),
            subitem: item, count: perColumn)
        column.interItemSpacing = .fixed(M.linkRowGap)
        let inner = cell.width * CGFloat(M.linkColumns) + M.linkColumnGap * CGFloat(M.linkColumns - 1)
        let row = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(inner),
                                               heightDimension: .absolute(columnHeight)),
            subitem: column, count: M.linkColumns)
        row.interItemSpacing = .fixed(M.linkColumnGap)
        let section = NSCollectionLayoutSection(group: row)
        let margin = M.Shelf.margin(containerWidth: containerWidth)
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: margin,
                                                        bottom: 0, trailing: margin)
        return section
    }

    /// 热门搜索结果的横卡网格：按内容列宽能塞几列就几列（列宽下限 250、列距 22），
    /// 铺满换行、行距 20、**行优先**（一行装满再换行，与链接组的列优先相反），不横滚。
    /// 一行就是一个横向 group，列宽与 `CatalogCardRegistry.size(for: .topResult,…)` 同一条算法。
    private func topResultsSection(containerWidth: CGFloat) -> NSCollectionLayoutSection {
        let inner = max(1, M.Shelf.innerWidth(containerWidth: containerWidth))
        let cell = cardSize(.topResult, containerWidth)
        let columns = M.topResultColumns(forWidth: inner)
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .absolute(max(1, cell.width)),
            heightDimension: .absolute(cell.height)))
        let row = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(inner),
                                               heightDimension: .absolute(cell.height)),
            subitem: item, count: columns)
        row.interItemSpacing = .fixed(M.topResultColumnGap)
        let section = NSCollectionLayoutSection(group: row)
        let margin = M.Shelf.margin(containerWidth: containerWidth)
        section.interGroupSpacing = M.topResultRowGap
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: margin,
                                                        bottom: 0, trailing: margin)
        return section
    }

    /// 翻页胶囊按「一屏几张卡」走位，所以卡宽一变（改窗口宽、开合侧栏/面板）就要重算，
    /// 由 `viewDidLayout` 在宽度真的变了那一次调。
    private func makeShelfMetrics(for section: CatalogSection,
                                  containerWidth: CGFloat) -> ShelfMetrics? {
        func card(_ kind: CatalogItem.Kind) -> NSSize {
            CatalogCardRegistry.size(for: kind, containerWidth: containerWidth)
        }
        let width: CGFloat
        let step: Int
        let coverOffsetY: CGFloat?
        var leadingOffset: CGFloat = 0
        switch section.layout {
        case .banner, .links, .artistHero, .topResults:
            // 都不是货架（不横滚），没有翻页箭头这回事。
            return nil
        case .artistBand:
            // 并排带按**曲目列**翻页；左边那张「最新發行」卡占的宽算成起始偏移，
            // 这样翻页落位仍然是「某一列贴左沿」，而不是差着 364+32 的半列。
            width = CatalogCardRegistry.trackRowSize(containerWidth: containerWidth).width
            step = 2
            coverOffsetY = nil
            leadingOffset = renderItems(of: section).isEmpty
                ? 0 : A.releaseWidth + A.releaseToShelfGap
        case .posters:
            let size = card(.poster)
            width = size.width; step = 3
            coverOffsetY = size.height / 2
        case .heroes:
            let size = card(.hero)
            width = size.width; step = 2
            coverOffsetY = M.heroTextHeight + (size.height - M.heroTextHeight) / 2
        case .stations:
            let size = card(.station)
            width = size.width; step = 4
            coverOffsetY = size.width / 2
        case .squares(let rows):
            let size = card(.square)
            width = size.width; step = 4
            coverOffsetY = rows <= 1 ? (size.width / 2) : nil
        case .videos:
            let size = card(.video)
            width = size.width; step = 3
            coverOffsetY = (size.height - M.videoTextHeight) / 2
        case .episodes(let rows):
            let size = card(.episode)
            width = size.width; step = 2
            coverOffsetY = rows <= 1 ? (size.height / 2) : nil
        case .trackColumns:
            width = CatalogCardRegistry.trackRowSize(containerWidth: containerWidth).width
            step = 2
            coverOffsetY = nil
        }
        return ShelfMetrics(pitch: width + M.Shelf.gutter(containerWidth: containerWidth),
                            step: step,
                            coverCenterOffsetY: coverOffsetY, leadingOffset: leadingOffset)
    }

    // MARK: - 悬浮翻页箭头

    /// 当前可见的货架：段序号 → (布局内部那个横向 scroll view, 在 collectionView 内的几何, 封面中心 Y)。
    private func visibleShelves() -> [(section: Int, shelf: NSScrollView, frameInCollection: NSRect, coverMidY: CGFloat)] {
        var found: [Int: (shelf: NSScrollView, frameInCollection: NSRect, coverMidY: CGFloat)] = [:]
        for item in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: item),
                  let shelf = item.view.enclosingScrollView, shelf !== scrollView
            else { continue }
            if found[indexPath.section] == nil {
                let rect = collectionView.convert(shelf.bounds, from: shelf)
                let coverY = coverCenterY(for: indexPath.section, shelfRect: rect)
                found[indexPath.section] = (shelf: shelf, frameInCollection: rect, coverMidY: coverY)
            }
        }
        return found.map { (section: $0.key, shelf: $0.value.shelf, frameInCollection: $0.value.frameInCollection, coverMidY: $0.value.coverMidY) }
    }

    private func coverCenterY(for section: Int, shelfRect: NSRect) -> CGFloat {
        guard let metrics = shelfMetrics[section] else { return shelfRect.midY }
        // 若该布局要求对齐整组货架（如多行方卡、曲目列），直接返回整段中心
        guard let offset = metrics.coverCenterOffsetY else { return shelfRect.midY }

        // 单行货架：优先通过当前屏内卡片的封面视图动态转换坐标（真实几何精准对齐）
        for item in collectionView.visibleItems() {
            if let ip = collectionView.indexPath(for: item), ip.section == section,
               let card = item.view as? CatalogCardContentView,
               let artwork = card.artworkViewForAlignment {
                let rect = collectionView.convert(artwork.bounds, from: artwork)
                return rect.midY
            }
        }
        // 兜底静态推算
        return shelfRect.minY + offset
    }

    private func refreshHover() {
        guard let window = view.window, window.isKeyWindow else { clearHover(); return }
        let inCollection = collectionView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updateHover(at: inCollection)
    }

    /// `point` 是 collection view（文稿）坐标。
    private func updateHover(at point: NSPoint) {
        updateCardHover(at: point)
        let inScroll = scrollView.convert(point, from: collectionView)
        guard scrollView.bounds.contains(inScroll) else { clearHover(); return }

        let shelves = visibleShelves()
        // 货架命中判定：纵向落在该货架的卡片条带内，横向在整个 collectionView 宽度内（含左右留白与胶囊位置）。
        let hit = shelves.first { entry in
            guard shelfMetrics[entry.section] != nil else { return false }
            let rect = entry.frameInCollection
            return point.y >= rect.minY && point.y <= rect.maxY
                && point.x >= 0 && point.x <= collectionView.bounds.width
        }

        guard let hit else { clearHover(); return }

        let shelfChanged = hoveredShelf !== hit.shelf
        if shelfChanged {
            observeShelf(hit.shelf)
            hoveredSection = hit.section
            hoveredShelf = hit.shelf
        }

        layoutArrows(over: hit.frameInCollection, coverMidY: hit.coverMidY)

        if !arrowsShown || shelfChanged {
            arrowsShown = true
            updateArrowVisibility(animated: true)
        }

        // 更新胶囊自身的悬浮高亮态
        leftArrow.isHovered = !leftArrow.isHidden && leftArrow.frame.contains(point)
        rightArrow.isHovered = !rightArrow.isHidden && rightArrow.frame.contains(point)
    }

    /// 卡片的悬浮态：用 hitTest 找鼠标下面那张卡（穿过 orthogonal 段自己的滚动视图），
    /// 与翻页箭头同一处判、同一份鼠标位置；滚轮滚动时 `refreshHover` 也走这里，
    /// 悬浮态跟着鼠标下面那张卡换（理由见 `CatalogHoverTarget`）。
    private func updateCardHover(at point: NSPoint) {
        guard let superview = collectionView.superview else { return }
        var hit = collectionView.hitTest(collectionView.convert(point, to: superview))
        var target: (any CatalogHoverTarget)?
        while let view = hit, view !== collectionView {
            if let card = view as? any CatalogHoverTarget { target = card; break }
            hit = view.superview
        }
        setHoveredCard(target)
    }

    private func setHoveredCard(_ card: (any CatalogHoverTarget)?) {
        guard card !== hoveredCard else { return }
        hoveredCard?.setHovering(false)
        hoveredCard = card
        card?.setHovering(true)
    }

    private func clearHover() {
        setHoveredCard(nil)
        leftArrow.isHovered = false
        rightArrow.isHovered = false
        guard hoveredShelf != nil || arrowsShown else { return }
        hoveredSection = nil
        hoveredShelf = nil
        if let shelfBoundsObserver {
            NotificationCenter.default.removeObserver(shelfBoundsObserver)
            self.shelfBoundsObserver = nil
        }
        arrowsShown = false
        updateArrowVisibility(animated: true)
    }

    private func observeShelf(_ shelf: NSScrollView) {
        if let shelfBoundsObserver {
            NotificationCenter.default.removeObserver(shelfBoundsObserver)
        }
        shelf.contentView.postsBoundsChangedNotifications = true
        shelfBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: shelf.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateArrowVisibility(animated: true) }
        }
    }

    private func layoutArrows(over shelfRect: NSRect, coverMidY: CGFloat) {
        // 胶囊水平绝对固定在两侧边距：
        // 左胶囊中心正对该档的左内缩（宽档 34），因此 frame.origin.x = 34 - 14 = 20；
        // 右胶囊中心正对右侧内缩，因此 frame.origin.x = width - 34 - 14 = width - 48。
        // 垂直居中于封面中心（或多行货架中心）。
        let width = collectionView.bounds.width
        let outset = M.Shelf.margin(containerWidth: width) - Self.arrowSize.width / 2
        let y = coverMidY - Self.arrowSize.height / 2
        leftArrow.frame = NSRect(x: outset, y: y,
                                 width: Self.arrowSize.width, height: Self.arrowSize.height)
        rightArrow.frame = NSRect(x: width - outset - Self.arrowSize.width, y: y,
                                  width: Self.arrowSize.width, height: Self.arrowSize.height)
    }

    /// 最左侧左胶囊不显示，最右侧右胶囊不显示；无溢出内容时双侧均不显示。
    private func updateArrowVisibility(animated: Bool) {
        guard let shelf = hoveredShelf, arrowsShown else {
            updateArrow(leftArrow, shouldShow: false, animated: animated)
            updateArrow(rightArrow, shouldShow: false, animated: animated)
            return
        }
        let x = shelf.contentView.bounds.origin.x
        let docWidth = shelf.documentView?.frame.width ?? 0
        let clipWidth = shelf.contentView.bounds.width
        let maxX = max(0, docWidth - clipWidth)

        // 离起止端 1pt 阈值避免浮点亚像素误差；若内容未溢出（maxX <= 1）则两端都不显
        let canScrollLeft = x > 1
        let canScrollRight = maxX > 1 && x < maxX - 1

        updateArrow(leftArrow, shouldShow: canScrollLeft, animated: animated)
        updateArrow(rightArrow, shouldShow: canScrollRight, animated: animated)
    }

    private func updateArrow(_ arrow: CatalogShelfArrowButton, shouldShow: Bool, animated: Bool) {
        arrow.isEnabled = shouldShow
        if shouldShow {
            arrow.isHidden = false
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    arrow.animator().alphaValue = 1
                }
            } else {
                arrow.alphaValue = 1
            }
        } else {
            if animated && !arrow.isHidden && arrow.alphaValue > 0 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    arrow.animator().alphaValue = 0
                } completionHandler: {
                    MainActor.assumeIsolated {
                        if arrow.alphaValue == 0 {
                            arrow.isHidden = true
                        }
                    }
                }
            } else {
                arrow.alphaValue = 0
                arrow.isHidden = true
            }
        }
    }

    /// 翻一页：以当前贴左沿的那一列为准（手滑过的位置也算数），前后挪 `step` 列。
    private func pageHoveredShelf(by direction: Int) {
        guard let shelf = hoveredShelf, let section = hoveredSection,
              let metrics = shelfMetrics[section], metrics.pitch > 0 else { return }
        let current = shelf.contentView.bounds.origin.x
        let docWidth = shelf.documentView?.frame.width ?? 0
        let clipWidth = shelf.contentView.bounds.width
        let maxX = max(0, docWidth - clipWidth)
        guard maxX > 0 else { return }

        let column = ((current - metrics.leadingOffset) / metrics.pitch).rounded()
        let target = min(maxX, max(0, metrics.leadingOffset
            + (column + CGFloat(direction * metrics.step)) * metrics.pitch))
        guard abs(target - current) > 0.5 else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shelf.contentView.animator().setBoundsOrigin(
                NSPoint(x: target, y: shelf.contentView.bounds.origin.y))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                shelf.reflectScrolledClipView(shelf.contentView)
                self?.updateArrowVisibility(animated: true)
            }
        }
    }

    // MARK: - 各货架的横向位置

    private func rememberShelfOffsets() {
        for entry in visibleShelves() {
            guard let descriptor = layoutSection(at: entry.section),
                  case .content(let section, _, _) = descriptor else { continue }
            shelfOffsets[section.id] = entry.shelf.contentView.bounds.origin.x
        }
    }

    private func restoreShelfOffsets() {
        for entry in visibleShelves() {
            guard let descriptor = layoutSection(at: entry.section),
                  case .content(let section, _, _) = descriptor,
                  let saved = shelfOffsets[section.id], saved > 0,
                  abs(entry.shelf.contentView.bounds.origin.x - saved) > 0.5
            else { continue }
            entry.shelf.contentView.setBoundsOrigin(
                NSPoint(x: saved, y: entry.shelf.contentView.bounds.origin.y))
            entry.shelf.reflectScrolledClipView(entry.shelf.contentView)
        }
    }
}

// MARK: - 三态覆盖层

/// 盖在 collection view 上的一层，但**不吃点击**：标题行（含音乐源切换器）在下面，
/// 加载/出错/空态期间照样要能点。
private final class CatalogOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

// MARK: - 收悬浮的 collection view

/// 悬浮态由 tracking area 直接推给页面控制器（铁律 3：不经 `@Published` 绕一圈）。
private final class CatalogShelfCollectionView: NSCollectionView {

    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?

    weak var leftArrow: NSView?
    weak var rightArrow: NSView?

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let pointInSelf = convert(point, from: superview)
        if let leftArrow, !leftArrow.isHidden, leftArrow.alphaValue > 0.05,
           leftArrow.frame.contains(pointInSelf) {
            return leftArrow
        }
        if let rightArrow, !rightArrow.isHidden, rightArrow.alphaValue > 0.05,
           rightArrow.frame.contains(pointInSelf) {
            return rightArrow
        }
        return super.hitTest(point)
    }

    /// orthogonal 段自带的横向滚动视图会在触控板滑动时冒出一条横向滚动条，
    /// Music 的货架没有这东西（翻页靠两端的胶囊箭头）。它是布局内部造的私有视图，
    /// 只能在它被挂进来那一刻把滚动条关掉。
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        makeInternalShelfTransparent(of: subview)
    }

    /// 布局每跑一遍就再来一次：那个私有滚动视图在自己的布局里会把滚动条和
    /// 背景重新打开。
    override func layout() {
        super.layout()
        for subview in subviews { makeInternalShelfTransparent(of: subview) }
    }

    /// orthogonal 货架（`_NSCollectionScrollView` + 里面的内层 collection view）
    /// 默认自带深色背景——艺人页的货架必须**无背景**，直接压在钉住的封面糊图上
    /// （Music 实机就是这样，段落之间透出的就是同一张糊图）。它每次布局都会
    /// 把自己的背景画回来，所以这里在挂进来时和每次布局都置透明。
    private func makeInternalShelfTransparent(of view: NSView) {
        guard let shelf = view as? NSScrollView else { return }
        shelf.drawsBackground = false
        if shelf.hasHorizontalScroller { shelf.hasHorizontalScroller = false }
        if shelf.hasVerticalScroller { shelf.hasVerticalScroller = false }
        if let inner = shelf.documentView as? NSCollectionView {
            inner.backgroundColors = [.clear]
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        let loc = convert(event.locationInWindow, from: nil)
        // 鼠标如果仍在可视区域（例如悬浮在胶囊或卡片上），不触发虚假退出
        if visibleRect.contains(loc) { return }
        onMouseExited?()
    }
}

// MARK: - 页面大标题行

/// 32pt bold 标题 + 右端音乐源切换器。切换器是 SwiftUI 叶子，装在定尺寸槽里
/// （铁律 2）；Music 单一服务没有这一件，挂在标题行不破坏版式。
private final class CatalogPageTitleView: NSView, NSCollectionViewElement {

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = NSFont.systemFont(ofSize: MusicMetrics.Catalog.titleSize, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, appState: AppState) {
        label.stringValue = title
    }
}

// MARK: - 段标题

/// 段标题三种形态（design-ref/apple-music-catalog-pages.md §0）：
/// ① 纯标题 ② 标题 + ›（可点进「查看全部」）
/// ③ **种子头**：左侧 36 种子封面 + 右侧两行（小字关系词 / 大字种子名 + ›）。
///
/// 视图自己的高里含着「上一段卡底 → 本段标题顶」的空白（`topGap`）与
/// 「段标题底 → 卡顶」的 13：组合布局的 `contentInsets.top` 落在段头**下面**，
/// 段头上方的空白只能由段头自己带（见文件头实测）。
private final class CatalogSectionHeaderView: NSView, NSCollectionViewElement {

    private typealias M = MusicMetrics.Catalog

    private let row = CatalogHeaderRow()
    private let thumb = NSImageView()
    private let headline = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    private var topConstraint: NSLayoutConstraint!
    private var thumbWidth: NSLayoutConstraint!
    private var thumbGap: NSLayoutConstraint!
    private var artworkToken = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 4
        thumb.layer?.masksToBounds = true
        thumb.imageScaling = .scaleProportionallyUpOrDown
        row.addSubview(thumb)

        headline.font = NSFont.systemFont(ofSize: M.seedHeadlineSize)
        headline.textColor = .secondaryLabelColor
        headline.lineBreakMode = .byTruncatingTail
        title.font = NSFont.systemFont(ofSize: M.headingSize, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        chevron.contentTintColor = .secondaryLabelColor

        let titleRow = NSStackView(views: [title, chevron])
        titleRow.orientation = .horizontal
        titleRow.spacing = 5
        titleRow.alignment = .centerY
        let text = NSStackView(views: [headline, titleRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(text)

        topConstraint = row.topAnchor.constraint(equalTo: topAnchor)
        thumbWidth = thumb.widthAnchor.constraint(equalToConstant: 0)
        thumbGap = text.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            topConstraint,
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -M.headingToContent),
            thumb.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            thumb.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            thumbWidth,
            thumb.heightAnchor.constraint(equalTo: thumb.widthAnchor),
            thumbGap,
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(section: CatalogSection, topGap: CGFloat, push: @escaping (Route) -> Void) {
        topConstraint.constant = topGap
        title.stringValue = section.title ?? ""
        chevron.isHidden = !section.showsChevron

        let seed = section.headline
        headline.stringValue = seed ?? ""
        headline.isHidden = seed == nil
        thumb.isHidden = seed == nil
        thumbWidth.constant = seed == nil ? 0 : M.seedThumbSize
        thumbGap.constant = seed == nil ? 0 : M.seedGap

        artworkToken += 1
        thumb.image = nil
        if seed != nil, let url = ArtworkSize.url(section.seedArtworkURL, points: M.seedThumbSize) {
            // 与卡片封面同一条道理：内存里有就同步贴，别让种子头也白一帧。
            if let cached = ImageCache.shared.memoryCachedImage(for: url) {
                thumb.image = cached
            } else {
                let token = artworkToken
                Task { [weak self] in
                    let image = await ImageCache.shared.image(for: url)
                    guard let self, token == self.artworkToken else { return }
                    self.thumb.image = image
                }
            }
        }

        if let destination = section.destination {
            row.onClick = { push(destination) }
        } else {
            row.onClick = nil
        }
    }
}

// MARK: - 并排带的双标题段头

/// 艺人页并排带那一行段头：左边「最新發行」（纯标签，不可点），
/// 右边「熱門歌曲 ›」（可点，走 `section.destination`）。
///
/// [PX] 右标题的左沿与右边那条曲目货架的第一列对齐 —— 也就是
/// `releaseWidth(364) + releaseToShelfGap(32)`；音源没给专辑（左半不摆）时，
/// 右标题退回 x=0，与整条带一起左移。
///
/// 高度算法与 `CatalogSectionHeaderView` 同一套：`topGap + 标题行高 + headingToContent`
/// （组合布局的 `contentInsets.top` 落在段头**下面**，段头上方的空白只能由段头自己带）。
private final class CatalogBandHeaderView: NSView, NSCollectionViewElement {

    private typealias M = MusicMetrics.Catalog

    private let leadingTitle = NSTextField(labelWithString: "")
    private let trailingRow = CatalogHeaderRow()
    private let trailingTitle = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    private var topConstraint: NSLayoutConstraint!
    private var trailingRowTop: NSLayoutConstraint!
    private var trailingRowLeading: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        leadingTitle.font = NSFont.systemFont(ofSize: M.headingSize, weight: .semibold)
        leadingTitle.lineBreakMode = .byTruncatingTail
        leadingTitle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leadingTitle)

        trailingTitle.font = NSFont.systemFont(ofSize: M.headingSize, weight: .semibold)
        trailingTitle.lineBreakMode = .byTruncatingTail
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        chevron.contentTintColor = .secondaryLabelColor

        let stack = NSStackView(views: [trailingTitle, chevron])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        trailingRow.addSubview(stack)
        trailingRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailingRow)

        topConstraint = leadingTitle.topAnchor.constraint(equalTo: topAnchor)
        trailingRowTop = trailingRow.topAnchor.constraint(equalTo: topAnchor)
        trailingRowLeading = trailingRow.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            topConstraint,
            leadingTitle.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailingRowTop,
            trailingRowLeading,
            trailingRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: trailingRow.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingRow.trailingAnchor),
            stack.topAnchor.constraint(equalTo: trailingRow.topAnchor),
            stack.bottomAnchor.constraint(equalTo: trailingRow.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(section: CatalogSection, topGap: CGFloat, hasRelease: Bool,
                   push: @escaping (Route) -> Void) {
        topConstraint.constant = topGap
        trailingRowTop.constant = topGap
        trailingRowLeading.constant = hasRelease
            ? MusicMetrics.ArtistPage.releaseWidth + MusicMetrics.ArtistPage.releaseToShelfGap : 0

        leadingTitle.stringValue = section.title ?? ""
        leadingTitle.isHidden = section.title == nil || !hasRelease
        trailingTitle.stringValue = section.trailingTitle ?? ""
        trailingRow.isHidden = section.trailingTitle == nil
        chevron.isHidden = !section.showsChevron

        if let destination = section.destination {
            trailingRow.onClick = { push(destination) }
        } else {
            trailingRow.onClick = nil
        }
    }
}

/// 段标题里真正可点的那一行（点击区域只覆盖文字，不包含上下留白）。
private final class CatalogHeaderRow: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard onClick != nil else { super.mouseDown(with: event); return }
    }

    override func mouseUp(with event: NSEvent) {
        guard let onClick else { super.mouseUp(with: event); return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 有落点才拦事件；没落点的纯标题段照旧把事件放给下面。
        guard onClick != nil else { return nil }
        return super.hitTest(point).map { _ in self }
    }
}

// MARK: - 翻页胶囊

/// 悬停货架时两端浮出的 28×52 胶囊箭头：`.ultraThinMaterial` 胶囊 + 0.5 描边 + 阴影
/// （与旧 SwiftUI 版 `navArrow` 同一长相）。
private final class CatalogShelfArrowButton: NSView {

    enum Direction { case left, right }

    private let action: () -> Void
    private let material = NSVisualEffectView()
    private let border = NSView()

    init(direction: Direction, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(direction == .left ? "上一页" : "下一页")
        toolTip = direction == .left ? "上一页" : "下一页"
        appearance = NSAppearance(named: .darkAqua)

        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 6
        // AppKit 的 y 轴朝上，SwiftUI 的 `y: 1`（往下）对应这里的 −1。
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        material.material = .hudWindow
        material.blendingMode = .withinWindow
        material.state = .active
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)

        border.wantsLayer = true
        border.layer?.borderWidth = 0.5
        border.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        let glyph = NSImageView()
        glyph.image = NSImage(
            systemSymbolName: direction == .left ? "chevron.compact.left" : "chevron.compact.right",
            accessibilityDescription: direction == .left ? "上一页" : "下一页")?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .regular))
        glyph.contentTintColor = .white
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)

        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.topAnchor.constraint(equalTo: topAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isEnabled: Bool = true {
        didSet {
            guard oldValue != isEnabled else { return }
            updateAppearance()
        }
    }

    var isHovered: Bool = false {
        didSet {
            guard oldValue != isHovered else { return }
            updateAppearance()
        }
    }

    private var isPressed: Bool = false {
        didSet {
            guard oldValue != isPressed else { return }
            updateAppearance()
        }
    }

    override func layout() {
        super.layout()
        let radius = min(bounds.width, bounds.height) / 2
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil)
        border.layer?.cornerRadius = radius
        // 材质层用 maskImage 剪成胶囊（`NSVisualEffectView` 的正经做法，不是给它的 layer 打圆角）。
        material.maskImage = Self.capsuleMask(radius: radius)
        updateAppearance()
    }

    private func updateAppearance() {
        if isPressed {
            layer?.transform = CATransform3DMakeScale(0.95, 0.95, 1)
            material.alphaValue = 0.85
        } else if isHovered {
            layer?.transform = CATransform3DIdentity
            material.alphaValue = 1.0
            border.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        } else {
            layer?.transform = CATransform3DIdentity
            material.alphaValue = 0.95
            border.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        }
    }

    private static func capsuleMask(radius: CGFloat) -> NSImage {
        let side = max(1, radius * 2)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, !isHidden, alphaValue > 0.05 else { return nil }
        guard frame.contains(point) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !isHidden, alphaValue > 0.1 else { return }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, !isHidden, alphaValue > 0.1 else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if isPressed != inside {
            isPressed = inside
        }
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let wasPressed = isPressed
        isPressed = false
        if isEnabled, !isHidden, alphaValue > 0.1, wasPressed, inside {
            action()
        }
    }
}

