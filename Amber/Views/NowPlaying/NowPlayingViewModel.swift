import AppKit
import Combine
import SwiftUI

/// 「正在播放」的行为层，对着 Music 1.7 的实测结果搭：
///
/// ```
/// PBPlayerControlsState   能力位（纯值对象，49 方法里 48 个存取器）
/// PBPlayerViewModel       播放状态：playButtonState / shuffle / repeat / 音量
/// PBPlayerMetadataViewModel   元数据：标题、时间三值、徽标、心水
/// NowPlayingViewModel  呈现状态：抽屉、rollover、LayoutHints
/// ```
///
/// 出处标注沿用 nowplaying 规格的章节号：
/// `§3.3` 指该文第 3.3 节，节里每条都带函数地址。
///
/// 这一层刻意只做「值与状态机」，不碰视图：与 Music 的分层一致
/// （`PBPlayerMetadataViewModel` 的 98 个函数里没有一行滚动/定时器代码，
/// 「−mm:ss」的取负与格式化都在视图层，见 §4.2 / §4.3）。

// MARK: - 能力位（PBPlayerControlsState）

/// [实测] §3.3：Music 的 `canPlay/canPause/canStop/canSkip*/canFF/canRewind/canSetVolume/
/// canMute/isMuted` 全部是`[visiblePlayer].playerControlsState` 的同名属性直读，
/// 播放器视图模型只负责转发。Amber 这边同构：从 `PlayerController` 的实际状态算一次。
struct PlayerControlsState: Equatable {
    var hasItem = false
    var canPlay = false
    var canPause = false
    var canStop = false
    var canSkipNext = false
    var canSkipPrevious = false
    var canRewind = false
    var canFF = false
    var canSetVolume = true
    var canMute = true
    var isMuted = false
    /// [实测] §4.4：0 = 非直播；1…5 各有一条 Live 徽标文案（5 槽跳表）。
    /// Amber 的两个音源都不给直播流，恒 0——但 `playButtonState` 的`liveMode == 2 → Stop`
    /// 那一支要靠它，所以字段保留。
    var liveMode = 0
    /// [实测] §4.2：远控别的设备时，标题位显示设备名而不是曲名。
    /// Amber 走系统 AirPlay 选择器（`AVRoutePickerView`），App 侧拿不到设备名，恒 false。
    var isRemoteControllingDevice = false
    var remoteControlDeviceName: String?

    @MainActor
    init(player: PlayerController) {
        hasItem = player.currentTrack != nil
        // canPlay = 「现在按下去会开始播」，canPause = 「现在按下去会暂停」，两者互斥。
        canPlay = hasItem && !player.isPlaying
        canPause = hasItem && player.isPlaying
        canStop = false
        canSkipNext = hasItem && (player.queue.count > 1 || player.repeatMode != .off)
        canSkipPrevious = hasItem
        canRewind = hasItem && player.duration > 0
        canFF = canRewind
        isMuted = player.volume <= 0.0001
    }

    init() {}

    /// [实测] §3.3 的 affecting 键表里，传输键的可用性走的**不是** skip 那两个：
    /// `previousTrackActionEnabled ← canRewind`、`nextTrackActionEnabled ← canFF`
    /// （`skipBackEnabled` / `skipForwardEnabled` 才读 canSkipPrevious / canSkipNext，
    /// 那是另一组按钮）。所以队列里只有一首歌时，整窗播放器的「下一首」照样可按——
    /// 按住是快进，点按才是切歌。
    var previousTrackActionEnabled: Bool { canRewind }
    var nextTrackActionEnabled: Bool { canFF }
}

// MARK: - 播放键三态

/// [实测] §3.3 `PBPlayerViewModel.playButtonState`。
/// 与 `MPTransportPlatter.currPlayImage` 的三态 switch 对上：
/// 0 → play 字形、1 → pause 字形、2 → 第三字形，越界直接 `_assertionFailure`。
enum PlayButtonState: Int {
    case play = 0
    case pause = 1
    case stop = 2

