import AppKit
import QuartzCore

/// 间奏的三个点。
///
/// 对应 `InstrumentalContentLayer`（objc 名`MusicInstrumentalContentLayer`）。
/// 字段名照原版取，行为见 lyrics 规格 §3.1–3.3。
final class InstrumentalContentLayer: CALayer, SyncedLyricsContentLayer {

    /// （§9.4）。`selecting line` 认间奏行靠的是把
    /// `contentLayer` 往`MusicInstrumentalContentLayer` 上转型，
    /// 转成功了才写 `instrumentalBreakVisibleView`——判的是**内容层的类**，
    /// 不是行模型的类型。
    func setSelected(_ selected: Bool, animated: Bool) {
        isSelected = selected
        guard !selected else { return }
        // 未轮到间奏时这一行在行流里完全折叠。点已经提前建好，但折叠期间必须
        // 藏掉，否则 CALayer 默认不裁子层，三个点会从 0 高度的行里漏出来。
        //
        // **不能只靠几何**：这里立刻藏 + 复位，是因为「拖时间条离开间奏」时点还
        // 亮着——自然播完那一路 `cueFadeOut` 已经把三个点的模型值写成 0，看不出
        // 问题；中途 seek 走的是「取消选中 + 重排」，淡出根本没起跑。这时候只要
        // 有一帧几何没把 `bounds.height` 判成 0（行图层带着 0.98 缩放，见
        // `SyncedLyricsLineView.layout()`），三个点就会永远留在原地。
        // 复位同时把状态机清干净，下次再选中这一段间奏才会重新从 `prepareActions`
        // 摆一次点——否则 `totalDotsFadedIn != nil` 会让它整个空转。
        isHidden = true
        masksToBounds = true
        reset()
    }


    var specs = LyricsSpecs()
    var line: (any LyricsLine)?

    /// 三点整排的水平对齐档位。
    ///
    /// 原始值就是那条三值分支（§13.6）的分支号：
    /// **1 = 居中、2 = 右，其余（含默认的 0）= 左/自然**。
    ///
    /// - Note: 原版这个字段的静态类型是 `NSTextAlignment`，但分支号走的是
    ///   **UIKit 的**原始值（left=0, center=1, right=2）。AppKit 的
    ///   `NSTextAlignment` 是 left=0、**right=1**、**center=2**、natural=4，
    ///   直接照搬类型会把左右对调、默认值也对不上。这里落成一个原始值明确的
    ///   自有枚举，分支号与与原版逐位对齐。
    enum DotAlignment: Int, Sendable {
        case natural = 0
        case center = 1
        case right = 2
    }

    /// 三点整排靠哪一边。
    ///
    /// **写入器带副作用**：[实测]（§15.5）——
    ///
    /// ```
    /// old = alignment ; alignment = new
    /// if new == old { return } ← 早退，值没变什么都不做
    /// if dots.isEmpty { makeDots() } →
    /// 按 specs 重排三个点的落点起
    /// ```
    ///
    /// **三个点就是在这里建的，不在 init 里**：init 内那次赋值是直接写字段、不走
    /// 这条（Swift 的 `didSet` 在 init 内同样不触发，语义正好对上）。把建点塞进
    /// init 会丢掉「值没变就早退」这一条——原版在 alignment 没变化时不重排点。
    var alignment: DotAlignment = .natural {
        didSet {
            guard alignment != oldValue else { return }
            if dots.isEmpty { makeDots() }
            layoutDots()
        }
    }

    /// 行自带的书写方向 → 三点靠边。左书写靠左（走「其余」那一支），右书写靠右。
    static func dotAlignment(for direction: Lyrics.Direction) -> DotAlignment {
        switch direction {
        case .leftToRight: return .natural
        case .rightToLeft: return .right
        }
    }

    /// 建点，但只在还没有点的时候。
    ///
    /// 装配路径（§15.3）是「新建 / 就地复用 → 赋一次 `alignment`」，点在赋值那一刻
    /// 出现。可我们的默认档位就是 `.natural`，行本身也多半是左书写——赋的值和旧值
    /// 相等，`didSet` 按原版语义早退，点就永远建不出来。所以装配收尾补这一手：
    /// **只补建、不重排**，早退那条语义原样保留。
    func makeDotsIfNeeded() {
        guard dots.isEmpty else { return }
        makeDots()
        layoutDots()
    }

    var isSelected = false
    var isScrolling = false
    var lastSeenBounds = CGRect.zero

