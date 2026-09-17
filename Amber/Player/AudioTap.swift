import AVFoundation
import Accelerate
import Foundation
import MediaToolbox
import Synchronization

// MARK: - 这个文件的不安全契约
//
// 整个文件是一支 `MTAudioProcessingTap`：五个 `@convention(c)` 回调由 MediaToolbox
// 调用，其中 `tapProcess` 跑在**它自己的实时音频线程**上。开了 strict memory safety
//（SE-0458）之后这里报了 152 条——不是 152 个问题，是下面四条契约被重复表述了 152 遍。
// 改这个文件之前先读这四条：它们决定了你的改动会不会违约。
//
// ① **实时线程规则**。适用于 `tapProcess` 与它调用的 `tapMeasure` / `tapEnhance` /
//    `tapWiden` / `tapGain` / `tapFadeOut` / `biquadInPlace`。这条线程有硬截止期——
//    晚一点就是一次听得见的爆音，所以这几个函数里**不许**出现：
//      - 任何内存分配或释放：`Array`、`String`、闭包装箱、`calloc` / `free`；
//      - 任何锁与等待：`NSLock`、`os_unfair_lock`、信号量、`DispatchQueue.sync`；
//      - 任何 ObjC / Swift 运行时调用：retain/release、动态派发、`as?` 桥接、`print`；
//      - 任何文件或网络 IO，任何 `Task` / `await` / 回主 actor；
//      - 任何无上界的循环：帧数由 `numberFrames` 给，块数由 `blockCapacity` 封顶。
//    主线程与实时线程之间只经由 `TapShared` 里的 `Atomic` 通信，曲线那一组走 seqlock。
//    `tapProcess` 用 `_withUnsafeGuaranteedRef` 而不是 `takeUnretainedValue()` 取回
//    `TapShared`，就是为了不在实时线程上碰引用计数——后者也能编过，但违约。
//    「只能由 MediaToolbox 在实时线程调用」是事实不是缺陷，所以这几个函数标 `@unsafe`：
//    标注朝**外**，让任何新的调用点都必须显式写 `unsafe`，先想清楚自己在哪条线程上。
//
// ② **clientInfo 的所有权契约**。`init?()` 里 `Unmanaged.passRetained(shared)` 把一次 +1
//    交给 MediaToolbox，`tapInit` 原样存进 tap storage，`tapFinalize` 里 `release()` 还回去，
//    全程正好一次。创建失败那一路没有人会调 finalize，所以就地 `passUnretained(shared).release()`
//    把那次 +1 抵掉。**动这一段就是在动引用计数配平**，多一次少一次都不会当场报错。
//
// ③ **`TapDSP` 分配的生命周期契约**。`TapShared.dsp` 是一块手工分配的内存：
//    `tapPrepare` 里 allocate/initialize，`tapUnprepare` 里 deinitialize/deallocate，
//    `TapShared.deinit` 兜底。MediaToolbox 把同一支 tap 的 prepare / process / unprepare
//    **串行**发出，所以 process 拿到的非空 `dsp` 在这一次调用里一定活着、而且只有它一个在摸。
//    这个句柄本身存成 `Atomic<UInt>`（`TapShared.dspBits`，读写各经 `dsp` / `installDSP`）：
//    串行下发是平台保证、不是这里的假设，但「跨线程共享的字段一律走 `Atomic`」这条
//    在本文件里不该有例外——少一条要靠读注释才成立的规矩。装新的一份走
//    `installDSP` 的 exchange，**先装新的再交出旧的**，释放永远发生在「不可能再被读到」之后。
//    这一条被 51 处 `dsp.pointee.<字段>` 重复表述了 51 遍——同一件事不写 51 遍，
//    收进下面 `UnsafeMutablePointer<TapDSP>.rt` 那个 `@safe` 外壳，契约写在它那儿一次。
//
// ④ **裸 float 缓冲区的定容契约**。两类：
//    a. `TapDSP` 里那四块 `calloc`（`shelfState` / `kState` / `scratch` / `channelWeight`）：
//       容量在 `tapPrepare` 里按 `channels` 与 `maxFrames` 一次定死，之后只读不扩容；
//       每个使用点都先过 `c < channels` 与 `frames <= maxFrames` 两道闸。
//    b. MediaToolbox 给的 `AudioBufferList`：只在这一次 `tapProcess` 调用期间有效。
//       `tapPrepare` 已经验过处理格式是非交织 float32（不是就不装 dsp，process 直接直通），
//       所以 `assumingMemoryBound(to: Float.self)` 拿到的确实是 float32。
//    这一条**没有**安全替代——`vDSP` 全系列吃的就是裸指针——也不适合做 `@safe` 外壳：
//    外壳的返回值仍然是 `UnsafeMutablePointer<Float>`，包了等于没包。所以就地写 `unsafe`。
//    读代码时反过来用：**看见 `unsafe` 就是「这里在拿裸缓冲区做指针算术」**，正是该停下来
//    核一遍长度的地方；看不见 `unsafe` 的行，长度已经由上面三条契约兜住了。
//
// 顺带一条给改动者的提醒：`TapShared` 与 `TapDSP` 标的是 `@safe` 而不是 `@unsafe`。
// 它们确实**持有**裸内存，但自己管好了生命周期，对外暴露的是安全 API
//（`snapshotBlocks()`、几个 `Atomic`、`peak`），主线程侧的 `PlayerController` 照常调用。
// 标成 `@unsafe` 会让每一个外部使用点都被要求写 `unsafe`，那是把契约泄漏到不相干的文件里。

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

