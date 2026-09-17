import AppKit
import Combine
import SwiftUI

/// 独立迷你播放器窗的内容视图，对应 Music 的 **`MPContentView`**。
///
/// 规格来源：miniplayer 规格 §0/§2/§3、
/// `inspector 规格` §4.3（十态真值表 + 三张跳表）/ §4.4（状态落地的动画块）、
/// `nowplaying 规格` §2.2（抽屉高度 200 的来源）；
/// 版式来自 **2026-09-08 的 Music 录屏**（2x 抓帧，度量见 `MusicMetrics.MiniPlayerWindow`）。
///
/// **它只是内容视图**：窗口壳、工具条、菜单、窗口 frame 的每一次改动都归
/// `MiniPlayerWindowController`。本类对外只暴露形态（`currState`）、四个派生谓词、
/// 两个 vtable 槽的等价物，以及窗口控制器算尺寸要用的 `layoutFrame` / 两条宽度约束。
///
/// **形态（`currState`）**：Music 是 0–9 十态，三组 × 三列（inspector spec §4.3）：
///
/// | 组 | 空 | 歌词 | 队列 |
/// | --- | --- | --- | --- |
/// | I 迷你横条 | 0 | 1 | 2 |
/// | II 窗口化 | 3 | 5 | 4 |
/// | III 全窗口 | 6 | 8 | 7 |
///
/// Amber 可达的只有 0…5：组 III 整条被 `integrate_mini_player_with_immersion` 门控，
/// 该 flag 关时 `loadWindow` 装`limitWidthToMaximum(600)` 把宽度夹住，宽度就再也过不了
/// 600 那条分界线（miniplayer spec §3.3）；9 是分离窗口，不属于本窗。
/// 跳表与谓词全部搬进文件末尾的 `MiniPlayerStates`，是纯函数，方便单测。
///
/// **版式骨架**（[PX] 录屏实测，见 `MusicMetrics.MiniPlayerWindow` 的类型注释）：
///
/// ```
/// ┌──────────────────── w ────────────────────┐
/// │  封面：方形，边长 = 窗宽，铺满顶块          │ ← 顶块 = w × w，画到窗口最顶
/// │  （工具条与红绿灯压在封面上，是窗口 chrome）│
/// │                                           │
/// │  以下全部浮在封面上：                       │
/// │   · 标题 / 艺人（左下）、☆ 与 ⋯（右）      │   靠封面下部的纱罩读得出来
/// │   · 进度条 + 已播 / 音质徽标 / 剩余         │
/// │   · 传输键 ⤨ ◀◀ ⏸ ▶▶ ↻                    │
/// ├───────────────────────────────────────────┤ ← 封面下沿 = 窗宽 w
/// │  抽屉：歌词 / 待播清单                      │ ← 高 = h − w
/// └───────────────────────────────────────────┘
/// ```
///
/// 这条结构同时解释了规格 §3.2 的高度阶梯：`h > 宽度 + 200` 才开抽屉，正是「方形封面块
/// w×w 之外还要再有至少一份 `drawerMinHeight = 200` 的抽屉」。
///
/// **收起态（组 I = 态 0/1/2）是同一套浮层减掉封面**（[PX] `music_collapsed.png` 实拍）：
///
/// ```
/// ┌────────────────────────────────────────┐
/// │ ●●●            (⋯)     [ 💬  ☰  🔊 ] │ ← 全是窗口 chrome（红绿灯 + NSToolbar）
/// │  ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬  │ ← 进度条，距窗底 73
/// │  0:33            〰 无损        −4:35  │ ← 时间行，距窗底 54
/// │  ⤨      ◀◀     ▶     ▶▶       ↻     │ ← 传输键，距窗底 31
/// └────────────────────────────────────────┘
/// ```
///
/// **没有封面、没有标题/艺人、没有 ☆**——就是一块半透明玻璃（`backdrop`）加三行控件。
/// 那一帧拍到的是**指针在窗内**（rollover 露着）的样子。收起态还有另一副面孔：
/// [实测] §11.3 的 `artwork.isHidden = !( !big && !rolloverShouldBeVisible && hasContentToShow )`
/// ——指针离开、控件层淡掉之后，露出来的是 **42pt 小封面 + 紧挨着它的标题/艺人**
/// （`artworkSize` 42、`artworkMargin` 16、标题盘`touchLeadingAgainst(artwork)`、右边距 18）。
/// 两副面孔在同一块地上（小封面距内容顶 ≥16，与工具条那 52pt 重叠），所以**工具条与红绿灯
/// 必须跟着 rollover 一起淡**——这一条 spec 没记，是上面那条几何逼出来的（[推]，落在
/// `MiniPlayerWindowController.setChromeVisible`）。静息层本身是`MPMiniBarView`。
/// 这正好坐实了 [实测] `applyLargeArtworkProgress` 的字面语义`alpha = progress`：
/// `h < 200` 时`progress = 0` → 封面 alpha 0 → 整块封面根本不出现，露出的就是那块玻璃。
/// 横向度量与展开态**一模一样**（内缩 16 / 随机键 34 / 中间三颗间距 58），只有纵向偏移
/// 换成 `collapsed*FromBottom` 那一组。判据用`MiniPlayerStates.isWindowed(currState)`
/// 而不是看窗高——状态机已经把高度换算成态了。
///
/// **浮层整层可以淡出（rollover，nowplaying spec §2.3）**：窗口安定、指针离开之后，
/// 窗口化那几档的标题/☆/⋯/进度/时间/传输键这一整层一起淡掉，只剩一张 edge-to-edge 的封面
/// （迷你横条那几档控件是常驻的，只换顶上那一行）。所以它们全部挂在 `overlay` 这**一个**
/// 容器里，改的是容器的 `alphaValue`。
///
/// **背景是三层，各管各的**（[实测] miniplayer spec §11.8）：
///
/// 1. 窗口底衬 `backdrop`——四边贴满、恒在，**两支**：缺省的 0 是
///    `NSVisualEffectView(.popover / .behindWindow / .active)`（糊窗后的桌面），
///    1 是 `MiniPlayerBackdropMetalView`（跟着封面走的 Metal 动态背景，纱罩`0.7 − 0.4p`、
///    律动 `10.5 − 9p`，`p = clamp((内容宽 − 400)/400, 0, 1)`）。切换靠调试开关
///    `miniplayer_backdrop`（KVO 热生效），全窗口组 III 则强制 1 不看偏好；
/// 2. 控件底下那条 `artworkBlur`——**封面自己的模糊副本**（见`MPArtworkBlurView`），
///    不是黑渐变、也不是窗后的桌面，只在窗口化组 II 出现；
/// 3. 控件自己的 `.vibrantDark` 外观（`updateOverlayAppearance`）。
@MainActor
final class MiniPlayerContentView: NSView {

    private typealias M = MusicMetrics.MiniPlayerWindow

    // MARK: - 对外契约

    /// 当前形态。**只能经 `apply(state:animated:)` 写**——inspector spec §4.4 里
    /// 状态是在动画块内部才落地的，绕过去写就把「先显示后动画」的顺序拆了。
    private(set) var currState: Int = 0

    /// 形态变了通知窗口控制器（刷工具条项、重算菜单标题）。
    var onStateChanged: (() -> Void)?

    /// rollover 变了通知窗口控制器：窗口 chrome（红绿灯 + 工具条）跟着这一层一起淡。
    /// 见类型注释里那条几何论证。
    var onRollStateChanged: ((Bool) -> Void)?

    /// spec §3.2 的 vtable 槽：起始态 ∈ {1,2} 那支高度判定要用的「迷你横条面板态」。
    /// 判据与 Music 同源——`inspectorContainer.mode == 0`（歌词）→ 1，否则（队列）→ 2。
    var miniBarPanelState: Int { panelMode == .lyrics ? 1 : 2 }

    /// spec §3.2 的 vtable 槽：窗口化那支的面板态。同一条判据，歌词 → 5、队列 → 4。
    var windowedPanelState: Int { panelMode == .lyrics ? 5 : 4 }

    /// = `(290 >> state) & 1` → {1,5,8}
    var isLyricsOpen: Bool { MiniPlayerStates.isLyricsOpen(currState) }

    /// = `(148 >> state) & 1` → {2,4,7}
    var isQueueOpen: Bool { MiniPlayerStates.isQueueOpen(currState) }

    /// = `state ∈ {3…8}`——组 II 起才有那颗 ellipsis 动作键。
    var showActionToolbar: Bool { MiniPlayerStates.isWindowed(currState) }

    /// 工具条 `volume` 项的字形（spec §5：图像绑在`contents.volumeImage` 上）。
    ///
    /// 这里是**算出来的**，没有存储；音量变了要刷工具条，窗口控制器自己订
    /// `player.$volume` 再回来读这一条——`onStateChanged` 只报形态，不报音量。
    var volumeImage: NSImage? {
        NSImage(systemSymbolName: VolumeGlyph.symbol(for: player.volume),
                accessibilityDescription: "音量")
    }

    /// 抽屉高度。收起前把当前帧高记下来（下限 `drawerMinHeight`），下次展开用它还原
    /// （nowplaying spec §2.2：`setDrawerHeight:` 的常量 200 是下限，
    /// 运行时的值来自 `inspector.frame.height`）。
    /// [实测] §11.1：**初值是 600**，不是下限那个 200。
    var drawerHeight: CGFloat = MusicMetrics.MiniPlayerWindow.drawerInitialHeight {
        didSet {
            let clamped = max(drawerHeight, M.drawerMinHeight)
            if clamped != drawerHeight { drawerHeight = clamped; return }
            if drawerHeight != oldValue { needsLayout = true }
        }
    }

    // MARK: - 内部状态

    /// 大封面的淡入进度 `progress`（[实测] §3.2 / §11.5）。0 = 迷你横条、1 = 窗口化；
    /// 200→250 那 50pt 的过渡带里取中间值。
    ///
    /// Music 拿它插值的是四条 platter 间距（`compactMetrics (18,14,0,16)` ⇄
    /// `largeArtMetrics (16,18,16,18)`）与大小封面的交叉淡化；Amber 是手排 frame，插的是
    /// 那四条间距的**落点**——浮层三条纵向偏移（见 `MiniPlayerStates.overlayOffsets`）。
    private var morphProgress: CGFloat = 0

    private let appState: AppState
    private var player: PlayerController { appState.player }
    private var library: LibraryStore { appState.library }
    private var cancellables = Set<AnyCancellable>()
    private var track: Track?

    /// 抽屉这一槽当前该摆歌词还是待播清单。
    ///
    /// **档位是全局一份**（`AppState.inspectorMode`，永不为 nil），本窗不再各存一份镜像：
    /// 从前这里是本类的存储属性、且**故意不回写**全局那一位（回写会把主窗的面板列一起
    /// 掀开），于是主窗胶囊上那两颗键的高亮与本窗抽屉的档位长期对不上
    ///（design-ref/reactive-ui-review.md §2.1「多份真相」）。
    /// 两位拆开之后回写是安全的：「开着没有」各宿主自持——本窗是 `currState`
    ///（{1,5,8} 歌词 / {2,4,7} 队列 / {0,3,6} 收着），主窗是 `AppState.isInspectorOpen`。
    ///
    /// 抽屉收着时读到的就是「上次那一档」，`miniBarPanelState` / `windowedPanelState`
    /// 要的正是它。
    private var panelMode: PlayerInspector { appState.inspectorMode }

    /// 抽屉里那台检查器容器（Music 的 `MPContentView.inspectorContainer` +88，
    /// **与主窗那条列是同一个类** `MusicInspectorContainer`——inspector spec §4 抬头
    /// 「窗口右侧栏和全屏播放器抽屉是同一个容器类的两个实例」）。
    ///
    /// - **一扇窗一台**：`mode` 是容器实例自己的字段（§1.1 的 +16），所以这里新建，
    ///   不跟主窗那台共用。代价是 `PlayQueueViewController` / `PlayQueueModel` 各一份；
    ///   模型只订阅 player 与设置、不写状态，两份互不干扰。
    /// - **`includeBackdrop = false`**：§1.2 的毛玻璃分支两处已知创建点都传 0
    ///   （主窗 §1.2、全屏播放器 §4.1），全屏那层玻璃另来自外面套的
    ///   `AMPVibrantContainerView`。迷你窗这一路同理——抽屉的底衬由本窗自己那套
    ///   （`MiniPlayerBackdrop` / 纱罩）给，容器保持素面。所以不需要给容器开参数。
    private let inspectorController: InspectorContainerViewController

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: rollover（nowplaying spec §2.3）

    /// `rollState` 的等价物：浮层这一整层现在露不露。
    private var rollState = true
    /// `mouseInterestTimer`：到点把浮层淡掉。两档间隔来自 [实测] §11.1 的字段表——
    /// 指针在窗内不动 `kMouseInterestTimeoutInSeconds` = 3.75，
    /// 指针离开窗口 `kMouseInterestExitingWindowTimeoutInSeconds` = 0.3。
    private var mouseInterestTimer: Timer?
    /// `mouseStartingInterestTimer`：起步计时，压住「指针擦过窗口」的抖动。
    /// 间隔取 `kDelayBeforeStartingRolloverMin` = 0.1（区间上限 0.3 怎么用规格没读出来）。
    private var mouseStartingInterestTimer: Timer?
    private var pointerInside = false
    private var rolloverTrackingArea: NSTrackingArea?
    /// `viewDidMoveToWindow` 挂的`windowFocusObserver`（spec §2.3 的 +384）。
    /// 另一支 `accessibilityFocusObserver`（+392）没做：AX 焦点没有公开通知。
    private var focusObservers: [NSObjectProtocol] = []

