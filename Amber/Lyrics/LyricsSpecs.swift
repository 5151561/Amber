import AppKit

/// 同步歌词的外观参数包。
///
/// 对应 Music 里 880 字节的 `LyricsSpecs`，79 个字段，声明顺序与偏移见
/// `歌词参数布局笔记`。
///
/// 下面每条的 `[实测]` 表示该取值是对着 Music 量出来的，不是推的。
// 装着 NSFont / NSColor，不是 Sendable；跨线程用请自行隔离。
struct LyricsSpecs {

    enum RenderingMode: Sendable { case synced, `static` }
    enum FocusStyle: Sendable { case bright, dark }

    /// 当前行在可视区里的落点。三个 case 与原枚举一致。
    ///
    /// [实测] 三个带载荷 case、没有空 case（§17.3）。载荷区是 `CGRect` 32 字节，
    /// 枚举 tag 打包在紧随其后那个字节的 bit 7-6，bit 0 是 `Optional<CGRect>` 自己的 tag：
    ///
    /// | 字节 | bit7-6 | case | bit0 |
    /// | --- | --- | --- | --- |
    /// | `0x00`–`0x3F` | `00` | `top` | — |
    /// | `0x40`–`0x7F` | `01` | `topRelative` | — |
    /// | `0x80` | `10` | `center` | 0 = `rect` 有值 |
    /// | `0x81` | `10` | `center` | 1 = `rect == nil` |
    enum SelectedLinePosition: Sendable {
        case top(CGFloat)
        case topRelative(CGFloat, cardHeightPercentage: CGFloat)
        /// `rect` 是**可选**的。nil 表示「用 `scrollView.frame`」。
        case center(rect: CGRect?)
    }

    // MARK: 排版

    var renderingMode: RenderingMode = .synced                    //[实测]
    var displayScale: CGFloat = 1.0                               //[实测]
    var firstLineStartingPosition: CGFloat = 60                   //[实测]
    /// [实测] 基线值实测自构造：
    /// 载荷 `(12.0, 0.0)`、tag 字节`0x40` ⇒ **`.topRelative(12, cardHeightPercentage: 0)`**
    /// （§17.3；早先记成 `.top(12)`，两者在`scrollOrigin` 里行为相同）。
    var selectedLinePosition: SelectedLinePosition =
        .topRelative(12, cardHeightPercentage: 0)                 //[实测]
    var staticTopContentInset: CGFloat = 22                       //[实测]
    var staticBottomContentInset: CGFloat = 30                    //[实测]
    var paragraphSpacing: CGFloat = 39                            //[实测]
    var lineTextAlignment: NSTextAlignment? = nil                 //[实测] nil = natural
    var songwritersTextAlignment: NSTextAlignment? = nil          //[实测]
    var lineSpacing: CGFloat = 25                                 //[实测]
    var backgroundVocalsTopSpacing: CGFloat = 15                  //[实测]
    var backgroundVocalsDeselectedTransform =
        CGAffineTransform(scaleX: 0.90, y: 0.90)                         //[实测]
    var lineDelay: TimeInterval = 0.05                            //[实测] 逐行错开
    var maxEndTimeOffset: TimeInterval = 0.5                      //[实测] 唱完后的选中宽限
    var maxSelectedLines: Int = 2                                 //[实测] 可同时选中两行
    var fontLeading: CGFloat? = nil                               //[实测]

    // MARK: 字体
    //
    // 七处 TextStyle 字体后面**都还有一道** `fontDescriptorWithSymbolicTraits: 2`
    // （`.bold`），一处不落——旧结论只记了 TextStyle，把 trait 整个丢了。
    // 唯一不走 Dynamic Type 的是背景和声的译文（`systemFont(ofSize: 14, weight: .bold)`）。
    //
    // **不要把 trait 换算成硬编码的 weight**：`.bold` trait 在 ≤15pt 上被 SF 解析成
    // Semibold（[PX] 本机实测），26pt 的正文才解析成 Bold。所以「正文 Bold、副行
    // Semibold」不是两套字重，是同一条 trait 链在不同 optical size 上的解析结果；
    // 写死 `.semibold` 在辅助功能放大字号之后就与原版分岔了。

