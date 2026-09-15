import AppKit
import QuartzCore

// 「发音贴在对应那几个字底下」的排版路径。块的切分与测量在 `RubyLayout`，
// 这里只把块折成排版行、建层、落位。
//
// 与 TextKit 那条路的分工：正文一旦被发音撑开，断点就不再是 TextKit 按文本算出来的
// 那些——块整个不可拆，折行只能按块贪心。所以这条路自己折行，不走
// `LyricsTextLayout.wrap`。发音开关关掉时`rubyBlocks` 为空，一切原样走老路，
// 排版结果一个像素都不变。
//
// 高亮不另起一套：发音层与正文层同挂在 `row.base` / `row.sung` 下，共用那一条
// 推进遮罩。于是前沿是一条竖线同时扫过正文和它底下的发音——比整行式那条
// 「按词数折算比例」精确得多，也不必给发音编一份它本来没有的时间轴。

extension SBS_TextContentLayer {

    /// 一个排版行：行内有哪些块、各自落在哪个 x。
    struct RubyRow {
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

    /// 按块折行。
    ///
    /// [实测] `transliterationMinWordSpacing` = 5是**发音之间**的最小间距，
    /// 不是块之间的恒定间距——两者差别很大：恒定间距会让每个块都多占 5pt，
    /// 一行八个块就凭空多出 35pt，本来一行放得下的句子被挤成两行。
    ///
    /// 所以步进取「正文紧排」与「发音留够间距」里大的那个：
    ///
    /// ```
    /// x₊₁ = x + max(正文宽, 发音宽 + minWordSpacing)
    /// ```
    ///
    /// 发音比正文窄的块（多数汉字词都是）步进就是正文宽，正文保持紧排，
    /// 只有发音真的要挤到一起时才把后面顶开。
    func rubyRows(width: CGFloat) -> [RubyRow] {
        guard width > 0, !rubyBlocks.isEmpty else { return [] }
        let spacing = specs.transliterationMinWordSpacing
        var result: [RubyRow] = []
        var current = RubyRow(spacing: specs.transliterationLineHeightAdjustment)
        var x: CGFloat = 0

        func flush() {
            guard !current.blocks.isEmpty else { return }
            // 行宽按末块的**占位宽**算，不带它身后那点给下一块留的间距。
            current.width = current.blocks.last.map { $0.x + rubyBlocks[$0.index].advance } ?? x
            current.textHeight = LyricsTextLayout.rasterSafeHeight(
                current.blocks.map { rubyBlocks[$0.index].textHeight }.max() ?? 0,
                font: specs.font)
            let ruby = current.blocks
                .map { rubyBlocks[$0.index].rubyHeight }
                .max() ?? 0
            current.rubyHeight = ruby > 0
                ? LyricsTextLayout.rasterSafeHeight(ruby, font: transliterationFontForMeasuring)
                : 0
            result.append(current)
            current = RubyRow(spacing: specs.transliterationLineHeightAdjustment)
            x = 0
        }

        for (index, block) in rubyBlocks.enumerated() {
            // 放不下就换行；一行只有一个块时再宽也得留着，不然会丢内容。
            // 判断用的是「它作为行末时占多宽」，不含给后面留的那点间距。
            if !current.blocks.isEmpty, x + block.advance > width { flush() }
            current.blocks.append((index: index, x: x))
            x += max(block.textWidth, block.rubyWidth + spacing)
        }
        flush()
        return result
    }

