import AppKit
import CoreText
import QuartzCore

// 逐字内容层的排版。一条歌词可能折成几行，原版把「排版意义上的一行」叫
// `LayoutLine`（§7.1，存自己的 frame）——这里就按它来：
// 先让 TextKit 把整行折成几段，再把逐字时间轴按字符范围分到各段上。

extension SBS_TextContentLayer {

    // MARK: - 测量

    func sizeThatFits(width: CGFloat) -> CGSize {
        guard width > 0, let line, !line.text.isEmpty else { return .zero }
        // 发音成块时正文被撑开，折行结果与 TextKit 那条完全不同——量高也得走块。
        let ruby = rubyRows(width: width)
        var used: CGFloat
        var height: CGFloat
        if ruby.isEmpty {
            let rows = Self.measureRows(text: line.text, font: specs.font, width: width)
            used = rows.map(\.width).max() ?? 0
            height = rows.map(\.height).reduce(0, +)
        } else {
            used = ruby.map(\.width).max() ?? 0
            height = ruby.map(\.height).reduce(0, +)
        }

        if let translation = visibleTranslation {
            let size = LyricsTextLayout.size(
                translation,
                attributes: LyricsTextLayout.attributes(for: translation,
                                                        font: translationFontForMeasuring,
                                                        color: CGColor(gray: 1, alpha: 1),
                                                        alignment: specs.lineTextAlignment),
                width: width)
            height += specs.translationSpacing + size.height + specs.translationBottomPadding
            used = max(used, size.width)
        }
        if let transliteration = visibleTransliteration {
            let size = LyricsTextLayout.size(
                transliteration,
                attributes: LyricsTextLayout.attributes(
                    for: transliteration,
                    font: transliterationFontForMeasuring,
                    color: CGColor(gray: 1, alpha: 1),
                    alignment: specs.lineTextAlignment,
                    lineHeightAdjustment: specs.transliterationLineHeightAdjustment),
                width: width)
            height += specs.translationSpacing + size.height
            used = max(used, size.width)
        }
        return CGSize(width: min(used, width), height: height)
    }

    /// 副行过一道 spec 的显隐开关，与整行档同解（规则见 `LyricsSecondaryText.swift`）。
    var visibleTranslation: String? { specs.visibleTranslation(line?.translation) }

    /// 整行式的那条发音副行。发音已经成块贴到字底下时就不要它了——
    /// 两条同时出现等于把同一份发音写两遍。
    var visibleTransliteration: String? {
        guard rubyBlocks.isEmpty else { return nil }
        return specs.visibleTransliteration(line?.transliteration)
    }

    /// 两条副行的字号一起取（规则见 `LyricsSecondaryText.swift`）。
    ///
    /// 选档看的是「这一屏有没有音译」，**发音成块贴在字底下也算**，
    /// 所以走的是 `specs.hasTransliteration(line)` 而不是`visibleTransliteration`
    /// ——后者答的是「整行式那条副行要不要画」，成块之后它是 nil，两回事。
    /// `secondaryFonts(for:)` 里问的正是前者。
    var secondaryFonts: (translation: NSFont, transliteration: NSFont) {
        specs.secondaryFonts(for: line)
    }

    var translationFontForMeasuring: NSFont { secondaryFonts.translation }

    /// 发音那一档：整行式副行、成块贴字底下的 ruby、以及那条推进渐变共用它。
    var transliterationFontForMeasuring: NSFont { secondaryFonts.transliteration }

    /// 一个排版行的量度。`range` 是这一段在整行文本里的 UTF-16 范围，
    /// `ctLine` 只覆盖这一段——问字符落点时下标要先减去`range.location`。
    struct RowMetrics {
        var range: NSRange
        var ctLine: CTLine
        var width: CGFloat
        var height: CGFloat
        var ascent: CGFloat
    }