    /// [实测] `.largeTitle` + `.bold` trait。macOS 上约 26pt，解析成 Bold。
    var font: NSFont = LyricsSpecs.bold(.preferredFont(forTextStyle: .largeTitle))
    /// [实测] `.title2` + `.bold` trait。
    var backgroundVocalsFont: NSFont =
        LyricsSpecs.bold(.preferredFont(forTextStyle: .title2))
    var writtenByFont: NSFont = .systemFont(ofSize: 22)           //[实测]
    var songwritersNamesFont: NSFont = .systemFont(ofSize: 22)    //[实测]
    var emphasizingScaleRange: ClosedRange<Double> = 1.0...1.14   //[实测]

    /// [实测] `.callout` + `.bold` trait ⇒ 本机 12pt`.SFNS-Semibold`。
    /// 同屏**有**音译时的译文档，选档规则见 `LyricsSecondaryText.swift`。
    var translationSmallFont: NSFont =
        LyricsSpecs.bold(.preferredFont(forTextStyle: .callout))
    /// [实测] `.title3` + `.bold` trait ⇒ 本机 15pt`.SFNS-Semibold`。
    /// 同屏**没有**音译时的译文档：这一行只剩主行 + 译文，译文升到音译那一档。
    var translationLargeFont: NSFont =
        LyricsSpecs.bold(.preferredFont(forTextStyle: .title3))
    /// [实测] 全表唯一不走 Dynamic Type 的一处：固定 14pt，weight 直接给 `.bold`
    /// （不是 trait），所以它不随辅助功能字号变。
    var translationFontBackgroundVocals: NSFont =
        .systemFont(ofSize: 14, weight: .bold)
    var translationSpacing: CGFloat = 7                           //[实测]
    var translationBottomPadding: CGFloat = 4                     //[实测]
    /// [实测] `.title3` + `.bold` trait ⇒ 本机 15pt`.SFNS-Semibold`。
    /// 音译**无条件**用这一个，没有译文那道二选一。
    var transliterationFont: NSFont =
        LyricsSpecs.bold(.preferredFont(forTextStyle: .title3))
    /// [实测] `.subheadline` + `.bold` trait ⇒ 本机 11pt`.SFNS-Semibold`。
    var transliterationFontBackgroundVocals: NSFont =
        LyricsSpecs.bold(.preferredFont(forTextStyle: .subheadline))
    var transliterationLineHeightAdjustment: CGFloat = 5          //[实测]
    var transliterationMinWordSpacing: CGFloat = 5                //[实测]
    /// `.footnote` + `.bold` trait。`[推]` 这一处是按「七道 trait 一处不落」补的：
    /// 结构里的 TextStyle 字体正好七个，另外六个的 trait 都是实测。
    var automaticallyCreatedDisclaimerFont: NSFont =
        LyricsSpecs.bold(.preferredFont(forTextStyle: .footnote))

    // MARK: 颜色
    //
    // 原版每个颜色都是 `NSColor(name:dynamicProvider:)`，provider 只判断是否高对比度
    // 辅助功能外观：命中 → labelColor 系，未命中（平时）→ whiteColor 系，只调 alpha。
    // 所以常规状态下歌词恒为白。`_x` 那一半是原结构里缓存解析结果的字段，复刻不需要。

    var selectedTextColor = LyricsSpecs.dynamicWhite(1.00, highContrast: 1.00)    //[实测]
    var selectedUpcomingTextColor = LyricsSpecs.dynamicWhite(0.35, highContrast: 0.85) //[实测]
    var deselectedTextColor = LyricsSpecs.dynamicWhite(0.175, highContrast: 0.40) //[实测]
    var selectedBackgroundVocalsTextColor = LyricsSpecs.dynamicWhite(1.00, highContrast: 1.00)
    var selectedUpcomingBackgroundVocalsTextColor = LyricsSpecs.dynamicWhite(0.35, highContrast: 0.85)
    var deselectedScrollTextColor = LyricsSpecs.dynamicWhite(0.40, highContrast: 0.40) //[实测] 拖动时全部行
    var translationTextColor: NSColor? = nil                      //[实测] nil = 继承主色
    var lineProgressionGradientColor = LyricsSpecs.dynamicWhite(1.00, highContrast: 1.00)   //[实测]
    var lineProgressionBackgroundVocalsGradientColor =
        LyricsSpecs.dynamicWhite(0.175, highContrast: 0.175)             //[实测]

