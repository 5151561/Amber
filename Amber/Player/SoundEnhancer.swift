import Foundation

/// 二阶节（biquad）。系数按 `a0` 归一化后直接给实时线程用，滤波是手写的 DF2T 循环——
/// 不用 `vDSP_biquad_CreateSetup`，是为了省掉 Setup 对象的生命周期：档位一变就要换系数，
/// 而 Setup 只能重建，重建就意味着在实时线程附近分配内存。
enum Biquad {

    /// 已按 a0 归一化：`y = b0·x + b1·x₁ + b2·x₂ − a1·y₁ − a2·y₂`
    struct Coefficients: Equatable {
        var b0: Float = 1
        var b1: Float = 0
        var b2: Float = 0
        var a1: Float = 0
        var a2: Float = 0

        static let identity = Coefficients()
    }

    /// RBJ Audio EQ Cookbook 的低架滤波器（S = 1）。
    static func lowShelf(frequency: Double, sampleRate: Double, gainDB: Double) -> Coefficients {
        shelf(frequency: frequency, sampleRate: sampleRate, gainDB: gainDB, low: true)
    }

    /// RBJ Audio EQ Cookbook 的高架滤波器（S = 1）。
    static func highShelf(frequency: Double, sampleRate: Double, gainDB: Double) -> Coefficients {
        shelf(frequency: frequency, sampleRate: sampleRate, gainDB: gainDB, low: false)
    }

    /// RBJ Audio EQ Cookbook 的峰值（parametric）滤波器：以 `frequency` 为中心
    /// 抬高 / 压低 `gainDB`，带宽由 `q` 定（Q 越大越窄）。两端回到 0 dB。
    static func peaking(frequency: Double, sampleRate: Double,
                        gainDB: Double, q: Double) -> Coefficients {
        guard sampleRate > 0, frequency > 0, frequency < sampleRate / 2, q > 0 else {
            return .identity
        }
        guard gainDB != 0 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let b0 = 1 + alpha * a
        let b1 = -2 * cosW
        let b2 = 1 - alpha * a
        let a0 = 1 + alpha / a
        let a1 = -2 * cosW
        let a2 = 1 - alpha / a
        return Coefficients(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
                            a1: Float(a1 / a0), a2: Float(a2 / a0))
    }

    private static func shelf(frequency: Double, sampleRate: Double,
                              gainDB: Double, low: Bool) -> Coefficients {
        guard sampleRate > 0, frequency > 0, frequency < sampleRate / 2 else { return .identity }
        guard gainDB != 0 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w0)
        // S = 1 时 α = sin(w0)/2 · √((A + 1/A)(1/S − 1) + 2) = sin(w0)/2 · √2
        let alpha = sin(w0) / 2 * 2.0.squareRoot()
        let twoSqrtAAlpha = 2 * a.squareRoot() * alpha
        let b0, b1, b2, a0, a1, a2: Double
        if low {
            b0 = a * ((a + 1) - (a - 1) * cosW + twoSqrtAAlpha)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
            b2 = a * ((a + 1) - (a - 1) * cosW - twoSqrtAAlpha)
            a0 = (a + 1) + (a - 1) * cosW + twoSqrtAAlpha
            a1 = -2 * ((a - 1) + (a + 1) * cosW)
            a2 = (a + 1) + (a - 1) * cosW - twoSqrtAAlpha
        } else {
            b0 = a * ((a + 1) + (a - 1) * cosW + twoSqrtAAlpha)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
            b2 = a * ((a + 1) + (a - 1) * cosW - twoSqrtAAlpha)
            a0 = (a + 1) - (a - 1) * cosW + twoSqrtAAlpha
            a1 = 2 * ((a - 1) - (a + 1) * cosW)
            a2 = (a + 1) - (a - 1) * cosW - twoSqrtAAlpha
        }
        return Coefficients(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
                            a1: Float(a1 / a0), a2: Float(a2 / a0))
    }

    /// 非实时侧的就地滤波（离线响度扫描、测试用）。实时线程走 `AudioTap` 里那份
    /// 不带边界检查的手写循环，两边是同一套 DF2T 递推。
    static func process(_ c: Coefficients, _ samples: inout [Float],
                        state: inout (Float, Float)) {
        var s1 = state.0, s2 = state.1
        for i in samples.indices {
            let x = samples[i]
            let y = c.b0 * x + s1
            s1 = c.b1 * x - c.a1 * y + s2
            s2 = c.b2 * x - c.a2 * y
            samples[i] = y
        }
        state = (abs(s1) < 1e-25 ? 0 : s1, abs(s2) < 1e-25 ? 0 : s2)
    }

    /// 频响幅度，dB。测试用它验直流 / 奈奎斯特两端的架高量。
    static func magnitudeDB(_ c: Coefficients, frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(w), sin1 = sin(w)
        let cos2 = cos(2 * w), sin2 = sin(2 * w)
        let numRe = Double(c.b0) + Double(c.b1) * cos1 + Double(c.b2) * cos2
        let numIm = -(Double(c.b1) * sin1 + Double(c.b2) * sin2)
        let denRe = 1 + Double(c.a1) * cos1 + Double(c.a2) * cos2
        let denIm = -(Double(c.a1) * sin1 + Double(c.a2) * sin2)
        let num = (numRe * numRe + numIm * numIm).squareRoot()
        let den = (denRe * denRe + denIm * denIm).squareRoot()
        guard den > 0 else { return 0 }
        return 20 * log10(num / den)
    }
}

