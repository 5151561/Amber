import AppKit

/// 视觉状态机：把 manager 算出的选中集合翻译成每一行的外观（选中/模糊/隐藏），
/// 并处理用户拖动带来的模式切换。
///
/// 对应 `SyncedLyricsVisualExperienceManager`。
@MainActor
final class SyncedLyricsVisualExperienceManager {

    /// 原版三个模式。存在 manager 的 `mode` 字段里，
    /// 取值按声明序：regular = 0 / scroll = 1 / tracking = 2。
    /// 与 `selecting line` 里的判的就是`.tracking`。
    enum Mode: Sendable {
        case regular    // 跟着时间轴走
        case scroll     // 用户在浏览；非播放行提亮，但当前行和逐字高亮继续跟时间轴
        case tracking   // 拖完之后、还没交还控制权的过渡态
    }

    /// [实测] +16 是**弱引用的 view controller**，不是 delegate：
    /// `selecting`、`deselecting all`、
    /// 都对 `self + 0x10` 做
    /// `swift_unknownObjectWeakLoadStrong`，随后立刻读
    /// 原版的 `SyncedLyricsViewController.scrollView`。
    weak var viewController: SyncedLyricsViewController?     // +16
    var manager: SyncedLyricsManager?                        // +32
    var specs = LyricsSpecs()                                // +40
    var lyrics: Lyrics?                                      // +920
    /// 时间源。走查用的时刻走 `manager.elapsedTimeProvider()`，这里只读
    /// `isPaused`——[PX] §22.3「**暂停后全表清晰**」那条要它，见
    /// `syncBlurToPlaybackState()`。
    var timingProvider: (any SyncedLyricsTimingProvider)?    // +928
    var mode: Mode = .regular                                // +968
    var allowAnimateToNextLineAfterScroll = true             // +969
    var lineViews: [SyncedLyricsLineView] = []               // +976
    /// **有序数组，不是集合。**[实测] `selecting line` 走的是
    /// `Array._makeUniqueAndReserveCapacityIfNotUnique` + `_appendElementAssumeUniqueAndCapacity`，
    /// 遍历用 `_getElementSlowPath` / `[base + i·8]`，清空写
    /// `__swiftEmptyArrayStorage`——全是数组语义。顺序有意义：§1.3 的
    /// 「队首出局」淘汰的就是第 0 个。
    /// 对比之下 `blurredLineViews`/`hiddenLineViews` 走的是`Set.insert`
    /// （里面是 `__CocoaSet.member(for:)` 加原生探测），确是集合。
    var selectedLineViews: [SyncedLyricsLineView] = []       // +984
    var blurredLineViews: Set<SyncedLyricsLineView> = []     // +992
    var hiddenLineViews: Set<SyncedLyricsLineView> = []      // +1000
    var instrumentalBreakVisibleView: SyncedLyricsLineView?  // +1008
    /// 上一次把焦点位交给了哪一行（`scrollTargetLineView` 的结论）。每帧的
    /// `followScrollTarget` 只在它变了的时候滚一次。`[补]`
    weak var scrollTargetView: SyncedLyricsLineView?
    var needsTapHandling = false                             // +1016
    var allowAnimateToNextLineAfterScrollTimer: Timer?
    var lastTapDate: Date?
    /// 上一帧看到的播放/暂停态。`nil` = 还没同步过（首帧不做淡变，见
    /// `syncBlurToPlaybackState()`）。
    var isPlaybackPausedForBlur: Bool?

    /// 非聚焦行的高斯模糊半径。
    ///
    /// **不在 `LyricsSpecs` 里**——是`deselecting all` 里写死的 3.0：
    /// 读 `SyncedLyricsLineLayer.blurRadius`，若不等于 3 就先`setShouldRasterize(false)`
    /// 再把 `filters.gaussianBlur.inputRadius` 动到 3.0。判据是二值的「是不是当前聚焦行」，
    /// 不是按距离的梯度——和实测的 σ≈3.1、不单调一致。
    ///
    /// **Amber 取 1.5，不是 3.0**（`[实机]`，2026-09-07 用户逐档判读）：3.0 在 Amber 上
    /// 把非聚焦行的副行（翻译/发音，侧栏 12pt）
    /// 糊到读不出来。这是个**取值不是结论**——3.0 是 [实测]、σ≈3.1 是 [PX] 实测，
    /// 两边自洽，所以差异出在 Amber 这一侧，只是还没测出来在哪：最可能的一处是
    /// `CIGaussianBlur.inputRadius` 在 Music 那边按背衬像素算、在 Amber 这边按点算
    /// （Retina 上正好差一倍），但没有证据，没敢照这个假设去写 `/ backingScaleFactor`。
    /// 量清楚之前先按实机判读取值，`-lyricsblur <值>` 可以现场调。
    static var deselectedBlurRadius: CGFloat { LyricsDebugFlags.blurRadius ?? 1.5 }