    // MARK: 动效

    var deselectedTransform = CGAffineTransform(scaleX: 0.98, y: 0.98) //[实测]
    var animationHeadstart: TimeInterval = 0.1                    //[实测] 比时间轴提前起跑
    var glowColor: NSColor = .white                               //[实测]
    var glowRadius: CGFloat = 5                                   //[实测]
    var glowRange: ClosedRange<Double> = 0...0.4                  //[实测] 逐词强度
    var lineProgressionGradientFeather: CGFloat = 16              // 软边宽度（从 30 收窄到 16，保留流光感同时减轻音节滞后）
    var touchDownTransform = CGAffineTransform(scaleX: 0.95, y: 0.95) //[实测]

    // MARK: 悬停 / 点击

    var highlightLabelAlpha: CGFloat = 0.85                       //[实测] 是「提到」不是「压到」
    var highlightViewBackgroundColor = NSColor(white: 1.0, alpha: 0.08) //[实测]
    var highlightViewCornerRadius: CGFloat = 16                   //[实测]
    var highlightViewMargin: CGFloat = 16                         //[实测]

    // MARK: 间奏

    var instrumentalBreakCountdownDotCount: Int = 3               //[实测]
    var instrumentalBreakViewHeight: CGFloat = 40                 //[实测]
    var instrumentalBreakDotLength: CGFloat = 12                  //[实测]
    var instrumentalBreakDotMargin: CGFloat = 8                   //[实测]

    // MARK: 逐字

    /// 被唱到的音节上抬多少。
    ///
    /// ASM 里读出来的是 **2**；[PX] 对着播放中的 Music 逐像素量，已唱字比未唱高
    /// **3.5…4.2pt**（半高顶端 +3.50、质心 +4.21，`AM-ANTI/Reports/lyrics-logic.md`
    /// 那一节），两者之差当时归因给取样字形的上沿不同。实机对比后取实测区间的中值
    /// **4**——ASM 那个 2 是在 Music 自己的字形落点公式里减掉的，
    /// Amber 没有字形层、减在音节层上，同一个数字给出的观感并不等价。
    var syllableLift: CGFloat = 4                                 //[PX] .lift 能力
    var vocalGroupWidthCoefficient: CGFloat = 0.85                //[实测]
    var lineTapProgressFreezeDuration: TimeInterval = 0.1         //[实测]
    var lineFinishProgressAnimationDuration: TimeInterval = 0.25  //[实测] 行末补完剩余进度

    // MARK: 开关

    /// 副行的显隐。`[补]` 原结构里没有这两个字段——Music 是把开关记在
    /// `lyricsFeatureDefaults` / `lyricsTranslationLocale` 那边、再驱动歌词视图；
    /// Amber 把它落在 spec 上，这样「显隐」与「行高」走同一条重排路径，
    /// 才谈得上 `showTranslationTransliterationSpringParameters` 那条弹簧。
    var showsTranslation = true
    var showsTransliteration = true

    /// 设置 › 通用 ›「更大字体」：**歌词与发音同屏时发音占哪一档**
    /// （`.pronunciation` → 大档 15，`.lyrics` → 小档 12）。译文不参与这道选择，
    /// 它只按原版那道 csel 与发音互补。
    /// `[补]` 原结构里同样没有这个字段——原版是一道写死的 csel（译文让给发音），
    /// 等价于这里的 `.pronunciation`，所以默认值取它，不带偏好时逐像素与原版一致。
    /// 选档规则集中在 `LyricsSecondaryText.secondaryFonts(hasTranslation:hasTransliteration:)`。
    var largerSecondary: LargerTextTarget = .pronunciation

    var showsVerticalScrollIndicator = true                       //[实测]
    var lineBlurEnabled = true                                    //[实测]
    var hidePreviousLines = false                                 //[实测]
    var snapScrollToLines = false                                 //[实测]
    var focusStyle: FocusStyle = .bright                          //[实测]
    var autoSnapAfterScroll = false                               //[实测]