/// tap 的共享状态。**主线程只写、实时线程只读**（测量结果反过来），全部走 `Atomic`
///（**包括 `dsp` 那个句柄**，见契约 ③）：实时回调里不许有锁，
/// 也不许有任何会走到 ObjC runtime / 分配器的东西。
///
/// `@safe`：这个类持有两块裸内存（`blocks` 与 `dsp` 指着的那块），但生命周期全在自己手里
///（`blocks` 在 init/deinit 配平，`dsp` 见契约 ③），对外只暴露安全 API。
/// 见文件头「顺带一条」：标 `@unsafe` 会把契约泄漏给 `PlayerController` 那些正常调用点。
@safe
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
    ///
    /// 存的是**指针位模式**，不是 `UnsafeMutablePointer<TapDSP>?`。它从前是这 13 个
    /// `Atomic` 兄弟里唯一的裸字段：实时线程的 `tapProcess` 读、prepare / unprepare 写。
    ///
    /// **这不是在修一个 use-after-free**——契约 ③ 写明 MediaToolbox 对同一支 tap 的
    /// prepare / process / unprepare 是串行下发的，那是平台保证，不是这里的假设。
    /// 换成 `Atomic` 是把「靠外部时序假设兜住」换成「靠类型系统兜住」：这个字段的
    /// 跨线程可见性从此与 `enhancerLevel`、`gainMilliDB` 那些同一套规矩，
    /// 读它的人不必再翻到文件头去确认自己有没有资格读。零成本——
    /// `Atomic<UInt>.load` 编出来就是一条 `ldar`，实时线程上不分配、不加锁、不碰 runtime。
    private let dspBits = Atomic<UInt>(0)

    /// 实时线程侧的读法：0 ＝ 没装 dsp，`tapProcess` 直接直通（见 `tapPrepare` 的格式闸）。
    /// `.acquiring` 与 `installDSP` 的 `.acquiringAndReleasing` 配对：读到非空指针时，
    /// `tapPrepare` 往那块内存里写的初值也一定一并可见。
    ///
    /// **只有「整数 → 指针」这半边是 `unsafe`**：凭一个位模式造出指针是编译器管不了的一步，
    /// 反过来（指针 → 整数，见 `installDSP`）只是把指针丢掉，标了反而会被
    /// `[#UnnecessaryUnsafe]` 哨兵点名。
    var dsp: UnsafeMutablePointer<TapDSP>? {
        unsafe UnsafeMutablePointer<TapDSP>(bitPattern: dspBits.load(ordering: .acquiring))
    }

    /// 装上新的一份，**返回被换下来的那一份**（nil 表示本来就没有）。
    /// 调用方负责在拿到之后 `release()` + `deinitialize` + `deallocate`。
    ///
    /// 先换后放，不是先放后换：旧那份从这一刻起就不可能再被 `tapProcess` 读到，
    /// 释放它才是安全的。从前的写法是「先释放旧的、再赋新的」，那中间有一拍
    /// `dsp` 仍指着已经释放的内存——串行契约下摸不到，但没必要留着。
    @discardableResult
    func installDSP(_ new: UnsafeMutablePointer<TapDSP>?) -> UnsafeMutablePointer<TapDSP>? {
        let bits = UInt(bitPattern: UnsafeMutableRawPointer(new))
        let old = dspBits.exchange(bits, ordering: .acquiringAndReleasing)
        return unsafe UnsafeMutablePointer<TapDSP>(bitPattern: old)
    }

    // 下面 init / deinit 这一对就是 `blocks` 的全部生命周期：一次 allocate + initialize，
    // 一次 deinitialize + deallocate，中间只有实时线程按 `blockCapacity` 封顶地写。
    init() {
        unsafe blocks = .allocate(capacity: Self.blockCapacity)
        unsafe blocks.initialize(repeating: 0, count: Self.blockCapacity)
    }

    deinit {
        unsafe blocks.deinitialize(count: Self.blockCapacity)
        unsafe blocks.deallocate()
        // 兜底：正常路径上 `tapUnprepare` 已经收掉了，这里管的是「tap 没走完就整个没了」。
        if let dsp = unsafe installDSP(nil) {
            dsp.rt.release()
            unsafe dsp.deinitialize(count: 1)
            unsafe dsp.deallocate()
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
        // 契约 ④a：`blocks` 定容 `blockCapacity`，`min` 就是那道闸。
        return unsafe Array(UnsafeBufferPointer(start: blocks, count: min(count, Self.blockCapacity)))
    }

    var peak: Float { Float(peakScaled.load(ordering: .relaxed)) / 100_000 }
}