    private(set) var dots: [CALayer] = []

    // MARK: 状态机的账本（字段名与原版一致）

    private(set) var fadeOutCued = false
    private(set) var dotFadeInDuration: TimeInterval = 0
    private(set) var breathDuration: TimeInterval = 0
    private(set) var totalDotsFadedIn: Int?
    private(set) var totalDotsCompleted = 0
    private(set) var totalBreathsCompleted = 0
    private(set) var currentElapsedTime: TimeInterval?

    /// 上一拍呼吸去的是哪一档。呼吸是**严格交替**的一张一收，早先按
    /// `totalBreathsCompleted` 的奇偶推算：中途 seek 进间奏时相位对不上，
    /// 下一拍的目标值可能和当前值相同，`LayerPropertyAnimator` 的
    /// 「值没变不建动画」就把它整拍跳过，看着像忽大忽小。记住上一拍直接翻面，
    /// 相位怎么进来的都不影响。初值取小的那一档，于是第一拍一定是涨大。
    private var lastBreathScale = InstrumentalContentLayer.breathScaleRange.lowerBound

    /// Core Animation 的 delegate 由 animator 承担；把正在跑的 animator 留住，
    /// 也方便 reset 时让旧一轮完成回调失效。
    private var activeAnimators: [LayerPropertyAnimator] = []
    private var animationGeneration = 0

    // MARK: 常量

    /// 尾部留给淡出的时间。行内所有推导都用 `endTime - fadeOutLeadTime` 当「有效终点」。
    ///
    /// [实测]`-1.8`，
    /// 同一个立即数。
    static let fadeOutLeadTime: TimeInterval = 1.8

    /// 头部静默：行开始到第一个点出现之间的空档。
    /// [实测] 的。
    static let firstDotDelay: TimeInterval = 1.0

    /// 一次完整呼吸的目标时长。`floor(span / 4)` 决定整个间奏塞得下几次。
    /// [实测] 的（乘 0.25 等价于除以 4）。
    static let breathCycleTarget: TimeInterval = 4.0

    /// 点淡入动画比一格短 0.1，整排呼吸动画比半周期短 0.4——留出落位的间隙。
    /// [实测]`-0.1`、`-0.4`。
    static let dotFadeInAnimationTrim: TimeInterval = 0.1
    static let breathAnimationTrim: TimeInterval = 0.4

    /// 呼吸动画的起始延迟。[实测] 传给 `0.2`。
    static let breathAnimationDelay: TimeInterval = 0.2

    /// 「已显示但还没轮到」的那些点停在几成亮度。**是 0.1，不是 0** ★★
    ///
    /// [实测] §13.10 的订正与证据链：行被选中时跑的那次刷新，对每一个点下发
    /// `(i < dueDots) ? 1.0 : 0.1`（linear 0.8，延迟`i × 0.06`）。
    /// 建点（§13.1）那句 `opacity = 0` 只是**出生值**，紧随其后的刷新会把整排
    /// 抬到 0.1 基线——所以间奏一起，三个点是**一起以 10% 亮度浮出来**的，
    /// 之后才从左往右逐个填到 100%。
    ///
    /// - Important: 别把它改成 0。那样点会从看不见的地方一个个冒出来，
    ///   整排失去存在感，一眼就和 Music 对不上。
    static let dotUnfilledOpacity: Float = 0.1

    /// 填充满的点。[实测] §13.7 closure 的，
    /// 也是 §13.2 逐点淡入的终点。
    static let dotFilledOpacity: Float = 1

    /// 点阵摆上来时的入场：线性 0.8 秒，每个点比前一个晚 0.06 秒——
    /// 错开这么点等于三个点一起浮出来，只是带一丝从左到右的扫入感。
    /// 中途 seek 进间奏（§7 追平）复用同一条路径。
    /// [实测]。
    static let initialDotAnimationDuration: TimeInterval = 0.8
    static let initialDotStagger: TimeInterval = 0.06

    /// 两侧的点在单位坐标里把锚点推开多少。见 3.1。
    /// [实测] 的 ±1.3。
    static let outerDotAnchorOffset: CGFloat = 1.3

    // MARK: 3.1 造点

