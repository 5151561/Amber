import AppKit
import Combine
import SwiftUI

/// 检查器容器里**歌词那一档**的控制器（Music 的 `MusicInspectorContainer.lyrics` +32，
/// inspector spec §1.1）。
///
/// 从前这一格是三层：SwiftUI `InspectorLyricsView` → `SyncedLyricsView`
///（`NSViewControllerRepresentable`）→`SyncedLyricsViewController`。中间那层只做
/// 「把 AppKit 控制器包成 SwiftUI 视图」这一件事，正是 AGENTS.md 界面层铁律 1
/// 要拆掉的方向（计划 §1.3「`SyncedLyricsView` 那层`NSViewControllerRepresentable`
/// 删掉，改直接持有 VC」）。所以这里直接把 `SyncedLyricsViewController` 当子控制器持有，
/// 取词、空态、覆盖项、基线换算都落在本类上。
///
/// **一台容器只归一个宿主**，档位由 `init(appState:immersion:)` 定死：
///
/// | 档 | 宿主 | 字号 | 基线 | 左右内边距 |
/// | --- | --- | --- | --- | --- |
/// | 侧栏（`immersion = false`） | 主窗面板列 / 迷你窗抽屉 | `.sidebar`（24pt） | 视口高 × 0.381 | `Inspector.lyricsInset` |
/// | 沉浸（`immersion = true`） | 整窗播放器右半区抽屉 | 按面板宽落档 | 封面中心 | `NowPlaying.hostedContentInset` |
///
/// ### `isImmersionMode` 的出处（inspector spec §4 / §4.2）
///
/// §4：`MPContentView` 自己持有 `inspectorContainer`(+88) 与`inspector`(+96)，
/// **「窗口右侧栏」和「全屏播放器抽屉」是同一个容器类的两个实例**，全屏那份打开
/// `isImmersionMode`（+41）。§4.2：唯一写入点是
/// `MPContentView.inspectorIsImmersionMode:`（0x100f3cc18），didSet 把
/// `isImmersionMode` 与它的反面 `isMiniPlayerMode` 一起传给歌词控制器
///（`w.isMiniPlayerMode = !isImmersionMode`，0x10104d254 的`bic w2, #1, w8`）。
///
/// §4.2 还记了一条不对称：**那条传导只对旧壳 `TSLLyricsControllerWrapper` 生效**，
/// didSet 用 `swift_dynamicCastObjCClass` 判型，新实现`LyricsXViewController`
/// 判型失败直接 return——所以沉浸模式这条线在 Music 的新旧两套歌词实现之间是断的，
/// spec 标 `[部分]`。**Amber 只有一套歌词实现**（`SyncedLyricsViewController`），
/// 不存在这个判型分叉，一律走得通。
///
/// 反面那一位（`isMiniPlayerMode`）Amber 不另存：本类里凡是「非沉浸」的分支就是它，
/// 多存一份等于给同一个开关留两个真相。
@MainActor
final class InspectorLyricsViewController: NSViewController {

    // MARK: - 依赖

    private let appState: AppState
    private let player: PlayerController
    /// [实测] inspector spec §4.2，见类头。
    private let isImmersionMode: Bool

    // MARK: - 歌词本体（子控制器）

    private let lyricsController = SyncedLyricsViewController()
    private let visual = SyncedLyricsVisualExperienceManager()
    /// 点一行跳转。原样搬自 `SyncedLyricsView.Coordinator`——歌词面板自己不 seek，
    /// 只把行交给 delegate（lyrics spec §4.3）。
    private let tapRelay: TapRelay

    // MARK: - 数据

    /// 当前这份歌词。写它就会重走一遍下发（`syncController()`）。
    ///
    /// 不是 `private(set)`：`AmberTests/LyricsFontsTests.swift` 那条
    /// 「改 `AppSettings.shared` → 行视图上的发音字号跟着变」走的就是这台真实宿主，
    /// 得从这里灌一份词进来（`@testable`）。
    var lines: [LyricLine] = [] {
        didSet {
            guard lines != oldValue else { return }
            updateContent()
        }
    }
    private var isLoading = false
    /// 当前这份词是哪首歌的。**沉浸档的空态文案靠它分叉**（见 `updateContent()`）。
    private var loadedTrackID: String?
    private var loadToken: String?
    private var loadTask: Task<Void, Never>?

