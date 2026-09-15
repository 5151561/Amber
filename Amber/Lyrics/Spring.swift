import QuartzCore

/// `LyricsSpecs` 里两种弹簧参数结构。原版分了两个类型：
/// `SpringTimingParameters`（翻行用，3 个 Double，24 字节）与
/// `SpringAnimationParameters`（翻译/音译显隐用，48 字节，多带初速与可选时长）。
struct SpringTimingParameters: Sendable, Equatable {
    var mass: Double
    var stiffness: Double
    var damping: Double
    init(mass: Double, stiffness: Double, damping: Double) {
        self.mass = mass; self.stiffness = stiffness; self.damping = damping
    }

    /// 无阻尼角频率 ω₀ = √(k/m)
    var angularFrequency: Double { (stiffness / mass).squareRoot() }
    /// 阻尼比 ζ = c / (2√(km))
    var dampingRatio: Double { damping / (2 * (stiffness * mass).squareRoot()) }

    /// 这条弹簧跑完要多久。
    ///
    /// 与原版同一条路：造一个 `CASpringAnimation` 把`settlingDuration` 读回来
    /// （§2.4 的工厂、`deselecting all`、`ScrollSpring.init` 三处都这么取）。
    /// `ScrollSpring` 的收尾判据用的就是它——**滚动动画的时长按定义就是这个数**，
    /// 不是另估一个「看起来停了」的时刻。
    ///
    /// 每次都现造一个 `CASpringAnimation`，别放进每帧路径；要按帧读就先存下来
    /// （`SyncedLyricsManager.Configuration.scrollLead` 就是存好的那一份）。
    var settlingDuration: TimeInterval {
        CASpringAnimation(keyPath: "position", spring: self).settlingDuration
    }

    /// 把整条曲线在时间轴上压一压，使它跑完只要 `duration`。
    ///
    /// **只动 ω₀，不动 ζ**：`stiffness /= k²`、`damping /= k`（k = duration / 现有时长），
    /// 因为 ω₀ = √(k_s/m) 变成 ω₀/k 而 ζ = c/(2√(k_s·m)) 原样不变。于是过冲多少、
    /// 回不回弹这些「性格」一点不改，只是整条曲线快了——而`settlingDuration`
    /// 与 ω₀ 成反比，正好落在 `duration` 上（实测误差 0）。
    ///
    /// 用在翻行上：句间空档比一整条弹簧还窄时，把这一次的滚动压进空档里，
    /// 而不是换一条手调的弹簧。
    ///
    /// - Parameter current: 当前的 `settlingDuration`。调用方多半已经算过，
    ///   传进来省一次 `CASpringAnimation` 构造。
    func timeScaled(to duration: TimeInterval, from current: TimeInterval) -> SpringTimingParameters {
        guard duration > 0, current > 0 else { return self }
        let k = duration / current
        return SpringTimingParameters(mass: mass,
                                      stiffness: stiffness / (k * k),
                                      damping: damping / k)
    }
}

/// 48 字节，`LyricsAnimationCurve.spring` 的载荷。字段顺序由三个独立构造点
/// 逐槽对齐读出，三处写法完全一致：
///
/// | 字段 |
/// | --- |
/// | `mass` / `stiffness` / `damping` |
/// | `duration: TimeInterval?`（值 + tag 两槽，三处都写 nil） |
/// | `settlingDuration` |
///
/// - Important: 早先把最后那一槽记成 `initialVelocity` 是错的。三个构造点都在
///   那里写刚造好的 `CASpringAnimation` 读回来的`settlingDuration`；而
///   `duration` 是个`Optional`（值槽 + tag 槽），48 字节里再排不下第四个非可选 Double。
struct SpringAnimationParameters: Sendable, Equatable {
    var mass: Double
    var stiffness: Double
    var damping: Double
    var duration: TimeInterval?
    var settlingDuration: TimeInterval
    init(mass: Double, stiffness: Double, damping: Double,
                duration: TimeInterval? = nil, settlingDuration: TimeInterval = 0) {
        self.mass = mass; self.stiffness = stiffness; self.damping = damping
        self.duration = duration; self.settlingDuration = settlingDuration
    }
}