/// 实时线程独占的滤波 / 测量状态。分配与释放都在 prepare / unprepare，不在 process。
///
/// `@safe`：四个指针字段指向契约 ④a 那四块 `calloc`，由 `release()` 统一释放。
/// 这个类型必须是 `@safe` 的，否则下面 `rt` 外壳的返回值本身又成了不安全表达式。
@safe
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
        unsafe shelfState?.deallocate(); unsafe shelfState = nil
        unsafe kState?.deallocate(); unsafe kState = nil
        unsafe scratch?.deallocate(); unsafe scratch = nil
        unsafe channelWeight?.deallocate(); unsafe channelWeight = nil
    }
}

/// 契约 ③ 的落点：`dsp.pointee` 在这个文件里出现 51 次，说的都是同一件事——
/// 「MediaToolbox 串行发 prepare / process / unprepare，所以 process 手里的非空 `dsp`
/// 这一次调用里一定活着，而且只有它一个在摸」。同一条契约不写 51 遍，写在这儿一遍。
///
/// 约束在 `Pointee == TapDSP` 上，是为了不把「裸指针解引用」这件事泛化成全仓可用的安全操作：
/// 这个外壳只认这一个类型，别处的 `UnsafeMutablePointer` 一律照常报警。
///
/// 用 `_read` / `_modify` 协程存取器而不是 `get` / `set`：后者会在每次写字段时
/// 把整个 `TapDSP`（两百来字节）拷进拷出，那是实时线程上凭空多出来的开销。
/// 协程版就地 yield 地址，不产生拷贝——换外壳时**务必保持这一点**，
/// 改成 `get` / `set` 能编过、能跑对，但会在实时回调里多出每次一趟的结构体拷贝。
/// 引入时比对过：整个模块 `-O` 下 tap 各函数的 SIL，与直接写 `dsp.pointee` 的版本
/// 指令构成完全相同（2484 行里只有两条指令的调度顺序不同）。
extension UnsafeMutablePointer where Pointee == TapDSP {
    @safe var rt: TapDSP {
        _read { yield unsafe pointee }
        nonmutating _modify { yield &(unsafe pointee) }
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
        // 契约 ②：`passRetained` 在这里交出一次 +1，之后只有两条路能把它还回来——
        // 正常路径走 `tapFinalize`，创建失败路径走下面那句 `passUnretained(...).release()`。
        // 这一整条语句一个 `unsafe` 盖住：裸指针 clientInfo、五个 `@unsafe` 回调的函数引用，
        // 说的都是同一件事——把这支 tap 的所有权和入口交给 MediaToolbox。
        var callbacks = unsafe MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(shared).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess)
        var tapRef: MTAudioProcessingTap?
        let status = unsafe MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects, &tapRef)
        guard status == noErr, let tapRef else {
            // 创建失败时把上面那次 passRetained 还回去，否则 TapShared 永远漏着。
            // 这一路 MediaToolbox 不会调 finalize，所以必须自己配平（契约 ②）。
            unsafe Unmanaged.passUnretained(shared).release()
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

/// 契约 ①/②。只由 MediaToolbox 调用。
@unsafe
private func tapInit(tap: MTAudioProcessingTap,
                     clientInfo: UnsafeMutableRawPointer?,
                     tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    // clientInfo 已经是 passRetained 的裸指针，直接当 storage 用；finalize 里放。
    // `tapStorageOut` 由 MediaToolbox 提供，只在这次调用里有效。
    unsafe tapStorageOut.pointee = clientInfo
}

/// 契约 ②的收尾：把 `init?()` 里那次 +1 还回去，全程只有这一处（失败路径除外）。
@unsafe
private func tapFinalize(tap: MTAudioProcessingTap) {
    guard let storage = unsafe MTAudioProcessingTapGetStorage(tap) as UnsafeMutableRawPointer? else { return }
    unsafe Unmanaged<TapShared>.fromOpaque(storage).release()
}

/// 契约 ③的起点：`dsp` 在这里分配。不是实时回调，允许分配。
@unsafe
private func tapPrepare(tap: MTAudioProcessingTap,
                        maxFrames: CMItemCount,
                        processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
    // storage 里存的就是 `init?()` 放进去的那个 TapShared，取引用不转移所有权。
    let shared = unsafe Unmanaged<TapShared>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()
    let asbd = unsafe processingFormat.pointee
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
    // 契约 ④a 的定容就发生在这几行：四块 calloc 的长度分别按 channels 与 frames 算死，
    // 之后 process 侧只按 `c < channels`、`frames <= maxFrames` 取用，不再有人改容量。
    let dsp = UnsafeMutablePointer<TapDSP>.allocate(capacity: 1)
    unsafe dsp.initialize(to: TapDSP())
    dsp.rt.sampleRate = asbd.mSampleRate
    dsp.rt.channels = channels
    dsp.rt.maxFrames = frames
    unsafe dsp.rt.shelfState = calloc(channels * 6, MemoryLayout<Float>.size)?
        .assumingMemoryBound(to: Float.self)
    unsafe dsp.rt.kState = calloc(channels * 4, MemoryLayout<Float>.size)?
        .assumingMemoryBound(to: Float.self)
    unsafe dsp.rt.scratch = calloc(frames, MemoryLayout<Float>.size)?
        .assumingMemoryBound(to: Float.self)
    let weights = unsafe calloc(channels, MemoryLayout<Float>.size)?
        .assumingMemoryBound(to: Float.self)
    if let weights = unsafe weights {
        for c in 0..<channels { unsafe weights[c] = LoudnessMeter.channelWeight(index: c, channels: channels) }
    }
    unsafe dsp.rt.channelWeight = weights
    let fs = asbd.mSampleRate
    dsp.rt.kHighShelf = LoudnessMeter.kWeightingHighShelf(sampleRate: fs)
    dsp.rt.kHighPass = LoudnessMeter.kWeightingHighPass(sampleRate: fs)

    // 重装 audioMix 会再走一遍 prepare，旧的那份在这里收掉（契约 ③）。
    // `installDSP` 是「先装新的、再交出旧的」：旧那份被交出来的那一刻起就不可能
    // 再被 `tapProcess` 读到，释放它才是安全的。
    if let old = unsafe shared.installDSP(dsp) {
        old.rt.release()
        unsafe old.deinitialize(count: 1)
        unsafe old.deallocate()
    }
}

/// 契约 ③的终点：`dsp` 在这里释放。与 `tapPrepare` 由 MediaToolbox 串行发出，
/// 所以不会和正在跑的 `tapProcess` 打架。
@unsafe
private func tapUnprepare(tap: MTAudioProcessingTap) {
    let shared = unsafe Unmanaged<TapShared>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()
    guard let dsp = unsafe shared.installDSP(nil) else { return }
    dsp.rt.release()
    unsafe dsp.deinitialize(count: 1)
    unsafe dsp.deallocate()
}

/// **实时线程**。规则：不分配、不加锁、不碰 ObjC、不 print、不起 Task——完整一份见文件头契约 ①。
///
/// `@unsafe` 标的是「只能由 MediaToolbox 在实时线程调用」这条**对外**契约：
/// 谁要在别处调它，编译器会逼他写 `unsafe`，先想清楚自己在哪条线程上。
@unsafe
private func tapProcess(tap: MTAudioProcessingTap,
                        numberFrames: CMItemCount,
                        flags: MTAudioProcessingTapFlags,
                        bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
                        numberFramesOut: UnsafeMutablePointer<CMItemCount>,
                        flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    var timeRange = CMTimeRange.zero
    // 这几个出参指针都是 MediaToolbox 给的，只在这次调用里有效（契约 ④b）。
    let status = unsafe MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, &timeRange, numberFramesOut)
    guard status == noErr else { return }
    let unmanaged = unsafe Unmanaged<TapShared>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
    // `_withUnsafeGuaranteedRef` 而不是 `takeUnretainedValue()`：前者不产生 retain/release，
    // 后者会在实时线程上碰引用计数，违反契约 ①（见文件头）。
    unsafe unmanaged._withUnsafeGuaranteedRef { shared in
        guard let dsp = unsafe shared.dsp else { return }
        let frames = Int(unsafe numberFramesOut.pointee)
        guard frames > 0 else { return }
        let buffers = unsafe UnsafeMutableAudioBufferListPointer(bufferListInOut)
        // 非 float32（罕见：某些直通格式）一律直通，不做任何加工。
        // 这三行就是契约 ④b 那道闸：过不去就不碰缓冲区。
        guard buffers.count > 0, unsafe buffers[0].mData != nil else { return }
        let bytesPerFrame = unsafe Int(buffers[0].mDataByteSize) / max(frames, 1)
        guard unsafe bytesPerFrame == MemoryLayout<Float>.size * Int(buffers[0].mNumberChannels) else { return }

        // 四段加工都吃裸指针，都是契约 ①的 `@unsafe` 函数，所以调用点显式写出来。
        unsafe tapMeasure(shared: shared, dsp: dsp, buffers: buffers, frames: frames)
        unsafe tapEnhance(shared: shared, dsp: dsp, buffers: buffers, frames: frames)
        unsafe tapGain(shared: shared, dsp: dsp, buffers: buffers, frames: frames)
        unsafe tapFadeOut(shared: shared, dsp: dsp, buffers: buffers, frames: frames,
                          startSeconds: timeRange.start.seconds)
    }
}

