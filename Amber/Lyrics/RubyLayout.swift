import AppKit
import CoreText
import NaturalLanguage

/// 「发音贴在对应那几个字底下」的块排版。
///
/// [实测] 依据是 `LyricsSpecs` 的`transliterationMinWordSpacing`（实测 5）：
/// 整行式的发音副行不需要「词间距」这种量，这个字段的存在本身说明原版的发音是
/// **按词成块**摆的——块宽取 max(正文宽, 发音宽)，块与块之间至少留这么多。
/// 于是发音比正文宽的地方，正文被撑开：
///
/// ```
/// 私      だけの      モナリザ
/// watashi dake no     monariza
/// ```
///
/// 「私」一个字底下要放下 `watashi`，后面那一块就得往右让。整行式排版没有这回事。
///
/// 成块的粒度是**词**（`NLTokenizer` 的`.word`），不是音节：按音节成块的话每个字
/// 都被自己的罗马音撑开，整行散成一个个孤字。
///
/// 时间轴仍旧只有正文那一套——发音没有自己的时间，也不需要有：块与正文同 x 起点、
/// 共用一条推进遮罩，前沿扫到哪儿两层一起亮（见 `SBS_TextContentLayer+Layout`）。
enum RubyLayout {

    /// 一个块：正文的一个词，加上它自己的发音。
    struct Block {
        /// 正文。
        var text: String
        /// 发音。块内各音节的发音顺次拼起来；块里一个字都没注上音时为空串。
        var ruby: String
        /// 块内音节。`minX` / `width` 是**块内局部坐标**，与原模型
        /// `Syllable.frame` 的解法一致（行末公式会再加一次`word.frame.minX`）。
        var syllables: [Syllable]
        var textWidth: CGFloat = 0
        var rubyWidth: CGFloat = 0
        /// 正文的排版高度（ascent + descent + leading）。行高取行内各块的最大值——
        /// 落到回退字体的块（emoji、少数文字）比基础字体高，按 spec 字体算会切顶。
        var textHeight: CGFloat = 0
        /// 发音的排版高度，同上。
        var rubyHeight: CGFloat = 0

        /// 块占的横向步进：正文与发音里宽的那个。
        var advance: CGFloat { max(textWidth, rubyWidth) }

        struct Syllable {
            var text: String
            var startTime: TimeInterval
            var endTime: TimeInterval
            var minX: CGFloat = 0
            var width: CGFloat = 0
        }
    }

    /// 一个排版行：行内有哪些块、各自落在哪个 x。
    struct Row {
        var blocks: [(index: Int, x: CGFloat)] = []
        /// 行宽（末块的 x + 它的占位宽）。
        var width: CGFloat = 0
        /// 正文那一段的高度。
        var textHeight: CGFloat = 0
        /// 发音那一段的高度；0 表示这一行一个字都没注上音。
        var rubyHeight: CGFloat = 0
        /// 正文与发音之间的间距。[实测] `transliterationLineHeightAdjustment` = 5——
        /// 整行式那条副行拿它当行距，成块之后它就是这道缝。
        var spacing: CGFloat = 0

        var height: CGFloat { textHeight + (rubyHeight > 0 ? spacing + rubyHeight : 0) }
        var rubyTop: CGFloat { textHeight + spacing }
    }

    /// 从整条 `TextLine` 生成发音块：
    /// - 有逐字时间轴且音节自带发音时，直接按音节切块；
    /// - 只有行级发音（如普通 LRC 歌词配 `romalrc`）时，先将正文按字符/词切分为合成单元并对齐发音，
    ///   成功后再走同一套块测量与排版。对齐失败时返回 `[]`，由调用方退回整行副行。
    static func blocks(for line: TextLine,
                       specs: LyricsSpecs,
                       rubyFont: NSFont? = nil) -> [Block] {
        if !line.syllables.isEmpty,
           line.syllables.contains(where: { $0.transliteration?.isEmpty == false }) {
            return blocks(text: line.text, syllables: line.syllables,
                          specs: specs, rubyFont: rubyFont)
        }
        guard let roma = line.transliteration, !roma.isEmpty else { return [] }
        let baseSyllables: [LyricSyllable]
        if !line.syllables.isEmpty {
            baseSyllables = line.syllables.map {
                LyricSyllable(text: $0.text, time: $0.startTime,
                              duration: max(0, $0.endTime - $0.startTime))
            }
        } else {
            baseSyllables = LyricParser.segmentForTransliteration(line.text)
        }
        guard let attached = LyricParser.attachTransliteration(roma, to: baseSyllables)
        else { return [] }
        let timings = attached.map {
            TextLine.SyllableTiming(text: $0.text, startTime: $0.time, endTime: $0.end,
                                    transliteration: $0.transliteration)
        }
        return blocks(text: line.text, syllables: timings, specs: specs, rubyFont: rubyFont)
    }

