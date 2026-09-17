import AppKit
import CoreText

/// 内容层共用的排版工具。
///
/// 原版这一层落在 Music 播放界面层的的文本组件里，没有定性到这一层；这里只做行几何
/// （`sizeThatFits:`）真正需要的那点事：
/// 按可用宽度折行、按折行结果测高、把 `LyricsSpecs` 的字体与对齐翻成属性字典。`[补]`
///
/// **折行一律交给系统 TextKit**（`NSLayoutManager` 的行片段），不自己实现断词。
/// 断点由三样东西决定：段落样式的 `lineBreakStrategy`、文本的
/// `languageIdentifier`、以及字体与可用宽度。
enum LyricsTextLayout {

    // MARK: - 断行规则

    /// [实测] 段落样式的 `lineBreakStrategy` 读出来是 rawValue 3，
    /// 即 `[.pushOut, .hangulWordPriority]`。
    ///
    /// 注意 **CoreText 的 `CTTypesetterSuggestLineBreak` 不认这个字段**
    /// （实测同一段韩文在两条路径下断点不同），所以折行必须走 TextKit。
    static let lineBreakStrategy: NSParagraphStyle.LineBreakStrategy =
        [.pushOut, .hangulWordPriority]

    /// [实测] `lineTextAlignment` / `songwritersTextAlignment` 都是`NSTextAlignment?`，
    /// nil 表示 natural（跟随书写方向）。
    /// 段落对齐 → `CATextLayer.alignmentMode`。
    ///
    /// **两处都要设。** `CATextLayer` 排属性串时认的是自己的 `alignmentMode`，
    /// 段落样式里的 `alignment` 它不看——只设属性串那一份，layer 仍按默认的
    /// `.natural` 贴左（对唱翻转侧的翻译副行就是这么掉队的）。
    static func alignmentMode(_ alignment: NSTextAlignment?) -> CATextLayerAlignmentMode {
        switch alignment {
        case .center: return .center
        case .right: return .right
        case .justified: return .justified
        default: return .natural
        }
    }

    static func paragraphStyle(alignment: NSTextAlignment?,
                               lineHeightAdjustment: CGFloat = 0,
                               tallScriptOutsets: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment ?? .natural
        style.lineBreakMode = .byWordWrapping
        style.lineBreakStrategy = lineBreakStrategy
        // [实测] `transliterationLineHeightAdjustment = 5`：音译行的行高加这么多。
        // 超高字符（藏文 / 天城文等）另外补一份字体外延，见 `tallScriptOutsets(for:font:)`。
        style.lineSpacing = lineHeightAdjustment + tallScriptOutsets
        return style
    }

