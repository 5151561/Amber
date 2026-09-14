import Foundation

/// 纯时间轴逻辑：给定播放进度，决定当前该选中哪几行。不碰任何视图。
///
/// 字段与顺序照原版排。每帧走查见 `+Selection.swift` 的`update(at:)`。
@MainActor
final class SyncedLyricsManager {

    struct Configuration: Sendable {
        /// 原版这里是个闭包，按行算动画时长，不是常数（§1.2 第三步）。
        ///
        /// 入参是**候选行的时长**（`endTime − startTime`），返回值被加到`elapsed` 上
        /// 得到淘汰队首用的 `cutoff`。闭包体本身没在静态数据里，宿主自己给。
        /// Amber 默认给 `specs.animationHeadstart`（0.1）—— 常数，`[推]`：
        /// 只知道量纲是秒、且与「行外观切换的动画时长」同一个量。
        var animationDuration: @Sendable (TimeInterval) -> TimeInterval = { _ in 0.1 }
        var finishLineAnimationDuration: TimeInterval
        var maxEndTimeOffset: TimeInterval
        init(finishLineAnimationDuration: TimeInterval, maxEndTimeOffset: TimeInterval) {
            self.finishLineAnimationDuration = finishLineAnimationDuration
            self.maxEndTimeOffset = maxEndTimeOffset
        }

        init(specs: LyricsSpecs) {
            self.init(finishLineAnimationDuration: specs.lineFinishProgressAnimationDuration,
                      maxEndTimeOffset: specs.maxEndTimeOffset)
            let headstart = specs.animationHeadstart
            self.animationDuration = { _ in headstart }
        }
    }

    var lyrics: Lyrics?                                   // +16
    var configuration: Configuration                      // +24
    weak var delegate: (any SyncedLyricsManagerDelegate)?  // +56
    /// 复数——`maxSelectedLines = 2`，句与句之间不会出现「谁都不亮」。
    /// 写口开着（不是 `private(set)`）：每帧走查在`+Selection.swift` 里，
    /// Swift 的 `private(set)` 跨文件写不了。
    var selectedLines: [any LyricsLine] = []              // +72
    var isPlayingSpatial = false                          // +80
    var elapsedTimeProvider: () -> TimeInterval = { 0 }    // +88
    var nextLine: (any LyricsLine)?                       // +104

    /// `LyricsSpecs.maxSelectedLines`，基线 2。可同时选中两行是句间不断亮的前提。
    var maxSelectedLines: Int = 2

    /// 已经走过收尾（`lineFinishProgressAnimationDuration`）的行，避免每帧重复触发。
    /// 原版把这件事记在行自己的动画状态里；这里单列一个集合，语义等价。`[补]`
    var finishedLineIndices: Set<Int> = []
    /// 正在整体重排（换歌 / seek）。这期间的「选中」是补账，不该逐行翻页——
    /// 视图侧改走 `jumping to`（§5.4）那条路，一次落位。`[补]`
    var isResyncing = false
    /// 下一条候选行的下标。原版只存 `nextLine` 本体，这里同时留下标，
    /// 因为行与视图是按下标一一对应的（见 `LyricsLine.index`）。
    var nextLineIndex = 0

    init(configuration: Configuration, maxSelectedLines: Int = 2) {
        self.configuration = configuration
        self.maxSelectedLines = maxSelectedLines
    }

    /// 换歌 / 换歌词。清空全部账本，`update(at:)` 会从头开始选。
    func setLyrics(_ lyrics: Lyrics?) {
        self.lyrics = lyrics
        selectedLines = []
        finishedLineIndices = []
        nextLineIndex = 0
        nextLine = lyrics?.lines.first
    }
}

/// 选行结果的接收方。原版 `delegate`(+56) 是个`AnyObject`，
/// 视图侧的三件事（选中 / 取消 / 行末补完）分别落在
/// `selecting line` / `deselecting line` / 三条路径上。
@MainActor
protocol SyncedLyricsManagerDelegate: AnyObject {
    func syncedLyricsManager(_ manager: SyncedLyricsManager, didSelect line: any LyricsLine)
    func syncedLyricsManager(_ manager: SyncedLyricsManager, didDeselect line: any LyricsLine)
    func syncedLyricsManager(_ manager: SyncedLyricsManager, didFinish line: any LyricsLine)
    /// 整体重排收尾，参数是重排后最靠后的那一行（没有就是 nil）。
    func syncedLyricsManager(_ manager: SyncedLyricsManager,
                             didResyncTo line: (any LyricsLine)?)
}
