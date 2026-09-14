import AppKit

// 翻译 / 发音两条副行的三条共用规则。
//
// 逐字档（`SBS_TextContentLayer`）与整行档（`TextContentLayer`）各自把这三段
// 抄了一遍，字号选档那一句连注释都是重复的——两边一旦不同步，**测量与排版就会
// 各按各的算**：`sizeThatFits` 说有译文、`layoutSublayers` 说没有，行高与实际
// 内容当场对不上。放一处，两边都从 `specs` 上取。

extension LyricsSpecs {

    /// 译文那条副行过一道开关：关掉就当这行没有译文，
    /// 于是测量、排版、行高三处一起变，重排出来的高度才对得上。
    func visibleTranslation(_ text: String?) -> String? {
        guard showsTranslation, let text, !text.isEmpty else { return nil }
        return text
    }

    /// 发音那条副行的同款开关。
    ///
    /// 逐字档还要再过一道「发音有没有成块贴到字底下」——成块之后整行式那条就不要了
    /// （两条同时出现等于把同一份发音写两遍），那一道留在调用点上，不进这里。
    func visibleTransliteration(_ text: String?) -> String? {
        guard showsTransliteration, let text, !text.isEmpty else { return nil }
        return text
    }

    /// 这一行有没有音译——**贴在字底下的那种也算**。
    ///
    /// 不能只看行级的 `line.transliteration`：QQ 的 roma 能按音节归位时，
    /// `LyricParser.assemble` 会把行级那条清成 nil（`transliterationText = nil`），
    /// 发音只剩在音节上。只问行级的话，恰恰是**发音成块贴在字底下**的那些行
    /// 被判成「没有音译」，译文反而升到 15——实机上就是这么露的馅。
    func hasTransliteration(_ line: TextLine?) -> Bool {
        guard showsTransliteration, let line else { return false }
        if let text = line.transliteration, !text.isEmpty { return true }
        return line.syllables.contains { $0.transliteration?.isEmpty == false }
    }

    /// 译文字号的两档。选档条件是**同屏有没有音译**，与行宽、主字号都无关。
    ///
    /// [实测] 整行档与逐字档
    /// 各有一份同构代码，方向一致：
    ///
    /// ```
    /// mov  w8,  #0x110      ; translationSmallFont
    /// mov  w11, #0x118      ; translationLargeFont
    /// cmp  x9,  #0x0        ; x9 = transliterationText 的 _object
    /// csel x8,  x11, x8, eq ; nil → large
    /// ```
    ///
    /// 音译自己无条件用 `transliterationFont`，没有这道 csel。于是三行同屏是
    /// 26 Bold → 15 Semibold（音译）→ 12 Semibold（译文），只有主行 + 译文时
    /// 译文升到 15，补上音译空出来的那一档。
    ///
    /// 设置 › 通用 ›「更大字体」把这一道 csel 变成**可选方向**，见
    /// `secondaryFonts(hasTranslation:hasTransliteration:)`。
    func translationFont(hasTransliteration: Bool) -> NSFont {
        // 会问译文字号，说明这一行的译文要画——`hasTranslation` 恒真。
        secondaryFonts(hasTranslation: true, hasTransliteration: hasTransliteration).translation
    }

    /// 音译字号。「更大字体 = 发音」时守着大那一档（15，原版行为）；
    /// 「= 歌词」时一律让到小档，**与译文在不在屏上无关**。
    func transliterationFont(hasTranslation: Bool) -> NSFont {
        secondaryFonts(hasTranslation: hasTranslation, hasTransliteration: true).transliteration
    }

    /// **两条副行字号的唯一选档点。**
    ///
    /// 原版只有一道 csel（译文按「同屏有没有音译」二选一，音译无条件 15），
    /// 相当于恒定的「发音更大」。设置 › 通用 ›「更大字体」两档就是给这道 csel 定方向：
    ///
    /// | largerSecondary | 主行 + 译文 | 主行 + 发音 | 三行同屏 |
    /// | --- | --- | --- | --- |
    /// | `.pronunciation`（原版行为） | 译文 15 | 发音 15 | 发音 15 / 译文 12 |
    /// | `.lyrics` | 译文 15 | **发音 12** | 译文 15 / 发音 12 |
    ///
    /// **这一档管的是「歌词与发音同屏时谁更大」，译文不参与。** 选项自己的说明
    /// 就是这么写的（「同时显示时，选择要以更大字体显示歌词还是发音」），
    /// 两个选项也叫「歌词 / 发音」——里面没有「翻译」。
    ///
    /// 早先这里有一道 `guard hasTranslation, hasTransliteration`：只有**译文也在屏上**
    /// 时两档才分岔，于是最常见的那一屏（只开了发音、没开翻译）两档给出同一组字号，
    /// 切换选项画面一动不动——用户报的「歌词与发音大小都没变」就是这道闸。
    /// 译文那条二选一（同屏有发音就让到小档）留着，它是 [实测] 的原版行为。
    ///
    /// 让出去的小档直接取 `translationSmallFont`：它与`transliterationFont` /
    /// `translationLargeFont` 同为 TextStyle + bold trait（12 / 15 / 15），
    /// `scaleSecondaryFonts(by:)` 又按同一个倍率缩，所以整窗四档下这个「对调」
    /// 仍旧是同两个字号在换位，不会多出第三档。
    ///
    /// 主行（`specs.font`）**两档都不动**：把正文与发音整个对调是另一套排版
    /// （发音成块贴在字底下那条路会跟着翻），没有 `[实测]/[AX]` 依据之前不臆造。
    func secondaryFonts(hasTranslation: Bool,
                        hasTransliteration: Bool) -> (translation: NSFont, transliteration: NSFont) {
        switch largerSecondary {
        case .pronunciation:
            // 发音守着大档；译文只在与发音同屏时让到小档——这正是原版那道 csel。
            return (hasTranslation && hasTransliteration
                    ? translationSmallFont : translationLargeFont,
                    transliterationFont)
        case .lyrics:
            // 歌词更大：发音让到小档，译文补上空出来的大档。
            return (translationLargeFont, translationSmallFont)
        }
    }

    /// 按行取两条副行的字号。行内两条的显隐判定与测量、排版共用同一处，
    /// 免得「测量说有译文、排版说没有」那种两边各按各的算。
    func secondaryFonts(for line: TextLine?) -> (translation: NSFont, transliteration: NSFont) {
        secondaryFonts(hasTranslation: visibleTranslation(line?.translation) != nil,
                       hasTransliteration: hasTransliteration(line))
    }
}
