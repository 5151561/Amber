import AppKit
import AVFoundation
import Combine
import Foundation
import Synchronization
import os

/// 播放进度。
///
/// 单独一个 ObservableObject，**不并进** `PlayerController`：进度 10 Hz 一跳，
/// 而 `AppState` 把`player.objectWillChange` 转发给了全体订阅者，
/// 于是「整个界面每秒重画十次」——实测光这一条就吃掉 40% CPU（风扇也是这么来的）。
/// 拆出来之后，只有真正显示时间的那几块（进度条、时间标签、歌词）订阅它。
@MainActor
final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var time: TimeInterval = 0
}

/// 「从列表播放」的上下文：整份可见行 + 要起播的那一首在其中的下标。
/// Music 里对列表行做的任何一种「播放」（双击 / 回车 / ••• / 右键）都是同一件事：
/// 从这一行开始播，后面按当前排序与筛选接着放。
struct TrackPlayContext: Equatable { var tracks: [Track]; var index: Int }

/// AVPlayer 队列封装：播放/暂停/切歌/循环/随机，自动连播与系统集成。
///
/// **不要往这里加 `@Published`**：`AppState` 把本对象的`objectWillChange` 转发给了
/// 全体订阅者，任何按帧/按缓冲变化的量一旦 `@Published`，整个界面就会跟着它重画
/// （`PlaybackClock` 就是为此拆出去的）。交叉淡入淡出、增强器、响度测量全程
/// 不发一次 `objectWillChange`。
@MainActor
final class PlayerController: ObservableObject {

    enum RepeatMode: Int, CaseIterable {
        case off, all, one
    }

    /// 队列项的来源。对应 Music `ITPlayQueueModel` 的`sectionKind`
    /// （[实测] playqueue spec §2.1：1=history / 3=manuallyQueued / 4=continuePlaying / 5=autoplay）：
    /// - `.manual` = 用户「稍后播放 / 加入待播清单」加的（Up Next，kind 3）；
    /// - `.source` = 起播那份列表剩下的（继续播放，kind 4）；
    /// - `.autoplay` = 自动连播续上的（kind 5）。由`refillAutoplayIfNeeded` 追加到队尾，
    ///   见 `PlayQueueModel.autoplayAvailable` 与`MusicProvider.similarTracks`。
    ///
    /// 「历史」不是一种来源：Music 的 kind 1 是**位置**（已播过的那一段），
    /// 同一项从 Up Next 播过去就落进 history，来源不变。所以分区推导要
    /// 「先看在不在 `currentIndex` 之前，再看 origin」，见`PlayQueueModel.sections`。
    enum QueueOrigin: Hashable {
        case source, manual, autoplay
    }

    /// 「继续播放」分区的来源（专辑 / 歌单名 ＋ 能跳转的话给个 `Route`）。
    /// 对应 [实测] playqueue spec §2.1 的 `continuePlayingSource`
    /// 与 §2.4 的 `continuePlayingSourceIsActionable` / `doContinuePlayingSourceClicked`
    /// ——那两个方法坐实了「来源标签仅在来源本身可导航时才响应点击」，
    /// 所以这里把「名字」和「能不能去」分成两个字段存。
    struct QueueSource: Equatable {
        var title: String
        var route: Route?

        init(title: String, route: Route? = nil) {
            self.title = title
            self.route = route
        }
    }

    // MARK: - 双路交接的状态机

    /// 「下一步该干什么」。从 `next()` 里抽出来的纯结果：预取与真正切歌共用同一份判断。
    enum NextStep: Equatable {
        /// 下一首在 `queue` 里的下标。`reshuffle` 为真表示随机序整体到头、要重洗一遍
        /// 才知道是哪一首，此时 `index` 无意义（−1），也就没法提前取流。
        case play(index: Int, reshuffle: Bool)
        case stop
    }

    /// 两首之间怎么接。
    enum HandoffMode: Equatable {
        /// 不接：老路，上一首播完才去解析下一首（过渡关掉时就是这一档）
        case none
        /// 无缝：提前取好流，end 通知一到立刻出声，不做音量交叠（同专辑的相邻曲目）
        case gapless
        /// 交叉淡入淡出，`seconds` 秒
        case crossfade(seconds: TimeInterval)
    }

    /// 一次预取。`queueVersion` 用来判断「取回来时队列还是不是原来那个」。
    struct Prefetch {
        let step: NextStep
        let track: Track
        let mode: HandoffMode
        let queueVersion: Int
    }

    enum StandbyPhase {
        case idle
        case prefetching(Prefetch)
        case ready(Prefetch)
        /// 两路同时出声：**`current` 还是退场那一首**，另一路（`other`）已经在放新歌。
        ///
        /// 这一段里「正在播放」的身份不换手——标题、封面、进度、歌词、系统面板
        /// 全程跟着退场那一首，直到它自己播到结尾（`handleTrackEnded` → `next` →
        /// `adoptStandbyIfMatches`）才整体交给新歌。用户的原话是
        /// 「应该是提前响起声音就行，不用切 nowplaying」。
        case overlapping(Prefetch)
    }

    /// 交接的日志。实听觉得不对时开 Console 看这一路：
    /// `log stream --level debug --predicate 'subsystem == "com.changlepan.Amber" AND category == "player.handoff"'`
    /// tap 的实时回调里**一行都不许有**（那是实时线程）。
    static let handoffLog = Logger(subsystem: "com.changlepan.Amber", category: "player.handoff")

    /// `makeItem` 的产物：item、音频加工、以及音轨自己报的时长。
    struct LoadedItem {
        let item: AVPlayerItem
        let mix: DeckAudioMix?
        /// `AVAssetTrack.timeRange.duration`，见`workingDuration`。
        let assetSeconds: TimeInterval?
    }

    @Published private(set) var queue: [Track] = []
    /// 与 `queue` **一一对应**的来源标记，长度恒等于`queue.count`。
    /// 队列面板的四个分区全靠它推（见 `PlayQueueModel.sections`），
    /// 所以每一处动 `queue` 的地方都要同步动它——这是硬不变式，`PlayQueueModelTests` 在断言。
    @Published private(set) var queueOrigins: [QueueOrigin] = []
    /// 这一队是从哪份列表起播的。`play(_:startAt:source:)` 写入，传 nil 就清空；
    /// 「继续播放」分区头上那行「来自…」与那颗「清除」都读它。
    @Published private(set) var queueSource: QueueSource?
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    /// 播放进度。转发到 `clock`，**不是**`@Published`——见`PlaybackClock` 的注释。
    let clock = PlaybackClock()
    var currentTime: TimeInterval {
        get { clock.time }
        set { clock.time = newValue }
    }
    @Published var duration: TimeInterval = 0
    @Published var repeatMode: RepeatMode = .off
    @Published var isShuffled = false
    @Published var volume: Double = 1.0 {
        // 母音量在 player 上，淡入淡出在 audioMix 里，两者相乘。两路都要写：
        // 过渡期间两路同时出声，只写一路会让退场那首突然变响。
        didSet {
            deckA.player.volume = Float(volume)
            deckB.player.volume = Float(volume)
        }
    }
    /// 播放失败的提示（如 VIP 曲目无权限）
    @Published var lastError: String?
    /// 当前这一路流的真实规格（采样率/位深/编码），就绪后从 asset 读出来。
    /// 迷你播放器的音质气泡显示它——设置里选的档位会降级，气泡要报实际拿到的那一档。
    @Published private(set) var streamFormat: StreamFormat?

    /// 由 AppState 注入：解析曲目流地址
    var providerResolver: ((Track) async throws -> URL)?
    /// 由 AppState 注入：本地曲目的原始文件找不着了（`ProviderError.localFileMissing`），
    /// 而且这一首是**用户自己点播的**。界面层接过去弹「你想要查找它吗？」
    /// （`MissingFileLocator`，spec §10.1）。
    ///
    /// 弹窗为什么不在这一层：播放器是播放层，不做 UI 决策；而「该不该弹」这件事
    /// 也只有这里判得出——预取（`prepareStandby`）同样会撞上文件缺失，
    /// 那一路一声不吭才是对的。
    var onLocalFileMissing: ((Track) -> Void)?
    /// 由 AppState 注入：一首歌被「跳过」时记一笔（资料库「跳过次数」列）。
    /// 什么才算跳过见 `next(userInitiated:)` 里的窗口判定。
    var onSkip: ((Track) -> Void)?
    /// 由 AppState 注入：曲目**真正开始出声**时调一次（item 就绪那一刻）。
    /// 只用来更新「最近播放」，不动播放次数——Music 的「最近播放」是「开始听过」的口径，
    /// 点开就算；播放次数则要听完才算，见 `onTrackPlayed`。
    var onTrackStarted: ((Track) -> Void)?
    /// 由 AppState 注入：曲目**播到结尾**时调一次，单曲循环每绕一遍都算一次。
    /// 播放次数与「上次播放时间」吃这一条：Music 里没听完就切走的那首不加次数，
    /// 所以记账点必须在结尾、不能在开播那一刻。
    var onTrackPlayed: ((Track) -> Void)?
    /// 由 AppState 注入：这首以前量过响度没有（音量平衡用）。
    var loudnessProvider: ((Track) -> LoudnessEntry?)?
    /// 由 AppState 注入：一首整整播完、响度量出来了，写回缓存。
    var onLoudnessMeasured: ((Track, LoudnessEntry) -> Void)?
    /// 由 AppState 注入：这首歌在歌曲表的勾选列里勾着没有。
    /// 未勾选的歌**只在自动往下走时**被跳过（顺播、随机、播完自动接），
    /// 双击、下一首、••• 菜单这些用户主动的入口一概照放（Music/iTunes 语义）。
    /// 没注入时一律当勾着，行为与没有这条开关时逐字一致。
    var isTrackChecked: ((Track) -> Bool)?
    /// 由 AppState 注入：当前该允许哪些空间化格式（跟着输出设备与「杜比全景声」偏好走）。
    /// 没注入时按设置里的模式直接折算，见 `spatializationFormats()`。
    var spatializationProvider: (() -> AVAudioSpatializationFormats)?
    /// 由 AppState 注入：自动连播——拿一首歌去问它的音源要**相似歌曲**
    /// （`MusicProvider.similarTracks`）。候选源就这一条，别再往里掺别的召回，
    /// 理由（连同 2026-09-09 那次接错）写在 `MusicProvider.similarTracks` 的注释里。
    var autoplayCandidatesProvider: ((Track, Int) async -> [Track])?
    /// 由 AppState 注入：这个音源有没有相似歌曲接口（`MusicProvider.supportsAutoplay`）。
    /// 没注入时一律当没有，行为与「自动连播关着」一致。
    var autoplaySupported: ((ProviderKind) -> Bool)?

    // MARK: 「显示简介」面板的逐曲覆盖（`TrackInfoStore`，由 AppState 注入）
    //
    // **三条闭包一律「没注入 / 返回 nil ＝ 走原来那条路，一行不差」**。面板上这几项
    // 是极少数曲目才会设的，正常播放不能为它们多绕一步。

