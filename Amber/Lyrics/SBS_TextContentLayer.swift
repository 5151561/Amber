import AppKit
import CoreText
import QuartzCore

/// 逐字档的内容层（原版 `ContentKind.sbsText`，类名实测得到）。
///
/// 四层数据模型（Line → Word → Syllable → Glyph）与每帧走查见
/// `SyncedLyricsLineLayer+Progress.swift` 与 §7.1 / §7.2；渐变几何见 §7.3；
/// 三个子层的落位见 §8.2。本类做的是把那些公式接到真实图层上：
///
/// ```
/// SBS_TextContentLayer
/// └─ 每个排版行（LayoutLine）一组：
///    ├─ base : 未唱的字（选中行 35%，非选中行 17.5%）
///    └─ sung : 已唱的字（100%），mask = LineProgressGradientLayer
/// ```
///
/// 两套字形完全同位，靠 mask 的推进边界决定露出多少——这正是「软边扫过」而不是
/// 「唱到就切色」：`lineProgressionGradientFeather = 30` 是 mask 前端那条定宽软边。
///
/// 逐字单元按**音节**各自成层（原版 `Syllable` 就带自己的`frame`/`xOffset`），
/// 这样 `syllableLift = 2` 的上抬才有落点。字形层（`Glyph`）只有`.emphasis`
/// 能力才用得上，Amber 的 QRC 源不声明这条能力，所以不建——公式仍在
/// `SyllableEmphasis.glyphPosition` 里备着。
final class SBS_TextContentLayer: CALayer, SyncedLyricsContentLayer, SBS_TextContentLayerProgress {

    var specs = LyricsSpecs()
    var appearance: NSAppearance?
    var line: TextLine?

    private(set) var isSelected = false
    private(set) var isScrolling = false
    /// 是否已为开唱预热亮字层透明度。
    private(set) var isSungPrepared = false
    /// 当前进度（全局时间轴上的秒数）。`setProgress` 的两级防抖比的就是它。
    private(set) var progress: Double = 0

    /// 排版结果。一条歌词折成几行就有几个。
    var layoutLines: [SyncedLyricsLineLayer.LayoutLine] = []
    var rows: [Row] = []
    var layoutWidth: CGFloat = 0

    /// 和声的那一层（原版同一个字段槽）。Amber 的数据源不产出和声，
    /// 建而不用——`TextLine.backgroundVocals` 一旦有值就该往这里塞。
    let backgroundVocalsLayer = CALayer()
    let translationLayer = CATextLayer()

    // 音译（界面上叫「发音」）。逐字档原来只有翻译一条副行——数据源当时不产音译，
    // 现在 QQ 的 `roma` / 网易的`romalrc` 接上了，这一层跟着补。
    //
    // 它**跟着高亮走**：[实测] §7.2 的每帧走查里，音译行只是 `isTransliteration`
    // 为真的一条普通 Line——跳过音节层，但照样落到末尾那段渐变几何上
    // （`animationKind == 0` 那一支）。所以这里和主行同构：一层暗底、一层亮字，
    // 亮字被一条推进的渐变遮罩罩住。翻译不跟（那是静态副行），只有音译跟。
    let transliterationBase = CATextLayer()
    let transliterationSung = CATextLayer()
    let transliterationGradient = LineProgressGradientLayer()
    /// 音译文本自己的墨宽，扫过比例乘在它上面。
    var transliterationWidth: CGFloat = 0

    /// 「发音贴在字底下」那条排版的块。非空就走它，空就走原来的整行副行。
    /// 内容与 specs 决定，与宽度无关，所以在 `setLine` / `updateAppearance` 时算好。
    var rubyBlocks: [RubyLayout.Block] = []

