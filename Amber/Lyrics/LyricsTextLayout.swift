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

    private static var languageCache: [String: String] = [:]

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
    }

    private static var wrapCache: [String: Wrapped] = [:]
    /// 每条缓存最后一次被用到的序号，LRU 淘汰按它排。
    private static var wrapCacheUse: [String: UInt64] = [:]
    private static var wrapCacheClock: UInt64 = 0
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
        guard !text.isEmpty, width > 0 else { return Wrapped(fragments: [], usedSize: .zero) }
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
        let wrapped = Wrapped(fragments: fragments,
                              usedSize: CGSize(width: min(ceil(used.width), width),
                                               height: used.height))
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
    static func hardWrapped(_ text: String,
                            attributes: [NSAttributedString.Key: Any],
                            width: CGFloat) -> NSAttributedString {
        let fragments = wrap(text, attributes: attributes, width: width).fragments
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
    static func size(_ text: String,
                     attributes: [NSAttributedString.Key: Any],
                     width: CGFloat) -> CGSize {
        guard !text.isEmpty, width > 0 else { return .zero }
        let wrapped = wrap(text, attributes: attributes, width: width)
        guard !wrapped.fragments.isEmpty else { return .zero }
        let font = attributes[.font] as? NSFont
        let height = font.map { rasterSafeHeight(wrapped.usedSize.height, font: $0) }
            ?? ceil(wrapped.usedSize.height)
        return CGSize(width: wrapped.usedSize.width, height: height)
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
