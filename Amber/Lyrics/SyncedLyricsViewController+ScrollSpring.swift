import AppKit
import QuartzCore

/// 滚动用的弹簧积分器。
///
/// 实测确认滚动**不是**交给 `NSScrollView`：`animate(line:` 起是一个
/// 每帧闭包，读 `contentView.bounds`、只替换`origin`、保留`size`、写回（§2.2）。
/// AppKit 的 `scroll(to:)` / `animator()` 会自己接管曲线，和原版对不上，
/// 所以这里按解析解逐帧求值，由 `CADisplayLink` 推。
///
/// 解的是零初速的二阶阻尼系统 `x'' + 2ζωx' + ω²x = 0`，`x` 是**距目标的位移**：
/// ζ<1 欠阻尼（会过冲）、ζ=1 临界、ζ>1 过阻尼（不回弹）。翻行那条 (1,100,18)
/// 是 ζ=0.900，点击那条 (2,260,50) 是 ζ=1.096——差别就在过不过冲（§6.1）。
struct ScrollSpring {

    var from: CGFloat
    var to: CGFloat
    var parameters: SpringTimingParameters
    var delay: TimeInterval
    var settlingDuration: TimeInterval
    var startTime: CFTimeInterval

    init(from: CGFloat,
         to: CGFloat,
         parameters: SpringTimingParameters,
         delay: TimeInterval,
         startTime: CFTimeInterval = CACurrentMediaTime()) {
        self.from = from
        self.to = to
        self.parameters = parameters
        self.delay = delay
        self.startTime = startTime
        // 时长取 `CASpringAnimation.settlingDuration`，与 §2.4 的工厂同一套。
        self.settlingDuration = CASpringAnimation(keyPath: "position", spring: parameters)
            .settlingDuration
    }

    var endTime: CFTimeInterval { startTime + delay + settlingDuration }

    func isFinished(at now: CFTimeInterval) -> Bool { now >= endTime }

    func value(at now: CFTimeInterval) -> CGFloat {
        let t = now - startTime - delay
        if t <= 0 { return from }
        if t >= settlingDuration { return to }
        return to + (from - to) * CGFloat(Self.decay(t: t, parameters: parameters))
    }

    /// 归一化位移：t = 0 时 1，收敛到 0。
    static func decay(t: TimeInterval, parameters: SpringTimingParameters) -> Double {
        let omega = parameters.angularFrequency
        let zeta = parameters.dampingRatio
        guard omega > 0 else { return 0 }

        if zeta < 1 {                                   // 欠阻尼：有过冲
            let damped = omega * (1 - zeta * zeta).squareRoot()
            return exp(-zeta * omega * t)
                * (cos(damped * t) + (zeta * omega / damped) * sin(damped * t))
        }
        if abs(zeta - 1) < 1e-9 {                       // 临界阻尼
            return exp(-omega * t) * (1 + omega * t)
        }
        let root = omega * (zeta * zeta - 1).squareRoot()   // 过阻尼：不回弹
        let r1 = -omega * zeta + root
        let r2 = -omega * zeta - root
        return (r2 * exp(r1 * t) - r1 * exp(r2 * t)) / (r2 - r1)
    }
}

extension SyncedLyricsViewController {

    /// 小于这么多 pt 的位移直接归零，不起动画。
    ///
    /// [实测] 间奏行进出行流时算位移那一段：`delta` 取绝对值后与`1.0` 比，
    /// 小于就写 0（§8）。**这条不能省**——漏了会在小位移时抖：间奏撑开 / 收起
    /// 前后差个零点几 pt 就要弹一次，密集歌词下连着抖。
    static let scrollDeadZone: CGFloat = 1

    /// 起一次滚动。x 分量恒为 0（§2.5），所以只积分 y。
    func scroll(to origin: CGPoint, spring: SpringTimingParameters, delay: TimeInterval) {
        guard let clip = scrollView?.contentView else { return }
        // 死区只在没有弹簧在跑时判：正跑着的那条目标可能在别处，这一帧的位置
        // 只是路过，不能拿它当「已经到位」。
        if scrollSpring == nil,
           abs(origin.y - clip.bounds.origin.y) < Self.scrollDeadZone { return }
        scrollSpring = ScrollSpring(from: clip.bounds.origin.y,
                                    to: origin.y,
                                    parameters: spring,
                                    delay: delay)
    }

    /// 每帧推一格。跑完就把 origin 落到目标值并清掉。
    func advanceScrollSpring(at now: CFTimeInterval = CACurrentMediaTime()) {
        guard let spring = scrollSpring else { return }
        setScrollOrigin(CGPoint(x: 0, y: spring.value(at: now)))
        if spring.isFinished(at: now) { scrollSpring = nil }
    }

    /// 用户一碰内容就撤掉在跑的滚动——§9.9 那条「手在内容上时任何动画都是在跟他抢」。
    func cancelScrollSpring() { scrollSpring = nil }

    /// 这一次翻行该用哪条弹簧、延迟多少。
    ///
    /// [实测]（§6.1）：`needsTapHandling` 为真就地硬编码
    /// `(2, 260, 50)`、`delay = 0`，**不读`LyricsSpecs`**；否则用 specs 那条
    /// `(1, 100, 18)`，并在 §2.8 的 duration hack 命中时压掉起始延迟。
    func lineChangeSpring(for line: any LyricsLine,
                          baseOffset: TimeInterval) -> (spring: SpringTimingParameters,
                                                        delay: TimeInterval) {
        guard manager?.needsTapHandling != true else {
            return (.tapDriven, 0)
        }
        let spring = specs.lineChangeSpringTimingParameters
        let settling = CASpringAnimation(keyPath: "position", spring: spring).settlingDuration
        let lineTime = line.endTime - line.startTime
        guard DurationHack.isTriggered(lineTime: lineTime,
                                       maxEndTimeOffset: specs.maxEndTimeOffset,
                                       baseOffset: baseOffset,
                                       settlingDuration: settling) else {
            return (spring, 0)
        }
        // 命中就压 delay（弹簧本身不动）。没有这条压缩，密集歌词下动画会排队积压，
        // 观感是「歌词越唱越慢、越拖越后」。
        let delay = DurationHack.delay(lineTime: lineTime,
                                       maxEndTimeOffset: specs.maxEndTimeOffset,
                                       baseOffset: baseOffset)
        return (spring, max(0, delay))
    }
}
