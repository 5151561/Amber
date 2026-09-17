import AppKit
import QuartzCore
import SwiftUI

/// 「正在播放」整窗播放器的容器（Music 的 `MPContentView`）。**常驻**，收起时整块位移到
/// 窗口下沿之外。
///
/// 骨架是 AppKit（计划阶段 6）：
///
/// ```
/// NowPlayingContainerViewController
///   ├── backdrop : MiniPlayerBackdropMetalView        §2.1 纱罩/律动＝内容视图宽度的函数
///   │                （「减弱透明度」开着时换成 NSVisualEffectView，见 `makeBackdrop()`）
///   ├── content  : NSHostingView<NowPlayingView>      封面/元数据/时间行/传输行（SwiftUI 叶子）
///   ├── drawer   : InspectorContainerViewController   §4 歌词档／队列档共用一台容器
///   │     └── platterGlass : NSGlassEffectView(.regular)   队列档那块盘的玻璃外形
///   └── chrome   : NowPlayingChromeView               四角胶囊 + rollover + 粒子
/// ```
///
/// 为什么不是「要用才建」：那样每次展开都是新建一棵 `NowPlayingView`，`@State` 全部归零——
/// 背景先画成空态灰、封面是占位方块，等 `.task` 取回封面才补上，肉眼就是
/// 「背景瞬间出现、内容随后滑上来」。常驻 + 自己算位移之后，展开即完成态。
///
/// 展开/收起的动画归 AppKit（旧版是 SwiftUI 的 `.animation(.spring(...), value:)`）：
/// `CASpringAnimation` 的 stiffness / damping 由`MusicMetrics.NowPlaying` 的
/// `transitionResponse` / `transitionDamping` 换算（质量取 1：ω = 2π/response，
/// stiffness = ω²，damping = 2ζω——这是 SwiftUI `spring(response:dampingFraction:)`
/// 的定义式，两边同一条曲线）。
///
/// 内容列仍是 SwiftUI（Music 同构，nowplaying spec §6.1 那棵 `NowPlayingView` 类型树），
/// 但**槽位契约反过来**：列宽由本容器算好当参数传进去，不再让 SwiftUI 自己
/// `GeometryReader` 量容器；`primaryArtworkCenterY` 也由本容器按同一个列宽自算，
/// 不再走 `PreferenceKey` 往上报（计划「阶段 6 开工前的三处决定」第 3 条）。
@MainActor
final class NowPlayingContainerViewController: NSViewController {

    private typealias M = MusicMetrics.NowPlaying

    private let appState: AppState
    private var player: PlayerController { appState.player }

    // MARK: 子视图

    /// [实测] 背景是 `TSLBackdropMetalView` 的复刻（计划「三处决定」第 2 条）。
    /// 四边贴满，纱罩浓度与律动速度每次 layout 按**容器宽度**重算（§2.1）。
    ///
    /// **不是 `let`，也不一定是 Metal 那只**：「减弱透明度」开着时它是毛玻璃那一支
    /// （见 `makeBackdrop()`）。降级＝整只换掉，不是给同一只视图改参数。
    ///
    /// 初值里写全类名而不是 `Self`：存储属性的初始值里 `Self` 算协变位置，编译器不收。
    private var backdrop: NSView = NowPlayingContainerViewController.makeBackdrop()

    /// `backdrop` 是不是 Metal 那只。`as?` 的地方有五处（isActive / 纱罩 / 律动 / 封面），
    /// 收在这一句里，省得每处各判一次型。
    private var metalBackdrop: MiniPlayerBackdropMetalView? {
        backdrop as? MiniPlayerBackdropMetalView
    }

    /// 当前封面的 CGImage。换底衬之后要把它重喂一遍
    /// （同 `MiniPlayerContentView.currentArtwork`）。
    private var backdropArtwork: CGImage?

    /// 「减弱透明度」的观察令牌。**观察点必须在宿主这边**：降级时那只 Metal 视图
    /// 根本不在场，挂在它身上的观察器等不到「关掉」那一下
    /// （批 F2 踩过的坑，判据因此做成了 `MiniPlayerBackdropMetalView` 的类型属性）。
    private var accessibilityPreferenceObserver: (any NSObjectProtocol)?

    /// 内容列那棵 SwiftUI 叶子。铁律 2：定尺寸槽 + `sizingOptions = []`。
    private var contentHost: NSHostingView<AnyView>?

    /// [实测] inspector 规格 §4：「窗口右侧栏」与「整窗播放器抽屉」是同一个容器类的
    /// 两个实例，整窗那份打开沉浸档、`includeBackdrop = false`。
    private let drawer: InspectorContainerViewController

    /// 队列档那块盘的玻璃。**不能用 clear**：盘有 630×748 那么大，clear 会让底下的
    /// 歌词整片透上来，两层字叠在一起谁都读不了（小胶囊用 clear 没问题）。
    private let platterGlass = NSGlassEffectView()
    /// 玻璃只保证 `contentView` 在效果里面（头文件原话），队列档时抽屉挂这一层。
    private let platterContent = NSView()

    /// 换档时被摘出抽屉、钉在原地单独演退场的**上一档面板**（见 `detachOutgoingPanel`）。
    private var outgoingPanel: NSView?

    /// 「盘正带着上一档的队列面板滑出去」这一程。期间 `syncDrawerPlacement`
    /// 不许摘掉/藏掉玻璃盘——落位统一交给 `animatePlatter` 的收尾。
    private var platterIsExiting = false

    private let chrome: NowPlayingChromeView

    /// 没有封面时的那层底色。
    ///
    /// `MiniPlayerBackdropMetalView` 的安全降级是「纹理拿不到就是一块**透明**的空视图」
    /// （见它自己的类头）——迷你窗那边缺省走毛玻璃那一支，所以这条降级从没露过面；
    /// 整窗这边它是唯一的背景，没有封面就等于整块播放器透明，资料库直接透上来。
    /// 旧的 SwiftUI 背景本来有这一层（`NowPlayingBackdropView.idle`），
    /// [PX] 反算自 Music 空态截图的 `#6E6F72`，换骨架时连同那个文件一起没了，这里补回。
    private let backdropIdle = NSView()

