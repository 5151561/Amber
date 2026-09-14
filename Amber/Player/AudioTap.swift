import AVFoundation
import Accelerate
import Foundation
import MediaToolbox
import Synchronization

// MARK: - 主线程侧的偏好快照

/// 播放器要从设置里读的那几项，抽成一个可比较的小结构：
/// `AppSettings.$values` 每次写回都会发一遍，`removeDuplicates()` 之后只有真变了才推给 tap。
struct AudioPrefs: Equatable, Sendable {
    var soundEnhancer: Bool
    var soundEnhancerLevel: Double
    var soundCheck: Bool

    init(soundEnhancer: Bool, soundEnhancerLevel: Double, soundCheck: Bool) {
        self.soundEnhancer = soundEnhancer
        self.soundEnhancerLevel = soundEnhancerLevel
        self.soundCheck = soundCheck
    }

    init(_ values: SettingsValues) {
        self.init(soundEnhancer: values.soundEnhancer,
                  soundEnhancerLevel: values.soundEnhancerLevel,
                  soundCheck: values.soundCheck)
    }

    /// 关着时是 −1：实时回调只看这一个数就知道要不要做滤波，不用再读一个 Bool。
    var enhancerLevel: Int32 { soundEnhancer ? Int32(soundEnhancerLevel.rounded()) : -1 }
}

// MARK: - 实时线程与主线程之间的共享状态

/// tap 的共享状态。**主线程只写、实时线程只读**（测量结果反过来），全部走 `Atomic`：
/// 实时回调里不许有锁，也不许有任何会走到 ObjC runtime / 分配器的东西。
final class TapShared: @unchecked Sendable {

    /// 增强器档位，−1 = 关。
    let enhancerLevel = Atomic<Int32>(-1)
    /// 增强器的几条曲线（低架 / 高架 / 临场感峰值 / 前置衰减），单位 0.001 dB。
    /// 主线程算好放这儿，实时线程只在版本号变了时读一次并折算成 biquad 系数。
    let lowShelfMilliDB = Atomic<Int32>(0)
    let highShelfMilliDB = Atomic<Int32>(0)
    let presenceMilliDB = Atomic<Int32>(0)
    let preampMilliDB = Atomic<Int32>(0)
    /// 立体声展宽的侧信号倍数 × 1000（1000 = 原样）。与上面几条同一把 seqlock。
    let sideGainMilli = Atomic<Int32>(1000)
    /// 上面三条的版本号（seqlock）：实时线程读前读后各看一次，中途被改过就这一块先不换系数。
    let coeffVersion = Atomic<Int32>(0)

    /// 音量平衡的增益，单位 0.001 dB。0 表示不调（首播不归一，见 §4.3）。
    let gainMilliDB = Atomic<Int32>(0)
    /// 这一支要不要边播边量响度。
    let measure = Atomic<Bool>(false)
    /// 播放期间被 seek 过：整首的积分响度就不作数了，量出来的不写回。
    let seeked = Atomic<Bool>(false)

    /// 淡出的备选路径（`PlayerController.fadeOutViaTap`）：斜坡起点与时长，单位毫秒。
    /// 起点 < 0 表示不淡出。tap 按 `MTAudioProcessingTapGetSourceAudio` 报回来的
    /// `timeRange` 自己算曲线，退场那一路就不用重装 `audioMix`。
    let fadeOutStartMs = Atomic<Int64>(-1)
    let fadeOutMs = Atomic<Int32>(0)

    // MARK: 测量结果（实时线程写、主线程读）

    /// 已完成的 400 ms 块数。
    let blockCount = Atomic<Int32>(0)
    /// 采样峰值（绝对值）× 100000，用整数存是为了不依赖 `Atomic<Float>`。
    let peakScaled = Atomic<Int32>(0)
    /// 进过 tap 的总帧数。用来判断「整首都量到了没有」。
    let framesSeen = Atomic<Int64>(0)
    /// 每块的均方能量（已加 K 权、按声道加权求和）。预分配 36 000 个 = 1 小时，
    /// 实时线程只往里写、绝不扩容；超出就停止记块（长于一小时的音轨不做归一）。
    static let blockCapacity = 36_000
    let blocks: UnsafeMutablePointer<Float>

