import AVKit
import AppKit
import Combine

/// 独立的「迷你播放器」窗（Music 的窗口 ▸ 迷你播放器 ⌥⌘M / 切换到迷你播放器 ⇧⌘M）。
///
/// 整只窗壳按 miniplayer 规格逐条复刻：
/// §2 `loadWindow` 的装配顺序、§3 的形态状态机、§4 的命令与响应链、§5 的工具条、§6 的持久化。
/// 窗里装的是 `MiniPlayerContentView`（对应 Music 的`MPContentView`）——
/// **迷你窗与整窗播放器共用同一个内容视图，形态差别只在 `currState`**（spec §0 结论 1）。
///
/// 形态编码（inspector spec §4.3）：组 I = 迷你横条 {0,1,2}、组 II = 窗口化 {3,5,4}、
/// 组 III = 全窗口 {6,8,7}、9 = 分离窗口单列；每组内 空 / 歌词 / 队列 三态同构。
/// 跳表与谓词都在 `MiniPlayerStates`（`MiniPlayerContentView.swift` 末尾的纯函数）。
///
/// **Amber 与 Music 的一处已知差异**：Music 的 `integrate_mini_player_with_immersion`
/// 这条 feature flag 开着时不装宽度上限、改由宽度驱动 `{0…5} ⇄ {6,7,8}` 的形态提升；
/// Amber 取 **flag 关**那条默认路径（不引入一个假 flag，见 `installWidthConstraints`），
/// 因此宽度死夹 320…600，组 III {6,7,8} 在 Amber 不可达，`windowWillResize` 里那条
/// 按 600 分界的宽度驱动路径不实现。跳表本身（`promotedToFullWindow` / `demotedFromFullWindow`）
/// 仍留在 `MiniPlayerStates` 并有单测覆盖——那是规格实测的表，将来打开这条路就用得上。
@MainActor
final class MiniPlayerWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {

    // MARK: - 窗口本体

    /// `Music.MiniPlayerWindowController.MiniPlayerWindow`（嵌套 NSWindow 子类，4 方法）。
    ///
    /// 唯一要覆写的是 `zoom(_:)`：spec §3.4 实测它是**空实现**——系统 zoom 不生效，
    /// 绿灯真正走的是 `windowShouldZoom(_:toFrame:)` + `windowWillUseStandardFrame(_:defaultFrame:)`
    /// 这两个 delegate（后者用临时约束反推内容尺寸，并保持窗口上边不动）。
    private final class MiniPlayerWindow: NSWindow {
        override func zoom(_ sender: Any?) {
            // [实测] 是空实现，故意不调 super。
        }
    }

    // MARK: - 常量

    /// spec §6：AppKit 自带的 frame 存档名，**带空格**（`"MiniPlayer frame"`，不是`"MiniPlayer"`）。
    private static let frameAutosaveName = "MiniPlayer frame"
    /// spec §1 `kStateKey`，与 §6 的关窗归档 / 启动迁移互为读写对。
    private static let stateKey = "miniPlayerState"
    /// spec §6：`encodeRestorableStateWithCoder:` 只编这一个矩形。
    private static let windowFrameKey = "windowFrame"
    /// [推] 音量滑杆的定宽。spec §5 只说 `pinWidth:` 定宽，没读出数值；
    /// 100 是 `NSSlider` 在工具条里既能拖得动、又不把其它件挤进溢出菜单的一档。
    private static let volumeSliderWidth: CGFloat = 100

    // MARK: - 字段（对应 spec §1）

    private let appState: AppState
    /// +8 `contents`，窗口的 contentView。
    private let contents: MiniPlayerContentView
    /// +104 `maxWidthConstraint`，只有 flag 关时才存在（Amber 恒存在，见类型注释）。
    private var maxWidthConstraint: NSLayoutConstraint?
    /// +40 `loadingViaWindowRestoration`。Amber 没接系统窗口恢复（不设`restorationClass`，
    /// 见 `loadWindow` 末尾的注释），所以这一位恒为 false；留着是为了让 §2 收尾那段
    /// 与规格同形，将来接上系统恢复时只要把它置起来。
    private var loadingViaWindowRestoration = false
    /// 正在「按 frame 反推形态」——这条路上不许再回头改 frame（见 `snapWindowToNaturalSize`）。
    private var applyingDerivedState = false
    /// +88 `lastShowWasDueToSwitch`。spec §4.1：没按 ⌥ 的「切换到迷你播放器」会把源窗收掉，
    /// 这一位记住「这次是切过来的」，关窗时据此把主窗放回来。
    var lastShowWasDueToSwitch = false
    /// +89 `windowIsClosing`。
    private var windowIsClosing = false
    /// +120 `resizingStartingState`，live resize 开始时的态。
    private var resizingStartingState = 0
    /// +128 `resizingDisplayedState`，resize 过程中已显示的态。
    private var resizingDisplayedState = 0
    /// +90 `showVolumeSlider`。spec §5 ★：didSet 会**整份换掉工具条项**。
    private var showVolumeSlider = false {
        didSet {
            guard showVolumeSlider != oldValue else { return }
            applyToolbarItemIdentifiers()
            refreshToolbarItems()
        }
    }
    /// +96 `airPlaySelector`，init 里直接 new。
    private let airPlaySelector = MiniPlayerRoutePickerView()