    /// 按可用宽度折行。
    ///
    /// **断点由 TextKit 给**（`LyricsTextLayout.wrap`，段落样式带
    /// `lineBreakStrategy` 与`languageIdentifier`）；CoreText 只负责在段内
    /// 量排版框和查字符落点——`CTTypesetterSuggestLineBreak` 不认断行策略，
    /// 拿它断出来的位置跟官方对不上。
    /// 结果按 (文本, 字体, 宽度) 缓存，见 `LyricsRowMetricsCache`：
    /// `sizeThatFits` 只要宽高却也要走这里，而它被行几何对全表每行调用，
    /// 一次翻行至少跑两遍——`CTLine` 一份就够了，不必每次重建。
    static func measureRows(text: String, font: NSFont, width: CGFloat) -> [RowMetrics] {
        guard !text.isEmpty, width > 0 else { return [] }
        let cacheKey = LyricsRowMetricsCache.key(text: text, font: font, width: width)
        if let cached = LyricsRowMetricsCache.value(for: cacheKey) { return cached }
        let rows = computeRows(text: text, font: font, width: width)
        LyricsRowMetricsCache.store(rows, for: cacheKey)
        return rows
    }

    private static func computeRows(text: String, font: NSFont, width: CGFloat) -> [RowMetrics] {
        let attributes = LyricsTextLayout.attributes(for: text, font: font,
                                                     color: CGColor(gray: 1, alpha: 1))
        let attributed = NSAttributedString(string: text, attributes: attributes)
        return LyricsTextLayout.wrap(text, attributes: attributes, width: width)
            .fragments.map { fragment in
                let ctLine = CTLineCreateWithAttributedString(
                    attributed.attributedSubstring(from: fragment.range))
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
                return RowMetrics(range: fragment.range,
                                  ctLine: ctLine,
                                  width: fragment.usedWidth,
                                  height: LyricsTextLayout.rasterSafeHeight(
                                    ascent + descent + leading, font: font),
                                  ascent: ascent)
            }
    }

    // MARK: - 逐字单元的字符范围
    //
    // QRC 的音节拼起来通常等于整行文本，但解析器对首尾做过 trim，直接按长度累加
    // 会错位。所以顺序查找：每个音节从上一个的结尾往后找第一处匹配。
    // 任何一个找不到就整条放弃，退回「没有逐字」——宁可不做，不做错。

    static func syllableRanges(in text: String,
                               syllables: [TextLine.SyllableTiming]) -> [Range<Int>]? {
        let utf16 = Array(text.utf16)
        var cursor = 0
        var ranges: [Range<Int>] = []
        for syllable in syllables {
            let needle = Array(syllable.text.utf16)
            guard !needle.isEmpty else { return nil }
            guard let start = indexOf(needle, in: utf16, from: cursor) else { return nil }
            ranges.append(start..<(start + needle.count))
            cursor = start + needle.count
        }
        return ranges
    }

    private static func indexOf(_ needle: [UInt16], in haystack: [UInt16], from: Int) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var i = from
        while i + needle.count <= haystack.count {
            // 逐元素比，不 `Array(haystack[i..<j])`——那一句每挪一个位置就堆分配
            // 一个新数组，一行几十个音节乘上几十个候选位置全是白扔的临时对象。
            // 结果完全一致：仍是「从 `from` 起第一处完整匹配」。
            var matched = true
            for k in 0..<needle.count where haystack[i + k] != needle[k] {
                matched = false
                break
            }
            if matched { return i }
            i += 1
        }
        return nil
    }
}

// MARK: - 建层

extension SBS_TextContentLayer {

    override func layoutSublayers() {
        super.layoutSublayers()
        guard bounds.width > 0 else { return }
        if bounds.width != layoutWidth { rebuild(width: bounds.width) }
        placeSecondaryLines()
    }