    /// 淡出之后得有东西露出来才值得淡：组 II 起露的是大封面；组 I 露的是静息层
    /// （42pt 小封面 + 标题），所以要有曲目。没曲目的组 I 淡掉只剩一块空玻璃，不淡。
    /// [实测] §11.3：`big && hasContentToShow && !isFullWindow(state)`。
    private var artworkBlurApplies: Bool {
        MiniPlayerStates.isWindowed(currState) && !MiniPlayerStates.isFullWindow(currState)
    }

    private var rolloverApplies: Bool {
        MiniPlayerStates.isWindowed(currState) || track != nil
    }

    // MARK: - 视图

    /// 最底下那层底衬（[实测] `backdrop` +56，miniplayer spec §11.8.1）。
    ///
    /// 工厂只判 `style == 1`，**取值域就此关死**：
    /// 0（缺省）= `NSVisualEffectView(.popover / .behindWindow / .active)`，糊的是**窗后的桌面**；
    /// 1 = `MiniPlayerBackdropMetalView`（对应`TSLBackdropMetalView`，跟着封面走的动态背景）。
    /// 由 `NSUserDefaults(Music).miniplayer_backdrop` 这条调试开关切，没设过就是 0；
    /// 全窗口组 III 不看偏好、强制 1。
    ///
    /// 换样式是**整只替换**（[实测]），所以这里是 `var`：
    /// 旧的 `removeFromSuperview()` → 新建 → 压到最底层 → 把当前封面重喂一遍 →
    /// 按当前宽度重算纱罩/律动。
    private var backdrop: NSView = MiniPlayerContentView.makeBackdrop(style: 0)

    /// [实测] `MPContentView.backdropStyle`（+64）。靠它去重：一样就不重建。
    private var backdropStyle = 0

    /// [实测] `debugBgObserver`（+72）：`miniplayer_backdrop` 上的 KVO，**热生效**。
    private var backdropPreferenceObserver: NSKeyValueObservation?

    /// 当前封面的 CGImage。重建底衬之后要把它重喂一遍（[实测] 尾段
    /// `largeArtwork.onAssignBlock?(artwork.currentImage)`）。
    private var currentArtwork: CGImage?

    /// 封面：方形顶块，`resizeAspectFill`，**画到窗口最顶**（工具条压在它上面）。
    /// `applyLargeArtworkProgress` 写的就是这一层的`alphaValue`。
    private let cover = MPCoverView()

    /// 迷你横条的**静息层**：42pt 小封面 + 紧挨着它的标题/艺人（[实测] §11.1/§11.3）。
    /// 与 `overlay` 互补——控件层淡出它才淡入，所以两层永远只见一层。
    private let miniBar = MPMiniBarView()

    /// 浮层容器，与封面同一个矩形（顶块）。里面所有件都以顶块**下沿**为基准排。
    private let overlay = MPFlippedView()
    /// 控件区底下那层**封面自己的模糊副本**（[实测] `artworkBlur` +80，spec §11.8.5）。
    /// 它画的就是封面底片那一条，所以挂成封面的子视图；淡入淡出跟着控件层一起排
    /// （见 `syncRolloverLayers`）。
    private let artworkBlur = MPArtworkBlurView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let favoriteButton = MPCircleButton()
    private let moreButton = MPCircleButton()
    private let progressBar = MPProgressBar()
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let remainingLabel = NSTextField(labelWithString: "")
    private let badgeView = MPBadgeView()
    private let shuffleButton = MPIconButton()
    private let previousButton = MPIconButton()
    private let playButton = MPIconButton()
    private let nextButton = MPIconButton()
    private let repeatButton = MPIconButton()

    /// 抽屉那一槽。普通 `NSView` 容器，里面**只挂一个**东西——
    /// `inspectorController.view`，槽的 frame 由本类`layout()` 手排。
    /// 对得上 Music 的是 `MPContentView.inspector`（+96，那边是
    /// `AMPVibrantContainerView`；Amber 的底衬另有来源，所以这里是素面翻转容器）。
    private let inspectorContainer = MPFlippedView()

    private var transportButtons: [MPIconButton] {
        [shuffleButton, previousButton, playButton, nextButton, repeatButton]
    }

    /// 只有展开态（组 II 起、且顶块排得下）才出现的那几件。
    /// 收起态实拍里**没有**标题/艺人/☆/⋯，三行控件下面直接就是窗底。
    ///
    /// 时间行不在这张表里：收起态实拍里「0:33 … −4:35」是在的。徽标也不在——
    /// 它还多两条闸（有没有无损档、中间那一格挤不挤得下），见 `layoutOverlay`。
    private var fullOnlyViews: [NSView] {
        [titleField, subtitleField, favoriteButton, moreButton]
    }

    // MARK: - 生命周期