    /// 判定顺序照抄 ASM，不要调换：`canPlay` 在最前，所以「既能播又能停」时显示播放键。
    static func resolve(_ state: PlayerControlsState) -> PlayButtonState {
        guard state.hasItem else { return .play }
        if state.canPlay { return .play }
        if state.canPause { return state.liveMode == 2 ? .stop : .pause }
        if state.canStop { return .stop }
        return .play
    }

    var symbolName: String {
        switch self {
        case .play:  return "play.fill"
        case .pause: return "pause.fill"
        case .stop:  return "stop.fill"
        }
    }

    var help: String {
        switch self {
        case .play:  return "播放"
        case .pause: return "暂停"
        case .stop:  return "停止"
        }
    }
}

// MARK: - 随机 / 循环

/// [实测] §3.3 `doShuffleClickedAction`：底层枚举在 **1（关）↔ 2（开）**
/// 之间 toggle，getter 布尔化的判据是 `(mode & ~1) == 2`，所以 2/3 都算开。
enum ShuffleMode: Int {
    case forcedOff = 0
    case off = 1
    case on = 2
    /// 「歌曲标签页强制开」之类的第三态：算开，但点击路径不产生它。
    case forcedOn = 3

    var isOn: Bool { (rawValue & ~1) == 2 }
    var toggled: ShuffleMode { self == .off ? .on : .off }
}

/// [实测] §3.3 `doRepeatClickedAction`：**底层** 0（关）→ 1（全部）→ 2（单曲）→ 0，
/// 而 getter 把底层 1 映射到 UI 2、底层 2 映射到 UI 1——**UI 的顺序与底层相反**
/// （UI 为 {0 关, 1 单曲, 2 全部}）。
///
/// `PlayerController.RepeatMode` 的 rawValue（off=0 / all=1 / one=2）与**底层**一致，
/// `cycleRepeatMode()` 的 off→all→one→off 也就是底层那条循环，无需改动；
/// 这里只补上「UI 档位」的映射，字形与文案按它取。
extension PlayerController.RepeatMode {
    /// UI 档位：0 关 / 1 单曲 / 2 全部
    var uiIndex: Int {
        switch self {
        case .off: return 0
        case .all: return 2
        case .one: return 1
        }
    }

    /// [实测] §3.1 `currentRepeatImage` = `glyphForRepeatMode:`——字形按模式由宿主供给。
    var symbolName: String { self == .one ? "repeat.1" : "repeat" }

    var isOn: Bool { self != .off }

    var help: String {
        switch self {
        case .off: return "重复播放"
        case .all: return "重复播放全部"
        case .one: return "重复播放当前歌曲"
        }
    }
}

// MARK: - 音量

/// [实测] §3.3 `PBPlayerControlsModel.incrementDecrementVolume:`：
/// 内部刻度 **0…256**，步进 **±12**，负值清零、上限封 256；且先查 `canSetVolume`，为假不动。
///
/// Amber 的 `PlayerController.volume` 是 0…1 的 Double，这里做一层刻度换算，
/// 键盘增减音量（⌘↑/⌘↓）落在同一格上，与 Music 的手感一致。
enum VolumeScale {
    static let maximum: Double = 256
    static let step: Double = 12

    static func ticks(from volume: Double) -> Double { (volume * maximum).rounded() }
    static func volume(from ticks: Double) -> Double { min(max(ticks, 0), maximum) / maximum }

    /// `steps` 为正是加、为负是减；夹在 0…256。
    static func increment(_ current: Double, steps: Int) -> Double {
        volume(from: ticks(from: current) + step * Double(steps))
    }
}

// MARK: - 心水 / 点踩

/// [实测] §4.5 `favoritingState`/ `doSetFavoritingState:`：
/// **内部存储 {2 = liked, 3 = disliked}，UI 出口 {0 无, 1 已喜欢, 2 已点踩}**，
/// 入口与出口两个函数严格互逆，外部传 0xFF 落到内部 1。
///
/// Amber 只产出 `.none` / `.liked` 两态：`.disliked`（Suggest Less）在 Music 里要写回
/// `setLikedState:forIdentifierSet:`，Amber 的两个音源都没有这个通道，
/// 所以状态机保留完整、但点踩这一支不接线（与 `TrackActions` 里不摆`doDislike:` 同因）。
enum FavoritingState: Int {
    case none = 0
    case liked = 1
    case disliked = 2

