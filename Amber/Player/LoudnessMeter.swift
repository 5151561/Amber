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
        private var scratch: [Float] = []
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

        /// `channelsData[c]` 是第 c 个声道这一段的样本（非交错）。
        mutating func append(_ channelsData: [[Float]]) {
            guard let length = channelsData.first?.count, length > 0 else { return }
            framesSeen += length
            for samples in channelsData {
                for value in samples where abs(value) > peak { peak = abs(value) }
            }
            var offset = 0
            while offset < length {
                let n = min(subLength - frames, length - offset)
                guard n > 0 else { break }
                for (c, samples) in channelsData.enumerated() where weights[min(c, weights.count - 1)] > 0 {
                    scratch = Array(samples[offset..<(offset + n)])
                    Biquad.process(kHighShelf, &scratch, state: &shelfState[c])
                    Biquad.process(kHighPass, &scratch, state: &passState[c])
                    let sum = scratch.reduce(Double(0)) { $0 + Double($1) * Double($1) }
                    energy += Double(weights[min(c, weights.count - 1)]) * sum
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