    // MARK: 呈现状态（原 `NowPlayingViewModel` 那一份）

    private(set) var isPresented = false

    /// **整窗播放器这一扇**的「抽屉开着没有」。[实测] §2.2 `lyricsClicked` / `queueClicked`。
    ///
    /// 「开着没有」一扇窗一份（主窗是 `AppState.isInspectorOpen`、迷你窗是
    /// `MiniPlayerContentView.currState`），「开的是哪一档」全局一份
    /// （`AppState.inspectorMode`）。
    private var isInspectorOpen = false

    /// 面板档位的只读窄镜像，真值在 `AppState.inspectorMode`。
    private var inspectorMode: PlayerInspector

    /// [实测] §3.2 `showTotalInsteadOfRemaining`（`doTimeRemainingClicked:` 翻转它）。
    /// 时间行在 SwiftUI 那一侧画，值与「翻下一档」的回调由本容器供给。
    private var timeAccessory: NowPlayingTimeAccessory = .remaining

    private var artwork: NSImage?
    private var artworkTask: Task<Void, Never>?
    private var loadedArtworkTrackID: String?


    private let observers = TaskBag()

    #if DEBUG
    /// 见 `init` 里那段：`-nowplaying -queue` / `-lyrics` 的验收口子，
    /// 第一次有效布局之后照点击那条路把抽屉打开。
    private var debugOpensDrawerOnLaunch = false
    /// `-nowplaying -queue -lyrics`：开在队列档之后再切到歌词档。
    private var debugSwitchesToLyrics = false
    #endif

    /// 有过一次「bounds 非空」的布局没有。
    ///
    /// 抽屉里装的是一张有分区头的 `NSTableView`（`PlayQueueViewController`）。它在
    /// **0 尺寸**下走一遍布局就会踩 AppKit 的断言
    /// （`-[NSTableRowData _updateFloatingGroupRowView:row:]`，NSTableRowData.m:6900，
    /// 实机 lldb 抓到：`NSTableView.setFrameSize:` → `updateRowViewFrames` → 断言抛出、
    /// 整个 App 起不来）。与「组合布局 0 宽会爆内存」是同一族：**已经进了视图树、
    /// 但还没有真尺寸**的那一帧最危险。
    ///
    /// 平时的顺序是安全的（抽屉由底栏那颗键在窗口早就布好局之后才打开），
    /// 危险的是「一上来就开着」——`-nowplaying -queue` 那个验收口子就是这条路，
    /// 将来若把抽屉状态做成可恢复的也一样。所以第一次有效布局之前抽屉一律当「收着」，
    /// 布局完再补摆一次。
    private var hasValidLayout = false

    /// 上一次推给 SwiftUI 的那组入参。相等就不换 rootView——换一次是整棵内容列重算，
    /// 而 `layout()` 在拖窗口时每帧都会来。
    private struct ContentInputs: Equatable {
        var columnWidth: CGFloat = 0
        var isActive = false
        var timeAccessory: NowPlayingTimeAccessory = .remaining
        var artworkFingerprint: ObjectIdentifier?
    }
    private var pushedInputs = ContentInputs()

    // MARK: - 生命周期

