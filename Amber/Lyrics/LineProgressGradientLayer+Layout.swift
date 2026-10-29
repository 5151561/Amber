import QuartzCore

extension LineProgressGradientLayer {

    /// 三个子层的落位。规格见 §8.2。
    ///
    /// [实测] `layoutSublayers` →。
    ///
    /// **软边是一个独立的定宽子层，不是渐变铺满整层**——
    /// `lineProgressionGradientFeather = 30` 是这个子层的宽度，
    /// 扫过时整层宽度在变、软边条始终 30pt 贴在最前端。
    /// §7.3 里已唱宽度加的那个 feather 就是给它留的位置。
    struct SublayerFrames: Equatable {
        var gradient: CGRect
        var fill: CGRect
        /// `outerPadding == nil` 时不摆（直接返回）。
        var horizontalPadding: CGRect?
    }

    /// - Parameters:
    ///   - isRightToLeft: `direction == 1`。只换左右两端，公式其余部分完全对称。
    ///   - outerPadding: `CGSize?`，tag 在；nil 时纵向余量按 0 算。
    static func sublayerFrames(bounds: CGRect,
                                      featherWidth: CGFloat,
                                      isRightToLeft: Bool,
                                      outerPadding: CGSize?) -> SublayerFrames {
        let pad = outerPadding?.height ?? 0
        let w = bounds.width
        let h = bounds.height

        // 软边条：定宽 feather，贴推进方向的前端；纵向外扩 pad（§7.3 的余量只用在这里）。
        let gradient = CGRect(x: isRightToLeft ? 0 : w - featherWidth,
                              y: -pad,
                              width: featherWidth,
                              height: h + 2 * pad)

        // 实心部分：纵向同样外扩 pad。
        //
        // [实测] 这里是`y: 0, height: h`——严格贴合 bounds，理由是「盖的是已经唱过的
        // 字，不会再被强调放大」。但**抬升会**：音节层整体上移`syllableLift`，
        // 贴合 bounds 的实心区会把已唱字的顶端切掉，露出底下那层暗字。
        // 2pt 时刚好擦着字形上沿过去，调到 [PX] 的 4pt 就切进墨里了。
        // 外扩量与软边条取同一个 pad（§7.3 的余量本来就是「强调 / 辉光超出正文多少」），
        // 没有溢出时多出来的那一圈落在空白上，是个纯无害的放宽。`[补]`
        let fill = CGRect(x: isRightToLeft ? featherWidth : min(0, w - featherWidth),
                          y: -pad,
                          width: max(0, w - featherWidth),
                          height: h + 2 * pad)

        var padding: CGRect?
        if let outer = outerPadding {
            // 高度是 2·outer.height，**不含** bounds.height（`fadd d3, d9, d9`）
            // ——与渐变条那条明显不同。照抄，但看着像原版自己的一处将就。[推]
            let x = isRightToLeft ? fill.maxX : fill.minX - outer.width
            padding = CGRect(x: x, y: -outer.height,
                             width: outer.width, height: 2 * outer.height)
        }
        return SublayerFrames(gradient: gradient, fill: fill, horizontalPadding: padding)
    }
}

extension SyncedLyricsLineLayer {

    /// 抬升 / 强调的落点。规格见 §8.1。
    ///
    /// [实测]，`animationKind != 1` 的词层路径。
    enum SyllableEmphasis {

        /// 强调缩放。**一条直线，没有缓动**——缓动全交给弹簧。
        ///
        /// [实测]：`lo + (hi − lo) × t`，`t` 是音节自己的进度。
        ///
        /// 这个 `t` 只在**发起那一刻**取一次：`s = lo + t·(hi − lo)` 算在逐字形循环之前，
        /// 而循环的门槛是「这个音节的动画已经派过一次」，所以取到时 `t ≈ 1`、
        /// `s` 正好落在上界 1.14。函数留着是为了把那条直线写明白，
        /// 接线处直接用 `specs.emphasizingScaleRange.upperBound`。
        static func scale(progress t: Double, specs: LyricsSpecs) -> Double {
            let r = specs.emphasizingScaleRange
            return r.lowerBound + (r.upperBound - r.lowerBound) * t
        }

        /// 一个字形层被强调的三相。
        enum Phase: Equatable {
            /// 还没轮到它。
            case idle
            /// 鼓着（`transform = MakeScale(s, s)`）。
            case grown
            /// 已经被按回去（`transform = 恒等`）。
            case shrunk
        }

        /// 一个字形层那**两条**弹簧的时刻。§1.1 第 9 条。
        ///
        /// 零点都是这个音节**开始高亮**的那一刻（`startTime`）——**不是唱完**。
        /// 放大与高亮同时起：两条延迟都是纯延迟
        /// （`stagger·i` 与 `span/(n/2) + stagger·i`），代码里没有 `end` 项，
        /// 下发时刻就是「这个音节成为当前音节」那一帧。
        struct Window: Equatable {
            /// 鼓起来那一刻。落 `MakeScale(scale, scale)`。
            var grow: TimeInterval
            /// 被写回恒等那一刻。下落不是一条曲线，是这次写值**覆盖**上一次。
            var shrink: TimeInterval
            /// 音节时长。弹簧的 ω 由它反解，窗口自带一份省得再从别处传。
            var span: TimeInterval
            /// 这一层鼓到多大。只有「唱住了」的音节才有窗口，所以这里就是区间上界；
            /// 门槛见 `windows(start:span:glyphCount:range:)`。
            var scale: Double