    var symbolName: String {
        switch self {
        case .liked:    return "star.fill"
        case .disliked: return "hand.thumbsdown.fill"
        case .none:     return "star"
        }
    }
}

// MARK: - 元数据（PBPlayerMetadataViewModel）

/// [实测] §4.1：这个模型只有三个字段（`userIsScrubbingCurrentTime` / `player` / `nowPlayingItem`），
/// **显示属性全部是当前条目的即时派生、无缓存**。Amber 照此做成 struct，每次取用现算。
struct NowPlayingMetadata {
    var item: Track?
    var controls: PlayerControlsState
    var duration: TimeInterval
    var isFavorite: Bool
    var isLossless: Bool

    /// [实测] §4.2 `primaryTitle`：远控别的设备且设备名非空 → 标题位显示设备名；
    /// 否则显示曲名。
    var primaryTitle: String {
        if controls.isRemoteControllingDevice, let name = controls.remoteControlDeviceName,
           !name.isEmpty {
            return name
        }
        return item?.title ?? "未在播放"
    }

    /// [实测] §4.2 `secondaryTitle`：远控中 → 「曲名 — 艺人」单行合并串；
    /// 否则副标题；条目为 nil → 本地化占位串（`REMOTE_CONTROL_DEVICE_NOT_PLAYING`）。
    var secondaryTitle: String {
        guard item != nil else {
            return controls.isRemoteControllingDevice ? "没有正在播放的内容" : ""
        }
        if controls.isRemoteControllingDevice { return singleLineTitleAndSubTitle }
        return subTitle
    }

    /// Music 的副标题是「艺人 — 专辑」；缺专辑时退化成只有艺人。
    private var subTitle: String {
        guard let item else { return "" }
        return item.albumName.isEmpty ? item.artistName : "\(item.artistName) — \(item.albumName)"
    }

    private var singleLineTitleAndSubTitle: String {
        guard let item else { return "" }
        return "\(item.title) — \(item.artistName)"
    }

    /// [实测] §4.2 `secondaryTitleIsActionable` + `doSecondaryTitleLinkAction`（导航事件码 0x61）：
    /// 副标题可点时跳到艺人/专辑。Amber 的判据是「艺人可跳转」。
    var secondaryTitleIsActionable: Bool { item?.canGoToArtist ?? false }

    /// [实测] §4.4 `artworkAspectRatio`：条目 kind ∈ {21,22,27}（音乐）→ **1.0**，
    /// 否则 **1.77778**（16:9 视频）。Amber 只有音乐条目。
    var artworkAspectRatio: CGFloat { 1.0 }

    // [实测] §4.3 时间三值：VM 统一输出 double 秒，
    // 「−mm:ss」的取负与格式化在视图层，这里不做。
    var endingTimecode: TimeInterval { duration }
    func currentTimecode(at time: TimeInterval) -> TimeInterval { time }
    /// 裸差值，不夹 0（Music 就是 end − current）。
    func remainingDisplayedTimecode(at time: TimeInterval) -> TimeInterval {
        endingTimecode - currentTimecode(at: time)
    }

    /// [实测] §4.4 徽标判定表。Live 与 Explicit/Clean 由 VM 判，
    /// 无损/Hi-Res/杜比三项是 VM **透传** `audioFormat*`、由 UI 层决定文案——
    /// Amber 只有「音源提供无损档」这一位，所以只出无损这一枚。
    var badges: [Badge] {
        var result: [Badge] = []
        if (1...5).contains(controls.liveMode) { result.append(.live) }
        if isLossless { result.append(.lossless) }
        return result
    }

    enum Badge: Hashable {
        case live
        case lossless

        var symbolName: String? {
            switch self {
            case .live:     return nil
            case .lossless: return "waveform"
            }
        }