    // MARK: - 覆盖项与「已下发」的账

    /// 整窗播放器推进来的「封面中心距面板顶边多少」。nil = 用兜底比例。
    private var artworkCenterOffsetFromPanelTop: CGFloat?

    /// 上一次真的落到控制器上的那一组覆盖项。原版是
    /// `SyncedLyricsView.Coordinator.appliedOverrides`，逐条搬过来。
    private var appliedRect: CGRect?
    private var appliedSizeClass: MusicMetrics.Lyrics.SizeClass?
    private var appliedMargin: CGFloat?
    /// 上一次落到行视图上的「更大字体」档。它不是面板的覆盖项而是应用级偏好，单记一份。
    private var appliedLargerText = AppSettings.shared.values.largerText
    /// 上一次下发的渲染档。有戳 ⇄ 无戳来回换歌时靠它判断要不要重建行视图。
    private var appliedRenderingMode: LyricsSpecs.RenderingMode = .synced
    /// 行的身份：条数 + 首尾时间 + 首行文字。够区分换歌，又不必逐行比。
    private var appliedLyricsIdentity = 0

    private var showsTranslation = LyricsTranslationOptions.showTranslationDefault
    private var showsTransliteration = LyricsTranslationOptions.showTransliterationDefault

    /// 面板是不是**真的在跟随**（[TYPE] `LyricsOptions.isActive`）。
    ///
    /// 整窗播放器是**常驻 + 位移**的（收起时整块挪到窗外、alpha 0，见
    /// `NowPlayingHostController.hideAfterCollapse`），既不走`viewWillDisappear`
    /// 也不走 `viewDidHide()`——只认那两条通路的话，每帧驱动在看不见的时候照样跑。
    /// 所以整窗那台宿主收起时把这一位置 false。
    ///
    /// 侧栏那档**不接**：容器切到待播盘就把这一片从视图树里摘掉、面板列收起会走
    /// `viewDidHide()`，两条都已经停住了；再按`isPlaying` 关一道的话，
    /// 暂停时拖进度条就不会重新落行。
    var isActive = true {
        didSet {
            guard isActive != oldValue else { return }
            syncVisibility()
        }
    }

    // MARK: - 视图

    private let spinner = NSProgressIndicator()
    private lazy var loadingView: NSView = makeLoadingView()
    private lazy var emptyView: NSView = makeEmptyView()
    private let emptyLabel = NSTextField(labelWithString: "")
    /// [AX] 右下角那颗翻译浮动键。**只有侧栏档有**：整窗那颗是底栏按钮组的一员
    /// （`lyricsFooterButton` → `FooterLayoutGlassGroup`，见`LyricsTranslationButton.Placement`）。
    private var translationHost: NSHostingView<AnyView>?

    private var cancellables = Set<AnyCancellable>()
    private let observers = TaskBag()

    // MARK: - 生命周期