    /// DSP 状态。**只有 tap 的 prepare / process / unprepare 摸它**，
    /// prepare 里分配、unprepare 里释放；`audioMix` 重装会走一遍 unprepare→prepare，
    /// 但上面那些测量结果**不重置**，否则一次重装就把已经量了三分钟的数据丢了。
    var dsp: UnsafeMutablePointer<TapDSP>?

    init() {
        blocks = .allocate(capacity: Self.blockCapacity)
        blocks.initialize(repeating: 0, count: Self.blockCapacity)
    }

    deinit {
        blocks.deinitialize(count: Self.blockCapacity)
        blocks.deallocate()
        if let dsp {
            dsp.pointee.release()
            dsp.deinitialize(count: 1)
            dsp.deallocate()
        }
    }

    /// 主线程：把整条曲线一次性换掉（seqlock 的写侧）。
    func writeCurve(_ curve: SoundEnhancerCurve.Gains) {
        coeffVersion.wrappingAdd(1, ordering: .releasing)
        lowShelfMilliDB.store(Int32((curve.lowDB * 1000).rounded()), ordering: .relaxed)
        highShelfMilliDB.store(Int32((curve.highDB * 1000).rounded()), ordering: .relaxed)
        presenceMilliDB.store(Int32((curve.presenceDB * 1000).rounded()), ordering: .relaxed)
        preampMilliDB.store(Int32((curve.preampDB * 1000).rounded()), ordering: .relaxed)
        sideGainMilli.store(Int32((curve.sideGain * 1000).rounded()), ordering: .relaxed)
        coeffVersion.wrappingAdd(1, ordering: .releasing)
    }

    /// 主线程：把量到的块搬出来（换歌前调一次）。
    func snapshotBlocks() -> [Float] {
        let count = Int(blockCount.load(ordering: .acquiring))
        guard count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: blocks, count: min(count, Self.blockCapacity)))
    }

    var peak: Float { Float(peakScaled.load(ordering: .relaxed)) / 100_000 }
}

/// 实时线程独占的滤波 / 测量状态。分配与释放都在 prepare / unprepare，不在 process。
struct TapDSP {
    var sampleRate: Double = 0
    var channels: Int = 0
    var maxFrames: Int = 0

    /// 每声道三节（低架 + 临场感 + 高架）DF2T 的两个状态量：`channels * 3 * 2`
    var shelfState: UnsafeMutablePointer<Float>?
    /// K 加权（高架 + 高通两节）每声道两个状态量：`channels * 2 * 2`
    var kState: UnsafeMutablePointer<Float>?
    /// 一块的工作区（单声道平方和），`maxFrames` 长
    var scratch: UnsafeMutablePointer<Float>?

    var lowCoeff = Biquad.Coefficients.identity
    var presenceCoeff = Biquad.Coefficients.identity
    var highCoeff = Biquad.Coefficients.identity
    var kHighShelf = Biquad.Coefficients.identity
    var kHighPass = Biquad.Coefficients.identity
    /// 已经吃进系数的版本号 / 档位，用来判断要不要重算。
    var appliedVersion: Int32 = -1
    var appliedLevel: Int32 = -2
    var preampLinear: Float = 1
    /// 立体声展宽的侧信号倍数（线性，1 = 不展宽）。
    var sideGain: Float = 1

    /// 平滑到位的输出增益（线性）。开关切换时一阶滑过去，不出咔哒。
    var smoothedGain: Float = -1
    /// 400 ms 块的累计：能量和与已累计帧数。
    var blockEnergy: Double = 0
    var blockFrames: Int = 0
    /// 每声道的 K 权重（L/R/C = 1、Ls/Rs = 1.41、LFE = 0）
    var channelWeight: UnsafeMutablePointer<Float>?

    mutating func release() {
        shelfState?.deallocate(); shelfState = nil
        kState?.deallocate(); kState = nil
        scratch?.deallocate(); scratch = nil
        channelWeight?.deallocate(); channelWeight = nil
    }
}

// MARK: - tap 本体