    /// 建三个点。
    ///
    /// [实测]：
    /// 首个点 `anchorPoint.x += +1.3`、末个点`anchorPoint.x += -1.3`、中间的不动；
    /// `backgroundColor = specs.selectedTextColor`、`opacity = 0`、
    /// `cornerRadius = instrumentalBreakDotLength / 2`（正圆）。
    ///
    /// ±1.3 是单位坐标，折成 1.3 × 12 = 15.6pt。两侧的点绕各自内侧 15.6pt 处的一点转，
    /// 整排呼吸时向中间收、向两边张。15.6 不等于点心距 20，所以也不是绕整排中心刚性缩放。
    func makeDots() {
        dots.forEach { $0.removeFromSuperlayer() }
        dots.removeAll()
        masksToBounds = true

        let count = specs.instrumentalBreakCountdownDotCount
        guard count > 0 else { return }

        for i in 0..<count {
            let dot = CALayer()
            if i == 0 {
                dot.anchorPoint.x += Self.outerDotAnchorOffset
            } else if i == count - 1 {
                dot.anchorPoint.x -= Self.outerDotAnchorOffset
            }
            dot.backgroundColor = specs.selectedTextColor.cgColor
            dot.opacity = 0
            dot.cornerRadius = specs.instrumentalBreakDotLength / 2
            dots.append(dot)
            addSublayer(dot)
        }
    }

    /// 整排的宽度。[实测]：`n × dotLength + (n − 1) × dotMargin`。
    /// 基线是 `3 × 12 + 2 × 8 = 52`。
    var dotsWidth: CGFloat {
        let n = specs.instrumentalBreakCountdownDotCount
        guard n > 0 else { return 0 }
        return CGFloat(n) * specs.instrumentalBreakDotLength
            + CGFloat(n - 1) * specs.instrumentalBreakDotMargin
    }

    /// 外侧圆点以越过自身边界的 anchor 做呼吸缩放，两端会探出行宽之外。
    /// **不为此留内边距**：[PX] Music 50pt 档实测亮点包围盒 x 749..769.5，
    /// 而间奏行左沿是 754——首个点的静止左沿就压在行左沿（= 歌词左沿）上，
    /// 呼吸胀大时直接探出行外，不缩进也不裁。早先这里留了一圈 padding，
    /// 三个点会比歌词左沿缩进十来 pt。裁剪已在行视图与内容层两处关掉。

    // MARK: 3.2 复位：两个时长在这里现算

    /// 复位并重算两个时长。
    ///
    /// [实测]。**这是整个原版里唯一写
    /// `breathDuration` / `dotFadeInDuration` 的地方**——它们不在`LyricsSpecs` 里，
    /// 是按这一行自己的时长现算的：
    ///
    /// ```
    /// end'              = endTime − 1.8
    /// span              = end' − startTime
    /// breathDuration    = span / floor(span / 4) / 2
    /// dotFadeInDuration = (end' − startTime − 1.0) / dotCount
    /// ```
    ///
    /// `floor(span / 4)` 是整个间奏塞得下几次完整呼吸（每次约 4 秒），
    /// `breathDuration` 取它的一半，即**半周期**（一次吸或一次呼）。
    ///
    /// - Note: `span < 4` 时`floor` 得 0，原版**没有防护**，`breathDuration` 会变成
    ///   `+inf`，呼吸这一档直接失效（间奏短于 5.8 秒时）。这里照抄不补洞，
    ///   要不要防护交给调用方。
    func reset() {
        guard let line else { return }

        animationGeneration &+= 1
        activeAnimators.removeAll()

        let effectiveEnd = line.endTime - Self.fadeOutLeadTime
        let span = effectiveEnd - line.startTime

        let breaths = (span / Self.breathCycleTarget).rounded(.down)
        breathDuration = span / breaths / 2

        let count = specs.instrumentalBreakCountdownDotCount
        dotFadeInDuration = (effectiveEnd - (line.startTime + Self.firstDotDelay)) / Double(count)

        totalDotsCompleted = 0
        totalBreathsCompleted = 0
        lastBreathScale = Self.breathScaleRange.lowerBound
        // `nil` 表示点还没摆上来；`prepare(at:)` 对应原版独立的
        // 会在布局完成后把它改成 0。
        totalDotsFadedIn = nil
        fadeOutCued = false
        currentElapsedTime = nil

        for dot in dots {
            dot.removeAllAnimations()
            dot.opacity = 0
            dot.setAffineTransform(.identity)
        }
    }

    // MARK: 3.3 每帧