    /// 这一首在面板里设过「开始 / 停止时间、随机播放时跳过、音量调整」没有。
    var playbackOverridesProvider: ((String) -> PlaybackOverrides?)?
    /// 「记住播放位置」记下的断点（只有勾了那一项的曲目才会有）。
    var resumePositionProvider: ((String) -> TimeInterval?)?
    /// 记 / 清断点。播到哪儿报到哪儿（10 Hz），播完整首报 nil。
    var onResumePosition: ((String, TimeInterval?) -> Void)?

    /// 这一首的「停止时间」已经触发过：`handleTick` 每 0.1 s 来一次，触发一次就够了。
    private var stopTimeFiredForTrackID: String?

    var currentTrack: Track? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    /// 当前这一首是**用户主动点播**的，还是自动往下走走到的。
    ///
    /// 只有一个消费者：本地文件缺失时该不该弹对话框（见 `onLocalFileMissing`）。
    /// 与「算不算一次跳过」那条判据无关，两者的 `userInitiated` 各管各的。
    private(set) var currentStartIsUserInitiated = true

    /// 切走时算不算一次跳过的时间窗，见 `next(userInitiated:)`。
    static let skipWindow: Range<TimeInterval> = 2..<20

    /// 淡出走哪条路。
    ///
    /// `false`（主路）：给退场那一路的`AVMutableAudioMixInputParameters` 补一段音量斜坡，
    /// 再把 `audioMix` 重新赋回 item。代价是 tap 会经历一次 unprepare→prepare。
    /// `true`（备选）：淡出增益搬进 tap 自己算（按`MTAudioProcessingTapGetSourceAudio`
    /// 报回来的 `timeRange`），退场那一路完全不用重装 mix。
    /// **实听判据**：主路在过渡起点有没有「咔哒」；有就把这里改成 `true`。
    static let fadeOutViaTap = false

    /// 沉浸声（AC-3 / E-AC-3 JOC）的 item 要不要挂 `audioMix`（＝斜坡 + tap）。
    ///
    /// `true`（当前）：所有 item 一视同仁，过渡、增强器、音量平衡对沉浸声也生效。
    /// `false`（备选）：沉浸声的 item 不挂 mix 也不挂 tap，`handoffMode` 把它们
    /// 一律按 `.gapless` 接（交叉淡入淡出得有 mix 才做得出斜坡），
    /// 增强器与音量平衡对沉浸声曲目失效。
    /// **实听判据**：挂上 tap 之后杜比空间化还在不在——带 `audioMix` 的 E-AC-3 有可能
    /// 被 AVFoundation 拉去走软件混音、跳过空间化渲染。听到「变成普通立体声」就改成 `false`，
    /// 只改这一个常量，别处不用动。
    static let attachMixToSpatialItems = true

    private let deckA = PlaybackDeck()
    private let deckB = PlaybackDeck()
    /// 出声的那一路
    private var current: PlaybackDeck
    /// 另一路（预取 / 退场）
    private var other: PlaybackDeck { current === deckA ? deckB : deckA }

    private var endObserver: NSObjectProtocol?
    private var settingsCancellable: AnyCancellable?
    private var shuffleOrder: [Int] = []
    private var shuffleCursor = 0
    /// 连续取流失败的次数。整队都放不出来时用它兜底，避免一路空跳到队尾。
    private var failureStreak = 0
    /// 上次向系统「正在播放」面板推送的时刻
    private var lastNowPlayingPush: TimeInterval = 0

    private var standbyPhase: StandbyPhase = .idle
    /// 每次动队列（播放/插入/随机/循环/停止）自增。在飞的预取拿着旧号回来就作废。
    private var queueVersion = 0
    /// 这一首被 seek 进了尾段：斜坡按绝对时间装，落到斜坡中段会起手半音量，
    /// 所以本首直接放弃过渡走老路。换歌时清掉。
    private var fadeSuppressedForCurrent = false
    /// 这一首的交叠被「位置离结尾太远」那道闸拦下过（见 `shouldBeginOverlap`）。
    /// 只是为了不让日志每 100 ms 刷一行；时长被精修之后会重新给一次机会。
    private var overlapSkippedForCurrent = false
    /// 用户此刻想不想出声。`pause()` 置假，用户主动起播 / 换歌置真。
    ///
    /// 所有**自动**的 `play()`（item 就绪、交叠开始、接管、单曲循环）都先看它：
    /// 用户在交叠里按了暂停，不能因为退场那一路又回报了一次就绪、或者它播到了结尾
    /// 就把声音重新放出来——那次 bug 的表现是「暂停后下一首没停，静默播完就切歌」。
    private var wantsPlayback = true
    private var audioPrefs = AudioPrefs(soundEnhancer: false, soundEnhancerLevel: 0, soundCheck: false)
    /// 「歌曲过渡」的缓存副本。tick 是 10 Hz，不能每跳都去拷一份几十个字段的
    /// `SettingsValues` 出来问一个 Bool。
    private var crossfadeEnabled = false
    private var crossfadeCancellable: AnyCancellable?

    /// 「自动连播」开关的缓存副本，来源同上（`SettingsValues.playQueueAutoplay`）。
    private var autoplayOn = false
    private var autoplayCancellable: AnyCancellable?
    /// 正在补的那一批。换歌/换队列时取消，见 `refillAutoplayIfNeeded`。
    private var autoplayTask: Task<Void, Never>?
    /// 「这一轮已经按这首补过了」。**按种子曲目 id 去重**，不是按次数：
    /// `startCurrent()` 每次换歌都会调`refillAutoplayIfNeeded`，没有这个标记的话
    /// 队列一直不够长（音源只肯给 5 首）就会每换一首都打一次网络。
    private var autoplaySeedID: String?

    init() {
        current = deckA
        audioPrefs = AudioPrefs(AppSettings.shared.values)
        crossfadeEnabled = AppSettings.shared.values.crossfade
        autoplayOn = AppSettings.shared.values.playQueueAutoplay

        for deck in [deckA, deckB] {
            deck.onTick = { [weak self] deck, seconds in self?.handleTick(deck, seconds) }
            deck.onStatus = { [weak self] deck, _, status in self?.handleStatus(deck, status) }
            deck.onBoundary = { [weak self] deck, _ in self?.handleBoundary(deck) }
            deck.onDurationChanged = { [weak self] deck, _ in self?.handleDurationChanged(deck) }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 交叠期间 `current` 仍然是退场那一首，所以这一条就是它的结尾通知：
                // 照常走 `handleTrackEnded`（记账 → next → 接管已经在响的那一路）。
                if item === self.current.item { self.handleTrackEnded() }
            }
        }

