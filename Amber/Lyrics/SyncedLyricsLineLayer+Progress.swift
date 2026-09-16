import AppKit

// 逐字的四层数据模型。字段与顺序来自原版的字段表，见 §7.1。
//
// 每一层都同时留 `frame` 与`originalFrame`：后者是排版算出来的原始位置，
// 前者是叠加 `xOffset`（Word 还有`widthOffset`）之后的当前位置。
// 逐字的横向位移是**改 frame、留 originalFrame 当基准**，不是往 transform 里塞平移。

extension SyncedLyricsLineLayer {

    /// 逐字高亮的技术选型。[实测] `Line.animationKind`，
    /// 两处分派。
    enum AnimationKind: Sendable, Equatable {
        /// 整行一条渐变扫过（`LineProgressGradientLayer`）。只有这一档走 §7.3 的几何。
        case gradient
        /// 词级 crossfade overlay（`Word.overlayLayer` + `crossfadeAnimationParameters`）。
        /// 未接线：Amber 的数据源不声明这条能力，建层时一律写 `.gradient`。
        case crossfade
    }

    /// 一个字的动画状态。带载荷的枚举，tag 字节紧跟在载荷后面
    /// （Syllable 载荷 / tag）。
    enum AnimationStatus: Sendable, Equatable {
        case idle
        case running
        case finished
    }

    /// 一个字形。
    struct Glyph: Sendable {
        var glyphIndex: Int = 0
        var textPosition: Int = 0
        var text: String = ""
        var frame: CGRect = .zero
        var xOffset: CGFloat = 0
        var originalFrame: CGRect = .zero
        init() {}
    }

    /// 一个音节。**只有这一层带时间**——Word 没有自己的 start/end，
    /// 一个词的时间范围是它 syllables 的并集。
    struct Syllable: Sendable {
        var text: String = ""
        var glyphs: [Glyph] = []
        var textPosition: Int = 0
        var animationStatus: AnimationStatus = .idle  //载荷 / tag
        var startTime: TimeInterval = 0
        var endTime: TimeInterval = 0
        var frame: CGRect = .zero
        var xOffset: CGFloat = 0
        var originalFrame: CGRect = .zero
        init() {}
    }

    /// 一个词。
    struct Word: Sendable {
        var text: String = ""
        /// 这个词的强调载荷。原版内联在 `correspondingLyricWord` 里：
        /// 载荷、tag（§23.6）。辉光强度（§23.3）与强调缩放（§8.1）
        /// 都读它，**是词级不是音节级**——§23.5 的触发闸查的也是模型词数组的首元素。
        var emphasis: Lyrics.Emphasis = .none
        var syllables: [Syllable] = []
        var index: Int = 0
        var animationStatus: AnimationStatus = .idle
        var originalFrame: CGRect = .zero
        var frame: CGRect = .zero
        var xOffset: CGFloat = 0
        var widthOffset: CGFloat = 0
        init() {}
    }

    /// 一行（排版意义上的一行，一条歌词可能折成多行）。
    final class LayoutLine {
        var words: [Word] = []
        var text: String = ""
        var isTransliteration = false
        var animationKind: AnimationKind = .gradient
        var isRightToLeft = false                    //direction == 1
        var startTime: TimeInterval = 0
        var endTime: TimeInterval = 0
        var frame: CGRect = .zero

        /// 互锁：为真时逐帧走查对这一行整个停手。
        ///
        /// 两处置位：§7.4 的行末补完（0.25 秒后解）与
        /// §7.6 的点击冻结（`lineTapProgressFreezeDuration` = 0.1 秒后解）。
        /// 没有它，每帧都会把渐变位置改回「按时间算出来的」，
        /// 补完动画一帧都活不下来。
        var ignoreProgress = false
        var lastProgressedToSyllable: Syllable?

        /// 这一行有没有带 `Emphasis.factor` 的词。建层时算一次，
        /// 免得每帧为「一个光斑都不会出现」的行去扫一遍词表。`[补]`
        var hasEmphasis = false