    /// 这一帧要做的事。`update(elapsed:)` 把它算出来，交给调用方去下发动画——
    /// 这样状态机本身可测，不必拖着 Core Animation。
    enum FrameAction: Equatable {
        /// 应亮的点数比已亮的少：整体复位再重排。
        case reset
        /// 第一次摆点：整排一起浮出来——已到时的点去 `dotFilledOpacity`，
        /// 其余点去 `dotUnfilledOpacity`（显示了但没填充），每点错开`stagger`。
        case prepareDots(activeCount: Int, curve: LyricsAnimationCurve,
                         stagger: TimeInterval, delay: TimeInterval)
        /// 把点填满：`snapToOpaque` 里的直接落值（追帧），`animate` 那个走曲线填过去。
        case fadeInDots(snapToOpaque: Range<Int>, animate: Int, curve: LyricsAnimationCurve)
        /// 整排呼吸一次。
        case breathe(curve: LyricsAnimationCurve, delay: TimeInterval, scale: CGFloat)
        /// 起淡出，只会发一次。
        case cueFadeOut
    }

    /// 把刚复位的点阵摆到给定时刻。
    ///
    /// 这是独立于每帧入口的：先按当前时刻决定哪些点
    /// 是 100% / 10%，再起第一拍 1.2 倍呼吸。选中间奏、seek 进间奏中段以及
    /// 倒带复位后都走这里。
    func prepareActions(at elapsed: TimeInterval) -> [FrameAction] {
        guard totalDotsFadedIn == nil, let line else { return [] }

        totalDotsFadedIn = 0
        let count = specs.instrumentalBreakCountdownDotCount
        let firstDotTime = line.startTime + Self.firstDotDelay
        let activeCount: Int
        if elapsed < firstDotTime || !dotFadeInDuration.isFinite || dotFadeInDuration <= 0 {
            activeCount = 0
        } else {
            activeCount = min(max(Int((elapsed - firstDotTime) / dotFadeInDuration) + 1, 0), count)
        }

        let canBreathe = breathDuration.isFinite && breathDuration > Self.breathAnimationTrim

        // 入场**不是选中那一刻起跑的**：要等到行开始后 `firstDotDelay`（1.0s）。
        // [PX] 2026-09-04 逐帧量 Music 的一段间奏：行在 t=3.13 开始、撑开 3.67 落定，
        // 三个点的亮度一直是背景值（32/32/30）直到 **t≈4.05**（+0.92s）才一起往上走，
        // 到 5.0 摸到 10% 那一档，5.1 起第一个点才填满。也就是说**空间先完全展开，
        // 点才出现**。少了这条延迟，点会跟着撑开一起浮出来，早半秒多。
        //
        // 中途 seek 进间奏（elapsed 已经越过那一刻）时 delay 自然是 0，立刻摆点。
        let entranceDelay = max(0, firstDotTime - elapsed)
        var actions: [FrameAction] = [
            .prepareDots(activeCount: activeCount,
                         curve: .linear(Self.initialDotAnimationDuration),
                         stagger: Self.initialDotStagger,
                         delay: entranceDelay)
        ]

        if canBreathe {
            // 入场恒定先涨到大的那一档；节奏（下一拍什么时候来）仍由 elapsed 决定，
            // 中途进间奏不会把已经过去的那些拍补跑一遍。
            actions.append(.breathe(
                curve: .easeOut(breathDuration - Self.breathAnimationTrim),
                delay: Self.breathAnimationDelay,
                scale: Self.breathScaleRange.upperBound))
            lastBreathScale = Self.breathScaleRange.upperBound
            totalBreathsCompleted = max(Int((elapsed - line.startTime) / breathDuration) + 1, 1)
        } else {
            // 间奏短于 5.8 秒时呼吸这一档整个失效（§3.2 的 `+inf`）。点仍然要停在
            // 大的那一档——早先是靠那条无限时长动画的副作用（`finishDispatch` 立刻
            // 把模型值写成 1.2）顺带做到的，闸一加就没人写了，点会缩回原始尺寸。
            actions.append(.breathe(curve: .easeOut(Self.staticGrowDuration), delay: 0,
                                    scale: Self.breathScaleRange.upperBound))
            lastBreathScale = Self.breathScaleRange.upperBound
        }
        currentElapsedTime = elapsed
        return actions
    }

