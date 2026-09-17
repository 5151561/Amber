import Foundation

/// ITU-R BS.1770 的响度测量：K 加权 → 100 ms 子块能量 → 400 ms 滑窗块 → 两级门限 → 积分响度。
///
/// 纯计算，没有任何 AVFoundation 依赖：实时 tap（边播边量）与离线扫描（下载完成后量）
/// 共用同一套系数与同一套门限，两条路才不会各量出一个数。
///
/// 分工：**K 加权与子块能量在实时线程做**（`AudioTap` 里的 `tapMeasure`，
/// 只做累加不做判断），**门限与积分在主线程做**（`integrated(subBlockEnergies:)`）。
enum LoudnessMeter {

    /// 子块长度：100 ms。BS.1770 的 400 ms 块之间 75% 重叠，等价于「4 个连续 100 ms 子块
    /// 合成一个块、每次滑一个子块」，所以底层只需要按 100 ms 存能量。
    static let subBlockSeconds: Double = 0.1
    static let subBlocksPerBlock = 4

    /// 块响度的常数项（BS.1770-4 §2.2）
    static let offset: Double = -0.691
    /// 绝对门限
    static let absoluteGate: Double = -70
    /// 相对门限：过了绝对门限那些块的平均响度再减 10 LU
    static let relativeGate: Double = -10

    // MARK: - K 加权（BS.1770 的两节预滤波，按采样率做双线性变换）

    /// 第一节：头部效应的高架（≈ +4 dB @ 1.68 kHz 以上）
    static func kWeightingHighShelf(sampleRate: Double) -> Biquad.Coefficients {
        guard sampleRate > 0 else { return .identity }
        let f0 = 1681.974450955533
        let g = 3.999843853973347
        let q = 0.7071752369554196
        let k = tan(Double.pi * f0 / sampleRate)
        let vh = pow(10, g / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return Biquad.Coefficients(
            b0: Float((vh + vb * k / q + k * k) / a0),
            b1: Float(2 * (k * k - vh) / a0),
            b2: Float((vh - vb * k / q + k * k) / a0),
            a1: Float(2 * (k * k - 1) / a0),
            a2: Float((1 - k / q + k * k) / a0))
    }

    /// 第二节：RLB 高通（≈ 38 Hz）
    static func kWeightingHighPass(sampleRate: Double) -> Biquad.Coefficients {
        guard sampleRate > 0 else { return .identity }
        let f0 = 38.13547087602444
        let q = 0.5003270373238773
        let k = tan(Double.pi * f0 / sampleRate)
        let a0 = 1 + k / q + k * k
        return Biquad.Coefficients(
            b0: 1, b1: -2, b2: 1,
            a1: Float(2 * (k * k - 1) / a0),
            a2: Float((1 - k / q + k * k) / a0))
    }

    /// 声道权重：L/R/C = 1，Ls/Rs = 1.41（+1.5 dB），LFE = 0（不计）。
    /// 声道序按 CoreAudio 的规范布局：0=L 1=R 2=C 3=LFE 4=Ls 5=Rs，6 以后一律按环绕算。
    static func channelWeight(index: Int, channels: Int) -> Float {
        guard channels > 2 else { return 1 }
        switch index {
        case 0, 1, 2: return 1
        case 3: return 0
        default: return 1.41
        }
    }

    // MARK: - 门限与积分

    /// 从 100 ms 子块能量算整首的积分响度（LUFS）。子块不足一个 400 ms 块时返回 nil。
    ///
    /// `subBlockEnergies[i]` = 该子块里 `Σ_c w_c · meanSquare_c`（K 加权后）。
    static func integrated(subBlockEnergies: [Float]) -> Double? {
        guard subBlockEnergies.count >= subBlocksPerBlock else { return nil }
        // 400 ms 块 = 连续 4 个子块的能量均值（等长子块，均值的均值就是总均值）
        var blocks: [Double] = []
        blocks.reserveCapacity(subBlockEnergies.count - subBlocksPerBlock + 1)
        var window: Double = 0
        for i in 0..<subBlockEnergies.count {
            window += Double(subBlockEnergies[i])
            if i >= subBlocksPerBlock { window -= Double(subBlockEnergies[i - subBlocksPerBlock]) }
            if i >= subBlocksPerBlock - 1 { blocks.append(window / Double(subBlocksPerBlock)) }
        }
        guard !blocks.isEmpty else { return nil }

        func loudness(_ z: Double) -> Double { z > 0 ? offset + 10 * log10(z) : -.infinity }

        let aboveAbsolute = blocks.filter { loudness($0) > absoluteGate }
        guard !aboveAbsolute.isEmpty else { return nil }
        let meanAbove = aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)
        let threshold = loudness(meanAbove) + relativeGate
        let kept = aboveAbsolute.filter { loudness($0) > threshold }
        guard !kept.isEmpty else { return nil }
        let mean = kept.reduce(0, +) / Double(kept.count)
        let result = loudness(mean)
        return result.isFinite ? result : nil
    }