/// 一支 item 一个 `MTAudioProcessingTap`。
///
/// 五个回调都是 `@convention(c)` 的静态函数，`clientInfo` 是 `Unmanaged.passRetained(TapShared)`；
/// process 里用 `_withUnsafeGuaranteedRef` 取回引用——它不产生 retain/release，
/// 也就不会在实时线程上碰 ObjC runtime 的引用计数。
///
/// `kMTAudioProcessingTapCreationFlag_PreEffects`：拿到的是**没有经过 audioMix 音量斜坡**的
/// 原始信号，所以交叉淡入淡出不会污染响度测量。
@MainActor
final class AudioTap {

    let processingTap: MTAudioProcessingTap
    let shared: TapShared
    private var invalidated = false

    init?() {
        let shared = TapShared()
        self.shared = shared
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(shared).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess)
        var tapRef: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects, &tapRef)
        guard status == noErr, let tapRef else {
            // 创建失败时把上面那次 passRetained 还回去，否则 TapShared 永远漏着。
            Unmanaged.passUnretained(shared).release()
            return nil
        }
        processingTap = tapRef
    }

    /// 主线程：推一次偏好。增强器档位、音量平衡增益都从这里进实时侧。
    func apply(_ prefs: AudioPrefs) {
        guard !invalidated else { return }
        let level = prefs.enhancerLevel
        shared.enhancerLevel.store(level, ordering: .relaxed)
        shared.writeCurve(SoundEnhancerCurve.gains(level: level))
    }

    /// 主线程：设这一支的响度归一增益（dB）。0 = 不调。
    func setGain(dB: Double) {
        shared.gainMilliDB.store(Int32((dB * 1000).rounded()), ordering: .relaxed)
    }

    /// 主线程：这一支要不要边播边量。
    func setMeasuring(_ on: Bool) {
        shared.measure.store(on, ordering: .relaxed)
    }

    /// 主线程：淡出的备选路径。从 `start` 秒起 `seconds` 秒把这一支收到 0。
    func setFadeOut(start: TimeInterval, seconds: TimeInterval) {
        shared.fadeOutMs.store(Int32(max(seconds, 0) * 1000), ordering: .relaxed)
        shared.fadeOutStartMs.store(Int64(max(start, 0) * 1000), ordering: .releasing)
    }

    /// 主线程：把淡出撤掉（交叠期间用户往回 seek，这一首要接着正常播完）。
    func clearFadeOut() {
        shared.fadeOutStartMs.store(-1, ordering: .releasing)
        shared.fadeOutMs.store(0, ordering: .relaxed)
    }

    /// 主线程：这一支被 seek 过，整首的积分响度作废。
    func markSeeked() {
        shared.seeked.store(true, ordering: .relaxed)
    }

    func invalidate() {
        invalidated = true
        shared.measure.store(false, ordering: .relaxed)
    }
}

// MARK: - 五个 C 回调

private func tapInit(tap: MTAudioProcessingTap,
                     clientInfo: UnsafeMutableRawPointer?,
                     tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    // clientInfo 已经是 passRetained 的裸指针，直接当 storage 用；finalize 里放。
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap: MTAudioProcessingTap) {
    guard let storage = MTAudioProcessingTapGetStorage(tap) as UnsafeMutableRawPointer? else { return }
    Unmanaged<TapShared>.fromOpaque(storage).release()
}