    /// 一个排版行对应的图层。
    final class Row {
        let base = CALayer()
        let sung = CALayer()
        let gradient = LineProgressGradientLayer()
        var syllables: [(base: CATextLayer, sung: CATextLayer)] = []
        /// 发音那一层。与正文同 x 起点、同一条遮罩，只是落在正文下面。
        var ruby: [(base: CATextLayer, sung: CATextLayer)] = []
        /// 已经上抬过的音节，避免每帧重发弹簧。倒着 seek 会把越过的项清掉。
        var lifted: Set<Int> = []
        /// 已经起过辉光 ramp 的**词**（键是这个词首音节的展平下标），
        /// 对应 §23.5 那五道闸放行后写回 `animationStatus` 的那一手：一个词只发一次。
        var glowed: Set<Int> = []
        /// 正在跑的辉光 ramp，键是音节的展平下标。逐 tick 直写，跑完就摘（§23.4）。
        var glows: [Int: GlowRamp] = [:]
        /// 整盒（正文 + 发音）。
        var frame: CGRect = .zero
        /// 正文那一段的高度。渐变的纵向余量按它算，不按整盒——
        /// 余量的语义是「强调放大与辉光会超出正文多少」，与发音无关。
        var textHeight: CGFloat = 0
    }

    override init() {
        super.init()
        contentsScale = LyricsRenderingScale.current
        for layer in [translationLayer, transliterationBase, transliterationSung] {
            layer.isWrapped = true
            layer.contentsScale = contentsScale
        }
        addSublayer(backgroundVocalsLayer)
        addSublayer(translationLayer)
        addSublayer(transliterationBase)
        addSublayer(transliterationSung)
        transliterationSung.mask = transliterationGradient
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }

    // MARK: - 数据

    func setLine(_ line: TextLine?) {
        self.line = line
        refreshRubyBlocks()
        layoutWidth = 0                 // 逼下一次布局重排
        setNeedsLayout()
    }

    /// 重算发音块。开关关掉、没有逐字、或者发音没落到音节上时为空。
    func refreshRubyBlocks() {
        guard specs.showsTransliteration, let line, !line.syllables.isEmpty else {
            rubyBlocks = []
            return
        }
        // 发音块的宽度按**发音真正会用的那一档**量：「更大字体 = 歌词」时它是小档，
        // 拿基线 15 去量会把块撑宽，正文被顶开的距离就跟画出来的对不上。
        rubyBlocks = RubyLayout.blocks(text: line.text, syllables: line.syllables,
                                       specs: specs, rubyFont: transliterationFontForMeasuring)
    }

    // MARK: - SyncedLyricsContentLayer

    func setSelected(_ selected: Bool, animated: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        if !selected { isSungPrepared = false }
        applyColors(animated: animated)
    }

    /// 为逐字歌词预热亮字层透明度。遮罩（row.gradient）在未开唱时为 0 宽，
    /// 将亮字层提前置 1 能保证开唱第一帧渐变扫过时亮字立即可见，避免 120ms 的淡入延迟。
    func prepareSungOpacity() {
        guard !isSungPrepared else { return }
        isSungPrepared = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for row in rows {
            row.sung.opacity = 1
        }
        transliterationSung.opacity = 1
        CATransaction.commit()
    }

    /// 取消逐字歌词高亮透明度预热。
    func cancelSungPreparation() {
        guard isSungPrepared else { return }
        isSungPrepared = false
        if !isSelected {
            applyColors(animated: false)
        }
    }

    func setScrolling(_ scrolling: Bool, animated: Bool) {
        guard scrolling != isScrolling else { return }
        isScrolling = scrolling
        applyColors(animated: animated)
    }

    func updateAppearance(specs: LyricsSpecs, appearance: NSAppearance?) {
        self.specs = specs
        self.appearance = appearance
        refreshRubyBlocks()
        layoutWidth = 0
        setNeedsLayout()
    }

