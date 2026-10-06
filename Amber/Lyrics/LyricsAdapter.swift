import Foundation

/// Amber 的歌词轨（`LyricParser` 的产物）→ Music 歌词模块的的数据模型。
///
/// 两边的形状差别不大，要留神的只有一条：**`LyricsLine.index` 必须等于它在
/// `lines` 里的下标**。实测确认视图数组与行数组是按下标一一对应的（行存在体的
/// `selecting line` 与`selecting`
/// 都直接拿它去取 `lineViews[index]`，中间没有查找表）。
enum LyricsAdapter {

    /// - Parameter handover: 一次翻行滚动的时长（`LyricsSpecs.scrollLead`）。
    ///   间奏行两头各让出这么宽的进出场余量，见下面 `.interlude` 那一支。
    static func makeLyrics(from lines: [LyricLine],
                           handover: TimeInterval = LyricsSpecs().scrollLead) -> Lyrics {
        var lyrics = Lyrics()
        guard !lines.isEmpty else { return lyrics }

        // 任一行带逐字时间轴就整首按逐字走——`lyrics.type == .timedWords` 是
        // §9.1 描述符工厂那条推导支的准入条件。
        //
        // `.static` 是第三档：整份词一个时间戳都没有（`LyricParser` 的无戳路径）。
        // 它决定的是渲染契约（`LyricsSpecs.renderingMode`），不是某一行的形态，
        // 所以在这里判一次、往下只读这个结论。
        let hasSyllables = lines.contains { !$0.syllables.isEmpty }
        lyrics.type = lines.isUntimed
            ? .static
            : (hasSyllables ? .timedWords : .timedLines)
        // 源数据直接给的前奏长度：第一条内容的起点。
        lyrics.leadingSilence = lines.first?.time ?? 0

        // 名册 → 左右两栏。`vocalistsType` 今天没有读者（`Lyrics.swift` 里只有声明），
        // 填它是为了模型完整；界面上的可见变化全部来自 `agentAlignment`。
        let voices = Set(lines.compactMap { $0.vocalist?.index }).count
        lyrics.vocalistsType = voices >= 3 ? .group : (voices == 2 ? .duet : .single)
        let alignments = agentAlignments(for: lines)

        var previousEnd: TimeInterval?
        lyrics.lines = lines.enumerated().map { index, line in
            defer { previousEnd = line.end }
            switch line.kind {
            case .interlude:
                var instrumental = InstrumentalLine()
                instrumental.index = index
                // **间奏行不是一句，是那段空档的可视化——它得给自己留出进场与退场。**
                //
                // 解析器给的是空档本身：`time = 上一句唱完`、`end = 下一句开唱`，
                // 两头贴死（`LyricParser` 那两处 `.interlude`）。照这个区间走，通用
                // 机制的两个时刻会落在错的地方——而且方向相反：
                //
                // - 准入是 `startTime − scrollLead`（`shouldAdmit` 的第 2 条路），
                //   而展开 + 滚动就是在准入那一刻起跑的（`select(_:)` 的间奏支）。
                //   于是**上一句还在唱，画面就开始往间奏走**。间奏至少 5 秒
                //   （`LyricParser.interludeMinGap`），是全曲最不赶时间的地方。
                // - 淘汰是 `endTime − animationHeadstart`（0.1 s），而收起 + 滚到
                //   下一句跑的是一整条翻行弹簧（0.89 s）。于是**落位比下一句开唱
                //   晚 0.79 秒**——恰恰是该提前的那一头没提前。
                //
                // 两头各让出一个翻行的量之后，那两个时刻自己就对了：
                //
                //     展开在上一句唱完那一刻起跑，跑完正好是 `startTime`；
                //     收起在 `endTime` 起跑，跑完正好是下一句开唱。
                //
                // 于是这两个字段有了准确语义：**行完全展开着的那一段**。
                // 选中 / 淘汰 / 焦点位 / 滚动一行都不用为间奏特判，
                // `handoverDuration` 拿到的空档也从 0 变成一整条 `scrollLead`。
                //
                // 前奏行（下标 0）头上不让：它没有上一句要等，`startTime` 必须留在
                // 源数据给的那一刻（通常是 0），否则第一帧准不进来。
                let head = index == 0 ? 0 : handover
                let room = max(line.end - line.time - head - handover, 0)
                instrumental.startTime = line.time + head
                // 余量比空档还宽时退化成零长行（`interludeMinGap = 5` 下不会发生，
                // 门槛哪天调小才谈得上）：准入即淘汰，不会翻成负区间。
                instrumental.endTime = instrumental.startTime + room
                // 行**张开**那一刻就是空档的起点：展开在这里起跑，行高瞬时变 40，
                // 三个点从这一刻起就在屏幕上。点阵的时间窗以它为原点，不是`startTime`
                // （那是撑开落定的时刻）——两者差一个展开动画，见 `InstrumentalLine.openTime`。
                instrumental.openTime = line.time
                return instrumental

            case .credits:
                var songwriters = SongwritersLine()
                songwriters.index = index
                songwriters.text = line.text
                // 原版这一行的时间是 ±∞（永不选中、永不淘汰）。Amber 的解析器给了
                // 一段真实时长，但选中它没有意义——照原版留 ∞。
                return songwriters

            case .plain:
                // 纯文本行：没有任何时间可言。时间给 ±∞ 而不是 0——与 `SongwritersLine`
                // 同解（永不选中、永不淘汰），也让 `SyncedLyricsView.Coordinator` 里
                // 那道 `startTime.isFinite` 天然把点击跳转挡掉，不依赖单独某一道闸。
                var plain = TextLine()
                plain.index = index
                plain.startTime = .infinity
                plain.endTime = .infinity
                plain.primaryVocalsStartTime = .infinity
                plain.primaryVocalsEndTime = .infinity
                plain.text = line.text
                plain.translation = line.translation.flatMap { $0.isEmpty ? nil : $0 }
                plain.transliteration = line.transliteration.flatMap { $0.isEmpty ? nil : $0 }
                // 段首是**解析层给的结构信息**（纯文本里的空行），不是从时间轴上猜的，
                // 与下面 `.lyric` 那一大段「不要再猜段落」并不矛盾。
                plain.isFirstLineOfParagraph = line.startsParagraph
                plain.agentAlignment = alignments[index]
                return plain

            case .lyric:
                var text = TextLine()
                text.index = index
                text.startTime = line.time
                // **行级歌词与下一句首尾相接时，尾巴让出一次翻行。**
                //
                // LRC 不知道一句什么时候唱完，解析器只能让它占到下一句开唱
                //（`LyricParser.assemble`）。照这个区间走，`handoverDuration` 拿到的空档是 0，
                // 每次翻行都是瞬时跳格。让出 `handover` 之后与间奏行同一个道理：
                // 滚动在 `endTime` 起跑，跑完正好是下一句开唱——不提前点亮、也不晚落位。
                //
                // 只管没有逐字的行、且下一条是普通句：逐字行的结束是真唱完的时刻，不动；
                // 下一条是间奏时间奏行自己头上已经让过了，再让就是两份。
                var end = line.end
                if line.syllables.isEmpty, index + 1 < lines.count,
                   lines[index + 1].kind == .lyric, end >= lines[index + 1].time {
                    end = max(line.time, lines[index + 1].time - handover)
                }
                text.endTime = end
                // 主唱时间与整行时间在 QRC 里是同一组。
                text.primaryVocalsStartTime = line.time
                text.primaryVocalsEndTime = end
                // 段首只认「前面一条都没有」这一种。段落是**结构信息**：原版的 TTML
                // 用 `<div>` 直接声明，QRC / YRC / LRC 一家都不给。早先按「与上一句
                // 空了 ≥3 秒」猜，猜出来的就是实机上那种忽宽忽窄的行距——
                //
                // - **有效窗口只有 2 秒宽。** 空隙 ≥5 秒会先被
                //   `LyricParser.interludeMinGap` 插成间奏行，而收起态的间奏行既不占
                //   高度也不产生行距（§16.1 / §16.2），前后两行的间距与普通行完全一样。
                //   于是「加 39」只可能发生在 3–5 秒这一段里，慢歌的换气正好在这个
                //   区间反复横跳。
                // - **顺序还是反的。** 空 3.2 秒 → 大间隔；空 6 秒（真·间奏）→ 与普通
                //   行同宽。空得越久反而越挤。
                // - **行级歌词那档的空隙曾经是编出来的。** 没有逐字时间轴时 `end` 一度按字数估
                //   （`LyricParser.secondsPerCharacter`），「空了多久」约等于「上一句
                //   有几个字」，短句后面必出一个大间隔。
                //
                // 真停顿由间奏行表达，够了。音源哪天给出段落结构，从那里接回来，
                // 不要再从时间轴上猜。
                text.isFirstLineOfParagraph = previousEnd == nil
                text.text = line.text
                text.translation = line.translation.flatMap { $0.isEmpty ? nil : $0 }
                text.transliteration = line.transliteration.flatMap { $0.isEmpty ? nil : $0 }
                let emphasis = synthesizeEmphasis(line.syllables)
                text.syllables = line.syllables.enumerated().map { index, syllable in
                    TextLine.SyllableTiming(text: syllable.text,
                                            startTime: syllable.time,
                                            endTime: syllable.end,
                                            transliteration: syllable.transliteration,
                                            emphasis: emphasis[index])
                }
                // 有逐字时间轴才谈得上渐变扫过与抬升。
                //
                // **`.emphasis` 不给**：代码里读这一位的只有字形（`Glyph`）层建不建
                // （见 `SBS_TextContentLayer` 文件头），给了会改排版；而辉光与强调缩放
                // 要的是 `Emphasis.factor` 这份**数据**，不是这一位能力
                // ——§23.3 的闸查的是词的 emphasis tag，不是行的 capability。
                text.capabilities = line.syllables.isEmpty ? [] : [.gradient, .lift]
                text.agentAlignment = alignments[index]
                // backgroundVocals：QRC/LRC 不提供，留默认值走普通行那条路。
                return text
            }
        }

        lyrics.songwriters = lines
            .filter { $0.kind == .credits }
            .map(\.text)
        return lyrics
    }