    // MARK: 弹簧

    var lineChangeSpringTimingParameters =
        SpringTimingParameters(mass: 1, stiffness: 100, damping: 18)     //[实测]
    var showTranslationTransliterationSpringParameters =
        SpringAnimationParameters(mass: 1, stiffness: 150, damping: 30)  //[实测]
    var hideTranslationTransliterationSpringParameters =
        SpringAnimationParameters(mass: 1, stiffness: 130, damping: 30)  //[实测]

    init() {}

    /// 叠 bold trait（原版的 `fontDescriptorWithSymbolicTraits: 2`）。取不到粗体时退回原字体。
    ///
    /// 字重**只走这条 trait 链**，不要在外面换算成 `systemFont(ofSize:weight:)`：
    /// SF 按 optical size 解析同一道 trait，26pt 给 Bold、≤15pt 给 Semibold，
    /// 写死某一档在辅助功能放大字号之后就与原版分岔。
    /// 也不要用 `fontDescriptor.addingAttributes(.weight)`——那条路拿到的是
    /// `.SFNS-Heavy` 这种**拉丁字体实例**，中日文 fallback 到 PingFang 时字重传不过去。
    static func bold(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.bold)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// 只换字号，descriptor（含上面那道 bold trait）原样带走。
    /// 不能重新走一遍 `bold(.preferredFont(...))`——那条路又回到 Dynamic Type，
    /// 拿不到整窗那几档固定字号。
    static func resized(_ font: NSFont, to size: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: size) ?? font
    }

    /// 把五处副行字体按同一个倍率换档。**只换字号，留白不跟。**
    ///
    /// 整窗播放器专用：主行按 `TextStyles.plist` 的 28/38/50/72 落档，副行不跟着走
    /// 的话，72pt 的正文底下压着一条 12pt 的译文，宽度拉再大也不动。
    /// [资源] 10205–10208 给出整窗副行的四档 13/17/20/24，这里让
    /// `transliterationFont`（基线 15）正好落到那个数，倍率由它反解，
    /// 其余四处按同一倍率跟着走。
    ///
    /// **按倍率缩、不逐个写死**，是为了保住 `translationFont(hasTransliteration:)`
    /// 那道 csel：两档译文（12 / 15）的差距按比例留着，同屏有没有音译仍然选得出档。
    /// 直接把两档都写成 `secondarySize` 等于把选档抹平。
    mutating func scaleSecondaryFonts(by scale: CGFloat) {
        guard scale > 0, scale != 1 else { return }
        func scaled(_ font: NSFont) -> NSFont {
            Self.resized(font, to: (font.pointSize * scale).rounded())
        }
        translationSmallFont = scaled(translationSmallFont)
        translationLargeFont = scaled(translationLargeFont)
        translationFontBackgroundVocals = scaled(translationFontBackgroundVocals)
        transliterationFont = scaled(transliterationFont)
        transliterationFontBackgroundVocals = scaled(transliterationFontBackgroundVocals)
        // **只动字号，留白一概不动。** `translationSpacing` 7 /
        // `transliterationLineHeightAdjustment` 5 是实测的绝对值，发音本来就该
        // 贴着正文；跟着倍率放大等于在正文与发音之间硬塞一道缝，一眼就看得出来。
    }

    /// 把动态色解析成 `CGColor`。`CALayer` 不吃`NSColor`，而这些色的 provider
    /// 要看外观（高对比度辅助功能外观下换 `labelColor`），所以必须指定外观来解析。
    static func cgColor(_ color: NSColor, in appearance: NSAppearance?) -> CGColor {
        guard let appearance else { return color.cgColor }
        var resolved = color.cgColor
        appearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }

    /// 平时用 white 调 alpha，高对比度辅助功能外观下换 labelColor。
    /// 对应原版的 `bestMatch(from: [AccessibilityHighContrastAqua, AccessibilityHighContrastDarkAqua])`。
    static func dynamicWhite(_ alpha: CGFloat, highContrast: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isHighContrast = appearance.bestMatch(from: [
                .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ]) != nil
            return isHighContrast
                ? NSColor.labelColor.withAlphaComponent(highContrast)
                : NSColor.white.withAlphaComponent(alpha)
        }
    }
}