    init(appState: AppState, immersion: Bool) {
        self.appState = appState
        self.player = appState.player
        self.isImmersionMode = immersion
        self.tapRelay = TapRelay(player: appState.player)
        super.init(nibName: nil, bundle: nil)
        addChild(lyricsController)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { loadTask?.cancel() }

    override func loadView() {
        let root = PanelRootView()
        root.wantsLayer = true
        view = root
        root.onVisibilityChanged = { [weak self] in self?.syncVisibility() }

        wireLyricsController()
        installTranslationButtonIfNeeded()
        updateContent()
        bind()
        reload()
    }

    /// 把「控制器 + 视觉管理器 + 时间轴」三件套接起来。
    /// 原样搬自 `SyncedLyricsView.makeNSViewController`，一条不差。
    private func wireLyricsController() {
        let specs = makeSpecs()
        lyricsController.specs = specs
        lyricsController.margins = contentMargins
        lyricsController.delegate = tapRelay

        visual.specs = specs
        visual.viewController = lyricsController

        let timeline = SyncedLyricsManager(configuration: .init(specs: specs),
                                           maxSelectedLines: specs.maxSelectedLines)
        timeline.delegate = lyricsController
        // 每帧走查要比 `PlaybackClock` 的 10 Hz 细，直接问播放器。
        timeline.elapsedTimeProvider = { [weak player] in player?.elapsedTime ?? 0 }

        visual.manager = timeline
        lyricsController.manager = visual
        visual.timingProvider = player

        appliedMargin = contentMargins.left
        appliedSizeClass = currentSizeClass
        appliedRect = currentSelectedLineRect
        appliedRenderingMode = specs.renderingMode
        appliedLargerText = AppSettings.shared.values.largerText
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 面板几何一变就重算基线与字号档——这就是 [实测] nowplaying spec §8.1 那条
        // `offsetObservation → activeBaselineConstraint`（容器几何 → 歌词布局的传导）。
        syncController()
    }

    // MARK: - 沉浸档的基线入口

    /// 整窗播放器把「封面中心在歌词面板里、距面板**顶边**多少」推进来。
    ///
    /// nil = 锚点还没报上来，用兜底比例（`LyricsBaseline.selectedLineRect` 里的
    /// `panel.height × viewportAnchorRatio`）。**侧栏那档永远不调这一口**：
    /// 它走 `LyricsBaseline.sidebarSelectedLineRect`（[PX] lyrics spec §22.3
    /// 视口高 × 0.381）。
    ///
    /// 入参已经是滚动视图自己坐标系里的 y（原 SwiftUI 版在公共坐标系里算
    /// `targetY = artworkCenterY − panel.minY`，这一步现在归宿主），
    /// 所以这里把 `panel` 的原点摆在零点直接交给`LyricsBaseline`——
    /// 同一层换算只做一遍。
    func setArtworkCenter(offsetFromPanelTop: CGFloat?) {
        guard artworkCenterOffsetFromPanelTop != offsetFromPanelTop else { return }
        artworkCenterOffsetFromPanelTop = offsetFromPanelTop
        guard isViewLoaded else { return }
        syncController()
    }

    // MARK: - 两档的覆盖项

    /// 歌词栏的水平内边距。**必须落在滚动视图里面**（走
    /// `SyncedLyricsViewController.margins`），不能加在滚动视图外面：行贴着 clip view
    /// 左沿时，逐行模糊往左糊出去的那一圈会被 `NSClipView` 剪掉，未轮到的行左边缘
    /// 出现一条硬边。
    ///
    /// - 侧栏 19：[AX] `lyrics-panel.json`（1470×923）歌词组`[1212, 33, 258, 923]`、
    ///   里面的滚动区**同尺寸**、行`[1231, …, 220, …]`——19pt 落在滚动区里面。
    /// - 整窗 19：[AX] Music 的歌词滚动区 `[735, 121, 683, 771]`、行`[754, …, 645, …]`，
    ///   同样落在里面。
    private var contentMargins: NSEdgeInsets {
        let inset = isImmersionMode
            ? MusicMetrics.NowPlaying.hostedContentInset
            : MusicMetrics.Inspector.lyricsInset
        return NSEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
    }

    /// 字号档。
    ///
    /// - 侧栏恒 `.sidebar`：[资源] `TextStyles.plist` 10200（Timed Lyrics **Sidebar**）
    ///   = 24pt Bold（lyrics spec §20.2）；[PX] §22.2 侧栏 258 宽实测主行 23.9–25.0 → 24，
    ///   与 §24.3 断点表「`< 300` → 档 0 → 10200」对上。不传的话会落到基线 spec 的
    ///   Dynamic Type `.largeTitle`（macOS 约 26pt），与实测行盒 28 对不上。
    /// - 整窗按**面板宽度原值**落档：[实测] lyrics spec §24.3
    ///   `-[TSLLyricsControllerWrapper breakpointForWidth:]`
    ///   （`<300|!pretty→0`、`<528→1`、`<672→2`、`<760→3`、否则 4），
    ///   §8.2 实读它的入参是`viewIfLoaded._layoutFrame` 的**宽度原值**
    ///   ——边距已由 AutoLayout 折进 frame，**没有额外的边距运算**。
    ///
    ///   [AX] 2026-09-03 同窗口（1470×923）实测：Music 的歌词滚动区 683 宽、19pt 在它
    ///   **里面**；Amber 若传扣过边距的 645 等于扣了两次——683 落 50pt 档、645 落 38pt 档，
    ///   正好差一整档字号。所以这里传的是**加边距之前**的面板宽。
    private var currentSizeClass: MusicMetrics.Lyrics.SizeClass {
        guard isImmersionMode else { return .sidebar }
        return MusicMetrics.Lyrics.sizeClass(
            forWidth: min(view.bounds.width, MusicMetrics.Lyrics.maxWidth))
    }

    /// 当前行停在哪。两档两条路，见 `LyricsBaseline`。
    private var currentSelectedLineRect: CGRect? {
        let size = view.bounds.size
        guard isImmersionMode else {
            // [PX] lyrics spec §22.3：焦点组框中心 = 视口高 × 0.381
            //（视口高 771 → 293.8、548 → 207.8）。
            return LyricsBaseline.sidebarSelectedLineRect(panelHeight: size.height,
                                                          panelWidth: size.width)
        }
        return LyricsBaseline.selectedLineRect(
            artworkCenterY: artworkCenterOffsetFromPanelTop,
            panel: CGRect(origin: .zero, size: size))
    }

    /// 把覆盖项叠到基线 spec 上。原样搬自 `SyncedLyricsView.makeSpecs()`。
    private func makeSpecs() -> LyricsSpecs {
        var specs = LyricsSpecs()
        // 整份词没有时间轴（全是 `.plain` / `.credits`）时切到静态档：一次铺开、
        // 统一亮度、用户自己滚，不高亮不自动滚不点击跳转。判据在数据侧
        // （`[LyricLine].isUntimed`），渲染契约在 `LyricsSpecs.renderingMode`。
        specs.renderingMode = lines.isUntimed ? .static : .synced
        specs.showsTranslation = showsTranslation
        specs.showsTransliteration = showsTransliteration
        specs.largerSecondary = AppSettings.shared.values.largerText
        if let rect = currentSelectedLineRect {
            specs.selectedLinePosition = .center(rect: rect)
        }
        let sizeClass = currentSizeClass
        specs.font = .systemFont(ofSize: sizeClass.lineSize, weight: .bold)
        // 行距要跟着字号一起换：基线 spec 的 `lineSpacing = 25` 配的是 26pt 的
        // Dynamic Type，直接拿去配 38pt 会挤成 63pt 的顶距。
        // [PX] 整窗 38pt 档实测顶距 95 = 2.5 倍字号，`SizeClass.lineSpacing`
        // 就是按「顶距 − 行盒」反解出来的那个数。
        specs.lineSpacing = sizeClass.lineSpacing
        // 副行**按同一个倍率**跟着换档，不逐档写死（[资源] 10205–10208 = 13/17/20/24）。
        // 侧栏档不缩：那四档只覆盖整窗，侧栏（10200）没有对应的副行条目，
        // 而 `LyricsSpecs` 实测得到的那五个字体本来就是侧栏这一档——再乘一次
        // 等于把基线缩掉。同 `interludeScale` / `lineSpacing`。
        if sizeClass != .sidebar {
            specs.scaleSecondaryFonts(
                by: sizeClass.secondarySize / specs.transliterationFont.pointSize)
        }
        // 间奏的点跟着字号档放大，**行高不跟**：[AX] Music 50pt 档实测
        // 点 21 / 间距 13 / 行高 42，行高相对基线 40 几乎没动。
        let dots = sizeClass.interludeScale
        specs.instrumentalBreakDotLength = (specs.instrumentalBreakDotLength * dots).rounded()
        specs.instrumentalBreakDotMargin = (specs.instrumentalBreakDotMargin * dots).rounded()
        return specs
    }

    // MARK: - 下发

    /// 把当前状态落到 `SyncedLyricsViewController` 上。
    ///
    /// 逐条对应原 `SyncedLyricsView.updateNSViewController`：先补边距，再按
    /// 「字号档 / 基线 / 边距 / 渲染档」四项里有没有变决定重建 specs，最后按
    /// 「歌词身份变了 / 字号档变了 / 渲染档变了」决定重建行视图——**只挪了基线**
    /// 那一路不重建行，只重排 + 把当前行滑到新落点。
    private func syncController() {
        guard isViewLoaded else { return }
        lyricsController.setSecondaryLinesVisible(translation: showsTranslation,
                                                  transliteration: showsTransliteration)

        let margin = contentMargins.left
        let sizeClass = currentSizeClass
        let rect = currentSelectedLineRect
        let largerText = AppSettings.shared.values.largerText
        let renderingMode: LyricsSpecs.RenderingMode = lines.isUntimed ? .static : .synced
        let identity = Self.identity(of: lines)

        // 字号档换了要连带重建行视图：字体是在 `configure(line:specs:)` 里落到层上的，
        // 光改 specs 不会让已经建好的行改字号。跨档只发生在窗口拉过断点时，不是每帧。
        // 「更大字体」按同一条走：它把两条副行的档位对调，已经建好的行同样不会自己改。
        let fontsChanged = appliedSizeClass != sizeClass || appliedLargerText != largerText
        let rectChanged: Bool = {
            guard let r1 = appliedRect, let r2 = rect else {
                return (appliedRect == nil) != (rect == nil)
            }
            return abs(r1.minY - r2.minY) > 0.5 || abs(r1.height - r2.height) > 0.5
        }()
        let marginsChanged = appliedMargin != margin
        // 有戳 ⇄ 无戳换歌时渲染档也得跟着换。**必须并进重建行视图那条析取**：
        // 换歌本来就因 `identity` 变了而重建行，但 specs 还停在上一首的档上，
        // 静态档等于没开；而「诞生模糊 / 诞生即选中」恰恰是在建行那一步落下去的。
        let modeChanged = appliedRenderingMode != renderingMode

        if marginsChanged {
            lyricsController.margins = contentMargins
            lyricsController.relayoutEverything()
        }

        if fontsChanged || rectChanged || marginsChanged || modeChanged {
            let specs = makeSpecs()
            lyricsController.specs = specs
            lyricsController.manager?.specs = specs
            appliedMargin = margin
            appliedSizeClass = sizeClass
            appliedRect = rect
            appliedLargerText = largerText
            appliedRenderingMode = renderingMode
            // 每帧驱动的开关也读 `renderingMode`（静态档不起链），而它只在
            // `isVisible` / `isActive` 变化时才被推一次——换档这条路没人推，
            // 这里显式补一次。两个方向都要：切进静态档要停链，切回来要重开。
            lyricsController.updateDisplayLink()
        }

        // 只在真的换了歌词时重建行视图——每次布局都重排的话，
        // 一首歌几十个 `NSView` 加一堆`CATextLayer` 会被反复拆建。
        if appliedLyricsIdentity != identity || fontsChanged || modeChanged {
            appliedLyricsIdentity = identity
            // `handover` 决定间奏行两头留多宽的进出场余量（见 `LyricsAdapter`），
            // 取的就是这份 specs 的翻行弹簧——和滚动真正跑的那条同源。
            lyricsController.setLyrics(
                LyricsAdapter.makeLyrics(from: lines,
                                         handover: lyricsController.specs.scrollLead))
        } else if rectChanged {
            // 只挪了基线：重算几何落位并把当前行滑到新位置——
            // 这就是 [实测] nowplaying spec §8.1 那条
            // `offsetObservation → activeBaselineConstraint`。
            lyricsController.relayoutEverything()
            lyricsController.reanchorSelectedLine()
        }
    }

    /// 行的身份。副行显隐**不**并进来：那条路不改数据，只改 spec 再重排
    ///（见 `setSecondaryLinesVisible`）。
    private static func identity(of lyrics: [LyricLine]) -> Int {
        var hasher = Hasher()
        hasher.combine(lyrics.count)
        hasher.combine(lyrics.first?.time ?? 0)
        hasher.combine(lyrics.last?.end ?? 0)
        hasher.combine(lyrics.first?.text ?? "")
        return hasher.finalize()
    }

    // MARK: - 三种空态

    private enum Content { case lyrics, loading, empty }

    /// 判序把「有词」提到最前：产线上 `lines` 非空必然已经取完词
    ///（`load` 是先清空再置`isLoading`），所以与原来
    /// 「loading → 没歌 → 没词 → 有词」那串等价；提前只是让「直接灌一份词进来」
    /// 也能显示（单测走这条）。
    private var content: Content {
        if !lines.isEmpty { return .lyrics }
        if isLoading { return .loading }
        return .empty
    }

    private func updateContent() {
        guard isViewLoaded else { return }
        switch content {
        case .lyrics:
            spinner.stopAnimation(nil)
            install(lyricsController.view)
        case .loading:
            install(loadingView)
            spinner.startAnimation(nil)
        case .empty:
            spinner.stopAnimation(nil)
            emptyLabel.stringValue = emptyMessage
            install(emptyView)
        }
        updateTranslationButton()
        syncVisibility()
        if content == .lyrics { syncController() }
    }

    /// 两句空态**不是一回事**：没歌在播是「去播一首」，在播却没有词是「这首就是没有词」。
    /// 纯音乐归成空态之后后一句才常见起来（见 `LyricsStore.isInstrumentalPlaceholder`），
    /// 拿前一句糊过去会变成「明明在播还叫我去播」。
    ///
    /// 两档的文案各自保留现状，不互相串：侧栏是从前 `InspectorLyricsView` 那两句、
    /// 整窗是从前 `FullWindowHostedContentView` 那两句。
    private var emptyMessage: String {
        if isImmersionMode {
            return loadedTrackID == nil ? "播放歌曲并在此处查看歌词。" : "这首歌曲暂时没有歌词"
        }
        return player.currentTrack == nil ? "播放歌曲以查看歌词" : "这首歌曲暂时没有歌词"
    }

    /// 装一块内容。永远 `positioned: .below`——右下那颗翻译浮动键是根视图的直接子件，
    /// 内容只能摆在它底下（[AX] Music 那颗也是窗口的直接子件，不在歌词组里、不跟着滚）。
    private func install(_ panel: NSView) {
        guard panel.superview !== view else { return }
        for sub in view.subviews where sub !== translationHost && sub !== panel {
            sub.removeFromSuperview()
        }
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func makeLoadingView() -> NSView {
        let container = NSView()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    /// 空态。侧栏是「图标 + 一行小字」，整窗只有一行字（两档从前就是两个样子）。
    private func makeEmptyView() -> NSView {
        let container = NSView()
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        if isImmersionMode {
            emptyLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            emptyLabel.textColor = .white.withAlphaComponent(
                MusicMetrics.NowPlaying.subtitleOpacity)
            container.addSubview(emptyLabel)
            NSLayoutConstraint.activate([
                emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
                emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            ])
            return container
        }

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "quote.bubble", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .light))
        icon.contentTintColor = .tertiaryLabelColor
        let stack = NSStackView(views: [icon, emptyLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor,
                                           constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                            constant: -24),
        ])
        return container
    }