    /// 重排：断行 → 每行建一组图层 → 把逐字时间轴分到各行 → 落一次进度。
    func rebuild(width: CGFloat) {
        layoutWidth = width
        for row in rows {
            row.base.removeFromSuperlayer()
            row.sung.removeFromSuperlayer()
        }
        rows = []
        layoutLines = []

        guard let line, !line.text.isEmpty else { return }
        guard rubyBlocks.isEmpty else {
            rebuildRuby(width: width)
            applyProgress(liftAnimated: false)
            return
        }
        let metrics = Self.measureRows(text: line.text, font: specs.font, width: width)
        guard !metrics.isEmpty else { return }
        let ranges = Self.syllableRanges(in: line.text, syllables: line.syllables)

        let baseColor = LyricsSpecs.cgColor(self.baseColor, in: appearance)
        let sungColor = LyricsSpecs.cgColor(specs.lineProgressionGradientColor, in: appearance)
        let isRightToLeft = line.direction == .rightToLeft

        var y: CGFloat = 0
        for metric in metrics {
            let row = Row()
            row.frame = CGRect(x: Self.rowOriginX(rowWidth: metric.width,
                                                  boxWidth: bounds.width,
                                                  isFlipped: isFlipped),
                               y: y, width: metric.width, height: metric.height)
            row.textHeight = metric.height
            row.base.frame = row.frame
            row.sung.frame = row.frame
            insertSublayer(row.base, at: 0)
            insertSublayer(row.sung, above: row.base)

            let layoutLine = SyncedLyricsLineLayer.LayoutLine()
            layoutLine.frame = row.frame
            layoutLine.isRightToLeft = isRightToLeft
            layoutLine.animationKind = .gradient
            layoutLine.text = Self.substring(line.text, utf16: metric.range)

            // 落在这一段里的逐字单元。
            let rowStart = metric.range.location
            let rowEnd = rowStart + metric.range.length
            for (index, syllable) in line.syllables.enumerated() {
                guard let ranges, ranges.indices.contains(index) else { break }
                let range = ranges[index]
                guard range.lowerBound >= rowStart, range.lowerBound < rowEnd else { continue }

                // `ctLine` 只覆盖本段，下标要换算成段内的。
                let x0 = CTLineGetOffsetForStringIndex(metric.ctLine,
                                                       range.lowerBound - rowStart, nil)
                let x1 = CTLineGetOffsetForStringIndex(metric.ctLine,
                                                       min(range.upperBound, rowEnd) - rowStart, nil)
                let absoluteFrame = CGRect(x: x0, y: 0,
                                           width: max(x1 - x0, 0), height: metric.height)
                // 原模型里 Syllable/Glyph 的 frame 是 Word 内局部坐标；此前三层都存了
                // 绝对 x，行末公式又把 word.minX 加一次，导致高亮在结束时向前跳。
                let localFrame = CGRect(origin: .zero, size: absoluteFrame.size)

                var glyph = SyncedLyricsLineLayer.Glyph()
                glyph.text = syllable.text
                glyph.textPosition = range.lowerBound
                glyph.frame = localFrame
                glyph.originalFrame = localFrame

                var unit = SyncedLyricsLineLayer.Syllable()
                unit.text = syllable.text
                unit.textPosition = range.lowerBound
                unit.startTime = syllable.startTime
                unit.endTime = syllable.endTime
                unit.frame = localFrame
                unit.originalFrame = localFrame
                unit.glyphs = [glyph]

                // QRC 的一个单元就是一个词，词里只有一个音节。
                var word = SyncedLyricsLineLayer.Word()
                word.text = syllable.text
                word.index = layoutLine.words.count
                word.frame = absoluteFrame
                word.originalFrame = absoluteFrame
                word.syllables = [unit]
                // 强调载荷是**词级**的（§23.6：内联模型的）。
                // 这条路上一个单元就是一个词，原样带过去。
                word.emphasis = syllable.emphasis
                layoutLine.words.append(word)

                row.syllables.append(makeSyllableLayers(text: syllable.text,
                                                        frame: absoluteFrame,
                                                        base: baseColor,
                                                        sung: sungColor,
                                                        emphasis: syllable.emphasis,
                                                        row: row))
            }

            layoutLine.startTime = layoutLine.words.first?.syllables.first?.startTime ?? line.startTime
            layoutLine.endTime = layoutLine.words.last?.syllables.last?.endTime ?? line.endTime

            // 没有逐字单元落在这一段（例如映射失败）：整段当一个单元，
            // 时间取整行——渐变仍会扫，只是不逐字。
            if layoutLine.words.isEmpty {
                let frame = CGRect(x: 0, y: 0, width: metric.width, height: metric.height)
                var unit = SyncedLyricsLineLayer.Syllable()
                unit.text = layoutLine.text
                unit.startTime = line.startTime
                unit.endTime = line.endTime
                unit.frame = frame
                unit.originalFrame = frame
                var word = SyncedLyricsLineLayer.Word()
                word.text = layoutLine.text
                word.frame = frame
                word.originalFrame = frame
                word.syllables = [unit]
                layoutLine.words = [word]
                layoutLine.startTime = line.startTime
                layoutLine.endTime = line.endTime
                row.syllables.append(makeSyllableLayers(text: layoutLine.text,
                                                        frame: frame,
                                                        base: baseColor,
                                                        sung: sungColor,
                                                        emphasis: .none,
                                                        row: row))
            }
            layoutLine.hasEmphasis = layoutLine.words.contains { !$0.emphasis.isNone }

            // 已唱那一份的遮罩：宽度就是扫过的进度，软边条永远贴在最前端。
            row.gradient.color = sungColor
            row.gradient.featherWidth = specs.lineProgressionGradientFeather
            row.gradient.direction = isRightToLeft ? .rightToLeft : .leftToRight
            row.gradient.outerPadding = CGSize(
                width: specs.lineProgressionGradientFeather,
                height: LineProgressGradientGeometry.verticalPadding(font: specs.font,
                                                                     lineHeight: metric.height,
                                                                     specs: specs))
            row.gradient.frame = CGRect(x: 0, y: 0, width: 0, height: metric.height)
            row.sung.mask = row.gradient
            row.sung.opacity = (isSelected || isSungPrepared) ? 1 : 0

            rows.append(row)
            layoutLines.append(layoutLine)
            y += metric.height
        }

        applyProgress(liftAnimated: false)
    }