    /// 每帧入口。
    ///
    /// [实测]。`elapsed` 是全局时间轴上的秒数，
    /// 不是行内相对时间。四段依次是：倒带检测 / 逐个淡入 / 整排呼吸 / 淡出。
    func update(elapsed: TimeInterval) -> [FrameAction] {
        guard let line else { return [] }
        var actions: [FrameAction] = []

        let count = specs.instrumentalBreakCountdownDotCount
        let effectiveEnd = line.endTime - Self.fadeOutLeadTime
        let firstDotTime = line.startTime + Self.firstDotDelay

        // 正常选中路径会先调 prepare；保留这条自愈，避免调用方漏掉交接时
        // 状态机永远卡在 `totalDotsFadedIn == nil`。
        if totalDotsFadedIn == nil {
            return prepareActions(at: elapsed)
        }

        // 一、倒带检测：应亮的点数比已亮的少 → 复位重排。
        // 这是唯一的回退路径，往回拖进度条靠它。
        let due = min(Int((elapsed - firstDotTime) / dotFadeInDuration) + 1, count)
        // 已经跑完淡出的点阵停在 opacity 0；往回拖进同一段间奏时点数是满的，
        // 上面那条「应亮 < 已亮」不成立，于是整段间奏只剩一块空档、一个点都不亮。
        // 只要回到了有效终点之前，就当成新的一轮重来。
        if due < totalDotsCompleted || (fadeOutCued && elapsed < effectiveEnd) {
            reset()
            return [.reset] + prepareActions(at: elapsed)
        }

        currentElapsedTime = elapsed

        // 二、逐个淡入。三道前置闸，任何一条不成立就跳过。
        // `fccmp ... eq` + 的实际含义是：初次摆点的三个动画必须全部
        // 完成，并且已经越过第一个点的时刻，才进入逐点填充。此前把这个组合
        // 条件读反了，会在 0.8 秒入场尚未结束时抢先点亮第一个点。
        let mayFadeIn = totalDotsFadedIn == count
            && firstDotTime < elapsed
            && elapsed < effectiveEnd
        if mayFadeIn, due != totalDotsCompleted, isSelected, due - 1 >= totalDotsCompleted {
            actions.append(.fadeInDots(
                snapToOpaque: totalDotsCompleted..<(due - 1),
                animate: due - 1,
                curve: .linear(dotFadeInDuration - Self.dotFadeInAnimationTrim)))
            totalDotsCompleted = due
        }

        // 三、整排呼吸。breathDuration 是半周期，
        // 所以这个计数一个完整周期加两次——一张一收，靠 easeOut 自己对称。
        //
        // 淡出已经起跑之后不再补呼吸：那条 1.5 秒的 group 也在动 `transform`，
        // 中途插一条新的整排缩放会把「涨大→缩没」的收尾顶掉，看起来像又弹了一下。
        // `breathDuration` 在间奏短于 5.8 秒时是`+inf`（`floor(span / 4) == 0`，§3.2
        // 照抄了原版不防护）。§3.2 那条闸只挡了 `prepareActions`，这里也得挡：
        // 漏掉的话会下发一条 `duration = inf` 的缩放动画，点从此冻在当前那一帧的
        // 大小上不再动，间奏长短不同就冻在不同尺寸——看着就是「大小随机」。
        let canBreathe = breathDuration.isFinite && breathDuration > Self.breathAnimationTrim
        let breaths = canBreathe ? Int((elapsed - line.startTime) / breathDuration) + 1 : 0
        if canBreathe, !fadeOutCued, totalBreathsCompleted < breaths {
            // [实测] 按应完成半周期数的奇偶在 1.2 / 0.9 之间选。
            // 这里改成从上一拍翻面：等价于奇偶，但中途 seek 进来也不会撞上
            // 「目标值没变」而整拍被跳过。
            let target = lastBreathScale == Self.breathScaleRange.upperBound
                ? Self.breathScaleRange.lowerBound
                : Self.breathScaleRange.upperBound
            actions.append(.breathe(
                curve: .easeOut(breathDuration - Self.breathAnimationTrim),
                delay: Self.breathAnimationDelay,
                scale: target))
            lastBreathScale = target
            totalBreathsCompleted = breaths
        }

        // 四、淡出。窗口是最后 1.8 秒，只发一次。
        if elapsed < line.endTime, effectiveEnd < elapsed, !fadeOutCued {
            fadeOutCued = true
            currentElapsedTime = nil
            actions.append(.cueFadeOut)
        }

        return actions
    }

