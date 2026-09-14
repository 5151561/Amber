import AppKit
import QuartzCore

// 辉光（glow）全链。规格见 §23。
//
// 一句话：**辉光不是滤镜、不是第二层模糊拷贝、不是 `NSShadow`，就是词的基础层自带的
// `CALayer` 投影**——半径 5、无偏移、静止态`shadowOpacity = 0`，唱到时把 opacity
// 推上去（§23.2）。强度是逐词的 `Emphasis.factor` 乘进`glowRange`（§23.3），
// ramp 的弹簧只用来取时长、执行是逐 tick 直写模型值（§23.4）。
//
// 落到 Amber 的两处形变，都记在下面各自的注释里：
//
// - **挂在哪一层**：原版一个词一个 `Word.layer`（承载文字，overlay 拿它当 mask，
//   §26.7）。Amber 走的是 `animationKind == 0` 那一支，没有 overlay，一个音节一对
//   `base`/`sung` 文字层。阴影挂`base`——`sung` 被那条推进遮罩罩着，
//   阴影会跟着在扫过前沿被剪掉；`base` 不带遮罩，光晕才是完整一圈。
//   两层字形完全同位，视觉上光晕仍然围着亮字。
// - **谁来推 tick**：原版把闭包挂进一个队列逐 tick 调 `setShadowOpacity:`。
//   Amber 的逐字进度本来就由 `SyncedLyricsViewController` 的`CADisplayLink`
//   每帧推到 `applyProgress`，ramp 直接搭这班车——同样是「逐 tick 直写模型值」，
//   不多起一条时基。

extension SBS_TextContentLayer {

    /// 一条正在跑的辉光 ramp。
    ///
    /// [实测] §23.4：弹簧**只用来取 `settlingDuration`**（原版就地 new 一个
    /// `CASpringAnimation` 又马上释放），真正的执行是逐 tick 把`shadowOpacity`
    /// **直写进模型值**，不是 `CAAnimation`。所以这里也只存端点与时长，
    /// 每帧按解析解求值。
    struct GlowRamp {
        var from: Float
        var to: Float
        var spring: SpringTimingParameters
        var settlingDuration: TimeInterval
        var startTime: CFTimeInterval

        func isFinished(at now: CFTimeInterval) -> Bool {
            now - startTime >= settlingDuration
        }

        func value(at now: CFTimeInterval) -> Float {
            let t = now - startTime
            if t <= 0 { return from }
            if t >= settlingDuration { return to }
            // `decay` 是归一化位移：t = 0 时 1、收敛到 0，与滚动弹簧共用一套解析解。
            let decay = ScrollSpring.decay(t: t, parameters: spring)
            return to + (from - to) * Float(decay)
        }
    }

    /// 打断时要逐条查的 keyPath 表。
    ///
    /// [实测] §23.5 / §8.1：原版遍历 `deglowAnimator` 的 keyPath 表，
    /// 对层逐条 `animationForKey:`、**是`CABasicAnimation` 才**
    /// `removeAnimationForKey:`。
    /// **不是盲调 `removeAllAnimations()`**——层上还有滚动、渐变、位置的动画，
    /// 一把清掉会误伤。
    static let syllableAnimationKeyPaths = ["position", "transform", "shadowOpacity"]

    // MARK: - 装配（§23.2）