    init(appState: AppState) {
        self.appState = appState
        self.inspectorController = InspectorContainerViewController(appState: appState)
        super.init(frame: NSRect(origin: .zero, size: M.initialContentSize))
        buildViews()
        bind()
        updateTrack(player.currentTrack, force: true)
        updatePlayButton()
        updateShuffle()
        updateRepeat()
        updateTime(player.currentTime)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 顶块 / 抽屉是从上往下排的，翻转坐标系读起来才和上面那张骨架图一致。
    override var isFlipped: Bool { true }

    /// 宽度不报（由窗口/约束说了算），高度报当前形态的自然高——绿灯
    /// （`windowWillUseStandardFrame:`）与`layoutFrame(width:height:)` 都要它。
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: naturalHeight(forWidth: bounds.width))
    }

    // MARK: - 搭视图

    private func buildViews() {
        // [实测] §11.8.1：`init` 里第一只 backdrop 就是`(0, readFromPrefs: true)`
        // ——读一次偏好。紧接着挂 KVO（`debugBgObserver` +72），此后这条偏好热生效。
        addSubview(backdrop)
        updateBackdropStyle(for: currState)
        backdropPreferenceObserver = UserDefaults.standard.observe(
            \.miniplayer_backdrop, options: [.new]
        ) { [weak self] _, _ in
            // KVO 回调在改偏好的那条线程上发，先回主线程再动视图树。
            Task { @MainActor in
                guard let self else { return }
                self.updateBackdropStyle(for: self.currState)
            }
        }

        addSubview(cover)
        addSubview(miniBar)

        // [实测] §11.8.5：模糊衬底是**大封面的子视图**（`largeArtwork.addSubview(artworkBlur)`），
        // 左右跟内容视图、底边贴封面底。
        cover.addSubview(artworkBlur)
        // [实测] §11.8.4 `largeArtwork.onAssignBlock`：**同一个块喂两处**——模糊衬底 ②，
        // 以及底衬 ① 里 `as?` 成功的那一支（毛玻璃拿不到封面，永远只糊窗后的桌面）。
        cover.onAssign = { [weak self] image in self?.assignArtwork(image) }

        // 浮层：前景一律 `labelColor`，颜色由**外观**决定而不是写死白色（[实测] §11.6）。
        // 组 II/III 且有内容时三个盘强制 `.vibrantDark` → `labelColor` 解析成白，
        // 与 [PX] 量到的墨迹峰值 246…255 一致；组 I（迷你横条）那边 `appearance = nil`
        // ——跟随系统外观，浅色下就是深色字压在玻璃上。写死白色的旧实现在浅色系统下
        // 收起态是白字压浅玻璃，读不出来。外观由 `updateOverlayAppearance(for:)` 跟着形态切。
        titleField.font = .systemFont(ofSize: M.titleSize, weight: .semibold)
        titleField.textColor = .labelColor
        subtitleField.font = .systemFont(ofSize: M.subtitleSize)
        subtitleField.textColor = .labelColor
        for field in [titleField, subtitleField] {
            field.lineBreakMode = .byTruncatingTail
            field.usesSingleLineMode = true
            field.cell?.truncatesLastVisibleLine = true
            overlay.addSubview(field)
        }

        favoriteButton.pointSize = M.favoriteIconSize
        favoriteButton.onClick = { [weak self] in
            guard let self, let track = self.track else { return }
            self.library.toggleFavorite(track)
        }
        moreButton.symbolName = "ellipsis"
        moreButton.pointSize = M.moreIconSize
        moreButton.toolTip = "更多"
        moreButton.setAccessibilityLabel("更多")
        // ⋯ 弹的是本窗的动作菜单（与工具条 action 项同一份，见 `actionMenu()`）。
        moreButton.onClick = { [weak self] in
            guard let self else { return }
            // `NSButton.isFlipped` 是 true（实测），(0,0) 是按钮**左上角**——菜单从顶边往下掉。
            // 迷你窗浮在屏幕中间，往下有地方，就不像悬浮胶囊那样要翻上去
            // （要翻的写法见 `MiniPlayerView.showMoreMenu`）。
            self.actionMenu().popUp(positioning: nil, at: .zero, in: self.moreButton)
        }
        overlay.addSubview(favoriteButton)
        overlay.addSubview(moreButton)

        progressBar.onScrub = { [weak self] value in
            guard let self, self.player.duration > 0 else { return }
            self.player.seek(to: value * self.player.duration)
        }
        progressBar.onNudge = { [weak self] delta in
            guard let self, self.player.duration > 0 else { return }
            let target = self.player.currentTime + delta * self.player.duration
            self.player.seek(to: min(max(target, 0), self.player.duration))
        }
        overlay.addSubview(progressBar)

        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: M.timeSize, weight: .regular)
            label.textColor = .labelColor
            overlay.addSubview(label)
        }
        remainingLabel.alignment = .right
        overlay.addSubview(badgeView)

        configure(shuffleButton, symbol: "shuffle", pointSize: M.shuffleIconSize,
                  help: "随机播放") { [weak self] in self?.player.toggleShuffle() }
        configure(previousButton, symbol: "backward.fill", pointSize: M.skipIconSize,
                  help: "上一首") { [weak self] in self?.player.previous() }
        configure(playButton, symbol: "play.fill", pointSize: M.playIconSize,
                  help: "播放") { [weak self] in self?.player.togglePlayPause() }
        configure(nextButton, symbol: "forward.fill", pointSize: M.skipIconSize,
                  help: "下一首") { [weak self] in self?.player.next() }
        configure(repeatButton, symbol: "repeat", pointSize: M.repeatIconSize,
                  help: "循环") { [weak self] in self?.player.cycleRepeatMode() }
        transportButtons.forEach(overlay.addSubview)

        addSubview(overlay)

        // 抽屉：槽 + 那台检查器容器控制器（与主窗同一个类，见 `inspectorController`）。
        inspectorContainer.isHidden = true
        // 先定档再取 `view`：`setMode` 在未`loadView` 时只写`mode` 就返回，
        // 紧接着这一句触发 `loadView`，容器一上来装的就是对的那一档，不用切一次。
        inspectorController.setMode(panelMode, animated: false)
        // [实测] miniplayer spec §11.7 尾段：`displayStyle` 是无条件跟着形态写的，
        // 起手那一次按 `currState`（构造完是 0 = 迷你横条）补上。
        inspectorController.queue.displayStyle = MiniPlayerStates.queueDisplayStyle(currState)
        let panel = inspectorController.view
        panel.translatesAutoresizingMaskIntoConstraints = false
        inspectorContainer.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: inspectorContainer.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: inspectorContainer.trailingAnchor),
            panel.topAnchor.constraint(equalTo: inspectorContainer.topAnchor),
            panel.bottomAnchor.constraint(equalTo: inspectorContainer.bottomAnchor),
        ])
        addSubview(inspectorContainer)

        updateOverlayAppearance()
    }

    /// [实测] §11.6：**外观跟着形态换**。
    ///
    /// ```
    /// if (state ∈ {3…8}) && hasContentToShow { 三个盘 .appearance = vibrantDark }
    /// else                                   { self / 三个盘 .appearance = nil }
    /// ```
    ///
    /// Amber 只有一层浮层（Music 是三个盘），所以这一条落在 `overlay` 与静息层上：
    /// 组 II 起、且有内容 → `.vibrantDark`（前景语义色解析成白，压在封面 + 纱罩上）；
    /// 组 I 或没内容 → `nil`，跟随系统外观。
    private func updateOverlayAppearance() {
        // ★ 与 ASM 的一处**有意偏差**：Music 那边合取项还有 `hasContentToShow`，因为它没内容时
        // 把占位封面用 `compositingFilter` 贴进背景（§11.6），底子还是那块浅玻璃，深色字才对；
        // Amber 的占位封面是一张不透明的彩色渐变（`MPCoverView.placeholder`），底子是深的，
        // 所以这里只看形态：组 II 起一律 vibrantDark。
        let vibrant = MiniPlayerStates.isWindowed(currState)
        let appearance: NSAppearance? = vibrant ? NSAppearance(named: .vibrantDark) : nil
        overlay.appearance = appearance
        // 静息层只在组 I 出现，恒跟随系统外观——写在这里是为了别被上一次的 vibrantDark 粘住。
        miniBar.appearance = nil
        // [实测] §11.3 的可见性收尾：`artworkBlur.isHidden = !(big && hasContentToShow
        // && !isFullWindow(state))`——**只有窗口化组 II 有**。组 I 底下是玻璃，
        // 在玻璃上再糊一层玻璃没有意义（memory `am-window-root-vibrancy` 同一条教训）。
        artworkBlur.isHidden = !artworkBlurApplies
        // [推] 开启态圆盘：vibrantDark 下 `labelColor` = 白，与 [PX] 量到的白 0.42 对上；
        // 组 I 跟随系统外观时改用 `quaternaryLabelColor`，免得浅色下黑盘压黑字。
        let disc: NSColor = vibrant
            ? NSColor.labelColor.withAlphaComponent(M.transportActiveOpacity)
            : .quaternaryLabelColor
        transportButtons.forEach { $0.discColor = disc }
    }

    private func configure(_ button: MPIconButton, symbol: String, pointSize: CGFloat,
                           help: String, action: @escaping () -> Void) {
        button.symbolName = symbol
        button.pointSize = pointSize
        button.toolTip = help
        // [HIG] *Adopting Liquid Glass*：「always specify an accessibility label for each icon」。
        button.setAccessibilityLabel(help)
        button.onClick = action
    }

    // MARK: - 底衬（[实测] miniplayer spec §11.8.1/§11.8.2/§11.8.3/§11.8.4）

    /// [实测] 工厂签名是 `(style:readFromPrefs:)`。
    /// 只判 `style == 1`，其余一律毛玻璃——取值域就此关死，没有第三种。
    private static func makeBackdrop(style: Int) -> NSView {
        guard style == 1 else {
            let view = NSVisualEffectView()
            // [实测] `.popover`（6）/ `.behindWindow`（0）/ `.active`（1）——上一版按
            // [PX] 亮度 168 挑的 `.hudWindow` 是拟合，ASM 的定数压过它。
            view.material = .popover
            view.blendingMode = .behindWindow
            // 窗失焦时 Music 的迷你窗看着没变化，所以不用 followsWindowActiveState。
            view.state = .active
            return view
        }
        let view = MiniPlayerBackdropMetalView()
        // [实测] `appearance = NSAppearance(named: .vibrantDark)` + `setBlur(1000)`。
        // 后者在稳态下会被「画布对角线算 σ」那条无条件覆盖（backdrop spec §2.2），
        // 视图内部照原样实现，这里也照原样调用。
        view.appearance = NSAppearance(named: .vibrantDark)
        view.setBlur(MusicMetrics.Backdrop.miniPlayerBlurRadius)
        return view
    }

    /// [实测] 同签名的 `(style:readFromPrefs:)`：只做去重与转发。
    ///
    /// 组 III（全窗口 `{6,7,8}`）传`(1, false)` 强制 Metal、不看偏好；其余传`(0, true)`
    /// 读 `miniplayer_backdrop`。**Amber 现在进不了组 III**——`integrate_mini_player_with_immersion`
    /// 关着，宽度被 `limitWidthToMaximum(600)` 夹住，过不了 600 那条分界线（spec §3.3），
    /// 而且 §11.4 的版式也还没做。判据照写，等版式补上就自然生效。
    private func updateBackdropStyle(for state: Int) {
        let style = MiniPlayerStates.backdropStyle(
            state: state, preference: UserDefaults.standard.miniplayer_backdrop)
        guard style != backdropStyle else { return }
        backdropStyle = style
        rebuildBackdrop()
    }

    /// [实测]：整只换掉。
    private func rebuildBackdrop() {
        backdrop.removeFromSuperview()
        backdrop = Self.makeBackdrop(style: backdropStyle)
        // `addAndAlignSubview` + `addSubview(_:positioned:.below, relativeTo: nil)`：
        // 四边贴满由本类的 `layout()` 手排，这里只管压到最底层。
        addSubview(backdrop, positioned: .below, relativeTo: nil)
        backdrop.frame = bounds
        // 把当前封面重喂一遍（原版这句是 `largeArtwork.onAssignBlock?(artwork.currentImage)`）。
        (backdrop as? MiniPlayerBackdropMetalView)?.cgImage = currentArtwork
        applyBackdropDynamics(contentWidth: bounds.width)
        needsLayout = true
    }

    /// [实测] §11.8.4：封面一落地就喂两处。
    private func assignArtwork(_ image: CGImage?) {
        currentArtwork = image
        (backdrop as? MiniPlayerBackdropMetalView)?.cgImage = image
        artworkBlur.sourceImage = image
    }

    /// [实测] 入参只有 `(w:)`：纱罩浓度与律动速度都是**内容宽度**的分段线性函数。
    /// 公式与全屏播放器共用同一份（`MusicMetrics.NowPlaying`）。
    /// 毛玻璃那支整段不管——原版第一句就是 `backdrop as? TSLBackdropMetalView` 的判型。
    private func applyBackdropDynamics(contentWidth: CGFloat) {
        guard let metal = backdrop as? MiniPlayerBackdropMetalView else { return }
        metal.scrimAlpha = MusicMetrics.NowPlaying.backdropScrimAlpha(contentWidth: contentWidth)
        metal.animationInterval =
            Float(MusicMetrics.NowPlaying.backdropAnimationInterval(contentWidth: contentWidth))
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let top = topBlockHeight(totalHeight: height, width: width)

        // 底衬铺满整扇窗（抽屉那台容器压在它上面）。
        backdrop.frame = bounds
        // [实测] §11.8.3：纱罩/律动挂在 `setFrameSize:` 真身尾段，**无条件**跟着宽度重算。
        applyBackdropDynamics(contentWidth: width)
        // ★ 封面画到窗口**最顶**，不让安全区。窗是 `fullSizeContentView`（[实测]），
        //   工具条那 52pt 与红绿灯都是窗口 chrome，本来就压在内容视图上面。
        cover.frame = NSRect(x: 0, y: 0, width: width,
                             height: coverHeight(totalHeight: height, width: width))
        // 浮层占「窗高 − 抽屉」这一整块，控件贴它的下沿——所以窗比封面高的时候，
        // 控件仍旧在窗底，不会跟着封面吊在半空。
        overlay.frame = NSRect(x: 0, y: 0, width: width, height: top)
        // 静息层与浮层同一个矩形（顶块），但里面是从**上沿**往下排的：
        // [实测] `artwork.separateTopEdgesByAtLeast(16, to: self)`。
        miniBar.frame = NSRect(x: 0, y: 0, width: width, height: top)
        // 模糊带贴封面下沿，高 `artworkBlurHeight`（= 进度条视觉上沿 + 106）——不是铺满整块。
        // 坐标系是**封面自己的**（不翻转），所以贴下沿就是 y = 0。
        let coverH = cover.frame.height
        artworkBlur.frame = NSRect(x: 0, y: 0, width: width, height: min(coverH, M.artworkBlurHeight))
        // 抽屉 = 顶块以下的全部，**有多少画多少**（拖动过程中就在渲染，不等阈值）。
        let drawer = max(0, height - top)
        inspectorContainer.frame = NSRect(x: 0, y: top, width: width, height: drawer)
        // 0 高的槽里挂面板没有意义，也躲开「0 宽/0 高灌快照」那类坑
        //（组合布局 0 宽会爆内存那条同源教训）。
        let drawerHidden = drawer <= 0
        // 收起时那条 5 秒回滚由**面板根视图自己**停（`PlayQueuePanelRootView.viewDidHide()`）：
        // `isHidden` 会沿视图树往下发`viewDidHide()`，主窗收分栏列那一路同样成立，
        // 所以这里不再另外喊一次 `panelDidBecomeHidden()`——两个宿主共用同一条驱动。
        inspectorContainer.isHidden = drawerHidden
        layoutOverlay()
    }

    /// 顶块的高度：窗口化是**方形封面**（边长 = 窗宽），迷你横条是那条 154 的横条。
    /// 窗比它高出来的部分全归抽屉。
    ///
    /// **只看几何，不看状态、也不看 `inspectorContainer.isHidden`**（[PX] 录屏
    /// `录屏2026-09-08 17.01.41.mov`，10.9…12.4s 那一段拖拽）：往下拖的过程中封面与控件
    /// 一动不动，长出来的那一截**当场就在渲染歌词**——不是等过了 `h > 宽 + 200` 才出现。
    /// 旧实现按「抽屉开没开」算顶块，于是没开面板时顶块吃满全高、控件被钉在窗底跟着走，
    /// 封面下面空一条灰（用户实机打回两次的就是这个）。
    ///
    /// 窗比封面还矮时（淡入带 200…250）顶块就是全高，控件照旧贴窗底。
    private func topBlockHeight(totalHeight: CGFloat, width: CGFloat) -> CGFloat {
        let base = MiniPlayerStates.isWindowed(currState) ? width : M.collapsedContentHeight
        return max(0, min(base, totalHeight))
    }

    /// 封面那一格：**恒为正方形，边长 = 窗宽**，钉在窗口最顶。
    ///
    /// 早前是「没开面板时铺满整个顶块」，于是窗一拉高封面就跟着变形／越裁越多
    /// （用户实机打回：「封面比例要固定，而不是随着窗口变化」）。
    /// 组 I 没有封面（`largeArtwork` 的 alpha 由`progress` 归零），这里给 0。
    private func coverHeight(totalHeight: CGFloat, width: CGFloat) -> CGFloat {
        guard MiniPlayerStates.isWindowed(currState) else { return 0 }
        return topBlockHeight(totalHeight: totalHeight, width: width)
    }

    /// 窗口按当前形态该有的内容尺寸：方形封面 + 抽屉。
    /// 开合面板时窗口就照它长高／收矮（**上边不动，往下长**，见 inspector spec §4.4）。
    func naturalContentSize(forWidth width: CGFloat) -> NSSize {
        NSSize(width: width, height: naturalHeight(forWidth: width))
    }

    /// 浮层全部以顶块**下沿**为基准排（窗口长高时只有封面变高，控制块贴着下沿不动）。
    ///
    /// 安全区只管浮层不管封面：`safeAreaInsets.top` 是工具条那 52（没有工具条时是标题栏
    /// 的 28），控制块要避开它，封面照旧铺到最顶。
    ///
    /// **两套纵向偏移**：展开态（组 II 起）用 `xxxCenterFromBottom`，收起态（组 I）用
    /// [PX] 实拍的 `collapsedXxxCenterFromBottom`——横向三条（内缩 16 / 贴边 34 /
    /// 间距 58）两态共用。判据以形态为主；顶块被压到连标题两行都排不下时（[实测] 淡入带
    /// 200…210 那一小段）也退到收起态那一组，免得字顶进工具条。
    private func layoutOverlay() {
        let width = overlay.bounds.width
        let bottom = overlay.bounds.height          // 翻转坐标系：顶块下沿的 y
        guard width > 0, bottom > 0 else { return }
        let inset = M.horizontalInset
        let available = bottom - safeAreaInsets.top
        let full = MiniPlayerStates.isWindowed(currState) && available >= M.metadataTopFromBottom
        fullOnlyViews.forEach { $0.isHidden = !full }

        // [实测] §11.5 ③：200→250 那 50pt 里四条间距是**线性插值**过去的，不是到点一跳。
        // Amber 手排 frame，插的是那四条间距的落点——三条纵向偏移（见 `overlayOffsets`）。
        // 标题两行排不下时（`full == false`）照旧钉在收起态那一组：那一档本来就没有标题行。
        let offsets = MiniPlayerStates.overlayOffsets(progress: full ? morphProgress : 0)

        // 传输五键：随机/循环贴左右沿，上一首/播放/下一首以窗口中线为中心等距排。
        let transportY = bottom - offsets.transport
        let box = M.transportButtonSize
        place(shuffleButton, centerX: M.transportEdgeInset, centerY: transportY, size: box)
        place(repeatButton, centerX: width - M.transportEdgeInset, centerY: transportY, size: box)
        place(previousButton, centerX: width / 2 - M.transportSpacing, centerY: transportY, size: box)
        place(playButton, centerX: width / 2, centerY: transportY, size: box)
        place(nextButton, centerX: width / 2 + M.transportSpacing, centerY: transportY, size: box)

        let scrubberY = bottom - offsets.scrubber
        progressBar.frame = NSRect(x: inset, y: scrubberY - M.scrubberHitHeight / 2,
                                   width: max(0, width - inset * 2), height: M.scrubberHitHeight)

        // 时间行：左「已播」/ 中「音质徽标」/ 右「剩余」，同一条中线。两态都有。
        let timeCenterY = bottom - offsets.time
        let timeTop = timeCenterY - M.timeRowHeight / 2
        let timeWidth = max(0, (width - inset * 2) / 3)
        elapsedLabel.frame = NSRect(x: inset, y: timeTop, width: timeWidth, height: M.timeRowHeight)
        remainingLabel.frame = NSRect(x: width - inset - timeWidth, y: timeTop,
                                      width: timeWidth, height: M.timeRowHeight)
        // 徽标：两侧时间标签各按自己的墨迹宽占位，中间那一格塞不下就整枚不出现
        // （[PX] 实拍那句「音质徽标居中，窄时不出现」；Music 同样是什么都不画）。
        let badgeSize = badgeView.fittingSize
        let sideWidth = max(ceil(elapsedLabel.intrinsicContentSize.width),
                            ceil(remainingLabel.intrinsicContentSize.width))
        let badgeRoom = width - inset * 2 - sideWidth * 2 - M.accessorySpacing * 2
        // [PX] 徽标只在展开态出现：Music 的收起态实拍（两段录屏各一帧，`music_collapsed.png`
        // 与第一段 16.2s 那帧）里「0:33 … −4:35」中间都是空的，而方形态有「〰 无损」。
        // 两帧互证，不是单样本拟合。再叠一条「中间那格塞不下就不出现」的 [推] 闸。
        badgeView.isHidden = !(MiniPlayerStates.isWindowed(currState)
            && badgeView.isLossless && badgeSize.width <= badgeRoom)
        badgeView.frame = NSRect(x: (width - badgeSize.width) / 2,
                                 y: timeCenterY - badgeSize.height / 2,
                                 width: badgeSize.width, height: badgeSize.height)

        guard full else { return }

        // 元数据两行：底沿钉在 117，往上排；☆ / ⋯ 在这两行的竖向中点上、右对齐。
        let subtitleHeight = ceil(subtitleField.intrinsicContentSize.height)
        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        let metadataBottom = bottom - M.metadataBottomFromBottom
        let subtitleTop = metadataBottom - subtitleHeight
        let titleTop = subtitleTop - M.metadataLineSpacing - titleHeight

        let accessoryRight = width - inset
        let accessoryWidth = M.accessorySize * 2 + M.accessorySpacing
        let accessoryCenterY = (titleTop + metadataBottom) / 2
        place(favoriteButton, centerX: accessoryRight - accessoryWidth + M.accessorySize / 2,
              centerY: accessoryCenterY, size: M.accessorySize)
        place(moreButton, centerX: accessoryRight - M.accessorySize / 2,
              centerY: accessoryCenterY, size: M.accessorySize)

        // 文字列到 ☆ 之间留一格，窄窗时先截字不压按钮。
        let textWidth = max(0, width - inset - accessoryWidth - M.accessorySpacing - inset)
        titleField.frame = NSRect(x: inset, y: titleTop, width: textWidth, height: titleHeight)
        subtitleField.frame = NSRect(x: inset, y: subtitleTop, width: textWidth, height: subtitleHeight)
    }

    /// 图标键按「字形中心」定位：命中盒统一取 `accessorySize`，字形自己居中。
    private func place(_ view: NSView, centerX: CGFloat, centerY: CGFloat,
                       size: CGFloat = MusicMetrics.MiniPlayerWindow.accessorySize) {
        view.frame = NSRect(x: (centerX - size / 2).rounded(),
                            y: (centerY - size / 2).rounded(),
                            width: size, height: size)
    }

    /// 当前形态下内容该有多高。三档正好对上规格的高度阶梯（§3.2）：
    /// 收起态 = [实测] 初始内容矩形的 100；窗口化空态 = 方形（高 = 宽）；
    /// 开了面板再加一份抽屉，于是「高 > 宽 + 200」这条判据自动成立（抽屉下限就是 200）。
    private func naturalHeight(forWidth width: CGFloat) -> CGFloat {
        let base = baseHeight(forWidth: width)
        let drawer = (isLyricsOpen || isQueueOpen) ? max(drawerHeight, M.drawerMinHeight) : 0
        let height = base + drawer
        // 组 I 开着面板（态 1/2）时还要过 [实测] 分支 A 的 400 那条线：
        // 在起始态 ∈ {1,2} 时按 `h ≥ 400` 判要不要保面板，
        // 算出来的标准高低于 400 的话，绿灯一按状态机就把面板收了，等于绿灯自带「关面板」。
        guard drawer > 0, !MiniPlayerStates.isWindowed(currState) else { return height }
        return max(height, M.miniBarPanelHeight)
    }

    /// 抽屉之上那一块（顶块）该有多高：窗口化是方形封面（边长 = 窗宽），收起态是那条横条。
    private func baseHeight(forWidth width: CGFloat) -> CGFloat {
        MiniPlayerStates.isWindowed(currState)
            ? max(width, M.collapsedContentHeight)
            : M.collapsedContentHeight
    }

    /// 拖窗松手时把**拖出来的抽屉高度**记成新的 `drawerHeight`。
    ///
    /// 没开面板的档没有抽屉，也就没有「中间态」——窗口控制器那边会把窗收回自然高
    /// （见 `MiniPlayerWindowController.windowDidEndLiveResize`），所以这里直接不管。
    ///
    /// 不读 `inspectorContainer.frame.height`：这一步紧跟在`apply(state:)` 之后，
    /// 那一档的 layout 还没跑，读到的是上一帧的高。按窗口给的内容高反算才对得上。
    func rememberDrawerHeight(contentHeight: CGFloat, width: CGFloat) {
        guard isLyricsOpen || isQueueOpen else { return }
        drawerHeight = max(contentHeight - baseHeight(forWidth: width), M.drawerMinHeight)
    }

    // MARK: - 形态

    /// 状态落地。顺序照 inspector spec §4.4 的准备段 → 动画块 → completion 块：
    /// 收起前记抽屉高 → **先显示**（旧态或新态任一是大形态就先挂出来）→
    /// 动画块里才写 `currState`、时长 0.4 → completion 里按**新态**决定藏不藏。
    ///
    /// 窗口 frame 的改动不在这里：那是窗口控制器的活（动画块里 Music 自己
    /// `window.animator().setFrame`，Amber 这边由`MiniPlayerWindowController` 做）。
    func apply(state: Int, animated: Bool) {
        let old = currState
        // 幂等：resize 过程中窗口控制器会反复喂同一个态。
        guard state != old else { return }

        // [实测] §11.8.2：换形态就重问一次底衬样式——组 III 强制 Metal，其余读偏好。
        updateBackdropStyle(for: state)

        // 准备段：收起前把抽屉当前高度记下来，下次展开用它还原。
        if MiniPlayerStates.isBig(old) && !MiniPlayerStates.isBig(state) {
            drawerHeight = max(inspectorContainer.frame.height, M.drawerMinHeight)
        }
        // 抽屉的显隐不在这里管：它就是「顶块以下还剩多少」，由 `layout()` 按几何定。
        // inspector spec §4.4 那套「先显示、completion 才藏」是给约束驱动的实现准备的，
        // Amber 手排 frame，窗口每长/缩一帧抽屉就跟着变——本来就是连续的。
        // 组 I 没有封面（[PX] 实拍），组 II 起才铺满顶块。中间那条 200→250 的淡入带由
        // 窗口控制器逐帧喂 `applyLargeArtworkProgress`，这里只管形态落地的两端。
        // ★ 窗口控制器的调用顺序是「先 `apply(state:)` 后`applyLargeArtworkProgress`」——
        //   反过来的话落在过渡带里的窗（h ∈ 200…250）会被这里的端点值把 progress 抹平。
        let targetAlpha: CGFloat = MiniPlayerStates.isWindowed(state) ? 1 : 0
        morphProgress = targetAlpha

        // [HIG] 减弱动态效果时不做中间帧：该到位的还是到位，只是瞬间切过去。
        guard animated, !reduceMotion else {
            currState = state
            syncInspector(for: state, animated: false)
            cover.alphaValue = targetAlpha
            updateOverlayAppearance()
            syncRolloverLayers(animated: false)
            needsLayout = true
            onStateChanged?()
            updateRollover(interested: pointerInside)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            // [实测] 0.4s；另一支 40.0 的慢动画开关没有动态替换时恒 false。
            context.duration = M.stateAnimationDuration
            // [实测] §11.7 的缓动。Music 把它用在「封面中心位移补偿」那条独立动画上；
            // Amber 没有那条约束（封面位移跟着窗口 frame 走），落点改成换态动画组本身。
            context.timingFunction = M.artworkRecenterTiming
            context.allowsImplicitAnimation = false
            // ★ 状态在动画块里才真正写入
            self.currState = state
            // [实测] §11.7：`inspectorContainer.setMode(表[state−1], animated: settingUpForAnimation)`
            // ——**动画开着**，而且 Music 就是在这一层的动画组**里面**调的，与这里同形。
            //
            // 「抽屉正被形变动画改高度、内部再叠一层交叉淡入会不会打架」：不会。
            // 两层动的是不同的属性——外层动窗口 frame 与封面 alpha，内层只动两个面板
            // 各自的 alpha；面板的**尺寸**是约束贴着槽走的，槽的 frame 每帧由 `layout()`
            // 重排，两个面板同槽同尺寸，淡入淡出期间不会互相拉扯。
            // 时长上内层是 `setMode` 自己开的嵌套动画组，用`NSAnimationContext` 默认
            //（§1.4 那条 `[推]`，约 0.25s），比外层 0.4s 先落——Music 同此，
            // 因为它的 `setMode` 也是这么嵌的。
            self.syncInspector(for: state, animated: true)
            self.updateOverlayAppearance()
            self.onStateChanged?()
            self.cover.animator().alphaValue = targetAlpha
            self.syncRolloverLayers(animated: true)
            // 顶块/抽屉跟着窗口每一帧的新 bounds 重排，不需要自己插值。
            self.needsLayout = true
            // 换形态一律先把浮层露出来（Music 长大的过程里控件是在的，安定之后才淡）。
            self.updateRollover(interested: self.pointerInside)
        } completionHandler: { [weak self] in
            // 完成回调的类型是 `@Sendable`，而这里动的是主线程隔离的视图。
            // `NSAnimationContext` 明文保证回调在主线程，所以用 `assumeIsolated` 接回来。
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
    }

    /// `lyricsClicked`：查跳表算出新态，再统一`apply`。
    func lyricsClicked() {
        apply(state: MiniPlayerStates.afterLyricsClick(currState), animated: true)
    }

    /// `queueClicked`：同上，走队列那张表。
    /// Music 开头那道 `show_queue_in_immersion` 短路只对全窗口态 {6,7,8} 生效，
    /// 本窗到不了那三态，所以没有对应分支。
    func queueClicked() {
        apply(state: MiniPlayerStates.afterQueueClick(currState), animated: true)
    }

    /// 工具条 `action`（ellipsis）项弹出的菜单（spec §5 的`doActionButton:` →
    /// `contents` 的动作菜单 vtable）。浮层右下那颗 ⋯ 弹的也是它。
    ///
    /// [PX] 2026-09-09 Music 实拍：**它就是播放器那份 ••• 菜单**（`PlayerMoreMenu`
    /// 那张表，与整窗播放器、底部悬浮条同一份），迷你窗在头尾各多包了自己的三样：
    ///
    /// 1. 顶上一块「正在播放」头（封面 + 标题 + 艺人 — 专辑），不可点；
    /// 2. 紧接着一条音质入口（「无损 – 48 kHz ALAC」，点开是音频质量设置）；
    /// 3. 末尾一条「显示 / 隐藏大插图」（⌥⌘A）。
    ///
    /// 旧实现摆的是「显示歌词 / 显示待播清单 / 显示大封面 / 切换到主窗口」四条——
    /// 那是照 §4.2 的 `validate_*` 一族猜的，实拍里这份菜单没有它们：歌词与待播清单
    /// 在工具条上各有一颗键，切回主窗走「窗口 ▸ 从迷你播放器切换回来」（⇧⌘M）。
    func actionMenu() -> NSMenu {
        var entries: [MenuSpec.Entry] = []
        if let quality = qualityTitle {
            entries.append(.command(MenuSpec.Command(quality, run: {
                AuxiliaryWindows.shared.showSettings(tab: .playback)
            })))
            entries.append(.separator)
        }
        if let track {
            entries += PlayerMoreMenu.entries(track: track, appState: appState,
                                              library: library, downloads: appState.downloads)
        }
        entries.append(.separator)
        // 判据是 `currState ∈ {3…8}`（= showActionToolbar 同一条）。快捷键真正生效的
        // 绑定在「窗口 ▸ 显示大插图」上（`MainMenu`），这里摆出来只是告诉用户它有。
        entries.append(.command(MenuSpec.Command(
            showActionToolbar ? "隐藏大插图" : "显示大插图",
            symbol: "photo", key: ("a", [.command, .option]),
            run: { [weak self] in self?.toggleLargeArtwork() })))

        let menu = PlayerMoreMenu.makeMenu(entries)
        if let track { menu.insertItem(headerItem(for: track), at: 0) }
        return menu
    }

    /// 音质那一条的标题。规格要等这一路流就绪才读得到，读不到就整条不摆
    /// （与气泡 `AudioQualityPopover` 同一份数据）。
    private var qualityTitle: String? {
        guard let format = player.streamFormat else { return nil }
        return "\(format.tierName) – \(format.detail)"
    }

    /// 菜单顶上那块「正在播放」头。菜单项带 `view` 就不参与高亮，正好——它不可点。
    private func headerItem(for track: Track) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MiniPlayerMenuHeaderView(track: track, artwork: currentArtwork)
        return item
    }

    /// 「显示/隐藏大插图」= 组 I ⇄ 组 II 互转且保持面板不变（那张表）。
    /// 「窗口 ▸ 显示大插图」（⌥⌘A）走的也是这一条（经窗口控制器转一手）。
    func toggleLargeArtwork() {
        apply(state: MiniPlayerStates.toggleGroup(currState), animated: true)
    }

    /// spec §3.2：`progress = (h − 200) / 50` 就是大封面的`alphaValue`。
    /// 照开头两句写：先 `setHidden(false)`，再`setAlphaValue(progress)`
    /// ——**没有下限**。
    ///
    /// 上一轮在这里加过一条 `collapsedCoverAlpha = 0.6` 的下限，理由是「淡到 0 只剩一块
    /// 空玻璃」。第二段录屏的收起态实拍（`music_collapsed.png`）证明那正是 Music 的样子：
    /// 收起态本来就没有封面，露出来的就是那块玻璃。所以下限撤掉，恢复字面语义。
    func applyLargeArtworkProgress(_ progress: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        cover.isHidden = false
        cover.alphaValue = clamped
        // [实测] §11.5 ①：**大封面淡入的同时小封面按 `1 − progress` 淡出**——
        // 旧实现只写了前半句。判据（`showSmallArtwork`）按调用当下的形态算：
        // 过渡带里窗口控制器还没落地新态，`currState` 仍是组 I，交叉淡化正好发生在这一段。
        morphProgress = clamped
        syncRolloverLayers(animated: false)
        needsLayout = true
    }

    /// 静息层与控件层的目标 alpha，都由（`rollState`、形态、`progress`）算出来。
    ///
    /// - 静息层：[实测] §11.3 的 × §11.5 ① 的 `1 − progress`。
    /// - 控件层：**只有窗口化那几档跟着 rollover 淡**（那一档淡光了露出 edge-to-edge 封面）。
    ///   迷你横条里**进度条 / 时间行 / 传输键是常驻的**——[PX] Music 迷你横条静息态实拍：
    ///   换掉的只是顶上那一行（chrome ⇄ 小封面 + 标题 + 无损徽标），下面三行原样在。
    ///   上一版把整层一起淡了，静息态就只剩封面和标题，控件全没了，实机打回。
    private func syncRolloverLayers(animated: Bool) {
        let showsMiniBar = MiniPlayerStates.showsSmallArtwork(
            state: currState, rolloverVisible: rollState, hasContent: track != nil)
        fade(miniBar, to: showsMiniBar ? 1 - morphProgress : 0, animated: animated)
        let overlayTarget: CGFloat = MiniPlayerStates.isWindowed(currState)
            ? (rollState ? 1 : 0)
            : 1
        fade(overlay, to: overlayTarget, animated: animated)
        // 模糊带住在封面里，淡出得自己跟一遍——不然控件淡光了封面下半截还糊着，
        // [PX] 那边淡完是一张 edge-to-edge 的清晰封面。模糊烘在自己的 `contents` 里，
        // 所以这里跟别的层一样淡 alpha 就行（老实现走背景滤镜，得单独把半径动画到 0）。
        fade(artworkBlur, to: artworkBlurApplies && overlayTarget > 0 ? 1 : 0, animated: animated)
    }

    private func fade(_ view: NSView, to target: CGFloat, animated: Bool) {
        guard view.alphaValue != target || view.isHidden != (target <= 0) else { return }
        guard animated, !reduceMotion else {
            view.alphaValue = target
            view.isHidden = target <= 0
            return
        }
        if target > 0 { view.isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = M.rolloverFadeDuration
            view.animator().alphaValue = target
        } completionHandler: {
            // 完成回调是 `@Sendable`，`NSAnimationContext` 保证它在主线程跑，
            // 所以把主线程隔离的视图属性用 `assumeIsolated` 接回来。
            MainActor.assumeIsolated {
                // 淡到 0 之后彻底摘掉：`alphaValue == 0` 的视图在 AppKit 里照样吃点击。
                view.isHidden = view.alphaValue <= 0
            }
        }
    }

    // MARK: - 浮层的 rollover（nowplaying spec §2.3）

    /// `NSTrackingArea` 装在内容视图自己身上：`.inVisibleRect` 让它跟着 bounds 走，
    /// 窗口每次 resize 都不用重算矩形。`.mouseMoved` 由 tracking area 自己投递，
    /// 不需要去动窗口的 `acceptsMouseMovedEvents`（那是窗口控制器的地盘）。
    /// [推] `.activeAlways`：这扇窗可以置顶，App 不在前台时把指针移上去也该露出控件。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let rolloverTrackingArea { removeTrackingArea(rolloverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        rolloverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        updateRollover(interested: true)
    }

    override func mouseMoved(with event: NSEvent) {
        pointerInside = true
        updateRollover(interested: true)
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        // ★ 离开窗口走的是短的那一档（0.3），不是窗内静止那档（3.75）。
        updateRollover(interested: false, exitingWindow: true)
    }

    /// spec §2.3 的 `viewDidMoveToWindow`：挂窗口焦点观察，焦点变化也驱动浮层淡入淡出。
    /// 块式观察者注册的是通知中心自己造的令牌，`removeObserver(self)` 摘不掉，得存下来
    /// 逐个摘（同 `SyncedLyricsViewController.installScrollObserversIfNeeded`）。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        focusObservers.forEach(center.removeObserver)
        focusObservers = []
        guard let window else {
            // 窗口关掉（`isReleasedWhenClosed = false`，本视图还活着）之后，队列面板那条
            // 5 秒回滚不该继续跑。迷你窗没有 `contentViewController`，容器与子控制器
            // 收不到 `viewDidDisappear`，所以从这里补一刀（同`layout()` 里收抽屉那处）。
            inspectorController.queue.panelDidBecomeHidden()
            return
        }
        // 块式观察者的闭包是 `@Sendable`；`queue: .main` 已经把投递线程钉死在主线程，
        // 所以用 `assumeIsolated` 接回主线程隔离的自己。
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            focusObservers.append(center.addObserver(forName: name, object: window,
                                                     queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateRollover(interested: self.pointerInside)
                }
            })
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification] {
            focusObservers.append(center.addObserver(forName: name, object: window,
                                                     queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRollover(interested: false) }
            })
        }
        updateRollover(interested: pointerInside)
    }

    /// 计时器与观察者令牌都不是 `Sendable`，非隔离的 `deinit` 取不到它们。
    /// 标 `isolated`：主线程上释放时照旧同步跑完，注销时机不变。
    isolated deinit {
        mouseInterestTimer?.invalidate()
        mouseStartingInterestTimer?.invalidate()
        let center = NotificationCenter.default
        focusObservers.forEach(center.removeObserver)
    }

    /// 有「兴趣」（指针在窗内、或窗口刚拿到焦点）就露出来；没有就起表，到点淡掉。
    ///
    /// [实测] §11.1 的**双计时器**：起步计时（0.1）决定「多久之后才认这次兴趣」，
    /// 兴趣计时决定「多久之后淡掉」——窗内静止 3.75、指针离开窗口 0.3。
    /// 旧实现是「进入即亮 / 离开 2 秒后淡」的单表 [推]，两个数现在都实测到了。
    private func updateRollover(interested: Bool, exitingWindow: Bool = false) {
        guard interested else {
            mouseStartingInterestTimer?.invalidate()
            mouseStartingInterestTimer = nil
            scheduleRolloverHide(after: exitingWindow ? M.mouseInterestExitingWindowTimeout
                                                      : M.mouseInterestTimeout)
            return
        }
        // 已经露着：只把兴趣计时续上，不重新起步。
        if rollState {
            scheduleRolloverHide(after: M.mouseInterestTimeout)
            return
        }
        guard mouseStartingInterestTimer == nil else { return }
        mouseStartingInterestTimer = Timer.scheduledTimer(
            withTimeInterval: M.delayBeforeStartingRolloverMin, repeats: false) { [weak self] _ in
            // 表挂在主 runloop 上，回调必在主线程；闭包类型是 `@Sendable`，接回来。
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mouseStartingInterestTimer = nil
                self.setRollState(true)
                self.scheduleRolloverHide(after: M.mouseInterestTimeout)
            }
        }
    }

    private func scheduleRolloverHide(after delay: TimeInterval) {
        mouseInterestTimer?.invalidate()
        mouseInterestTimer = nil
        // 这一档没东西可露就恒亮（没曲目的迷你横条）。
        guard rolloverApplies else { setRollState(true); return }
        mouseInterestTimer = Timer.scheduledTimer(withTimeInterval: delay,
                                                  repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.setRollState(false) }
        }
    }

    /// `setRollState:`。整层一起改`alphaValue`——这就是「浮层必须是一个容器」的理由。
    ///
    /// 三件事一起走：控件层淡出／淡入、静息层（组 I 的小封面 + 标题）反向淡、
    /// 窗口 chrome（红绿灯 + 工具条）交给窗口控制器一起淡——最后这一条是 [实测] §11.3 的
    /// 几何逼出来的：小封面钉在「距内容顶 ≥ 16」，与工具条那 52pt 是同一块地。
    private func setRollState(_ visible: Bool) {
        // 没东西可露的那一档强制常显。
        let target = rolloverApplies ? visible : true
        guard target != rollState else { return }
        rollState = target
        // 窗口 chrome（红绿灯 + 工具条）跟着走：迷你横条里它与静息层是同一块地，
        // 窗口化那档它与 edge-to-edge 封面抢地。纱罩是控件层的子视图，跟着一起淡。
        onRollStateChanged?(target)
        syncRolloverLayers(animated: true)
    }

    /// 形态落地时推给抽屉那台容器的两件事（[实测] miniplayer spec §11.7 尾段，顺序同源）：
    ///
    /// ```
    /// if state ∈ {1,2,4,5,7,8} { inspectorContainer.setMode(表[state−1], animated: …) }
    /// inspectorContainer.queue.displayStyle = (state ∈ {6,7,8}) ? 3 : ((state ∈ {3…8}) ? 1 : 2)
    /// ```
    ///
    /// `setMode` 有掩码 219 那道闸（空态 {0,3,6} 不切），`displayStyle` 是**无条件**写的。
    /// 空态不切档正对应「面板收起时 mode 保持不变，下次展开还回原来那一档」。
    private func syncInspector(for state: Int, animated: Bool) {
        if MiniPlayerStates.isLyricsOpen(state) {
            setPanelMode(.lyrics, animated: animated)
        } else if MiniPlayerStates.isQueueOpen(state) {
            setPanelMode(.queue, animated: animated)
        }
        inspectorController.queue.displayStyle = MiniPlayerStates.queueDisplayStyle(state)
    }

    /// 换档的唯一入口。两头各写一次、各自去重：
    ///
    /// - 视图层：容器实例上的 `mode`（inspector spec §1.1 的 +16），交叉淡入归它；
    /// - 模型层：全局那一份 `AppState.inspectorMode`——主窗胶囊上那两颗键读它，
    ///   下次在任何一个宿主打开面板也是这一档。写它**不会**掀开主窗的面板列，
    ///   因为「开着没有」是 `AppState.isInspectorOpen` 那一位，本窗碰不到。
    private func setPanelMode(_ mode: PlayerInspector, animated: Bool) {
        inspectorController.setMode(mode, animated: animated)
        if appState.inspectorMode != mode { appState.inspectorMode = mode }
    }

    /// 别的宿主（主窗胶囊、另一扇窗）换档时本窗跟上。
    ///
    /// 抽屉正开着就换成另一档——走的是「点另一颗键」那张跳表（1↔2 / 5↔4 / 8↔7，
    /// 组不变、窗高不变）；抽屉收着就只把容器摆对，**不自己打开**：
    /// 「开着没有」是本窗自己那一位。
    private func syncPanelModeFromGlobal() {
        let mode = appState.inspectorMode
        guard isLyricsOpen || isQueueOpen else {
            inspectorController.setMode(mode, animated: false)
            return
        }
        guard (mode == .lyrics) != isLyricsOpen else { return }
        apply(state: mode == .lyrics ? MiniPlayerStates.afterLyricsClick(currState)
                                     : MiniPlayerStates.afterQueueClick(currState),
              animated: true)
    }

    // MARK: - 约束与尺寸（窗口控制器用）

    /// `loadWindow` 无条件装的那条：`contents.limitWidthToMinimum(320)`。
    @discardableResult
    func limitWidthToMinimum(_ width: CGFloat) -> NSLayoutConstraint {
        let constraint = widthAnchor.constraint(greaterThanOrEqualToConstant: width)
        constraint.isActive = true
        return constraint
    }

    /// flag 关时才装的那条：`maxWidthConstraint = contents.limitWidthToMaximum(600)`。
    /// 装上它，宽度就过不了 600 → 组 III {6,7,8} 在本窗不可达（spec §3.3）。
    @discardableResult
    func limitWidthToMaximum(_ width: CGFloat) -> NSLayoutConstraint {
        let constraint = widthAnchor.constraint(lessThanOrEqualToConstant: width)
        constraint.isActive = true
        return constraint
    }

    /// 绿灯（`windowWillUseStandardFrame:`）用：临时把宽/高钉死、过一遍布局、读回内容矩形、
    /// 再解开（spec §3.4：**标准尺寸不是算出来的常量，是把内容视图临时钉死再反推的**）。
    ///
    /// Amber 的两段是手排 frame，不是约束堆出来的，所以「反推」这一步退化成
    /// `naturalHeight(forWidth:)` 那套同源算术；调用形状照原样保留（激活 → 强制布局 →
    /// 读回 → deactivate），窗口控制器那边一个字都不用改。
    /// 两条临时约束用 `.required − 1`：窗口给 contentView 的那套尺寸约束是 required，
    /// 同级硬碰硬会在控制台刷一片 unsatisfiable。
    func layoutFrame(width: CGFloat, height: CGFloat?) -> NSRect {
        let widthPin = widthAnchor.constraint(equalToConstant: width)
        widthPin.priority = .required - 1
        widthPin.isActive = true
        var heightPin: NSLayoutConstraint?
        if let height {
            let pin = heightAnchor.constraint(equalToConstant: height)
            pin.priority = .required - 1
            pin.isActive = true
            heightPin = pin
        }
        layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: height ?? naturalHeight(forWidth: width))
        widthPin.isActive = false
        heightPin?.isActive = false
        return NSRect(origin: .zero, size: size)
    }

    // MARK: - 状态恢复

    private static let stateKey = "MPContentView.currState"
    private static let drawerKey = "MPContentView.drawerHeight"
    // 档位不再各窗归档一份：它是全局的 `AppState.inspectorMode`，
    // 而 `currState` 本身就带着「开的是哪一档」（{1,5,8} 歌词 / {2,4,7} 队列），
    // 恢复时由 `apply(state:)` → `syncInspector(for:)` 一并推回去。

    /// 窗口控制器的 `encodeRestorableStateWithCoder:` 会连本视图一起编
    /// （spec §2 的一次性迁移与 §6 的关窗归档都是「自己 + contents」两份）。
    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        coder.encode(currState, forKey: Self.stateKey)
        coder.encode(Double(drawerHeight), forKey: Self.drawerKey)
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        if coder.containsValue(forKey: Self.drawerKey) {
            drawerHeight = CGFloat(coder.decodeDouble(forKey: Self.drawerKey))
        }
        if coder.containsValue(forKey: Self.stateKey) {
            // 恢复不做动画：窗口 frame 是同一批恢复的，动画会和它打架。
            apply(state: coder.decodeInteger(forKey: Self.stateKey), animated: false)
        }
    }

    // MARK: - 订阅

    private func bind() {
        // 一律 `receive(on: .main)` 再读属性：`@Published` 是在 **willSet** 里发的，
        // 同步读回去拿到的是旧值（同 `MiniPlayerView.bind()` 的注释）。
        player.$currentIndex.map { _ in () }
            .merge(with: player.$queue.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.updateTrack(self.player.currentTrack)
            }
            .store(in: &cancellables)

        player.$isPlaying.removeDuplicates()
            .merge(with: player.$isLoading.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePlayButton() }
            .store(in: &cancellables)

        player.$isShuffled.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateShuffle() }
            .store(in: &cancellables)

        player.$repeatMode.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateRepeat() }
            .store(in: &cancellables)

        player.$duration.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateTime(self.player.currentTime)
            }
            .store(in: &cancellables)

        // 进度 10 Hz 一跳，只让进度条与两枚时间标签跟着跳（见 `PlaybackClock`）。
        player.clock.$time
            .sink { [weak self] time in self?.updateTime(time) }
            .store(in: &cancellables)

        // ☆ 的实心/空心跟着资料库那份心水名单走。
        library.$favoriteTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateFavorite() }
            .store(in: &cancellables)

        // 别处切档时本窗跟着走：档位是全局一份，两台容器显示的该是同一档。
        // （`@Published` 在 willSet 发布，所以照例先 `receive(on:)` 再读属性。）
        appState.$inspectorMode.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncPanelModeFromGlobal() }
            .store(in: &cancellables)
    }

    // MARK: - 各件的刷新

    private func updateTrack(_ newTrack: Track?, force: Bool = false) {
        guard force || newTrack != track else { return }
        track = newTrack

        if let newTrack {
            let tint = NSColor(Color.tint(for: newTrack.kind))
            cover.setArtwork(url: newTrack.artworkURL, tint: tint, points: ArtworkSize.header)
            let subtitle = newTrack.albumName.isEmpty
                ? newTrack.artistName
                : "\(newTrack.artistName) — \(newTrack.albumName)"
            titleField.stringValue = newTrack.title
            subtitleField.stringValue = subtitle
        } else {
            cover.setArtwork(url: nil, tint: .amberSidebarAccent, points: ArtworkSize.header)
            titleField.stringValue = "未在播放"
            subtitleField.stringValue = ""
        }

        miniBar.update(track: newTrack)
        // `hasContentToShow` 变了要重判外观（§11.6 的 vibrantDark 是「组 II 起 **且有内容**」）
        // 与静息层的显隐（§11.3 的第三个合取项就是它）。
        updateOverlayAppearance()
        syncRolloverLayers(animated: false)
        updateRollover(interested: pointerInside)

        for button in transportButtons { button.isEnabled = newTrack != nil }
        favoriteButton.isEnabled = newTrack != nil
        progressBar.isHidden = newTrack == nil
        updateFavorite()
        updateBadge()
        updateShuffle()
        updateRepeat()
        updatePlayButton()
        updateTime(player.currentTime)
        needsLayout = true
    }

    private func updateFavorite() {
        // [实测] §4.5 的三态机 Amber 只走 none ↔ liked 两态（同 `NowPlayingView.favoriteButton`）。
        let state: FavoritingState = (track.map { library.isFavorite($0) } ?? false) ? .liked : .none
        favoriteButton.symbolName = state.symbolName
        favoriteButton.toolTip = state == .liked ? "取消心水" : "心水"
        favoriteButton.setAccessibilityLabel(favoriteButton.toolTip ?? "")
    }

    /// 徽标要跟徽标点开的气泡说同一件事：这一路流真就绪了就按实际拿到的那一档判，
    /// 还没就绪才退回目录里「这首有没有无损档」那一位（同 `NowPlayingView.metadata`）。
    /// `updateTime` 每 100ms 就叫一次，所以只有真的变了才请求重排。
    private func updateBadge() {
        let lossless = (player.streamFormat?.isLossless ?? (track?.losslessAvailable == true))
            && track != nil
        guard badgeView.isLossless != lossless else { return }
        badgeView.isLossless = lossless
        miniBar.isLossless = lossless
        needsLayout = true
    }

    private func updatePlayButton() {
        if player.isLoading {
            playButton.symbolName = "hourglass"
        } else {
            playButton.symbolName = player.isPlaying ? "pause.fill" : "play.fill"
        }
        let help = player.isPlaying ? "暂停" : "播放"
        playButton.toolTip = help
        playButton.setAccessibilityLabel(help)
    }

    private func updateShuffle() {
        shuffleButton.showsActiveDisc = player.isShuffled && track != nil
    }

    private func updateRepeat() {
        repeatButton.symbolName = player.repeatMode == .one ? "repeat.1" : "repeat"
        repeatButton.showsActiveDisc = player.repeatMode != .off && track != nil
    }

    private func updateTime(_ time: TimeInterval) {
        let duration = player.duration
        progressBar.progress = duration > 0 ? min(time / duration, 1) : 0
        progressBar.setAccessibilityValue(duration > 0 ? "\(time.mmss) / \(duration.mmss)" : "--:--")
        elapsedLabel.stringValue = duration > 0 ? time.mmss : "--:--"
        let remaining = duration - time
        remainingLabel.stringValue = (duration > 0 && remaining >= 0) ? "-" + remaining.mmss : "--:--"
        updateBadge()
    }
}