/// 声音增强器滑杆（0–255）到各条曲线的映射。
///
/// Music 的「声音增强器」推到高档时是**明显**能听出来的：更亮、更宽、更有推力，
/// 不是「仔细听才有一点点」。从前那条曲线（低架 +3 dB @120 Hz、高架 +6 dB @6 kHz、
/// 前级 −3 dB）太保守：高架的转折放在 6 kHz 已经只剩齿音，而 −3 dB 前级又把
/// 抬起来的那点响度原样扣了回去，两条一抵消就成了「效果不明显」。
///
/// 现在这一套（全部 [推]，`t = level/255` 线性插值，单调）：
/// - 低架 +6·t dB @100 Hz：低音的体量，转折压到 100 Hz 避开人声的胸声区。
/// - 峰值 +2.5·t dB @2.5 kHz，Q ≈ 1：临场感（人声与吉他的「出来」那一段）。
/// - 高架 +7.5·t dB @4 kHz：4 kHz 而不是 6 kHz——大众听感里的「增强了」
///   落在 presence/air 这一段，6 kHz 以上基本只剩齿音和镲片。
/// - 立体声展宽：侧信号 ×(1 + 0.7·t)（只对正好两声道的流做，见 `AudioTap` 的 M/S）。
/// - 前级只 −2·t dB，末级挂一个软限幅（`softClip`）接住叠加后的峰值。
///   前级从 −3 收到 −2，是因为「响一点」本身就是听感上「增强了」的一半；
///   削顶交给软限幅去处理，比整体压低 3 dB 划算。
///
/// 滑杆本身在 AX 里就是 0–255 的线性量程，没有非线性的证据，所以中间一律线性插值。
enum SoundEnhancerCurve {

    struct Gains: Equatable {
        var lowDB: Double
        var highDB: Double
        /// 中频临场感峰值（`presenceFrequency` / `presenceQ`）。
        var presenceDB: Double
        var preampDB: Double
        /// 侧信号 S =（L−R）/2 的倍数。1 = 原样，>1 = 展宽。
        var sideGain: Double

        static let flat = Gains(lowDB: 0, highDB: 0, presenceDB: 0, preampDB: 0, sideGain: 1)
    }

    /// 低架 / 高架的转折频率与临场感峰值的中心频率。[推]
    static let lowFrequency: Double = 100
    static let highFrequency: Double = 4000
    static let presenceFrequency: Double = 2500
    /// Q ≈ 1：大约一个八度的带宽，窄到不会把整段中频顶起来，宽到能听出「出来了」。[推]
    static let presenceQ: Double = 1

    static let maxLowDB: Double = 6
    static let maxHighDB: Double = 7.5
    static let maxPresenceDB: Double = 2.5
    static let maxPreampDB: Double = -2
    /// 满档时侧信号额外的倍数（`sideGain = 1 + maxSideBoost·t`）。[推]
    static let maxSideBoost: Double = 0.7

    /// 软限幅的直线段上限与拐点上方的软化幅度。0.8 以下原样通过（绝大多数样本都在这儿，
    /// 一点非线性都不引入），0.8 以上用 tanh 压进 [0.8, 1.0]。[推]
    static let softClipThreshold: Double = 0.8
    static let softClipKnee: Double = 0.2

    /// `level` 为负表示开关关着，返回全 0（实时线程看到全 0 就整段跳过滤波）。
    static func gains(level: Int32) -> Gains {
        guard level >= 0 else { return .flat }
        let t = min(Double(level), 255) / 255
        return Gains(lowDB: maxLowDB * t, highDB: maxHighDB * t,
                     presenceDB: maxPresenceDB * t, preampDB: maxPreampDB * t,
                     sideGain: 1 + maxSideBoost * t)
    }

    /// 末级软限幅。0.8 以下是恒等映射，之上按 `sign(x)·(0.8 + 0.2·tanh((|x|−0.8)/0.2))`
    /// 压过去：单调、连续、上限正好 1.0，硬削那种砂音不会出现。
    ///
    /// **实时线程**会逐样本调它：`@inline(__always)` + `tanhf`（libm 叶子函数），
    /// 不分配、不加锁、不碰 ObjC。
    @inline(__always)
    static func softClip(_ x: Float) -> Float {
        let threshold = Float(softClipThreshold)
        let knee = Float(softClipKnee)
        let magnitude = abs(x)
        guard magnitude > threshold else { return x }
        let folded = threshold + knee * tanhf((magnitude - threshold) / knee)
        return x < 0 ? -folded : folded
    }
}