// MARK: - 实时线程的三段加工

/// DF2T 二阶节，就地滤波。手写循环：系数随时会换，`vDSP_biquad` 的 Setup 只能重建，
/// 重建就意味着在实时线程附近分配内存。
///
/// 契约 ④a：`x` 至少 `n` 个 float，`state` 至少 2 个——两者都由调用方在
/// `frames <= maxFrames` / `c < channels` 的闸后传进来，这里不再复查（实时线程上省一次分支）。
@unsafe
@inline(__always)
private func biquadInPlace(_ x: UnsafeMutablePointer<Float>, _ n: Int,
                           _ c: Biquad.Coefficients,
                           _ state: UnsafeMutablePointer<Float>) {
    var s1 = unsafe state[0], s2 = unsafe state[1]
    let b0 = c.b0, b1 = c.b1, b2 = c.b2, a1 = c.a1, a2 = c.a2
    for i in 0..<n {
        let input = unsafe x[i]
        let y = b0 * input + s1
        s1 = b1 * input - a1 * y + s2
        s2 = b2 * input - a2 * y
        unsafe x[i] = y
    }
    // 静音之后状态会滑进非规格化数，一个非规格化乘法能吃掉几十倍的时间，直接抹平。
    unsafe state[0] = abs(s1) < 1e-25 ? 0 : s1
    unsafe state[1] = abs(s2) < 1e-25 ? 0 : s2
}