        init() {}
    }
}

extension SyncedLyricsLineLayer.LayoutLine {

    /// 这一行在 `elapsed` 时刻的进度状态。[实测]/b3c。
    enum ProgressState: Sendable, Equatable {
        case notStarted
        case singing(syllableIndexInWord: Int, wordIndex: Int)
        case finished
    }

    /// 每帧走查。规格见 §7.2。
    ///
    /// [实测]。
    /// **音译行整个跳过音节层**（读 `isTransliteration`）——
    /// 音译文本没有逐字时间。
    ///
    /// - Returns: 每个音节是否「还没开始」，供音节层动画（§7.5）用；
    ///   顺序与 `words` × `syllables` 展平后一致。
    ///
    /// 未接线：Amber 的音节上抬按 `progress >= syllable.startTime` 就地判
    /// （`SBS_TextContentLayer.liftStartedSyllables`），没有先摊平成一张旗标表。
    func syllableNotStartedFlags(at elapsed: TimeInterval) -> [Bool] {
        guard !isTransliteration else { return [] }
        return words.flatMap { word in
            word.syllables.map { elapsed < $0.startTime }
        }
    }

    /// 三状态判定。注意边界：`endTime <= elapsed` 才算唱完，
    /// `elapsed >= startTime` 才算开始。
    func progressState(at elapsed: TimeInterval) -> ProgressState {
        if endTime <= elapsed { return .finished }
        guard elapsed >= startTime else { return .notStarted }
        var lastStarted: (syllable: Int, word: Int)?
        for (w, word) in words.enumerated() {
            for (s, syl) in word.syllables.enumerated() {
                // startTime > endTime 的音节直接跳过（脏数据保护）
                guard syl.startTime <= syl.endTime else { continue }
                if syl.startTime <= elapsed, elapsed < syl.endTime {
                    return .singing(syllableIndexInWord: s, wordIndex: w)
                }
                if syl.startTime <= elapsed {
                    lastStarted = (s, w)
                }
            }
        }
        // QRC 的相邻音节并不保证首尾相接。空档期间应保持在刚唱完的音节末端；
        // 退回 `.notStarted` 会把整行遮罩清零，表现为高亮唱到一半突然闪灭。
        if let lastStarted {
            return .singing(syllableIndexInWord: lastStarted.syllable,
                            wordIndex: lastStarted.word)
        }
        return .notStarted
    }
}

/// 渐变扫过的几何。规格见 §7.3。
enum LineProgressGradientGeometry {

    /// 渐变层要比行框多罩住多少（上下各一半）。
    ///
    /// [实测]：
    /// ```
    /// h   = CTFontGetAscent(font) + CTFontGetDescent(font)   ;，13 条指令
    /// h  *= specs.emphasizingScaleRange.upperBound           ; 1.14
    /// h  += 2 * specs.glowRadius                             ; 5
    /// pad = |h − line.frame.height| * 0.5
    /// ```
    ///
    /// 强调时字号放大到 1.14 倍、外面还有半径 5 的辉光。
    /// **只按行高铺渐变的话，强调峰值那一帧字的顶部和辉光会被切掉。**
    ///
    /// 注意取的是**墨高**（ascent + descent），不含 leading。
    static func verticalPadding(font: NSFont,
                                       lineHeight: CGFloat,
                                       specs: LyricsSpecs) -> CGFloat {
        let ink = font.ascender + abs(font.descender)
        let covered = ink * specs.emphasizingScaleRange.upperBound + 2 * specs.glowRadius
        return abs(covered - lineHeight) * 0.5
    }

    /// 唱完之后渐变的右端。
    ///
    /// [实测]：
    /// `width = pad + feather + (最后一个 word.frame.minX + 它最后一个 syllable.frame.maxX)`。
    ///
    /// **不是行宽**——行框可能比墨迹宽（居中排版留白），照行宽铺会多亮一截。
    static func finishedWidth(lastWordMinX: CGFloat,
                                     lastSyllableMaxX: CGFloat,
                                     verticalPadding pad: CGFloat,
                                     specs: LyricsSpecs) -> CGFloat {
        pad + specs.lineProgressionGradientFeather + (lastWordMinX + lastSyllableMaxX)
    }

