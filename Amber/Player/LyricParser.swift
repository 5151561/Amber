import Foundation

/// LRC / QRC / YRC 歌词解析。
///
/// 输出的不是原始歌词行的一一映射，而是一条**可直接播放的歌词轨**，跟 Music 对齐：
///
/// - 逐字：QQ 的 QRC `[行起点,行时长]字(起点,时长)…` 与网易的 YRC
///   `[行起点,行时长](起点,时长,0)字…` 都解析成 `LyricSyllable`
///   （两家把时间戳放在字的**两边**，见 `parseTimedLine`）；纯 LRC 没有这一层，退回整行。
/// - 间奏：相邻两句之间空得够久就插一行 `.interlude`（界面上是三个点），
///   不让上一句在屏幕中间干等。开头一大段前奏同理。
/// - 创作者：开头那一坨「歌名 - 歌手 / 词：/ 曲：/ 编曲：/ 制作人：…」不是歌词，
///   整块摘掉；其中只留词作者与曲作者，合成一行「创作者：A、B」（同一个人不重复），
///   作为 `.credits` 挂到整首歌的最尾部。
///
/// 一行多个时间戳会展开成多行；元信息行（`[ti:]` 等）忽略。
/// 翻译按时间就近匹配（容差 0.6 秒）。
///
/// 还有第三档：**整份词一条时间戳都没有**（纯文本歌词）。那时全部时间派生物
/// （间奏、行结束、按时间认领副行）都无从谈起，走 `parseUntimed` 出一份
/// `.plain` 行，界面静态整页显示。
enum LyricParser {

    // MARK: - 时长推断参数
    //
    // QRC 自带每行时长，LRC 没有，只能估：不估的话「行结束」只能取下一行的起点，
    // 于是永远不存在空隙，间奏和「唱完先翻页」这两件事都无从谈起。

    /// 每个字大致唱多久。[推]
    private static let secondsPerCharacter: TimeInterval = 0.28
    /// 一行至少占这么久，避免「嗯」「啊」这种一个字的行瞬间就算唱完。[推]
    private static let minLineDuration: TimeInterval = 1.2
    /// 空白到这个长度才值得插三个点；再短就只是正常的换气。[推]
    private static let interludeMinGap: TimeInterval = 5
    /// 尾部创作者停留多久（够读完即可）。[推]
    private static let creditsDuration: TimeInterval = 20

    // MARK: - 入口

    static func parse(_ text: String, translation: String? = nil,
                      transliteration: String? = nil) -> [LyricLine] {
        var raw = parseTimedLines(text)
        // **一条真正带时间戳的行都没有** ⇒ 纯文本歌词，走无戳那条路。
        //
        // 判据不能写成「`raw` 为空」：网易的 `lrc` 可以是「JSON 制作人信息头 + 无戳正文」，
        // 那些头行被 `parseNeteaseMetaLine` 以 `time = 0` 收下，`raw` 非空，
        // 而正文一行都没进来——那样照旧返回 `[]`，界面显示「暂时没有歌词」。
        //
        // 这一句必须排在下面 `removeAll` **之前**：占位行（`[00:10.00]//`）被滤空之后
        // `raw` 也会变空，但那是「有时间戳、只是没文字」，它该留在带戳这条路上返回 `[]`。
        guard raw.contains(where: { !$0.isMetadata }) else {
            return parseUntimed(text, translation: translation,
                                transliteration: transliteration)
        }
        // 正文不要空文字行（占位行是给副行对齐用的，正文里没有意义）。
        raw.removeAll { $0.text.isEmpty }
        guard !raw.isEmpty else { return [] }

        var credits = stripLeadingCredits(&raw)
        // 尾部也有一块（《从未见过的海》正文唱完后接 16 行制作人/编曲/录音师…）。
        // 词曲只在头块缺位时才由尾块补——见 `Credits.fillGaps`。
        credits.fillGaps(from: stripTrailingCredits(&raw))
        guard !raw.isEmpty else { return [] }
        markAgentCues(&raw)

        let trans = translation.map { parseTimedLines($0) } ?? []
        // 音译（Music 界面上叫「发音」）：QQ 的 `roma` 常常是 QRC 逐字格式、
        // 网易的 `yromalrc` 是 YRC 逐字、`romalrc` 是纯 LRC，
        // `parseTimedLines` 三种都认，按时间就近配对。
        let roma = transliteration.map { parseTimedLines($0) } ?? []
        return assemble(raw, translation: trans, transliteration: roma, credits: credits)
    }

    // MARK: - 原始行

    private struct RawLine {
        var time: TimeInterval
        /// QRC / YRC 给的行时长；LRC 没有
        var declaredDuration: TimeInterval?
        var text: String
        var syllables: [LyricSyllable]
        /// 网易那种 JSON 制作人信息行（见 `parseNeteaseMetaLine`）。
        /// 它们**一定**不是歌词，摘除时不受 `creditKeys` 白名单约束。
        var isMetadata = false
        /// 独立成行的歌手提示行（`TAEYANG：`）。**留到最后一刻才摘**，见 `markAgentCues`。
        var isAgentCue = false
        /// 这一行归谁唱。由上方最近一条提示行给出。
        var vocalist: LyricLine.Vocalist?
        /// 上面隔着一个空行 ⇒ 这一行是段首。**只有无戳那条路会置真**：
        /// 带戳的歌词里空行是副行的占位，不是段落（见 `untimedRawLines`）。
        var startsParagraph = false
    }

    private static let lrcTimestamp = try! NSRegularExpression(
        pattern: "\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]")
    /// QRC / YRC 共用的行头 `[起点ms,时长ms]`
    private static let qrcHeader = try! NSRegularExpression(
        pattern: "^\\[(\\d+),(\\d+)\\]")
    /// QRC 音节 `字(起点ms,时长ms)`
    private static let qrcSyllable = try! NSRegularExpression(
        pattern: "([^()]*)\\((\\d+),(\\d+)\\)")
    /// YRC 音节 `(起点ms,时长ms,0)字`。第三个数是网易自己的标记位，一直是 0，只做占位。
    private static let yrcSyllable = try! NSRegularExpression(
        pattern: "\\((\\d+),(\\d+),(-?\\d+)\\)([^()]*)")

    private static func parseTimedLines(_ text: String) -> [RawLine] {
        var items: [RawLine] = []
        for rawLine in text.components(separatedBy: .newlines) {
            if let meta = parseNeteaseMetaLine(rawLine) {
                items.append(meta)
                continue
            }
            if let timed = parseTimedLine(rawLine) {
                items.append(timed)
                continue
            }
            items.append(contentsOf: parseLRCLine(rawLine))
        }
        return items.sorted { $0.time < $1.time }
    }