    /// 把辉光装到一个音节的基础层上。静止态是全透明的，所以这一步不产生任何观感。
    ///
    /// [实测] 新建 `Word.layer` 的分支：
    ///
    /// ```
    /// layer.rasterizationScale = specs.displayScale
    /// layer.shouldRasterize    = true
    /// layer.shadowColor        = 镜面.glowColor      ;
    /// layer.shadowRadius       = specs.glowRadius    ; = 5
    /// layer.shadowOpacity      = 0.0                 ; ★ 静止态全透明
    /// layer.shadowOffset       = (0, 0)              ; 均匀光晕，不带方向
    /// ```
    ///
    /// 两处按 Amber 的实际情况落地：
    ///
    /// - `rasterizationScale` 取`contentsScale × emphasizingScaleRange.upperBound`
    ///   而不是 `specs.displayScale`。原版那个字段就是屏幕缩放；Amber 的
    ///   `LyricsSpecs.displayScale` 默认 1.0 且没有接到真实屏幕，照抄会把 Retina 上的
    ///   文字烘焙成 1x 位图。再乘 1.14 是因为**会发光的词正是会被强调放大的词**
    ///   （§8.1 与 §23.3 同一个 `factor` 源）——位图按放大前的尺寸烘焙、再被
    ///   `transform` 拉到 1.14 倍，就会糊。这个 1.14 不是试出来的系数，
    ///   它就是 §7.3 里「这行字最大能长到多大」用的那一个。`[补]`
    /// - 只给**真的会发光的词**（`emphasis != .none`）开`shouldRasterize`。
    ///   §23.3 的第四道闸对 `.none` 是整词跳过，那些层的`shadowOpacity` 永远是 0，
    ///   烘焙没有收益、只多占一份位图。`[补]`
    func configureGlow(on layer: CALayer, emphasis: Lyrics.Emphasis) {
        guard !emphasis.isNone else { return }
        layer.shadowColor = LyricsSpecs.cgColor(specs.glowColor, in: appearance)
        layer.shadowRadius = specs.glowRadius
        layer.shadowOffset = .zero
        layer.shadowOpacity = 0
        layer.rasterizationScale = contentsScale * specs.emphasizingScaleRange.upperBound
        layer.shouldRasterize = true
    }

    // MARK: - 强度（§23.3）

    /// `shadowOpacity` 的终值。
    ///
    /// [实测]：
    /// `intensity = glowRange.lowerBound + (upperBound − lowerBound) × factor`。
    /// 默认 `glowRange = 0…0.4`，也就是 **opacity = 0.4 × factor**。
    static func glowIntensity(factor: Double, specs: LyricsSpecs) -> Float {
        let range = specs.glowRange
        return Float(range.lowerBound
            + (range.upperBound - range.lowerBound) * min(max(factor, 0), 1))
    }

    /// ramp 弹簧。
    ///
    /// [实测] §23.4：`stiffness = min(span, 3.0)`、
    /// `damping` 入参恒 **1.0**，交给描述符工厂。
    /// 那个工厂就是 `SpringTimingParameters(dampingRatio:response:)`
    /// （58 条全部实测）——**第二个入参是「周期」不是刚度**：
    /// `ω = 2π / response`、`stiffness = mass·ω²`、`damping = ζ·2√(stiffness·mass)`。
    /// 于是 `span` 直接就是 ramp 的周期，ζ = 入参 = 1.0 → **临界阻尼、无回弹**，
    /// 与 §7.5 那条欠阻尼（ζ = 0.935）的音节弹簧刻意不同。
    ///
    /// - Note: §23.4 正文写的 `ζ = π/k ∈ [1.05, 3.14]` 与它自己贴的那串算术
    ///   （`2.0×π → ÷k → 平方 → ×mass → √ → ×2 → ×damping_in`）对不上：
    ///   那串算术是标准的「(阻尼比, 周期) → (刚度, 阻尼)」换算，解出来 ζ 恒等于入参 1.0。
    ///   按 `k` 当刚度讲则 span = 1s 时`settlingDuration` 要几十秒，明显不成立。
    ///   这里取**算术**那一份。`[补]`
    static func glowSpring(span: TimeInterval) -> SpringTimingParameters {
        SpringTimingParameters(dampingRatio: 1.0, response: min(max(span, 0.05), 3.0))
    }

    // MARK: - 触发（§23.5）