    // MARK: - 非实时侧的累加器

    /// 离线扫描（已下载文件）与单元测试用的累加器。与实时 tap 走同一套系数、
    /// 同一种分块，只是不受实时线程的约束（可以用数组、可以增长）。
    struct Accumulator {
        private let kHighShelf: Biquad.Coefficients
        private let kHighPass: Biquad.Coefficients
        private let weights: [Float]
        private let subLength: Int
        private var shelfState: [(Float, Float)]
        private var passState: [(Float, Float)]
        private var energy: Double = 0
        private var frames = 0
        private(set) var subBlocks: [Float] = []
        private(set) var peak: Float = 0
        private(set) var framesSeen: Int = 0

        init(sampleRate: Double, channels: Int) {
            kHighShelf = LoudnessMeter.kWeightingHighShelf(sampleRate: sampleRate)
            kHighPass = LoudnessMeter.kWeightingHighPass(sampleRate: sampleRate)
            weights = (0..<max(channels, 1)).map {
                LoudnessMeter.channelWeight(index: $0, channels: channels)
            }
            subLength = max(1, Int((LoudnessMeter.subBlockSeconds * sampleRate).rounded()))
            shelfState = Array(repeating: (0, 0), count: max(channels, 1))
            passState = shelfState
        }

        /// `channels[c]` 指向第 c 个声道这一段的 `length` 个样本（非交错）。
        ///
        /// 接口收成指针，是因为上游（`AVAudioPCMBuffer.floatChannelData`、实时 tap）
        /// 手里本来就是裸缓冲：从前的 `[[Float]]` 逼着调用方每读一段就为每个声道造一份
        /// 新数组，一首 4 分钟的立体声要多出一万多次分配。
        ///
        /// **热循环里把三件事融成一趟**：K 加权两节 + 峰值 + 平方和。不再落中间缓冲，
        /// 也不再调 `Biquad.process`——它的接口是 `inout [Float]`，除了逼出那次拷贝，
        /// 在 Debug（`-Onone`，数组下标与 `IndexingIterator` 都没特化）下还要为每个样本
        /// 走一遍泛型元数据实例化与边界检查：实测 60 s 立体声一趟 3177 万次 malloc，
        /// 一整个核 1.6 s，真正做 DSP 的时间反倒是零头。
        ///
        /// 递推式逐行照抄 `Biquad.process`（含收尾那次非规格化数抹平），分段边界也保持
        /// 原样（按 100 ms 子块切），所以结果与改之前**逐位相同**——这一条由
        /// `LoudnessMeterTests` 里钉死的常量把关。`AudioTap.biquadInPlace` 是同一条式子的
        /// 第三份拷贝，理由同类：接口形状各不相同，算式必须一样。
        ///
        /// 也没有换 `vDSP`：`vDSP_svesq` 的平方和是 `Float` 累加，这里是 `Double` 累加
        /// （实时 tap 与离线扫描本来就差这一点点），换过去数值会动，那是改语义不是优化。
        ///
        /// **这一族 `unsafe` 的契约**（下面逐处不再重复）：签名里的
        /// `UnsafeBufferPointer<UnsafePointer<Float>>` 是**借来的**声道指针表——
        /// 不安全在于调用方必须保证 `channels[c]` 各自至少有 `length` 个样本可读、
        /// 且在本次调用返回前不被释放或改写。本函数只读不写、一个指针也不留存
        /// （出去的全是 `Float`/`Double` 标量），所以越界与悬垂只可能来自调用方。
        /// 两个调用方都是现取现用：`LoudnessStore` 在 `withUnsafeBufferPointer` 里调、
        /// 下面那个数组版在自己刚分配又 `defer` 释放的缓冲上调，都出不了作用域。
        /// `base[c] + offset` 与 `samples[i]` 的越界由上面 `n = min(subLength - frames,
        /// length - offset)` 与 `offset < length` 两条夹住，`i < n` 恒有 `offset + i < length`。
        mutating func append(_ channels: UnsafeBufferPointer<UnsafePointer<Float>>,
                             frames length: Int) {
            guard length > 0, let base = channels.baseAddress, !channels.isEmpty else { return }
            framesSeen += length
            let shelf = kHighShelf
            let pass = kHighPass
            var offset = 0
            while offset < length {
                let n = min(subLength - frames, length - offset)
                guard n > 0 else { break }
                for c in 0..<channels.count {
                    let samples = unsafe base[c] + offset
                    let weight = weights[min(c, weights.count - 1)]
                    // 权重 0 的声道（LFE）不进能量，但峰值照算——峰值是采样峰值，
                    // 不是加权响度，从前那版也是所有声道一起看。
                    guard weight > 0, c < shelfState.count else {
                        var channelPeak = peak
                        var i = 0
                        while i < n {
                            let magnitude = abs(unsafe samples[i])
                            if magnitude > channelPeak { channelPeak = magnitude }
                            i += 1
                        }
                        peak = channelPeak
                        continue
                    }
                    var s1 = shelfState[c].0, s2 = shelfState[c].1
                    var t1 = passState[c].0, t2 = passState[c].1
                    var sum: Double = 0
                    var channelPeak = peak
                    // 手写 `while` 而不是 `for i in 0..<n`：Debug（`-Onone`）下
                    // `Range` 的迭代器没有特化，每转一圈要走一次 `IndexingIterator.next()`
                    // 加一次泛型元数据实例化——实测每圈一次 malloc、76 ns，而循环体本身只有
                    // 几 ns。`while` 版每圈 4 ns、零分配（同一台机器上 20 倍差距）。
                    // Release 下两种写法一样快，这条纯粹是为了 Debug 别把一个核焊死。
                    var i = 0
                    while i < n {
                        let x = unsafe samples[i]
                        let magnitude = abs(x)
                        if magnitude > channelPeak { channelPeak = magnitude }
                        let y = shelf.b0 * x + s1
                        s1 = shelf.b1 * x - shelf.a1 * y + s2
                        s2 = shelf.b2 * x - shelf.a2 * y
                        let z = pass.b0 * y + t1
                        t1 = pass.b1 * y - pass.a1 * z + t2
                        t2 = pass.b2 * y - pass.a2 * z
                        sum += Double(z) * Double(z)
                        i += 1
                    }
                    peak = channelPeak
                    // 静音之后状态会滑进非规格化数，一个非规格化乘法能吃掉几十倍的时间。
                    // 抹平的时机与 `Biquad.process` 一致：每段收尾抹一次。
                    shelfState[c] = (abs(s1) < 1e-25 ? 0 : s1, abs(s2) < 1e-25 ? 0 : s2)
                    passState[c] = (abs(t1) < 1e-25 ? 0 : t1, abs(t2) < 1e-25 ? 0 : t2)
                    energy += Double(weight) * sum
                }
                frames += n
                if frames >= subLength {
                    subBlocks.append(Float(energy / Double(subLength)))
                    energy = 0
                    frames = 0
                }
                offset += n
            }
        }