    /// 只换副行显隐时的轻量路径。
    ///
    /// `updateAppearance` 会把`layoutWidth` 清零，逼下一次`layoutSublayers` 走
    /// `rebuild`——正文每个音节那一对`CATextLayer` 全部拆掉重建、`RubyLayout.blocks`
    /// 重跑一遍，而且是**全表每一行**。可显隐副行改的其实只有 `placeSecondaryLines`
    /// 摆的那三层（发音暗底 / 发音亮字 / 译文），正文一个字都没动。
    ///
    /// 唯一的例外是发音**成块贴在字底下**那条路：块的存在与否直接决定正文的断行与
    /// 每个字的落点（见 `SBS_TextContentLayer+Ruby.swift`），那已经不是「副行显隐」，
    /// 是整条排版换了一套——只有这一种情形才清 `layoutWidth` 重排。
    func applySecondaryLineVisibility(specs: LyricsSpecs, appearance: NSAppearance?) {
        let hadRubyBlocks = !rubyBlocks.isEmpty
        self.specs = specs
        self.appearance = appearance
        refreshRubyBlocks()
        if hadRubyBlocks || !rubyBlocks.isEmpty { layoutWidth = 0 }
        setNeedsLayout()
    }

    /// 非选中行整行一个色（17.5%），选中行未唱部分 35%、已唱 100%。
    /// 浏览时非选中行提到 40%，当前播放行的渐变继续按时间轴推进。
    func applyColors(animated: Bool) {
        let base = LyricsSpecs.cgColor(baseColor, in: appearance)
        let sung = LyricsSpecs.cgColor(specs.lineProgressionGradientColor, in: appearance)
        // 浏览歌词只暂停自动跟随，不应关掉当前播放行的逐字高亮。
        let sungOpacity: Float = (isSelected || isSungPrepared) ? 1 : 0

        var baseColorTargets: [(CATextLayer, CGColor)] = []
        var rubyColorTargets: [(CATextLayer, CGColor)] = []
        let translationCGColor = LyricsSpecs.cgColor(translationColor, in: appearance)

        for row in rows {
            // 换状态就把辉光打断（§8.1「去辉光的打断」）：这一行不再是当前播放行，
            // 不该继续挂着光晕——非选中行也收不到逐帧进度，ramp 自己也推不动了。
            if !isSelected {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                interruptGlow(in: row, fade: true)
                row.glowed.removeAll()
                CATransaction.commit()
            }
            for pair in row.syllables {
                baseColorTargets.append((pair.base, base))
                pair.sung.foregroundColor = sung
            }
            // 发音与正文同一套明暗：未唱走 `translationColor`（nil 时就是正文的暗色），
            // 已唱走 `lineProgressionGradientColor`——和整行式那条副行取色一致。
            for pair in row.ruby {
                rubyColorTargets.append((pair.base, translationCGColor))
                pair.sung.foregroundColor = sung
            }
            // 逐字高亮由渐变遮罩（row.gradient）的 sweptWidth 随音频推进，
            // 亮字层的整体 opacity 在选中时必须立即可见（1.0），绝不能套 120ms 的 ease-in 淡入动画——
            // 否则在淡入期间（前数十毫秒几乎全透明）前一两个音节就已经被渐变扫过了，
            // 导致视觉上「慢半拍、等唱了一两个字才突然冒出来并覆盖已唱内容」。
            // 只有在取消选中（淡出）且 animated 时才走淡出动画。
            if animated && !isSelected && !isSungPrepared {
                let animator = LayerPropertyAnimator(curve: SyncedLyricsLineLayer.focusTransitionCurve)
                animator.layers = [row.sung]
                animator.addAnimation(to: row.sung, keyPath: "opacity",
                                      from: row.sung.presentation()?.opacity ?? row.sung.opacity,
                                      to: sungOpacity,
                                      frameRateRange: (min: 0, max: 0))
                animator.finishDispatch { row.sung.opacity = sungOpacity }
            } else {
                row.sung.opacity = sungOpacity
            }
        }

        let allSecondaryTargets: [(CATextLayer, CGColor)] = rubyColorTargets + [
            (translationLayer, translationCGColor),
            (transliterationBase, translationCGColor),
        ]

        if animated {
            let colorAnimator = LayerPropertyAnimator(curve: SyncedLyricsLineLayer.focusTransitionCurve)
            colorAnimator.layers = baseColorTargets.map(\.0) + allSecondaryTargets.map(\.0)
            for (layer, color) in baseColorTargets {
                colorAnimator.addAnimation(to: layer, keyPath: "foregroundColor",
                                          from: layer.presentation()?.foregroundColor ?? layer.foregroundColor,
                                          to: color,
                                          frameRateRange: (min: 0, max: 0))
            }
            for (layer, color) in allSecondaryTargets {
                colorAnimator.addAnimation(to: layer, keyPath: "foregroundColor",
                                          from: layer.presentation()?.foregroundColor ?? layer.foregroundColor,
                                          to: color,
                                          frameRateRange: (min: 0, max: 0))
            }
            colorAnimator.finishDispatch {
                for (layer, color) in baseColorTargets { layer.foregroundColor = color }
                for (layer, color) in allSecondaryTargets { layer.foregroundColor = color }
            }
        } else {
            for (layer, color) in baseColorTargets { layer.foregroundColor = color }
            for (layer, color) in allSecondaryTargets { layer.foregroundColor = color }
        }

        // 音译与主行同一套明暗：未唱走 `translationColor`（nil 时就是主行的暗色），
        // 已唱走 `lineProgressionGradientColor`。
        transliterationSung.foregroundColor = sung
        if animated && !isSelected && !isSungPrepared {
            let animator = LayerPropertyAnimator(curve: SyncedLyricsLineLayer.focusTransitionCurve)
            animator.layers = [transliterationSung]
            animator.addAnimation(to: transliterationSung, keyPath: "opacity",
                                  from: transliterationSung.presentation()?.opacity
                                      ?? transliterationSung.opacity,
                                  to: sungOpacity,
                                  frameRateRange: (min: 0, max: 0))
            animator.finishDispatch { self.transliterationSung.opacity = sungOpacity }
        } else {
            transliterationSung.opacity = sungOpacity
        }
    }