/// ① 测量。走在增强器与增益之前，量的是**原始信号**，
/// 加上 tap 建在 `PreEffects`，交叉淡入淡出的斜坡也进不来。
@unsafe
private func tapMeasure(shared: TapShared, dsp: UnsafeMutablePointer<TapDSP>,
                        buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
    guard shared.measure.load(ordering: .relaxed) else { return }
    // 这三块是契约 ④a 的 calloc，取出来的仍是裸指针，所以这一条 guard 要写 unsafe。
    guard let scratch = unsafe dsp.rt.scratch,
          let kState = unsafe dsp.rt.kState,
          let weights = unsafe dsp.rt.channelWeight else { return }
    let channels = min(dsp.rt.channels, buffers.count)
    let fs = dsp.rt.sampleRate
    guard channels > 0, fs > 0 else { return }
    let subLen = Int((LoudnessMeter.subBlockSeconds * fs).rounded())
    // `frames <= maxFrames` 就是 scratch 那道闸；`channels` 已经对 buffers.count 取过 min。
    guard subLen > 0, frames <= dsp.rt.maxFrames else { return }

    var peak: Float = 0
    for c in 0..<channels {
        guard let data = unsafe buffers[c].mData else { continue }
        var m: Float = 0
        unsafe vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &m, vDSP_Length(frames))
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
        let n = min(subLen - dsp.rt.blockFrames, frames - offset)
        guard n > 0 else { break }
        var energy: Double = 0
        for c in 0..<channels {
            let w = unsafe weights[c]
            guard w > 0, let data = unsafe buffers[c].mData else { continue }
            // `offset + n <= frames <= maxFrames`，所以 scratch 与源都读得下（契约 ④a）。
            // `kState + c * 4` 落在 `channels * 4` 之内，因为 c < channels。
            unsafe scratch.update(from: data.assumingMemoryBound(to: Float.self) + offset, count: n)
            unsafe biquadInPlace(scratch, n, dsp.rt.kHighShelf, kState + c * 4)
            unsafe biquadInPlace(scratch, n, dsp.rt.kHighPass, kState + c * 4 + 2)
            var sum: Float = 0
            unsafe vDSP_svesq(scratch, 1, &sum, vDSP_Length(n))
            energy += Double(w) * Double(sum)
        }
        dsp.rt.blockEnergy += energy
        dsp.rt.blockFrames += n
        if dsp.rt.blockFrames >= subLen {
            let index = Int(shared.blockCount.load(ordering: .relaxed))
            if index < TapShared.blockCapacity {
                unsafe shared.blocks[index] = Float(dsp.rt.blockEnergy / Double(subLen))
                shared.blockCount.store(Int32(index + 1), ordering: .releasing)
            }
            dsp.rt.blockEnergy = 0
            dsp.rt.blockFrames = 0
        }
        offset += n
    }
}

