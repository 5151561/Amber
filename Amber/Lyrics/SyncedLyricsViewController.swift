import AppKit

/// 整个歌词面板。每帧由 `CADisplayLink` 驱动，不是`Timer`。
///
/// 对应 `SyncedLyricsViewController`。
final class SyncedLyricsViewController: NSViewController {

    weak var delegate: AnyObject?                     // +8
    var lyrics: Lyrics?                               // +24
    var scrollView: NSScrollView?
    var documentView: NSView?                         // 原版是个 FlippedView
    var displayLink: CADisplayLink?
    var margins = NSEdgeInsets()
    var topInset: CGFloat = 0
    var specs = LyricsSpecs()
    var manager: SyncedLyricsVisualExperienceManager?
    var currentAnimators: [LayerPropertyAnimator] = []
    var isDragging = false
    var isVisible = false
    /// 面板是不是**真的在跟随**（[TYPE] `LyricsOptions.isActive`）。
    ///
    /// 整窗播放器是常驻 + 位移的（收起时整块挪到窗口外），SwiftUI 不会因此调
    /// `viewWillDisappear`——只认`isVisible` 的话，每帧驱动在看不见的时候照样跑。
    var isActive = true {
        didSet {
            guard isActive != oldValue else { return }
            updateDisplayLink()
        }
    }
    var didAppear = false
    var isSettingLyrics = false
    var previousBounds = CGRect.zero

    /// 自动生成的免责声明标签（原版的 `SyncedLyricsViewController.automaticallyCreatedDisclaimerLabel`）。
    /// 由 §3.6 的收口函数按需建、按需拆。
    var disclaimerLabel: NSTextField?
    /// 免责声明的富文本，对应的返回值；nil 表示这首歌没有声明。
    var disclaimerText: NSAttributedString?

    /// 全部行算好的 frame。原版一次算一行、y 靠外层循环累加，
    /// 这里一次算完存下来，三个滚动入口共用的 `measure` 就退化成查表。
    var lineFrames: [CGRect] = []
    /// 时间源。换源时要过 §1.4 的三条闸。
    var timingProviderGate = TimingProviderGate()
    /// 正在跑的滚动弹簧。每帧由 `displayLinkFired` 推一格，见 +ScrollSpring.swift。
    var scrollSpring: ScrollSpring?
    /// 动画期间处于临时独立位移状态的行集合（零位移对账用）。
    var displacedLineViews: Set<SyncedLyricsLineView> = []
    /// 正在进行的逐行动画对账目标 origin。
    var pendingScrollTargetOrigin: CGPoint?
    /// 逐行滚动动画代际，用于废弃上一轮尚未结束的回调。
    var scrollAnimationGeneration: Int = 0
    /// 当前处在悬停外观的那一行。见 `syncHoverState()`。
    weak var hoveredLineView: SyncedLyricsLineView?
    /// 块式通知观察者的令牌。见 `installScrollObserversIfNeeded()`——
    /// 这种观察者不是以 `self` 注册的，`removeObserver(self)` 摘不掉。
    var scrollObservers: [any NSObjectProtocol] = []

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        view = container
        installScrollView(in: container)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateViewportMask()
        // [实测] `layoutLines: scrolling to` 的判据是**锚点行矩形全等**，
        // 不是 y 差——窗口宽度变了导致换行数变化、锚点行因此移位时才滚。
        guard let scrollView, scrollView.bounds != previousBounds else { return }
        previousBounds = scrollView.bounds
        let anchor = manager.flatMap { $0.scrollTargetLineView(at: $0.currentElapsedTime()) }
            ?? manager?.selectedLineViews.first
        recomputeLineFrames()
        layoutLines(anchor: anchor, measure: measure)
        collapseDocument(below: manager?.lineViews.last)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        isVisible = true
        // `tearDown()` 会把观察者摘掉，再次上台得装回来（幂等，装过就不重复装）。
        installScrollObserversIfNeeded()
        updateDisplayLink()
        updateViewportMask()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        didAppear = true
        updateViewportMask()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        isVisible = false
        tearDown()
    }

    func updateDisplayLink() {
        // 静态档（整份无戳纯文本）没有时间轴可走查，每帧驱动整个不启动。
        // 闸放在控制器这一层而不是宿主侧：一处改动同时覆盖整窗与侧栏两个宿主。
        // 停掉之后没有旁路依赖——`viewDidLayout` 的`layoutLines(anchor: nil, …)`
        // 因 `before == after == .zero` 返回 nil，`scrollTargetLineView(at:)` 读空的
        // `selectedLineViews` 得 nil，`SyncedLyricsManager.setLyrics` 不发 delegate 回调。
        if isVisible && isActive && specs.renderingMode != .static {
            startDisplayLink()
        } else {
            stopDisplayLink()
        }
        // 停链之后补同步一次模糊。[PX] §22.3 的「暂停后全表清晰」平时靠
        // `displayLinkFired` 每帧看一眼，但整窗那端的`isActive` 本身就带着
        // `isPlaying`（`NowPlayingLyrics.syncOptions`：`isVisible && !isEmpty && isPlaying`）
        // ——一暂停 `isActive` 先翻 false、链子跟着停，那一帧永远轮不到，
        // 模糊会卡在暂停前的样子。恢复播放时链子重开，回填由第一帧自己做。
        manager?.syncBlurToPlaybackState()
    }

    /// 停机：停每帧驱动、撤在跑的动画、摘掉块式观察者。
    ///
    /// 三处调用——`viewWillDisappear`、SwiftUI 的
    /// `dismantleNSViewController`、以及`deinit`。写成幂等的：
    /// `stopDisplayLink` 会把字段置 nil，`cancelRunningAnimations` 收尾清空数组，
    /// `removeScrollObservers` 摘完也清空。再次上台由`viewWillAppear` 装回来。
    ///
    /// **`view.displayLink(target:selector:)` 是强引用`self` 的**，光靠
    /// `viewWillDisappear` 停不住：SwiftUI 拆掉`NSViewControllerRepresentable` 时
    /// 不保证走 AppKit 的上下台回调，链子不 `invalidate` 就一直每帧回调回来。
    func tearDown() {
        stopDisplayLink()
        cancelRunningAnimations()
        removeScrollObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        for token in scrollObservers { NotificationCenter.default.removeObserver(token) }
        displayLink?.invalidate()
    }

    /// 关掉隐式动画跑一段。
    ///
    /// 手工挂上去的子层（`lineLayer` / 内容层 / 渐变遮罩）改几何时会吃
    /// CoreAnimation 默认那条 0.25s 的隐式动画，而歌词的重排要么自己带弹簧、
    /// 要么就该一帧到位。`+Setup` 的`relayoutEverything`、`+Scrolling` 的`jump`、
    /// `+Selection` 的`relayout` 早就各自手写了一遍`begin/setDisableActions/commit`，
    /// 剩下几处漏了——统一收到这里，免得再漏。
    func withoutImplicitAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // 每帧驱动与搭台见 +Setup.swift（§1.1 / §2.6）
    // 间奏三入口与文档收口见 +Instrumental.swift（§3.5 / §3.6）
    // 滚动判据与目标位置见 +Scrolling.swift（§2.1 / §2.5 / §2.7 / §4.4）
    // animating to 的四条闸见 +AnimatingTo.swift（§6.4）
    // 选行状态机的视图侧配件见 +Selection.swift（§9.3 / §9.5）
}

