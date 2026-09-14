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

        // 实心部分：严格贴合 bounds，盖的是已经唱过的字，不会再被强调放大。
        let fill = CGRect(x: isRightToLeft ? featherWidth : min(0, w - featherWidth),
                          y: 0,
                          width: max(0, w - featherWidth),
                          height: h)

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

        /// 强调缩放。**一条直线，没有缓动**——缓动全交给
        /// `SpringTimingParameters.syllableEmphasis`（1, 14, 7）那条弹簧。
        ///
        /// [实测]：`lo + (hi − lo) × t`。
        static func scale(progress t: Double, specs: LyricsSpecs) -> Double {
            let r = specs.emphasizingScaleRange
            return r.lowerBound + (r.upperBound - r.lowerBound) * t
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