        // 设置窗一按「好」就整份写回，`removeDuplicates` 之后只有音频那三项真变了才推给 tap。
        settingsCancellable = AppSettings.shared.$values
            .map(AudioPrefs.init)
            .removeDuplicates()
            .sink { [weak self] prefs in
                guard let self else { return }
                self.audioPrefs = prefs
                self.deckA.mix?.tap?.apply(prefs)
                self.deckB.mix?.tap?.apply(prefs)
            }
        crossfadeCancellable = AppSettings.shared.$values
            .map(\.crossfade)
            .removeDuplicates()
            .sink { [weak self] in self?.crossfadeEnabled = $0 }
        // 「自动连播」翻开就立刻补一批（不等下一次换歌），翻关就把已经补进来的清掉。
        autoplayCancellable = AppSettings.shared.$values
            .map(\.playQueueAutoplay)
            .removeDuplicates()
            .sink { [weak self] on in
                guard let self else { return }
                self.autoplayOn = on
                if on { self.refillAutoplayIfNeeded() } else { self.clearAutoplayItems() }
            }
    }

    /// `isolated deinit`：观察者令牌是 `any NSObjectProtocol`，非隔离的 deinit 摸不了。
    /// 注销时机不变——播放器由主 actor 上的 `AppState` 持有，最后一次释放本来就在主 actor 上，
    /// 隔离的 deinit 在那里是就地同步跑的。
    isolated deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: - 队列控制

    /// 播放一组曲目。
    ///
    /// **不动随机开关**：Music 里随机开着时双击列表某一行，是「先放这首、其余按随机接上」，
    /// 开关照旧亮着（从前这里一进来就 `isShuffled = false`，等于用户双击一次就被悄悄关掉）。
    /// 所以随机开着就以起播那首为头重建一遍随机序，关着就按传进来的顺序放。
    /// `source` 是「继续播放」分区头要显示的那份列表（歌单名 / 专辑名 ＋ 可跳转的`Route`）。
    /// 有默认值 nil，是为了让「不知道自己从哪来」的起播点（单曲、卡片上的 ▶）不用改也能编译。
    func play(_ tracks: [Track], startAt index: Int = 0, source: QueueSource? = nil) {
        guard !tracks.isEmpty else { return }
        wantsPlayback = true
        let clamped = min(max(index, 0), tracks.count - 1)
        // 交叠期间从别的列表起播：退场那一首掐掉并照记一次播放。
        cutOverlapOutgoing()
        invalidateStandby()
        queue = tracks
        // 新起播的整份列表都算「继续播放」（[实测] playqueue spec §2.1 kind 4：
        // 「队列原有的、专辑/歌单剩余曲目」）；手动加的项此刻一个都没有。
        queueOrigins = .init(repeating: .source, count: tracks.count)
        queueSource = source
        currentIndex = clamped
        // 换了一整队：上一队正在补的那批作废，「已经按这首补过」的标记也清掉
        // （同一首歌在新队列里可能又当上种子）。
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplaySeedID = nil
        failureStreak = 0
        currentStartIsUserInitiated = true
        if isShuffled {
            // buildShuffleOrder 会把起播那首挪到序首，所以游标就是 0。
            buildShuffleOrder(startingAt: clamped)
            shuffleCursor = 0
        }
        startCurrent()
    }

    /// 播放单个曲目（插入到当前队列之后）
    func playSingle(_ track: Track) {
        guard let idx = currentIndex else {
            play([track])
            return
        }
        insert([track], at: idx + 1, shuffledAt: shuffleCursor + 1, origin: .manual)
        playIndex(idx + 1)
    }

    func playTrack(at index: Int) {
        guard queue.indices.contains(index) else { return }
        failureStreak = 0
        // 交叠期间双击另一行：与按下一首同一个口径，退场那一首掐掉并照记一次播放。
        cutOverlapOutgoing()
        playIndex(index)
    }

    /// 「稍后播放」：插到当前曲目之后（Music 的 `doPlayNext:`）。
    /// 队列空时退化成直接播放这批曲目。
    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard let index = currentIndex else {
            play(tracks)
            return
        }
        insert(tracks, at: index + 1, shuffledAt: shuffleCursor + 1, origin: .manual)
    }

    /// 「加入待播清单」：追加到 **Up Next 分区的末尾**（Music 的 `doPlayLast:`）。
    ///
    /// 从前这里是插到 `queue.count`（整队队尾），那等于排到「继续播放」后面去了。
    /// [实测] playqueue spec §2.1 把队列切成 history / manuallyQueued(Up Next) /
    /// continuePlaying / autoplay 四个 `sectionKind`，§3.4 的快照又按
    /// **0=history → 1=upNext → 2=continuePlaying → 3=autoplay** 的顺序 append——
    /// 面板从上往下就是播放顺序，所以手动加的项**永远排在「继续播放」之前**。
    /// 落到 Amber 这边就是：插到「当前曲之后那一串连续 `.manual` 项」的后面。
    ///
    /// 不变式（`PlayQueueModelTests` 在断言）：`currentIndex` 之后先是一串`.manual`，
    /// 再才是 `.source` / `.autoplay`。
    func playLast(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard let index = currentIndex else {
            play(tracks)
            return
        }
        var slot = index + 1
        while slot < queueOrigins.count, queueOrigins[slot] == .manual { slot += 1 }
        // 随机序里也排在同一串手动项之后：`slot - index` 就是「当前曲往后数几格」。
        insert(tracks, at: slot, shuffledAt: shuffleCursor + (slot - index), origin: .manual)
    }

    /// 往队列里插一批曲目（面板从外部拖进来时用）。`index` 是落点**之前**。
    /// `origin` 决定它落进哪个分区：拖到「继续播放」里就是`.source`，其余都算用户手动加的。
    func insertIntoQueue(_ tracks: [Track], at index: Int, origin: QueueOrigin = .manual) {
        guard !tracks.isEmpty else { return }
        guard currentIndex != nil else {
            play(tracks)
            return
        }
        let slot = min(max(index, 0), queue.count)
        // 随机序里插在「落点那一项」的位置上；落点是队尾就排到随机序末尾。
        let shuffleSlot = shuffleOrder.firstIndex(of: slot) ?? shuffleOrder.count
        insert(tracks, at: slot, shuffledAt: shuffleSlot, origin: origin)
    }

    /// 往队列里插一批曲目。随机序保存的是 queue 下标，插入会把插入点之后的下标整体后移，
    /// 得同步搬一次，否则随机播放会跳错歌。`queueOrigins` 与`queue` 等长，同步插同样多条。
    private func insert(_ tracks: [Track], at index: Int, shuffledAt shuffleSlot: Int,
                        origin: QueueOrigin) {
        invalidateStandby()
        queue.insert(contentsOf: tracks, at: index)
        queueOrigins.insert(contentsOf: Array(repeating: origin, count: tracks.count), at: index)
        if let current = currentIndex, current >= index {
            currentIndex = current + tracks.count
        }
        guard !shuffleOrder.isEmpty else { return }
        shuffleOrder = shuffleOrder.map { $0 >= index ? $0 + tracks.count : $0 }
        let slot = min(max(shuffleSlot, 0), shuffleOrder.count)
        shuffleOrder.insert(contentsOf: index..<(index + tracks.count), at: slot)
    }

    // MARK: 队列面板的三个编辑动作（[实测] playqueue spec §1.3 / §2.3）

    /// 批量移除队列项（面板选中若干行按 Delete，或右键「移除」）。
    ///
    /// [实测] playqueue spec §2.3：Music 的 `doDeleteActionForItem:` 只做「删这一项」，
    /// 没有「删了当前曲要怎么办」的分支——那归引擎 `removeContentItemID:` 管，
    /// 静态里没坐实。Amber 这边取「删的就是正在播的那首 → 跳到下一首活着的项」，
    /// 沿用 `playIndex`；当前曲连同它后面的项一起被删光时收掉播放器（`haltPlayback`），
    /// 前面的历史留着。这一段是 `[推]`。
    ///
    /// `currentIndex` / `queueOrigins` / `shuffleOrder` / `shuffleCursor` 一起搬：
    /// 随机序存的是 queue 下标，删掉几项之后**每个下标都要重算**，
    /// 漏搬的表现与 `insert` 那条注释里说的一样——随机播放跳错歌。
    func removeFromQueue(at indices: IndexSet) {
        let removed = Set(indices.filter { queue.indices.contains($0) })
        guard !removed.isEmpty else { return }
        invalidateStandby()

        let oldCount = queue.count
        // 旧下标 → 新下标。被删的没有对应项。
        var mapping: [Int: Int] = [:]
        var next = 0
        for i in 0..<oldCount where !removed.contains(i) {
            mapping[i] = next
            next += 1
        }

        let old = currentIndex
        let removingCurrent = old.map { removed.contains($0) } ?? false
        // 删的是当前曲：先在**旧**下标里找到它后面第一个活着的项。
        let successor = removingCurrent
            ? ((old! + 1)..<oldCount).first { !removed.contains($0) }
            : nil

        queue = queue.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        queueOrigins = queueOrigins.enumerated()
            .filter { !removed.contains($0.offset) }.map(\.element)

        // 随机序：先按「游标之前删掉了几个」把游标往回收，再重映射下标。
        if !shuffleOrder.isEmpty {
            let cursorDrop = shuffleOrder.prefix(min(shuffleCursor, shuffleOrder.count))
                .filter { removed.contains($0) }.count
            shuffleOrder = shuffleOrder.compactMap { mapping[$0] }
            shuffleCursor = max(0, min(shuffleCursor - cursorDrop, shuffleOrder.count))
        }

        if let old, !removingCurrent {
            currentIndex = mapping[old]
        } else if removingCurrent {
            if let successor, let target = mapping[successor] {
                playIndex(target)
            } else {
                // 当前曲之后一个都不剩：等于「队列到头」。
                currentIndex = nil
                haltPlayback()
            }
        }
    }

    /// 队列内部拖拽重排（[实测] playqueue spec §2.2 `doReorderItemsWithIdentifiers:beforeItem:`）。
    /// `destination` 是**旧**下标里的落点，语义是「插到这一项之前」；`queue.count` 就是排到队尾。
    /// 与 `removeFromQueue` 同理，靠一张「旧下标 → 新下标」的映射一次把
    /// `queue` / `queueOrigins` / `shuffleOrder` / `currentIndex` 全搬过去。
    func moveInQueue(_ indices: IndexSet, to destination: Int) {
        let moving = indices.filter { queue.indices.contains($0) }.sorted()
        guard !moving.isEmpty else { return }
        let dest = min(max(destination, 0), queue.count)
        let movingSet = Set(moving)
        var order = (0..<queue.count).filter { !movingSet.contains($0) }
        // 落点换算：留下的那些项里，第一个「旧下标 ≥ dest」的位置就是插入位。
        let slot = order.firstIndex { $0 >= dest } ?? order.count
        order.insert(contentsOf: moving, at: slot)
        guard order != Array(0..<queue.count) else { return }

        invalidateStandby()
        var mapping: [Int: Int] = [:]
        for (newIndex, oldIndex) in order.enumerated() { mapping[oldIndex] = newIndex }
        queue = order.map { queue[$0] }
        queueOrigins = order.map { queueOrigins[$0] }
        // 重排不增删元素，随机序里的**位置**不变，只有它存的下标要换一遍；
        // 于是 `shuffleCursor` 照旧指着同一首。
        shuffleOrder = shuffleOrder.compactMap { mapping[$0] }
        if let current = currentIndex { currentIndex = mapping[current] }
    }

    /// 「继续播放」分区头那颗「清除」（[实测] playqueue spec §3.6：按钮的 enabled
    /// 绑在 `continuePlayingItems` 非空上；§1.3 引擎侧对应`clearAllItemsAfterContentItemID:`）。
    /// 把当前曲之后所有 `.source` / `.autoplay` 项删掉，手动加的（Up Next）与历史都不动，
    /// 再清掉「来自…」那行的来源。
    func clearContinuePlaying() {
        let start = (currentIndex ?? -1) + 1
        guard start <= queue.count else { return }
        let victims = IndexSet((start..<queue.count).filter { queueOrigins[$0] != .manual })
        if !victims.isEmpty { removeFromQueue(at: victims) }
        queueSource = nil
    }

    // MARK: 自动连播（队列面板顶部那颗 ∞）

    /// 当前曲之后剩不到这么多项就去补一批。
    ///
    /// 取 3 的理由：过渡（交叉淡入淡出）最多提前 12 秒预取**下一首**，所以只要队尾
    /// 始终留着 2 首以上，续队列这条网络就永远在预取之前跑完，用户听不出接缝；
    /// 再大就变成「提前一整段猜用户要听什么」，换歌之后那批多半又被后面的种子顶掉。
    /// spec 没有坐实这个数（§3.4 只说分区 3 装 `autoplayItems`），这一条是`[推]`。
    static let autoplayRefillThreshold = 3

    /// 一次最多补几首。音源本来就给不满（[实测] 网易云匿名恒 5 首、QQ 一次 15 首上下），
    /// 这个上限是防「服务端哪天改口一次发几百条」把队列灌爆。`[推]`
    static let autoplayBatchSize = 10

    /// 该不该续队列（纯函数，可单测）。
    /// 没有当前曲（队列空、或还没起播）就不续——自动连播是「接着当前这首放」，没有种子无从谈起。
    nonisolated static func autoplayShouldRefill(queueCount: Int, currentIndex: Int?,
                                                threshold: Int) -> Bool {
        guard let currentIndex, currentIndex >= 0, currentIndex < queueCount else { return false }
        return queueCount - currentIndex - 1 < threshold
    }

    /// 从候选里挑出真正要追加的（纯函数，可单测）：
    /// 已经在队列里的（**含历史**——刚播过的又排回队尾是自动连播最容易犯的错）一律不要，
    /// 候选自身重复的只留第一条，最后按 `limit` 截断。
    nonisolated static func autoplayAdditions(candidates: [Track], existing: [Track],
                                             limit: Int) -> [Track] {
        guard limit > 0 else { return [] }
        var seen = Set(existing.map(\.id))
        var out: [Track] = []
        for track in candidates where !seen.contains(track.id) {
            seen.insert(track.id)
            out.append(track)
            if out.count == limit { break }
        }
        return out
    }

    /// 要清掉的自动连播项（纯函数，可单测）。
    ///
    /// 只算**当前曲之后**的 `.autoplay` 项，与`clearContinuePlaying` 同一个起点：
    /// 当前曲之前的落在「历史」分区（面板上根本不在自动播放那一段里），
    /// 正在播的那首更不能删——一关开关就把歌掐了不是任何一处 spec 的意思。`[推]`
    nonisolated static func autoplayVictims(origins: [QueueOrigin], currentIndex: Int?) -> IndexSet {
        let start = (currentIndex ?? -1) + 1
        guard start < origins.count else { return IndexSet() }
        return IndexSet((start..<origins.count).filter { origins[$0] == .autoplay })
    }

    /// 关掉「自动连播」时把已经补进来的项清掉。
    ///
    /// `[推]`：Music 那边关掉自动播放会把该分区清掉（面板上分区 3 整段消失），
    /// playqueue spec 里没有对应的方法名坐实这件事，照观感做。
    func clearAutoplayItems() {
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplaySeedID = nil
        let victims = Self.autoplayVictims(origins: queueOrigins, currentIndex: currentIndex)
        if !victims.isEmpty { removeFromQueue(at: victims) }
    }

    /// 队尾快见底就拿**当前这首**去问音源要候选，以 `.autoplay` 追加到队尾。
    /// `startCurrent()` 每次换歌调一次，设置里翻开开关也调一次。
    ///
    /// 「无限」是这么来的：`autoplaySeedID` 只挡住「同一个种子问第二次」，
    /// 而队列播进自动播放分区之后**当前曲一直在往前走**，于是每换一首就是一个新种子、
    /// 队尾又快见底，自然再补一批——不需要谁去循环调它。
    private func refillAutoplayIfNeeded() {
        guard autoplayOn, let index = currentIndex, queue.indices.contains(index) else { return }
        let seed = queue[index]
        guard autoplaySupported?(seed.kind) == true,
              let ask = autoplayCandidatesProvider else { return }
        guard Self.autoplayShouldRefill(queueCount: queue.count, currentIndex: index,
                                        threshold: Self.autoplayRefillThreshold) else { return }
        // 这一轮已经按这首补过了：补到没补到都不再打第二次网络。
        guard autoplaySeedID != seed.id else { return }
        autoplaySeedID = seed.id
        autoplayTask?.cancel()
        autoplayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.appendAutoplayBatch(seed: seed,
                                              expectedCurrentID: seed.id, ask: ask) { return }
            // 问到了、但去重之后一首不剩（音源翻来覆去就那几首，队列里全有了）：
            // 换**队尾那首**当种子再问一次。种子往后挪一格才问得出新东西来。
            // **只重试这一次**——不递归、不循环，还是空就这一轮放弃，
            // 等下次换歌带着新的当前曲再来。
            guard let tail = self.queue.last, tail.id != seed.id else { return }
            _ = await self.appendAutoplayBatch(seed: tail,
                                               expectedCurrentID: seed.id, ask: ask)
        }
    }

    /// 补一批的一趟：问音源要候选 → 去重 → 追加到队尾。
    ///
    /// 返回**这一轮到此为止**：补进去了、被取消了、或者队列已经整个换掉了都算「到此为止」；
    /// 只有「问到了但去重后一首不剩」才回 `false`，由调用方换个种子再试一次。
    private func appendAutoplayBatch(seed: Track, expectedCurrentID: String,
                                     ask: (Track, Int) async -> [Track]) async -> Bool {
        let candidates = await ask(seed, Self.autoplayBatchSize)
        guard !Task.isCancelled else { return true }
        // 一趟网络的工夫里队列可能整个换掉了（用户点了别的专辑）：
        // 当前曲已经不是发起这一轮的那首就把这批丢掉，别往新队列尾巴上贴旧歌的相似曲。
        guard let now = currentIndex, queue.indices.contains(now),
              queue[now].id == expectedCurrentID else { return true }
        let additions = Self.autoplayAdditions(candidates: candidates, existing: queue,
                                               limit: Self.autoplayBatchSize)
        guard !additions.isEmpty else { return false }
        // 追加到**整队队尾**：分区顺序是 history → upNext → continuePlaying → autoplay，
        // 自动连播那一段永远在最后（[实测] playqueue spec §3.4）。
        insert(additions, at: queue.count, shuffledAt: shuffleOrder.count, origin: .autoplay)
        return true
    }

    func toggleShuffle() {
        invalidateStandby()
        isShuffled.toggle()
        if isShuffled {
            buildShuffleOrder(startingAt: currentIndex ?? 0)
            if let i = currentIndex { shuffleCursor = shuffleOrder.firstIndex(of: i) ?? 0 }
        }
    }

    func cycleRepeatMode() {
        invalidateStandby()
        let all = RepeatMode.allCases
        repeatMode = all[(all.firstIndex(of: repeatMode)! + 1) % all.count]
    }

    // MARK: - 播放控制

    /// 位置已经在（或几乎在）结尾时，`AVPlayer.play()` 是**空操作**。
    ///
    /// 队列播完那一支（见 `next()`）会`pause()` 并把位置钉在`duration`，
    /// `AVPlayerItem` 也停在那儿。此时按播放键：`timeControlStatus` 会短暂变
    /// `.playing`（图标跟着翻成暂停、`isPlaying` 变真），位置却纹丝不动——
    /// 表现就是「点了没反应，只有图标翻了个面」。所以起播前要先回到开头。
    private static let endTolerance: TimeInterval = 0.35

    private var isAtEnd: Bool {
        guard duration > 0 else { return false }
        let item = current.player.currentItem?.currentTime().seconds
        let position = (item?.isFinite == true) ? item! : currentTime
        return position >= duration - Self.endTolerance
    }

    /// 起播。停在结尾时先回到开头，否则 `play()` 不产生任何效果。
    private func startPlayback() {
        wantsPlayback = true
        if isAtEnd { seek(to: 0) }
        current.player.play()
        if case .overlapping = standbyPhase { other.player.play() }
        Self.handoffLog.debug("起播 阶段=\(String(describing: self.standbyPhase), privacy: .public)")
    }

    func togglePlayPause() {
        guard let index = currentIndex, queue.indices.contains(index) else { return }
        // 取流失败后播放器里是空的，AVPlayer.play() 只会空转（timeControlStatus
        // 停在 WaitingWithNoItemToPlay），按播放键得重新取一次流。
        if current.player.currentItem == nil {
            failureStreak = 0
            playIndex(index)
            return
        }
        if current.player.rate > 0 { pause() } else { startPlayback() }
    }

    func pause() {
        wantsPlayback = false
        current.player.pause()
        if case .overlapping = standbyPhase { other.player.pause() }
        isPlaying = false
        updateNowPlaying()
        Self.handoffLog.debug("暂停 阶段=\(String(describing: self.standbyPhase), privacy: .public)")
    }

    func resume() {
        guard let index = currentIndex, queue.indices.contains(index) else { return }
        if current.player.currentItem == nil {
            failureStreak = 0
            playIndex(index)
            return
        }
        startPlayback()
        isPlaying = true
        updateNowPlaying()
    }

    /// `userInitiated` 为真表示是用户主动切歌；自然播完与取流失败的自动跳转都不算跳过。
    ///
    /// 「算不算一次跳过」照 Music 的窗口来：**播了 2 秒以上、20 秒以内**切走才记。
    /// 从前的判据是「没放完就算」，于是听了三分钟只差最后一秒切走也记一次跳过；
    /// 而下界的 2 秒挡掉「连按下一首翻过一串歌」——那是在找歌，不是嫌这首难听。[推]
    /// 窗口的两个端点没有静态数据可对，取的是 Music 社区长期公认的口径。
    func next(userInitiated: Bool = true) {
        guard !queue.isEmpty else { return }
        currentStartIsUserInitiated = userInitiated
        if userInitiated {
            wantsPlayback = true
            failureStreak = 0
            if let track = currentTrack, Self.skipWindow.contains(currentTime) {
                onSkip?(track)
            }
            // 交叠期间用户按了下一首：退场那一首现在就掐掉，那一次播放照记
            // （它已经播到离结尾不足 N 秒，按「听完才算」的口径就算听完了）。
            // 进场那一路先不动——下面的 `startCurrent` 会判断目标是不是它。
            cutOverlapOutgoing()
        }
        // 自动连播（`userInitiated == false`）走的是另一条：这时候`current` 正是
        // 刚播完的那一首，记账已经在 `handleTrackEnded` 里做过，交叠那一路留给
        // `adoptStandbyIfMatches` 原地接管——不掐、不重播、不 seek。
        // 随机序没建起来（比如 currentIndex 还是 nil）时老路什么都不做，保持原样。
        guard isShuffled || currentIndex != nil else { return }
        // 自动往下走才认勾选列；用户主动按下一首照放（Music 语义）。
        let step = nextStep(skippingUnchecked: !userInitiated)
        apply(step)
        switch step {
        case .stop:
            // 队列到头了：备用那一路（可能正响着）也得收掉，不然新歌会一个人接着放。
            invalidateStandby()
            pause()
            if !isShuffled { currentTime = duration }
        case .play:
            currentTime = 0
            duration = 0
            startCurrent()
        }
    }

    func previous() {
        wantsPlayback = true
        failureStreak = 0
        currentStartIsUserInitiated = true
        // 播放超过 3 秒回到开头，否则上一首
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        cutOverlapOutgoing()
        if isShuffled {
            shuffleCursor = max(0, shuffleCursor - 1)
            playIndex(shuffleOrder[shuffleCursor])
        } else if let i = currentIndex, i > 0 {
            playIndex(i - 1)
        } else {
            seek(to: 0)
        }
    }

    // MARK: 快进 / 回退扫描

    /// [实测] nowplaying spec §3.3：方向常量 **FF = 1、Rewind = 0**
    /// （`doFF:` 非 0 →`doFFRewUsingKeyScanTimer:1`，`doRewind:` 对应 0）。
    enum ScanDirection: Int {
        case rewind = 0
        case fastForward = 1
    }

    /// 按住多久才从「点按切歌」转成扫描。Music 的键盘路径走 KeyScanTimer，
    /// 点按路径走 start/stop，两者的门槛没在静态数据里。[推]
    static let scanHoldDelay: TimeInterval = 0.35
    /// 扫描的采样周期与倍速 [推]
    private static let scanTick: TimeInterval = 0.15
    private static let scanRate: Double = 8

    private var scanTask: Task<Void, Never>?

    /// [实测] `startFFRew:`：按住期间持续推进播放位置，松手停。
    func startFFRew(_ direction: ScanDirection) {
        guard currentTrack != nil, duration > 0 else { return }
        scanTask?.cancel()
        let step = Self.scanTick * Self.scanRate * (direction == .fastForward ? 1 : -1)
        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 自己记游标，别每跳都从 currentTime 读：时间观察器 100ms 才报一次，
            // 报的还是上一次 seek 之前的位置，读它会把游标一路拖回去。
            var cursor = self.currentTime
            while !Task.isCancelled {
                cursor = min(max(cursor + step, 0), self.duration)
                // 扫描期间走带容差的 seek。逐跳的精确 seek（tolerance = 0）在流媒体上
                // 根本来不及落地——实测按住 1.5 秒只前进了 2 秒，等于没快进。
                self.seek(to: cursor, precise: false)
                // 扫到两端就停下：Music 的快进不会自己翻到下一首。
                if cursor <= 0 || cursor >= self.duration { return }
                try? await Task.sleep(for: .seconds(Self.scanTick))
            }
        }
    }

    func stopFFRew() {
        scanTask?.cancel()
        scanTask = nil
    }

    /// - Parameter precise: 拖动进度条要精确落点；快进/回退扫描要的是「跟得上手」，
    ///   给 0.3 秒容差，seek 才来得及在下一跳之前完成。
    func seek(to time: TimeInterval, precise: Bool = true) {
        let target = max(0, min(time, duration > 0 ? duration : time))
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.3, preferredTimescale: 600)
        // 交叠期间 `current` 就是用户正在听的那一首（退场那一路）：拖进度条动的是它，
        // 已经在响的新歌由 `suppressFadeIfSeekedIntoTail` 决定撤不撤。
        // 走 deck 的 seek 而不是 `player.seek`：deck 会记下「这一次还没落点」，
        // 落点之前时间观察器报的旧位置一律不认（见 `PlaybackDeck.isSeekPending`）。
        current.seek(to: CMTime(seconds: target, preferredTimescale: 600), tolerance: tolerance)
        currentTime = target
        // 往回拖到「停止时间」之前，这一首就该能再放到那儿一次（单曲循环也走这条：
        // `handleTrackEnded` 的`.one` 分支就是`seek(to: 0)`）。
        if stopTimeFiredForTrackID != nil, let track = current.track,
           stopTimeFiredForTrackID == track.id,
           target < (stopTime(for: track, duration: current.duration) ?? .infinity) {
            stopTimeFiredForTrackID = nil
        }
        // seek 过的这一首整首积分响度不作数了。
        current.mix?.tap?.markSeeked()
        suppressFadeIfSeekedIntoTail(target)
        updateNowPlaying()
    }

    /// 每帧要用的播放进度。
    ///
    /// `clock.time` 是 10 Hz 采样，够界面用，但同步歌词按显示刷新率走查
    /// （逐字渐变、行末补完都吃这个精度），所以直接问播放器。
    var elapsedTime: TimeInterval {
        // seek 未落点时播放器报的还可能是旧位置，歌词会「先弹回旧位置再跳过去」
        // （`SyncedLyricsLineView+Interaction.swift` 的 §7.6 冻结正是为了盖住这一下）。
        // 这里直接认目标点，逐字高亮就与进度条走同一条时间轴。
        if let target = current.pendingSeekTarget { return target }
        let seconds = current.player.currentTime().seconds
        return seconds.isFinite ? seconds : clock.time
    }

    func stop() {
        cutOverlapOutgoing()
        invalidateStandby()
        finishMeasurement(current)
        deckA.unload()
        deckB.unload()
        current = deckA
        queue = []
        queueOrigins = []
        queueSource = nil
        currentIndex = nil
        failureStreak = 0
        currentTime = 0
        duration = 0
        isPlaying = false
        isLoading = false
        streamFormat = nil
        updateNowPlaying()
    }

    // MARK: - 下一步（纯函数）

    /// `next()` 会往哪儿去。只读当前队列状态，不改任何东西——预取要先知道
    /// 「下一首是哪一首」，又不能真的把游标推过去。
    /// `isChecked` 是勾选列那条过滤：`false` 的下标在**自动**往下走时跳过去
    /// （顺播/随机/播完自动接），一路都没勾就与「队列到头」同解——
    /// 停下来（`repeatMode == .all` 时也一样，绕一圈还是一首都放不出来，
    /// 再绕就是死循环）。默认闭包一律返回 true ＝ 没有这条开关时的老行为。
    nonisolated static func nextStep(count: Int, currentIndex: Int?, isShuffled: Bool,
                         shuffleOrder: [Int], shuffleCursor: Int,
                         repeatMode: RepeatMode,
                         isChecked: (Int) -> Bool = { _ in true }) -> NextStep {
        guard count > 0 else { return .stop }
        if isShuffled {
            // 随机序：游标往后找第一个勾着的。整份到头时照旧要么重洗、要么停。
            var next = shuffleCursor + 1
            while next < shuffleOrder.count {
                let index = shuffleOrder[next]
                if isChecked(index) { return .play(index: index, reshuffle: false) }
                next += 1
            }
            guard repeatMode == .all else { return .stop }
            // 整份都没勾就别重洗了：洗完照样一首都放不出来，洗一次落一次、
            // 落一次又重洗，就是死循环。这一问是 O(n)，只在随机序到头时走一次。
            guard shuffleOrder.contains(where: isChecked) else { return .stop }
            // 重洗之后是哪一首要洗完才知道，这里没法先替它挑一首勾着的；
            // 洗完由 `apply` 落位，真落到没勾的那一首上，下一跳再跳过去。
            return .play(index: -1, reshuffle: true)
        }
        guard let i = currentIndex else { return .stop }
        var index = i + 1
        while index < count {
            if isChecked(index) { return .play(index: index, reshuffle: false) }
            index += 1
        }
        guard repeatMode == .all else { return .stop }
        // 循环全部：从头再找，但**最多扫到当前这一首为止**——一圈下来一首都没勾着
        // 就停，不然会在队列里空转。
        index = 0
        while index <= i, index < count {
            if isChecked(index) { return .play(index: index, reshuffle: false) }
            index += 1
        }
        return .stop
    }

    /// 这一支该按多长算。三个候选：item 报的、曲目元数据里的、音轨 `timeRange` 的。
    ///
    /// 渐进式 MP3/OGG 的 `item.duration` 只是按码率估出来的，AVFoundation 边下边改
    /// （所以 `PlaybackDeck` 还 KVO 盯着它）。估短了 10 秒，过渡起点`duration − N`
    /// 就提前 10 秒——用户听到的正是「还剩十几秒，歌都没唱完就切了」。
    ///
    /// 所以几个候选相差超过 2 秒时取**最大**的那个：取短了会把歌切掉；取长了最坏
    /// 也只是「歌先播完、过渡没赶上」，那时走 end 通知的无缝接管，听感上没有损失。
    /// 差在 2 秒以内就用 item 报的（三个里它最准）。一个有限值都没有时返回 0
    /// （上层看见 0 就整套过渡都不做）。
    nonisolated static func workingDuration(item: TimeInterval?, meta: TimeInterval?,
                                            assetTrack: TimeInterval?) -> TimeInterval {
        let candidates = [item, meta, assetTrack].compactMap { $0 }.filter { $0.isFinite && $0 > 0 }
        guard let longest = candidates.max() else { return 0 }
        guard let item, item.isFinite, item > 0 else { return longest }
        return longest - item > 2 ? longest : item
    }

    private func workingDuration(for deck: PlaybackDeck) -> TimeInterval {
        Self.workingDuration(item: deck.itemSeconds, meta: deck.track?.duration,
                             assetTrack: deck.assetSeconds)
    }

    /// item 把时长改了（渐进式流的估值被精修）：重算工作时长，当前这一路还要跟着
    /// 把界面时长与过渡的边界点挪过去。
    private func handleDurationChanged(_ deck: PlaybackDeck) {
        guard deck.isReady else { return }
        let updated = workingDuration(for: deck)
        guard updated > 0, abs(updated - deck.duration) > 0.05 else { return }
        let before = deck.duration
        deck.setDuration(updated)
        guard deck === current else { return }
        duration = updated
        // 之前那次「离结尾太远」的判断是拿旧时长做的，重新给一次机会。
        overlapSkippedForCurrent = false
        if case .ready(let plan) = standbyPhase, case .crossfade(let n) = plan.mode {
            current.armBoundary(at: max(0, updated - n))
        }
        Self.handoffLog.debug("""
            时长被精修 \(before, privacy: .public) → \(updated, privacy: .public) \
            \(deck.track?.title ?? "-", privacy: .public)
            """)
    }

    /// `skippingUnchecked` 为真才过勾选列那道滤（自动连播与它的预取）；
    /// 用户主动按下一首时不过——Music 里手动切歌不认那个勾。
    func nextStep(skippingUnchecked: Bool = false) -> NextStep {
        Self.nextStep(count: queue.count, currentIndex: currentIndex, isShuffled: isShuffled,
                      shuffleOrder: shuffleOrder, shuffleCursor: shuffleCursor,
                      repeatMode: repeatMode,
                      isChecked: { [weak self] index in
                          guard skippingUnchecked, let self,
                                let check = self.isTrackChecked,
                                self.queue.indices.contains(index) else { return true }
                          return check(self.queue[index])
                      })
    }

    /// 只落 index / 游标，不起播。
    private func apply(_ step: NextStep) {
        switch step {
        case .stop:
            // 与老路一致：随机序到头时游标也照推过界，`previous()` 才回得到最后一首。
            if isShuffled { shuffleCursor += 1 }
        case .play(let index, let reshuffle):
            if isShuffled {
                if reshuffle {
                    buildShuffleOrder(startingAt: nil)
                    shuffleCursor = 0
                    currentIndex = shuffleOrder.first
                } else {
                    // 跳过了几首没勾的就得推几格：`+= 1` 只在「一格都没跳」时才对，
                    // 跳过之后游标会停在被跳过的那一首上，`previous()` 与下一次
                    // `nextStep()` 都会从错的位置起算。下标在随机序里唯一，找得回来。
                    shuffleCursor = shuffleOrder.firstIndex(of: index) ?? shuffleCursor + 1
                    currentIndex = index
                }
            } else {
                currentIndex = index
            }
        }
    }

    /// 两首之间怎么接。
    ///
    /// - 过渡关着 → `.none`：一切都走老路，与没有这套双路时逐字一致。
    /// - 单曲循环 → `.none`：同一支 item 自己绕，没有「下一首」可交叠。
    /// - 同专辑同音源 → `.gapless`：Music 的「同一张专辑内的歌曲之间不做过渡」。
    /// - 退场这一路没有 mix（沉浸声且 `attachMixToSpatialItems == false`，或者压根读不出音轨）
    ///   → `.gapless`：没有`AVMutableAudioMixInputParameters` 就装不了淡出斜坡，
    ///   硬做只会变成「新的淡入、旧的原音量顶到底」。
    /// - 其余 → `.crossfade(N)`，`N` 见`CrossfadeRamp.seconds(forDuration:)`。
    ///
    /// `crossfadeStyle` 的「智能过渡」与「自动过渡」在这里**同样处理**：
    /// 智能过渡要按调性/拍速挑接口，AVFoundation 与 MediaToolbox 都没有公开的
    /// 调性或拍速分析 API（`AVAudioUnit` 那套也只有节拍检测的第三方实现），
    /// 没有能力就不假装有，两档一律按自动来。
    nonisolated static func handoffMode(from: Track, to: Track, duration: TimeInterval,
                            repeatMode: RepeatMode, crossfadeEnabled: Bool,
                            outgoingHasMix: Bool = true) -> HandoffMode {
        guard crossfadeEnabled, repeatMode != .one else { return .none }
        if let a = from.albumId, let b = to.albumId, !a.isEmpty, a == b, from.kind == to.kind {
            return .gapless
        }
        guard let seconds = CrossfadeRamp.seconds(forDuration: duration) else { return .none }
        guard outgoingHasMix else { return .gapless }
        return .crossfade(seconds: seconds)
    }

    // MARK: - 交接状态机

    /// 当前这一首打算怎么交接。返回 nil 表示不预取。
    private func plannedHandoff() -> Prefetch? {
        guard let from = currentTrack, duration > 0 else { return nil }
        // 预取的是「自动播完之后会走到哪一首」，与 `next(userInitiated: false)` 同解，
        // 所以这里也要过勾选列那道滤，否则提前取回来的是一首会被跳过的歌。
        let step = nextStep(skippingUnchecked: true)
        guard case .play(let index, let reshuffle) = step, !reshuffle,
              queue.indices.contains(index) else { return nil }
        let to = queue[index]
        // 设了「停止时间」的这一首根本走不到过渡起点（停止时间在它之前），
        // 设了「开始时间 / 断点」的下一首又不能被提前 preroll 到 0 再淡入
        //（淡入斜坡是按绝对时间 0…N 写的，一 seek 就落到斜坡中段）。
        // 两种都退回普通换歌：冷起播一次，`handleCurrentStatus` 那条路会把起点挪准。
        guard stopTime(for: from, duration: duration) == nil,
              startOffset(for: to, duration: 0) == nil else { return nil }
        let mode = Self.handoffMode(from: from, to: to, duration: duration,
                                    repeatMode: repeatMode,
                                    crossfadeEnabled: crossfadeEnabled,
                                    outgoingHasMix: current.mix != nil)
        guard mode != .none else { return nil }
        return Prefetch(step: step, track: to, mode: mode, queueVersion: queueVersion)
    }

    /// 过渡起点：交叉淡入淡出提前 N 秒，无缝就是结尾。
    private func fadeStart(for mode: HandoffMode, duration: TimeInterval) -> TimeInterval {
        if case .crossfade(let n) = mode { return max(0, duration - n) }
        return duration
    }

    private func handleTick(_ deck: PlaybackDeck, _ seconds: TimeInterval) {
        // 另一路的 tick 直接丢：界面上的进度、播放态只跟着 current，
        // 而交叠期间的 current 仍然是用户正在听的那一首（退场那首）。
        guard deck === current else { return }
        // seek 还没落点：这一跳采的是 seek 之前的位置，认它就是用户看到的
        // 「先跳到目标点、往回闪一下、再跳回来」。
        let stale = deck.isSeekPending
        if !stale, seconds.isFinite { currentTime = seconds }
        let playing = deck.player.timeControlStatus == .playing
        let stateChanged = playing != isPlaying
        // 只在真的变了才写：@Published 不比较新旧值，每跳赋一次
        // 就等于每跳发一次 objectWillChange，整个界面跟着重画。
        if stateChanged { isPlaying = playing }
        // 系统「正在播放」面板不需要 10Hz，播放状态变了或隔了一秒才推一次。
        let now = Date.timeIntervalSinceReferenceDate
        if stateChanged || now - lastNowPlayingPush >= 1 {
            lastNowPlayingPush = now
            updateNowPlaying()
        }
        // 门控期间喂目标点而不是旧采样：`applyTickOverrides` 会写「记住播放位置」，
        // 喂旧值等于把断点记到 seek 之前那儿去。
        let t = stale ? currentTime : seconds
        applyTickOverrides(deck, t)
        updateHandoff(at: t)
    }

    private func updateHandoff(at t: TimeInterval) {
        guard t.isFinite, duration > 0, !fadeSuppressedForCurrent else { return }
        switch standbyPhase {
        case .idle:
            guard let plan = plannedHandoff() else { return }
            let start = fadeStart(for: plan.mode, duration: duration)
            guard t >= start - CrossfadeRamp.prefetchLead else { return }
            prefetchNext(plan)
        case .ready(let plan):
            // 边界观察器是主路；seek 跨过边界时它不保证触发，这里兜一次底。
            guard case .crossfade(let n) = plan.mode, !overlapSkippedForCurrent else { return }
            if t >= duration - n { beginOverlap() }
        case .prefetching, .overlapping:
            break
        }
    }

    private func prefetchNext(_ plan: Prefetch) {
        guard let resolver = providerResolver else { return }
        standbyPhase = .prefetching(plan)
        // 三个时长候选与最终的过渡起点都记一行：用户觉得「还剩十几秒就切了」时，
        // 从这一行就能看出是哪个候选把工作时长拉短了。
        Self.handoffLog.debug("""
            预取 \(plan.track.title, privacy: .public) 接法=\(String(describing: plan.mode), privacy: .public) \
            item=\(self.current.itemSeconds ?? -1, privacy: .public) \
            meta=\(self.currentTrack?.duration ?? -1, privacy: .public) \
            asset=\(self.current.assetSeconds ?? -1, privacy: .public) \
            工作时长=\(self.duration, privacy: .public) \
            过渡起点=\(self.fadeStart(for: plan.mode, duration: self.duration), privacy: .public)
            """)
        let fadeIn: TimeInterval? = {
            if case .crossfade(let n) = plan.mode { return n }
            return nil
        }()
        Task { [weak self] in
            do {
                let url = try await resolver(plan.track)
                guard let self, self.stillPrefetching(plan) else { return }
                let loaded = await self.makeItem(url: url, track: plan.track, fadeIn: fadeIn)
                let (item, mix) = (loaded.item, loaded.mix)
                guard self.stillPrefetching(plan) else { return }
                // 进场这一支没有 mix（沉浸声关掉了挂载、或者读不出音轨）就淡入不了，
                // 整次交接降级成无缝：不装边界、不做斜坡，等 end 通知到了直接接上。
                var plan = plan
                if mix == nil, case .crossfade = plan.mode {
                    plan = Prefetch(step: plan.step, track: plan.track,
                                    mode: .gapless, queueVersion: plan.queueVersion)
                    self.standbyPhase = .prefetching(plan)
                }
                self.other.load(item: item, track: plan.track, mix: mix,
                                assetSeconds: loaded.assetSeconds)
                self.other.player.volume = Float(self.volume)
                self.other.player.pause()
                // 预取那一路只要 30 秒缓冲：够撑过交接，又不去抢当前这一路的带宽。
                item.preferredForwardBufferDuration = 30
            } catch {
                // 预取失败静默降级：不计 failureStreak、不弹 toast，
                // 到点照老路走（那时会重新解析一次流，真不行才报错）。
                guard let self, self.stillPrefetching(plan) else { return }
                self.standbyPhase = .idle
            }
        }
    }

    private func stillPrefetching(_ plan: Prefetch) -> Bool {
        guard case .prefetching(let cur) = standbyPhase else { return false }
        return cur.track.id == plan.track.id && cur.queueVersion == queueVersion
    }

    /// `.ready` / `.overlapping` 两个阶段各自带着的那一份预取计划。
    private var standbyPlan: Prefetch? {
        switch standbyPhase {
        case .ready(let plan), .overlapping(let plan): return plan
        case .idle, .prefetching: return nil
        }
    }

    /// 预取好的那一首正好就是现在要播的这一首 → 直接接管，不再取一次流。
    ///
    /// 三种情况都走这里：无缝交接；过渡点到了但还没 ready、放到底才轮到它；
    /// 以及**交叠**——那一路已经出了 N 秒声，接管时绝不能 pause / 重播 / seek，
    /// 只是把「正在播放」的身份挪过去，位置照它自己的走。
    private func adoptStandbyIfMatches(_ track: Track) -> Bool {
        guard let plan = standbyPlan, plan.track.id == track.id,
              plan.queueVersion == queueVersion, other.isReady else { return false }
        // 退场那一首的响度到这一刻才结算：它已经整整播完了。
        finishMeasurement(current)
        let outgoing = current
        current = other
        standbyPhase = .idle
        outgoing.unload()
        startFromStandby()
        Self.handoffLog.debug("""
            接管 \(track.title, privacy: .public) 位置=\(self.currentTime, privacy: .public) \
            时长=\(self.duration, privacy: .public)
            """)
        return true
    }

    private func handleBoundary(_ deck: PlaybackDeck) {
        guard deck === current else { return }
        beginOverlap()
    }

    /// 交叠开不开得起来：位置得离工作时长不足 `fade + 2` 秒，才算真的到尾了。
    ///
    /// 边界观察点是按「装的时候的时长」放的，而渐进式流的时长是估的、之后还会被精修。
    /// 估短了 10 秒，边界就落在真正结尾前 16 秒——用户听到的就是「还剩十几秒，
    /// 歌都没唱完就切了」。这道闸把那种情况拦下来，等 end 通知到了走无缝接管。
    nonisolated static func shouldBeginOverlap(position: TimeInterval,
                                              workingDuration: TimeInterval,
                                              fade: TimeInterval) -> Bool {
        guard position.isFinite, workingDuration.isFinite, workingDuration > 0 else { return false }
        return position >= workingDuration - (fade + 2)
    }

    /// 交叠开始：给退场那一路装淡出斜坡，另一路直接开声。
    ///
    /// **不换 `current`、不`apply(step)`**——「正在播放」还是退场那一首，
    /// 标题、封面、进度、歌词、系统面板全都不动，直到它自己播完。
    private func beginOverlap() {
        guard case .ready(let plan) = standbyPhase,
              case .crossfade(let n) = plan.mode,
              plan.queueVersion == queueVersion,
              other.isReady, !overlapSkippedForCurrent,
              // 暂停中到了过渡点（比如暂停后被拖到尾段）：不叠。恢复播放后
              // tick 兜底会再判一次，那时再叠。
              wantsPlayback, current.player.rate > 0 else { return }
        let outgoingDeck = current
        let position = outgoingDeck.elapsed
        let working = outgoingDeck.duration
        guard Self.shouldBeginOverlap(position: position, workingDuration: working, fade: n) else {
            // 时长明显被低估了。这一首本轮不再交叠（等时长精修回来会重新给一次机会），
            // 到结尾走 end 通知 → `adoptStandbyIfMatches`，接得上、也不会切早。
            overlapSkippedForCurrent = true
            outgoingDeck.disarmBoundary()
            Self.handoffLog.debug("""
                交叠跳过（离结尾太远）位置=\(position, privacy: .public) \
                工作时长=\(working, privacy: .public) N=\(n, privacy: .public)
                """)
            return
        }
        outgoingDeck.disarmBoundary()
        if Self.fadeOutViaTap {
            outgoingDeck.mix?.tap?.setFadeOut(start: max(0, working - n), seconds: n)
        } else if let mix = outgoingDeck.mix {
            mix.applyFadeOut(start: max(0, working - n), seconds: n)
            outgoingDeck.refreshMix()
        }
        // 退场那一路的测量**不在这里结算**：它还要继续播到自己的结尾，
        // tap 建在 PreEffects 上，淡出斜坡进不了测量，整首照样量得全。
        other.player.play()
        standbyPhase = .overlapping(plan)
        Self.handoffLog.debug("""
            交叠开始 退场=\(outgoingDeck.track?.title ?? "-", privacy: .public) \
            位置=\(position, privacy: .public) 工作时长=\(working, privacy: .public) \
            进场=\(plan.track.title, privacy: .public) N=\(n, privacy: .public)
            """)
    }

    /// 把「正在播放」的身份交给 `current` 这一路（刚接管过来的那一路）。
    private func startFromStandby() {
        fadeSuppressedForCurrent = false
        overlapSkippedForCurrent = false
        isLoading = false
        lastError = nil
        // 交叠期间它已经出了 N 秒声，位置照它自己的读；`.ready` 那一路没播过，读回来就是 0。
        currentTime = current.elapsed
        duration = current.duration
        streamFormat = current.streamFormat
        failureStreak = 0
        if let track = current.track {
            onTrackStarted?(track)
            fetchArtwork(track)
            if current.streamFormat == nil { readStreamFormat(for: current) }
        }
        // 已经在响的那一路上，`play()` 是空操作：不重头、不 seek。
        // 用户暂停着（交叠里按了暂停、退场那一首恰好走到头）就接管过来但不出声。
        if wantsPlayback { current.player.play() } else { current.player.pause() }
        updateNowPlaying()
    }

    /// 交叠期间用户切歌：退场那一首（也就是 `current`）现在就掐掉，播放次数照记。
    ///
    /// 进场那一路**不动**——接下来的 `startCurrent` 会用`adoptStandbyIfMatches`
    /// 判断目标是不是它：是就原地接管（不重播），不是才由 `invalidateStandby` 一并卸掉。
    /// 掐完把阶段降回 `.ready`，所以重复调是安全的（不会记第二次账）。
    private func cutOverlapOutgoing() {
        guard case .overlapping(let plan) = standbyPhase else { return }
        if let track = current.track { onTrackPlayed?(track) }
        finishMeasurement(current)
        current.unload()
        standbyPhase = .ready(plan)
        Self.handoffLog.debug("交叠被切歌打断 进场=\(plan.track.title, privacy: .public)")
    }

    /// 交叠期间往回 seek 到尾段之前：新歌撤回，退场这一首把淡出斜坡收掉接着正常播。
    /// **不设 `fadeSuppressedForCurrent`**——再放进窗口时还要重新预取一次。
    private func cancelOverlap() {
        guard case .overlapping = standbyPhase else { return }
        other.unload()
        standbyPhase = .idle
        if Self.fadeOutViaTap {
            current.mix?.tap?.clearFadeOut()
        } else if let flat = current.mix?.flatCopy() {
            // 斜坡只能加不能删，只好整份 mix 重建；tap 还是原来那个（响度接着量）。
            current.adoptMix(flat)
        }
        Self.handoffLog.debug("交叠撤销（往回 seek）位置=\(self.currentTime, privacy: .public)")
    }

    /// 所有会改队列的入口都调它：在飞的预取作废、备用那一路卸掉。
    /// **不设抑制**——下一跳 tick 会按新的 `nextStep()` 重新预取。
    ///
    /// 交叠期间走的是「撤销」而不是「掐掉」：`current` 是用户正在听的那一首，
    /// 按一下随机 / 循环按钮不该把它的声音掐了。真要换掉它的那几个入口
    /// （play / next / previous / 双击别的行 / stop）自己在前面调 `cutOverlapOutgoing`。
    private func invalidateStandby() {
        cancelOverlap()
        queueVersion &+= 1
        if case .idle = standbyPhase {} else { standbyPhase = .idle }
        if other.item != nil { other.unload() }
    }

    /// seek 进尾段（过渡起点前 1 秒之内）：斜坡是按绝对时间装的，落到斜坡中段
    /// 会以半音量起手，所以本首直接放弃过渡走老路。
    ///
    /// 交叠已经开起来了则是另一回事：往回 seek 到尾段之前，说明用户还要接着听这一首，
    /// 把新歌撤回、淡出斜坡收掉（`cancelOverlap`）；还在尾段里就两路都不动。
    private func suppressFadeIfSeekedIntoTail(_ target: TimeInterval) {
        guard duration > 0 else { return }
        if case .overlapping(let plan) = standbyPhase {
            let start = fadeStart(for: plan.mode, duration: duration)
            if target < start - 1 { cancelOverlap() }
            return
        }
        guard let plan = plannedHandoff() else { return }
        let start = fadeStart(for: plan.mode, duration: duration)
        guard target >= start - 1 else { return }
        fadeSuppressedForCurrent = true
        invalidateStandby()
    }

    // MARK: - 「显示简介」的逐曲覆盖

    /// 这一首起播该从哪儿起。断点（「记住播放位置」）优先于「开始时间」——
    /// 断点是「上次听到这儿」，开始时间是「这首的前奏不要」，两个都设时按断点续
    /// 才是用户当下想要的；断点被清掉之后自然落回开始时间。[推]
    ///
    /// 返回 nil ＝ 从头播，与没有这个功能时逐字一致。
    private func startOffset(for track: Track, duration: TimeInterval) -> TimeInterval? {
        guard let overrides = playbackOverridesProvider?(track.id) else { return nil }
        var offset: TimeInterval?
        if overrides.rememberPlaybackPosition,
           let saved = resumePositionProvider?(track.id), saved > 0 {
            offset = saved
        } else if let start = overrides.startTime, start > 0 {
            offset = start
        }
        guard let offset, offset.isFinite, offset > 0 else { return nil }
        // 时长还没解出来（duration == 0）就只按有限值判一次；解出来了就别让起点
        // 落到结尾附近——那等于一起播就跳歌。**用的是 `deck.duration`（`workingDuration`
        // 三选一的结果）而不是 `item.duration`**：渐进式流的 item 时长是估的。
        guard duration <= 0 || offset < duration - 1 else { return nil }
        return offset
    }

    /// 这一首的「停止时间」。没设、或者设得比工作时长还长（改过音源、换过文件）就是 nil。
    private func stopTime(for track: Track, duration: TimeInterval) -> TimeInterval? {
        guard let stop = playbackOverridesProvider?(track.id)?.stopTime,
              stop.isFinite, stop > 0 else { return nil }
        guard duration <= 0 || stop < duration - 0.25 else { return nil }
        return stop
    }

    /// 每一跳都要判的两件事：到「停止时间」了没有、要不要记断点。
    /// 没有任何 override 的曲目在这里只多走一次字典查询就出去了。
    private func applyTickOverrides(_ deck: PlaybackDeck, _ seconds: TimeInterval) {
        guard let track = deck.track, seconds.isFinite,
              let overrides = playbackOverridesProvider?(track.id) else { return }

        if overrides.rememberPlaybackPosition, seconds > 0 {
            onResumePosition?(track.id, seconds)
        }

        // 停止时间：走正常的「这首放完了」那条路（记一次播放次数、按重复模式往下走），
        // 不是硬停。**已知取舍**：过渡（交叉淡入淡出）不会对着停止时间对齐——
        // 过渡的预取与边界点都是按工作时长装的，停止时间在那之前就到了，
        // 于是设了停止时间的那一首是「戛然而止 + 下一首冷起播」。要让它也过渡，
        // 得把停止时间灌进 `duration` 那一套里去，动的是过渡主路径，不值当。
        if let stop = stopTime(for: track, duration: deck.duration), seconds >= stop,
           stopTimeFiredForTrackID != track.id {
            stopTimeFiredForTrackID = track.id
            handleTrackEnded()
        }
    }

    // MARK: - 内部

    /// 一首放到结尾。记账点就在这里——**切歌之前**，因为 `next()` 一走`currentTrack` 就变了。
    /// 单曲循环每绕一遍都算一次播放（Music 也是这样：单曲循环放十遍，播放次数加十）。
    ///
    /// `internal` 是为了让测试不用真起播就能验证回调（见 PlayerAccountingTests）。
    func handleTrackEnded() {
        if let track = currentTrack {
            onTrackPlayed?(track)
            // 整首放完了，断点就该清掉——下次再点它是从头播，不是「从结尾续」。
            onResumePosition?(track.id, nil)
        }
        switch repeatMode {
        case .one:
            seek(to: 0)
            if wantsPlayback { current.player.play() }
        case .off, .all:
            next(userInitiated: false)
        }
    }

    /// 重新指路成功之后接着把这一首播起来（`MissingFileLocator` 唯一的调用点）。
    ///
    /// 认 id：用户在选取面板里挑文件那会儿可能已经切歌了，那就什么都别做。
    func retryCurrent(id: String) {
        guard currentTrack?.id == id else { return }
        startCurrent()
    }

    private func playIndex(_ index: Int) {
        wantsPlayback = true
        // 这条路只有用户点得出来（队列面板双击、`playTrack(at:)`、上一首/下一首之外的跳转）。
        currentStartIsUserInitiated = true
        currentIndex = index
        currentTime = 0
        duration = 0
        startCurrent()
    }

    private func startCurrent() {
        guard let track = currentTrack else { return }
        // 换歌就是重新判一次「队尾够不够长」的时刻。放在最前面，交接（`adoptStandbyIfMatches`）
        // 那条早退路径也得走到——正是因为过渡已经预取好了下一首，队尾才更需要提前续上。
        refillAutoplayIfNeeded()
        // 提前取好的正是这一首（无缝交接、或者过渡没赶上但流已经就绪）→ 直接接管。
        if adoptStandbyIfMatches(track) { return }
        finishMeasurement(current)
        invalidateStandby()
        fadeSuppressedForCurrent = false
        overlapSkippedForCurrent = false
        stopTimeFiredForTrackID = nil
        isLoading = true
        lastError = nil
        streamFormat = nil
        fetchArtwork(track)
        let trackID = track.id
        let resolver = providerResolver
        Task { [weak self] in
            do {
                guard let self, let resolver else { throw ProviderError.api("播放器未初始化") }
                let url = try await resolver(track)
                guard self.currentTrack?.id == trackID else { return } // 期间已切歌
                let loaded = await self.makeItem(url: url, track: track, fadeIn: nil)
                guard self.currentTrack?.id == trackID else { return }
                self.current.load(item: loaded.item, track: track, mix: loaded.mix,
                                  assetSeconds: loaded.assetSeconds)
                self.current.player.volume = Float(self.volume)
            } catch {
                guard let self, self.currentTrack?.id == trackID else { return }
                self.isLoading = false
                // 本地文件找不着了（spec §10.1）：这一首不报 toast、也不静默跳过，
                // 交给界面层弹「你想要查找它吗？」，队列停在这一首等用户回答——
                // 他点「查找」指完路，`retryCurrent(id:)` 会接着把它播起来。
                //
                // 只有用户主动点播的那一首走这条：自动往下走撞上的照旧往后走
                //（感叹号在取流那一步已经打上了，不需要再拦一次）。这条分档是 `[推]`，
                // 旁证是 Music 那边起播方法的 `allowUserInteraction:` 形参（§10.1.2）——
                // 「许不许打断用户」在它那儿也是起播路径上的一个开关。
                if case .localFileMissing = error as? ProviderError,
                   self.currentStartIsUserInitiated, self.onLocalFileMissing != nil {
                    self.onLocalFileMissing?(track)
                    return
                }
                self.lastError = (error as? ProviderError)?.errorDescription ?? "网络错误"
                self.advanceOnFailure()
            }
        }
    }

    /// 造一支 item。每一支从出生就带 tap（增强器、响度测量都在里面），
    /// 带不带淡入斜坡看它是不是过渡进来的那一支。
    ///
    /// 音轨要先加载出来才能建 `AVMutableAudioMixInputParameters`（它是按音轨挂的），
    /// 所以这里比从前的 `AVPlayerItem(url:)` 多一次 asset 解析；解析不出音轨就
    /// 整支不挂 mix，照老路播——过渡与增强器对它失效，但绝不能因此播不出来。
    private func makeItem(url: URL, track: Track, fadeIn: TimeInterval?) async -> LoadedItem {
        // 网络上的纯音频（尤其 FLAC）默认只按字节估算时间轴：seek 落到估出来的位置，
        // 再把那里标成目标时间——声音与时间轴（进度条、歌词）从此对不上，
        // 实测点一句歌词声音偏 1.4 秒。打开精确时序让它按真实包表定位（实测偏差 ≤ 0.06 秒）。
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        let item = AVPlayerItem(asset: asset)
        item.allowedAudioSpatializationFormats = spatializationFormats()
        guard let audioTrack = audioTrack ?? nil else {
            return LoadedItem(item: item, mix: nil, assetSeconds: nil)
        }
        // 顺手把音轨自己报的时长取出来：`item.duration` 对渐进式流只是估值，
        // 这一条是第三个候选，见 `workingDuration`。
        var assetSeconds: TimeInterval?
        if let range = try? await audioTrack.load(.timeRange) {
            let seconds = range.duration.seconds
            if seconds.isFinite, seconds > 0 { assetSeconds = seconds }
        }
        // 沉浸声要不要挂 mix 见 `attachMixToSpatialItems`。判据与`StreamFormat.isSpatial`
        // 是同一条（AC-3 / E-AC-3），只是这里必须在建 mix **之前**就知道，
        // 所以直接读音轨的格式描述，不等 `StreamFormat.read` 那条异步路。
        if !Self.attachMixToSpatialItems, await Self.isSpatialTrack(audioTrack) {
            return LoadedItem(item: item, mix: nil, assetSeconds: assetSeconds)
        }
        guard let mix = DeckAudioMix(track: audioTrack, tap: AudioTap()) else {
            return LoadedItem(item: item, mix: nil, assetSeconds: assetSeconds)
        }
        if let fadeIn { mix.applyFadeIn(start: 0, seconds: fadeIn) } else { mix.applyFlat() }
        item.audioMix = mix.audioMix
        mix.tap?.apply(audioPrefs)
        configureLoudness(mix.tap, for: track)
        return LoadedItem(item: item, mix: mix, assetSeconds: assetSeconds)
    }

    /// 这条音轨是不是杜比（AC-3 / E-AC-3 JOC）。与 `StreamFormat.isSpatial` 同一条判据，
    /// 只是取的是音轨自己的格式描述——建 `DeckAudioMix` 之前就要有答案。
    nonisolated static func isSpatialTrack(_ track: AVAssetTrack) async -> Bool {
        guard let descriptions = try? await track.load(.formatDescriptions) else { return false }
        return descriptions.contains { description in
            guard let asbd = description.audioStreamBasicDescription else { return false }
            return asbd.mFormatID == kAudioFormatAC3 || asbd.mFormatID == kAudioFormatEnhancedAC3
        }
    }

    /// 音量平衡：量过的按缓存对齐目标响度，**没量过的这一遍不调**——
    /// 只用开头一段去估整首会把安静的前奏误判成「整首都轻」，
    /// Music 遇到没有响度标签的曲目也是原样放（见 memory `am-no-per-song-tuning`）。
    private func configureLoudness(_ tap: AudioTap?, for track: Track) {
        guard let tap else { return }
        let enabled = audioPrefs.soundCheck
        // 「显示简介 › 选项 › 音量调整」：−255…255 折成 dB，**叠在音量平衡的增益上**。
        // 走 tap 而不是 `DeckAudioMix`：`AVMutableAudioMixInputParameters` 上的斜坡是
        // 按绝对时间写的（交叉淡入淡出），再往里乘一个固定增益就得把两条曲线揉在一起，
        // 而且斜坡加上去就删不掉（见 `DeckAudioMix.flatCopy` 的注释）。tap 这边
        // `setGain(dB:)` 本来就是一个数 + 一条 50 ms 平滑斜坡，叠加是纯加法。
        //
        // 没设过的曲目 `adjustment == 0`，下面两条分支与从前逐字相同。
        let adjustment = playbackOverridesProvider?(track.id)?.gainDB ?? 0
        if enabled, let entry = loudnessProvider?(track) {
            tap.setGain(dB: entry.gainDB + adjustment)
            tap.setMeasuring(false)
        } else {
            tap.setGain(dB: adjustment)
            // 边播边量的是**源**信号：`tapMeasure` 在`tapGain` 之前跑，
            // 逐曲增益不会把量出来的响度带偏。
            tap.setMeasuring(enabled)
        }
    }

    /// 一首离开（换歌 / 停止 / 过渡退场）时把测量结果结算掉。
    /// 整首没量全（中途切走、被 seek 过）就丢弃，不写回一个偏低的值。
    private func finishMeasurement(_ deck: PlaybackDeck) {
        guard let tap = deck.mix?.tap, let track = deck.track else { return }
        let shared = tap.shared
        guard shared.measure.load(ordering: .relaxed) else { return }
        shared.measure.store(false, ordering: .relaxed)
        guard !shared.seeked.load(ordering: .relaxed) else { return }
        let blocks = shared.snapshotBlocks()
        let measuredSeconds = Double(blocks.count) * LoudnessMeter.subBlockSeconds
        guard deck.duration > 0, measuredSeconds >= deck.duration * 0.98 else { return }
        guard let lufs = LoudnessMeter.integrated(subBlockEnergies: blocks) else { return }
        let peak = Double(shared.peak)
        let peakDB = peak > 0 ? min(20 * log10(peak), 0) : -120
        onLoudnessMeasured?(track, LoudnessEntry(lufs: lufs, peakDB: peakDB, measuredAt: Date()))
    }

    /// 允许哪些空间化格式。没有注入判定器时按设置里的模式直接折算：
    /// 「关闭」不做空间化、「自动」只对多声道内容开、「始终打开」连双声道也上混。
    private func spatializationFormats() -> AVAudioSpatializationFormats {
        if let spatializationProvider { return spatializationProvider() }
        switch AppSettings.shared.values.dolbyAtmos {
        case .off: return []
        case .automatic: return .multichannel
        case .alwaysOn: return .monoStereoAndMultichannel
        }
    }

    private func handleStatus(_ deck: PlaybackDeck, _ status: AVPlayerItem.Status) {
        if deck === current {
            handleCurrentStatus(deck, status)
        } else {
            handleStandbyStatus(deck, status)
        }
    }

    private func handleCurrentStatus(_ deck: PlaybackDeck, _ status: AVPlayerItem.Status) {
        guard let track = deck.track, currentTrack?.id == track.id else { return }
        switch status {
        case .readyToPlay:
            // KVO 可能不止回报一次（重装 audioMix 之类都可能再来一遍）；
            // 就绪只处理第一次，否则暂停中的那一路会被这里悄悄 `play()` 回去。
            guard !deck.isReady else { return }
            failureStreak = 0
            // 「最近播放」在这一刻置顶：取流成功、马上要出声了才算听过这首。
            onTrackStarted?(track)
            deck.markReady(duration: workingDuration(for: deck))
            duration = deck.duration
            isLoading = false
            // 「开始时间」/「记住播放位置」：**出声之前**先挪到位，起播才不会先漏出
            // 一声 0:00 的原声。所以 `play()` 挪进 seek 的完成回调里——
            // 没有 override 的那条分支一行没动。
            if let offset = startOffset(for: track, duration: deck.duration) {
                currentTime = offset
                deck.seek(to: CMTime(seconds: offset, preferredTimescale: 600),
                          tolerance: .zero) { [weak self] in
                    // 被后来的 seek 打断时也照放，否则用户一拖进度条这一首就永远
                    // 起不来了。认的是「这一路还是当前这一路」。
                    guard let self, self.wantsPlayback, self.current === deck else { return }
                    deck.player.play()
                }
            } else if wantsPlayback {
                deck.player.play()
            }
            updateNowPlaying()
            readStreamFormat(for: deck)
        case .failed:
            isLoading = false
            lastError = "无法播放：\(track.title)"
            advanceOnFailure()
        default:
            break
        }
    }

    private func handleStandbyStatus(_ deck: PlaybackDeck, _ status: AVPlayerItem.Status) {
        switch standbyPhase {
        case .prefetching(let plan):
            guard deck.track?.id == plan.track.id, plan.queueVersion == queueVersion else { return }
            switch status {
            case .readyToPlay:
                deck.markReady(duration: workingDuration(for: deck))
                deck.player.preroll(atRate: 1) { _ in }
                standbyPhase = .ready(plan)
                if case .crossfade(let n) = plan.mode, duration > 0 {
                    current.armBoundary(at: max(0, duration - n))
                }
            case .failed:
                standbyPhase = .idle
                deck.unload()
            default:
                break
            }
        case .ready(let plan):
            // 待命期间才挂的（缓冲断了）：撤回，到点走老路重新取一次流。
            guard deck.track?.id == plan.track.id, status == .failed else { return }
            standbyPhase = .idle
            deck.unload()
        case .overlapping(let plan):
            // 已经在响的那一路挂了：整次交叠撤销，退场这一首把淡出收掉正常播完。
            guard deck.track?.id == plan.track.id, status == .failed else { return }
            cancelOverlap()
        case .idle:
            break
        }
    }

    private func readStreamFormat(for deck: PlaybackDeck) {
        guard let item = deck.item else { return }
        let gen = deck.generation
        Task { [weak self] in
            let format = await StreamFormat.read(from: item)
            guard let self, deck.generation == gen else { return }
            deck.setStreamFormat(format)
            if deck === self.current { self.streamFormat = format }
        }
    }

    /// 取流失败（VIP/网络）时自动跳到下一首。这不是用户主动切歌，不记跳过。
    /// 整个队列都取不到流（比如一队全是 VIP 曲目）时停下来，别把队列空跳一遍——
    /// 单曲队列更是会直接停在「有封面有歌词、播放器里却没有 item」的死状态。
    private func advanceOnFailure() {
        failureStreak += 1
        guard failureStreak < max(queue.count, 1) else {
            haltPlayback()
            return
        }
        next(userInitiated: false)
    }

    /// 收掉播放器（两路 deck 卸干净、播放键回到「可重试」而不是没反应），**队列本身不动**。
    /// 两个调用点：一队全取不到流（`advanceOnFailure`），以及队列面板把当前曲连同
    /// 它后面的项一起删掉（`removeFromQueue`）。
    private func haltPlayback() {
        invalidateStandby()
        deckA.unload()
        deckB.unload()
        current = deckA
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        streamFormat = nil
        updateNowPlaying()
    }

    /// 洗一份随机序。
    ///
    /// 「随机播放时跳过」的曲目**在组队列这一步就剔掉**，不是播到了再跳——
    /// 后者会先出一声再切走。剔完一首不剩时整份退回不剔的那一版：
    /// 用户按下随机播放总得有歌放，一首都放不出来看着就像播放器坏了。[推]
    ///
    /// 只管洗牌这一处：往队列里插歌（`insert`）时新下标是直接补进随机序的，
    /// 那条路上的「跳过」要等下一次重洗才生效。
    private func buildShuffleOrder(startingAt: Int?) {
        var indices = Array(0..<queue.count)
        if playbackOverridesProvider != nil {
            let kept = indices.filter { index in
                playbackOverridesProvider?(queue[index].id)?.skipWhenShuffling != true
            }
            // 起播那一首是用户点的，照 Music 的「手动点播不认自动跳过」留着。
            if !kept.isEmpty {
                indices = kept
                if let startingAt, !indices.contains(startingAt) { indices.append(startingAt) }
            }
        }
        var order = indices.shuffled()
        if let startingAt {
            if let idx = order.firstIndex(of: startingAt) {
                order.remove(at: idx)
                order.insert(startingAt, at: 0)
            }
        }
        shuffleOrder = order
    }

    private func fetchArtwork(_ track: Track) {
        guard let urlString = track.artworkURL else { return }
        Task { @MainActor [weak self] in
            let image = await ImageCache.shared.image(for: urlString)
            guard self?.currentTrack?.id == track.id else { return }
            self?.updateNowPlaying(artwork: image)
        }
    }

    private func updateNowPlaying(artwork: NSImage? = nil) {
        NowPlayingCenter.shared.update(
            track: currentTrack,
            artwork: artwork,
            position: currentTime,
            duration: duration,
            rate: Double(current.player.rate))
    }
}

/// 歌词面板要的时间源。三条判据的防抖在 `TimingProviderGate` 里，
/// 这里只负责回答「现在放到哪儿」和「停没停」。
extension PlayerController: SyncedLyricsTimingProvider {
    var isPaused: Bool { current.player.timeControlStatus != .playing }
}
