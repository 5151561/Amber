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

    /// 渲染档。**触发条件与 Music 不同。**
    ///
    /// 本仓的注释一路把 `.static` 说成「侧栏那一档」——那是 Music 的用法：
    /// 同一份带时间轴的词，在侧栏检查器里退化成不可交互的静态排版。
    /// Amber 把它**重新定义**为「这份词没有时间轴」（`[LyricLine].isUntimed`，
    /// 整份都是无戳纯文本），侧栏照旧走 `.synced`。
    ///
    /// 渲染契约是同一套（整份铺开、统一亮度、用户自己滚、不高亮不自动滚
    /// 不点击跳转），换的只是谁来打开它。所以八个判据点原样复用，不改值。
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

    /// 主字体：**`boldSystemFont(24)`**，不走 Dynamic Type。
    ///
    /// [实测] 结构体默认值在 `+0xe0` 写的是 `.largeTitle` + bold（≈26），
    /// 但主 surface 的 provider（`（略）` @（略））无条件覆写成
    /// `boldSystemFont(24.0)`。**生效的是 24** —— 上一版取了 `.largeTitle`，
    /// 比原版大 8%。
    ///
    /// 副行的 `+0xf0/+0xf8` 则被改写成 `.callout` + bold（见 `translationSmallFont`），
    /// 「更大字体」那条 `scaleSecondaryFonts` 只动副行，与原版一致。
    var font: NSFont = .boldSystemFont(ofSize: 24)
    /// [实测] `.title2` + `.bold` trait。
    var backgroundVocalsFont: NSFont =
        LyricsSpecs.bold(.preferredFont(forTextStyle: .title2))
    var writtenByFont: NSFont = .systemFont(ofSize: 22)           //[实测]
    var songwritersNamesFont: NSFont = .systemFont(ofSize: 22)    //[实测]

    /// 演唱中那个音节的放大系数。
    ///
    /// [实测] 结构体 `+0x100`（lower 1.0）/ `+0x108`（upper 1.14），
    /// `（略）` L306 的 `hScale = lower + t·(upper − lower)`。
    /// `t` 是**该音节自身的归一化进度**，不是 emphasis 强度——两者不要串。
    ///
    /// **这个数不写字形几何。** 2026-10-27 与 Music.app 同帧对拍，原版整行字宽 / 字重
    /// 全程不变；本仓曾把它接到音节层 `transform`，结果整行「越唱越大」，与截图不符。
    /// 现在只剩两个不画字的消费者：
    /// 渐变层纵向余量 `|ascent·1.14 + 2·glowRadius − h| / 2`（`（略）`）、
    /// 辉光层 `rasterizationScale`（放大后栅格不糊）。
    var emphasizingScaleRange: ClosedRange<Double> = 1.0...1.14   //[实测] +0x100/+0x108

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
    // 原版每个颜色都是 `NSColor(name:dynamicProvider:)` + 外层 `withAlphaComponent`。
    // **provider 里返回什么是由宿主给的**：resolver 的默认值返回「平时 white /
    // 高对比度 labelColor」，但主 surface 的 provider 一律返回 `labelColor`，
    // 于是明暗跟随系统、只剩 alpha 在变。两套都在二进制里，生效的是后者。
    // `_x` 那一半是原结构里缓存解析结果的字段，复刻不需要。

    // [实测] 主 surface 的 provider（`（略）`）把这一组**整段换掉**：
    // 全部是 `labelColor` 加不同 alpha，不再有 white 那一支。原来那套
    // 「平时 white / 高对比度换 labelColor」是 resolver（W1 默认值）的写法，
    // 运行时并不生效——上一版照默认值抄，未唱 0.35、普通行 0.175，
    // 比原版暗了一大截（生效值是 0.50 / 0.40）。
    //
    // 顺带修掉一个真实缺陷：white 系在浅色外观下等于「白字白底」，
    // 换成 labelColor 后自动跟随明暗。
    var selectedTextColor = LyricsSpecs.dynamicLabel(1.00)        //+0x168
    var selectedUpcomingTextColor = LyricsSpecs.dynamicLabel(0.50) //+0x178
    var deselectedTextColor = LyricsSpecs.dynamicLabel(0.40)      //+0x188
    var selectedBackgroundVocalsTextColor = LyricsSpecs.dynamicLabel(0.65)          //+0x198
    var selectedUpcomingBackgroundVocalsTextColor = LyricsSpecs.dynamicLabel(0.45)  //+0x1a8
    var deselectedScrollTextColor = LyricsSpecs.dynamicLabel(0.40) //+0x1b8 拖动时全部行
    var translationTextColor: NSColor? = nil                      //+0x1d8 = labelColor，nil = 继承主色
    /// 已唱段的颜色。`+0x1e8` 在主 surface 是 `labelColor @65%`，
    /// 但「谁画已唱、谁画未唱」这条映射还挂着（`lyrics-spec.md` §6 O5），
    /// 改成 0.65 有可能把已唱/未唱**反过来**，所以先留 1.00 等 O5 闭合。
    var lineProgressionGradientColor = LyricsSpecs.dynamicLabel(1.00)   //[待 O5]
    /// 背景和声的渐变条颜色。**这一项没有在原版里定位到写入点**（provider 只写了
    /// `+0x1e8` 那一处渐变），沿用手上的旧实测值，等和声行真正开始渲染时再查。`[未查]`
    var lineProgressionBackgroundVocalsGradientColor =
        LyricsSpecs.dynamicWhite(0.175, highContrast: 0.175)

    // MARK: 动效

    /// 未选中行的缩放。**主 surface 是单位阵**：provider（（略））把它覆盖成
    /// identity，消费者 `setSelected:`（（略））读到什么就打在整行 layer 上。
    /// 0.98 只是 resolver 的默认值，别的 surface 才可能用它。
    var deselectedTransform = CGAffineTransform.identity
    var animationHeadstart: TimeInterval = 0.1                    //[实测] 比时间轴提前起跑
    var glowColor: NSColor = .white                               //[实测]
    var glowRadius: CGFloat = 5                                   //[实测]
    var glowRange: ClosedRange<Double> = 0...0.4                  //[实测] 逐词强度

    /// 已唱段与未唱段之间那条定宽软边的宽度。
    ///
    /// [实测] 结构体 `+0x250` 的字面量是 **30.0**，`（略）`（渐变层布局）
    /// 把它同时用作渐变条宽与 fill 的扣减量。本仓曾收窄到 16，注释理由是
    /// 「减轻音节滞后」——那是产品手调，不是原版值，本轮按结构体改回 30。
    /// 短行会命中 `（略）` 里的 `max(W − feather, 0)`，fill 宽夹到 0 即可。
    var lineProgressionGradientFeather: CGFloat = 30              //[实测] +0x250
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
    /// [实测] 结构体 `+0x2d0` 读出来是 2.0，但那个数在 `（略）` 里是按
    /// **字形落点**的坐标系算的：`newY = (sh + scale·y + y) × 0.25 − syllableLift`
    /// 里的 y 已经是「相对词基线的一组候选落点」，减 2 落在那一套里只是微调。
    /// [PX] 对着播放中的 Music 逐像素量，已唱字比未唱高 **3.5…4.2pt**
    /// （半高顶端 +3.50、质心 +4.21，`AM-ANTI/Reports/lyrics-logic.md`），
    /// 而且 2026-10-27 的用户对拍复核仍是这个量级——**原版没有可见的字形放大**
    /// （`emphasizingScaleRange` 只用于渐变纵向余量 / 栅格化倍率，不写 `transform`），
    /// 所以抬升就是纯平移、不能再指望被缩放「补」出来。
    ///
    /// 本仓没有字形层、抬升减在音节层上，取实测区间的中值 4 ≈ 原版观感。`[PX]`
    var syllableLift: CGFloat = 4                                 //[PX] .lift 能力
    /// 长音门槛：一个逐字单元唱满**超过**这么久，就逐字母抬升并发辉光。
    ///
    /// 产品指定的值，不是对着 Music 量出来的。数据侧（`LyricsAdapter.synthesizeEmphasis`）
    /// 与建层侧（`SBS_TextContentLayer.appendSyllableLayers`）共用这一份，所以是静态的。
    static let heldSyllableThreshold: TimeInterval = 1.0          //[推] 产品指定
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

    /// 翻行 / 焦点位让位用的弹簧。`(mass 1, stiffness 100, damping 18)`
    ///
    /// [实测] 解析器 `（略）` 里这一组不走 `CASpringAnimation`，
    /// 而是 `（略）` 打包成 timing 值存进 `+0x2f8`（`scrollLead` 因此可解析求值）。
    var lineChangeSpringTimingParameters =
        SpringTimingParameters(mass: 1, stiffness: 100, damping: 18)     //[实测] +0x2f8

    /// 副行展开 / 收起。`(1, 150, 30)` 与 `(1, 130, 30)`
    ///
    /// [实测] 解析器里这两组各自 new 了一个 `CASpringAnimation` 只为取 `settlingDuration`，
    /// 存进 `+0x310` / `+0x338`。阻尼比分别 1.22 / 1.32，都是过阻尼——落到终点不回弹。
    var showTranslationTransliterationSpringParameters =
        SpringAnimationParameters(mass: 1, stiffness: 150, damping: 30)  //[实测] +0x310
    var hideTranslationTransliterationSpringParameters =
        SpringAnimationParameters(mass: 1, stiffness: 130, damping: 30)  //[实测] +0x338

    /// 悬停底板的进出弹簧。`进 (2, 300, 50)` / `出 (1, 322, 24)`
    ///
    /// [实测] `（略）`（`setHighlighted:` 实体）里的立即数：
    /// `0x4000000000000000`/`0x4072c00000000000`/`0x4049000000000000` 进出两组。
    /// 进入更"弹"（mass 2、damping 50），退出更脆（mass 1、damping 24），不要共用一套。
    var hoverHighlightSpringIn = SpringAnimationParameters(mass: 2, stiffness: 300, damping: 50)
    var hoverHighlightSpringOut = SpringAnimationParameters(mass: 1, stiffness: 322, damping: 24)

    /// 悬停时底板与文字的透明度过渡曲线。
    ///
    /// [实测] 同一函数里那组五元组（进入 `0.25 / 0 / 0.55 / 1.0 / 0.2`），
    /// 语义 `[推]`：按本仓 `LyricsAnimationCurve` 的 `custom` 四控制点 + 时长落地。
    /// 光靠弹簧驱动透明度会有肉眼可见的回弹，原版把这两件事拆成两条动画。
    var hoverHighlightTransitionCurve = LyricsAnimationCurve.custom(
        CGPoint(x: 0.33, y: 0), CGPoint(x: 0.2, y: 0.1), duration: 0.12)

    /// 一次翻行滚动跑完要多久。`[补]`
    ///
    /// 全模块只有这一个「一次翻行的量」：焦点位提前它这么久让位、句间空档比它窄时
    /// 把弹簧压进空档、间奏行两头各留它这么宽的进出场余量（`LyricsAdapter`）。
    /// 三处必须是同一个数，所以收到这里算一次，别各自去读弹簧。
    ///
    /// **不要放进每帧路径**：`settlingDuration` 每次都现造一个`CASpringAnimation`。
    /// 按帧读的那一份存在 `SyncedLyricsManager.Configuration.scrollLead`。
    var scrollLead: TimeInterval { lineChangeSpringTimingParameters.settlingDuration }

    /// 紧邻句或极窄空档（`gap < fastHandoverSpringDuration`）换行时的快速弹簧结算时长。`[补]`
    var fastHandoverSpringDuration: TimeInterval = 0.38

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

    /// `labelColor` 加 alpha。对应原版
    /// `NSColor(name:dynamicProvider: { _ in labelColor }).withAlphaComponent(a)`。
    /// 原版把 alpha 套在 dynamic 色**外面**；这里放进 provider 里面，
    /// 保证每次按外观解析时拿到的一定是「当次外观的 labelColor × alpha」——
    /// 外层套 alpha 是否保留动态性依赖 AppKit 实现，放里面没有这个不确定性。
    /// 主 surface 的六个文字色全部走这一个。
    static func dynamicLabel(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { _ in NSColor.labelColor.withAlphaComponent(alpha) }
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
