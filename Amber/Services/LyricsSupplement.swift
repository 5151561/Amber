import Foundation

/// 本家只给行级歌词时，去另一家找**同一个录音**的逐字版换上。
///
/// 起因：网易的逐字（`yrc`）只覆盖一部分歌，新歌与独立音乐基本没有——
/// [实测 2026-10-07 eapi] 最近播放里 7 首网易歌（陈粒《果实》、刘森《峨眉》…）
/// 匿名与桌面身份都只回 `lrc`，而同一接口问《孤勇者》照样有 `yrc`，所以不是取词坏了。
/// 反过来 QQ 也有没做 QRC 的歌，两个方向走同一条路。
///
/// **最怕的是换成别的版本**（Live、重录、剪辑版）：词一样、时间轴整段错开，
/// 比行级歌词还糟。所以换之前过三道：
/// 1. 搜索结果里歌名规范化后完全相同、歌手有交集、时长差 ≤ `durationTolerance`；
/// 2. 候选的词真的带逐字（没有逐字换过来没有意义）；
/// 3. **按时间轴核对**：两份里文字相同的句子，开唱时刻的中位差 ≤ `startTolerance`，
///    且至少一半的句子对得上。这一条才是「同一个录音」的证据，前两条只是缩小候选。
///
/// 任何一步不成立就原样返回本家那份——宁可行级，不要错轴。
enum LyricsSupplement {

    /// 两家给同一首歌标的时长差。同一母带通常差在 1 秒内（取整方式不同），
    /// 剪辑版 / Live 往往差出十几秒。[推]
    static let durationTolerance: TimeInterval = 3
    /// 同一句在两份歌词里的开唱时刻差。LRC 是人工打点、QRC 按首字，
    /// 同一录音实测差在零点几秒；不同录音的前奏一般差出整秒以上。[推]
    static let startTolerance: TimeInterval = 1
    /// 搜几条候选。同名同歌手的翻唱 / Live 会挤在前面，留一点余量。
    static let searchLimit = 10

    /// 入口。`lines` 是本家那份；不需要换或换不成都原样返回。
    static func supplement(_ lines: [LyricLine], for track: Track,
                           from other: any MusicProvider) async -> [LyricLine] {
        guard isLineLevel(lines), !track.isLocal else { return lines }
        let keyword = "\(track.title) \(track.artistName)"
        guard let results = try? await other.searchTracks(keyword: keyword,
                                                          limit: searchLimit, offset: 0)
        else { return lines }
        for candidate in results where isCandidate(candidate, for: track) {
            guard let found = try? await other.lyrics(track: candidate),
                  found.contains(where: { !$0.syllables.isEmpty }),
                  timingAgrees(lines, found)
            else { continue }
            return carrySecondaryLines(from: lines, into: found)
        }
        return lines
    }

    /// 有带时间轴的正文、但一个音节都没有。
    /// 空数组（没词 / 纯音乐）与纯文本都不换：前者没有可核对的时间轴，
    /// 后者本家明说了没有时间戳，换过来核对不了是不是同一个录音。
    static func isLineLevel(_ lines: [LyricLine]) -> Bool {
        lines.contains { $0.kind == .lyric }
            && !lines.contains { !$0.syllables.isEmpty }
    }

    static func isCandidate(_ candidate: Track, for track: Track) -> Bool {
        guard normalized(candidate.title) == normalized(track.title),
              abs(candidate.duration - track.duration) <= durationTolerance
        else { return false }
        let theirs = artistNames(candidate.artistName)
        return artistNames(track.artistName).contains { own in
            theirs.contains { sameArtist(own, $0) }
        }
    }

    /// 两家对同一个人的写法常差一截别名：QQ `银河快递 (Galaxy Express)`、网易 `银河快递`。
    /// 规范化之后一方包含另一方就算同一人；短的那方至少两个字，免得单字名到处撞。
    /// 放宽这里不怕错配——是不是同一个录音由 `timingAgrees` 把关。
    static func sameArtist(_ a: String, _ b: String) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short == long || (short.count >= 2 && long.contains(short))
    }

    /// 两份词是不是同一条时间轴。按文字相同的句子配对（同一句在副歌里会出现多次，
    /// 取时间上最近的那次），看开唱时刻的中位差。
    static func timingAgrees(_ primary: [LyricLine], _ candidate: [LyricLine]) -> Bool {
        let own = primary.filter { $0.kind == .lyric }
        guard !own.isEmpty else { return false }
        var byText: [String: [TimeInterval]] = [:]
        for line in candidate where line.kind == .lyric {
            byText[normalized(line.text), default: []].append(line.time)
        }
        let deltas = own.compactMap { line -> TimeInterval? in
            byText[normalized(line.text)]?.map { abs($0 - line.time) }.min()
        }.sorted()
        guard deltas.count * 2 >= own.count else { return false }
        return deltas[deltas.count / 2] <= startTolerance
    }

    /// 本家有翻译 / 发音、另一家没有时，按句子配回去。只补空着的，不覆盖另一家自己的。
    static func carrySecondaryLines(from primary: [LyricLine],
                                    into candidate: [LyricLine]) -> [LyricLine] {
        let donors = primary.filter {
            $0.kind == .lyric && ($0.translation != nil || $0.transliteration != nil)
        }
        guard !donors.isEmpty else { return candidate }
        return candidate.map { line in
            guard line.kind == .lyric,
                  line.translation == nil || line.transliteration == nil,
                  let donor = donors
                    .filter({ normalized($0.text) == normalized(line.text) })
                    .min(by: { abs($0.time - line.time) < abs($1.time - line.time) }),
                  abs(donor.time - line.time) <= startTolerance
            else { return line }
            // 逐字行的发音已经落到音节上时（`LyricParser.attachTransliteration`），
            // 整行那条副行是 nil 是故意的，别把行级的补回来叠一份。
            let syllablesCarryReading = line.syllables.contains { $0.transliteration != nil }
            return LyricLine(index: line.index, time: line.time, end: line.end, text: line.text,
                             translation: line.translation ?? donor.translation,
                             transliteration: syllablesCarryReading
                                ? line.transliteration
                                : (line.transliteration ?? donor.transliteration),
                             syllables: line.syllables, kind: line.kind,
                             vocalist: line.vocalist, startsParagraph: line.startsParagraph)
        }
    }

    /// 比对用的规范形：全半角、大小写、空白与标点都不算差别。
    static func normalized(_ text: String) -> String {
        let folded = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        return String(folded.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }.map(Character.init))
    }

    /// 「A/B」「A、B」「A & B」都拆开，任一人对上就算歌手有交集。
    static func artistNames(_ text: String) -> Set<String> {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: "/、,，&;；"))
        return Set(parts.map(normalized).filter { !$0.isEmpty })
    }
}