private func tapPrepare(tap: MTAudioProcessingTap,
                        maxFrames: CMItemCount,
                        processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
    let shared = Unmanaged<TapShared>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()
    let asbd = processingFormat.pointee
    let channels = Int(asbd.mChannelsPerFrame)
    let frames = Int(maxFrames)
    guard channels > 0, frames > 0 else { return }
    // 下面的加工全按「每个 buffer 一路 float32」写。AVFoundation 给 tap 的处理格式
    // 一向是非交织 float32，但这只是惯例不是契约：万一来的是交织或整型，
    // process 里按声道取 buffer 就会把左右声道当成一路去滤。不认识的格式就不装 dsp，
    // process 见 `shared.dsp == nil` 直接直通，宁可这一首没有增强器/响度也不能出错声。
    let flags = asbd.mFormatFlags
    guard asbd.mFormatID == kAudioFormatLinearPCM,
          flags & kAudioFormatFlagIsFloat != 0,
          flags & kAudioFormatFlagIsNonInterleaved != 0,
          asbd.mBitsPerChannel == 32 else { return }

    // prepare 不是实时回调，这里分配是允许的（实时回调里一个字节都不许分配）。
    let dsp = UnsafeMutablePointer<TapDSP>.allocate(capacity: 1)
    dsp.initialize(to: TapDSP())
    dsp.pointee.sampleRate = asbd.mSampleRate
    dsp.pointee.channels = channels
    dsp.pointee.maxFrames = frames
    dsp.pointee.shelfState = calloc(channels * 6, MemoryLayout<Float>.size)?
        .assumingMemoryBound(to: Float.self)
    dsp.pointee.kState = calloc(channels * 4, MemoryLayout<Float>.size)?
        .assumingMemoryBound(to: Float.self)
    dsp.pointee.scratch = calloc(frames, MemoryLayout<Float>.size)?
        .assumingMemoryBound(to: Float.self)
    let weights = calloc(channels, MemoryLayout<Float>.size)?
        .assumingMemoryBound(to: Float.self)
    if let weights {
        for c in 0..<channels { weights[c] = LoudnessMeter.channelWeight(index: c, channels: channels) }
    }
    dsp.pointee.channelWeight = weights
    let fs = asbd.mSampleRate
    dsp.pointee.kHighShelf = LoudnessMeter.kWeightingHighShelf(sampleRate: fs)
    dsp.pointee.kHighPass = LoudnessMeter.kWeightingHighPass(sampleRate: fs)

    if let old = shared.dsp {
        old.pointee.release()
        old.deinitialize(count: 1)
        old.deallocate()
    }
    shared.dsp = dsp
}

private func tapUnprepare(tap: MTAudioProcessingTap) {
    let shared = Unmanaged<TapShared>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()
    guard let dsp = shared.dsp else { return }
    shared.dsp = nil
    dsp.pointee.release()
    dsp.deinitialize(count: 1)
    dsp.deallocate()
}

/// **实时线程**。规则：不分配、不加锁、不碰 ObjC、不 print、不起 Task。
private func tapProcess(tap: MTAudioProcessingTap,
                        numberFrames: CMItemCount,
                        flags: MTAudioProcessingTapFlags,
                        bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
                        numberFramesOut: UnsafeMutablePointer<CMItemCount>,
                        flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    var timeRange = CMTimeRange.zero
    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, &timeRange, numberFramesOut)
    guard status == noErr else { return }
    let unmanaged = Unmanaged<TapShared>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
    unmanaged._withUnsafeGuaranteedRef { shared in
        guard let dsp = shared.dsp else { return }
        let frames = Int(numberFramesOut.pointee)
        guard frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
        // 非 float32（罕见：某些直通格式）一律直通，不做任何加工。
        guard buffers.count > 0, buffers[0].mData != nil else { return }
        let bytesPerFrame = Int(buffers[0].mDataByteSize) / max(frames, 1)
        guard bytesPerFrame == MemoryLayout<Float>.size * Int(buffers[0].mNumberChannels) else { return }

        tapMeasure(shared: shared, dsp: dsp, buffers: buffers, frames: frames)
        tapEnhance(shared: shared, dsp: dsp, buffers: buffers, frames: frames)
        tapGain(shared: shared, dsp: dsp, buffers: buffers, frames: frames)
        tapFadeOut(shared: shared, dsp: dsp, buffers: buffers, frames: frames,
                   startSeconds: timeRange.start.seconds)
    }
}

// MARK: - 实时线程的三段加工

/// DF2T 二阶节，就地滤波。手写循环：系数随时会换，`vDSP_biquad` 的 Setup 只能重建，
/// 重建就意味着在实时线程附近分配内存。
@inline(__always)
private func biquadInPlace(_ x: UnsafeMutablePointer<Float>, _ n: Int,
                           _ c: Biquad.Coefficients,
                           _ state: UnsafeMutablePointer<Float>) {
    var s1 = state[0], s2 = state[1]
    let b0 = c.b0, b1 = c.b1, b2 = c.b2, a1 = c.a1, a2 = c.a2
    for i in 0..<n {
        let input = x[i]
        let y = b0 * input + s1
        s1 = b1 * input - a1 * y + s2
        s2 = b2 * input - a2 * y
        x[i] = y
    }
    // 静音之后状态会滑进非规格化数，一个非规格化乘法能吃掉几十倍的时间，直接抹平。
    state[0] = abs(s1) < 1e-25 ? 0 : s1
    state[1] = abs(s2) < 1e-25 ? 0 : s2
}