    // MARK: - 对唱分栏

    /// 名册 → 二元对齐位。
    ///
    /// 载体只有 `normal` / `flipped` 两档，而名册可以有 5 个人
    /// （BIGBANG《BANG BANG BANG》：TAEYANG / T.O.P / 승리 / G-DRAGON / 대성）。
    ///
    /// 规则：**每换一次人就换一次边**，从 `.normal` 起。对唱本来就是「你一句我一句」，
    /// 换边表达的是「换人了」这件事本身，而不是「你是第几位歌手」——按名册序号的奇偶
    /// 分边则要看「谁先被点名」这个偶然。两人对唱时它退化成「甲左乙右」。
    ///
    /// 代价：同一位歌手在不同段落可以落到不同侧（上面那首实测没有发生——
    /// TAEYANG 恒左、G-DRAGON 恒右）。真要「同一人恒同侧」，换成
    /// 「行数最多者 normal、其余 flipped」即可，不动结构。`[推]`
    /// 返回与 `lines` **等长**的对齐位：换边是按段落发生的，不是按人固定的，
    /// 所以结果不能按歌手编号收进字典。
    static func agentAlignments(for lines: [LyricLine]) -> [Lyrics.AgentAlignment] {
        var result: [Lyrics.AgentAlignment] = []
        result.reserveCapacity(lines.count)
        var previous: Int?
        var flipped = false
        for line in lines {
            // 间奏、创作者、以及第一条提示之前的行都没有归属：留在左边，也不影响换边节奏。
            guard let index = line.vocalist?.index else {
                result.append(.normal)
                continue
            }
            if let previous, previous != index { flipped.toggle() }
            previous = index
            result.append(flipped ? .flipped : .normal)
        }
        return result
    }