// MARK: - 封面模糊衬底

/// 控件区底下那一层：**封面自己的模糊副本**（[实测] `artworkBlur` +80 = 私有嵌套类
/// `MPContentView.BlurView`，miniplayer spec §11.8.5）。几何见
/// `MusicMetrics.MiniPlayerWindow.artworkBlurHeight`。
///
/// 原版就一层加一枚滤镜：`layer.contents` 是封面本身、`contentsRect = (0, 0, 1, h/w)`
/// 只取源图**底片**那一条（[PX] 标定过取的是底不是顶），层上挂一枚
/// `CAFilter(kCAFilterVariableBlur)`——radius **10** + 一张 1×225 的`clear → white`
/// 竖向 mask，于是自上而下由清到糊；再叠一层 1×255 的 `clear → black 0.3` 子层压暗。
/// 顶边因此能和上方没动过的封面无缝接上，底边（控件那一带）最糊也最暗，
/// **「浅色封面下控件也看得清」就是这一层**。
///
/// `kCAFilterVariableBlur` 是私有 API，这里按 spec 的「复刻要点」走公开等价物：
/// 底片切出来交给 `CIMaskedVariableBlur`（同样是「遮罩亮度调制半径」）当场烘成一张图
/// 贴回 `layer.contents`，压暗那层照旧是`CAGradientLayer`。
///
/// **为什么不再走 `backgroundFilters`**（糊「画在它背后的那张封面」）：观感能出来，
/// 但滤镜参数的坐标系（点还是设备像素）没有文档、只能试；而且背景滤镜是合成器对背后
/// 那块内容做的，层自己的 `alphaValue` 压不住它，rollover 淡出还得单独把半径动画到 0。
/// 自己烘图两头都确定：半径按 backing scale 换算，淡出就是普通的 alpha。
///
/// **历史**：早前用 `.behindWindow` 给封面挖透明，控制区糊出来的是**桌面**，与专辑毫无关系
/// （用户实机截图打回）；后来换成一条高 148 的黑色渐变，又丢了「封面内容糊在进度条底下」
/// 这个事实（原版录屏里看得一清二楚）。两次都记在 `artworkBlurTopOffset` 那条注释里。
@MainActor
private final class MPArtworkBlurView: NSView {