    /// 淡出的三段。
    ///
    /// [实测]。第一段的曲线是整块常量搬过来的
    /// 控制点 `(0.25, 0.1)`、`(0.25, 1.0)`，
    /// 时长 1.0——正好是 CSS 的 `ease`。
    static let fadeOutCurves: [(curve: LyricsAnimationCurve, delay: TimeInterval)] = [
        (.custom(CGPoint(x: 0.25, y: 0.1), CGPoint(x: 0.25, y: 1.0), duration: 1.0), 0),
        (.easeIn(0.3), 1.0),
        // 同样把 1.0 传给下发口；
        // 早期报告漏记了第三段的 delay。
        (.easeIn(0.5), 1.0),
    ]

    /// 淡出最后一段的目标缩放。[实测] 初始化 0.2 变换。
    static let fadeOutScale: CGFloat = 0.2
}

// MARK: - 协议一致性与落位

extension InstrumentalContentLayer {

    /// 整排的尺寸。宽度是 §3.1 的 `n × length + (n−1) × margin`（基线 52）。
    /// 未选中时高度为 0，不提前在两句歌词之间占位；轮到间奏、选中态落下后才
    /// 返回 `instrumentalBreakViewHeight`（40），由行重排弹簧把中间撑开。
    func sizeThatFits(width: CGFloat) -> CGSize {
        CGSize(width: min(dotsWidth, width),
               height: isSelected ? specs.instrumentalBreakViewHeight : 0)
    }

    func setScrolling(_ scrolling: Bool, animated: Bool) {
        isScrolling = scrolling
    }

    func updateAppearance(specs: LyricsSpecs, appearance: NSAppearance?) {
        self.specs = specs
        let color = LyricsSpecs.cgColor(specs.selectedTextColor, in: appearance)
        for dot in dots { dot.backgroundColor = color }
    }

    /// 三个点在整排里的落位。点是正圆（`cornerRadius = length / 2`），纵向居中。
    ///
    /// `makeDots` 已经把首末两个点的`anchorPoint.x` 推开了 ±1.3（§3.1），
    /// 所以这里按 anchorPoint 自己算 `position`。
    ///
    /// **不能写 `frame`**：呼吸把`transform` 变成非单位矩阵之后，`frame` 的 setter
    /// 会把缩放反除进 `bounds`（0.9 倍时 bounds 变成`length / 0.9`），而
    /// `cornerRadius` 仍是`length / 2`——半径小于半边长，圆点就成了圆角方块。
    /// 12pt 时偏差 0.67pt 看不出来，按字号档放大到 23pt 就有 1.3pt，一眼就是方的。
    /// 附带的另一半：bounds 被撑大后渲染尺寸恒等于 `length`，呼吸在重排跑过之后
    /// 就完全看不出来了，观感上正是「大小时有时无」。
    ///
    /// 整段**关掉隐式动作**（与 `SyncedLyricsLineLayer.layoutSublayers` 一致）。
    /// 点是手工挂上去的子层、不是视图背衬层，CALayer 的默认动作在这儿是生效的：
    /// 行高 0→40 时 `dotOrigins` 的 y 从 `(0−length)/2` 变成`(40−length)/2`，
    /// 三个点会各自跑一条 0.25s 的隐式位移，和行重排那条弹簧完全不同拍；
    /// `isHidden` / `masksToBounds` 的翻转同理会被补一段淡变。
    /// 点自己的出现、呼吸与淡出另有动画（`reset()` / `cueFadeOut`），
    /// 布局这一步只该落值。
    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // 0 高度阶段整层藏掉；行展开完成后再显示，让既有呼吸动画可以越过
        // 点阵自身边界。行视图为滤镜溢出关掉了 `clipsToBounds`，只靠裁剪
        // 兜不住——没轮到的间奏行会把点画到下一句歌词上。
        // 判据里必须带上 `isSelected`：几何会因为行图层的缩放被`frame` 的 setter
        // 反除而虚胖零点几 pt，光比 `bounds.height` 判不出「这一行已经折叠了」。
        let collapsed = !isSelected || bounds.height <= 0
        isHidden = collapsed
        masksToBounds = collapsed
        guard !dots.isEmpty, bounds != lastSeenBounds || dots.first?.bounds.width == 0 else {
            lastSeenBounds = bounds
            return
        }
        lastSeenBounds = bounds