    /// 建一个音节的那一对层，顺手把辉光装到基础层上（§23.2）。
    /// 发音（ruby）那一层不走这里——原版的阴影只挂在承载正文的词层上。
    func makeSyllableLayers(text: String,
                            frame: CGRect,
                            base: CGColor,
                            sung: CGColor,
                            emphasis: Lyrics.Emphasis,
                            row: Row) -> (base: CATextLayer, sung: CATextLayer) {
        let pair = makeTextLayers(text: text, frame: frame, font: specs.font,
                                  base: base, sung: sung, row: row)
        configureGlow(on: pair.base, emphasis: emphasis)
        return pair
    }

    /// 建一对同位的文字层：一层暗底进 `row.base`，一层亮字进`row.sung`
    /// （后者被那条推进遮罩罩着）。正文与发音用的是同一套，只差字体。
    func makeTextLayers(text: String,
                        frame: CGRect,
                        font: NSFont,
                        base: CGColor,
                        sung: CGColor,
                        row: Row) -> (base: CATextLayer, sung: CATextLayer) {
        let make: (CGColor) -> CATextLayer = { color in
            let layer = CATextLayer()
            layer.contentsScale = self.contentsScale
            layer.isWrapped = false
            layer.truncationMode = .none
            layer.alignmentMode = .left
            layer.font = font
            layer.fontSize = font.pointSize
            layer.foregroundColor = color
            layer.string = text
            // 宽度放宽一点：CTLine 的字距落点和 CATextLayer 自己排出来的宽度
            // 不一定一致，卡死会把最后一个字形切掉。
            layer.frame = CGRect(x: frame.minX, y: frame.minY,
                                 width: frame.width + font.pointSize,
                                 height: frame.height)
            return layer
        }
        let baseLayer = make(base)
        let sungLayer = make(sung)
        row.base.addSublayer(baseLayer)
        row.sung.addSublayer(sungLayer)
        return (baseLayer, sungLayer)
    }