/// ② 声音增强器：前级衰减 → 每声道低架 / 临场感 / 高架三节 DF2T → 立体声展宽 → 软限幅。
///
/// 系数在这里算而不是主线程算好送进来：架高量取决于**这一路流的采样率**，
/// 而采样率要到 tap 的 `prepare` 才知道。主线程送的是几条曲线的 dB 值（seqlock 保护），
/// 折算成系数只有几次 sin/cos/pow——叶子数学函数，不分配也不加锁，符合实时线程规则。
@unsafe
private func tapEnhance(shared: TapShared, dsp: UnsafeMutablePointer<TapDSP>,
                        buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
    guard let state = unsafe dsp.rt.shelfState else { return }
    let channels = min(dsp.rt.channels, buffers.count)
    guard channels > 0 else { return }
    let level = shared.enhancerLevel.load(ordering: .relaxed)
    guard level >= 0 else {
        // 刚关掉：清一次滤波器状态，下次打开不会把几分钟前的尾巴接上。
        if dsp.rt.appliedLevel != -1 {
            // shelfState 按 `channels * 6` 分配（契约 ④a），这里清的正是那个长度。
            unsafe state.update(repeating: 0, count: channels * 6)
            dsp.rt.appliedLevel = -1
        }
        return
    }
    dsp.rt.appliedLevel = level

    let version = shared.coeffVersion.load(ordering: .acquiring)
    if version != dsp.rt.appliedVersion, version & 1 == 0 {
        let low = Double(shared.lowShelfMilliDB.load(ordering: .relaxed)) / 1000
        let high = Double(shared.highShelfMilliDB.load(ordering: .relaxed)) / 1000
        let presence = Double(shared.presenceMilliDB.load(ordering: .relaxed)) / 1000
        let pre = Double(shared.preampMilliDB.load(ordering: .relaxed)) / 1000
        let side = Double(shared.sideGainMilli.load(ordering: .relaxed)) / 1000
        if shared.coeffVersion.load(ordering: .acquiring) == version {
            let fs = dsp.rt.sampleRate
            dsp.rt.lowCoeff = Biquad.lowShelf(
                frequency: SoundEnhancerCurve.lowFrequency, sampleRate: fs, gainDB: low)
            dsp.rt.presenceCoeff = Biquad.peaking(
                frequency: SoundEnhancerCurve.presenceFrequency, sampleRate: fs,
                gainDB: presence, q: SoundEnhancerCurve.presenceQ)
            dsp.rt.highCoeff = Biquad.highShelf(
                frequency: SoundEnhancerCurve.highFrequency, sampleRate: fs, gainDB: high)
            dsp.rt.preampLinear = Float(pow(10, pre / 20))
            dsp.rt.sideGain = Float(side)
            dsp.rt.appliedVersion = version
        }
    }

    var preamp = dsp.rt.preampLinear
    let low = dsp.rt.lowCoeff, high = dsp.rt.highCoeff
    let presence = dsp.rt.presenceCoeff
    let width = dsp.rt.sideGain
    // 滑杆在最左（t = 0）时几条曲线都是恒等，整段跳过——连软限幅都不挂，
    // 「开着但滑到 0」与「关着」在信号上必须一模一样。
    guard preamp != 1 || low != .identity || high != .identity
            || presence != .identity || width != 1 else { return }
    // `state + c * 6 (+2/+4)` 三节状态落在 `channels * 6` 之内，因为 c < channels（契约 ④a）。
    for c in 0..<channels {
        guard let data = unsafe buffers[c].mData else { continue }
        let x = unsafe data.assumingMemoryBound(to: Float.self)
        if preamp != 1 { unsafe vDSP_vsmul(x, 1, &preamp, x, 1, vDSP_Length(frames)) }
        if low != .identity { unsafe biquadInPlace(x, frames, low, state + c * 6) }
        if presence != .identity { unsafe biquadInPlace(x, frames, presence, state + c * 6 + 2) }
        if high != .identity { unsafe biquadInPlace(x, frames, high, state + c * 6 + 4) }
    }
    unsafe tapWiden(dsp: dsp, buffers: buffers, frames: frames, width: width)

    // 末级软限幅。几节架高叠起来最坏能抬到 +8 dB 上下，前级只让掉 2 dB，
    // 满档遇上本来就顶着 0 dBFS 的母带一定会过 1.0；硬削是砂音，这里用 tanh 软化。
    for c in 0..<channels {
        guard let data = unsafe buffers[c].mData else { continue }
        let x = unsafe data.assumingMemoryBound(to: Float.self)
        for i in 0..<frames { unsafe x[i] = SoundEnhancerCurve.softClip(x[i]) }
    }
}