        layoutDots()
    }

    /// 三个点各自的落点（左上角，图层坐标系）。
    ///
    /// [实测] 的三值分支（§13.6）。整排宽 `dotsWidth`（基线 52），
    /// 起点 x 由 `alignment` 选边，之后每个点按`length + margin`（基线 20）平推：
    ///
    /// ```
    /// alignment == 1(居中): x0 = (width − 52) × 0.5
    /// alignment == 2(右):   x0 = width − 52
    /// 其它(含 0 = 左/自然): x0 = 0
    /// 第 i 个点 x = x0 + i × 20，宽高都是 12
    /// y = (height − 12) × 0.5                       // 垂直居中
    /// ```
    func dotOrigins(inWidth width: CGFloat, height: CGFloat) -> [CGPoint] {
        let length = specs.instrumentalBreakDotLength
        let margin = specs.instrumentalBreakDotMargin
        let x0: CGFloat
        switch alignment {
        case .center: x0 = (width - dotsWidth) / 2
        case .right:  x0 = width - dotsWidth
        case .natural: x0 = 0
        }
        let y = (height - length) / 2
        return (0..<dots.count).map { CGPoint(x: x0 + CGFloat($0) * (length + margin), y: y) }
    }

    /// 按当前 `bounds` 与`alignment` 重排三个点。
    /// [实测] 起那一段，也是 `alignment` 写入器的后半。
    func layoutDots() {
        let length = specs.instrumentalBreakDotLength
        for (dot, origin) in zip(dots, dotOrigins(inWidth: bounds.width, height: bounds.height)) {
            dot.bounds = CGRect(x: 0, y: 0, width: length, height: length)
            dot.position = CGPoint(x: origin.x + dot.anchorPoint.x * length,
                                   y: origin.y + dot.anchorPoint.y * length)
            dot.cornerRadius = length / 2
        }
    }
}

// MARK: - 把 FrameAction 下发成动画

extension InstrumentalContentLayer {

    /// 呼吸失效时把点摆到大的那一档所用的时长。
    static let staticGrowDuration: TimeInterval = 0.3

    /// 呼吸的缩放范围。动的是**每个点的 `transform`**（§13.3 已把 §3.3 的`[部分]` 坐实）：
    /// 呼吸序号奇 → 张、偶 → 收，首拍（序号 1，奇）从 `.identity` 走向上限。
    ///
    /// 张 = 载入 = **1.2**。
    /// 收 = 载入——§13.3 的表把它标成 0.8/「缩到 80%」，
    /// 但这 8 字节实际解码是 **0.9**（0.8 的位型是，那串是 §13.7 淡入
    /// 的 0.8 s 时长，不是缩放）。报告是转十进制时手滑，落地以字节为准，别照 prose 改成 0.8。
    static let breathScaleRange: ClosedRange<CGFloat> = 0.9...1.2

    /// 走一帧：算出这一帧要做的事，再下发成动画。
    @discardableResult
    func advance(to elapsed: TimeInterval) -> [FrameAction] {
        let actions = update(elapsed: elapsed)
        for action in actions { perform(action) }
        return actions
    }

    /// 选中 / jump 进间奏时调用。不能只跑 `update`：`update` 会先推进计数，
    /// 下一帧便认为动作已经完成，实际图层却从未收到动画。
    @discardableResult
    func prepare(at elapsed: TimeInterval) -> [FrameAction] {
        // 同上：重新选中一段播完过的间奏（循环、往回拖）得先复位，
        // 否则 `prepareActions` 的`totalDotsFadedIn == nil` 闸会把它整个挡掉。
        if fadeOutCued, let line, elapsed < line.endTime - Self.fadeOutLeadTime { reset() }
        let actions = prepareActions(at: elapsed)
        for action in actions { perform(action) }
        return actions
    }