    struct SweptGeometry: Equatable {
        var width: CGFloat
        var feather: CGFloat
    }

    /// 计算当前进度下渐变层的宽度与羽化宽度。
    ///
    /// 歌唱推进原则：
    /// 1. 连贯歌唱中（音节间无显著停顿）：羽化宽度恒定为 30pt（`specs.lineProgressionGradientFeather`），
    ///    推进前沿与渐变右端严格按音节时长匀速推进，确保丝滑无跳跃的手感。
    /// 2. 音节间停顿期（当前音节已唱完，距离下一音节开唱有 >= 0.15s 停顿）：
    ///    唱完后在 150ms 内将羽化软边平滑回缩至字间距内，使遮罩在停顿期间不越过下一个字的起始位置，
    ///    彻底消除停顿期间未唱字被静态半高亮的现象。
    /// 3. 停顿后开唱：在开唱前 120ms 内羽化从字间距平滑展开至 30pt，衔接无跳跃。
    static func sweptGeometry(of layoutLine: SyncedLyricsLineLayer.LayoutLine,
                              state: SyncedLyricsLineLayer.LayoutLine.ProgressState,
                              progress: Double,
                              verticalPadding padding: CGFloat,
                              specs: LyricsSpecs) -> SweptGeometry {
        let defaultFeather = specs.lineProgressionGradientFeather
        switch state {
        case .notStarted:
            return SweptGeometry(width: 0, feather: defaultFeather)
        case .finished:
            guard let word = layoutLine.words.last,
                  let syllable = word.syllables.last else {
                return SweptGeometry(width: 0, feather: defaultFeather)
            }
            let finished = finishedWidth(
                lastWordMinX: word.frame.minX,
                lastSyllableMaxX: syllable.frame.maxX,
                verticalPadding: padding,
                specs: specs)
            return SweptGeometry(width: finished, feather: defaultFeather)
        case .singing(let syllableIndex, let wordIndex):
            guard layoutLine.words.indices.contains(wordIndex) else {
                return SweptGeometry(width: 0, feather: defaultFeather)
            }
            let word = layoutLine.words[wordIndex]
            guard word.syllables.indices.contains(syllableIndex) else {
                return SweptGeometry(width: 0, feather: defaultFeather)
            }
            let syllable = word.syllables[syllableIndex]

            let span = syllable.endTime - syllable.startTime
            let ratio = span > 0 ? min(max((progress - syllable.startTime) / span, 0), 1) : 1
            let sylMinX = word.frame.minX + syllable.frame.minX
            let sylMaxX = sylMinX + syllable.frame.width
            let front = sylMinX + syllable.frame.width * ratio

            // 查找下一个音节与其在排版行中的起始坐标
            var nextSyl: SyncedLyricsLineLayer.Syllable?
            var nextSylMinX: CGFloat?
            if syllableIndex + 1 < word.syllables.count {
                let ns = word.syllables[syllableIndex + 1]
                nextSyl = ns
                nextSylMinX = word.frame.minX + ns.frame.minX
            } else {
                for nextW in (wordIndex + 1)..<layoutLine.words.count {
                    let nw = layoutLine.words[nextW]
                    if let firstSyl = nw.syllables.first {
                        nextSyl = firstSyl
                        nextSylMinX = nw.frame.minX + firstSyl.frame.minX
                        break
                    }
                }
            }

            // 查找上一个音节的结束时间
            var prevSylEndTime: TimeInterval?
            if syllableIndex > 0 {
                prevSylEndTime = word.syllables[syllableIndex - 1].endTime
            } else if wordIndex > 0 {
                for prevW in (0..<wordIndex).reversed() {
                    let pw = layoutLine.words[prevW]
                    if let lastSyl = pw.syllables.last {
                        prevSylEndTime = lastSyl.endTime
                        break
                    }
                }
            }

            // 1. 停顿期处理：当前音节已唱完（progress >= syllable.endTime），
            // 且与下一个音节之间存在停顿空档（gap >= 0.15s）。
            if let nextSyl, let nextMinX = nextSylMinX,
               nextSyl.startTime - syllable.endTime >= 0.15 {
                let pauseDuration = nextSyl.startTime - syllable.endTime
                let physicalGap = max(0, nextMinX - sylMaxX)
                let restingFeather = min(defaultFeather, physicalGap)

                if progress >= syllable.endTime {
                    let fadeDuration = min(0.15, pauseDuration * 0.3)
                    let elapsedInPause = progress - syllable.endTime
                    if elapsedInPause < fadeDuration && fadeDuration > 0 {
                        let t = elapsedInPause / fadeDuration
                        let smoothT = t * t * (3 - 2 * t)
                        let currentFeather = defaultFeather + (restingFeather - defaultFeather) * smoothT
                        let width = sylMaxX + currentFeather
                        return SweptGeometry(width: width, feather: currentFeather)
                    } else {
                        let width = sylMaxX + restingFeather
                        return SweptGeometry(width: width, feather: restingFeather)
                    }
                }
            }

            // 2. 停顿后起跑平滑处理：如果当前音节前曾有停顿（>= 0.15s），
            // 在开唱前 120ms 内羽化软边从平滑展开至 30pt，避免起跑跳变。
            if let prevEnd = prevSylEndTime,
               syllable.startTime - prevEnd >= 0.15,
               progress >= syllable.startTime {
                let bloomDuration = min(0.12, span * 0.4)
                let elapsedInSyl = progress - syllable.startTime
                if elapsedInSyl < bloomDuration && bloomDuration > 0 {
                    let prevMaxX = prevSylMaxX(layoutLine, wordIndex: wordIndex, syllableIndex: syllableIndex) ?? sylMinX
                    let physicalGap = max(0, sylMinX - prevMaxX)
                    let startFeather = min(defaultFeather, physicalGap)
                    let t = elapsedInSyl / bloomDuration
                    let smoothT = t * t * (3 - 2 * t)
                    let currentFeather = startFeather + (defaultFeather - startFeather) * smoothT
                    let width = front + currentFeather
                    return SweptGeometry(width: width, feather: currentFeather)
                }
            }

            // 3. 正常歌唱中（连贯音节，或停顿展开后）：羽化恒为 30pt，匀速丝滑推进！
            let feather = defaultFeather
            let width = front + feather
            return SweptGeometry(width: width, feather: feather)
        }
    }