    var baseColor: NSColor {
        if isSelected { return specs.selectedUpcomingTextColor }
        return isScrolling ? specs.deselectedScrollTextColor : specs.deselectedTextColor
    }

    var translationColor: NSColor {
        specs.translationTextColor ?? baseColor
    }

    // MARK: - 进度

    /// [实测]：两级「值没变就不做」，第二级带一条倒退阈值——
    /// 往前永远下发，往回只有退超过 0.5 才下发。逐字进度每帧都在抖，
    /// 这条闸把抖动吃掉、只放行真正的 seek。
    func setProgress(_ progress: Double, animated: Bool) {
        guard Self.shouldForward(newProgress: progress, current: self.progress) else { return }
        self.progress = progress
        applyProgress(animated: animated)
    }

    /// 每帧走查：算出每个排版行扫到哪儿，顺手把该上抬的音节抬起来。
    ///
    /// 三件事在这里合成一遍：
    /// - 每行的进度状态只算一次，主行渐变与音译那条比例共用（原来 `sweptWidth`
    ///   与 `sweptFraction` 各遍历一次`progressState`，每帧走两遍全表排版行）；
    /// - `CATransaction` 只开一次（原来每行一次、音译再一次，一行歌词折三行就是四次）；
    /// - 音节上抬留到事务外——`addAnimation` 在`CATransaction.disableActions()`
    ///   为真时会退化成直接赋值，包进去弹簧就没了。
    func applyProgress(animated: Bool) {
        let needsTransliteration = transliterationWidth > 0 && !transliterationSung.isHidden
        var totalWords = 0
        var doneWords = 0.0
        var pendingLifts: [(row: Row, layoutLine: SyncedLyricsLineLayer.LayoutLine)] = []
        let lifts = specs.syllableLift != 0 && line?.capabilities.contains(.lift) == true
        let now = CACurrentMediaTime()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layoutLine) in layoutLines.enumerated() {
            let state = layoutLine.progressState(at: progress)
            if needsTransliteration {
                totalWords += layoutLine.words.count
                doneWords += sweptWords(of: layoutLine, state: state)
            }
            guard let row = rows[safe: index] else { continue }

            // §7.6 / §7.4 的互锁：**只锁渐变几何**。
            // [实测] §7.2 的走查里 `if line.ignoreProgress { return }` 落在**词循环之后**
            // （那一支之前），所以词层的抬升 / 强调 / 辉光照跑——
            // 早先这里对整行 `continue`，行末补完那 0.25 秒与点击冻结那 0.1 秒里
            // 抬升会整个停手。
            if !layoutLine.ignoreProgress {
                let padding = verticalPadding(for: row)
                let geometry = sweptGeometry(of: layoutLine,
                                             state: state,
                                             verticalPadding: padding)
                row.gradient.featherWidth = geometry.feather
                var frame = row.gradient.frame
                frame.size.width = geometry.width
                row.gradient.frame = frame
                row.gradient.layoutIfNeeded()
            }

            // 辉光：起 ramp 与逐 tick 直写都必须留在这个关掉隐式动画的事务里（§23.4）。
            startGlowRamps(in: row, layoutLine: layoutLine, now: now)
            advanceGlowRamps(in: row, now: now)

            // 只为抬升排队。带 emphasis 的行不必也进来——强调缩放没接线
            // （理由见 `liftStartedSyllables`），辉光自己在上面那两句里走完了。
            if lifts { pendingLifts.append((row, layoutLine)) }
        }
        if needsTransliteration {
            let fraction = totalWords > 0
                ? min(max(doneWords / Double(totalWords), 0), 1)
                : 0
            applyTransliterationProgress(fraction: fraction)
        }
        CATransaction.commit()