/// 立体声展宽（M/S）。**只对正好两声道的流做**：单声道没有侧信号，
/// 多声道要按环绕矩阵来，一律跳过。
///
/// L' = M + w·S、R' = M − w·S（M =（L+R）/2、S =（L−R）/2）展开就是一个 2×2 矩阵：
/// p =（1+w）/2、q =（1−w）/2 时 L' = pL + qR、R' = qL + pR。两次 `vDSP_vsmsma`
/// 算完，中间那份借测量用的 `scratch`（测量在这一块之前已经跑完，不冲突），
/// 不额外分配。
@unsafe
private func tapWiden(dsp: UnsafeMutablePointer<TapDSP>,
                      buffers: UnsafeMutableAudioBufferListPointer,
                      frames: Int, width: Float) {
    // 这条 guard 同时是契约 ④a/④b 的闸：两声道、frames 不超 maxFrames（scratch 的容量）、
    // 两个 mData 都在。任何一条不成立就整段不做。
    guard width != 1, dsp.rt.channels == 2, buffers.count == 2,
          frames <= dsp.rt.maxFrames,
          let scratch = unsafe dsp.rt.scratch,
          let leftData = unsafe buffers[0].mData, let rightData = unsafe buffers[1].mData else { return }
    let left = unsafe leftData.assumingMemoryBound(to: Float.self)
    let right = unsafe rightData.assumingMemoryBound(to: Float.self)
    var p = (1 + width) / 2
    var q = (1 - width) / 2
    unsafe vDSP_vsmsma(left, 1, &p, right, 1, &q, scratch, 1, vDSP_Length(frames))
    unsafe vDSP_vsmsma(left, 1, &q, right, 1, &p, right, 1, vDSP_Length(frames))
    unsafe left.update(from: scratch, count: frames)
}