        /// 便利入口：`channelsData[c]` 是第 c 个声道这一段的样本（非交错）。
        ///
        /// 只给测试和「手里正好是数组」的调用方用：它自己要先把各声道拷进一段连续缓冲
        /// 才能拿到稳定的指针表，**每调一次两次分配**。离线扫描那条热路径走上面那个指针版。
        ///
        /// **不安全在哪、谁保证它安全**：两块手工分配的缓冲。`flat` 是 `count * length`
        /// 个 `Float` 的连续区，`table` 是 `count` 根指进 `flat` 的指针。
        /// 安全由三件事保：容量与写入量同源（都从 `count`／`length` 这两个值算，
        /// 中途没人改）；两块都 `initialize` 满了才用，各配一条 `defer`
        /// 做 `deinitialize` + `deallocate`，函数任何出口都走到；
        /// `table` 里的指针只在本函数体内被 `append(_:frames:)` 借走一次，
        /// 那个函数不留存指针（见它的注释），所以 `defer` 释放时没有别人还握着。
        /// 每声道写入取 `min(length, source.count)`——声道长度不齐时按短的来，
        /// 不会越过 `flat` 里属于本声道的那一段。
        mutating func append(_ channelsData: [[Float]]) {
            guard let length = channelsData.first?.count, length > 0 else { return }
            let count = channelsData.count
            let flat = UnsafeMutablePointer<Float>.allocate(capacity: count * length)
            unsafe flat.initialize(repeating: 0, count: count * length)
            defer { unsafe flat.deinitialize(count: count * length); unsafe flat.deallocate() }
            for (c, samples) in channelsData.enumerated() {
                samples.withUnsafeBufferPointer { source in
                    guard let start = source.baseAddress else { return }
                    unsafe (flat + c * length).update(from: start, count: min(length, source.count))
                }
            }
            let table = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: count)
            defer { unsafe table.deinitialize(count: count); unsafe table.deallocate() }
            for c in 0..<count { unsafe (table + c).initialize(to: UnsafePointer(flat + c * length)) }
            unsafe append(UnsafeBufferPointer(start: table, count: count), frames: length)
        }