        for (row, layoutLine) in pendingLifts {
            liftStartedSyllables(in: row, layoutLine: layoutLine, animated: animated)
        }
    }

    /// 音译那条渐变。宽度 = 内外余量 + 扫过比例 × 音译墨宽。
    /// 调用方已经把它包在关掉隐式动画的事务里了。
    private func applyTransliterationProgress(fraction: Double) {
        guard fraction > 0 else {
            var frame = transliterationGradient.frame
            frame.size.width = 0
            transliterationGradient.frame = frame
            return
        }
        let padding = LineProgressGradientGeometry.verticalPadding(
            font: transliterationFontForMeasuring,
            lineHeight: transliterationSung.frame.height,
            specs: specs)
        let feather = specs.lineProgressionGradientFeather
        var frame = transliterationGradient.frame
        if fraction >= 1.0 {
            frame.size.width = padding + feather + transliterationWidth
        } else {
            frame.size.width = transliterationWidth * CGFloat(fraction) + feather * 0.25
        }
        transliterationGradient.frame = frame
    }

    /// 这一个排版行**按词**走完了几个词（含正在唱那个词的词内比例）。
    ///
    /// [实测] §7.2：音译行 `isTransliteration` 为真时**整个跳过音节层**，只做词级。
    /// 所以这里不去给音译文本假造逐字时间轴（它本来就没有），而是拿主行
    /// 「走到第几个词 + 词内比例」折成一个比例，再乘到音译自己的宽度上——
    /// 前沿与主行始终同步，又没有多编一层时间。
    private func sweptWords(of layoutLine: SyncedLyricsLineLayer.LayoutLine,
                            state: SyncedLyricsLineLayer.LayoutLine.ProgressState) -> Double {
        switch state {
        case .notStarted:
            return 0
        case .finished:
            return Double(layoutLine.words.count)
        case .singing(let syllableIndex, let wordIndex):
            let word = layoutLine.words[wordIndex]
            let syllable = word.syllables[syllableIndex]
            let span = syllable.endTime - syllable.startTime
            return Double(wordIndex) + (span > 0
                ? min(max((progress - syllable.startTime) / span, 0), 1)
                : 1)
        }
    }

    /// 渐变要罩住的纵向余量。§7.3：墨高 × 1.14 + 2 × glowRadius，与行高之差的一半。
    private func verticalPadding(for row: Row) -> CGFloat {
        // 按**正文**高度算，不按整盒：块排版的 row 底下还挂着一条发音，
        // 而这个余量说的是「强调与辉光超出正文多少」。
        LineProgressGradientGeometry.verticalPadding(
            font: specs.font,
            lineHeight: row.textHeight > 0 ? row.textHeight : row.frame.height,
            specs: specs)
    }

    /// 这一行扫到哪儿。几何计算与羽化夹紧委托给 `LineProgressGradientGeometry`。
    func sweptGeometry(of layoutLine: SyncedLyricsLineLayer.LayoutLine,
                       state: SyncedLyricsLineLayer.LayoutLine.ProgressState,
                       verticalPadding padding: CGFloat) -> LineProgressGradientGeometry.SweptGeometry {
        LineProgressGradientGeometry.sweptGeometry(
            of: layoutLine,
            state: state,
            progress: progress,
            verticalPadding: padding,
            specs: specs)
    }

    /// `syllableLift = 2`：被唱到的音节整体上抬 2pt，由 (1, 14, 7) 那条弹簧走完。
    /// **是常量位移不是动画幅度**（§8.1：它是直接从纵向落点里减掉的），抬起来之后保持。
    ///
    /// 同一趟还带上 §8.1 的**强调缩放**（`emphasizingScaleRange = 1.0…1.14`，
    /// `scale = lo + (hi − lo) × t`，一条直线、没有缓动，缓动全交给同一条弹簧）。
    /// 这里的 `t` 取该词的`Emphasis.factor`——与辉光同一个源：
    ///
    /// - 没有 emphasis 数据时 `factor = 0` ⇒ `scale = lo = 1.0` ⇒ **一个像素都不动**，
    ///   `LayerPropertyAnimator` 那道「值没变就不建动画」还会把它整条挡掉，
    ///   所以接上它对现有数据源零影响；
    /// - 原版这个 `t` 是「归一化进度」，Amber 不逐帧推缩放而是一次推到位，
    ///   由 (1, 14, 7) 那条欠阻尼弹簧走完这一段——观感上的差别只在起步那几帧。`[补]`
    ///
    /// **进出都做**：§25.3 的 `LyricsAnimationStatus` 有`reverseAnimating` 一支，
    /// 说明这套动画本来就是可逆的。往回 seek 时把越过的音节放回原位，
    /// 否则重听同一段时那些字一直保持抬起 + 放大。
    private func liftStartedSyllables(in row: Row,
                                      layoutLine: SyncedLyricsLineLayer.LayoutLine,
                                      animated: Bool) {
        let lift = specs.syllableLift != 0 && line?.capabilities.contains(.lift) == true
            ? specs.syllableLift
            : 0
        var flat = 0
        for word in layoutLine.words {
            // **强调缩放不接线**，公式仍在 `SyllableEmphasis.scale` 里备着。
            //
            // 1.0…1.14 这个数是实测（§8.1，`emphasizingScaleRange`），但
            //    §8.1 里乘上去的 `t` 是**词内归一化进度**，不是 emphasis 的 factor；
            //    而 §23.5 那道 `.none → 跳过` 的闸，spec 写明是**辉光 ramp 之前**的
            //    五道闸，不是缩放的闸。拿合成 factor 当 `t` 是把两条链接串了。
            // 2. 照 §8.1 原样接（`t` = 词内进度）意味着**每个被唱到的词**都要涨到
            //    1.14×，而 [PX] §22.2 在播放态量到的主行字号只比整数档高 1–8%，
            //    §23.7 还把这 1–8% 整个归因给了辉光（半径 5 的阴影被墨迹标定算进字高）。
            //    真有 14% 的缩放，那批样本不可能只高 1–8%。
            //
            // 两头都不成立，所以这里不放大。要接的话得先有「哪些词该放大」的实测
            // 或实测依据——合成 factor 是给辉光用的（`LyricsAdapter.synthesizeEmphasis`
            // 标了 `[补]`），不该拿去改字号几何。
            let scale: Double? = nil
            for syllable in word.syllables {
                defer { flat += 1 }
                guard row.syllables.indices.contains(flat) else { continue }
                let started = progress >= syllable.startTime
                if started {
                    guard row.lifted.insert(flat).inserted else { continue }
                } else {
                    guard row.lifted.remove(flat) != nil else { continue }
                }
                let pair = row.syllables[flat]
                for layer in [pair.base, pair.sung] {
                    emphasize(layer, lift: started ? -lift : lift,
                              scale: scale.map { started ? $0 : 1 },
                              animated: animated)
                }
            }
        }
    }

    /// 把一个音节层推到「已唱」或「未唱」那一端。位移是增量（抬起来是负的），
    /// 缩放是绝对值（`nil` 表示这个词没有强调数据，整条不碰`transform`）。
    private func emphasize(_ layer: CALayer,
                           lift: CGFloat,
                           scale: Double?,
                           animated: Bool) {
        let curve = LyricsAnimationCurve.spring(
            .init(mass: SpringTimingParameters.syllableEmphasis.mass,
                  stiffness: SpringTimingParameters.syllableEmphasis.stiffness,
                  damping: SpringTimingParameters.syllableEmphasis.damping))
        let position = CGPoint(x: layer.position.x, y: layer.position.y + lift)
        // 原版是把 scale 折进字形的落点公式（§8.1 `glyphPosition`）；Amber 没有字形层，
        // 音节层的 anchorPoint 就是 (0.5, 0.5)，`transform` 缩放等价于绕中心放大。
        // `newX = (sw + scale·x + x) × 0.5` 在 scale = 1 时正是中心 x，两条对得上。`[补]`
        let transform = scale.map { NSValue(caTransform3D: CATransform3DMakeScale($0, $0, 1)) }

        guard animated else {
            if lift != 0 { layer.position = position }
            if let transform { layer.transform = transform.caTransform3DValue }
            return
        }
        let animator = LayerPropertyAnimator(curve: curve)
        animator.layers = [layer]
        if lift != 0 {
            animator.addAnimation(to: layer, keyPath: "position",
                                  from: layer.position, to: position,
                                  frameRateRange: (min: 0, max: 0))
        }
        if let transform {
            animator.addAnimation(to: layer, keyPath: "transform",
                                  from: NSValue(caTransform3D: layer.transform),
                                  to: transform,
                                  frameRateRange: (min: 0, max: 0))
        }
        animator.finishDispatch {
            if lift != 0 { layer.position = position }
            if let transform { layer.transform = transform.caTransform3DValue }
        }
    }

    /// 换行 / 换歌时把上抬与进度清干净。
    func resetProgress() {
        cancelSungPreparation()
        progress = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        transliterationGradient.frame.size.width = 0
        CATransaction.commit()
        for row in rows {
            row.lifted.removeAll()
            row.glowed.removeAll()
            var frame = row.gradient.frame
            frame.size.width = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            row.gradient.featherWidth = specs.lineProgressionGradientFeather
            row.gradient.frame = frame
            row.gradient.layoutIfNeeded()
            // 去辉光：先落值、再清引用，最后熄灭（§8.1 / §23.5）。
            interruptGlow(in: row, fade: true)
            CATransaction.commit()
            // [实测] §23.5：**不许盲调 `removeAllAnimations()`**——按 keyPath 逐条
            // `animationForKey:`，是 basic animation 才摘。这些层上除了抬升 / 强调 /
            // 辉光，还可能挂着别处下发的动画（`applyColors` 的 opacity 就在`row.sung`
            // 上），一把清掉会误伤。
            for pair in row.syllables + row.ruby {
                Self.cancelBasicAnimations(on: pair.base,
                                           keyPaths: Self.syllableAnimationKeyPaths)
                Self.cancelBasicAnimations(on: pair.sung,
                                           keyPaths: Self.syllableAnimationKeyPaths)
            }
        }
        layoutWidth = 0
        setNeedsLayout()
    }
}