    /// 每帧起 ramp。五道闸照 §23.5 抄。
    ///
    /// [实测]：
    ///
    /// ```
    /// 模型词数组首元素 originalStartTime > elapsed → 跳过   ; 词段没开始
    /// Word.animationStatus tag < 2         → 跳过   ; 还在动（§25.3 tag<2 = 运动态）
    /// Word.animationStatus 载荷 ≠ 0        → 跳过   ; 身上挂着动画器
    /// emphasis tag == 1（.none）           → 跳过
    /// Word.layer == nil                            → 跳过   ; ramp
    /// ```
    ///
    /// 第二、三道在 Amber 合成一条：`Word.animationStatus` 是三 case
    /// （`idle`/`running`/`finished`），`.running` 就是「运动态 + 载荷非空」。
    /// Amber 目前不写这个字段，恒为 `.idle`，闸恒放行——保留是为了接线时不至于漏。
    func startGlowRamps(in row: Row,
                        layoutLine: SyncedLyricsLineLayer.LayoutLine,
                        now: CFTimeInterval) {
        guard layoutLine.hasEmphasis else { return }
        var flat = 0
        for word in layoutLine.words {
            let base = flat
            flat += word.syllables.count
            // 闸四：`.none` 的词整个不做辉光。
            guard !word.emphasis.isNone else { continue }
            // 闸二 + 闸三。
            guard word.animationStatus != .running else { continue }
            guard let start = word.syllables.first?.startTime else { continue }

            // 闸一：词段没开始。取的是**模型词**首音节的起点。
            //
            // 往回 seek 时这一闸从「放行」翻回「拦住」，此时把已经点亮的词**反向 ramp
            // 回 0**——§25.3 的 `LyricsAnimationStatus.reverseAnimating` 就是给这一支
            // 留的位置。少了它，重听同一段时那些字一直亮着。`[补]`
            let started = progress >= start
            if started {
                guard row.glowed.insert(base).inserted else { continue }
            } else {
                guard row.glowed.remove(base) != nil else { continue }
            }

            // span = 该词模型侧首音节 startTime → 末音节 endTime（§23.4）。
            let span = (word.syllables.last?.endTime ?? start) - start
            let spring = Self.glowSpring(span: span)
            let target = started
                ? Self.glowIntensity(factor: word.emphasis.factor, specs: specs)
                : 0
            let settling = CASpringAnimation(keyPath: "shadowOpacity", spring: spring)
                .settlingDuration

            for offset in 0..<word.syllables.count {
                guard let pair = row.syllables[safe: base + offset] else { continue }
                row.glows[base + offset] = GlowRamp(
                    from: pair.base.shadowOpacity,
                    to: target,
                    spring: spring,
                    settlingDuration: settling,
                    startTime: now)
            }
        }
    }

    /// 逐 tick 直写 `shadowOpacity`（§23.4 第 5 步）。
    ///
    /// 调用方已经把它包在 `CATransaction.setDisableActions(true)` 里了——
    /// **必须**如此：写的是模型值，再让 CoreAnimation 叠一次隐式动画就不是直写了。
    func advanceGlowRamps(in row: Row, now: CFTimeInterval) {
        guard !row.glows.isEmpty else { return }
        for (index, ramp) in row.glows {
            guard let pair = row.syllables[safe: index] else {
                row.glows[index] = nil
                continue
            }
            pair.base.shadowOpacity = ramp.value(at: now)
            if ramp.isFinished(at: now) { row.glows[index] = nil }
        }
    }

    // MARK: - 打断（§23.5 + §8.1「去辉光的打断」）

    /// 打断一行的辉光：**先把最终值落进属性、再清引用**。
    ///
    /// [实测] §8.1 →：把动画最终值直接写进
    /// 属性，然后才 `word.deglowAnimator = nil`。**顺序反了会闪一下**——
    /// 动画是 `isRemovedOnCompletion = true` 的（§6.3），只清引用不落值，
    /// 属性会弹回模型层的旧值。
    ///
    /// - Parameter fade: 落完值之后是否顺手熄灭（换行 / 换歌那种硬复位）。
    func interruptGlow(in row: Row, fade: Bool) {
        for (index, ramp) in row.glows {
            guard let pair = row.syllables[safe: index] else { continue }
            pair.base.shadowOpacity = ramp.to        // 先落值
        }
        row.glows.removeAll()                        // 再清引用
        for pair in row.syllables {
            Self.cancelBasicAnimations(on: pair.base,
                                       keyPaths: Self.syllableAnimationKeyPaths)
            if fade { pair.base.shadowOpacity = 0 }
        }
    }

    /// 按 keyPath 逐条摘动画，**只摘 `CABasicAnimation`**。
    ///
    /// [实测] §23.5：`animationForKey:` → 是 basic animation 才`removeAnimationForKey:`。
    /// `CASpringAnimation` 是`CABasicAnimation` 的子类，抬升那条也在表里。
    static func cancelBasicAnimations(on layer: CALayer, keyPaths: [String]) {
        for keyPath in keyPaths where layer.animation(forKey: keyPath) is CABasicAnimation {
            layer.removeAnimation(forKey: keyPath)
        }
    }
}
