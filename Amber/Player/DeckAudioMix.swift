import AVFoundation
import Foundation

/// 一支 item 的音频加工：音量斜坡（交叉淡入淡出）+ 处理 tap（增强器 / 响度测量）。
///
/// `AVMutableAudioMixInputParameters` 是**按音轨**挂的，所以建它必须先拿到
/// asset 的音轨；拿不到（还没解析出来、或者根本不是音频）就整支不挂 mix，
/// 照老路直接播——过渡与增强器对这支失效，但绝不能因此播不出来。
@MainActor
final class DeckAudioMix {

    let audioMix: AVAudioMix
    private let parameters: AVMutableAudioMixInputParameters
    /// tap 的共享状态。实时线程与主线程都摸它，全是 `Atomic`，见 `AudioTap`。
    let tap: AudioTap?

    /// 等功率折线的节点。`setVolumeRamp` 只有线性斜坡，用 3 段折线逼近 cos/sin：
    /// 淡入取 `[0, .5, .866, 1]`、淡出取它的镜像，节点处两条曲线的功率和正好是 1
    /// （0.25+0.75 = 0.75+0.25 = 1），段内最低约 −0.3 dB，听不出凹陷。[推]
    /// 真正的等功率要 cos/sin，AVFoundation 没有非线性斜坡的 API，只能折线逼近。
    static let equalPowerNodes: [Float] = [0, 0.5, 0.866, 1]

    /// 建这一份 mix 用的音轨。留着是为了 `flatCopy()`：
    /// `AVMutableAudioMixInputParameters` 只能加斜坡不能删，要撤掉淡出只能整份重建。
    private let assetTrack: AVAssetTrack

    init?(track: AVAssetTrack, tap: AudioTap?) {
        let parameters = AVMutableAudioMixInputParameters(track: track)
        self.parameters = parameters
        self.tap = tap
        self.assetTrack = track
        if let tap { parameters.audioTapProcessor = tap.processingTap }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        audioMix = mix
    }

    /// 复制一份「没有任何斜坡」的 mix，**tap 是同一个**（响度可能还在量着，换不得）。
    /// 交叠被取消时用：淡出斜坡已经写进 `parameters` 了，没有 API 能把它取下来。
    func flatCopy() -> DeckAudioMix? {
        let copy = DeckAudioMix(track: assetTrack, tap: tap)
        copy?.applyFlat()
        return copy
    }

    /// 从 `start` 起 `seconds` 秒淡入（0 → 1）。
    func applyFadeIn(start: TimeInterval, seconds: TimeInterval) {
        applyRamp(start: start, seconds: seconds, nodes: Self.equalPowerNodes)
    }

    /// 从 `start` 起 `seconds` 秒淡出（1 → 0）。
    func applyFadeOut(start: TimeInterval, seconds: TimeInterval) {
        applyRamp(start: start, seconds: seconds, nodes: Self.equalPowerNodes.reversed())
    }

    /// 全程满音量（不过渡的那些 item）。
    func applyFlat() {
        parameters.setVolume(1, at: .zero)
    }

    private func applyRamp<S: Sequence<Float>>(start: TimeInterval, seconds: TimeInterval, nodes: S) {
        let values = Array(nodes)
        guard values.count >= 2, seconds > 0 else { return }
        let step = seconds / Double(values.count - 1)
        parameters.setVolume(values[0], at: CMTime(seconds: start, preferredTimescale: 600))
        for i in 0..<(values.count - 1) {
            let from = start + Double(i) * step
            let range = CMTimeRange(
                start: CMTime(seconds: from, preferredTimescale: 600),
                duration: CMTime(seconds: step, preferredTimescale: 600))
            parameters.setVolumeRamp(fromStartVolume: values[i], toEndVolume: values[i + 1],
                                     timeRange: range)
        }
    }

    /// 这一支不再使用：放掉 tap 的共享状态（实时回调可能还在跑，靠 tap 自己的 retain 兜底）。
    func invalidate() {
        tap?.invalidate()
    }
}

/// 折线斜坡的节点计算，供测试直接验功率和（不需要 asset）。
enum CrossfadeRamp {

    /// 过渡时长 N：设置里的上限 6 秒封顶，短歌按 1/4 时长收，不足 12 秒不过渡。
    ///
    /// 6 秒是 iTunes「歌曲过渡」滑杆 1–12 秒量程的中点，也是它的出厂值。[推]
    /// Amber 的设置窗里没有这根滑杆（Music 已经把它收成一个勾选框），所以取那个默认。
    /// `duration/4` 与 12 秒下限都是为了别让一首 20 秒的间奏被过渡吃掉小一半。[推]
    static let maxSeconds: TimeInterval = 6
    static let minTrackSeconds: TimeInterval = 12

    /// 预取提前量：QQ 取流实测 2–4 秒，留一次重试的余量；20 秒又远短于 vkey 的有效期，
    /// 不会出现「预取时拿到的地址、真播时已经过期」。[推]
    static let prefetchLead: TimeInterval = 20

    static func seconds(forDuration duration: TimeInterval) -> TimeInterval? {
        guard duration.isFinite, duration >= minTrackSeconds else { return nil }
        return min(maxSeconds, duration / 4)
    }

    /// 折线在 `t ∈ [0, 1]` 处的值（淡入方向）。测试用它验等功率。
    static func fadeInValue(at t: Double) -> Double {
        let nodes = DeckAudioMix.equalPowerNodes.map(Double.init)
        return interpolate(nodes, at: t)
    }

    static func fadeOutValue(at t: Double) -> Double {
        let nodes = DeckAudioMix.equalPowerNodes.reversed().map(Double.init)
        return interpolate(nodes, at: t)
    }

    private static func interpolate(_ nodes: [Double], at t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        let scaled = clamped * Double(nodes.count - 1)
        let i = min(Int(scaled), nodes.count - 2)
        let f = scaled - Double(i)
        return nodes[i] + (nodes[i + 1] - nodes[i]) * f
    }
}