    // MARK: - 强调因子的合成 `[补]`

    /// 给一行的逐字单元合成 `Emphasis`。
    ///
    /// **这是 Amber 自己的推导，不是实测。** 原版 `Emphasis.factor` 的生产侧是服务端数据
    /// （§23.8 明确记为 `[缺口]`：TTML 名字空间里没有 emphasis 相关属性串，
    /// 原版里也没有对应的字面量）；QQ 的 QRC 与网易的 YRC 都只给
    /// `字(起点, 时长)`，一个强调字段都没有。照 §23 把整条链实现完之后，
    /// 没有这份数据就等于「一个光斑都不会出现」——所以这里补一条合成规则。
    ///
    /// 规则（一句话）：**一个音节比本行的常规音节多拖了多少个自身长度，就有多亮；
    /// 拖满一倍（2×）到顶。**
    ///
    /// ```
    /// p_i    = 音节时长 / max(1, 音节的字符数)        // 换成「每个字拖多久」
    /// p_ref  = 本行 p 的中位数
    /// factor = clamp(p_i / p_ref − 1, 0, 1)
    /// ```
    ///
    /// 三条依据，都是规律不是样本：
    ///
    /// 1. **强调 = 拖长**。逐字歌词里被强调的就是被唱住的那个字（长音、拖腔）。
    ///    这是把「时长」当强调信号的唯一理由，与具体是哪首歌无关。
    /// 2. **参照系取本行、取中位数**。歌速、断句粒度逐行逐曲都不同，绝对秒数没有可比性；
    ///    中位数而不是均值，是因为要检测的正是那几个离群的长音——用均值会被它们自己抬高，
    ///    检测灵敏度反而随「这行有几个长音」浮动。
    /// 3. **归一化到「翻倍」**。分母取 `p_ref` 自身、满点定在 2×，
    ///    是因为「比常规长一倍」本身就是一个自然刻度，不需要任何试出来的系数；
    ///    上下界直接是 `glowRange` 公式要求的`[0, 1]`。
    ///    换成 1.5× 或 3× 只会整体变亮/变暗，不改变「哪些字发光」的排序。
    ///
    /// 除以字符数是因为一个单元可能是「一个汉字」也可能是「一个英文词」——
    /// 同一行内源数据的粒度是一致的，除掉之后剩下的才是「拖了多久」。
    ///
    /// 落到 `.none` 而不是`.factor(0)`：§23.3 的第四道闸对`.none` 是**整词跳过**，
    /// 不建阴影、不起 ramp；`.factor(0)` 会白跑一遍强度恒 0 的链路。
    static func synthesizeEmphasis(_ syllables: [LyricSyllable]) -> [Lyrics.Emphasis] {
        let none = [Lyrics.Emphasis](repeating: .none, count: syllables.count)
        // 一个音节没有参照系（中位数就是它自己），谈不上「比常规长」。
        guard syllables.count >= 2 else { return none }

        let perCharacter: [Double] = syllables.map { syllable in
            let characters = syllable.text.reduce(into: 0) {
                if !$1.isWhitespace { $0 += 1 }
            }
            return syllable.duration / Double(max(characters, 1))
        }
        guard let reference = median(perCharacter), reference > 0 else { return none }

        return perCharacter.map { value in
            let factor = min(max(value / reference - 1, 0), 1)
            // 浮点误差级别的「长一点点」不算强调。
            return factor > 0.001 ? .factor(factor) : Lyrics.Emphasis.none
        }
    }

    private static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
