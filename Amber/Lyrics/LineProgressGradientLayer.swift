import QuartzCore

/// 逐字进度的「渐变扫过」。前沿是 30pt 的软边，不是硬切。
///
/// 对应 `LineProgressGradientLayer`。字段与顺序照原版排。
final class LineProgressGradientLayer: CALayer {

    enum Direction: Sendable { case leftToRight, rightToLeft }

    var color: CGColor?                       // +8
    var featherWidth: CGFloat = 16 {          // +16  specs.lineProgressionGradientFeather
        didSet {
            guard oldValue != featherWidth else { return }
            setNeedsLayout()
        }
    }
    var direction: Direction = .leftToRight   // +24
    /// [实测] §8.2：它是 `CGSize?`——宽、高、是 Optional 的
    /// tag 字节（即 nil）。宽高各有各的用处：
    /// 高度是渐变条的纵向外扩量，宽度只给 `horizontalPaddingLayer` 用。
    /// 先前记成一个 CGFloat 是错的。
    var outerPadding: CGSize?                 // +32（tag 在 +48）
    var horizontalPaddingLayer: CALayer?      // +56
    var gradientLayer: CAGradientLayer?       // +64
    var fillLayer: CALayer?                   // +72

    // 批次 7：垂直余量与已唱宽度见 LineProgressGradientGeometry（§7.3）。
    // 批次 8：三个子层的落位见 +Layout.swift 的 sublayerFrames(...)（§8.2）。
    // 实测：50pt 字号下 30pt ≈ 0.6 字宽，所以逐字染色的时间斜坡只该占音节时长的 0.6。
}

extension LineProgressGradientLayer {

    /// 建三个子层。软边条是 `CAGradientLayer`，另外两个是实心`CALayer`。
    ///
    /// 这一层在原版里同时当**遮罩**用：已唱的那份字形整层盖在未唱的上面，
    /// 靠它的 alpha 决定露出多少，所以软边条要做成 alpha 渐变而不是颜色渐变。
    func installSublayersIfNeeded() {
        guard gradientLayer == nil else { return }

        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer = gradient
        addSublayer(gradient)

        let fill = CALayer()
        fillLayer = fill
        addSublayer(fill)

        let padding = CALayer()
        horizontalPaddingLayer = padding
        addSublayer(padding)

        applyColors()
    }

    /// 实心部分不透明、软边条从不透明渐变到全透明；方向跟着 `direction` 翻。
    func applyColors() {
        let opaque = color ?? CGColor(gray: 1, alpha: 1)
        guard let clear = opaque.copy(alpha: 0) else { return }
        fillLayer?.backgroundColor = opaque
        horizontalPaddingLayer?.backgroundColor = opaque
        gradientLayer?.colors = direction == .rightToLeft
            ? [clear, opaque] : [opaque, clear]
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        installSublayersIfNeeded()

        let frames = Self.sublayerFrames(bounds: bounds,
                                         featherWidth: featherWidth,
                                         isRightToLeft: direction == .rightToLeft,
                                         outerPadding: outerPadding)
        // 子层不吃隐式动画：整层的宽度每帧都在变，子层跟着走就行，
        // 再叠一层默认的 0.25 秒 fade 只会把软边拖成糊的。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer?.frame = frames.gradient
        fillLayer?.frame = frames.fill
        if let padding = frames.horizontalPadding {
            horizontalPaddingLayer?.isHidden = false
            horizontalPaddingLayer?.frame = padding
        } else {
            horizontalPaddingLayer?.isHidden = true      //直接返回
        }
        CATransaction.commit()
    }
}