    private typealias M = MusicMetrics.MiniPlayerWindow

    /// [实测] `BlurView.sourceImage`（+8），由大封面的`onAssignBlock` 喂进来（§11.8.4）。
    var sourceImage: CGImage? {
        didSet {
            guard sourceImage !== oldValue else { return }
            renderedKey = nil
            renderIfNeeded()
        }
    }

    /// [实测] 压暗子层：`clear → black(0.3)`，到半高压满，之后铺满剩下的一半。
    private let dimming = CAGradientLayer()
    /// 烘好的那张图对应的输入（源图 + 像素尺寸），两者都没变就不重烘。
    private var renderedKey: (source: CGImage, size: CGSize)?
    private let ciContext = CIContext()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        // 烘出来的图就是本视图的像素尺寸，一比一贴上去。
        layer?.contentsGravity = .resize
        dimming.colors = [NSColor(white: 0, alpha: 0).cgColor,
                          NSColor(white: 0, alpha: M.artworkBlurDimming).cgColor]
        // ★ `CAGradientLayer` 的单位坐标里 **y=0 是下沿**（离线实测：起点 (0.5, 0) 时
        // 起色出现在底行，翻转/不翻转的宿主里一样），所以起点要写在 y=1 那一头，
        // 才是「上沿全透明、往下到 `artworkBlurDimmingRampEnd` 压满」——与模糊同向。
        // 上一版按「y=0 是上沿」写，压暗是**倒过来**的。
        dimming.locations = [0, NSNumber(value: Double(M.artworkBlurDimmingRampEnd))]
        dimming.startPoint = CGPoint(x: 0.5, y: 1)
        dimming.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(dimming)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 纯装饰，不吃鼠标——底下是封面，拖它就是拖窗。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // [实测] `setFrameSize:` 尾段：把第一个子层（纱罩）的 frame 同步成`layer.bounds`。
        dimming.frame = bounds
        CATransaction.commit()
        renderIfNeeded()
    }

    /// [实测] `BlurView.viewDidChangeEffectiveAppearance`：深浅色一变就把`sourceImage`
    /// 原样重设一遍重取一次 CGImage（模板/动态色封面才有区别）。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderedKey = nil
        renderIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderedKey = nil
        renderIfNeeded()
    }

    /// 把封面底片烘成「自上而下 0 → 满」的变半径模糊图，贴进 `layer.contents`。
    private func renderIfNeeded() {
        let scale = window?.backingScaleFactor ?? 2
        let px = CGSize(width: (bounds.width * scale).rounded(),
                        height: (bounds.height * scale).rounded())
        // [实测] `setFrameSize:` 里高 ≤ 0 直接跳过。
        guard px.width > 0, px.height > 0, let source = sourceImage else {
            layer?.contents = nil
            renderedKey = nil
            return
        }
        if let key = renderedKey, key.source === source, key.size == px { return }

        // ① 底片：[实测] `contentsRect = (0, 0, 1, h/w)`——源图最下面、与本视图同宽高比的那一条。
        let fraction = min(1, px.height / px.width)
        let sliceHeight = max(1, (CGFloat(source.height) * fraction).rounded())
        let crop = CGRect(x: 0, y: CGFloat(source.height) - sliceHeight,
                          width: CGFloat(source.width), height: sliceHeight)
        guard let slice = source.cropping(to: crop),
              let gradient = CIFilter(name: "CILinearGradient"),
              let blur = CIFilter(name: "CIMaskedVariableBlur") else { return }

        // ② 拉到本视图的像素尺寸（原版靠 `contentsGravity = .resizeAspectFill` 做同一件事）。
        let source0 = CIImage(cgImage: slice)
        let scaled = source0.transformed(by: CGAffineTransform(
            scaleX: px.width / source0.extent.width, y: px.height / source0.extent.height))
        let rect = CGRect(origin: .zero, size: px)

        // ③ 遮罩：CI 的原点在左下，所以白（满半径）在**下沿**，往上到
        //    `artworkBlurRampEnd` 那一档转黑（不糊）；`CILinearGradient` 两端各自延伸出去，
        //    正好等价于原版那张「画到 2/3 处再把末色铺满」的渐变图。
        gradient.setValue(CIVector(x: 0, y: px.height * (1 - M.artworkBlurRampEnd)), forKey: "inputPoint0")
        gradient.setValue(CIColor.white, forKey: "inputColor0")
        gradient.setValue(CIVector(x: 0, y: px.height), forKey: "inputPoint1")
        gradient.setValue(CIColor.black, forKey: "inputColor1")
        // ★ 遮罩必须裁成有限矩形：`CILinearGradient` 的输出 extent 是无限的，
        //   直接喂进去输出也无限，合成器渲染不出来——那一块就成了一个纯透明的洞
        //   （用户实机打回：「这个框内容都没了」）。
        guard let mask = gradient.outputImage?.cropped(to: rect) else { return }

        blur.setValue(scaled.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(mask, forKey: "inputMask")
        // [实测] radius 10 是**点**；CI 这一路的输入是像素图，所以按 backing scale 换算。
        blur.setValue(M.artworkBlurRadius * scale, forKey: kCIInputRadiusKey)
        guard let output = blur.outputImage?.cropped(to: rect),
              let baked = ciContext.createCGImage(output, from: rect) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = baked
        layer?.contentsScale = scale
        CATransaction.commit()
        renderedKey = (source, px)
    }
}