        var integratedLUFS: Double? { LoudnessMeter.integrated(subBlockEnergies: subBlocks) }
        var peakDB: Double { peak > 0 ? min(20 * log10(Double(peak)), 0) : -120 }

        var entry: LoudnessEntry? {
            guard let lufs = integratedLUFS else { return nil }
            return LoudnessEntry(lufs: lufs, peakDB: peakDB, measuredAt: Date())
        }
    }

    // MARK: - 归一化增益

    /// 目标响度。−16 LUFS 是流媒体（Apple Music / Spotify 一档）的常用目标，
    /// 也是 Amber 的音源普遍的母带响度往下调一点点就能对齐的位置：
    /// 大部分现代流行母带在 −9 ~ −6 LUFS，取 −16 意味着「统一往下拉」，
    /// 靠衰减而不是靠增益去对齐，绝大多数曲目根本用不到 +6 dB 那个上限。[推]
    static let targetLUFS: Double = -16
    /// 提升上限。安静的古典录音可以差到 −30 LUFS，全额补上去等于把底噪一起拉出来；
    /// +6 dB 是「听得出被拉齐了、又不至于把动态压平」的常规上限。[推]
    static let maxBoostDB: Double = 6
    /// 峰值余量：拉完之后至少留 1 dB，别削顶。
    static let peakHeadroomDB: Double = -1

    /// `peakDB` 是采样峰值（dBFS，≤ 0）。衰减方向不设限。
    static func gainDB(lufs: Double, peakDB: Double) -> Double {
        let wanted = targetLUFS - lufs
        guard wanted > 0 else { return wanted }
        return min(wanted, maxBoostDB, peakHeadroomDB - peakDB)
    }
}

/// 一首歌量到的响度。存进 `LoudnessStore`。
struct LoudnessEntry: Codable, Equatable, Sendable {
    /// 积分响度，LUFS
    var lufs: Double
    /// 采样峰值，dBFS（≤ 0）
    var peakDB: Double
    var measuredAt: Date

    var gainDB: Double { LoudnessMeter.gainDB(lufs: lufs, peakDB: peakDB) }
}