/// ① 测量。走在增强器与增益之前，量的是**原始信号**，
/// 加上 tap 建在 `PreEffects`，交叉淡入淡出的斜坡也进不来。
private func tapMeasure(shared: TapShared, dsp: UnsafeMutablePointer<TapDSP>,
                        buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
    guard shared.measure.load(ordering: .relaxed) else { return }
    guard let scratch = dsp.pointee.scratch,
          let kState = dsp.pointee.kState,
          let weights = dsp.pointee.channelWeight else { return }
    let channels = min(dsp.pointee.channels, buffers.count)
    let fs = dsp.pointee.sampleRate
    guard channels > 0, fs > 0 else { return }
    let subLen = Int((LoudnessMeter.subBlockSeconds * fs).rounded())
    guard subLen > 0, frames <= dsp.pointee.maxFrames else { return }

    var peak: Float = 0
    for c in 0..<channels {
        guard let data = buffers[c].mData else { continue }
        var m: Float = 0
        vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &m, vDSP_Length(frames))
        if m > peak { peak = m }
    }
    if peak.isFinite, peak > 0 {
        let scaled = Int32(min(peak, 20) * 100_000)
        if scaled > shared.peakScaled.load(ordering: .relaxed) {
            shared.peakScaled.store(scaled, ordering: .relaxed)
        }
    }
    shared.framesSeen.wrappingAdd(Int64(frames), ordering: .relaxed)

    // 按 100 ms 子块的边界切开，子块长度才是精确的（BS.1770 的 400 ms 块 = 4 个子块滑窗）。
    var offset = 0
    while offset < frames {
        let n = min(subLen - dsp.pointee.blockFrames, frames - offset)
        guard n > 0 else { break }
        var energy: Double = 0
        for c in 0..<channels {
            let w = weights[c]
            guard w > 0, let data = buffers[c].mData else { continue }
            scratch.update(from: data.assumingMemoryBound(to: Float.self) + offset, count: n)
            biquadInPlace(scratch, n, dsp.pointee.kHighShelf, kState + c * 4)
            biquadInPlace(scratch, n, dsp.pointee.kHighPass, kState + c * 4 + 2)
            var sum: Float = 0
            vDSP_svesq(scratch, 1, &sum, vDSP_Length(n))
            energy += Double(w) * Double(sum)
        }
        dsp.pointee.blockEnergy += energy
        dsp.pointee.blockFrames += n
        if dsp.pointee.blockFrames >= subLen {
            let index = Int(shared.blockCount.load(ordering: .relaxed))
            if index < TapShared.blockCapacity {
                shared.blocks[index] = Float(dsp.pointee.blockEnergy / Double(subLen))
                shared.blockCount.store(Int32(index + 1), ordering: .releasing)
            }
            dsp.pointee.blockEnergy = 0
            dsp.pointee.blockFrames = 0
        }
        offset += n
    }
}