    /// 松手后多久交还控制权。
    ///
    /// [实测]：喂给
    /// `scheduledTimerWithTimeInterval:repeats:block:`（repeats = NO），
    /// 存进 `allowAnimateToNextLineAfterScrollTimer`。
    ///
    /// 计时器到点前 `allowAnimateToNextLineAfterScroll` 为假，自动翻行被抑制。
    /// 配合 `autoSnapAfterScroll = false`：松手**不吸附**到最近一行，
    /// 只是等满 3 秒再恢复自动跟随。
    static let allowAnimateAfterScrollDelay: TimeInterval = 3.0

    /// 用户按下开始拖动。[实测]：置 `isDragging`，`mode = .scroll`。
    /// 进入 `.scroll` 后清除模糊、提亮非播放行；当前播放行仍保留逐字高亮。
    func beginScrolling() {
        mode = .scroll
        beginScrollingAppearance()          //，见 §9.7
    }

    /// 用户松手。[实测] `-[… scrollViewDidEndScrolling]` →
    /// 起一个 3 秒一次性计时器。
    func endScrolling() {
        allowAnimateToNextLineAfterScrollTimer?.invalidate()
        allowAnimateToNextLineAfterScrollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.allowAnimateAfterScrollDelay, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.returnControlToPlayback() }
        }
    }

    /// 交还控制权：允许自动翻行、退出 `.scroll` 外观（颜色回 17.5%、模糊填回来）。
    ///
    /// **两个调用方**：上面那个 3 秒计时器，以及 `handleTap`（§4.3）。
    ///
    /// 拆出来是因为 `handleTap` 会把计时器`invalidate()` 掉（实测），
    /// 而 `mode = .regular` 这一步在 Amber 这边**只挂在计时器身上**——[实测] 只记了
    /// 「计时器到点前 `allowAnimateToNextLineAfterScroll` 为假」（§2.9），没记 mode
    /// 从哪儿回去，Amber 把它放进了计时器体。于是「滑动 → 3 秒内点一行」这条路上，
    /// 计时器被点击掐掉、mode 永远停在 `.scroll`：全部行留在 40% 的
    /// `deselectedScrollTextColor`、模糊再也填不回来（`scroll(toLineView:)` 那道
    /// `mode == .regular` 也一直不通）。表现就是「点完之后歌词一直是清晰的往下走」。
    ///
    /// §4.3 写明「**点击立刻交还控制权**，不走 §2.9 那 3 秒」——那么掐掉计时器的人
    /// 就得把计时器该做的事做掉。`[补]`（这一步是 Amber 的结构决定的，原版 mode
    /// 的复位点没读出来。）
    func returnControlToPlayback() {
        allowAnimateToNextLineAfterScrollTimer?.invalidate()
        allowAnimateToNextLineAfterScrollTimer = nil
        allowAnimateToNextLineAfterScroll = true
        guard mode != .regular else { return }
        mode = .regular
        endScrollingAppearance()
    }

    init() {}

    // 批次 4：点击路径见 SyncedLyricsLineView+Interaction.swift——
    //   handleTap 会立刻把 allowAnimateToNextLineAfterScroll 置 true 并作废计时器，
    //   等 3 秒的只有拖动。
    // 批次 9：选行状态机与模式切换的外观下发见
    //   SyncedLyricsVisualExperienceManager+Selection.swift，规格 §9。
}

@MainActor
protocol SyncedLyricsTimingProvider: AnyObject {
    var isPaused: Bool { get }
    var elapsedTime: TimeInterval { get }
}