    /// 把一行切成块。返回空数组表示这行不走 ruby 排版（没有音节级发音、
    /// 或者音节与正文对不上），调用方退回原来那条 TextKit 路径。
    /// `rubyFont` 是**发音真正会用的那一档**（`LyricsSpecs.secondaryFonts`）：
    /// 「更大字体」把两条副行的字号对调时，块宽必须按对调之后的字体量，
    /// 否则块被撑开的距离与画出来的发音对不上。不传就用 spec 的基线档。
    static func blocks(text: String,
                       syllables: [TextLine.SyllableTiming],
                       specs: LyricsSpecs,
                       rubyFont: NSFont? = nil) -> [Block] {
        guard !text.isEmpty,
              syllables.contains(where: { $0.transliteration?.isEmpty == false }),
              let ranges = SBS_TextContentLayer.syllableRanges(in: text, syllables: syllables),
              ranges.count == syllables.count
        else { return [] }

        let starts = wordStarts(in: text)
        let lineHasKana = text.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0x31F0...0x31FF).contains($0.value)
        }
        var blocks: [Block] = []
        var groups: [[Int]] = []            // 每组是落在同一个词里的音节下标

        var previousText = ""
        for (index, range) in ranges.enumerated() {
            // 音节起点正好是一个词的起点 → 开新块；否则跟着上一块走。
            // 落在词与词之间的字符（空格、标点）没有自己的词起点，于是自然
            // 并进前一块，不会单独撑出一个空块。
            //
            // 日语按词（`NLTokenizer` 的 `.word`）成块，上一块以促音或小书假名收尾、
            // 或连续片假名外来语（「モナリザ」）时不开新块；非假名行（粤语/普通话/韩语）
            // 每个带发音的音节各自成块，保证单字读音严丝合缝贴在对应那个字底下。
            let opensBlock: Bool
            if lineHasKana {
                opensBlock = starts.contains(range.lowerBound)
                    && !endsWithNonMoraicKana(previousText)
                    && !bothKatakana(previousText, syllables[index].text)
            } else {
                opensBlock = starts.contains(range.lowerBound)
                    || syllables[index].transliteration?.isEmpty == false
            }
            if groups.isEmpty || opensBlock {
                groups.append([index])
            } else {
                groups[groups.count - 1].append(index)
            }
            previousText = syllables[index].text
        }

        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let span = ranges[first].lowerBound..<ranges[last].upperBound
            let blockText = SBS_TextContentLayer.substring(
                text, utf16: NSRange(location: span.lowerBound,
                                     length: span.count))
            guard !blockText.isEmpty else { continue }

            let ruby = group
                .compactMap { syllables[$0].transliteration }
                .joined()
            var block = Block(text: blockText, ruby: ruby, syllables: [])

            // 块内落点走 CTLine：`CATextLayer` 自己排出来的宽度与 CTLine 的字距
            // 落点不一定一致，音节层的 x 必须和这里量的是同一套。
            let line = ctLine(blockText, font: specs.font)
            block.textWidth = offset(in: line, at: span.count)
            block.textHeight = typographicHeight(of: line)
            for index in group {
                let range = ranges[index]
                let x0 = offset(in: line, at: range.lowerBound - span.lowerBound)
                let x1 = offset(in: line, at: range.upperBound - span.lowerBound)
                block.syllables.append(Block.Syllable(text: syllables[index].text,
                                                      startTime: syllables[index].startTime,
                                                      endTime: syllables[index].endTime,
                                                      minX: x0,
                                                      width: max(x1 - x0, 0)))
            }
            if !ruby.isEmpty {
                let rubyLine = ctLine(ruby, font: rubyFont ?? specs.transliterationFont)
                block.rubyWidth = offset(in: rubyLine, at: (ruby as NSString).length)
                block.rubyHeight = typographicHeight(of: rubyLine)
            }
            blocks.append(block)
        }
        return blocks
    }

    /// 按块折行。
    ///
    /// [实测] `transliterationMinWordSpacing` = 5 是**发音之间**的最小间距，
    /// 不是块之间的恒定间距——步进取「正文紧排」与「发音留够间距」里大的那个：
    /// `x₊₁ = x + max(正文宽, 发音宽 + minWordSpacing)`。
    static func rows(for blocks: [Block],
                     width: CGFloat,
                     specs: LyricsSpecs,
                     rubyFont: NSFont? = nil) -> [Row] {
        guard width > 0, !blocks.isEmpty else { return [] }
        let effectiveRubyFont = rubyFont ?? specs.transliterationFont
        let spacing = specs.transliterationMinWordSpacing
        var result: [Row] = []
        var current = Row(spacing: specs.transliterationLineHeightAdjustment)
        var x: CGFloat = 0

        func flush() {
            guard !current.blocks.isEmpty else { return }
            current.width = current.blocks.last.map { $0.x + blocks[$0.index].advance } ?? x
            current.textHeight = LyricsTextLayout.rasterSafeHeight(
                current.blocks.map { blocks[$0.index].textHeight }.max() ?? 0,
                font: specs.font)
            let ruby = current.blocks
                .map { blocks[$0.index].rubyHeight }
                .max() ?? 0
            current.rubyHeight = ruby > 0
                ? LyricsTextLayout.rasterSafeHeight(ruby, font: effectiveRubyFont)
                : 0
            result.append(current)
            current = Row(spacing: specs.transliterationLineHeightAdjustment)
            x = 0
        }

        for (index, block) in blocks.enumerated() {
            if !current.blocks.isEmpty, x + block.advance > width { flush() }
            current.blocks.append((index: index, x: x))
            x += max(block.textWidth, block.rubyWidth + spacing)
        }
        flush()
        return result
    }

    // MARK: - 分词

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
    //
    // 开了 strict memory safety（SE-0458）之后**每读写一次就报一条**，逐处标的 `unsafe`
    // 就是这一条，含义一个字没变：**不安全在哪**——`nonisolated(unsafe)` 等于跟编译器说
    //「这个全局可变量的并发访问我自己负责」，真有第二个线程摸进来就是数据竞争；
    // **谁保证它安全**——上面那条实测。SDK 给 `CALayer` 补上 `@MainActor` 的那天，
    // 这行连同 `unsafe` 一起删。
    nonisolated(unsafe) private static var wordStartCache: [String: Set<Int>] = [:]

    /// 每个词在整行里的起始 UTF-16 下标。
    ///
    /// `NLTokenizer` 的`.word` 对日文按词切（「初めて」「の」「ルーブル」「は」），
    /// 正好是发音要成块的粒度。它不加载语言模型，可以留在主线程的排版路径上——
    /// 与 `LyricsTextLayout` 里刻意绕开的`NLLanguageRecognizer` 不是一回事。
    static func wordStarts(in text: String) -> Set<Int> {
        if let cached = unsafe wordStartCache[text] { return cached }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var starts: Set<Int> = []
        for token in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
            starts.insert(NSRange(token, in: text).location)
        }
        if unsafe wordStartCache.count > 512 { unsafe wordStartCache.removeAll(keepingCapacity: true) }
        unsafe wordStartCache[text] = starts
        return starts
    }

    /// 片假名连写是一个外来语词。分词器的词典里没有「モナリザ」这种，会切成
    /// 「モナ」+「リザ」，成块之后发音就排成 `mona riza`。两边都是片假名就不断块。
    private static func bothKatakana(_ previous: String, _ next: String) -> Bool {
        guard let last = previous.unicodeScalars.last,
              let first = next.unicodeScalars.first else { return false }
        return isKatakana(last) && isKatakana(first)
    }

    private static func isKatakana(_ scalar: Unicode.Scalar) -> Bool {
        (0x30A0...0x30FF).contains(scalar.value) || (0x31F0...0x31FF).contains(scalar.value)
    }

    /// 促音与小书假名（`っ` `ゃ` `ェ` …）以及长音符：它们自己不成一拍，
    /// 也就不可能是一个词的结尾，后面那一拍必须跟它同块。
    private static func endsWithNonMoraicKana(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        switch last.value {
        case 0x3041, 0x3043, 0x3045, 0x3047, 0x3049,        // ぁぃぅぇぉ
             0x3063,                                         // っ
             0x3083, 0x3085, 0x3087, 0x308E,                 // ゃゅょゎ
             0x3095, 0x3096,                                 // ゕゖ
             0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9,         // ァィゥェォ
             0x30C3,                                         // ッ
             0x30E3, 0x30E5, 0x30E7, 0x30EE,                 // ャュョヮ
             0x30F5, 0x30F6,                                 // ヵヶ
             0x30FC:                                         // ー
            return true
        default:
            return false
        }
    }

    // MARK: - 测量

    private static func ctLine(_ text: String, font: NSFont) -> CTLine {
        let attributes = LyricsTextLayout.attributes(for: text, font: font,
                                                     color: CGColor(gray: 1, alpha: 1))
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
    }

    private static func offset(in line: CTLine, at index: Int) -> CGFloat {
        CTLineGetOffsetForStringIndex(line, index, nil)
    }

    private static func typographicHeight(of line: CTLine) -> CGFloat {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        // CoreText 的 C 出参：三个形参都是 `UnsafeMutablePointer<CGFloat>?`，
        // 不安全在于要给三块能写 `CGFloat` 的内存。这里传的是本地 var 的地址，
        // 三个都在上一行刚声明、生命周期不出本函数、不逃逸。没有安全替代——
        // CoreText 整套就是 C API，`CTLine` 的度量只此一条路。
        unsafe CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return ascent + descent + leading
    }
}