    /// 发音、翻译两条副行依次落在最后一个排版行下面。
    ///
    /// **发音在上、翻译在下**：发音是正文的读法，贴着正文才讲得通——
    /// 块排版那条路（发音贴在字底下）本来就是这个次序，整行副行这条也得一致，
    /// 不然同一屏里没有发音数据的那几行（歌手提示行之类）看着是反的。
    private func placeSecondaryLines() {
        var y = rows.last.map { $0.frame.maxY } ?? 0

        if let transliteration = visibleTransliteration {
            transliterationBase.isHidden = false
            transliterationSung.isHidden = false
            let top = y + specs.translationSpacing
            // 暗底与亮字是同一段文字、同一个 frame，差别只在颜色与那层遮罩。
            let height = place(transliteration, in: transliterationBase,
                               font: transliterationFontForMeasuring,
                               color: LyricsSpecs.cgColor(translationColor, in: appearance),
                               lineHeightAdjustment: specs.transliterationLineHeightAdjustment,
                               y: top)
            _ = place(transliteration, in: transliterationSung,
                      font: transliterationFontForMeasuring,
                      color: LyricsSpecs.cgColor(specs.lineProgressionGradientColor,
                                                 in: appearance),
                      lineHeightAdjustment: specs.transliterationLineHeightAdjustment,
                      y: top)
            configureTransliterationGradient(height: height)
            y = top + height
        } else {
            transliterationBase.isHidden = true
            transliterationSung.isHidden = true
            transliterationWidth = 0
        }

        if let translation = visibleTranslation {
            translationLayer.isHidden = false
            _ = place(translation, in: translationLayer,
                      font: translationFontForMeasuring,
                      y: y + specs.translationSpacing)
        } else {
            translationLayer.isHidden = true
        }
    }

    /// 音译那条渐变的固定参数。与主行同一套：软边宽度、方向、内外余量。
    /// 宽度每帧由 `applyProgress` 推，这里只摆好其余部分。
    private func configureTransliterationGradient(height: CGFloat) {
        let isRightToLeft = line?.direction == .rightToLeft
        transliterationGradient.color =
            LyricsSpecs.cgColor(specs.lineProgressionGradientColor, in: appearance)
        transliterationGradient.featherWidth = specs.lineProgressionGradientFeather
        transliterationGradient.direction = isRightToLeft ? .rightToLeft : .leftToRight
        transliterationGradient.outerPadding = CGSize(
            width: specs.lineProgressionGradientFeather,
            height: LineProgressGradientGeometry.verticalPadding(
                font: transliterationFontForMeasuring, lineHeight: height, specs: specs))
        // 副行是满宽层 + 段落右对齐，墨迹靠在右边，遮罩的起点得跟过去；
        // `applyTransliterationProgress` 只改 width，不碰 origin，设一次就够。
        transliterationGradient.frame = CGRect(
            x: isFlipped ? max(bounds.width - transliterationWidth, 0) : 0,
            y: 0, width: 0, height: height)
        transliterationSung.opacity = isSelected ? 1 : 0
    }

    /// 把一条副行落到图层上，返回它占的高度。
    @discardableResult
    private func place(_ text: String, in layer: CATextLayer, font: NSFont,
                       color: CGColor? = nil,
                       lineHeightAdjustment: CGFloat = 0, y: CGFloat) -> CGFloat {
        let alignment: NSTextAlignment? = isFlipped ? .right : specs.lineTextAlignment
        let attributes = LyricsTextLayout.attributes(
            for: text,
            font: font,
            color: color ?? LyricsSpecs.cgColor(translationColor, in: appearance),
            alignment: alignment,
            lineHeightAdjustment: lineHeightAdjustment)
        layer.alignmentMode = LyricsTextLayout.alignmentMode(alignment)
        layer.string = LyricsTextLayout.hardWrapped(text, attributes: attributes,
                                                    width: bounds.width)
        let size = LyricsTextLayout.size(text, attributes: attributes, width: bounds.width)
        layer.frame = CGRect(x: 0, y: y, width: bounds.width, height: size.height)
        if layer === transliterationSung { transliterationWidth = min(size.width, bounds.width) }
        return size.height
    }