// MARK: - 封面

/// 方形顶块那张封面。`CALayer` + `contentsGravity = .resizeAspectFill`
/// ——`NSImageView` 只有 aspect-fit，而这里要的是「按短边填满、长边溢出的部分裁掉」。
///
/// **自始至终不透明**。文字底下那层模糊归 `MPArtworkBlurView`（在浮层里），不在这一层——
/// 早前这里挂过 `layer.mask` 把下部挖透明，见那个类型的注释。
@MainActor
private final class MPCoverView: NSView {

    private typealias M = MusicMetrics.MiniPlayerWindow

    private let artwork = CALayer()
    private let placeholder = CAGradientLayer()
    private let placeholderGlyph = NSImageView()
    private var loadTask: Task<Void, Never>?
    private var requestedURL: String?

    /// [实测] `largeArtwork.onAssignBlock`（§11.8.4）：封面一落地（含清空）就把 CGImage
    /// 转出去。顶块那张接的是模糊衬底 `MPArtworkBlurView.sourceImage`。
    var onAssign: ((CGImage?) -> Void)?

    /// 静息层那颗 42pt 小封面要圆角；顶块那张铺满窗口的不要。
    /// [推] 4pt——`AMPArtworkLockup.style` 的 case 名未解（spec §11.6 的`[缺口]`）。
    var cornerRadius: CGFloat = 0 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        placeholder.startPoint = CGPoint(x: 0, y: 1)
        placeholder.endPoint = CGPoint(x: 1, y: 0)
        layer?.addSublayer(placeholder)
        artwork.contentsGravity = .resizeAspectFill
        artwork.masksToBounds = true
        artwork.isHidden = true
        layer?.addSublayer(artwork)

