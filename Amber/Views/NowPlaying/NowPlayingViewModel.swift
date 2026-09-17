import AppKit
import SwiftUI

/// 「正在播放」的行为层，对着 Music 1.7 的实测结果搭：
///
/// ```
/// PBPlayerControlsState   能力位（纯值对象，49 方法里 48 个存取器）
/// PBPlayerViewModel       播放状态：playButtonState / shuffle / repeat / 音量
/// PBPlayerMetadataViewModel   元数据：标题、时间三值、徽标、心水
/// ```
///
/// 第四支「呈现状态」（抽屉、rollover、时间行档位、`preMuteVolume`、反应条）本来在这里
/// 落成 `NowPlayingViewModel` 那个 `ObservableObject`，阶段 6 换 AppKit 骨架之后归了
/// `NowPlayingContainerViewController` 与 `NowPlayingChromeView` 自己（铁律 3）；
/// 这个文件从此**只剩值类型**——迷你播放器、菜单、⌘↑/⌘↓ 也都在用它们。
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
    /// 心水那一位**只有元数据那一行用得上**，所以给了默认值：时间行、徽标、封面
    /// 那几处也拿这个值对象，但它们不该为了一个用不到的字段把整份 `LibraryStore`
    /// 拉进自己的依赖集（reactive-ui-review §2.1）。填它的是 `MetadataLabels`，
    /// 那是全屏播放器里唯一观察资料库的一小块。
    var isFavorite = false
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

// MARK: - 呈现状态

// [实测] §6.1 的字段树里，与 Amber 对得上的那几支——`presentation` / `geometry` /
// `windowProperties`（抽屉与窗口）、`trackSections`（待播清单盘）、`hostedContent`（歌词）
// ——现在**全部归 AppKit 那台容器**（`NowPlayingContainerViewController`）：抽屉开合、
// rollover、反应条、`preMuteVolume` 都是视图自己的状态，不必再经一个 `ObservableObject`
// 绕一圈（计划 §2 铁律 3）。`LayoutHints` 那两个锚点也一并没了：封面中心由容器按
// 同一个列宽自算，不再走 `PreferenceKey` 往上报（「阶段 6 开工前的三处决定」第 3 条）。
//
// 只有下面这一枚枚举还留在值类型这一侧——时间行画在 SwiftUI 那棵内容列里，
// 容器把当前档位当参数传进去、把「翻下一档」当回调收回来。

/// [实测] §3.2 `showTotalInsteadOfRemaining`（`doTimeRemainingClicked:` 翻转它）。
/// AppKit 那块盘只有「剩余 / 总时长」两态；SwiftUI 侧的
/// `TimeControlAccessoryView` [TYPE] 另有`TimeAtEndView` / `TrackDurationView` /
/// `ClockTimeText` 三个成员，Amber 取三态，第一态与 AppKit 的「剩余」同解。
enum NowPlayingTimeAccessory: Equatable {
    case remaining, duration, endsAt

    var next: NowPlayingTimeAccessory {
        switch self {
        case .remaining: return .duration
        case .duration:  return .endsAt
        case .endsAt:    return .remaining
        }
    }
}

/// rollover 的时长。
///
/// 停留那两档是 [实测] miniplayer spec §11.1 `MPContentView` 的 ivar 表
/// （`kMouseInterestTimeoutInSeconds` = 3.75、
/// `kMouseInterestExitingWindowTimeoutInSeconds` = 0.3、
/// `kDelayBeforeStartingRolloverMin` = 0.1）——那张表记的就是**整窗内容视图自己**的字段，
/// 迷你横条与整窗共用同一台 `MPContentView`，所以两处本来就是同一个数。
/// 常量落在 `MusicMetrics.MiniPlayerWindow` 那一组，这里只做转引，不再抄一份
/// （旧版这里写的 `interest = 3` 是 [推]，已按实测订正）。
enum NowPlayingRollover {
    static let interest = MusicMetrics.MiniPlayerWindow.mouseInterestTimeout
    static let exitingWindow = MusicMetrics.MiniPlayerWindow.mouseInterestExitingWindowTimeout
    static let startDelay = MusicMetrics.MiniPlayerWindow.delayBeforeStartingRolloverMin
    /// 淡入淡出本身没量到，取手感值。[推]
    static let fadeIn: TimeInterval = 0.14
    static let fadeOut: TimeInterval = 0.45
}