            /// 这个时刻该处在哪一相。
            func phase(at time: TimeInterval) -> Phase {
                if time < grow { return .idle }
                return time < shrink ? .grown : .shrunk
            }
        }

        /// 把**唱住了的**音节摊成 n 个字形层的时刻表。§1.1 第 6、9 条。
        ///
        /// **这个函数不做准入**：谁会进来由建层那一处唯一判据决定
        /// （`SBS_TextContentLayer+Layout` 里的 `held = splitsHeld && span > heldSyllableThreshold`，
        /// 与拆字形共用）。短音节根本不会调到这里，所以 `transform` 一次都不写。
        /// 上一版把「够不够长」写在这个函数里，于是它和拆字形各有一套判断，
        /// 改一处忘一处就会让短词也跳一下——那是上过机的坏版本。
        ///
        /// [实测] 逐字形循环里，`start` 是音节起点、`span` 是时长：
        /// ```
        /// stagger  = min(span / n × 0.4, 0.4)
        /// grow_i   = start + stagger · i
        /// shrink_i = start + span / (n/2) + stagger · i
        /// ```
        /// 两条都是**从下发那一刻起的纯延迟**（`stagger·i` 与
        /// `span/(n/2) + stagger·i`），没有任何 `end` 加法。
        /// 所以鼓包**跟高亮同时起步**，逐字形往右爬；先起的那几个在 `span/(n/2)`
        /// 之后就被收回按下去——这也是「峰值只有 +8% 而不是 1.14」的原因：
        /// 弹簧时长 `min(span, 3)` 往往还没走完，收回就已经来了（§1.1 第 8 条）。
        ///
        /// `span/(n/2)` 在 n = 1 时退化成 `2·span`（一个汉字的长音会鼓着不放两倍时长），
        /// 这里夹到 `span`。原版有没有这个夹没读到，`[推]`。
        static func windows(start: TimeInterval,
                            span: TimeInterval,
                            glyphCount: Int,
                            range: ClosedRange<Double>) -> [Window] {
            guard span > 0 else { return [] }
            let n = max(glyphCount, 1)
            let stagger = min(span / Double(n) * 0.4, 0.4)
            let hold = min(span / (Double(n) / 2), span)
            return (0..<n).map { i in
                Window(grow: start + stagger * Double(i),
                       shrink: start + hold + stagger * Double(i),
                       span: span,
                       scale: range.upperBound)
            }
        }

        /// 这条强调弹簧：**临界阻尼**（ζ = 1），角频率由音节时长反解。
        ///
        /// [实测] ζ = 1.0、`dur = min(span, 3.0)`：
        /// `mass = 1`、`ω = 2π/dur`、`k = m·ω²`、`c = 2·√(m·k)`——正是 ζ = 1，不弹。
        /// 所以短音节的弹簧很硬（0.4s → k ≈ 247、c ≈ 15.7），长音节被 3s 截顶。
        ///
        /// 注意这**不是** `SpringTimingParameters.syllableEmphasis`（1, 14, 7）——
        /// 那三个数属于逐字形那条管颜色/遮罩的弹簧。
        static func spring(span: TimeInterval) -> SpringAnimationParameters {
            let duration = min(max(span, 0.05), 3.0)
            let omega = 2 * Double.pi / duration
            return SpringAnimationParameters(mass: 1,
                                             stiffness: omega * omega,
                                             damping: 2 * omega)
        }

        /// 字形落点。
        ///
        /// [实测]：
        /// ```
        /// newX = (sw + scale·x + x) × 0.5
        /// newY = (sh + scale·y + y) × 0.25 − syllableLift
        /// ```
        /// `sw` / `sh` 是原始尺寸经`CGSize.scaled(by:)`（Music 的播放界面层扩展）之后的值。
        ///
        /// `newX` 化简得漂亮：`scale == 1` 时是`x + w/2`，**正是中心 x**，
        /// 所以这一对是喂给 `layer.position` 的。`newY` 的系数是 **0.25 不是 0.5**，
        /// 末尾还减一个 `syllableLift`——纵向用的显然不是「中心」这套基准（更像基线）。
        /// 算术是实测，纵向基准的语义 `[推]`。
        ///
        /// `syllableLift = 2` 到这里才落到实处：**它是直接从纵向落点里减掉的常量位移，
        /// 不是动画幅度**——被唱到的字形整体上抬 2pt，由弹簧把这 2pt 走完。
        static func glyphPosition(origin: CGPoint,
                                         scaledSize: CGSize,
                                         scale: Double,
                                         specs: LyricsSpecs) -> CGPoint {
            let x = (scaledSize.width + scale * origin.x + origin.x) * 0.5
            let y = (scaledSize.height + scale * origin.y + origin.y) * 0.25
                - specs.syllableLift
            return CGPoint(x: x, y: y)
        }
    }
}