        placeholderGlyph.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .regular))
        placeholderGlyph.contentTintColor = NSColor(white: 1, alpha: 0.75)
        addSubview(placeholderGlyph)

        // 封面是窗口背景那一层：不吃鼠标，拖它就是拖窗（`isMovableByWindowBackground`）。
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholder.frame = bounds
        artwork.frame = bounds
        CATransaction.commit()
        // 占位字形按格子大小缩：顶块那张 44，静息层那颗 42pt 的只有 ~19。
        let glyph = min(44, bounds.height * 0.45)
        placeholderGlyph.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: glyph * 0.64, weight: .regular))
        placeholderGlyph.frame = NSRect(x: (bounds.width - glyph) / 2,
                                        y: (bounds.height - glyph) / 2,
                                        width: glyph, height: glyph)
    }

    func setArtwork(url: String?, tint: NSColor, points: CGFloat) {
        placeholder.colors = [tint.withAlphaComponent(0.85).cgColor,
                              NSColor(Color.amberPurple).withAlphaComponent(0.55).cgColor]
        let request = ArtworkSize.url(url, points: points)
        // 「没有封面」这一路每次都走到底，别拿 `nil == nil` 当「没变」——那样上一首的
        // 封面会留在层上（同 `MiniArtworkView.setArtwork`）。
        guard request != requestedURL || request == nil else { return }
        requestedURL = request
        artwork.contents = nil
        artwork.isHidden = true
        placeholderGlyph.isHidden = false
        onAssign?(nil)
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let image = await ImageCache.shared.image(for: request)
            guard let self, !Task.isCancelled, self.requestedURL == request,
                  let image else { return }
            // 贴 CGImage 而不是 NSImage，理由同 `CatalogArtworkView.showArtwork`。
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.artwork.contents = cgImage ?? image
            self.artwork.isHidden = false
            CATransaction.commit()
            self.placeholderGlyph.isHidden = true
            self.onAssign?(cgImage)
        }
    }
}

// MARK: - 迷你横条的静息层

/// 迷你横条（组 I）指针离开之后露出来的那一层：**42pt 小封面 + 紧挨着它的标题/艺人**。
///
/// [实测] miniplayer spec §11.3 的三条约束：
///
/// ```
/// artwork.alignLeadingWith(self, offset: 16)           // artworkMargin
/// artwork.separateTopEdgesByAtLeast(16, to: self)      // 同一个 16
/// titlePlatter.touchLeadingAgainst(artwork)            // ★ 组 II 时这条换成「贴内容左边 4」
/// titlePlatter.alignTrailingWith(self, offset: −18)    // compactMetrics 的 m0
/// titlePlatter.centerVerticallyWith(artwork)
/// ```
///
/// 与控件层（`overlay`）互补：`rollState` 一变两层反向淡，所以窗里永远只见一层。
/// 字色走语义色不写死白——组 I 的 `appearance` 是`nil`（跟随系统外观，§11.6）。
@MainActor
private final class MPMiniBarView: NSView {

    private typealias M = MusicMetrics.MiniPlayerWindow

    private let artwork = MPCoverView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    /// [PX] 静息行右端那一枚无损徽标：**只有波形字形，没有「无损」两个字**
    /// （时间行中间那一枚才带字，且只在方形态出现）。
    private let badge = MPBadgeView(showsLabel: false)

    /// 有没有无损档。显隐只看这一位——静息行本身已经由 rollover 管住了。
    var isLossless = false {
        didSet {
            guard isLossless != oldValue else { return }
            badge.isHidden = !isLossless
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        artwork.cornerRadius = 4
        addSubview(artwork)
        badge.isHidden = true
        addSubview(badge)
        titleField.font = .systemFont(ofSize: M.titleSize, weight: .semibold)
        titleField.textColor = .labelColor
        subtitleField.font = .systemFont(ofSize: M.subtitleSize)
        subtitleField.textColor = .secondaryLabelColor
        for field in [titleField, subtitleField] {
            field.lineBreakMode = .byTruncatingTail
            field.usesSingleLineMode = true
            field.cell?.truncatesLastVisibleLine = true
            addSubview(field)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 里面是从**上沿**往下排的（`separateTopEdgesByAtLeast`），与浮层相反。
    override var isFlipped: Bool { true }

    /// 纯展示层：不吃鼠标，拖它就是拖窗（同封面）。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let size = M.artworkSize
        artwork.frame = NSRect(x: M.artworkMargin, y: M.artworkMargin, width: size, height: size)

        let left = artwork.frame.maxX + M.miniBarTitleSpacing
        // 徽标钉在右端、与小封面同一条中线；文字列到它之前收住。
        var right = bounds.width - M.outerMargin
        if !badge.isHidden {
            let size = badge.fittingSize
            badge.frame = NSRect(x: right - size.width, y: artwork.frame.midY - size.height / 2,
                                 width: size.width, height: size.height)
            right -= size.width + M.accessorySpacing
        }
        let width = max(0, right - left)
        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        let subtitleHeight = ceil(subtitleField.intrinsicContentSize.height)
        let block = titleHeight + M.metadataLineSpacing + subtitleHeight
        // 两行整体与小封面竖向居中（`centerVerticallyWith(artwork)`）。
        let top = artwork.frame.midY - block / 2
        titleField.frame = NSRect(x: left, y: top, width: width, height: titleHeight)
        subtitleField.frame = NSRect(x: left, y: top + titleHeight + M.metadataLineSpacing,
                                     width: width, height: subtitleHeight)
    }

    func update(track: Track?) {
        guard let track else {
            artwork.setArtwork(url: nil, tint: .amberSidebarAccent, points: ArtworkSize.header)
            titleField.stringValue = "未在播放"
            subtitleField.stringValue = ""
            needsLayout = true
            return
        }
        artwork.setArtwork(url: track.artworkURL, tint: NSColor(Color.tint(for: track.kind)),
                           points: ArtworkSize.inlineAvatar)
        titleField.stringValue = track.title
        subtitleField.stringValue = track.albumName.isEmpty
            ? track.artistName
            : "\(track.artistName) — \(track.albumName)"
        needsLayout = true
    }
}

// MARK: - 图标键

/// 传输键。字形纯白、无边框；开启态（随机/循环）在字形底下垫一颗
/// [PX] 32pt 的半透明白圆盘——Music 用的是拿不到的 `shuffle.and.dot` 一族自定义符号，
/// 但这扇窗实测就是圆盘，不是圆点。
@MainActor
private class MPIconButton: NSButton {

    var onClick: (() -> Void)?

    var symbolName = "" { didSet { applySymbol() } }
    var pointSize: CGFloat = 13 { didSet { applySymbol() } }
    /// 开启态的圆盘
    var showsActiveDisc = false { didSet { needsDisplay = true } }
    /// 圆盘颜色。由 `updateOverlayAppearance()` 按形态给（§11.6）。
    var discColor: NSColor = NSColor.labelColor
        .withAlphaComponent(MusicMetrics.MiniPlayerWindow.transportActiveOpacity) {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .shadowlessSquare
        imagePosition = .imageOnly
        // 字号已经是视觉大小，命中盒比它大；默认的 `.scaleProportionallyDown`
        // 会在盒子偏小时偷偷把字形缩掉。
        imageScaling = .scaleNone
        title = ""
        // 语义色：外观由 `overlay.appearance` 说了算（§11.6），不写死白。
        contentTintColor = .labelColor
        target = self
        action = #selector(clicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clicked() { onClick?() }

    private func applySymbol() {
        guard !symbolName.isEmpty else { return }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsActiveDisc {
            let size = MusicMetrics.MiniPlayerWindow.transportActiveDiameter
            let rect = NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2,
                              width: size, height: size)
            discColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        super.draw(dirtyRect)
    }
}

/// ☆ / ⋯ 两颗：字形纯白，底下**恒有**一颗 [PX] 26pt 的半透明白圆盘。
@MainActor
private final class MPCircleButton: MPIconButton {

    override func draw(_ dirtyRect: NSRect) {
        let size = MusicMetrics.MiniPlayerWindow.accessorySize
        let rect = NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2,
                          width: size, height: size)
        // ☆ / ⋯ 只在组 II 起出现，那一档 `overlay.appearance` 是 vibrantDark →
        // `labelColor` 解析成白，与 [PX] 量到的白 0.42 一致。
        NSColor.labelColor
            .withAlphaComponent(MusicMetrics.MiniPlayerWindow.accessoryBackgroundOpacity).setFill()
        NSBezierPath(ovalIn: rect).fill()
        super.draw(dirtyRect)
    }
}

// MARK: - 音质徽标

/// 时间行正中那一枚「〰 无损」。曲目没有无损档时整块不占位——Music 同样什么都不画
/// （同 `NowPlayingView.badges`）。
@MainActor
private final class MPBadgeView: NSView {

    private typealias M = MusicMetrics.MiniPlayerWindow

    /// 显隐不归自己管：还要跟「浮层排不排得下全套」与一起判，落在
    /// `MiniPlayerContentView.layoutOverlay()` 里。
    var isLossless = false {
        didSet {
            guard isLossless != oldValue else { return }
            needsLayout = true
        }
    }

    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "无损")
    /// 静息行那一枚只画字形（[PX]）；时间行中间那一枚才带「无损」两个字。
    private let showsLabel: Bool

    init(showsLabel: Bool = true) {
        self.showsLabel = showsLabel
        super.init(frame: .zero)
        isHidden = true
        glyph.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: M.badgeIconSize, weight: .regular))
        glyph.contentTintColor = .labelColor
        glyph.imageScaling = .scaleNone
        addSubview(glyph)
        label.font = .systemFont(ofSize: M.timeSize)
        label.textColor = .labelColor
        if showsLabel { addSubview(label) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("音质：无损")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        let g = glyph.intrinsicContentSize
        guard showsLabel else { return g }
        let t = label.intrinsicContentSize
        return NSSize(width: g.width + M.badgeSpacing + t.width,
                      height: max(g.height, t.height))
    }

    override func layout() {
        super.layout()
        let g = glyph.intrinsicContentSize
        glyph.frame = NSRect(x: 0, y: (bounds.height - g.height) / 2,
                             width: g.width, height: g.height)
        guard showsLabel else { return }
        let t = label.intrinsicContentSize
        label.frame = NSRect(x: g.width + M.badgeSpacing, y: (bounds.height - t.height) / 2,
                             width: t.width, height: t.height)
    }
}

// MARK: - 进度条

/// 浮在封面上的进度条：两层 `CALayer`（未播白 0.22 / 已播纯白），按下即跟手、松手才 seek。
/// 没有复用 `MiniProgressView`：那一颗把底栏胶囊的`centerContentInset` / `progressBottom`
/// 一组 [AX] 常量焊死在 `layoutBars()` 里，搬到这里位置全是错的。
@MainActor
private final class MPProgressBar: NSView {

    private typealias M = MusicMetrics.MiniPlayerWindow