/// ③ 音量平衡的固定增益。块内按线性斜坡滑过去（一阶平滑，时间常数 50 ms），
/// 开关切换或换曲时不出咔哒。
@unsafe
private func tapGain(shared: TapShared, dsp: UnsafeMutablePointer<TapDSP>,
                     buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
    let milli = shared.gainMilliDB.load(ordering: .relaxed)
    let target = milli == 0 ? Float(1) : Float(pow(10, Double(milli) / 20000))
    if dsp.rt.smoothedGain < 0 { dsp.rt.smoothedGain = target }
    let start = dsp.rt.smoothedGain
    let fs = dsp.rt.sampleRate
    let alpha = fs > 0 ? Float(1 - exp(-Double(frames) / (0.05 * fs))) : 1
    let end = start + (target - start) * alpha
    dsp.rt.smoothedGain = end
    guard start != 1 || end != 1 else { return }
    let channels = min(dsp.rt.channels, buffers.count)
    var step = (end - start) / Float(max(frames, 1))
    for c in 0..<channels {
        guard let data = unsafe buffers[c].mData else { continue }
        let x = unsafe data.assumingMemoryBound(to: Float.self)
        var s = start
        unsafe vDSP_vrampmul(x, 1, &s, &step, x, 1, vDSP_Length(frames))
    }
}

/// ④ 淡出（备选路径，`PlayerController.fadeOutViaTap` 打开时才生效）。
///
/// 主路是给 `audioMix` 补一段音量斜坡，但那要把 `audioMix` 重新赋回正在播的 item，
/// tap 会跟着走一遍 unprepare→prepare。这条路把同一条曲线搬进 tap 自己算：
/// 位置从 `timeRange.start` 来，曲线用真正的 cos（不需要像 `setVolumeRamp` 那样折线逼近）。
@unsafe
private func tapFadeOut(shared: TapShared, dsp: UnsafeMutablePointer<TapDSP>,
                        buffers: UnsafeMutableAudioBufferListPointer, frames: Int,
                        startSeconds: Double) {
    let startMs = shared.fadeOutStartMs.load(ordering: .acquiring)
    guard startMs >= 0, startSeconds.isFinite else { return }
    let fadeSeconds = Double(shared.fadeOutMs.load(ordering: .relaxed)) / 1000
    guard fadeSeconds > 0 else { return }
    let fs = dsp.rt.sampleRate
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

    let channels = min(dsp.rt.channels, buffers.count)
    var step = (tail - head) / Float(max(frames, 1))
    for c in 0..<channels {
        guard let data = unsafe buffers[c].mData else { continue }
        let x = unsafe data.assumingMemoryBound(to: Float.self)
        var s = head
        unsafe vDSP_vrampmul(x, 1, &s, &step, x, 1, vDSP_Length(frames))
    }
}