    private var cancellables = Set<AnyCancellable>()

    private let observers = TaskBag()
    /// `NSApplication` 没有公开的`isTerminating`，用`willTerminateNotification` 自己记一位：
    /// spec §6 要求「App 不在退出中」时才把状态归档回 UserDefaults。
    private var appIsTerminating = false

    /// 「切回主窗」：内容视图上的封面/展开键点下去时叫，关窗时若这次是切过来的也叫。
    /// 由 `AuxiliaryWindows` 接。
    var onSwitchToMainWindow: (() -> Void)?

    /// 菜单校验读这一位。**不会把窗建出来**（内容视图在 init 里就有了）。
    var currentState: Int { contents.currState }

    /// 菜单勾选态读这一位。
    var isVisible: Bool { window?.isVisible == true }

    // MARK: - 构造

    init(appState: AppState) {
        self.appState = appState
        self.contents = MiniPlayerContentView(appState: appState)
        super.init(window: nil)

        contents.onStateChanged = { [weak self] in self?.stateDidChange() }
        contents.onRollStateChanged = { [weak self] visible in self?.setChromeVisible(visible) }

        // 音量：滑杆的值与音量键的图像都跟着播放器走。
        observers.observeNow({ [appState] in appState.player.volume }) { [weak self] volume in
            self?.playerVolumeDidChange(volume)
        }

        NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.appIsTerminating = true }
            .store(in: &cancellables)

        buildWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - §2 窗口装配