        var title: String {
            switch self {
            case .live:     return "直播"
            case .lossless: return "无损"
            }
        }
    }

    /// [实测] §4.5：菜单四态可用性 = `canFavorite && state != 该态`——
    /// 已经是这个态就不再摆那一项（心水/取消心水互斥出现，见 `NowPlayingActionMenu`）。
    var favoritingState: FavoritingState { isFavorite ? .liked : .none }
}

// MARK: - 呈现状态（NowPlayingViewModel）

/// [实测] §6.1 的字段树里，与 Amber 对得上的那几支：`presentation` / `geometry` /
/// `windowProperties`（抽屉与窗口）、`trackSections`（待播清单盘）、`hostedContent`（歌词）。
@MainActor
final class NowPlayingViewModel: ObservableObject {

    /// 歌词桥。[实测] §8.1 `Lyrics`：
    /// 面板自己持 viewModel + options + footerButton，播放器只经它开合。
    let lyrics = NowPlayingLyrics()

    /// [实测] §2.2 `queueClicked` 与`keyPathsForValuesAffectingIsQueueOpen`。
    @Published private(set) var isQueueOpen = false

    /// [实测] §3.2 `showTotalInsteadOfRemaining`（`doTimeRemainingClicked:` 翻转它）。
    /// AppKit 那块盘只有「剩余 / 总时长」两态；SwiftUI 侧的
    /// `TimeControlAccessoryView` [TYPE] 另有`TimeAtEndView` / `TrackDurationView` /
    /// `ClockTimeText` 三个成员，Amber 取三态，第一态与 AppKit 的「剩余」同解。
    @Published var timeAccessory: TimeAccessory = .remaining

    /// [TYPE] `NowPlayingViewModel.VolumeControl.preMuteVolume: Float?`：
    /// 静音只是把音量压到 0，再点一次要还原到静音前那一档。
    @Published var preMuteVolume: Double?

    /// 反应条（[TYPE] `EmojiReactionPicker`）
    @Published var isReactionBarOpen = false

    /// [实测] §2.3 `rollState` / `rolloverShouldBeVisible`：鼠标停住一会儿就把悬浮控件收掉，
    /// 窗口失焦也收（`viewDidMoveToWindow` 挂的`windowFocusObserver` + `accessibilityFocusObserver`）。
    @Published private(set) var rolloverVisible = true

    /// [实测] §6.1 `LayoutHints`：SwiftUI 布局与 AppKit 侧同步的锚点**只有两个**，
    /// 就是下面这两支——歌词面板的基线全靠 `primaryArtworkCenterY` 对齐（见 §8.1 与
    /// `NowPlayingLyrics` 的注释）。
    @Published var layoutHints = LayoutHints()

    private var rolloverTask: Task<Void, Never>?
    private var rolloverDeadline = Date.distantPast
    private var lyricsObserver: AnyCancellable?
    private var isPresented = false