    static func substring(_ text: String, utf16 range: NSRange) -> String {
        let ns = text as NSString
        let location = min(range.location, ns.length)
        let length = min(range.length, ns.length - location)
        return ns.substring(with: NSRange(location: location, length: length))
    }
}

// MARK: - 行末补完（§7.4）

extension SBS_TextContentLayer {

    /// 一行唱完时把没走完的进度补完。
    ///
    /// [实测]：置 `LayoutLine.ignoreProgress`，
    /// 在 `lineFinishProgressAnimationDuration = 0.25` 内把渐变推到行末，
    /// 到点解锁。**没有这个互锁，每帧走查会立刻把渐变改回「按时间算出来的」，
    /// 补完动画一帧都活不下来**。
    func finishRemainingProgress(duration: TimeInterval) {
        guard !rows.isEmpty else { return }
        for (index, row) in rows.enumerated() {
            guard let layoutLine = layoutLines[safe: index] else { continue }
            layoutLine.ignoreProgress = true

            let padding = LineProgressGradientGeometry.verticalPadding(
                font: specs.font, lineHeight: row.frame.height, specs: specs)
            guard let word = layoutLine.words.last,
                  let syllable = word.syllables.last else { continue }
            let target = LineProgressGradientGeometry.finishedWidth(
                lastWordMinX: word.frame.minX,
                lastSyllableMaxX: syllable.frame.maxX,
                verticalPadding: padding,
                specs: specs)

            row.gradient.featherWidth = specs.lineProgressionGradientFeather
            row.gradient.layoutIfNeeded()

            var frame = row.gradient.frame
            let from = frame.size.width
            frame.size.width = target
            let animator = LayerPropertyAnimator(curve: .easeOut(duration))
            animator.layers = [row.gradient]
            animator.addAnimation(to: row.gradient, keyPath: "bounds.size.width",
                                  from: from, to: target,
                                  frameRateRange: (min: 0, max: 0))
            animator.finishDispatch { row.gradient.frame = frame }
        }
        // `nonisolated(unsafe)` 的理由同本族那几张排版缓存（见 `LyricsRowMetricsCache`）：
        // asyncAfter 到 .main 的闭包是主 actor 隔离的，而 `self` 是 `CALayer` 子类、
        // 在 SDK 里非隔离，直接捕获就是「sending 'self'」。弱引用语义一点没变。
        nonisolated(unsafe) weak let me = self
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            me?.layoutLines.forEach { $0.ignoreProgress = false }
        }
    }

    /// 点击一行时把逐字进度钉住。
    ///
    /// [实测] §7.6：`handleTap` 冻结的是`Line.ignoreProgress`，
    /// `lineTapProgressFreezeDuration = 0.1` 秒后解冻——等新时间源送到再放开，
    /// 免得进度先弹回旧位置再跳过去。
    func freezeProgress(for duration: TimeInterval) {
        layoutLines.forEach { $0.ignoreProgress = true }
        // `nonisolated(unsafe)` 的理由同本族那几张排版缓存（见 `LyricsRowMetricsCache`）：
        // asyncAfter 到 .main 的闭包是主 actor 隔离的，而 `self` 是 `CALayer` 子类、
        // 在 SDK 里非隔离，直接捕获就是「sending 'self'」。弱引用语义一点没变。
        nonisolated(unsafe) weak let me = self
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            me?.layoutLines.forEach { $0.ignoreProgress = false }
        }
    }
}