    private static func prevSylMaxX(_ layoutLine: SyncedLyricsLineLayer.LayoutLine,
                                    wordIndex: Int,
                                    syllableIndex: Int) -> CGFloat? {
        if syllableIndex > 0 {
            let pw = layoutLine.words[wordIndex]
            let ps = pw.syllables[syllableIndex - 1]
            return pw.frame.minX + ps.frame.minX + ps.frame.width
        } else if wordIndex > 0 {
            for prevW in (0..<wordIndex).reversed() {
                let pw = layoutLine.words[prevW]
                if let ps = pw.syllables.last {
                    return pw.frame.minX + ps.frame.minX + ps.frame.width
                }
            }
        }
        return nil
    }
}

extension SpringTimingParameters {

    /// 逐字抬升 / 强调的弹簧。
    ///
    /// [实测] 就地建
    /// `CASpringAnimation`：`mass 1 / stiffness 14 / damping 7`，时长取`settlingDuration`。
    ///
    /// ω₀ = 3.742、ζ = 0.935——**欠阻尼、留一点点回弹**。
    /// 和翻行那条 (1, 100, 18) 的 ζ = 0.900 是同一个量级的手感，但慢得多
    /// （ω₀ 3.74 对 10.0）。`syllableLift = 2` 与`emphasizingScaleRange = 1.0…1.14`
    /// 都由它推动。
    static let syllableEmphasis = SpringTimingParameters(
        mass: 1, stiffness: 14, damping: 7)
}