    // MARK: - 右下角那颗翻译浮动键（侧栏档）

    /// [AX] `lyrics-panel.json`：`AXButton 翻译 [1421, 915, 34, 26]`——它是**窗口的
    /// 直接子件、不在歌词组里**，所以浮在歌词之上而不是跟着滚；距面板右沿与窗底各 15。
    private func installTranslationButtonIfNeeded() {
        guard !isImmersionMode else { return }
        let host = appState.hostingView { self.translationButton }
        view.addSubview(host)
        let size = MusicMetrics.Lyrics.TranslationButton.size
        let inset = MusicMetrics.Lyrics.TranslationButton.inset
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: size.width),
            host.heightAnchor.constraint(equalToConstant: size.height),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -inset),
        ])
        translationHost = host
    }

    private var translationButton: some View {
        LyricsTranslationButton(hasTranslation: lines.hasTranslation,
                                hasTransliteration: lines.hasTransliteration)
    }

    private func updateTranslationButton() {
        guard let translationHost else { return }
        // 从前它挂在「有词」那一支的 overlay 上，没有词时整颗不在树里。
        translationHost.isHidden = lines.isEmpty
        translationHost.rootView = appState.hostingRoot { self.translationButton }
    }

    // MARK: - 看得见 / 在跟随

    /// 把「看得见没有」与「在不在跟随」一起推给歌词控制器。
    ///
    /// 三条通路各补各的洞：
    ///
    /// - `viewWillAppear` / `viewWillDisappear`（`SyncedLyricsViewController` 自带）：
    ///   **迷你播放器窗没有 `contentViewController`**（`window.contentView = contents`），
    ///   那扇窗里的子控制器收不到这条链——`PlayQueueViewController.panelDidBecomeHidden`
    ///   的注释记的就是这件事。所以不能只靠它。
    /// - `viewDidHide()`（本类根视图）：两个宿主收面板都是把某一层`isHidden = true`
    ///   （主窗收 `NSSplitViewItem` 的分栏列，迷你窗抽屉高度归零时收容器），
    ///   `viewDidHide()` 沿视图树往下发，一处覆盖两条路。
    /// - `isActive`（宿主推）：整窗播放器收起时只是位移到窗外 + alpha 0，
    ///   上面两条都不触发，见 `isActive` 的注释。
    private func syncVisibility() {
        guard isViewLoaded else { return }
        // `viewIfLoaded` 而不是 `view`：空态期间歌词控制器的视图还没建，
        // 读 `view` 会把它顺手建出来。
        let onScreen = view.window != nil
            && !view.isHiddenOrHasHiddenAncestor
            && lyricsController.viewIfLoaded?.superview != nil
        if onScreen {
            // `tearDown()` 会把块式滚动观察者摘掉，再次上台得装回来（幂等）。
            lyricsController.installScrollObserversIfNeeded()
            lyricsController.isVisible = true
            lyricsController.isActive = isActive
            lyricsController.updateDisplayLink()
        } else {
            lyricsController.isVisible = false
            lyricsController.isActive = isActive
            lyricsController.updateDisplayLink()
            // `view.displayLink(target:selector:)` 强引用控制器，光把 `isVisible`
            // 翻 false 不够——照 `SyncedLyricsView.dismantleNSViewController` 那一口收干净。
            lyricsController.tearDown()
        }
    }

    // MARK: - 订阅

    private func bind() {
        // 换歌：`currentIndex` 与`queue` 分别发一次，中间那一拍两者还不同步，
        // 同一跳之后直接读 `currentTrack` 才是两者都落定的值（同 `MiniPlayerView.bind`）。
        player.$currentIndex.map { _ in () }
            .merge(with: player.$queue.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.reload() }
            .store(in: &cancellables)

        // 在「显示简介 › 歌词」里改完自定义歌词要立刻反映到面板上。
        // 键是 `LyricsStore.displayToken(for:trackInfo:)`——换歌要重取，改完自定义词也要重取。
        observers.observe({ TrackInfoStore.shared.infos }) { [weak self] _ in self?.reload() }

        // 设置 › 通用 ›「更大字体」。从前是 `SyncedLyricsView` 上的`@ObservedObject`，
        // 骨架换成 AppKit 之后落在这条唯一的读取点上。
        observers.observe({ AppSettings.shared.values.largerText }) { [weak self] _ in
            self?.syncController()
        }

        // 翻译 / 发音两条副行的显隐。从前是两个 `@AppStorage`；AppKit 这边直接听
        // `UserDefaults` 的变更通知再读那两个键（`LyricsTranslationOptions`），
        // 写入点仍是那颗翻译键上的 `@AppStorage`。
        readTranslationOptions()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.readTranslationOptions() else { return }
                self.syncController()
            }
            .store(in: &cancellables)
    }

    /// 读回两个开关，返回「变了没有」。
    @discardableResult
    private func readTranslationOptions() -> Bool {
        let defaults = UserDefaults.standard
        let translation = defaults.object(forKey: LyricsTranslationOptions.showTranslationKey)
            as? Bool ?? LyricsTranslationOptions.showTranslationDefault
        let transliteration = defaults.object(forKey: LyricsTranslationOptions.showTransliterationKey)
            as? Bool ?? LyricsTranslationOptions.showTransliterationDefault
        guard translation != showsTranslation || transliteration != showsTransliteration else {
            return false
        }
        showsTranslation = translation
        showsTransliteration = transliteration
        return true
    }

    // MARK: - 取词

    /// 取词统一走 `LyricsStore` 的**显示口**：勾了「自定义歌词」就用用户那份，
    /// 否则是音源那份；同一首在侧栏与整窗之间来回切只打一次网络，
    /// 命中缓存时同步就能拿到，连转圈那一帧都省了。
    ///
    /// 竞态防护照现有写法：换歌时取消上一份 `Task`，取消后回来的结果不写进去。
    private func reload() {
        let track = player.currentTrack
        let token = LyricsStore.displayToken(for: track, trackInfo: TrackInfoStore.shared)
        guard token != loadToken else { return }
        loadToken = token
        loadTask?.cancel()

        guard let track else {
            loadTask = nil
            isLoading = false
            loadedTrackID = nil
            lines = []
            updateContent()
            return
        }
        if let cached = appState.lyricsStore.cachedDisplayLyrics(for: track) {
            loadTask = nil
            isLoading = false
            loadedTrackID = track.id
            lines = cached
            updateContent()
            return
        }
        loadedTrackID = nil
        lines = []
        isLoading = true
        updateContent()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let loaded = await self.appState.lyricsStore.displayLyrics(
                for: track, using: self.appState.provider(track.kind))
            guard !Task.isCancelled else { return }
            self.isLoading = false
            self.loadedTrackID = track.id
            self.lines = loaded
            self.updateContent()
        }
    }
}

// MARK: - 点一行跳转

/// 歌词面板**自己不 seek**（只把行交给 delegate，lyrics spec §4.3），
/// 由这一位转给 `PlayerController`。原样搬自`SyncedLyricsView.Coordinator`。
private final class TapRelay: SyncedLyricsViewControllerDelegate {
    private let player: PlayerController
    init(player: PlayerController) { self.player = player }

    func syncedLyricsViewController(_ controller: SyncedLyricsViewController,
                                    didTap line: (any LyricsLine)?) {
        // 词曲作者那一行的时间是 ∞，点不动。
        guard let line, line.startTime.isFinite else { return }
        player.seek(to: line.startTime)
    }
}

// MARK: - 根视图

/// 面板根视图：被宿主收起（`isHidden`）或移出窗口时喊一声。
/// 与 `PlayQueuePanelRootView` 同一招，理由见`InspectorLyricsViewController.syncVisibility()`。
private final class PanelRootView: NSView {

    var onVisibilityChanged: (() -> Void)?

    override func viewDidHide() {
        super.viewDidHide()
        onVisibilityChanged?()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        onVisibilityChanged?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onVisibilityChanged?()
    }
}