/// 选行结果落到视图上。`SyncedLyricsManager` 每帧算出该选谁，由这里翻成外观。
extension SyncedLyricsViewController: SyncedLyricsManagerDelegate {

    func syncedLyricsManager(_ manager: SyncedLyricsManager, didSelect line: any LyricsLine) {
        guard !manager.isResyncing else {
            // 重排期间只补外观，位置交给收尾那一次 `jumping to`——
            // 否则中间每一行都会各翻一次页。
            self.manager?.selectLine(line, animation: nil,
                                     deselectingOthers: false,
                                     updatesInstrumentalTime: true)
            return
        }
        self.manager?.select(line)
    }

    /// 换歌 / 拖进度条之后的落位。走 §5.4 的 `jumping to`：
    /// 目标行与视口相交才动画，**完全不可见反而硬跳**（§2.7 与 §2.1 判据相反）。
    func syncedLyricsManager(_ manager: SyncedLyricsManager,
                             didResyncTo line: (any LyricsLine)?) {
        guard let line else { return }
        jump(to: line, animated: true)
    }

    func syncedLyricsManager(_ manager: SyncedLyricsManager, didDeselect line: any LyricsLine) {
        self.manager?.deselectLine(line)
    }

    /// 行唱完的收尾：把没走完的进度在
    /// `lineFinishProgressAnimationDuration`(0.25) 内补完（§7.4）。
    /// 补完期间 `ignoreProgress` 置位，否则每帧走查会立刻把渐变改回按时间算的位置。
    func syncedLyricsManager(_ manager: SyncedLyricsManager, didFinish line: any LyricsLine) {
        guard let view = self.manager?.lineViews[safe: line.index],
              let content = view.lineLayer?.contentLayer as? SBS_TextContentLayer
        else { return }
        content.finishRemainingProgress(duration: specs.lineFinishProgressAnimationDuration)
    }
}