    init(appState: AppState) {
        self.appState = appState
        self.inspectorMode = appState.inspectorMode
        // [实测] §4.2：整窗那份容器打开沉浸档（`isImmersionMode` 与 `isMiniPlayerMode`
        // 是同一个开关的正反面，一起传给歌词控制器）。
        self.drawer = InspectorContainerViewController(appState: appState, immersion: true)
        self.chrome = NowPlayingChromeView(appState: appState)
        super.init(nibName: nil, bundle: nil)
        addChild(drawer)
        #if DEBUG
        // 与 `AmberApp` 里 `-lyrics` / `-queue` 同族的验收口子。那两个开的是**主窗**
        // 面板列（`AppState.isInspectorOpen`），而整窗播放器的抽屉是**本窗自己**那一份，
        // 底栏胶囊那两颗键又没有菜单命令、还跟着 rollover 淡出（实机点不到，
        // 同 `-lyrics` 那处的注释），于是 `-nowplaying` 同时带上 `-lyrics` / `-queue`
        // 时把这台的抽屉也打开，配 `-dumpviews` 就能量到抽屉开着时的内容列与面板 frame。
        //
        // **不直接把 `isInspectorOpen` 预置成 true**：那样抽屉是在「还没有任何布局」
        // 的状态下被摆出来的，与用户点那颗键的路径不是同一条（真点的时候窗口早就布好局了），
        // 验收就失去意义；而且队列表在 0 尺寸下走布局会踩 AppKit 的断言。
        // 改成第一次有效布局之后**走和点击同一条路**（`setInspectorOpen`），
        // 见 `layoutPieces` 里那一段。
        let args = CommandLine.arguments
        if args.contains("-nowplaying"), args.contains("-lyrics") || args.contains("-queue") {
            debugOpensDrawerOnLaunch = true
            debugSwitchesToLyrics = args.contains("-queue") && args.contains("-lyrics")
        }
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let container = NowPlayingContainerView()
        container.wantsLayer = true
        view = container

        // 自底向上：背景 → 内容列 → 抽屉（队列档时外面套玻璃）→ 四角胶囊 + 粒子。
        backdropIdle.wantsLayer = true
        // [PX] 反算自 Music 空态截图的 #6E6F72。
        backdropIdle.layer?.backgroundColor = NSColor(srgbRed: 0.357, green: 0.361,
                                                      blue: 0.373, alpha: 1).cgColor
        backdropIdle.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(backdropIdle)
        container.addSubview(backdrop)
        pushBackdropInputs()
        // [HIG] 「减弱透明度」两个方向都要走得通：打开时退回毛玻璃、关掉时换回 Metal。
        // 系统偏好随时可改，所以常驻一条观察。
        accessibilityPreferenceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildBackdropIfNeeded() }
        }

        // 首帧先用列宽下限占位；真正的列宽在第一次 `layout()` 里算好推进去。
        let host = appState.hostingView { contentColumn(columnWidth: Self.minimumColumn) }
        // 槽是本容器手排的定尺寸 frame，不要自动布局掺一脚。
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = []
        container.addSubview(host)
        contentHost = host

        platterGlass.wantsLayer = true
        platterGlass.style = .regular
        platterGlass.cornerRadius = M.platterCornerRadius
        platterGlass.contentView = platterContent
        platterGlass.translatesAutoresizingMaskIntoConstraints = true

        // 抽屉起手挂在容器上（歌词档不套玻璃，见 inspector spec §4.1）。
        container.addSubview(drawer.view)
        drawer.view.translatesAutoresizingMaskIntoConstraints = true
        // 与背景同因：抽屉**开着**的时候整块播放器被收起，歌词面板既收不到
        // `viewWillDisappear` 也收不到 `viewDidHide()`（位移出窗、不动 `isHidden`），
        // 每帧驱动会一直跑。抽屉关着那条由 `drawer.view.isHidden` 自己兜住。
        drawer.isActive = isPresented

        chrome.onClose = { [weak self] in self?.close() }
        chrome.onShowMiniPlayer = { [weak self] in
            self?.close()
            AuxiliaryWindows.shared.showMiniPlayer()
        }
        chrome.onInspectorClicked = { [weak self] inspector in
            self?.inspectorClicked(inspector)
        }
        chrome.onReportLyricsConcern = { [weak self] in
            guard let self else { return }
            PlayerMoreMenu.reportLyricsConcern(self.appState)
        }
        container.addSubview(chrome)
        chrome.translatesAutoresizingMaskIntoConstraints = true
        chrome.setInspector(open: isInspectorOpen, mode: inspectorMode)

        // 四角胶囊已经在树上，抽屉这才好按「在玻璃里还是在容器上」摆位（z 序要压在它底下）。
        syncDrawerPlacement()

        container.isInert = !isPresented
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // 抽屉档位跟着全局那一份走（真值在 `AppState.inspectorMode`）。
        observers.observe({ [appState] in appState.inspectorMode }) { [weak self] mode in
            self?.applyInspectorMode(mode, animated: true)
        }

        // 封面：换歌就重取。`currentIndex` 与 `queue` 各发一次，中间那一拍两者还不同步，
        // 同一跳之后直接读 `currentTrack` 才是两者都落定的值（同 `MiniPlayerView.bind`）。
        observers.observeAny({ [player] in (player.currentIndex, player.queue) }) { [weak self] in
            self?.reloadArtworkIfNeeded()
        }

        reloadArtworkIfNeeded()
    }

    /// 观察令牌不是 `Sendable`，非隔离的 `deinit` 取不到它。标 `isolated`：
    /// 主线程上释放时照旧同步跑完，注销时机不变（同 `MiniPlayerContentView`）。
    isolated deinit {
        if let accessibilityPreferenceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityPreferenceObserver)
        }
    }

    // MARK: - 底衬（[HIG]「减弱透明度」的降级）

    /// 造一只当下该用的底衬。
    ///
    /// Metal 那一支是**自绘**的，`NSVisualEffectView` / `NSGlassEffectView` 会在
    /// 「减弱透明度」打开时自己变实心，自绘的这一层不会——所以只能整只换成系统材质那支，
    /// 判据与迷你窗同一条（`MiniPlayerBackdropMetalView.reducesTransparency`，
    /// 那边的落点是 `MiniPlayerContentView.makeBackdrop(style:)` 的 `style != 1` 分支）。
    ///
    /// 毛玻璃那支的三个参数照抄迷你窗那份 [实测]：`.popover`（6）/`.behindWindow`（0）/
    /// `.active`（1）。命中这一支时系统已经把它渲成实心，所以「透出什么」不重要，
    /// 重要的是**这一层是不透明的**——它底下就是资料库，透过去就穿帮了。
    private static func makeBackdrop() -> NSView {
        guard !MiniPlayerBackdropMetalView.reducesTransparency else {
            let view = NSVisualEffectView()
            view.material = .popover
            view.blendingMode = .behindWindow
            view.state = .active
            return view
        }
        let view = MiniPlayerBackdropMetalView()
        // [实测] `appearance = NSAppearance(named: .vibrantDark)` + `setBlur(1000)`
        // （后者在稳态下会被「画布对角线算 σ」那条无条件覆盖，见视图内部注释）。
        view.appearance = NSAppearance(named: .vibrantDark)
        view.setBlur(MusicMetrics.Backdrop.miniPlayerBlurRadius)
        return view
    }

    /// 偏好翻了就整只换掉；没翻就什么都不做（这条通知里还捎着「减弱动态效果」
    /// 等好几项，每一项改动都会发一次，不判一下等于无谓重建）。
    private func rebuildBackdropIfNeeded() {
        let wantsMetal = !MiniPlayerBackdropMetalView.reducesTransparency
        guard wantsMetal != (metalBackdrop != nil) else { return }
        let old = backdrop
        let new = Self.makeBackdrop()
        // 插在旧的正上方再撤掉旧的：z 序原样留住（压在空态底之上、内容列之下）。
        view.addSubview(new, positioned: .above, relativeTo: old)
        old.removeFromSuperview()
        backdrop = new
        pushBackdropInputs()
        view.needsLayout = true
    }

    /// 把「本容器持有、底衬需要」的那几件一次性喂进去。新建一只之后必须调它，
    /// 否则换回来的 Metal 底衬是黑的（没有封面）、而且在没人看的时候照样跑（`isActive`）。
    private func pushBackdropInputs() {
        backdrop.frame = view.bounds
        // ⚠ 背景自己的 `updatePausedState()` 只看窗口可见性/遮挡/`isHidden`，
        // 而整窗播放器收起时是**位移出窗 + alpha 0，不是 isHidden**，它会一直画。
        // 所以多一位 `isActive` 由本容器按 `isPresented` 推。
        metalBackdrop?.isActive = isPresented
        metalBackdrop?.cgImage = backdropArtwork
        applyBackdropDynamics(width: view.bounds.width)
    }

    /// [实测] §2.1：纱罩/律动挂在 `setFrameSize:` 真身尾段，**无条件**跟着宽度重算；
    /// 入参是内容视图的**宽度**，不是高度。毛玻璃那支整段不管
    /// （原版第一句就是 `backdrop as? TSLBackdropMetalView` 的判型）。
    private func applyBackdropDynamics(width: CGFloat) {
        guard let metalBackdrop else { return }
        metalBackdrop.scrimAlpha = M.backdropScrimAlpha(contentWidth: width)
        metalBackdrop.animationInterval = Float(M.backdropAnimationInterval(contentWidth: width))
    }

    // MARK: - 内容列

    /// 整窗播放器的内容列。列宽、是否在跟随、时间行档位全部由本容器算好传进去。
    private func contentColumn(columnWidth: CGFloat) -> some View {
        NowPlayingView(
            columnWidth: columnWidth,
            artwork: artwork,
            isActive: isPresented,
            timeAccessory: timeAccessory,
            onCycleTimeAccessory: { [weak self] in
                guard let self else { return }
                self.timeAccessory = self.timeAccessory.next
                self.pushContentInputsIfNeeded(force: true)
            },
            onGoToArtist: { [weak self] track in
                guard let self else { return }
                self.appState.goToArtist(of: track)
                self.close()
            })
    }

    private func pushContentInputsIfNeeded(columnWidth: CGFloat? = nil, force: Bool = false) {
        guard let host = contentHost else { return }
        var inputs = pushedInputs
        if let columnWidth { inputs.columnWidth = columnWidth }
        inputs.isActive = isPresented
        inputs.timeAccessory = timeAccessory
        inputs.artworkFingerprint = artwork.map(ObjectIdentifier.init)
        guard force || inputs != pushedInputs else { return }
        pushedInputs = inputs
        host.rootView = appState.hostingRoot { contentColumn(columnWidth: inputs.columnWidth) }
    }

    // MARK: - 布局

    /// 窗口矮到放不下时的列宽下限。[推]
    private static let minimumColumn: CGFloat = 120

    /// 内容列的槽位几何。**这是契约**：容器算好、当参数传进去，SwiftUI 不再自己量。
    ///
    /// ```
    /// slotWidth  = 抽屉开 ? 宽/2 : 宽                       // 内容列所在半区
    /// stackBelow = 19 + 37.5 + 17 + 15 + 1.85 + 13 + 10.15 + 48 = 161.5
    /// byWidth    = 整窗宽 × contentWidthFraction(0.28)      // 注意是整窗宽，不是半区宽
    /// byHeight   = 高 − stackBelow − minVerticalMargin × 2
    /// column     = max(min(byWidth, byHeight), 120).rounded()
    /// ```
    ///
    /// 自检（1440×923、抽屉开）：`column = 403`、内容块顶 = (923 − 564.5)/2 + 2.75 = **182.0**、
    /// 封面中心 = 182 + 403/2 = **383.5**。规格 [AX] 实测是封面顶 182、底 585.5、
    /// 中心 383.75（0.25 是 403.5 的取整误差）。列左沿 = (720 − 403)/2 = 158.5，
    /// 封面中心 x = 360，也与 [AX] 对上。
    private struct ContentGeometry {
        var column: CGFloat
        var blockHeight: CGFloat
        /// 内容块顶边距容器顶（**自上而下**的坐标）
        var topInset: CGFloat
        /// 封面格子中心距容器顶（**自上而下**）
        var artworkCenterY: CGFloat
        /// 内容列在容器坐标系（AppKit，y 自下而上）里的矩形
        var frame: NSRect
    }

    private func contentGeometry(in bounds: NSRect) -> ContentGeometry {
        let slotWidth = isInspectorOpen ? bounds.width / 2 : bounds.width
        let stackBelow = M.artworkToMetadata + M.metadataHeight + M.metadataToScrubber
            + M.scrubberHitHeight + M.scrubberToTime + M.timeRowHeight
            + M.timeToTransport + M.transportRowHeight
        let byWidth = bounds.width * M.contentWidthFraction
        let byHeight = bounds.height - stackBelow - M.minVerticalMargin * 2
        let column = max(min(byWidth, byHeight), Self.minimumColumn).rounded()
        let blockHeight = column + stackBelow
        let topInset = (bounds.height - blockHeight) / 2 + M.contentOffsetY
        let frame = NSRect(x: (slotWidth - column) / 2,
                           y: bounds.height - topInset - blockHeight,
                           width: column, height: blockHeight)
        return ContentGeometry(column: column, blockHeight: blockHeight, topInset: topInset,
                               artworkCenterY: topInset + column / 2, frame: frame)
    }

    /// 歌词档的面板矩形（**不套玻璃**：Music 那层玻璃在容器外面，inspector spec §4.1；
    /// Amber 这边歌词档压根不给玻璃，窗口根那层就是底）。
    /// 左右各 19 的内缩走歌词滚动视图**内部**的 margins，不是外面加 padding。
    private func lyricsPanelRect(in bounds: NSRect) -> NSRect {
        let width = max(bounds.width / 2 - M.hostedContentTrailing, 0)
        let height = max(bounds.height - M.hostedContentTop - M.hostedContentBottom, 0)
        return NSRect(x: bounds.width / 2,
                      y: M.hostedContentBottom,
                      width: width, height: height)
    }

    /// 队列档那块盘。高有 [实测] §2.2 的 200 下限。
    private func platterRect(in bounds: NSRect) -> NSRect {
        let height = max(bounds.height - M.hostedContentTop - M.hostedContentBottom,
                         M.drawerMinHeight)
        let x = bounds.width / 2 + M.hostedContentInset
        let width = max(bounds.width - M.hostedContentTrailing - x, 0)
        return NSRect(x: x, y: M.hostedContentBottom, width: width, height: height)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutPieces()
    }

    private func layoutPieces() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let firstLayout = !hasValidLayout
        hasValidLayout = true
        defer {
            if firstLayout {
                syncDrawerPlacement()
                #if DEBUG
                if debugOpensDrawerOnLaunch {
                    debugOpensDrawerOnLaunch = false
                    // 布局里再触发一轮布局是回环，挪到下一轮 runloop。
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.setInspectorOpen(true, animated: false)
                        // `-queue` 与 `-lyrics` **同时**给 = 「开在队列档，再切到歌词档」，
                        // 也就是底栏那两颗键连点两下那条路（收盘 → 换档）。
                        // 这一步单独留个口子是因为它出过 bug：盘的收起动画收尾时
                        // 连抽屉一起藏，而那时抽屉里装的已经是歌词面板了。
                        guard self.debugSwitchesToLyrics else { return }
                        self.debugSwitchesToLyrics = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                            self?.inspectorClicked(.lyrics)
                        }
                    }
                }
                #endif
            }
        }

        backdropIdle.frame = bounds
        backdrop.frame = bounds
        applyBackdropDynamics(width: bounds.width)

        let geometry = contentGeometry(in: bounds)
        contentHost?.frame = geometry.frame
        pushContentInputsIfNeeded(columnWidth: geometry.column)

        chrome.frame = bounds

        let drawerRect = inspectorMode == .queue ? platterRect(in: bounds)
                                                 : lyricsPanelRect(in: bounds)
        platterGlass.frame = platterRect(in: bounds)
        platterContent.frame = NSRect(origin: .zero, size: platterGlass.frame.size)
        drawer.view.frame = inspectorMode == .queue
            ? NSRect(origin: .zero, size: drawerRect.size)
            : drawerRect

        // 封面中心 → 歌词面板顶边往下多少。[实测] §8.1 的 `offsetObservation` 那条路：
        // 容器几何一变（抽屉开合、窗口缩放）就把新的基线传导给歌词布局。
        let panelTop = bounds.height - lyricsPanelRect(in: bounds).maxY
        drawer.lyrics.setArtworkCenter(
            offsetFromPanelTop: isInspectorOpen && inspectorMode == .lyrics
                ? geometry.artworkCenterY - panelTop
                : nil)
    }

    /// 宿主（窗口根）布局时调一次：整块与窗口同尺寸，按当前状态放在窗内或窗下。
    func layoutInHost(bounds: NSRect) {
        view.frame = NSRect(x: bounds.minX,
                            y: bounds.minY + (isPresented ? 0 : -bounds.height),
                            width: bounds.width, height: bounds.height)
    }

    // MARK: - 展开 / 收起

    func setPresented(_ presented: Bool, animated: Bool) {
        let changed = presented != isPresented
        isPresented = presented
        if changed {
            // 背景律动、rollover 计时、时间行那 10 Hz 的走时全按这一位启停。
            // 毛玻璃那支没有律动可停（由系统自己画），所以只推给 Metal 那只。
            metalBackdrop?.isActive = presented
            chrome.isActive = presented
            drawer.isActive = presented
            pushContentInputsIfNeeded()
            if !presented {
                // 收起期间视图并没有离开视图树（不靠 `isHidden`，见 `hideAfterCollapse`），
                // 子控制器收不到 `viewDidDisappear`，队列面板那条 5 秒回滚要从这里补一刀
                // （同 `MiniPlayerContentView.viewDidMoveToWindow` 里那处）。
                drawer.queue.panelDidBecomeHidden()
            }
        }
        if presented {
            // 收起期间只是「不参与命中测试、不进辅助功能树」+ alpha 0，展开先还原。
            (view as? NowPlayingContainerView)?.isInert = false
            view.alphaValue = 1
        }
        guard let superview = view.amberSuperview else { return }

        let bounds = superview.bounds
        let targetY = bounds.minY + (presented ? 0 : -bounds.height)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        guard changed, animated, !reduceMotion, let layer = view.layer else {
            view.frame = NSRect(x: bounds.minX, y: targetY,
                                width: bounds.width, height: bounds.height)
            if !presented { hideAfterCollapse() }
            return
        }

        let fromY = layer.presentation()?.position.y ?? layer.position.y
        view.frame = NSRect(x: bounds.minX, y: targetY,
                            width: bounds.width, height: bounds.height)
        let spring = Self.spring(keyPath: "position.y",
                                 response: M.transitionResponse,
                                 damping: M.transitionDamping)
        spring.fromValue = fromY
        spring.toValue = layer.position.y
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "amber.nowPlayingSlide")

        if !presented {
            let delay = spring.settlingDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isPresented else { return }
                self.hideAfterCollapse()
            }
        }
    }

    /// 动画结束再收尾：收早了就看不到落下去的那一段。
    ///
    /// 类头注释真正要的只有两件事——**不参与命中测试、不进辅助功能树**。
    /// 从前是拿 `isHidden` 一并办掉的，代价是`NSHostingView` 一旦被隐藏，
    /// 里面那棵 SwiftUI 就**停止更新**（`PageHosting.swift` 自己记着这条规律）：
    /// 收起期间从迷你播放器换了歌，内容列的 `.task(id: track?.id)` 不跑，
    /// 再按开先看到上一首的封面/空态再淡入新的——正是本类头注释说要避免的那一幕
    /// （design-ref/reactive-ui-review.md 故障 16）。
    ///
    /// 所以两件事各用各的开关，`isHidden` 这把过度的锤子收起来：
    /// 命中测试由 `NowPlayingContainerView.hitTest` 短路、辅助功能树由
    /// `accessibilityHidden` 摘掉，画面上再压一道 `alphaValue = 0`
    ///（整块本来就已经位移到窗外，这一道是保险）。
    ///
    /// 「收起后 CPU ≈ 0」不靠这里：那是 `isPresented` 的事——背景律动（`backdrop.isActive`）、
    /// rollover 计时与粒子（`chrome.isActive`）、连时间行那 10 Hz 的走时
    /// （`PlaybackTimeReader.isActive`）全按它停。
    private func hideAfterCollapse() {
        (view as? NowPlayingContainerView)?.isInert = true
        view.alphaValue = 0
    }

    // MARK: - 抽屉

    /// 底栏那两颗键：点当前这一档 = 收起（不动全局档位），点另一档 = 换档并保持展开
    /// （与主窗 `AppState.toggleInspector` 同一条语义，只是「开着没有」记在本宿主上）。
    ///
    /// [实测] §2.2 `lyricsClicked` / `queueClicked`；菜单项`validate_doShowHide*`
    /// 恒返回 1（§1.1）——**这两个开关永远可用**，没内容时由面板自己兜底显示空态。
    private func inspectorClicked(_ inspector: PlayerInspector) {
        if isInspectorOpen, inspectorMode == inspector {
            setInspectorOpen(false, animated: true)   // 收起不动档位
        } else {
            appState.inspectorMode = inspector        // 真值写回全局那一份
            applyInspectorMode(inspector, animated: isInspectorOpen)
            setInspectorOpen(true, animated: true)
        }
    }

    /// 换档。
    ///
    /// [实测] §1.4 说档位切换是容器**内部**的交叉淡入。整窗播放器这一台不能照搬：
    /// 两档的落点不一样大（队列档在玻璃盘里 = `platterRect`，歌词档直接铺在容器上
    /// = `lyricsPanelRect`，宽 19pt），容器内部淡出的旧面板被约束钉着，抽屉一改尺寸
    /// 它就跟着被拉宽并重排一次——**先变形，再（因为盘被当场摘掉）突然消失**。
    ///
    /// 这里改成「交接」：先把上一档的面板从抽屉里摘出来钉在原地，再各演各的——
    /// - 出队列档：旧面板**留在玻璃盘里**，盘带着它滑下去，与「直接收起清单」完全同一条
    ///   曲线（都是 `animatePlatter(expanded: false)`）；歌词在自己的位置淡入。
    /// - 进队列档：旧的歌词面板留在容器上原地淡出；盘带着队列面板滑上来。
    private func applyInspectorMode(_ mode: PlayerInspector, animated: Bool) {
        guard mode != inspectorMode else { return }
        let previous = inspectorMode
        inspectorMode = mode
        // 上一程还没演完就又换档：先把它收干净，免得两份旧面板叠在场上。
        finishOutgoingPanel()

        let handoff = animated && isInspectorOpen
        platterIsExiting = handoff && previous == .queue
        if handoff { detachOutgoingPanel(of: previous) }

        syncDrawerPlacement()
        // 旧面板已经被摘走，容器里没有可淡出的对象了，直接换。
        drawer.setMode(mode, animated: false)
        chrome.setInspector(open: isInspectorOpen, mode: mode)
        view.needsLayout = true
        layoutPieces()
        guard isInspectorOpen else {
            platterIsExiting = false
            finishOutgoingPanel()
            return
        }
        // 抽屉本身恒可见。alpha 也要掰回来——上一轮收起走的是 `fadeDrawer(to: 0)`，
        // 它把 alpha 留在 0 上。
        drawer.view.isHidden = false
        drawer.view.alphaValue = 1
        if mode == .queue {
            animatePlatter(expanded: true, animated: animated)
            fadeOutOutgoingPanel(animated: animated)
        } else {
            animatePlatter(expanded: false, animated: animated)
            if handoff { fadeDrawer(to: 1, animated: true) }
        }
    }

    /// 把上一档的面板从抽屉里摘出来，钉在它此刻画着的位置上（TAMIC + 定 frame，
    /// 不再吃容器的约束，于是抽屉换尺寸也不会把它重排——「变形」那一半就没了）。
    ///
    /// 落点按档位分：队列那份留在 `platterContent`（玻璃盘的内容层）里，跟着盘一起走；
    /// 歌词那份留在容器上、压在四角胶囊底下，原地淡出。
    private func detachOutgoingPanel(of mode: PlayerInspector) {
        let panel = mode == .queue ? drawer.queue.viewIfLoaded : drawer.lyrics.viewIfLoaded
        guard let panel, panel.superview === drawer.view else { return }
        let host: NSView = mode == .queue ? platterContent : view
        let frame = host.convert(panel.bounds, from: panel)
        drawer.releasePanel(panel)
        panel.translatesAutoresizingMaskIntoConstraints = true
        panel.frame = frame
        if mode == .queue {
            host.addSubview(panel)
        } else {
            view.addSubview(panel, positioned: .below, relativeTo: chrome)
        }
        outgoingPanel = panel
    }

    /// 上一档的面板在原地淡出（只有「进队列档」这条路用得上——出队列档那份是被玻璃盘
    /// 整块带着淡走的，盘的 alpha 已经把它一起吃了）。
    private func fadeOutOutgoingPanel(animated: Bool) {
        guard let panel = outgoingPanel else { return }
        guard animated else { finishOutgoingPanel(); return }
        panel.alphaValue = 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.panelHandoffFade
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishOutgoingPanel() }
        }
    }

    /// 退场演完：把面板还原成「没在场上」的样子并撤走。下次 `setMode` 时容器的
    /// `install` 会重新钉约束，什么都不用交回来。
    private func finishOutgoingPanel() {
        guard let panel = outgoingPanel else { return }
        outgoingPanel = nil
        panel.alphaValue = 1
        panel.removeFromSuperview()
        // 队列面板是被**移出视图树**而不是 `isHidden` 掉的，`viewDidHide` 不会来，
        // 5 秒回滚得自己停（照 `setInspectorOpen(false)` 那一处）。
        if panel === drawer.queue.viewIfLoaded { drawer.queue.panelDidBecomeHidden() }
    }

    /// 换档交接时旧面板原地淡出的时长，与 `fadeDrawer` 那条同值。
    private static let panelHandoffFade: TimeInterval = 0.22

    private func setInspectorOpen(_ open: Bool, animated: Bool) {
        guard open != isInspectorOpen else { return }
        isInspectorOpen = open
        // 换档的交接还没演完就要开合：先收干净，免得旧面板留在盘里跟着一起动。
        platterIsExiting = false
        finishOutgoingPanel()
        syncDrawerPlacement()
        chrome.setInspector(open: open, mode: inspectorMode)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animates = animated && !reduceMotion

        // 内容列的半区跟着变宽/变窄，列宽要重算。落点换了半区，整列是**横移**过去的，
        // 不是在新位置直接出现——先记下它现在画在哪，布完局再从那儿起弹簧。
        let fromX = animates ? contentColumnPresentationX() : nil
        view.needsLayout = true
        layoutPieces()
        if let fromX { slideContentColumn(from: fromX) }

        if inspectorMode == .queue {
            animatePlatter(expanded: open, animated: animates)
        } else {
            fadeDrawer(to: open ? 1 : 0, animated: animates)
        }
        if !open {
            drawer.queue.panelDidBecomeHidden()
        }
    }

    /// 队列档时抽屉挂在玻璃盘里、歌词档时直接挂在容器上。
    /// [实测] inspector spec §4.1：容器本身 `includeBackdrop = false`，
    /// 全屏那层玻璃来自把容器套进外面那一层——Amber 这边就是这块 platter 玻璃。
    private func syncDrawerPlacement() {
        guard isViewLoaded else { return }
        // 有效尺寸出来之前**根本不让抽屉进视图树**。
        //
        // 只把它 `isHidden` 是不够的——隐藏的视图照样参与布局，队列表还是会在 0 尺寸下
        // 走一遍 `setFrameSize:`，照样踩那条断言（实机 lldb 读到的异常正文：
        // **“The row at 0 is not floating.”**，抛点 `NSTableRowData.m:6900`）：
        // 浮动分区头的记账在那一帧被打乱，之后任何一次 resize 都会抛。
        // 见 `hasValidLayout` 的注释。
        guard hasValidLayout else {
            drawer.view.removeFromSuperview()
            platterGlass.removeFromSuperview()
            return
        }
        let wantsPlatter = inspectorMode == .queue
        if wantsPlatter {
            if platterGlass.amberSuperview == nil {
                // 压在四角胶囊底下、内容列之上。
                view.addSubview(platterGlass, positioned: .below, relativeTo: chrome)
            }
            if drawer.view.amberSuperview !== platterContent {
                drawer.view.removeFromSuperview()
                // 先把玻璃的尺寸解算完再插抽屉。
                //
                // `NSGlassEffectView` 是**用约束**把 `contentView` 钉满自己的
                // （计划 §5 的实测：TAMIC 被置 false、frame = 玻璃的 bounds），
                // 所以刚赋值那一刻 `contentView` 还是 0×0，约束要等下一轮布局才解。
                // 队列表就装在里面：它会先按 0 尺寸摆一遍、再被拉到真尺寸，
                // 而 `NSTableView` 从 0 宽 resize（栈里的 `resizeWithOldSuperviewSize:`）
                // 会把浮动分区头的记账弄错，抛
                // **“The row at 0 is not floating.”**（`NSTableRowData.m:6900`）。
                platterGlass.layoutSubtreeIfNeeded()
                platterContent.addSubview(drawer.view)
            }
        } else {
            if drawer.view.amberSuperview !== view {
                drawer.view.removeFromSuperview()
                view.addSubview(drawer.view, positioned: .below, relativeTo: chrome)
            }
            // 交接期间盘还要带着上一档的队列面板滑出去，这里不摘——
            // 收尾在 `animatePlatter` 的 completion 里（`platterIsExiting`）。
            if !platterIsExiting { platterGlass.removeFromSuperview() }
        }
        // 「谁负责淡」随档位换：队列档淡的是玻璃盘（抽屉在盘里恒不透明），
        // 歌词档淡的是抽屉自己。换过去之前把另一位复位，免得留着上一档的 alpha 0。
        if wantsPlatter { drawer.view.alphaValue = 1 }
        // `hasValidLayout` 见它自己的注释：0 尺寸下让队列表上屏 = AppKit 断言。
        let shows = isInspectorOpen && hasValidLayout
        drawer.view.isHidden = !shows
        if !platterIsExiting { platterGlass.isHidden = !(wantsPlatter && shows) }
    }

    /// 内容列此刻**画在**哪（不是它的落点）。
    ///
    /// 读 presentation 而不是 `layer.position`：抽屉开→换档→关这种连点，第二下来的时候
    /// 上一程还在半路，从落点起弹簧会先瞬移回去再走，正是要消掉的那一跳。
    private func contentColumnPresentationX() -> CGFloat? {
        guard let layer = contentHost?.layer else { return nil }
        return layer.presentation()?.position.x ?? layer.position.x
    }

    /// 抽屉开合时整列（封面/元数据/时间行/传输行）横移到新半区的正中。
    ///
    /// 从前这一步就是 `layoutPieces()` 里那句 frame 赋值，落点直接换——1440 宽的窗口上
    /// 是 360pt 的瞬移，肉眼看就是封面在中间和左边之间闪一下。
    ///
    /// 只动 `position.x` 就够：列宽由 `byWidth = 整窗宽 × 0.28` 定（见 `ContentGeometry`），
    /// 抽屉开合不改整窗宽，所以 `column` 和 y 都不变，变的只有半区决定的 x。
    /// frame 仍然一步到位落在终值上（`-dumpviews` 量到的还是落点，同整块的推拉动画），
    /// 动的只是 presentation。
    ///
    /// 曲线沿用盘那条 `.spring(response: 0.34, dampingFraction: 0.86)`：列往左让位与盘
    /// 推上来是同一次交互的两半，两边不同速会散开。
    private func slideContentColumn(from fromX: CGFloat) {
        guard let layer = contentHost?.layer, fromX != layer.position.x else { return }
        let spring = Self.spring(keyPath: "position.x",
                                 response: Self.platterResponse,
                                 damping: Self.platterDamping)
        spring.fromValue = fromX
        spring.toValue = layer.position.x
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "amber.nowPlayingContentSlide")
    }

    /// [实测] §6.5 具名动画 `trackSectionsPlatter.expanded` / `.collapsed`：位移 + 淡入。
    /// 曲线沿用旧 SwiftUI 版那条 `.spring(response: 0.34, dampingFraction: 0.86)`，
    /// 按同一条定义式换算成 `CASpringAnimation`（见类头注释）。
    /// **只管玻璃盘，不碰 `drawer.view`。**
    ///
    /// 从前这里连抽屉一起藏，于是「待播清单 → 歌词」这一步把歌词也藏掉了：
    /// 换档时盘要收回去（`expanded == false`），而那时抽屉里装的已经是歌词面板，
    /// 收尾那句 `drawer.view.isHidden = !expanded` 正好把它按灭——症状是切回歌词
    /// 一片空白、手动开关一次（走 `fadeDrawer`）才回来。
    /// 队列档时抽屉在玻璃**里面**，藏玻璃已经连它一起藏了，本来就不需要这一句。
    private func animatePlatter(expanded: Bool, animated: Bool) {
        platterGlass.isHidden = false
        let target: CGFloat = expanded ? 1 : 0
        guard animated, let layer = platterGlass.layer else {
            platterGlass.alphaValue = target
            platterGlass.isHidden = !expanded
            platterIsExiting = false
            if !expanded { finishOutgoingPanel() }
            return
        }
        platterGlass.alphaValue = expanded ? 0 : 1

        // 位移：从盘高那么远的下方推上来 / 落回去。收起那一程靠 alpha 同步归零收尾，
        // 所以动画照常在结束时移除（`fillMode` 不留），不会有「落下去又弹回原位」那一帧。
        let spring = Self.spring(keyPath: "position.y",
                                 response: Self.platterResponse,
                                 damping: Self.platterDamping)
        let settled = layer.position.y
        let offset = platterGlass.frame.height
        spring.fromValue = expanded ? settled - offset : settled
        spring.toValue = expanded ? settled : settled - offset
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "amber.trackSectionsPlatter")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = spring.settlingDuration
            platterGlass.animator().alphaValue = target
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !expanded { self.platterIsExiting = false }
                let stillExpanded = self.isInspectorOpen && self.inspectorMode == .queue
                guard stillExpanded == expanded else { return }
                if !expanded {
                    // 盘带着走的那份队列面板，演到这里才撤。
                    self.finishOutgoingPanel()
                    if self.inspectorMode != .queue { self.platterGlass.removeFromSuperview() }
                }
                self.platterGlass.isHidden = !expanded
            }
        }
    }

    private func fadeDrawer(to alpha: CGFloat, animated: Bool) {
        drawer.view.isHidden = false
        guard animated else {
            drawer.view.alphaValue = alpha
            drawer.view.isHidden = alpha <= 0
            return
        }
        drawer.view.alphaValue = alpha > 0 ? 0 : 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            drawer.view.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.drawer.view.isHidden = self.drawer.view.alphaValue <= 0
            }
        }
    }

    /// [实测] §6.5 的盘动画曲线（旧 SwiftUI 版那条 spring，换骨架不改手感）。
    private static let platterResponse: Double = 0.34
    private static let platterDamping: Double = 0.86

    /// SwiftUI `spring(response:dampingFraction:)` 的定义式（质量取 1）：
    /// ω = 2π/response，stiffness = ω²，damping = 2ζω。两边同一条曲线。
    private static func spring(keyPath: String, response: Double,
                               damping: Double) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = 1
        let omega = 2 * Double.pi / response
        spring.stiffness = omega * omega
        spring.damping = 2 * damping * omega
        spring.initialVelocity = 0
        return spring
    }

    // MARK: - 动作与资源

    private func close() {
        appState.showingNowPlaying = false
    }

    private func reloadArtworkIfNeeded() {
        let track = player.currentTrack
        guard track?.id != loadedArtworkTrackID else { return }
        loadedArtworkTrackID = track?.id
        artworkTask?.cancel()

        guard let track else {
            // 只有真的没曲目时才清空；换歌时留着旧封面，等新的取回来再换。
            // 先清成 nil 的话背景场跟着变 nil，画面会闪一下空态灰再淡进新色。
            applyArtwork(nil)
            return
        }

        // [实测] 整窗播放器走 ITMPMetadataModel 那一档（800），是整套阶梯里最大的。
        artworkTask = Task { [weak self] in
            let loaded = await ImageCache.shared.image(
                for: ArtworkSize.url(track.artworkURL, points: ArtworkSize.fullPlayer))
            guard !Task.isCancelled, let self,
                  self.player.currentTrack?.id == track.id else { return }
            self.applyArtwork(loaded)
        }
    }

    private func applyArtwork(_ image: NSImage?) {
        artwork = image
        // [实测] §11.8.4：封面一落地就喂给背景（换图触发 0.5 秒交叉淡化，在视图内部）。
        var rect = NSRect(origin: .zero, size: image?.size ?? .zero)
        // 这一处给了建议尺寸，走不了 `amberCGImage` 那个外壳：`forProposedRect` 导进来是
        // `UnsafeMutablePointer<NSRect>?`。契约很短——指向上一行那个局部 `var`，
        // AppKit 只在这次调用里读写它，调用一返回就没人再拿着这个地址。
        let cgImage = unsafe image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        backdropArtwork = cgImage
        metalBackdrop?.cgImage = cgImage
        // 有封面时 Metal 那层自己铺满，空态底让位；没有（或还在取）就露出它。
        // 「减弱透明度」那一支盖的是整块，露不露空态底都看不见，无需另开一路。
        backdropIdle.isHidden = cgImage != nil
        pushContentInputsIfNeeded()
    }
}

/// 「正在播放」整窗播放器的 AppKit 容器。
///
/// 对应 Music 规格（nowplaying spec §2.4）的 `VibrantDragBlockingView` 阻断层：
/// 吸收未被内部视图消费的 `scrollWheel:` 事件，阻止滚轮/触控板双指滑动事件沿响应链冒泡至`NSWindow`，
/// 彻底避免背后的表格/内容页发生穿透滚动。
private final class NowPlayingContainerView: NSView {

    /// 收起期间「当它不存在」：不接命中测试、不进辅助功能树。
    /// **不动 `isHidden`**——那会连带把里面那棵 SwiftUI 的更新一起停掉，
    /// 理由见 `NowPlayingContainerViewController.hideAfterCollapse`。
    var isInert = false {
        didSet {
            guard isInert != oldValue else { return }
            setAccessibilityHidden(isInert)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInert ? nil : super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        // 吸收未被内部视图消费的滚轮与触控板滑动手势，拦截穿透。
    }
}