/// ② 声音增强器：前级衰减 → 每声道低架 / 临场感 / 高架三节 DF2T → 立体声展宽 → 软限幅。
///
/// 系数在这里算而不是主线程算好送进来：架高量取决于**这一路流的采样率**，
/// 而采样率要到 tap 的 `prepare` 才知道。主线程送的是几条曲线的 dB 值（seqlock 保护），
/// 折算成系数只有几次 sin/cos/pow——叶子数学函数，不分配也不加锁，符合实时线程规则。
private func tapEnhance(shared: TapShared, dsp: UnsafeMutablePointer<TapDSP>,
                        buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
    guard let state = dsp.pointee.shelfState else { return }
    let channels = min(dsp.pointee.channels, buffers.count)
    guard channels > 0 else { return }
    let level = shared.enhancerLevel.load(ordering: .relaxed)
    guard level >= 0 else {
        // 刚关掉：清一次滤波器状态，下次打开不会把几分钟前的尾巴接上。
        if dsp.pointee.appliedLevel != -1 {
            state.update(repeating: 0, count: channels * 6)
            dsp.pointee.appliedLevel = -1
        }
        return
    }
    dsp.pointee.appliedLevel = level

    let version = shared.coeffVersion.load(ordering: .acquiring)
    if version != dsp.pointee.appliedVersion, version & 1 == 0 {
        let low = Double(shared.lowShelfMilliDB.load(ordering: .relaxed)) / 1000
        let high = Double(shared.highShelfMilliDB.load(ordering: .relaxed)) / 1000
        let presence = Double(shared.presenceMilliDB.load(ordering: .relaxed)) / 1000
        let pre = Double(shared.preampMilliDB.load(ordering: .relaxed)) / 1000
        let side = Double(shared.sideGainMilli.load(ordering: .relaxed)) / 1000
        if shared.coeffVersion.load(ordering: .acquiring) == version {
            let fs = dsp.pointee.sampleRate
            dsp.pointee.lowCoeff = Biquad.lowShelf(
                frequency: SoundEnhancerCurve.lowFrequency, sampleRate: fs, gainDB: low)
            dsp.pointee.presenceCoeff = Biquad.peaking(
                frequency: SoundEnhancerCurve.presenceFrequency, sampleRate: fs,
                gainDB: presence, q: SoundEnhancerCurve.presenceQ)
            dsp.pointee.highCoeff = Biquad.highShelf(
                frequency: SoundEnhancerCurve.highFrequency, sampleRate: fs, gainDB: high)
            dsp.pointee.preampLinear = Float(pow(10, pre / 20))
            dsp.pointee.sideGain = Float(side)
            dsp.pointee.appliedVersion = version
        }
    }

    var preamp = dsp.pointee.preampLinear
    let low = dsp.pointee.lowCoeff, high = dsp.pointee.highCoeff
    let presence = dsp.pointee.presenceCoeff
    let width = dsp.pointee.sideGain
    // 滑杆在最左（t = 0）时几条曲线都是恒等，整段跳过——连软限幅都不挂，
    // 「开着但滑到 0」与「关着」在信号上必须一模一样。
    guard preamp != 1 || low != .identity || high != .identity
            || presence != .identity || width != 1 else { return }
    for c in 0..<channels {
        guard let data = buffers[c].mData else { continue }
        let x = data.assumingMemoryBound(to: Float.self)
        if preamp != 1 { vDSP_vsmul(x, 1, &preamp, x, 1, vDSP_Length(frames)) }
        if low != .identity { biquadInPlace(x, frames, low, state + c * 6) }
        if presence != .identity { biquadInPlace(x, frames, presence, state + c * 6 + 2) }
        if high != .identity { biquadInPlace(x, frames, high, state + c * 6 + 4) }
    }
    tapWiden(dsp: dsp, buffers: buffers, frames: frames, width: width)

    // 末级软限幅。几节架高叠起来最坏能抬到 +8 dB 上下，前级只让掉 2 dB，
    // 满档遇上本来就顶着 0 dBFS 的母带一定会过 1.0；硬削是砂音，这里用 tanh 软化。
    for c in 0..<channels {
        guard let data = buffers[c].mData else { continue }
        let x = data.assumingMemoryBound(to: Float.self)
        for i in 0..<frames { x[i] = SoundEnhancerCurve.softClip(x[i]) }
    }
}