    func perform(_ action: FrameAction) {
        switch action {
        case .reset:
            // `reset()` 已经在`update` 里跑过了，动画也一并撤了。
            break

        case .prepareDots(let activeCount, let curve, let stagger, let delay):
            let generation = animationGeneration
            for (index, dot) in dots.enumerated() {
                let animator = LayerPropertyAnimator(curve: curve)
                animator.delay = delay + Double(index) * stagger
                animator.layers = [dot]
                animator.addAnimation(to: dot, keyPath: "opacity",
                                      from: dot.presentation()?.opacity ?? dot.opacity,
                                      to: index < activeCount
                                          ? Self.dotFilledOpacity : Self.dotUnfilledOpacity,
                                      frameRateRange: (min: 0, max: 0))
                animator.completionHandlers.append { [weak self] in
                    guard let self, self.animationGeneration == generation,
                          self.totalDotsFadedIn != nil else { return }
                    self.totalDotsFadedIn = max(self.totalDotsFadedIn ?? 0, index + 1)
                    self.pruneFinishedAnimators()
                }
                retain(animator)
                animator.finishDispatch {
                    dot.opacity = index < activeCount
                        ? Self.dotFilledOpacity : Self.dotUnfilledOpacity
                }
            }

        case .fadeInDots(let snapToOpaque, let animate, let curve):
            // 追帧的那几个直接落值（seek 进间奏中段时不该一个个补淡入）。
            for index in snapToOpaque where dots.indices.contains(index) {
                dots[index].removeAnimation(forKey: "opacity")
                dots[index].opacity = Self.dotFilledOpacity
            }
            guard dots.indices.contains(animate) else { break }
            let dot = dots[animate]
            let animator = LayerPropertyAnimator(curve: curve)
            animator.layers = [dot]
            animator.addAnimation(to: dot, keyPath: "opacity",
                                  from: dot.opacity, to: Self.dotFilledOpacity,
                                  frameRateRange: (min: 0, max: 0))
            animator.finishDispatch { dot.opacity = Self.dotFilledOpacity }

        case .breathe(let curve, let delay, let scale):
            // `breathDuration` 是半周期，一个完整周期会发两次——一张一收。
            let animator = LayerPropertyAnimator(curve: curve)
            animator.delay = delay
            animator.layers = dots
            let target = CATransform3DMakeScale(scale, scale, 1)
            for dot in dots {
                animator.addAnimation(to: dot, keyPath: "transform",
                                      from: dot.transform, to: target,
                                      frameRateRange: (min: 0, max: 0))
            }
            animator.completionHandlers.append { [weak self] in self?.pruneFinishedAnimators() }
            retain(animator)
            animator.finishDispatch { self.dots.forEach { $0.transform = target } }

        case .cueFadeOut:
            performFadeOut()
        }
    }

    private func retain(_ animator: LayerPropertyAnimator) {
        pruneFinishedAnimators()
        activeAnimators.append(animator)
    }

    private func pruneFinishedAnimators() {
        activeAnimators.removeAll { $0.state == .idle }
    }

    /// [实测] 的三段不是三条 opacity：
    /// 先 scale→1.2（CSS ease, 1.0s），然后在 t+1 同时 opacity→0（0.3s）
    /// 与 scale→0.2（0.5s）。用 group 保留同一 keyPath 上的前后两段，避免后一条
    /// `transform` 在加入时把前一条移除。
    private func performFadeOut() {
        let now = CACurrentMediaTime()
        for dot in dots {
            let startTransform = dot.presentation()?.transform ?? dot.transform
            let startOpacity = dot.presentation()?.opacity ?? dot.opacity

            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = startTransform
            grow.toValue = CATransform3DMakeScale(Self.breathScaleRange.upperBound,
                                                  Self.breathScaleRange.upperBound, 1)
            grow.duration = 1
            grow.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.25, 0.1, 0.25, 1)

            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = CATransform3DMakeScale(Self.breathScaleRange.upperBound,
                                                      Self.breathScaleRange.upperBound, 1)
            shrink.toValue = CATransform3DMakeScale(Self.fadeOutScale, Self.fadeOutScale, 1)
            shrink.beginTime = 1
            shrink.duration = 0.5
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = startOpacity
            fade.toValue = Float(0)
            fade.beginTime = 1
            fade.duration = 0.3
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            // 模型值在下面已经被写成 0，而这条子动画从 t=1 才开始。默认的
            // `.removed` 让前 1 秒的呈现值回落到模型值——点会在起淡出的那一刻
            // 直接消失，涨大那一段全程看不见，到 t=1 又从满不透明重新闪一下。
            // `.backwards` 把`fromValue` 往前铺满，涨大期间才一直亮着。
            fade.fillMode = .backwards

            let group = CAAnimationGroup()
            group.animations = [grow, shrink, fade]
            group.beginTime = now
            group.duration = 1.5
            group.fillMode = .both
            group.isRemovedOnCompletion = true
            group.preferredFrameRateRange = LayerPropertyAnimator.frameRateRange(min: 0, max: 0)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.opacity = 0
            dot.transform = CATransform3DMakeScale(Self.fadeOutScale, Self.fadeOutScale, 1)
            CATransaction.commit()
            dot.removeAnimation(forKey: "opacity")
            dot.removeAnimation(forKey: "transform")
            dot.removeAnimation(forKey: "instrumentalFadeOut")
            dot.add(group, forKey: "instrumentalFadeOut")
        }
    }
}
