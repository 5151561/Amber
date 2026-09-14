import AppKit
import QuartzCore

/// 整行档的内容层（原版 `ContentKind.despacito`）：主行 + 翻译 + 音译三个文本层。
///
/// 只有整行时间的歌词走这条——没有逐字时间轴就没有渐变扫过可言，
/// 选中与否是一次整行换色。三条间距全部来自 `LyricsSpecs`：
/// `translationSpacing` 7、`translationBottomPadding` 4、
/// `transliterationLineHeightAdjustment` 5。
///
/// 换色的曲线用的是 §9.4 那条统一的行外观淡入淡出曲线（三处独立构造点一致）。
/// 原版这个类内部怎么切没走完 `[部分]`，这里按「和别处一样」取。`[推]`
final class TextContentLayer: CALayer, SyncedLyricsContentLayer {

    var specs = LyricsSpecs()
    var appearance: NSAppearance?
    var line: TextLine?

    private(set) var isSelected = false
    private(set) var isScrolling = false

    private let mainLayer = CATextLayer()
    private let translationLayer = CATextLayer()
    private let transliterationLayer = CATextLayer()

    override init() {
        super.init()
        // 倍率不能写死 2：外接 1× 屏上是浪费，真正的值由 `SyncedLyricsLineView`
        // 按窗口 `backingScaleFactor` 灌下来（见`LyricsRenderingScale`），
        // 这里先取主屏倍率兜底，免得还没上屏时子层停在 1×。
        contentsScale = LyricsRenderingScale.current
        for layer in [mainLayer, translationLayer, transliterationLayer] {
            layer.isWrapped = true
            layer.contentsScale = contentsScale
            layer.truncationMode = .none
            addSublayer(layer)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }

    // MARK: - 文本

    func setLine(_ line: TextLine?) {
        self.line = line
        refreshText()
    }

    /// 文字本身在 `layoutSublayers` 里落——折行结果要按当时的宽度算，
    /// 这里只更新可见性再请一次布局。
    private func refreshText() {
        translationLayer.isHidden = visibleTranslation == nil
        transliterationLayer.isHidden = visibleTransliteration == nil
        setNeedsLayout()
    }

    /// 副行过一道 spec 的显隐开关：关掉就当这行没有译文/发音，
    /// 于是测量、排版、行高三处一起变，重排出来的高度才对得上。
    /// 规则与逐字档共用，见 `LyricsSecondaryText.swift`。
    private var visibleTranslation: String? { specs.visibleTranslation(line?.translation) }

    private var visibleTransliteration: String? {
        specs.visibleTransliteration(line?.transliteration)
    }

    /// 把一段文字落到图层上并返回它占的尺寸。
    ///
    /// 交给图层的是**已经按 TextKit 断点加好硬换行**的字符串：`CATextLayer`
    /// 自己折行走 CoreText，不认 `lineBreakStrategy`，跟测量断得不一样时
    /// 多出来的那一行会被裁掉。
    @discardableResult
    private func assign(_ text: String?,
                        to layer: CATextLayer,
                        font: NSFont,
                        color: CGColor,
                        lineHeightAdjustment: CGFloat = 0,
                        width: CGFloat) -> CGSize {
        guard let text, !text.isEmpty, width > 0 else {
            layer.string = nil
            return .zero
        }
        let attributes = LyricsTextLayout.attributes(
            for: text, font: font, color: color,
            alignment: specs.lineTextAlignment,
            lineHeightAdjustment: lineHeightAdjustment)
        layer.string = LyricsTextLayout.hardWrapped(text, attributes: attributes, width: width)
        return LyricsTextLayout.size(text, attributes: attributes, width: width)
    }

    // MARK: - 颜色

    /// 三档：当前播放行始终 100%，浏览时其它行 40%，常态其它行 17.5%。
    private var mainColor: CGColor {
        let color: NSColor
        if isSelected {
            color = specs.selectedTextColor
        } else {
            color = isScrolling ? specs.deselectedScrollTextColor : specs.deselectedTextColor
        }
        return LyricsSpecs.cgColor(color, in: appearance)
    }

    /// [实测] `translationTextColor` 为 nil 表示继承主色。
    private var secondaryColor: CGColor {
        guard let color = specs.translationTextColor else { return mainColor }
        return LyricsSpecs.cgColor(color, in: appearance)
    }

    /// 两条副行的字号一起取：选档要同时看「同屏有没有音译」与「更大字体」偏好，
    /// 两条各问各的就会在偏好那一档上分岔。规则见 `LyricsSecondaryText.swift`。
    private var secondaryFonts: (translation: NSFont, transliteration: NSFont) {
        specs.secondaryFonts(for: line)
    }
    private var translationFont: NSFont { secondaryFonts.translation }
    private var transliterationFont: NSFont { secondaryFonts.transliteration }

    // MARK: - SyncedLyricsContentLayer

    func setSelected(_ selected: Bool, animated: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        applyColors(animated: animated)
    }

    func setScrolling(_ scrolling: Bool, animated: Bool) {
        guard scrolling != isScrolling else { return }
        isScrolling = scrolling
        applyColors(animated: animated)
    }

    func updateAppearance(specs: LyricsSpecs, appearance: NSAppearance?) {
        self.specs = specs
        self.appearance = appearance
        refreshText()
    }

    private func applyColors(animated: Bool) {
        let main = mainColor
        let secondary = secondaryColor
        let targets: [(CATextLayer, CGColor)] = [
            (mainLayer, main), (translationLayer, secondary), (transliterationLayer, secondary),
        ]
        guard animated else {
            for (layer, color) in targets { layer.foregroundColor = color }
            refreshText()
            return
        }
        let animator = LayerPropertyAnimator(curve: SyncedLyricsLineLayer.focusTransitionCurve)
        animator.layers = targets.map(\.0)
        for (layer, color) in targets {
            animator.addAnimation(to: layer, keyPath: "foregroundColor",
                                  from: layer.foregroundColor, to: color,
                                  frameRateRange: (min: 0, max: 0))
        }
        animator.finishDispatch {
            for (layer, color) in targets { layer.foregroundColor = color }
            self.refreshText()
        }
    }

    // MARK: - 几何

    func sizeThatFits(width: CGFloat) -> CGSize {
        guard width > 0 else { return .zero }
        var height: CGFloat = 0
        var used: CGFloat = 0

        let main = measure(line?.text, font: specs.font, width: width)
        height += main.height
        used = max(used, main.width)

        if let translation = visibleTranslation {
            let size = measure(translation, font: translationFont, width: width)
            height += specs.translationSpacing + size.height + specs.translationBottomPadding
            used = max(used, size.width)
        }
        if let transliteration = visibleTransliteration {
            let size = measure(transliteration,
                               font: transliterationFont,
                               lineHeightAdjustment: specs.transliterationLineHeightAdjustment,
                               width: width)
            height += specs.translationSpacing + size.height
            used = max(used, size.width)
        }
        return CGSize(width: used, height: height)
    }

    private func measure(_ text: String?,
                         font: NSFont,
                         lineHeightAdjustment: CGFloat = 0,
                         width: CGFloat) -> CGSize {
        guard let text, !text.isEmpty else { return .zero }
        return LyricsTextLayout.size(
            text,
            attributes: LyricsTextLayout.attributes(
                for: text, font: font, color: mainColor,
                alignment: specs.lineTextAlignment,
                lineHeightAdjustment: lineHeightAdjustment),
            width: width)
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        let width = bounds.width
        guard width > 0 else { return }
        var y: CGFloat = 0

        let main = assign(line?.text, to: mainLayer,
                          font: specs.font, color: mainColor, width: width)
        mainLayer.frame = CGRect(x: 0, y: y, width: width, height: main.height)
        y += main.height

        // 发音在上、翻译在下：发音是正文的读法，贴着正文才讲得通。
        // 逐字档那边（发音贴在字底下）就是这个次序，这条也得一致。
        let transliteration = assign(visibleTransliteration, to: transliterationLayer,
                                     font: transliterationFont, color: secondaryColor,
                                     lineHeightAdjustment: specs.transliterationLineHeightAdjustment,
                                     width: width)
        if transliteration.height > 0 {
            y += specs.translationSpacing
            transliterationLayer.frame = CGRect(x: 0, y: y, width: width,
                                                height: transliteration.height)
            y += transliteration.height
        }

        let translation = assign(visibleTranslation, to: translationLayer,
                                 font: translationFont, color: secondaryColor, width: width)
        if translation.height > 0 {
            y += specs.translationSpacing
            translationLayer.frame = CGRect(x: 0, y: y, width: width, height: translation.height)
        }
    }
}
