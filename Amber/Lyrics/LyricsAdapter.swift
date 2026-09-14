import Foundation

/// Amber 的歌词轨（`LyricParser` 的产物）→ Music 歌词模块的的数据模型。
///
/// 两边的形状差别不大，要留神的只有一条：**`LyricsLine.index` 必须等于它在
/// `lines` 里的下标**。实测确认视图数组与行数组是按下标一一对应的（行存在体的
/// `selecting line` 与`selecting`
/// 都直接拿它去取 `lineViews[index]`，中间没有查找表）。
enum LyricsAdapter {

    static func makeLyrics(from lines: [LyricLine]) -> Lyrics {
        var lyrics = Lyrics()
        guard !lines.isEmpty else { return lyrics }

        // 任一行带逐字时间轴就整首按逐字走——`lyrics.type == .timedWords` 是
        // §9.1 描述符工厂那条推导支的准入条件。
        let hasSyllables = lines.contains { !$0.syllables.isEmpty }
        lyrics.type = hasSyllables ? .timedWords : .timedLines
        // 源数据直接给的前奏长度：第一条内容的起点。
        lyrics.leadingSilence = lines.first?.time ?? 0

        var previousEnd: TimeInterval?
        lyrics.lines = lines.enumerated().map { index, line in
            defer { previousEnd = line.end }
            switch line.kind {
            case .interlude:
                var instrumental = InstrumentalLine()
                instrumental.index = index
                instrumental.startTime = line.time
                instrumental.endTime = line.end
                return instrumental

            case .credits:
                var songwriters = SongwritersLine()
                songwriters.index = index
                songwriters.text = line.text
                // 原版这一行的时间是 ±∞（永不选中、永不淘汰）。Amber 的解析器给了
                // 一段真实时长，但选中它没有意义——照原版留 ∞。
                return songwriters

            case .lyric:
                var text = TextLine()
                text.index = index
                text.startTime = line.time
                text.endTime = line.end
                // 主唱时间与整行时间在 QRC 里是同一组。
                text.primaryVocalsStartTime = line.time
                text.primaryVocalsEndTime = line.end
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
                // - **行级歌词那档的空隙是编出来的。** 没有逐字时间轴时 `end` 按字数估
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
                // agentAlignment / backgroundVocals：QRC/LRC 不提供，
                // 留默认值走普通行那条路。
                return text
            }
        }

        lyrics.songwriters = lines
            .filter { $0.kind == .credits }
            .map(\.text)
        return lyrics
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