    /// 一段文本的完整属性。语言标识与超高字符的行距补偿都按这段文本自己算。
    static func attributes(for text: String,
                           font: NSFont,
                           color: CGColor,
                           alignment: NSTextAlignment? = nil,
                           lineHeightAdjustment: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .white,
            .paragraphStyle: paragraphStyle(
                alignment: alignment,
                lineHeightAdjustment: lineHeightAdjustment,
                tallScriptOutsets: tallScriptOutsets(for: text, font: font)),
        ]
        // CJK 的字形选择与断点开关。中文不设的话字形和断点都跟官方不一样。
        if let language = languageIdentifier(for: text) {
            attributes[.languageIdentifier] = language
        }
        return attributes
    }

    // MARK: - 语言标识

    // 下面几张表标 `nonisolated(unsafe)`，理由与代价都写在这里，别当橡皮擦看：
    //
    // 事实：它们只在主线程的排版路径上被摸。[实测 2026-09-17] 在歌词那 5 个
    // `layoutSublayers` 覆写里插 `dispatchPrecondition(condition: .onQueue(.main))`，
    // 装机后带歌词播放 35 秒，一次都没触发。
    //
    // 那为什么不用 `@MainActor` 把这件事写出来——试过了，走不通：调用方是
    // `SBS_TextContentLayer` 那一族 `CALayer` 子类，而 SDK 里 `CALayer` 没有
    // `@MainActor` 标注（`NSView` 有，所以视图层没这问题）。给子类标上之后，
    // `layoutSublayers` / `init()` 这些覆写仍然跟着父类是非隔离的，体内一碰 `self`
    // 就是「sending 'self'」——问题只是从这里挪到了那里。
    //
    // 所以 SDK 给 `CALayer` 补上 `@MainActor` 之前，这里只能是断言而不是证明。
    nonisolated(unsafe) private static var languageCache: [String: String] = [:]

    /// 按文本自身的字符判语言（BCP-47）。拉丁 / 西里尔返回 nil——
    /// 这个属性是给 CJK 与南亚 / 东南亚文字用的，拉丁文本设不设都一样。
    ///
    /// 原版的语言来自歌词数据（每首歌带语言字段），Amber 的音源不给，只能自己认。
    static func languageIdentifier(for text: String) -> String? {
        guard !text.isEmpty else { return nil }
        if let cached = languageCache[text] { return cached.isEmpty ? nil : cached }
        let resolved = resolveLanguage(text)
        if languageCache.count > 512 { languageCache.removeAll(keepingCapacity: true) }
        languageCache[text] = resolved ?? ""
        return resolved
    }

    private static func resolveLanguage(_ text: String) -> String? {
        var hasHan = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF: return "ja"   // 平假名 / 片假名
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return "ko"  // 谚文
            case 0x0590...0x05FF: return "he"
            case 0x0600...0x06FF, 0x0750...0x077F: return "ar"
            case 0x0900...0x097F: return "hi"                     // 天城文
            case 0x0980...0x09FF: return "bn"
            case 0x0A00...0x0A7F: return "pa"
            case 0x0A80...0x0AFF: return "gu"
            case 0x0B00...0x0B7F: return "or"
            case 0x0B80...0x0BFF: return "ta"
            case 0x0C00...0x0C7F: return "te"
            case 0x0C80...0x0CFF: return "kn"
            case 0x0D00...0x0D7F: return "ml"
            case 0x0D80...0x0DFF: return "si"
            case 0x0E00...0x0E7F: return "th"
            case 0x0E80...0x0EFF: return "lo"
            case 0x0F00...0x0FFF: return "bo"                     // 藏文
            case 0x1000...0x109F: return "my"
            case 0x1780...0x17FF: return "km"
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: hasHan = true
            default: continue
            }
        }
        // 只有汉字：一律按简体。简繁只影响少数变体字形，而这条路在**主线程的排版里**，
        // 每行都要走一次——`NLLanguageRecognizer` 会在这儿同步加载 CoreNLP / Espresso
        // 的模型（实测能在 `recomputeLineFrames` 里卡住主线程），代价远超那点收益。
        return hasHan ? "zh-Hans" : nil
    }

    // MARK: - 超高字符的行距补偿

    /// 藏文、天城文这类字符会越过基础字体的 ascent / descent，原版给这些行的行距
    /// 加一份 `CTFontGetLanguageAwareOutsets` 的上 + 下外延。
    ///
    /// 那是私有 SPI，这里用公开 API 等价换算：取真正承载这些字形的回退字体
    /// （`CTFontCreateForString`），把它超出基础字体的那部分补进行距。
    /// 纯中英文命不中这张表，返回 0。
    static func tallScriptOutsets(for text: String, font: NSFont) -> CGFloat {
        guard let scalar = text.unicodeScalars.first(where: { isTallScript($0.value) }) else {
            return 0
        }
        let sample = String(scalar) as CFString
        let fallback = CTFontCreateForString(
            font, sample, CFRange(location: 0, length: CFStringGetLength(sample)))
        let above = max(0, CTFontGetAscent(fallback) - font.ascender)
        let below = max(0, CTFontGetDescent(fallback) - abs(font.descender))
        return ceil(above + below)
    }

    /// 天城文起、缅甸文止的那一段南亚 / 东南亚文字，外加藏文。
    private static func isTallScript(_ value: UInt32) -> Bool {
        switch value {
        case 0x0900...0x0DFF, 0x0E00...0x0FFF, 0x1000...0x109F, 0x1780...0x17FF: return true
        default: return false
        }
    }

    // MARK: - 折行（TextKit）

    /// 一个排版行片段。`range` 是在整段文本里的 UTF-16 范围。
    struct Fragment: Equatable {
        var range: NSRange
        /// 片段自己占的宽度（不含行末空白）。
        var usedWidth: CGFloat
        /// 片段占的高度，含段落样式给的行距。
        var height: CGFloat
    }

    struct Wrapped {
        var fragments: [Fragment]
        /// 整段折完后占的尺寸，宽是各片段用宽的最大值。
        var usedSize: CGSize
        /// `CATextLayer` 画这段硬换行文本要多高（CoreText 的口径，见 `size`）。
        ///
        /// 跟折行结果一起算、一起进缓存：`size` 被行几何对全表每行调用、一次翻行至少
        /// 两遍，而 `CTFramesetter` 建一次 0.134 ms，与 TextKit 折行同量级——
        /// 那一条早就有缓存了，这一条没道理每次现算。
        ///
        /// **只缓存高度，不缓存那串字。** 文本的度量与颜色无关，而 `cacheKey`
        /// 里没有颜色（也不该有，否则每换一次明暗就是一条新缓存）——
        /// 把 `hardWrapped` 的产物也存进来的话，后来的调用方会拿到**第一个**
        /// 调用方那份属性串，颜色跟着串走（`CATextLayer` 拿属性串时
        /// `foregroundColor` 不生效），副行就会永远停在行几何量它时用的那个色上。
        var drawnHeight: CGFloat
    }

    nonisolated(unsafe) private static var wrapCache: [String: Wrapped] = [:]
    /// 每条缓存最后一次被用到的序号，LRU 淘汰按它排。
    nonisolated(unsafe) private static var wrapCacheUse: [String: UInt64] = [:]
    nonisolated(unsafe) private static var wrapCacheClock: UInt64 = 0
    /// 上限。一行要缓存正文 + 翻译 + 发音三条，原来的 256 在**行数过 85 的歌**上
    /// 会在同一次 `recomputeLineFrames` 的循环中途被撑满——而原来的处置是
    /// `removeAll`，等于把这一轮前面刚算好的全丢掉，下一轮再从头算一遍，
    /// 缓存反而成了负担。
    static let wrapCacheLimit = 1024

    /// 按可用宽度折行。宽度非正时直接返回空——与行几何
    /// 那条「可用宽度非正就整段跳过」一致。
    static func wrap(_ text: String,
                     attributes: [NSAttributedString.Key: Any],
                     width: CGFloat) -> Wrapped {
        guard !text.isEmpty, width > 0 else {
            return Wrapped(fragments: [], usedSize: .zero, drawnHeight: 0)
        }
        let key = cacheKey(text: text, attributes: attributes, width: width)
        if let cached = wrapCache[key] { touchWrapCache(key); return cached }

        let storage = NSTextStorage(string: text, attributes: attributes)
        let manager = NSLayoutManager()
        manager.usesFontLeading = true
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0        // 不限行数、不截断、不缩字号
        container.lineBreakMode = .byWordWrapping
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        var fragments: [Fragment] = []
        var glyphIndex = 0
        while glyphIndex < manager.numberOfGlyphs {
            var glyphRange = NSRange()
            let used = manager.lineFragmentUsedRect(forGlyphAt: glyphIndex,
                                                    effectiveRange: &glyphRange)
            let full = manager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let characters = manager.characterRange(forGlyphRange: glyphRange,
                                                    actualGlyphRange: nil)
            fragments.append(Fragment(range: characters,
                                      usedWidth: used.width,
                                      height: full.height))
            glyphIndex = NSMaxRange(glyphRange)
        }

        let used = manager.usedRect(for: container)
        // 折出不止一行时才问 CoreText：单行两边给的高度一样，老路更省。
        let drawn = fragments.count > 1
            ? drawnHeight(of: assembleHardWrapped(text: text, fragments: fragments,
                                                  attributes: attributes),
                          width: width)
            : used.height
        let wrapped = Wrapped(fragments: fragments,
                              usedSize: CGSize(width: min(ceil(used.width), width),
                                               height: used.height),
                              drawnHeight: drawn)
        wrapCache[key] = wrapped
        touchWrapCache(key)
        evictWrapCacheIfNeeded()
        return wrapped
    }

    private static func touchWrapCache(_ key: String) {
        wrapCacheClock &+= 1
        wrapCacheUse[key] = wrapCacheClock
    }

    /// 真正的淘汰：超上限就按访问序号丢掉最旧的一半，而不是整张表清空。
    /// 丢一半（不是一条）是为了不让每次插入都触发一轮排序。
    private static func evictWrapCacheIfNeeded() {
        guard wrapCache.count > wrapCacheLimit else { return }
        let victims = wrapCacheUse
            .sorted { $0.value < $1.value }
            .prefix(wrapCache.count / 2)
        for (key, _) in victims {
            wrapCache.removeValue(forKey: key)
            wrapCacheUse.removeValue(forKey: key)
        }
    }

    private static func cacheKey(text: String,
                                 attributes: [NSAttributedString.Key: Any],
                                 width: CGFloat) -> String {
        let font = attributes[.font] as? NSFont
        let style = attributes[.paragraphStyle] as? NSParagraphStyle
        let language = attributes[.languageIdentifier] as? String ?? ""
        // 断行策略必须进 key：它换了断点就换，漏掉的话第二种策略会命中第一种的缓存。
        return [
            text,
            font?.fontName ?? "",
            String(describing: font?.pointSize ?? 0),
            String(style?.lineBreakStrategy.rawValue ?? 0),
            String(describing: style?.lineSpacing ?? 0),
            String(style?.alignment.rawValue ?? -1),
            language,
            String(describing: width),
        ].joined(separator: "\u{1}")
    }

    /// 把 TextKit 的断点固化成硬换行，再交给 `CATextLayer`。
    ///
    /// 图层自己折行走的是 CoreText，**不认 `lineBreakStrategy`**；测量按 TextKit
    /// 的行数算、渲染按 CoreText 断的话，多断出来的那一行会被图层边界裁掉。
    /// 每个片段都已经能放下，加硬换行后图层不会再断第二次。
    ///
    /// **每次按调用方自己的属性现拼**，不进缓存：同一段文字会被不同的明暗各要一次
    /// （行几何量它时用白色、落到图层上时用当前行色），而属性串里的颜色会盖过
    /// `CATextLayer.foregroundColor`。存一份共用的话，副行就永远停在第一次那个色上。
    static func hardWrapped(_ text: String,
                            attributes: [NSAttributedString.Key: Any],
                            width: CGFloat) -> NSAttributedString {
        let fragments = wrap(text, attributes: attributes, width: width).fragments
        return assembleHardWrapped(text: text, fragments: fragments, attributes: attributes)
    }

    private static func assembleHardWrapped(
        text: String,
        fragments: [Fragment],
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        guard fragments.count > 1 else {
            return NSAttributedString(string: text, attributes: attributes)
        }
        let ns = text as NSString
        let pieces = fragments.map { fragment -> String in
            ns.substring(with: fragment.range)
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        return NSAttributedString(string: pieces.joined(separator: "\n"), attributes: attributes)
    }

    // MARK: - 测量

    /// `CATextLayer` 不是按`boundingRect` 的墨迹框裁剪，而是按字体的排版框放置
    /// baseline。部分字体的字形会越过 descender（SF Bold 26pt 约越过 1.68pt）；
    /// 如果图层高度恰好等于排版高度，最下面一两个像素就会被图层边界截掉。
    ///
    /// 用字体全局字形框算出需要补给 `CATextLayer` 的垂直安全区，并整点向上取整，
    /// 避免 Retina 像素取整再次吃掉边缘。这个值只用于图层外框，不改变字号或基线。
    static func verticalRasterPadding(for font: NSFont) -> CGFloat {
        let glyphBounds = font.boundingRectForFont
        let overflowAbove = max(0, glyphBounds.maxY - font.ascender)
        let overflowBelow = max(0, font.descender - glyphBounds.minY)
        return ceil(overflowAbove + overflowBelow)
    }

    static func rasterSafeHeight(_ height: CGFloat, font: NSFont) -> CGFloat {
        ceil(height) + verticalRasterPadding(for: font)
    }

    /// 按给定宽度折行后要占多大。宽度非正时直接返回零。
    ///
    /// **折成几行问 TextKit，行与行隔多远问 CoreText。** 两边对同一段中文的行距不一样：
    /// [实测 2026-09-16] 50pt 的「一天到晚命令王宮裡的裁縫師們，替他做各種不同款式的新衣」
    /// 折 3 行，TextKit 的 `usedRect` 报 150（每行 50——它按**真正落到行上的字体**算，
    /// 中文回退到苹方，50pt 行高正好 50），而 `CATextLayer` 画出来是 174
    /// （每行 58.89——CoreText 的行距取**基准字体**，SF 50pt 是 48.34 + 10.55）。
    /// 行框按 150 建、图层按 174 画，最后那一行就有小半行在框外被裁掉。
    /// 纯文本歌词（散文，动辄三四行）一眼就能看见；唱词那种一两行的只啃掉一点 descender。
    ///
    /// **别试着用段落样式把行高钉死**：`minimumLineHeight` / `maximumLineHeight`
    /// `CTFramesetter` 是认的（钉到 50 之后 suggest 回 150），但 **`CATextLayer` 不认**
    /// ——钉完照旧按 58.89 画（实测把图层渲进位图数行，三行的墨迹带仍是 19–106 /
    /// 137–232 / 255–…）。它与「`CATextLayer` 认 `alignmentMode`、不认段落对齐」是同一族坑。
    ///
    /// 所以**只有折出不止一行时**才改问 CoreText：单行没有「行与行」可言，
    /// 两边给的高度本来就一样，走老路，既有的行距规格一点不动。
    static func size(_ text: String,
                     attributes: [NSAttributedString.Key: Any],
                     width: CGFloat) -> CGSize {
        guard !text.isEmpty, width > 0 else { return .zero }
        let wrapped = wrap(text, attributes: attributes, width: width)
        guard !wrapped.fragments.isEmpty else { return .zero }
        let laidOut = wrapped.drawnHeight
        let font = attributes[.font] as? NSFont
        let height = font.map { rasterSafeHeight(laidOut, font: $0) } ?? ceil(laidOut)
        return CGSize(width: wrapped.usedSize.width, height: height)
    }

    /// `CATextLayer` 画这串硬换行的字要多高——直接问画它的那个引擎。
    /// 入参必须是已经加好硬换行的那一份（`hardWrapped` 的产物），
    /// 不然 CoreText 会按自己的断点再折一次，数出来的行数就不是屏上那几行。
    private static func drawnHeight(of string: NSAttributedString, width: CGFloat) -> CGFloat {
        let setter = CTFramesetterCreateWithAttributedString(string)
        return CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil).height
    }

    /// 一行文字的墨高（ascent + descent，**不含 leading**）。
    /// [实测]就是 `CTFontGetAscent + CTFontGetDescent`，
    /// §7.3 的渐变纵向余量用的就是它。
    ///
    /// 未接线：`LineProgressGradientGeometry.verticalPadding` 自己算了同一个量，
    /// 没有绕到这里。留着记那 13 条指令的结论。
    static func inkHeight(of font: NSFont) -> CGFloat {
        font.ascender + abs(font.descender)
    }
}