/// 立体声展宽（M/S）。**只对正好两声道的流做**：单声道没有侧信号，
/// 多声道要按环绕矩阵来，一律跳过。
///
/// L' = M + w·S、R' = M − w·S（M =（L+R）/2、S =（L−R）/2）展开就是一个 2×2 矩阵：
/// p =（1+w）/2、q =（1−w）/2 时 L' = pL + qR、R' = qL + pR。两次 `vDSP_vsmsma`
/// 算完，中间那份借测量用的 `scratch`（测量在这一块之前已经跑完，不冲突），
/// 不额外分配。
private func tapWiden(dsp: UnsafeMutablePointer<TapDSP>,
                      buffers: UnsafeMutableAudioBufferListPointer,
                      frames: Int, width: Float) {
    guard width != 1, dsp.pointee.channels == 2, buffers.count == 2,
          frames <= dsp.pointee.maxFrames,
          let scratch = dsp.pointee.scratch,
          let leftData = buffers[0].mData, let rightData = buffers[1].mData else { return }
    let left = leftData.assumingMemoryBound(to: Float.self)
    let right = rightData.assumingMemoryBound(to: Float.self)
    var p = (1 + width) / 2
    var q = (1 - width) / 2
    vDSP_vsmsma(left, 1, &p, right, 1, &q, scratch, 1, vDSP_Length(frames))
    vDSP_vsmsma(left, 1, &q, right, 1, &p, right, 1, vDSP_Length(frames))
    left.update(from: scratch, count: frames)
}

/// ③ 音量平衡的固定增益。块内按线性斜坡滑过去（一阶平滑，时间常数 50 ms），
/// 开关切换或换曲时不出咔哒。
private func tapGain(shared: TapShared, dsp: UnsafeMutablePointer<TapDSP>,
                     buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
    let milli = shared.gainMilliDB.load(ordering: .relaxed)
    let target = milli == 0 ? Float(1) : Float(pow(10, Double(milli) / 20000))
    if dsp.pointee.smoothedGain < 0 { dsp.pointee.smoothedGain = target }
    let start = dsp.pointee.smoothedGain
    let fs = dsp.pointee.sampleRate
    let alpha = fs > 0 ? Float(1 - exp(-Double(frames) / (0.05 * fs))) : 1
    let end = start + (target - start) * alpha
    dsp.pointee.smoothedGain = end
    guard start != 1 || end != 1 else { return }
    let channels = min(dsp.pointee.channels, buffers.count)
    var step = (end - start) / Float(max(frames, 1))
    for c in 0..<channels {
        guard let data = buffers[c].mData else { continue }
        let x = data.assumingMemoryBound(to: Float.self)
        var s = start
        vDSP_vrampmul(x, 1, &s, &step, x, 1, vDSP_Length(frames))
    }
}

/// ④ 淡出（备选路径，`PlayerController.fadeOutViaTap` 打开时才生效）。
///
/// 主路是给 `audioMix` 补一段音量斜坡，但那要把 `audioMix` 重新赋回正在播的 item，
/// tap 会跟着走一遍 unprepare→prepare。这条路把同一条曲线搬进 tap 自己算：
/// 位置从 `timeRange.start` 来，曲线用真正的 cos（不需要像 `setVolumeRamp` 那样折线逼近）。
private func tapFadeOut(shared: TapShared, dsp: UnsafeMutablePointer<TapDSP>,
                        buffers: UnsafeMutableAudioBufferListPointer, frames: Int,
                        startSeconds: Double) {
    let startMs = shared.fadeOutStartMs.load(ordering: .acquiring)
    guard startMs >= 0, startSeconds.isFinite else { return }
    let fadeSeconds = Double(shared.fadeOutMs.load(ordering: .relaxed)) / 1000
    guard fadeSeconds > 0 else { return }
    let fs = dsp.pointee.sampleRate
    guard fs > 0 else { return }
    let from = Double(startMs) / 1000

    // 这一块的首尾各算一个增益，块内线性插值（块只有几毫秒，曲线的二阶差可以忽略）。
    func gain(at t: Double) -> Float {
        let x = (t - from) / fadeSeconds
        if x <= 0 { return 1 }
        if x >= 1 { return 0 }
        return Float(cos(x * Double.pi / 2))
    }
    let head = gain(at: startSeconds)
    let tail = gain(at: startSeconds + Double(frames) / fs)
    guard head != 1 || tail != 1 else { return }

    let channels = min(dsp.pointee.channels, buffers.count)
    var step = (tail - head) / Float(max(frames, 1))
    for c in 0..<channels {
        guard let data = buffers[c].mData else { continue }
        let x = data.assumingMemoryBound(to: Float.self)
        var s = head
        vDSP_vrampmul(x, 1, &s, &step, x, 1, vDSP_Length(frames))
    }
}