extension CASpringAnimation {
    /// 原版统一走这条：造 `CASpringAnimation`、设 mass/stiffness/damping，
    /// 然后**读 `settlingDuration` 当动画时长**（见`deselecting all`）。
    convenience init(keyPath: String, spring: SpringTimingParameters) {
        self.init(keyPath: keyPath)
        mass = spring.mass
        stiffness = spring.stiffness
        damping = spring.damping
        duration = settlingDuration
    }
}

extension CASpringAnimation {
    /// 翻译/音译显隐那条弹簧的 48 字节版（`LyricsSpecs`
    /// `showTranslationTransliterationSpringParameters`）。`duration` 有值就用它，
    /// 否则同样取 `settlingDuration`。
    convenience init(keyPath: String, spring: SpringAnimationParameters) {
        self.init(keyPath: keyPath)
        mass = spring.mass
        stiffness = spring.stiffness
        damping = spring.damping
        duration = spring.duration ?? settlingDuration
    }
}

extension SpringTimingParameters {

    /// 点击驱动的滚动专用弹簧。
    ///
    /// [实测]：`needsTapHandling` 为真时
    /// 就地硬编码，**不读 `LyricsSpecs`**：
    /// `setMass: 2.0` / `setStiffness: 260.0` / `setDamping: 50.0`，`delay = 0`。
    ///
    /// 关键不在更快，而在 **ζ 从 0.9 推过 1**：
    /// 正常翻行 (1, 100, 18) 是 ω₀=10.00、ζ=0.900，欠阻尼、有过冲；
    /// 这条是 ω₀=11.40、ζ=1.096，过阻尼、直接落位不回弹——用户点了一行，
    /// 要的就是干脆落位，不要弹一下。
    ///
    /// - Important: 更早的记录（§2.8）把它当成「剩余时间不够时的降级弹簧」，
    ///   那是错的。触发条件与剩余时间无关，见 §6.1。真正的 duration hack
    ///   是压 `delay`，见`DurationHack`。
    static let tapDriven = SpringTimingParameters(
        mass: 2, stiffness: 260, damping: 50)
}

/// duration hack 本体：时长不够时压掉动画的起始延迟。
///
/// [实测]。**只在非点击驱动（自动翻行）时做**——
/// `tbz w24, #0` 把点击那一支整个跳过了。
enum DurationHack {

    /// 判据。
    ///
    /// [实测]：
    /// `(行时间量 − specs.maxEndTimeOffset) < baseOffset + settlingDuration`。
    /// 减数 `maxEndTimeOffset` 是实测（manager = specs = 0.5）；
    /// 被减数走协议取，是 `endTime` 还是「剩余时长」待证。`[推]`
    ///
    /// 快歌、短句、密集逐行会命中。
    static func isTriggered(lineTime: TimeInterval,
                                   maxEndTimeOffset: TimeInterval,
                                   baseOffset: TimeInterval,
                                   settlingDuration: TimeInterval) -> Bool {
        (lineTime - maxEndTimeOffset) < baseOffset + settlingDuration
    }

    /// 命中之后把 `delay` 换成这个值（弹簧本身不动）。
    ///
    /// [实测]：`delay = (行时间量 − maxEndTimeOffset) − baseOffset`。
    /// 同时把曲线 kind 归零。
    ///
    /// 没有这条压缩，密集歌词下动画会排队积压，观感是「歌词越唱越慢、越拖越后」。
    static func delay(lineTime: TimeInterval,
                             maxEndTimeOffset: TimeInterval,
                             baseOffset: TimeInterval) -> TimeInterval {
        (lineTime - maxEndTimeOffset) - baseOffset
    }
}