    /// spec §2 `loadWindow`（397 条）逐条照搬。
    /// `windowNibName` 在 Music 里返回字面量`"notUsed"`——窗是纯代码搭的，没有 nib。
    ///
    /// **这里不能写成 `override func loadWindow()`**：`NSWindowController.init(window:)`
    /// 一调完就把自己标成「已载入」（实测：`init(window: nil)` 之后`isWindowLoaded == true`
    /// 而 `window == nil`），懒加载那条路根本不会触发，`showWindow` 里`guard let window`
    /// 直接空手而归——窗一辈子建不出来。所以改成 `init` 末尾主动建。
    /// 代价是 §6 那句「`isWindowLoaded` 为假就什么都不写」在 Amber 恒为真；保留它是为了与规格同形。
    private func buildWindow() {
        let M = MusicMetrics.MiniPlayerWindow.self

        // [实测] contentRect 300×100、styleMask =
        // Titled | Closable | Miniaturizable | Resizable | FullSizeContentView。
        let window = MiniPlayerWindow(
            contentRect: NSRect(origin: .zero, size: M.initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.contentView = contents

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // [RES] Music 的 `MINIPLAYER_WINDOW_TITLE` = "MiniPlayer"；Amber 用中文。
        // 标题栏上的字是藏起来的，这里的 title 是给窗口菜单/AX 用的。
        window.title = "迷你播放器"
        window.isMovableByWindowBackground = true
        window.isExcludedFromWindowsMenu = true
        window.autorecalculatesKeyViewLoop = true
        window.isRestorable = true
        // [实测] collectionBehavior = 512 = FullScreenNone：迷你窗口**不进**系统全屏。
        // （旧实现写的是 `.fullScreenAuxiliary`，与规格相反，已删。）
        window.collectionBehavior = .fullScreenNone
        // ⌘W / 红绿灯关掉之后这一份还要能再开回来（与主窗同一条理由）。
        window.isReleasedWhenClosed = false
        // Amber 切到后台时别自己消失——它的用处正是「盖在别的 App 上看着」。
        window.hidesOnDeactivate = false
        window.delegate = self

        // 先把 window 认下来：下面的 `restoreState(with:)` / `observeDefaults` 都读`self.window`。
        self.window = window
        // spec §2：`self.nextResponder = NSApp`。菜单命令实现在 AppDelegate 上（NSApp 之后），
        // 这一句让迷你窗当 key 时命令照样送得到。
        nextResponder = NSApp

        installWidthConstraints()
        // 竖向也有下限：Music 的迷你横条拖不动比它更矮（[PX] 实拍那扇最小窗 = 320 × 153.5）。
        // 宽度这边靠内容视图上的两条约束夹（spec §2 的 `limitWidthTo*`），高度没有对应约束——
        // 内容视图的高是手排的，不会自己顶住；所以这一条落在窗口的 `contentMinSize` 上。
        window.contentMinSize = NSSize(width: M.minWidth, height: M.collapsedContentHeight)

        window.layoutIfNeeded()
        // spec 是 `center()`；Amber 多一步「先按存档摆位」，与 MV 播放器窗同一手法 [推]：
        // 规格那边的落位靠系统窗口恢复，Amber 没接（见下），只剩 frame 存档这一条。
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        installToolbarIfNeeded()
        observeDefaults()

        migrateArchivedStateIfNeeded()

        // spec §2 收尾：不是窗口恢复期间的话，按当前 frame 反推初始形态。
        // Amber 不设 `restorationClass`（要`NSWindowRestoration` 那套类方法入口，
        // 主窗也没接），所以 `loadingViaWindowRestoration` 恒 false，这条恒走。
        if !loadingViaWindowRestoration {
            applyFormStateForCurrentFrame(animated: false)
            // `setFrameAutosaveName` 存回来的 frame 可能是旧版本留下的中间态
            //（没开面板、却比方形封面高，封面下面空一条灰）——开窗时纠一次。
            snapWindowToNaturalSize()
        }
    }

    /// 按当前 frame 反推形态并落地——spec §2 收尾那一步（`loadWindow` 末尾）。
    ///
    /// 用户拖窗走的是 `windowWillResize` + `windowDidEndLiveResize`（§3.3），
    /// **程序改尺寸不经过那条路**（`setFrame` / `setContentSize` 不发`windowWillResize:`），
    /// 所以建窗和窗口恢复之后要各叫一次。Music 同此：`loadWindow` 里那一句就是为
    /// `restoreStateWithCoder:` 刚`setFrame` 完的那种情形准备的。
    func applyFormStateForCurrentFrame(animated: Bool) {
        guard let window else { return }
        applyingDerivedState = true
        defer { applyingDerivedState = false }
        let frame = window.frame
        let form = Self.formState(width: frame.width, height: frame.height,
                                  startingState: contents.currState,
                                  miniBarPanelState: contents.miniBarPanelState,
                                  windowedPanelState: contents.windowedPanelState)
        // ★ 顺序：先落地形态，**再**喂 progress。`apply(state:)` 会把 progress 拉到 0/1 两端
        // （换态本来就是两端之间跳），窗口正停在过渡带里（h ∈ 200…250）时反过来会被抹平。
        contents.apply(state: form.state, animated: animated)
        contents.applyLargeArtworkProgress(form.progress)
    }

    /// spec §2「宽度约束」：最小宽无条件装；最大宽只在
    /// `os_feature_enabled("Music", "integrate_mini_player_with_immersion")` **关**时装。
    ///
    /// Amber 没有这条 feature flag，也不打算立一个假 flag 出来——**取规格里 flag 关的那条默认路径**，
    /// 即最大宽恒装。后果写在类型注释里：宽度死夹 320…600，组 III 不可达。
    private func installWidthConstraints() {
        let M = MusicMetrics.MiniPlayerWindow.self
        contents.limitWidthToMinimum(M.minWidth)
        maxWidthConstraint = contents.limitWidthToMaximum(M.maxWidth)
    }

    /// spec §2 的两条 KVO（`toolbarDefaultObserver` / `alwaysOnTopObserver`）。
    /// Amber 的偏好走 `AppSettings`，所以用同语义的 Combine 订阅：两条都要**实时**生效。
    private func observeDefaults() {
        observers.observe({ AppSettings.shared.values.miniPlayerOnTop }) { [weak self] onTop in
            self?.window?.level = Self.level(onTop: onTop)
        }
        // [实测] `miniPlayerAlwaysOnTop` 为真 →`window.level = 3` = `.floating`。
        window?.level = Self.level(onTop: AppSettings.shared.values.miniPlayerOnTop)

        observers.observe({ AppSettings.shared.values.useToolbarInMiniPlayer }) { [weak self] _ in
            self?.installToolbarIfNeeded()
        }
    }

    /// spec §6 + §2：一次性状态迁移。失败静默吞掉。
    private func migrateArchivedStateIfNeeded() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.stateKey) else { return }
        defer { defaults.removeObject(forKey: Self.stateKey) }
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return }
        // 归档里没有的 key 只想拿到 nil/空值，不想抛异常。
        coder.decodingFailurePolicy = .setErrorAndReturn
        restoreState(with: coder)
        contents.restoreState(with: coder)
        coder.finishDecoding()
    }

    /// `miniPlayerOnTop` → 窗口层级。`.floating` 就是规格里的`level = 3`
    /// （`NSWindow.Level` 里`.normal` = 0、`.floating` = 3）。
    static func level(onTop: Bool) -> NSWindow.Level {
        onTop ? .floating : .normal
    }

    // MARK: - 显示 / 关闭

    override func showWindow(_ sender: Any?) {
        guard let window else { return }
        window.level = Self.level(onTop: AppSettings.shared.values.miniPlayerOnTop)
        window.makeKeyAndOrderFront(sender)
        NSApp.activate()
    }

    func hide() {
        window?.close()
    }

    // MARK: - §3.2 形态状态机（纯函数）

    /// spec §3.2 的 `(width, height) -> (newState, progress)`。
    ///
    /// 入口两分支按 **`resizingStartingState`** 分流（不是按当前态）。
    /// `progress` 的去向是大封面的`alphaValue`——200→250 这 50pt 是它的线性淡入带。
    static func formState(width: CGFloat, height: CGFloat,
                          startingState: Int,
                          miniBarPanelState: Int,
                          windowedPanelState: Int) -> (state: Int, progress: CGFloat) {
        let M = MusicMetrics.MiniPlayerWindow.self
        // 分支 A —— 起始态 ∈ {1,2}（迷你横条且已开着某个面板）。
        if startingState == 1 || startingState == 2 {
            return (height >= M.miniBarPanelHeight ? miniBarPanelState : 0, 0)
        }
        // 分支 B —— 其余所有起始态。
        if height < M.collapseHeight { return (0, 0) }
        if height < M.expandHeight {
            return (3, (height - M.collapseHeight) / M.fadeBand)
        }
        // ★ 第三档的阈值是 **宽度 + 200**，不是常数 400（spec §3.2 的订正）。
        if height <= width + M.panelHeightOffset { return (3, 1) }
        return (windowedPanelState, 1)
    }

    /// live resize 时正被拖的边。
    ///
    /// spec 读的是 `NSWindow.liveResizeEdges`，掩码`& 5`——**bit N 对应`NSRectEdge(rawValue: N)`**，
    /// 即 5 = 0b101 = bit0(`.minX` = 左边) | bit2(`.maxX` = 右边)。
    /// 这个属性在公开 AppKit 头文件里查不到（NSWindow.h 无此声明，是私有接口），
    /// Amber 不碰私有 API，改由「宽度这一帧有没有变」推断：
    /// 只拖上/下边宽度不会变，拖左/右边或任一角都会变——与 `& 5 != 0` 同解。
    struct ResizeEdges: OptionSet, Sendable {
        let rawValue: UInt
        static let minX = ResizeEdges(rawValue: 1 << 0)
        static let minY = ResizeEdges(rawValue: 1 << 1)
        static let maxX = ResizeEdges(rawValue: 1 << 2)
        static let maxY = ResizeEdges(rawValue: 1 << 3)
        /// 规格里的掩码 5。
        static let horizontal: ResizeEdges = [.minX, .maxX]
    }

    /// 由「这一帧宽/高有没有变」推断正被拖的边，见 `ResizeEdges` 的注释。
    static func resizeEdges(proposed: NSSize, current: NSSize) -> ResizeEdges {
        var edges: ResizeEdges = []
        if proposed.width != current.width { edges.formUnion(.horizontal) }
        if proposed.height != current.height { edges.formUnion([.minY, .maxY]) }
        return edges
    }

    /// spec §3.3 ★ 方形锁：live resize 且**起始态与显示态都是 3**（窗口化空态）时，
    /// 只要命中左/右边就把宽高一起取 `max(w, h)`；只拖上下边不锁。
    static func squareLocked(proposed: NSSize, startingState: Int, newState: Int,
                             edges: ResizeEdges) -> NSSize {
        guard startingState == 3, newState == 3,
              !edges.intersection(.horizontal).isEmpty else { return proposed }
        let side = max(proposed.width, proposed.height)
        return NSSize(width: side, height: side)
    }

    // MARK: - §3.4 绿灯（纯函数）

    /// spec §3.4 `windowShouldZoom:toFrame:`。
    static func shouldZoom(currState: Int, newFrame: NSRect, currentFrame: NSRect) -> Bool {
        let windowed = MiniPlayerStates.isWindowed(currState)   // {3…8}
        let big = MiniPlayerStates.isBig(currState)             // {1,2,4,5,6,7,8}
        if big { return true }
        // 窗口化空态（3）= 方形态：只有正方形的目标才允许。
        if windowed { return newFrame.width == newFrame.height }
        // 迷你横条空态（0/9）：只允许往高了长。
        return newFrame.height >= currentFrame.height
    }

    /// spec §3.4 `windowWillUseStandardFrame:defaultFrame:` 的前半段：
    /// 算出内容视图要被临时钉成的宽/高（`height == nil` = 不加高度约束，组 {0,9}）。
    ///
    /// `chromeHeight` = `window.frameRect(forContentRect: .zero).height`（窗口 chrome 的高）。
    static func standardContentSize(currState: Int, defaultFrame: NSRect,
                                    chromeHeight: CGFloat) -> (width: CGFloat, height: CGFloat?) {
        let w = min(defaultFrame.width, MusicMetrics.MiniPlayerWindow.maxWidth)
        if MiniPlayerStates.isBig(currState) {
            return (w, defaultFrame.height - chromeHeight)
        }
        if MiniPlayerStates.isWindowed(currState) {
            let h = min(defaultFrame.height, w)
            return (h, h)   // 方形
        }
        return (w, nil)
    }

    /// spec §3.4 的后半段：**上边固定**——x 用当前 frame 的左边、y 由 maxY 减新高反推。
    static func standardFrame(currentFrame: NSRect, size: NSSize) -> NSRect {
        NSRect(x: currentFrame.minX, y: currentFrame.maxY - size.height,
               width: size.width, height: size.height)
    }

    // MARK: - §7 三个切换动作

    /// 「大封面」（⌥⌘A）：组 I ⇄ 组 II 互转且保持面板不变（`toggleGroup` 那张跳表）。
    func toggleLargeArtwork() { contents.toggleLargeArtwork() }

    /// 「待播清单」（⌥⌘U）。走内容视图自己的 `queueClicked`——它就是`afterQueueClick` 那张表。
    func toggleQueue() { contents.queueClicked() }

    /// 「歌词」（⌃⌘U）。同上，走 `afterLyricsClick`。
    func toggleLyrics() { contents.lyricsClicked() }

    // MARK: - NSWindowDelegate

    func windowWillStartLiveResize(_ notification: Notification) {
        resizingStartingState = contents.currState
        resizingDisplayedState = resizingStartingState
    }

    /// spec §3.3 分支 b（flag 关，Amber 的默认路径）。
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender.inLiveResize else { return frameSize }

        let form = Self.formState(width: frameSize.width, height: frameSize.height,
                                  startingState: resizingStartingState,
                                  miniBarPanelState: contents.miniBarPanelState,
                                  windowedPanelState: contents.windowedPanelState)
        contents.applyLargeArtworkProgress(form.progress)
        resizingDisplayedState = form.state

        return Self.squareLocked(
            proposed: frameSize,
            startingState: resizingStartingState,
            newState: form.state,
            edges: Self.resizeEdges(proposed: frameSize, current: sender.frame.size))
    }

    /// 松手之后要么落在一个**完整**形态上，要么弹回去——**没有中间态**。
    ///
    /// 用户实机打回的那一帧：窗比方形封面高、但又没高过 `宽 + 200`，于是抽屉没开、
    /// 封面下面空出一条灰玻璃。旧实现「拖成什么样就是什么样」正是这条缝的来源。
    ///
    /// 两档分开处理：
    /// - **开着面板**（态 1/2/4/5）：抽屉本来就可以是任意高度（下限 200），
    ///   把拖出来的高记成新的 `drawerHeight`，自然高随即等于当前帧高，下面那一步就是空操作。
    /// - **没开面板**（态 0/3）：自然高是唯一的（横条 154 / 方形 = 窗宽），
    ///   拖到一半松手就收回去对齐封面，动画与开合面板同一条（0.4s、上边不动）。
    func windowDidEndLiveResize(_ notification: Notification) {
        applyingDerivedState = true
        // 形态先落地：`stateDidChange` 那条 snap 这一段先按住，免得拿旧的抽屉高去算。
        contents.apply(state: resizingDisplayedState, animated: true)
        resizingStartingState = resizingDisplayedState
        applyingDerivedState = false

        guard let window else { return }
        // 窗是 `fullSizeContentView`，chrome 高一般就是 0；照旧按`frameRect(forContentRect:)`
        // 换算，别把「工具条那 52」当成 chrome（`contentLayoutRect` 是安全区，不是内容矩形）。
        let chrome = window.frameRect(forContentRect: .zero).height
        contents.rememberDrawerHeight(contentHeight: window.frame.height - chrome,
                                      width: window.contentLayoutRect.width)
        snapWindowToNaturalSize()
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        Self.shouldZoom(currState: contents.currState,
                        newFrame: newFrame, currentFrame: window.frame)
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let chromeHeight = window.frameRect(forContentRect: .zero).height
        let target = Self.standardContentSize(currState: contents.currState,
                                              defaultFrame: newFrame,
                                              chromeHeight: chromeHeight)
        // ★ 标准尺寸不是算出来的常量：把内容视图临时钉死，让 auto layout 反推出真实内容矩形。
        let content = contents.layoutFrame(width: target.width, height: target.height)
        let size = window.frameRect(forContentRect: content).size
        return Self.standardFrame(currentFrame: window.frame, size: size)
    }

    /// spec §6 第 4 条：关窗时把状态归档写回 `UserDefaults["miniPlayerState"]`，
    /// 与 `migrateArchivedStateIfNeeded()` 互为读写对。
    func windowWillClose(_ notification: Notification) {
        windowIsClosing = true
        // 这次是「切换到迷你播放器」切过来的（主窗被收掉了）：关掉它就得把主窗放回来，
        // 否则用户手上一扇窗都不剩。[推]——规格只记了这一位的写入点，没记消费方。
        if lastShowWasDueToSwitch {
            lastShowWasDueToSwitch = false
            onSwitchToMainWindow?()
        }
        guard !appIsTerminating else { return }
        let coder = NSKeyedArchiver(requiringSecureCoding: false)
        encodeRestorableState(with: coder)
        contents.encodeRestorableState(with: coder)
        UserDefaults.standard.set(coder.encodedData, forKey: Self.stateKey)
    }

    // MARK: - §6 持久化

    override func encodeRestorableState(with coder: NSCoder) {
        // spec §6：`isWindowLoaded` 为假就什么都不写。
        guard isWindowLoaded, let window else { return }
        super.encodeRestorableState(with: coder)
        coder.encode(window.frame, forKey: Self.windowFrameKey)
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        // spec §6：**非空才** setFrame。
        let frame = coder.decodeRect(forKey: Self.windowFrameKey)
        guard !frame.isEmpty else { return }
        window?.setFrame(frame, display: true)
    }

    // MARK: - §5 工具条

    /// 工具条项的标识符。规格里另有 `maximize` / `platter` / `modeSelect` 三个——
    /// spec §5 已坐实**它们不在任何一张列表里**（`allowsUserCustomization = false`、
    /// 也没有 autosave 名，AppKit 不会来要），是造得出来但上不了架的死分支，**不实现**。
    enum ToolbarID {
        static let action = NSToolbarItem.Identifier("action")
        static let lyrics = NSToolbarItem.Identifier("lyrics")
        static let queue = NSToolbarItem.Identifier("queue")
        static let airplay = NSToolbarItem.Identifier("airplay")
        static let volume = NSToolbarItem.Identifier("volume")
        static let volumeSlider = NSToolbarItem.Identifier("volumeSlider")
    }

    /// `toolbarDefaultItemIdentifiers:`（7 项，顺序实测）。
    static let defaultToolbarIdentifiers: [NSToolbarItem.Identifier] = [
        .flexibleSpace, ToolbarID.action, .space,
        ToolbarID.lyrics, ToolbarID.queue, ToolbarID.airplay, ToolbarID.volume,
    ]

    /// `toolbarAllowedItemIdentifiers:`（8 项）：同上，在`volume` 前多一个`volumeSlider`。
    static let allowedToolbarIdentifiers: [NSToolbarItem.Identifier] = [
        .flexibleSpace, ToolbarID.action, .space,
        ToolbarID.lyrics, ToolbarID.queue, ToolbarID.airplay,
        ToolbarID.volumeSlider, ToolbarID.volume,
    ]

    /// 音量条展开时替换用的那张（5 项）：歌词/队列/AirPlay 直接从条上撤掉。
    static let volumeExpandedToolbarIdentifiers: [NSToolbarItem.Identifier] = [
        .flexibleSpace, ToolbarID.action, .space,
        ToolbarID.volumeSlider, ToolbarID.volume,
    ]

    private var actionItem: NSToolbarItem?
    private var lyricsItem: NSToolbarItem?
    private var queueItem: NSToolbarItem?
    private var airplayItem: NSToolbarItem?
    private var volumeItem: NSToolbarItem?
    private var volumeSliderItem: NSToolbarItem?
    private let lyricsButton = NSButton()
    private let queueButton = NSButton()
    private let volumeSlider = NSSlider()

    /// spec §5：`use_toolbar_in_miniplayer` 为真时装 NSToolbar，为假时卸掉。
    private func installToolbarIfNeeded() {
        guard let window else { return }
        guard AppSettings.shared.values.useToolbarInMiniPlayer else {
            window.toolbar = nil
            // 安全区从 52（unified 工具条）变回 28（只有标题栏），三段要重排。
            contents.needsLayout = true
            return
        }
        guard window.toolbar == nil else { return }
        let toolbar = NSToolbar()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly              // [实测] 2
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified               // [实测] 3
        applyToolbarItemIdentifiers()
        refreshToolbarItems()
        contents.needsLayout = true
    }

    /// spec §5 ★ `showVolumeSlider` 的 didSet：整份换掉工具条项。
    ///
    /// Music 调的是 `setItemIdentifiers:`；macOS 15 起 AppKit 把它开成了可写属性
    /// `NSToolbar.itemIdentifiers`（`NSToolbar.h:159`），语义一致，直接用公开这一份。
    private func applyToolbarItemIdentifiers() {
        guard let toolbar = window?.toolbar else { return }
        toolbar.itemIdentifiers = showVolumeSlider
            ? Self.volumeExpandedToolbarIdentifiers
            : Self.defaultToolbarIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultToolbarIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.allowedToolbarIdentifiers
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem?
        switch itemIdentifier {
        case ToolbarID.action: item = makeActionItem()
        case ToolbarID.lyrics: item = makeLyricsItem()
        case ToolbarID.queue: item = makeQueueItem()
        case ToolbarID.airplay: item = makeAirPlayItem()
        case ToolbarID.volume: item = makeVolumeItem()
        case ToolbarID.volumeSlider: item = makeVolumeSliderItem()
        default: item = nil
        }
        // [实测] 所有 item 的 visibilityPriority = 2000 = `.high`。
        item?.visibilityPriority = .high
        return item
    }

    private func makeActionItem() -> NSToolbarItem {
        if let actionItem { return actionItem }
        let item = NSToolbarItem(itemIdentifier: ToolbarID.action)
        item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多")
        item.label = "更多"
        item.target = self
        item.action = #selector(doActionButton(_:))
        actionItem = item
        return item
    }

    private func makeLyricsItem() -> NSToolbarItem {
        if let lyricsItem { return lyricsItem }
        let item = NSToolbarItem(itemIdentifier: ToolbarID.lyrics)
        configureToggle(lyricsButton, symbol: "quote.bubble",
                        action: #selector(doLyricsButton(_:)))
        item.view = lyricsButton
        item.label = "歌词"
        // [实测] AX 标签 `AX_PLAYER_LYRICS_BUTTON`（默认值`Lyrics`）。
        item.toolTip = "歌词"
        lyricsButton.setAccessibilityLabel("歌词")
        lyricsItem = item
        return item
    }

    private func makeQueueItem() -> NSToolbarItem {
        if let queueItem { return queueItem }
        let item = NSToolbarItem(itemIdentifier: ToolbarID.queue)
        configureToggle(queueButton, symbol: "list.bullet",
                        action: #selector(doQueueButton(_:)))
        item.view = queueButton
        item.label = "待播清单"
        // [实测] AX 标签 `AX_PLAYER_QUEUE_BUTTON`（默认值`playing next`）。
        item.toolTip = "待播清单"
        queueButton.setAccessibilityLabel("待播清单")
        queueItem = item
        return item
    }

    /// 歌词 / 队列这两颗是**带选中态的独立按钮**（不是 `modeSelect` 那个分段控件，
    /// 那一个上不了架）。选中态用系统的 push-on/push-off，不自绘。
    private func configureToggle(_ button: NSButton, symbol: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.bezelStyle = .toolbar
        button.setButtonType(.pushOnPushOff)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
    }

    private func makeAirPlayItem() -> NSToolbarItem {
        if let airplayItem { return airplayItem }
        let item = NSToolbarItem(itemIdentifier: ToolbarID.airplay)
        item.view = airPlaySelector
        item.label = "AirPlay"
        airplayItem = item
        return item
    }

    private func makeVolumeItem() -> NSToolbarItem {
        if let volumeItem { return volumeItem }
        let item = NSToolbarItem(itemIdentifier: ToolbarID.volume)
        item.label = "音量"
        item.target = self
        item.action = #selector(doVolumeButton(_:))
        volumeItem = item
        return item
    }

    private func makeVolumeSliderItem() -> NSToolbarItem {
        if let volumeSliderItem { return volumeSliderItem }
        let item = NSToolbarItem(itemIdentifier: ToolbarID.volumeSlider)
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.doubleValue = appState.player.volume
        volumeSlider.controlSize = .small
        // [实测] `trackFillColor = NSColor.labelColor`。
        volumeSlider.trackFillColor = .labelColor
        volumeSlider.target = self
        volumeSlider.action = #selector(doVolumeSliderChanged(_:))
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.widthAnchor.constraint(equalToConstant: Self.volumeSliderWidth).isActive = true
        item.view = volumeSlider
        item.label = "音量"
        volumeSliderItem = item
        return item
    }

    /// 形态一变，工具条上跟着形态走的那几件（动作键显隐、歌词/队列选中态）就要刷新。
    private func stateDidChange() {
        refreshToolbarItems()
        snapWindowToNaturalSize()
    }

    /// 开合歌词/待播时**把窗口长高／收矮**，而不是在窗内挤占封面。
    ///
    /// inspector spec §4.4 的动画块就是这么干的：算出内容视图的自然矩形、
    /// `r.origin.y = CGRectGetMaxY(window.frame) − r.height` 把**上边钉住**，
    /// 再 `window.animator().setFrame(_, display: true)`——所以面板是从下沿往下长出来的。
    /// 早前只改了内部布局，窗口尺寸没动，看着就是「封面被面板挤扁」（用户实机打回）。
    ///
    /// 两种情况**不能**snap，否则会跟别人抢方向盘：
    /// - live resize 期间（用户正拖着边），形态由 `windowWillResize` 那条路管；
    /// - 由 frame 反推形态时（建窗、窗口恢复、`-minisize`），本来就是「先有 frame 后有态」。
    private func snapWindowToNaturalSize() {
        guard let window, !window.inLiveResize, !applyingDerivedState else { return }
        var target = contents.naturalContentSize(forWidth: window.contentLayoutRect.width)
        // [实测] §11.1 的 `drawerHeight` 初值是 600，方形封面之上再加它就可能高过屏幕；
        // Music 也没有这条夹子（窗口可以越界），但越界的窗口用户拖不回来，这里夹一次可见区。
        if let visible = window.screen?.visibleFrame.height {
            let chrome = window.frameRect(forContentRect: .zero).height
            target.height = min(target.height, visible - chrome)
        }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        guard abs(frame.height - window.frame.height) > 0.5 else { return }
        frame.origin.x = window.frame.minX
        // ★ 上边不动
        frame.origin.y = window.frame.maxY - frame.height
        // 窗还没上屏时不做中间帧（开窗那次纠偏走的就是这条）。
        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && window.isVisible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? MusicMetrics.MiniPlayerWindow.stateAnimationDuration : 0
            (animated ? window.animator() : window).setFrame(frame, display: true)
        }
    }

    /// rollover 淡出时把窗口 chrome（红绿灯 + 工具条）一起淡掉。
    ///
    /// spec 只记了内容视图那一层的 `rollState`，这一条是 [实测] §11.3 的几何逼出来的 [推]：
    /// 迷你横条的小封面钉在「距内容顶 ≥ 16」、边长 42，占的正是工具条那 52pt 的同一块地，
    /// 两者不可能同时可见。原先那句「Music 连工具条一起淡，Amber 暂时只淡自己这一层」
    /// 也在这里补上。
    ///
    /// 落点取红绿灯的父视图（`NSTitlebarView`）：工具条与三颗按钮都是它的子视图，
    /// 淡一层就够；取不到就退回逐颗按钮。
    private func setChromeVisible(_ visible: Bool) {
        guard let window else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        let targets: [NSView] = buttons.first?.superview.map { [$0] } ?? buttons
        guard !targets.isEmpty else { return }
        let alpha: CGFloat = visible ? 1 : 0
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            targets.forEach { $0.alphaValue = alpha }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MusicMetrics.MiniPlayerWindow.rolloverFadeDuration
            targets.forEach { $0.animator().alphaValue = alpha }
        }
    }

    private func playerVolumeDidChange(_ volume: Double) {
        volumeSlider.doubleValue = volume
        volumeItem?.image = contents.volumeImage
    }

    private func refreshToolbarItems() {
        // [实测] spec §5 的原话是「`hidden` 绑定到`contents.showActionToolbar`」——
        // **就是字面意思，不取反**：`showActionToolbar` = `currState ∈ {3…8}` 为真时
        // 工具条上这颗 ⋯ 反而**藏起来**，因为展开态里它已经跑到浮层标题行右端、和 ☆ 并排了。
        // 收起态（组 I）浮层没有那一行，⋯ 才由工具条出面。
        // [PX] 录屏两态互证：方形态工具条只有 💬 ☰ 🔊、⋯ 在标题行右侧；
        // 收起态工具条上有 ⋯、面板里没有标题行。
        actionItem?.isHidden = contents.showActionToolbar
        lyricsButton.state = contents.isLyricsOpen ? .on : .off
        queueButton.state = contents.isQueueOpen ? .on : .off
        // [实测] §4.4 `hideAirPlaySelector` = `showVolumeSlider || airPlaySelector.isHidden`。
        //
        // 后半条在 Amber 恒为 false：Music 那颗是自家的 `NativeAirPlayPopoverButton`，
        // 没有可投送目标时自己 `isHidden`；`AVRoutePickerView` 不会。macOS 上也**没有**
        // 公开的路由探测 API（`AVRouteDetector` 只在 AVKit 的 .tbd 里有符号，
        // macOS SDK 不带头文件，iOS/tvOS 才公开），所以这一项在 Amber 里除非展开音量条否则常显。
        // 用户录屏里 Music 只有三颗（没有 AirPlay），是那台机器当时没有外部路由，不是版式差异。
        airplayItem?.isHidden = showVolumeSlider || airPlaySelector.isHidden
        volumeItem?.image = contents.volumeImage
        volumeSliderItem?.isHidden = !showVolumeSlider
        volumeSlider.doubleValue = appState.player.volume
    }

    // MARK: - 工具条动作

    /// spec §5 `doActionButton:`：`popUpMenuPositioningItem:atLocation:inView:` 定位在 sender 的 view 原点。
    @objc private func doActionButton(_ sender: Any?) {
        let menu = contents.actionMenu()
        guard let view = (sender as? NSToolbarItem)?.view ?? (sender as? NSView) else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        menu.popUp(positioning: nil, at: .zero, in: view)
    }

    @objc private func doLyricsButton(_ sender: Any?) {
        contents.lyricsClicked()
    }

    @objc private func doQueueButton(_ sender: Any?) {
        contents.queueClicked()
    }

    /// spec §5 `volume` 项：翻转`showVolumeSlider`（didSet 会整份换掉工具条项）。
    @objc private func doVolumeButton(_ sender: Any?) {
        showVolumeSlider.toggle()
    }

    @objc private func doVolumeSliderChanged(_ sender: NSSlider) {
        appState.player.volume = sender.doubleValue
    }
}

// MARK: - AirPlay

/// 系统输出设备选择器。与底栏胶囊里那颗同款（`MiniPlayerView` 里那份是 private，
/// 跨文件用不了，这里另立一份），把固有尺寸钉成工具条件的常规见方，
/// 免得 `AVRoutePickerView` 自带的 41.5×38 把相邻两件挤走。
private final class MiniPlayerRoutePickerView: AVRoutePickerView {
    /// [推] 24 是工具条图标件的常规见方（`NSToolbar` 图标档的图像 hit 区），
    /// 与底栏胶囊那份取 `MiniPlayer.trailingButtonSize` 同一手法。
    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }
}