    /// 重排（块排版）。与 TextKit 那条同构：每个排版行一组 base/sung 图层，
    /// 逐字时间轴分到各行，最后落一次进度。
    func rebuildRuby(width: CGFloat) {
        let layoutRows = rubyRows(width: width)
        guard !layoutRows.isEmpty, let line else { return }

        let baseColor = LyricsSpecs.cgColor(self.baseColor, in: appearance)
        let rubyColor = LyricsSpecs.cgColor(translationColor, in: appearance)
        let sungColor = LyricsSpecs.cgColor(specs.lineProgressionGradientColor, in: appearance)
        let isRightToLeft = line.agentAlignment == .flipped
        // 块是按**词**切的（`RubyLayout` 用`NLTokenizer` 的`.word`），一个块里可能
        // 有好几个音节，而强调载荷在原版是词级的（§23.6）。`RubyLayout.Block.Syllable`
        // 不带这个字段，所以按起点回查 `line.syllables`——两边的时间是同一份拷贝，
        // 不存在浮点漂移。
        let emphasisByStart = Dictionary(
            line.syllables.map { ($0.startTime, $0.emphasis) },
            uniquingKeysWith: { first, second in
                first.factor >= second.factor ? first : second
            })

        var y: CGFloat = 0
        for layout in layoutRows {
            let row = Row()
            row.frame = CGRect(x: 0, y: y, width: layout.width, height: layout.height)
            row.textHeight = layout.textHeight
            row.base.frame = row.frame
            row.sung.frame = row.frame
            insertSublayer(row.base, at: 0)
            insertSublayer(row.sung, above: row.base)

            let layoutLine = SyncedLyricsLineLayer.LayoutLine()
            layoutLine.frame = row.frame
            layoutLine.isRightToLeft = isRightToLeft
            layoutLine.animationKind = .gradient
            layoutLine.text = layout.blocks.map { rubyBlocks[$0.index].text }.joined()

            for entry in layout.blocks {
                let block = rubyBlocks[entry.index]
                // 一个块就是原模型里的一个 Word——这一次名副其实：块是按词切的，
                // 词里可以有好几个音节，而不是老路上「一个音节顶一个词」。
                var word = SyncedLyricsLineLayer.Word()
                word.text = block.text
                word.index = layoutLine.words.count
                let wordFrame = CGRect(x: entry.x, y: 0,
                                       width: block.advance, height: layout.textHeight)
                word.frame = wordFrame
                word.originalFrame = wordFrame
                // 一个块（词）一份强调载荷：块内音节里最强的那个。词是辉光与强调缩放
                // 的单位（§23.3 / §8.1），块里各音节得到同一份强度才不会一个字亮
                // 一个字不亮地撕开。
                word.emphasis = block.syllables
                    .compactMap { emphasisByStart[$0.startTime] }
                    .max { $0.factor < $1.factor } ?? .none

                for syllable in block.syllables {
                    // Syllable/Glyph 的 frame 是 **Word 内局部坐标**：行末公式
                    // （§7.3 `finishedWidth`）会再加一次`word.frame.minX`。
                    let localFrame = CGRect(x: syllable.minX, y: 0,
                                            width: syllable.width, height: layout.textHeight)
                    var glyph = SyncedLyricsLineLayer.Glyph()
                    glyph.text = syllable.text
                    glyph.frame = localFrame
                    glyph.originalFrame = localFrame

                    var unit = SyncedLyricsLineLayer.Syllable()
                    unit.text = syllable.text
                    unit.startTime = syllable.startTime
                    unit.endTime = syllable.endTime
                    unit.frame = localFrame
                    unit.originalFrame = localFrame
                    unit.glyphs = [glyph]
                    word.syllables.append(unit)

                    row.syllables.append(makeSyllableLayers(
                        text: syllable.text,
                        frame: CGRect(x: entry.x + syllable.minX, y: 0,
                                      width: syllable.width, height: layout.textHeight),
                        base: baseColor, sung: sungColor,
                        emphasis: word.emphasis, row: row))
                }
                layoutLine.words.append(word)

                // 发音整块一层：它没有自己的逐字时间，也不该有——遮罩扫到哪儿它就
                // 亮到哪儿，切成音节反而要给它编一份假时间轴。
                guard !block.ruby.isEmpty, layout.rubyHeight > 0 else { continue }
                row.ruby.append(makeTextLayers(
                    text: block.ruby,
                    frame: CGRect(x: entry.x, y: layout.rubyTop,
                                  width: block.rubyWidth, height: layout.rubyHeight),
                    font: transliterationFontForMeasuring,
                    base: rubyColor, sung: sungColor, row: row))
            }

            layoutLine.startTime = layoutLine.words.first?.syllables.first?.startTime
                ?? line.startTime
            layoutLine.endTime = layoutLine.words.last?.syllables.last?.endTime ?? line.endTime
            layoutLine.hasEmphasis = layoutLine.words.contains { !$0.emphasis.isNone }

            row.gradient.color = sungColor
            row.gradient.featherWidth = specs.lineProgressionGradientFeather
            row.gradient.direction = isRightToLeft ? .rightToLeft : .leftToRight
            // 纵向余量按**正文**高度算：它的语义是「强调放大到 1.14 与半径 5 的辉光
            // 会超出正文多少」，跟底下多出来的那条发音无关。遮罩本身仍按整盒铺，
            // 不然扫过的时候发音那一层露不出来。
            row.gradient.outerPadding = CGSize(
                width: specs.lineProgressionGradientFeather,
                height: LineProgressGradientGeometry.verticalPadding(
                    font: specs.font, lineHeight: layout.textHeight, specs: specs))
            row.gradient.frame = CGRect(x: 0, y: 0, width: 0, height: layout.height)
            row.sung.mask = row.gradient
            row.sung.opacity = (isSelected || isSungPrepared) ? 1 : 0

            rows.append(row)
            layoutLines.append(layoutLine)
            y += layout.height
        }
    }
}