    init() {
        // 歌词桥是嵌套的 ObservableObject，变化不会自己往上冒泡。
        // 不转发的话「歌词开关」翻了，宿主这层不重画——底栏那颗键与右半区都停在旧样子。
        lyricsObserver = lyrics.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var isLyricsOpen: Bool { lyrics.options.isVisible }

    // MARK: 抽屉开合

    /// [实测] §2.2 `lyricsClicked`。菜单项`validate_doShowHideLyrics:`
    /// 恒返回 1（§1.1）——**这个开关永远可用**，没歌词时由面板自己兜底显示空态。
    func lyricsClicked() {
        lyrics.options.isVisible.toggle()
    }

    /// [实测] §2.2 `queueClicked`。同样永远可用。
    func queueClicked() {
        isQueueOpen.toggle()
    }

    // MARK: rollover

    /// 展开时**只显形、不起计时**：Music 那对计时器是
    /// `mouseStartingInterestTimer`（等鼠标先进来）+`mouseInterestTimer`（进来之后才计停留），
    /// 所以「开了播放中但一直没动鼠标」不该把关闭键也收掉。
    /// 计时从第一次鼠标活动起（`noteMouseActivity`）。
    func setPresented(_ presented: Bool) {
        isPresented = presented
        rolloverTask?.cancel()
        rolloverTask = nil
        rolloverVisible = true
    }

    /// 鼠标动了：立刻显形并把「停留到期时刻」往后推（Music 是
    /// `mouseStartingInterestTimer` + `mouseInterestTimer` 两只计时器，到点切`rollState`）。
    ///
    /// 推的是一个 deadline、不是每次都重开一只计时器：鼠标移动一秒能来几十个事件，
    /// 每个都 cancel + 新建 Task 纯属白烧。
    func noteMouseActivity() {
        guard isPresented else { return }
        if !rolloverVisible {
            withAnimation(.easeOut(duration: NowPlayingRollover.fadeIn)) { rolloverVisible = true }
        }
        rolloverDeadline = Date().addingTimeInterval(NowPlayingRollover.interest)
        startRolloverWatch()
    }

    /// 鼠标停在控件上就别收——Music 的 `rolloverTracker` 也是这么挡的。
    func holdRollover() {
        rolloverTask?.cancel()
        rolloverTask = nil
        rolloverDeadline = .distantFuture
        if !rolloverVisible {
            withAnimation(.easeOut(duration: NowPlayingRollover.fadeIn)) { rolloverVisible = true }
        }
    }

    /// [实测] §2.3 `windowFocusObserver`：失焦即收，回焦即显。
    func noteWindowFocus(_ focused: Bool) {
        guard isPresented else { return }
        if focused {
            noteMouseActivity()
        } else {
            rolloverTask?.cancel()
            rolloverTask = nil
            withAnimation(.easeOut(duration: NowPlayingRollover.fadeOut)) { rolloverVisible = false }
        }
    }

    private func startRolloverWatch() {
        guard rolloverTask == nil else { return }
        rolloverTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(NowPlayingRollover.tick))
                guard !Task.isCancelled, let self else { return }
                guard Date() >= self.rolloverDeadline else { continue }
                self.rolloverTask = nil
                withAnimation(.easeOut(duration: NowPlayingRollover.fadeOut)) {
                    self.rolloverVisible = false
                }
                return
            }
        }
    }

    // MARK: 音量

    /// [实测] §3.3：先查 `canSetVolume`，为假不动；再按 ±12/256 的刻度走。
    func incrementVolume(_ steps: Int, on player: PlayerController, state: PlayerControlsState) {
        guard state.canSetVolume else { return }
        player.volume = VolumeScale.increment(player.volume, steps: steps)
        if player.volume > 0 { preMuteVolume = nil }
    }

    /// 静音：压到 0 并记下原值；再点一次还原。`canMute` 为假不动。
    func toggleMute(on player: PlayerController, state: PlayerControlsState) {
        guard state.canMute else { return }
        if let restored = preMuteVolume {
            player.volume = restored
            preMuteVolume = nil
        } else {
            preMuteVolume = player.volume
            player.volume = 0
        }
    }

    /// [TYPE] `TimeControlAccessoryView` 的三个成员
    enum TimeAccessory {
        case remaining, duration, endsAt

        var next: TimeAccessory {
            switch self {
            case .remaining: return .duration
            case .duration:  return .endsAt
            case .endsAt:    return .remaining
            }
        }
    }
}

/// [实测] §6.1：`LayoutHints` 实测只有这两个可选 CGFloat
/// （`primaryArtworkCenterY` / `hostedContentMinY`）。
/// 两者都记在整窗播放器的公共坐标系里（`NowPlayingCoordinateSpace`）。
struct LayoutHints: Equatable {
    var primaryArtworkCenterY: CGFloat?
    var hostedContentMinY: CGFloat?
}

/// rollover 的时长。Music 那两只计时器的秒数没在静态数据里，取手感值。[推]
enum NowPlayingRollover {
    static let interest: TimeInterval = 3
    /// deadline 的查看周期
    static let tick: TimeInterval = 0.25
    static let fadeIn: TimeInterval = 0.14
    static let fadeOut: TimeInterval = 0.45
}