    /// 网易 `yrc` / `lrc` 开头那一坨制作人信息，是 JSON 不是歌词行：
    /// `{"t":0,"c":[{"tx":"作词: "},{"tx":"唐恬","li":"…","or":"orpheus://…"}]}`。
    ///
    /// 直接扔掉最省事，但那样就把「创作者」那行的来源也一起扔了——网易的逐字歌词里
    /// **只有这里**写了词曲作者。所以拼回「作词: 唐恬」这样一行普通文本，
    /// 交给下面 `stripLeadingCredits` 按老路认领，尾部照样能排出「创作者：…」。
    private static func parseNeteaseMetaLine(_ rawLine: String) -> RawLine? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parts = object["c"] as? [[String: Any]]
        else { return nil }
        let text = parts.compactMap { $0["tx"] as? String }.joined()
            .trimmingCharacters(in: .whitespaces)
        // `t` 是毫秒；这一坨一律在最前面（实测都是 0），排序靠它就够。
        let time = ((object["t"] as? Double) ?? 0) / 1000
        return RawLine(time: time, declaredDuration: nil, text: text,
                       syllables: [], isMetadata: true)
    }

    /// QQ 对「这一行没有译文 / 没有发音」给的是占位符 `//`（有时是 `/`、`///`），
    /// 不是空串。照原样排上去就是副行里一串斜杠。
    private static func isPlaceholder(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0 == "/" }
    }

    /// 把副行按序认领给正文行。
    ///
    /// **不能各行独立「找最近的一条」**：那样一条译文可以被两行认领。
    /// `G-DRAGON：`（54748）这种歌手提示行与下一句（55294）只差 0.546 秒，
    /// 独立就近匹配时它会把下一句的译文抢过来，两行显示同一句。
    ///
    /// 与音节那边同解：每个正文行去副行序列里认领时间最接近的一条，游标只前进，
    /// 两行认领到同一条时归**先来的**那个，后来的拿不到（它本来就没有）。
    /// 占位行不丢、留着占位，提示行于是认领到自己那条空的，各归各位。
    private static func claim(_ secondary: [RawLine], for lines: [RawLine]) -> [Int?] {
        guard !secondary.isEmpty else { return Array(repeating: nil, count: lines.count) }
        var heads: [Int] = []
        var cursor = 0
        for (offset, line) in lines.enumerated() {
            while cursor + 1 < secondary.count {
                let current = abs(secondary[cursor].time - line.time)
                let next = abs(secondary[cursor + 1].time - line.time)
                if next < current {
                    cursor += 1
                    continue
                }
                // 平手：下一个正文行离它更远，才由我拿走。
                guard next == current, offset + 1 < lines.count,
                      abs(secondary[cursor + 1].time - lines[offset + 1].time) > next
                else { break }
                cursor += 1
            }
            heads.append(cursor)
        }
        return heads.enumerated().map { offset, head -> Int? in
            // 只有第一个认领到这一条的行拿得到。
            guard offset == 0 || heads[offset - 1] < head else { return nil }
            // 最后一道闸：认领到的东西离得太远就当没有（副行整个对不上时兜底）。
            guard abs(secondary[head].time - lines[offset].time) < secondaryMaxDrift,
                  !secondary[head].text.isEmpty
            else { return nil }
            return head
        }
    }

    /// 认领到的副行离正文行最远能差多少，超了就当这行没有。`[推]`
    private static let secondaryMaxDrift: TimeInterval = 0.6

    /// QRC / YRC 行。两家的行头一样（`[起点,时长]`），差别只在音节的时间戳
    /// 写在字的**后面**（QQ：`字(起点,时长)`）还是**前面**（网易：`(起点,时长,0)字`）。
    /// 两种写法互不误命中：QRC 的括号里只有两个数，YRC 的有三个。
    private static func parseTimedLine(_ rawLine: String) -> RawLine? {
        let ns = rawLine as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let header = qrcHeader.firstMatch(in: rawLine, range: full),
              let start = Double(ns.substring(with: header.range(at: 1))),
              let duration = Double(ns.substring(with: header.range(at: 2)))
        else { return nil }

        let bodyRange = NSRange(location: header.range.length,
                                length: ns.length - header.range.length)
        let body = ns.substring(with: bodyRange)
        let bodyNS = body as NSString
        let bodyFull = NSRange(location: 0, length: bodyNS.length)
        var syllables: [LyricSyllable] = []
        var plain = ""
        // 同一条 body 只跑一遍正则，下面判「有没有音节标记」直接看这批结果。
        // YRC 先试：它的括号里有三个数，QRC 的正则匹配不到它，反之亦然。
        let yrcMatches = yrcSyllable.matches(in: body, range: bodyFull)
        let syllableMatches = yrcMatches.isEmpty
            ? qrcSyllable.matches(in: body, range: bodyFull)
            : yrcMatches
        // 文字与时间在两种格式里的捕获组位置不同，取值前先分清是哪一种。
        let textGroup = yrcMatches.isEmpty ? 1 : 4
        let timeGroup = yrcMatches.isEmpty ? 2 : 1
        for match in syllableMatches {
            let word = bodyNS.substring(with: match.range(at: textGroup))
            let wordStart = (Double(bodyNS.substring(with: match.range(at: timeGroup))) ?? 0) / 1000
            let wordDuration = (Double(bodyNS.substring(with: match.range(at: timeGroup + 1))) ?? 0) / 1000
            plain += word
            guard !word.isEmpty else { continue }
            syllables.append(LyricSyllable(text: word, time: wordStart, duration: wordDuration))
        }
        // 没有音节标记的 QRC 行（纯文字）也认，退回整行。
        // **但音节标记存在、文字却全是空的那种行不算**——QQ 的 roma / trans 里
        // 常有 `[119759,1248](119759,1248)`、`[2131,1279] (3157,253)` 这样的占位行，
        // 照 body 兜底会把时间标记本身当成歌词排上屏。
        let hasSyllableMarkup = !syllableMatches.isEmpty
        if plain.isEmpty, !hasSyllableMarkup { plain = body }
        let content = plain.trimmingCharacters(in: .whitespaces)
        // 占位行**留着占位**，只把文字清空：副行要靠它与正文按序对上，
        // 丢掉的话「TAEYANG：」这类提示行没有自己的条目，会去认领下一句的译文。
        // 正文那边由 `parse` 把空文字行滤掉。
        return RawLine(time: start / 1000, declaredDuration: duration / 1000,
                       text: isPlaceholder(content) ? "" : content,
                       syllables: sanitize(syllables, lineStart: start / 1000))
    }

    /// 音节时间轴对不上（不单调、跑到行首之前）时宁可不要，退回整行高亮。
    private static func sanitize(_ syllables: [LyricSyllable],
                                 lineStart: TimeInterval) -> [LyricSyllable] {
        guard !syllables.isEmpty else { return [] }
        var cursor = lineStart - 0.001
        for s in syllables {
            guard s.time >= cursor else { return [] }
            cursor = s.time
        }
        return syllables
    }

    private static func parseLRCLine(_ rawLine: String) -> [RawLine] {
        let ns = rawLine as NSString
        let matches = lrcTimestamp.matches(in: rawLine, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return [] }

        // 最后一个时间戳之后的内容是正文。空行也留着——副行要靠它占位。
        var content = ns.substring(from: last.range.location + last.range.length)
        // 行内逐字标记在 LRC 语境下没有可靠的绝对时间，只取文字
        content = content
            .replacingOccurrences(of: "\\(\\d+,\\d+\\)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // 同 QRC：`//` 这种占位行留着占位，文字清空。
        if isPlaceholder(content) { content = "" }

        return matches.map { match in
            let minutes = ns.substring(with: match.range(at: 1))
            let seconds = ns.substring(with: match.range(at: 2))
            let fractionRange = match.range(at: 3)
            let fraction = fractionRange.location != NSNotFound ? ns.substring(with: fractionRange) : "0"
            let time = (Double(minutes) ?? 0) * 60
                + (Double(seconds) ?? 0)
                + (Double(fraction) ?? 0) / pow(10, Double(fraction.count))
            return RawLine(time: time, declaredDuration: nil, text: content, syllables: [])
        }
    }

    // MARK: - 创作者信息

    struct Credits: Equatable {
        var lyricist: String?
        var composer: String?
        var isEmpty: Bool { names.isEmpty }

        /// Music 把词与曲合成一行「创作者」（`Lyrics.songwriters: [String]`，
        /// 由 `SongwritersLine` 整行渲染），不是「词：X / 曲：Y」两行。
        /// 词曲同一个人时只出现一次——所以这里是一份**去重后的人名表**，
        /// 一个字段里挂多个人（`词：A/B`）也拆开。
        var names: [String] {
            var seen = Set<String>()
            var result: [String] = []
            for value in [lyricist, composer].compactMap({ $0 }) {
                for piece in value.split(whereSeparator: { Self.nameSeparators.contains($0) }) {
                    let name = piece.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, seen.insert(name).inserted else { continue }
                    result.append(name)
                }
            }
            return result
        }

        /// 认下一条角色署名。**只填 `nil`**：同一首歌里 `词：` 出现两次时以先认到的为准。
        fileprivate mutating func adopt(_ role: SongwriterRole, value: String) {
            switch role {
            case .lyricist:
                if lyricist == nil { lyricist = value }
            case .composer:
                if composer == nil { composer = value }
            case .both:
                if lyricist == nil { lyricist = value }
                if composer == nil { composer = value }
            case .none:
                break // 编曲 / 制作人 / 吉他 / 混音…：认出来是为了摘掉，不展示
            }
        }

        /// 头块缺位时由尾块补。**只填 `nil`，不覆盖**：一首歌的词曲作者按惯例写在
        /// 开头，尾块那份是同一份信息的重复（或者只有尾块有）。
        mutating func fillGaps(from other: Credits) {
            if lyricist == nil { lyricist = other.lyricist }
            if composer == nil { composer = other.composer }
        }

        private static let nameSeparators: Set<Character> = ["/", "、", ",", "，", "&", "＆", ";", "；", "|"]
    }

    /// 开头那一块非歌词行：`歌名 - 歌手`、`词：`、`编曲 Arranger：`、`OP：`…
    ///
    /// 三条规律，缺一条就漏：
    ///
    /// 1. **只扫开头连续的一段**：正文里出现「XX：YY」是可能的（对白、旁白），
    ///    从头扫到尾会误伤。
    /// 2. **角色名列不完**（`弦乐编写`、`录音混音`、`音乐企划`…），所以不认整个键、
    ///    认词根，中英两侧各认各的；再加上「中文 + 英文对照」这个写法本身
    ///    （`封面设计 Cover Designer`）——那是制作表的排版习惯，歌词不会这么写。
    /// 3. **这一块是连着的**：认不出的行先挂起（只推进不摘），后面再出现一条认得出的，
    ///    夹在中间的就跟着一起摘；块尾之后一行都不多摘。所以漏认一条不会连累整块。
    private static func stripLeadingCredits(_ lines: inout [RawLine]) -> Credits {
        var credits = Credits()
        var cut = 0 // 已确认的块尾：`lines[..<cut]` 都不是歌词
        scan: for (offset, line) in lines.enumerated() {
            if offset == 0, cut == 0, isHeaderLine(line.text) {
                cut = 1
                continue
            }
            switch classify(line, insideBlock: cut > 0) {
            case .stop:
                break scan
            case .suspended:
                continue // 认不出的先挂起：要么被后面某条确认行带走，要么留在正文里
            case .confirmed(let role, let value):
                cut = offset + 1
                credits.adopt(role, value: value)
            }
        }
        lines.removeFirst(cut)
        return credits
    }

    /// 结尾那一块制作表（《从未见过的海》正文唱完后接 16 行「制作人 Produer：…」）。
    ///
    /// 与开头那块**同一套判据**（`classify`），只是锚点在末行、扫描方向相反。
    /// 另加一条尾部专有的闸：**摘完必须还剩正文**。开头那块有「第 0 行」这个天然锚点
    /// （文件第一行不可能是歌的第二句），尾块没有——它的扫描方向是**朝着正文去的**，
    /// 一旦连续判错就会一路吃进副歌。所以整首都被判成制作信息时整块不摘。
    private static func stripTrailingCredits(_ lines: inout [RawLine]) -> Credits {
        var credits = Credits()
        var cut = lines.count // 已确认的块首：`lines[cut...]` 都不是歌词
        scan: for offset in stride(from: lines.count - 1, through: 0, by: -1) {
            switch classify(lines[offset], insideBlock: cut < lines.count) {
            case .stop:
                break scan
            case .suspended:
                continue
            case .confirmed(let role, let value):
                cut = offset
                credits.adopt(role, value: value)
            }
        }
        guard cut > 0, cut < lines.count else { return Credits() }
        lines.removeLast(lines.count - cut)
        return credits
    }

    /// 一行在块扫描里的去向。头块与尾块共用，两边只差扫描方向。
    private enum CreditScan {
        /// 确认不是歌词，块界推到这一行
        case confirmed(role: SongwriterRole, value: String)
        /// 认不出的「键：值」，先挂起（只推进不摘）
        case suspended
        /// 块到此为止
        case stop
    }

    private static func classify(_ line: RawLine, insideBlock: Bool) -> CreditScan {
        // 版权声明按定义就不是歌词，且**不中断块扫描**——《我天生-有梦版》里它排在
        // 「词：/曲：」之后、正文之前，中断的话它连同上面已认的两行一起留在屏上。
        if isNoticeLine(line.text) { return .confirmed(role: .none, value: "") }
        // 值为空的「键：」有两种去向：角色名是制作残行（`编曲：`），人名是歌手提示行。
        // 后者留给 `markAgentCues`，这里只摘前者。判据与 `speakerCue` 用**同一句**，
        // 两边才不会对同一行给出两种解释。
        if let key = emptyValueKey(in: line.text) {
            return isCreditKey(key, insideBlock: false) ? .confirmed(role: .none, value: "") : .stop
        }
        guard let (key, value) = creditPair(in: line.text) else {
            // 网易那种 JSON 信息行按定义就不是歌词，认不出角色名也照样摘掉。
            return line.isMetadata ? .confirmed(role: .none, value: "") : .stop
        }
        guard line.isMetadata || isCreditKey(key, insideBlock: insideBlock) else { return .suspended }
        return .confirmed(role: songwriterRole(of: key), value: value)
    }

    /// 整行版权声明（`【本作品声明，著作权权利保留。未经著作权人书面许可…】`）。
    ///
    /// 判据是**两条形态规律的合取**，不是关键词表：
    ///
    /// 1. 整行被一对「标示括号」包住（`【】` `〖〗` `〔〕`）。中文排印里这一族承担的
    ///    语义就是「这不是正文」（`【注】` `【声明】`）；歌词文件里的和声与旁白一律走
    ///    **圆括号**（`（哎呦不错哦）`、`（斑驳的家徽擦拭了一夜）`）。两族用途互斥，
    ///    所以这条从构造上咬不到和声行——不是「圆括号恰好没被列进黑名单」。
    /// 2. 括号里是成句的散文：含句号 `。`。唱词不打句号——LRC/QRC 的一行就是一个乐句，
    ///    句读由**时间戳**表达而不由标点表达，这是行式歌词格式本身的性质。
    ///
    /// 两条都要：只认括号会把 `【副歌】` 这类段落标记一并摘掉（摘了也不坏，但那是
    /// 另一件事）；只认句号会咬到真的带句号的口白行。
    ///
    /// 已知盲区：用方头括号写的旁白会被摘。规律层面区分不了「用标注括号写的唱词」
    /// 与「标注」——那是源数据自己打破了排印惯例。别为此把括号族放宽成「任意成对
    /// 括号」，那会一口吃掉全部和声行。
    private static func isNoticeLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, let last = trimmed.last,
              noticeBrackets[first] == last
        else { return false }
        return trimmed.contains("。")
    }

    /// 中文排印里的「标示括号」族。圆括号**不在其中**，那是和声与旁白用的。
    private static let noticeBrackets: [Character: Character] = [
        "【": "】", "〖": "〗", "〔": "〕",
    ]

    // MARK: - 歌手提示行

    /// 独立成行、**值为空**的「名字：」。QQ 用它标下一段由谁唱
    /// （`TAEYANG：` `T.O.P：` `周杰伦：`）。
    ///
    /// 判据只有一条：**冒号后面什么都没有**。`creditPair` 要求两侧非空，所以它对这种行
    /// 返回 nil，今天它就当普通唱词排上了屏。有值的那种（`他说：我不走了`、
    /// `权志龙 G-DRAGON：Let's go`）走的是另一条路，这里一概不碰——所以名册有没有、
    /// 有几个人，都不会改变行内前缀那类行的解释。
    ///
    /// `编曲：` 这种空值的制作残行先被 `isCreditKey` 拦下：它不是人名。
    private static func speakerCue(in text: String) -> String? {
        guard let name = emptyValueKey(in: text),
              !isCreditKey(name, insideBlock: false)
        else { return nil }
        return name
    }

    /// 「键：」——冒号后面什么都没有。`creditPair` 要求两侧非空，认不出这种行。
    private static func emptyValueKey(in text: String) -> String? {
        guard let separator = text.rangeOfCharacter(from: CharacterSet(charactersIn: "：:")) else { return nil }
        guard text[separator.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let key = text[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
        return looksLikeRoleName(key) ? key : nil
    }

    /// 建名册、给每行标歌手。**只打标记，不删行。**
    ///
    /// 删除推迟到 `assemble` 的发射环节，因为提示行必须留在 `claim` 的输入里替自己
    /// 吃掉那条占位副行：`G-DRAGON：`（54.748）与下一句（55.294）只差 0.546 秒，
    /// 而 `secondaryMaxDrift` 是 0.6——提前摘掉，下一句就会去认领它那条空的。
    ///
    /// 名册只做三件事：去重、按首次出现序编号、给出规模。**从不拿来匹配正文文本**——
    /// 归属是「上方最近的那条提示」这个位置关系定的，不是在正文里找名字。
    private static func markAgentCues(_ lines: inout [RawLine]) {
        var roster: [String: Int] = [:]
        var order: [String] = []
        for index in lines.indices {
            guard let name = speakerCue(in: lines[index].text) else { continue }
            let key = normalizedVocalistName(name)
            if roster[key] == nil {
                roster[key] = order.count
                order.append(name)
            }
            lines[index].isAgentCue = true
            lines[index].vocalist = LyricLine.Vocalist(name: order[roster[key]!], index: roster[key]!)
        }
        guard !roster.isEmpty else { return }

        var current: LyricLine.Vocalist?
        var used = false
        for index in lines.indices {
            if lines[index].isAgentCue {
                current = lines[index].vocalist
                continue
            }
            lines[index].vocalist = current
            if current != nil { used = true }
        }
        // 一条提示都没有管到正文（末行孤零零一个「XX：」之类）：整份名册作废，
        // 免得把一首独唱歌判成对唱。
        guard used else {
            for index in lines.indices {
                lines[index].isAgentCue = false
                lines[index].vocalist = nil
            }
            return
        }
    }

    /// 名册去重用的归一化：大小写与空白。跨语言的两种写法（`G-DRAGON` / `지드래곤`）
    /// 归不到一起，接受——那要的是人名库，不是规律。`[推]`
    private static func normalizedVocalistName(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace }
    }

    /// 首行的「歌名 - 歌手」
    private static func isHeaderLine(_ text: String) -> Bool {
        creditPair(in: text) == nil
            && text.range(of: "^.+\\s[-–—]\\s.+$", options: .regularExpression) != nil
    }

    /// 「键：值」两侧；键不像角色名就不算（那是带冒号的唱词）。
    private static func creditPair(in text: String) -> (key: String, value: String)? {
        guard let separator = text.rangeOfCharacter(from: CharacterSet(charactersIn: "：:")) else { return nil }
        let key = text[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
        let value = text[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, looksLikeRoleName(key) else { return nil }
        return (key, value)
    }

    /// 这个键在**形态**上像不像一个角色名。
    ///
    /// 角色名是一个**名词短语**（中英对照时是一对），不是句子：汉字段是几个字的职称，
    /// 拉丁段是几个词的对译。早先这里卡的是整键字符数（24，依据是
    /// `录音师 Recording Engineer` 正好 22 个字符）——那是**一个样本**：
    /// 双语键的字符数随英文职称长度线性增长，实测
    /// `人声/吉他录音师 Vocal/Guitar Recording Engineer` 是 40 个字符的真角色名。
    /// 用字符数当闸等于在给英文职称的长度设限，与「像不像角色名」无关。
    /// 分段计数分的是**短语与句子**：`我对你说过无数次我爱你` 是 11 个汉字的从句。
    private static func looksLikeRoleName(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        // 句读只出现在句子里，角色名不会有。
        guard !key.contains(where: { sentencePunctuation.contains($0) }) else { return false }
        let han = key.filter { $0.isLetter && !$0.isASCII }.count
        let latin = key.split(whereSeparator: { $0.isWhitespace || $0 == "/" })
            .filter { $0.contains(where: { $0.isASCII && $0.isLetter }) }.count
        return han <= maxRoleNameHanCount && latin <= maxRoleNameLatinWords
    }

    /// 汉字段的字数上限（不计 `/` 与空白）。`人声/吉他录音师` = 7。[推]
    private static let maxRoleNameHanCount = 8
    /// 拉丁段的词数上限（按 `/` 与空白切）。`Vocal/Guitar Recording Engineer` = 4。[推]
    private static let maxRoleNameLatinWords = 4
    /// 句末与句中的点断。唱词与角色名的分界线之一。
    private static let sentencePunctuation: Set<Character> = ["。", "！", "？", "，", "；", "、"]

    /// 这个键是不是制作信息里的角色名。
    ///
    /// - Parameter insideBlock: 前面已经确认过至少一条制作信息行。
    ///   「中文 + 英文」这条形态规律只在块内生效——否则
    ///   `权志龙 G-DRAGON：…` 这种双语歌手提示行会被当成制作信息吃掉。
    private static func isCreditKey(_ key: String, insideBlock: Bool) -> Bool {
        let compact = key.filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return false }
        let han = String(compact.filter { $0.isLetter && !$0.isASCII })
        let latin = String(compact.lowercased().filter { $0.isASCII && $0.isLetter })
        // 单字角色名（`词` `曲` `鼓`）只认整个键——包含匹配会咬到唱词。
        if songwriterRole(of: key) != .none { return true }
        if shortCreditKeys.contains(han.isEmpty ? latin : han) { return true }
        if !han.isEmpty, chineseCreditWords.contains(where: { han.contains($0) }) { return true }
        if !latin.isEmpty, latinCreditWords.contains(where: { latin.contains($0) }) { return true }
        if creditAbbreviations.contains(compact.uppercased()) { return true }
        return insideBlock && !han.isEmpty && !latin.isEmpty
    }

    /// 只认整键的短角色名。
    private static let shortCreditKeys: Set<String> = [
        "鼓", "唱", "琴", "笛", "箫", "编", "监", "制", "唢呐", "琵琶", "口白", "旁白",
    ]

    /// 中文角色词根（按**包含**匹配，所以 `弦乐` 认得下 `弦乐编写`、`弦乐监制`）。
    /// 一律两个字起——单字（`词` `曲` `鼓`）包含匹配会咬到唱词。
    private static let chineseCreditWords: Set<String> = [
        "作词", "填词", "词曲", "曲词", "作曲", "谱曲", "编曲", "改编", "编写", "配器", "作者",
        "制作", "监制", "出品", "发行", "策划", "企划", "统筹", "制片", "导演", "厂牌", "公司",
        "录音", "混音", "缩混", "母带", "后期", "工程", "工作室", "录音棚", "版权", "出版",
        "和声", "合声", "和音", "伴唱", "配唱", "合唱", "人声", "演唱", "歌手", "艺人", "指挥",
        "吉他", "贝斯", "鼓手", "鼓组", "打击", "键盘", "钢琴", "弦乐", "提琴", "长笛", "单簧",
        "萨克斯", "小号", "口琴", "二胡", "琵琶", "古筝", "笛子", "乐手", "乐队", "乐团",
        "编程", "合成器", "采样", "调音", "修音", "配乐", "编制", "编配",
        "设计", "美术", "视觉", "封面", "摄影", "造型", "化妆", "剪辑", "文案",
        "推广", "宣传", "营销", "经纪", "翻译", "音乐", "歌曲", "专辑", "鸣谢",
    ]

    /// 英文角色词根（小写、**包含**匹配，所以 `master` 认得下 `Mastering` / `Mastered by`）。
    private static let latinCreditWords: Set<String> = [
        "lyric", "compos", "songwrit", "written", "arrang", "produc", "direct", "record",
        "mix", "master", "engineer", "vocal", "chorus", "backing", "harmon", "featur",
        "guitar", "bass", "drum", "percussion", "piano", "keyboard", "violin", "cello",
        "viola", "string", "flute", "sax", "trumpet", "synth", "program", "orchestra",
        "design", "artwork", "cover", "photo", "styling", "makeup", "edit", "translat",
        "market", "promot", "publish", "label", "studio", "plan", "supervis", "manage",
        "compan", "copyright", "executive", "credit", "thanks", "perform", "band", "music",
    ]

    /// 整键就是缩写的那些（`OP：步虚工作室`）。
    private static let creditAbbreviations: Set<String> = [
        "OP", "SP", "OP/SP", "SP/OP", "A&R", "AR", "PD", "MV", "OST", "ISRC", "UPC",
    ]

    fileprivate enum SongwriterRole { case lyricist, composer, both, none }

    /// 只有词与曲进「创作者」那一行。这里按**整键**认（去掉空白与英文对照那半边），
    /// 免得 `编曲` 被 `曲` 咬中——摘除可以粗，署名不能错。
    private static func songwriterRole(of key: String) -> SongwriterRole {
        let compact = key.filter { !$0.isWhitespace }
        let han = String(compact.filter { !$0.isASCII })
        let latin = String(compact.lowercased().filter { $0.isASCII && $0.isLetter })
        let name = han.isEmpty ? latin : han
        if Self.bothRoleKeys.contains(name) { return .both }
        if Self.lyricistKeys.contains(name) { return .lyricist }
        if Self.composerKeys.contains(name) { return .composer }
        return .none
    }

    private static let bothRoleKeys: Set<String> = [
        "词曲", "曲词", "词/曲", "曲/词", "作词作曲", "作曲作词", "词曲作者", "词曲创作",
        "lyricscomposer", "lyricscompose",
    ]
    private static let lyricistKeys: Set<String> = [
        "词", "作词", "填词", "词作", "词作者", "作词人", "原词",
        "lyric", "lyrics", "lyricist", "lyricsby", "writtenby", "songwriter",
    ]
    private static let composerKeys: Set<String> = [
        "曲", "作曲", "谱曲", "曲作", "曲作者", "作曲人", "原曲",
        "compose", "composer", "composedby", "music", "musicby",
    ]

    // MARK: - 发音归位

    /// 把音译的逐字时间轴归到正文音节上。
    ///
    /// 两边同源：QQ 的 `roma` 与正文是同一套时间戳，只是切得更细——正文
    /// `甘(46529,928)い(47457,297)` 对上 roma `a(46529)ma(46705)i(47457)`。
    /// 关键性质是**每个正文音节的起点必然也是某个 roma 音节的起点**（一个字的读音
    /// 总是从这个字开始唱的），差别只有整行时间戳的舍入。
    ///
    /// 所以对齐是「正文去 roma 里认领自己那一项」，不是「roma 落在哪个区间」：
    /// 每个正文音节找起点离它最近的 roma 音节当组头，游标只前进，组边界就定死了。
    /// 这样既不需要容差，也不受 roma 切得多细影响——
    ///
    /// - 正文 `[38028]` 对 roma `[38027]`，整行差 1ms：`あ(40612)` 认领 `a(40611)`，
    ///   区间法会把它算进前一拍，排成 `ippaia` + `ru`。
    /// - `を(30404,**20**)見(30424,473)` 只隔 20ms：两者各自认领 `wo` 与 `mi`，
    ///   容差法只要给到 20ms 就会排成 `womi`。
    ///
    /// 拉丁文本不注音（`I am a villain` 底下再写一遍一模一样的东西没有意义）。
    ///
    /// 不要求逐个音节都认领到东西：拗音与促音在 roma 里是**并进前一拍**的
    /// （正文 `ウ(17229,104)ェ(17333,104)` 只对上一个 `e (17229,103)`，`ェ` 那一拍
    /// 是空的），这很常见，不算错。真正要挡的是 roma 与正文根本不是同一首
    /// （时间戳全错，认领结果乱成一团），所以按覆盖率判。
    static func attachTransliteration(_ roma: [LyricSyllable],
                                      to syllables: [LyricSyllable]) -> [LyricSyllable]? {
        guard !roma.isEmpty, !syllables.isEmpty else { return nil }

        // 每个正文音节在 roma 里的组头下标。游标只前进：两边都是按时间排好的，
        // 「下一个 roma 比当前这个更贴近我」时才挪。
        //
        // 平手要分情况，判据是「下一个正文音节是不是更需要它」：
        //
        // - `ウ(17229)ェ(17333)` 对 roma `e(17229)` `i(17437)`：`ェ` 到两边都是 104，
        //   但下一个正文音节 `イ(17437)` 到 `i` 是 0——`i` 是它的，`ェ` 不能拿，
        //   于是 `ェ` 与 `ウ` 同组头、吃空（拗音的后半拍本来就没有自己的读音）。
        // - `け(97173,1600) (98773,**0**)叶(98773,842)`：零时长的空格音节与「叶」
        //   时间戳完全相同，roma 那边也有两项同为 98773。「叶」到 `ka` 是 0，
        //   下一个正文音节 `う(99615)` 到 `ka` 是 842——`ka` 该归「叶」。
        //   一律不前进的话，「叶」之后的音节会全部卡在同一个组头上，
        //   整个后半行都判成非 owner、一个字都注不上音。
        var heads: [Int] = []
        var cursor = 0
        for (offset, syllable) in syllables.enumerated() {
            while cursor + 1 < roma.count {
                let current = abs(roma[cursor].time - syllable.time)
                let next = abs(roma[cursor + 1].time - syllable.time)
                if next < current {
                    cursor += 1
                    continue
                }
                // 平手：下一个正文音节离它更远，才由我拿走。
                guard next == current, offset + 1 < syllables.count,
                      abs(roma[cursor + 1].time - syllables[offset + 1].time) > next
                else { break }
                cursor += 1
            }
            heads.append(cursor)
        }

        // 相邻音节认领到同一项时（拗音的后半拍 `ェ` 没有自己的那一拍，
        // 与前面的 `ウ` 共享一个 `e`），归**先来的**那个，后面那个吃空。
        // 每一组的上界是右边第一个更大的组头。
        var upperBounds = [Int](repeating: roma.count, count: syllables.count)
        var next = roma.count
        for offset in stride(from: syllables.count - 1, through: 0, by: -1) {
            upperBounds[offset] = next
            if offset == 0 || heads[offset - 1] < heads[offset] { next = heads[offset] }
        }

        var result: [LyricSyllable] = []
        var wanted = 0
        var covered = 0
        for (offset, syllable) in syllables.enumerated() {
            guard needsTransliteration(syllable.text) else {
                result.append(syllable)
                continue
            }
            wanted += 1
            let isOwner = offset == 0 || heads[offset - 1] < heads[offset]
            let reading = isOwner
                ? roma[heads[offset]..<max(heads[offset], upperBounds[offset])]
                    .map { Self.romanization(of: $0.text) }
                    .joined()
                : ""
            guard !reading.isEmpty else {
                result.append(syllable)
                continue
            }
            covered += 1
            result.append(LyricSyllable(text: syllable.text, time: syllable.time,
                                        duration: syllable.duration,
                                        transliteration: reading))
        }
        guard wanted > 0, Double(covered) >= Double(wanted) * minTransliterationCoverage
        else { return nil }
        return result
    }

    /// 一个 roma 音节的可显示文本。
    ///
    /// QQ 用前置撇号标促音：「乗(20987)っ(21187)た(21387)」对上 `no` / `'t` / `ta`，
    /// 撇号的意思是「这个辅音接到下一拍开头」，拼起来是 notta。撇号本身不是罗马字，
    /// 去掉。只去开头那一个——`n'` 那种后置撇号（kin'en）是要留的。
    private static func romanization(of text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("'") { text.removeFirst() }
        return text
    }

    /// 需要注音的音节里至少这么多认领到了发音，这份 roma 才认。`[推]`
    private static let minTransliterationCoverage = 0.6

    /// 这段文字要不要注音：含拉丁字母与数字以外的**表意 / 音节文字**才要。
    /// 标点、空格、纯拉丁一律不要。
    private static func needsTransliteration(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF,      // 假名
                 0x3400...0x4DBF, 0x4E00...0x9FFF,      // 汉字
                 0xF900...0xFAFF,                       // 兼容汉字
                 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF,   // 谚文
                 0x0400...0x04FF,                       // 西里尔
                 0x0590...0x05FF, 0x0600...0x06FF,      // 希伯来 / 阿拉伯
                 0x0900...0x0DFF, 0x0E00...0x0FFF:      // 南亚 / 东南亚 / 藏文
                return true
            default:
                return false
            }
        }
    }

    // MARK: - 组装

    private static func assemble(_ raw: [RawLine], translation: [RawLine],
                                 transliteration: [RawLine],
                                 credits: Credits) -> [LyricLine] {
        // 先算每行的结束时刻：QRC 有现成的，LRC 按字数估，且不越过下一行起点。
        var ends: [TimeInterval] = []
        for (offset, line) in raw.enumerated() {
            let nextStart = offset + 1 < raw.count ? raw[offset + 1].time : .greatestFiniteMagnitude
            let estimated: TimeInterval
            if let declared = line.declaredDuration, declared > 0 {
                estimated = declared
            } else if let last = line.syllables.last {
                estimated = max(last.end - line.time, minLineDuration)
            } else {
                estimated = max(minLineDuration, Double(line.text.count) * secondsPerCharacter)
            }
            ends.append(min(line.time + estimated, nextStart))
        }

        // 两条副行按序认领，一条只归一行。
        let translations = claim(translation, for: raw)
        let transliterations = claim(transliteration, for: raw)

        var result: [LyricLine] = []
        func append(_ make: (Int) -> LyricLine) { result.append(make(result.count)) }

        // 歌手提示行到这里才摘：上面的 `claim` 与 `ends` 都要按**完整的 `raw`** 算，
        // 否则它那条占位副行会被下一句认领走（见 `markAgentCues`）。
        // 副行取值仍用 `offset`（对齐 `raw`），只有发射顺序按 `emitted`。
        let emitted = raw.indices.filter { !raw[$0].isAgentCue }
        guard let firstEmitted = emitted.first, let lastEmitted = emitted.last else { return [] }

        // 开头的长前奏也是间奏。起点取第一条**排得上屏**的行——摘完开头那块制作表之后，
        // `raw[0]` 可能正是一条提示行（BIGBANG 是 12.85，首句在 14.10）。
        if raw[firstEmitted].time >= interludeMinGap {
            append {
                LyricLine(index: $0, time: 0, end: raw[firstEmitted].time, text: "", kind: .interlude)
            }
        }

        for (rank, offset) in emitted.enumerated() {
            let line = raw[offset]
            let translationText = translations[offset].map { translation[$0].text }
            // 音译与正文**逐字同源**（QQ 的 roma 是 QRC），发音还要按音节归位，
            // 所以这里要的是整条 `RawLine`，不只是文本。
            let romaLine = transliterations[offset].map { transliteration[$0] }
            // 逐字都有的时候把发音落到音节上：这样界面才排得出「发音贴在对应那几个字
            // 底下」的样子，而不是整行扔在下面。落不进去（网易的 romalrc 只有行级）
            // 就退回整行那条副行。
            var syllables = line.syllables
            var transliterationText = romaLine?.text
            if let romaLine, !romaLine.syllables.isEmpty, !syllables.isEmpty,
               let merged = attachTransliteration(romaLine.syllables, to: syllables) {
                syllables = merged
                transliterationText = nil
            }
            append {
                LyricLine(index: $0, time: line.time, end: ends[offset], text: line.text,
                          translation: translationText,
                          transliteration: transliterationText,
                          syllables: syllables, kind: .lyric,
                          vocalist: line.vocalist)
            }
            let nextStart = rank + 1 < emitted.count ? raw[emitted[rank + 1]].time : nil
            if let nextStart, nextStart - ends[offset] >= interludeMinGap {
                append {
                    LyricLine(index: $0, time: ends[offset], end: nextStart, text: "", kind: .interlude)
                }
            }
        }

        if !credits.isEmpty {
            let start = ends[lastEmitted]
            let text = "创作者：" + credits.names.joined(separator: "、")
            append {
                LyricLine(index: $0, time: start, end: start + creditsDuration,
                          text: text, kind: .credits)
            }
        }

        return result
    }

    // MARK: - 无时间戳的纯文本

    /// 整份词一条时间戳都没有时走这条路：静态整页，不高亮不滚。
    ///
    /// 清洗环节**全部复用**带戳那条路的（`stripLeadingCredits` / `stripTrailingCredits` /
    /// `classify` / `isNoticeLine` / `markAgentCues` / `Credits.fillGaps`）——它们只读
    /// `RawLine.text` / `.isMetadata` / `.isAgentCue`，一个都不看时间。这正是这里仍然
    /// 走 `RawLine` 而不另造一套平行结构的理由：头尾制作表、`【…】` 声明行、歌手提示行
    /// 这三件事在无戳歌词里一样会出现，「整首都像键：值时尾块不摘」那条保护也跟着继承。
    ///
    /// 与 `parse` 的差别只有两处：分词器换成 `untimedRawLines`（**不排序**），
    /// 组装换成 `assembleUntimed`（没有间奏、没有行结束、没有按时间认领的副行）。
    private static func parseUntimed(_ text: String, translation: String?,
                                     transliteration: String?) -> [LyricLine] {
        var raw = untimedRawLines(text)
        guard !raw.isEmpty else { return [] }

        var credits = stripLeadingCredits(&raw)
        credits.fillGaps(from: stripTrailingCredits(&raw))
        guard !raw.isEmpty else { return [] }
        markAgentCues(&raw)

        let trans = translation.map { untimedSecondaryLines($0) } ?? []
        let roma = transliteration.map { untimedSecondaryLines($0) } ?? []
        return assembleUntimed(raw, translation: trans, transliteration: roma, credits: credits)
    }

    /// 无戳文本自己的分词器。
    ///
    /// **不排序**，这是它不复用 `parseTimedLines` 的全部原因：后者末尾那句
    /// `sorted { $0.time < $1.time }` 在全 0 的时间上不稳定（Swift 的 introsort 不保序），
    /// 二十来行就会被打乱——而**文件顺序是纯文本歌词仅有的顺序信息**。
    ///
    /// 空行**不是简单丢掉**：纯文本里空行是仅有的段落信息（[实测 2026-09-16] 网易
    /// 《国王的新衣》正文里多处空行分段）。吃掉空行，把「下一条非空行是段首」记在
    /// `RawLine.startsParagraph` 上，最终落到 `LyricLine.startsParagraph`。
    ///
    /// 行首 BOM（`U+FEFF`）要去：[实测 2026-09-16] 网易《国王的新衣》正文首行带着它，
    /// 留着就是行首一个宽度不定的空格。整行都去而不只去开头——`U+FEFF` 是零宽字符，
    /// 歌词里出现在哪儿都不是内容。
    private static func untimedRawLines(_ text: String) -> [RawLine] {
        var items: [RawLine] = []
        var startsParagraph = false
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine
                .replacingOccurrences(of: "\u{feff}", with: "")
                .trimmingCharacters(in: .whitespaces)
            // 网易的 JSON 制作人信息头在无戳的 `lrc` 里照样有，仍旧交给它。
            // 它不上屏，所以不动段首位——空行后面紧跟一条 JSON 头时，段首归再下一行。
            if let meta = parseNeteaseMetaLine(trimmed) {
                items.append(meta)
                continue
            }
            guard !trimmed.isEmpty else {
                startsParagraph = true
                continue
            }
            // QQ 的 `//` 占位行在无戳这条路上没有占位的必要（副行按下标配对，不按时间）。
            guard !isPlaceholder(trimmed) else { continue }
            // LRC 的元信息标签（`[ti:]` / `[ar:]` / `[offset:]` …）。带戳那条路上
            // `parseLRCLine` 认不出时间戳、直接丢，等于「忽略」；无戳这条路没有那道
            // 天然的滤网，不显式滤掉的话它们会原样上屏成歌词。
            guard !isLRCTagLine(trimmed) else { continue }
            items.append(RawLine(time: 0, declaredDuration: nil, text: trimmed,
                                 syllables: [], startsParagraph: startsParagraph))
            startsParagraph = false
        }
        return items
    }

    /// 整行就是一个 LRC 元信息标签：`[键:值]`，键是拉丁字母（`ti` / `ar` / `al` /
    /// `by` / `offset` / `re` / `ve` …，不穷举）。
    ///
    /// 键限定为拉丁字母有两个作用：`[00:05.00]` 这种时间戳不会命中（键是数字，
    /// 而且它本来也走不到这儿），中文的方括号旁白（`[旁白：他说]`）也不会被误滤。
    private static let lrcTagLine = try! NSRegularExpression(
        pattern: "^\\[[A-Za-z#]+:[^\\]]*\\]$")

    private static func isLRCTagLine(_ text: String) -> Bool {
        let ns = text as NSString
        return lrcTagLine.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// 无戳正文的副行（网易的 `tlyric` / `romalrc` 常常同样无戳）。
    ///
    /// 用**同一个**分词器，再跑一遍头尾 credits 摘除——返回的 `Credits` 丢弃，
    /// 摘只为把两边归一化：`tlyric` 确实会把「作词 : …」原样回显一遍，不摘就整体错位。
    ///
    /// 配对判据在 `assembleUntimed`：**只在行数完全相等时**按下标配上，否则整份丢弃。
    /// 不加任何时间容差与比例系数——这是结构判据，错位的译文严格比没有译文更糟。
    private static func untimedSecondaryLines(_ text: String) -> [RawLine] {
        // 副行自己带时间戳（正文无戳、译文有戳）：两边没有可对齐的结构，直接丢弃，别猜。
        // 判据与 `parse` 的分支判据是同一句。
        guard !parseTimedLines(text).contains(where: { !$0.isMetadata }) else { return [] }
        var lines = untimedRawLines(text)
        _ = stripLeadingCredits(&lines)
        _ = stripTrailingCredits(&lines)
        return lines
    }

    /// 照 `assemble` 去掉一切时间派生物：没有 `ends[]`、没有前奏/中段的间奏行、
    /// 没有按时间认领的 `claim`、没有按音节归位的 `attachTransliteration`。
    ///
    /// 剩下的只有两件事：行本身，与「谁是段首」。
    private static func assembleUntimed(_ raw: [RawLine], translation: [RawLine],
                                        transliteration: [RawLine],
                                        credits: Credits) -> [LyricLine] {
        // 歌手提示行同样不上屏（标记由 `markAgentCues` 打，与带戳那路共用）。
        let emitted = raw.indices.filter { !raw[$0].isAgentCue }
        guard !emitted.isEmpty else { return [] }

        /// 副行按**下标**认领。两种行数都接受：与 `raw` 等长（副行文件把歌手提示行也写了），
        /// 或与上屏行数等长（副行文件省掉了提示行）。其余一律 `nil`——fail-closed。
        func secondary(_ lines: [RawLine], offset: Int, rank: Int) -> String? {
            let text: String
            if lines.count == raw.count {
                text = lines[offset].text
            } else if lines.count == emitted.count {
                text = lines[rank].text
            } else {
                return nil
            }
            return text.isEmpty ? nil : text
        }

        var result: [LyricLine] = []
        // 首行算段首——与带戳那路的 `isFirstLineOfParagraph = previousEnd == nil` 同解。
        var startsParagraph = true
        for offset in raw.indices {
            if raw[offset].startsParagraph { startsParagraph = true }
            // 提示行不上屏；它要是段首，段首位顺延给下一条上屏的行。
            guard !raw[offset].isAgentCue else { continue }
            let line = raw[offset]
            // `index` 必须等于它在返回数组里的下标（`LyricsAdapter` 的头号不变量）。
            let rank = result.count
            result.append(LyricLine(index: rank, time: 0, end: 0, text: line.text,
                                    translation: secondary(translation, offset: offset, rank: rank),
                                    transliteration: secondary(transliteration, offset: offset, rank: rank),
                                    kind: .plain,
                                    vocalist: line.vocalist,
                                    startsParagraph: startsParagraph))
            startsParagraph = false
        }

        if !credits.isEmpty {
            // 时间在这条路上没有意义：适配层给 `SongwritersLine` 的本来就是 ±∞。
            result.append(LyricLine(index: result.count, time: 0, end: 0,
                                    text: "创作者：" + credits.names.joined(separator: "、"),
                                    kind: .credits))
        }
        return result
    }
}