    var onScrub: ((Double) -> Void)?
    /// VoiceOver 的增减：按总时长的 ±5% 走。
    var onNudge: ((Double) -> Void)?

    var progress: Double = 0 {
        didSet {
            guard dragValue == nil, progress != oldValue else { return }
            layoutBars()
        }
    }

    private var hovering = false
    private var dragValue: Double?
    private let track = CALayer()
    private let played = CALayer()
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // CALayer 的颜色不随外观自动重解析，`updateColors()` 在
        // `viewDidChangeEffectiveAppearance` 里重取一次（§11.6 的外观切换会走到这里）。
        updateColors()
        layer?.addSublayer(track)
        layer?.addSublayer(played)

        // [HIG] 自绘的轨道在 AX 树里什么都不是，角色得自己报。
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("播放进度")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layoutBars()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        // `labelColor` 是动态色，取 cgColor 要在自己的外观下解析，否则拿到的是当前 App 外观那一档。
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.labelColor
                .withAlphaComponent(M.scrubberTrackOpacity).cgColor
            played.backgroundColor = NSColor.labelColor.cgColor
        }
    }

    private func layoutBars() {
        // [推] 悬浮时轨道长 2pt——录屏没拍到悬浮态，取「明显但不跳」的一档。
        let height = M.scrubberBarHeight + (hovering ? 2 : 0)
        let y = (bounds.height - height) / 2
        let width = max(0, bounds.width)
        let value = min(max(dragValue ?? progress, 0), 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = NSRect(x: 0, y: y, width: width, height: height)
        track.cornerRadius = height / 2
        played.frame = NSRect(x: 0, y: y, width: width * value, height: height)
        played.cornerRadius = height / 2
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    /// 悬浮态自己持有（AGENTS.md 界面层铁律 3）。
    private func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        layoutBars()
    }

    override func mouseDown(with event: NSEvent) {
        dragValue = value(at: event)
        layoutBars()
    }

    override func mouseDragged(with event: NSEvent) {
        dragValue = value(at: event)
        layoutBars()
    }

    override func mouseUp(with event: NSEvent) {
        let target = value(at: event)
        // 先 seek 再松开 `dragValue`：`seek` 会同步把进度推到目标点，
        // 反过来就是先把条摆回旧 `progress`、再跳过去。
        onScrub?(target)
        dragValue = nil
        layoutBars()
    }

    private func value(at event: NSEvent) -> Double {
        let point = convert(event.locationInWindow, from: nil)
        return min(max(point.x / max(1, bounds.width), 0), 1)
    }

    override func accessibilityPerformIncrement() -> Bool {
        onNudge?(0.05)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onNudge?(-0.05)
        return true
    }
}

// MARK: - 翻转容器

/// 浮层与抽屉两个容器都要 `isFlipped`。本类自己是 flipped（`isFlipped` 恒 true），
/// 但**子视图的坐标系不会跟着继承**——容器不翻，容器内部手排的 frame 就是自下而上，
/// 「传输键在最下沿」会整段倒过来渲染。
private final class MPFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 形态跳表与谓词

/// `MPContentView` 的十态机。全部来自`inspector 规格` §4.3 的**实测**跳表
/// 与位掩码谓词（不是从转移表反推的），纯函数，不碰任何视图状态——单元测试直接调。
///
/// | 组 | 空 | 歌词 | 队列 |
/// | --- | --- | --- | --- |
/// | I 迷你横条 | 0 | 1 | 2 |
/// | II 窗口化 | 3 | 5 | 4 |
/// | III 全窗口 | 6 | 8 | 7 |
enum MiniPlayerStates {

    /// （跳表）：索引 `state − 1`，`state ∈ 1…8`，越界→1。
    /// 实测 `[1→0, 2→1, 3→5, 4→5, 5→3, 6→8, 7→8, 8→6]`。
    static func afterLyricsClick(_ state: Int) -> Int {
        let table = [0, 1, 5, 5, 3, 8, 8, 6]
        guard state >= 1, state <= 8 else { return 1 }
        return table[state - 1]
    }

    /// （跳表）：索引 `state − 2`，`state ∈ 2…8`，越界→2。
    /// 实测 `[2→0, 3→4, 4→3, 5→4, 6→7, 7→6, 8→7]`。
    static func afterQueueClick(_ state: Int) -> Int {
        let table = [0, 4, 3, 4, 7, 6, 7]
        guard state >= 2, state <= 8 else { return 2 }
        return table[state - 2]
    }

    /// （跳表）：索引 `state − 1`，`state ∈ 1…5` → `[5,4,0,2,1]`，
    /// 越界→3。即组 I ⇄ 组 II 互转且保持面板不变（1↔5、2↔4、3↔0）。
    static func toggleGroup(_ state: Int) -> Int {
        let table = [5, 4, 0, 2, 1]
        guard state >= 1, state <= 5 else { return 3 }
        return table[state - 1]
    }

    /// `state < 9 && (290 >> state) & 1`，290 = 0b100100010 → {1,5,8}
    static func isLyricsOpen(_ state: Int) -> Bool {
        guard state >= 0, state < 9 else { return false }
        return (290 >> state) & 1 == 1
    }

    /// `state < 8 && (148 >> state) & 1`，148 = 0b10010100 → {2,4,7}
    static func isQueueOpen(_ state: Int) -> Bool {
        guard state >= 0, state < 8 else { return false }
        return (148 >> state) & 1 == 1
    }

    /// `state < 9 && (502 >> state) & 1`，502 = 0b111110110 →
    /// {1,2,4,5,6,7,8} = 全集减两个空态 {0,3}（组 III 的空态 6 仍在集合里，
    /// 因为全窗口本身就是大形态）。抽屉的显隐判据就是它。
    static func isBig(_ state: Int) -> Bool {
        guard state >= 0, state < 9 else { return false }
        return (502 >> state) & 1 == 1
    }

    /// `state ∈ {3…8}`——组 II 起才有动作工具条（=`showActionToolbar`）。
    static func isWindowed(_ state: Int) -> Bool { (3...8).contains(state) }

    /// `state ∈ {6,7,8}`——全窗口（Music 口径的「沉浸」）。
    static func isFullWindow(_ state: Int) -> Bool { (6...8).contains(state) }

    /// [实测] miniplayer spec §11.7 尾段实测的一行：
    /// `inspectorContainer.queue.displayStyle = (state ∈ {6,7,8}) ? 3 : ((state ∈ {3…8}) ? 1 : 2)`
    /// ——全窗口 3、窗口化 1、迷你横条 2，**无条件**跟着形态写（不受掩码 219 那道闸管）。
    ///
    /// 三档各自改了什么外观规格没坐实（`playqueue 规格` §3 里没有读取点），
    /// 所以只把写入侧接上，见 `PlayQueueViewController.displayStyle`。
    static func queueDisplayStyle(_ state: Int) -> Int {
        if isFullWindow(state) { return 3 }
        return isWindowed(state) ? 1 : 2
    }

    /// （miniplayer spec §11.3 的可见性收尾）：
    /// `artwork.isHidden = !( !big && !rolloverShouldBeVisible && hasContentToShow )`。
    /// 即**小封面只在「迷你横条 + 没在 rollover + 有内容」时露脸**——
    /// Amber 把「紧挨着它的标题盘」一起算进这一层（静息层 `MPMiniBarView`）。
    static func showsSmallArtwork(state: Int, rolloverVisible: Bool, hasContent: Bool) -> Bool {
        !isWindowed(state) && !rolloverVisible && hasContent
    }

    /// miniplayer spec §11.5 ③ 的等价物：过渡带里三条纵向偏移按 `progress` 线性插值。
    ///
    /// Music 插的是四条 platter 间距（`compactMetrics (18,14,0,16)` ⇄
    /// `largeArtMetrics (16,18,16,18)`，`spacingConstraints` 四个 weak 槽）；Amber 是手排 frame，
    /// 插的是这四条间距在版面上的落点——[PX] 实测的收起/展开两组「距顶块下沿」。
    /// 两端与旧实现逐条相同，中间不再是到点一跳。
    static func overlayOffsets(progress: CGFloat)
        -> (transport: CGFloat, scrubber: CGFloat, time: CGFloat) {
        let M = MusicMetrics.MiniPlayerWindow.self
        let p = min(max(progress, 0), 1)
        func lerp(_ from: CGFloat, _ to: CGFloat) -> CGFloat { from + (to - from) * p }
        return (transport: lerp(M.collapsedTransportCenterFromBottom, M.transportCenterFromBottom),
                scrubber: lerp(M.collapsedScrubberCenterFromBottom, M.scrubberCenterFromBottom),
                time: lerp(M.collapsedTimeRowCenterFromBottom, M.timeRowCenterFromBottom))
    }

    /// 宽度 > 600 的形态升表（6 项实测）：`[0→6, 1→8, 2→7, 3→6, 4→7, 5→8]`；
    /// 已经是 {6,7,8} 或越界的原样返回。
    static func promotedToFullWindow(_ state: Int) -> Int {
        let table = [6, 8, 7, 6, 7, 8]
        guard state >= 0, state <= 5 else { return state }
        return table[state]
    }

    /// 降表：`{6,7,8} → state − 3`，其余原样。与升表互为逆映射。
    static func demotedFromFullWindow(_ state: Int) -> Int {
        isFullWindow(state) ? state - 3 : state
    }

    /// [实测] 底衬样式的判据（miniplayer spec §11.8.1/§11.8.2）：
    ///
    /// - 组 III（全窗口 `{6,7,8}`）走`(1, readFromPrefs: false)`
    ///   ——**强制 1、不看偏好**；
    /// - 其余形态走 `(0, readFromPrefs: true)`，样式 =`miniplayer_backdrop`。
    ///
    /// 工厂只有一处 `== 1` 的比较（负面证据），**取值域就此关死**：
    /// 1 = Metal 封面背景，其余（含没设过的 0 与任何越界值）= 系统毛玻璃。
    static func backdropStyle(state: Int, preference: Int) -> Int {
        if isFullWindow(state) { return 1 }
        return preference == 1 ? 1 : 0
    }
}

// MARK: - 底衬样式的偏好

extension UserDefaults {
    /// [实测] `NSUserDefaults(Music).miniplayer_backdrop`（→
    /// `integerForKey("miniplayer_backdrop")`，键名字面量实测 19 字节）。
    ///
    /// 写成 `@objc dynamic` 是为了能对它下 KVO——原版`init` 里那句
    /// `UserDefaults.standard.observe(keyPath, options: .new)` 观察的就是它，
    /// 观察句柄存 `debugBgObserver`。字段名（`debugBg…`）也说明了它的身份：
    /// **一条热生效的调试开关**，没设过就是 0。
    @objc dynamic var miniplayer_backdrop: Int {
        integer(forKey: "miniplayer_backdrop")
    }
}

// MARK: - ⋯ 菜单顶上的「正在播放」头

/// 封面 + 标题 + 「艺人 — 专辑」，摆在迷你窗 ⋯ 菜单的第一项上。
///
/// [PX] 2026-09-09 Music 实拍（2x 抓帧折半）：菜单宽 232、封面 36 见方、左内缩 15、
/// 封面与文字间距 10。字号用系统菜单字（`NSFont.menuFont`）与它的 small 变体，
/// 与菜单里其余各项同源——实拍里这两行就是菜单字体的粗体与小号。
private final class MiniPlayerMenuHeaderView: NSView {

    /// 菜单会按最宽的一项定宽，这块是其中最宽的，所以它就是这份菜单的宽度。
    private static let width: CGFloat = 232
    private static let artworkSize: CGFloat = 36
    private static let inset: CGFloat = 15
    private static let gap: CGFloat = 10
    private static let verticalPadding: CGFloat = 8

    init(track: Track, artwork: CGImage?) {
        let height = Self.artworkSize + Self.verticalPadding * 2
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))

        let cover = NSImageView(frame: NSRect(x: Self.inset, y: Self.verticalPadding,
                                              width: Self.artworkSize, height: Self.artworkSize))
        cover.imageScaling = .scaleProportionallyUpOrDown
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 4
        cover.layer?.masksToBounds = true
        cover.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        if let artwork {
            cover.image = NSImage(cgImage: artwork,
                                  size: NSSize(width: Self.artworkSize, height: Self.artworkSize))
        }
        addSubview(cover)

        let textX = Self.inset + Self.artworkSize + Self.gap
        let textWidth = Self.width - textX - Self.inset
        let title = Self.label(track.title, font: .menuFont(ofSize: 0), color: .labelColor)
        let subtitleText = track.albumName.isEmpty
            ? track.artistName
            : "\(track.artistName) — \(track.albumName)"
        let subtitle = Self.label(subtitleText,
                                  font: .menuFont(ofSize: NSFont.smallSystemFontSize),
                                  color: .secondaryLabelColor)
        // 两行贴着封面上下居中：各自按自身行高排，中间空 2。
        let titleHeight = ceil(title.intrinsicContentSize.height)
        let subtitleHeight = ceil(subtitle.intrinsicContentSize.height)
        let block = titleHeight + 2 + subtitleHeight
        let top = Self.verticalPadding + (Self.artworkSize - block) / 2
        subtitle.frame = NSRect(x: textX, y: top, width: textWidth, height: subtitleHeight)
        title.frame = NSRect(x: textX, y: top + subtitleHeight + 2,
                             width: textWidth, height: titleHeight)
        addSubview(title)
        addSubview(subtitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.truncatesLastVisibleLine = true
        return field
    }
}
