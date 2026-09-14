import AVFoundation
import Foundation

/// 一路播放通道：一个 `AVPlayer`，加上它当前这一支 item 的全部随身状态
/// （曲目、时长、真实规格、audioMix、时间观察器、status KVO、边界观察器）。
///
/// `PlayerController` 持两路（A/B 交替）：出声的那一路是 `current`，另一路 `other`
/// 用来提前把下一首取好、解好、preroll 好。过渡时两路同时出声，交换之后角色对调。
/// 把「一路的东西」收进这里，是因为从前那些观察器全挂在控制器上，一变两路就会互相踩。
@MainActor
final class PlaybackDeck {

    let player = AVPlayer()

    private(set) var item: AVPlayerItem?
    private(set) var track: Track?
    /// 每次 `load` / `unload` 自增。异步回调（取流、status、`StreamFormat` 读取）拿着
    /// 装载时的号回来，号对不上就说明这一路已经换过 item，结果直接丢掉。
    private(set) var generation = 0
    /// 这一路在用的「工作时长」，由 `PlayerController.workingDuration` 在几个候选里选出来。
    private(set) var duration: TimeInterval = 0
    /// 音轨自己报的时长（`AVAssetTrack.timeRange.duration`，装载时解出来）。
    /// 渐进式流的 `item.duration` 是按码率估的，这一条是第三个候选，见 `workingDuration`。
    private(set) var assetSeconds: TimeInterval?
    private(set) var streamFormat: StreamFormat?
    private(set) var mix: DeckAudioMix?
    /// item 报过 `.readyToPlay` 没有。预取那一路靠它判断「能不能直接接上」。
    private(set) var isReady = false

    /// 10 Hz 的进度回调。退场那一路也会照报，接的人自己按 `deck === current` 过滤。
    var onTick: ((PlaybackDeck, TimeInterval) -> Void)?
    var onStatus: ((PlaybackDeck, Int, AVPlayerItem.Status) -> Void)?
    var onBoundary: ((PlaybackDeck, Int) -> Void)?
    /// item 把时长改了（渐进式流的估值被 AVFoundation 精修）。控制器据此重算工作时长、
    /// 重新装过渡的边界点——不然「估短了 10 秒」就等于「提前 10 秒切歌」。
    var onDurationChanged: ((PlaybackDeck, Int) -> Void)?

    private var timeObserver: Any?
    private var boundaryObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?

    /// 播放进度的采样间隔。0.1s 而不是 0.5s：逐字歌词的高亮和「一句唱完就翻页」
    /// 都吃这个精度，半秒一跳肉眼就是一顿一顿的。
    static let tickInterval: TimeInterval = 0.1

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: Self.tickInterval, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onTick?(self, seconds)
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
    }

    /// 每帧要用的播放位置（问播放器，不是 10 Hz 采样的那个）。
    var elapsed: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var isPlayingNow: Bool { player.timeControlStatus == .playing }

    /// item 自己报的时长。非有限（还没解出来、直播流）时是 nil。
    var itemSeconds: TimeInterval? {
        guard let seconds = item?.duration.seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    // MARK: - 装载

    /// 装一支 item 进这一路。返回这次装载的代号，异步回调回来时用它对号。
    @discardableResult
    func load(item: AVPlayerItem, track: Track, mix: DeckAudioMix? = nil,
              assetSeconds: TimeInterval? = nil) -> Int {
        disarmBoundary()
        statusObservation = nil
        durationObservation = nil
        self.mix?.invalidate()

        generation &+= 1
        let gen = generation
        self.item = item
        self.track = track
        self.mix = mix
        duration = 0
        self.assetSeconds = assetSeconds
        streamFormat = nil
        isReady = false
        if let mix { item.audioMix = mix.audioMix }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.onStatus?(self, gen, status)
            }
        }
        // 渐进式 MP3/OGG 的时长一开始是估的，AVFoundation 边下边改。只观察不猜：
        // 一变就报给控制器，由它重算工作时长。
        durationObservation = item.observe(\.duration, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.onDurationChanged?(self, gen)
            }
        }
        player.replaceCurrentItem(with: item)
        return gen
    }

    func markReady(duration: TimeInterval) {
        isReady = true
        self.duration = duration
    }

    /// 只改时长（item 把估值精修了），不动就绪标记。
    func setDuration(_ seconds: TimeInterval) {
        duration = seconds
    }

    func setStreamFormat(_ format: StreamFormat?) {
        streamFormat = format
    }

    /// 换一套 audioMix（过渡开始时给退场那一路装淡出斜坡）。
    /// 见 `PlayerController` 里对「播放中重装 audioMix 会不会有咔哒」的备选方案说明。
    func replaceMix(_ mix: DeckAudioMix?) {
        guard let item else { return }
        self.mix?.invalidate()
        self.mix = mix
        item.audioMix = mix?.audioMix
    }

    /// 把（刚被改过斜坡的）同一套 mix 重新赋回 item，让 AVFoundation 重新读一遍参数。
    /// 代价是 tap 会经历一次 unprepare→prepare，见 `PlayerController.fadeOutViaTap`。
    func refreshMix() {
        guard let item, let mix else { return }
        item.audioMix = mix.audioMix
    }

    /// 换一套 mix，但**不放掉旧那份的 tap**——新旧共用同一个 tap 时（撤销淡出斜坡，
    /// 见 `DeckAudioMix.flatCopy`）走这条，走 `replaceMix` 会把还在量的 tap 作废。
    func adoptMix(_ mix: DeckAudioMix) {
        guard let item else { return }
        self.mix = mix
        item.audioMix = mix.audioMix
    }

    func unload() {
        disarmBoundary()
        statusObservation = nil
        durationObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        mix?.invalidate()
        mix = nil
        item = nil
        track = nil
        duration = 0
        assetSeconds = nil
        streamFormat = nil
        isReady = false
        generation &+= 1
    }

    // MARK: - 边界观察

    /// 在 `seconds` 处放一个边界观察点（过渡的起点）。同一路只留一个。
    func armBoundary(at seconds: TimeInterval) {
        disarmBoundary()
        guard seconds.isFinite, seconds > 0 else { return }
        let gen = generation
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: time)], queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.onBoundary?(self, gen)
            }
        }
    }

    func disarmBoundary() {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
    }
}
