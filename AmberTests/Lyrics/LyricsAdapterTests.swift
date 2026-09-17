import XCTest
@testable import Amber

/// `LyricParser` 的产物 → Music 歌词模块的数据模型。
///
/// 最要紧的一条：**`LyricsLine.index` 必须等于它在`lines` 里的下标**——
/// 视图数组与行数组按下标一一对应，中间没有查找表（`selecting line`）。
final class LyricsAdapterTests: XCTestCase {

    private func line(_ index: Int,
                      _ time: TimeInterval,
                      _ end: TimeInterval,
                      text: String = "",
                      kind: LyricLine.Kind = .lyric,
                      translation: String? = nil,
                      syllables: [LyricSyllable] = [],
                      vocalist: LyricLine.Vocalist? = nil) -> LyricLine {
        LyricLine(index: index, time: time, end: end, text: text,
                  translation: translation, syllables: syllables, kind: kind,
                  vocalist: vocalist)
    }

    private func voice(_ index: Int) -> LyricLine.Vocalist {
        LyricLine.Vocalist(name: "歌手\(index)", index: index)
    }

    func testIndicesMatchArrayPositions() {
        let source = [
            line(0, 0, 3, kind: .interlude),
            line(1, 3, 6, text: "第一句"),
            line(2, 6, 9, text: "第二句"),
            line(3, 9, 29, text: "创作者：甲、乙", kind: .credits),
        ]
        let lyrics = LyricsAdapter.makeLyrics(from: source)
        XCTAssertEqual(lyrics.lines.count, 4)
        for (position, mapped) in lyrics.lines.enumerated() {
            XCTAssertEqual(mapped.index, position)
        }
    }

    func testKindMapping() {
        let source = [
            line(0, 0, 3, kind: .interlude),
            line(1, 3, 6, text: "唱词"),
            line(2, 6, 26, text: "创作者：甲", kind: .credits),
        ]
        let lyrics = LyricsAdapter.makeLyrics(from: source)
        XCTAssertTrue(lyrics.lines[0] is InstrumentalLine)
        XCTAssertTrue(lyrics.lines[1] is TextLine)
        XCTAssertTrue(lyrics.lines[2] is SongwritersLine)
        XCTAssertEqual(lyrics.songwriters, ["创作者：甲"])
    }

    /// 词曲作者那一行照原版留 ±∞：永不选中、永不淘汰、不吃悬停。
    func testSongwritersLineKeepsInfiniteTimes() {
        let lyrics = LyricsAdapter.makeLyrics(from: [line(0, 5, 25, text: "创作者：甲", kind: .credits)])
        XCTAssertEqual(lyrics.lines[0].startTime, .infinity)
        XCTAssertEqual(lyrics.lines[0].endTime, .infinity)
    }

    func testTypeIsTimedWordsOnlyWhenSyllablesExist() {
        let plain = LyricsAdapter.makeLyrics(from: [line(0, 0, 3, text: "整行")])
        XCTAssertEqual(plain.type, .timedLines)

        let syllables = [LyricSyllable(text: "逐", time: 0, duration: 0.5),
                         LyricSyllable(text: "字", time: 0.5, duration: 0.5)]
        let worded = LyricsAdapter.makeLyrics(
            from: [line(0, 0, 3, text: "逐字", syllables: syllables)])
        XCTAssertEqual(worded.type, .timedWords)
    }

    /// 有逐字时间轴才谈得上渐变扫过与抬升；强调是逐行声明的能力，QRC 源没有。
    func testCapabilities() {
        let syllables = [LyricSyllable(text: "字", time: 0, duration: 1)]
        let worded = LyricsAdapter.makeLyrics(
            from: [line(0, 0, 3, text: "字", syllables: syllables)])
        let textLine = try? XCTUnwrap(worded.lines[0] as? TextLine)
        XCTAssertEqual(textLine?.capabilities, [.gradient, .lift])
        XCTAssertFalse(textLine?.capabilities.contains(.emphasis) ?? true)

        let plain = LyricsAdapter.makeLyrics(from: [line(0, 0, 3, text: "整行")])
        XCTAssertEqual((plain.lines[0] as? TextLine)?.capabilities, [])
    }

    func testSyllableTimesAreCarriedOver() {
        let syllables = [LyricSyllable(text: "逐", time: 1, duration: 0.5),
                         LyricSyllable(text: "字", time: 1.5, duration: 0.25)]
        let lyrics = LyricsAdapter.makeLyrics(
            from: [line(0, 1, 3, text: "逐字", syllables: syllables)])
        let mapped = (lyrics.lines[0] as? TextLine)?.syllables ?? []
        XCTAssertEqual(mapped.count, 2)
        XCTAssertEqual(mapped[1].startTime, 1.5, accuracy: 1e-9)
        XCTAssertEqual(mapped[1].endTime, 1.75, accuracy: 1e-9)
    }

    func testEmptyTranslationBecomesNil() {
        let lyrics = LyricsAdapter.makeLyrics(
            from: [line(0, 0, 3, text: "词", translation: "")])
        XCTAssertNil((lyrics.lines[0] as? TextLine)?.translation)
    }

    /// 段首吃 `paragraphSpacing = 39`，而**段落只能来自源数据**。
    /// QRC / YRC / LRC 都不声明段落，所以除了第一句，谁都不是段首——
    /// 哪怕与上一句空了 14 秒（那种停顿由间奏行表达，不是段落）。
    func testOnlyFirstLineIsParagraphStart() {
        let source = [
            line(0, 0, 3, text: "一"),
            line(1, 3.2, 6, text: "二"),
            line(2, 20, 23, text: "三"),
        ]
        let lyrics = LyricsAdapter.makeLyrics(from: source)
        XCTAssertEqual((lyrics.lines[0] as? TextLine)?.isFirstLineOfParagraph, true)
        XCTAssertEqual((lyrics.lines[1] as? TextLine)?.isFirstLineOfParagraph, false)
        XCTAssertEqual((lyrics.lines[2] as? TextLine)?.isFirstLineOfParagraph, false)
    }

    /// 前奏那条间奏行也算「前面有东西」：第一句唱词此时不再是段首。
    /// 它落在下标 1 上，判成段首就会在前奏与第一句之间凭空多出 39。
    func testLeadingInterludeSuppressesParagraphStart() {
        let source = [
            line(0, 0, 7, kind: .interlude),
            line(1, 7, 10, text: "一"),
            line(2, 10, 13, text: "二"),
        ]
        let lyrics = LyricsAdapter.makeLyrics(from: source)
        XCTAssertEqual((lyrics.lines[1] as? TextLine)?.isFirstLineOfParagraph, false)
        XCTAssertEqual((lyrics.lines[2] as? TextLine)?.isFirstLineOfParagraph, false)
    }

    // MARK: - 间奏行的进出场余量

    /// 间奏行不是一句，是那段空档的可视化——两头各让出一个翻行的量，
    /// 好让展开在上一句唱完那一刻起跑、收起在下一句开唱前一整条弹簧起跑。
    ///
    /// 解析器给的是空档本身（`time = 上一句唱完`、`end = 下一句开唱`），两头贴死；
    /// 照那个区间走，`handoverDuration` 两侧都算出 0，进间奏提前 0.89 s、
    /// 出间奏晚 0.79 s 落位——**方向正好相反**。这条用例钉的就是那两个 0 不许回来。
    func testInstrumentalLeavesRoomToScrollInAndOut() {
        let lead = LyricsSpecs().scrollLead
        let source = [
            line(0, 0, 8, text: "上一句"),
            line(1, 8, 20, kind: .interlude),
            line(2, 20, 25, text: "下一句"),
        ]
        let lines = LyricsAdapter.makeLyrics(from: source, handover: lead).lines
        XCTAssertEqual(lines[1].startTime, 8 + lead, accuracy: 1e-9)
        XCTAssertEqual(lines[1].endTime, 20 - lead, accuracy: 1e-9)
        // 两侧的空档都正好是一整条翻行弹簧——`handoverDuration` 拿到的就是它。
        XCTAssertEqual(lines[1].startTime - lines[0].endTime, lead, accuracy: 1e-9)
        XCTAssertEqual(lines[2].startTime - lines[1].endTime, lead, accuracy: 1e-9)
    }

    /// 前奏行头上不让：它没有上一句要等，`startTime` 必须留在源数据给的那一刻。
    /// 让了的话准入判据（`elapsed > startTime − scrollLead`）在第一帧就不成立，
    /// 开头那三个点整段不出现。
    func testPreludeKeepsItsHeadAtZero() {
        let lead = LyricsSpecs().scrollLead
        let source = [
            line(0, 0, 12, kind: .interlude),
            line(1, 12, 16, text: "第一句"),
        ]
        let lines = LyricsAdapter.makeLyrics(from: source, handover: lead).lines
        XCTAssertEqual(lines[0].startTime, 0, accuracy: 1e-9)
        XCTAssertEqual(lines[0].endTime, 12 - lead, accuracy: 1e-9)
    }

    /// 余量比空档还宽时退化成零长行，不许翻成负区间。
    /// `interludeMinGap = 5` 下不会发生，门槛哪天调小才谈得上。
    func testInstrumentalRoomNeverGoesNegative() {
        let source = [
            line(0, 0, 8, text: "上一句"),
            line(1, 8, 9, kind: .interlude),
            line(2, 9, 12, text: "下一句"),
        ]
        let lines = LyricsAdapter.makeLyrics(from: source, handover: 5).lines
        XCTAssertEqual(lines[1].startTime, 13, accuracy: 1e-9)
        XCTAssertEqual(lines[1].endTime, lines[1].startTime, accuracy: 1e-9)
    }

    func testLeadingSilenceIsFirstLineStart() {
        let lyrics = LyricsAdapter.makeLyrics(from: [line(0, 7.5, 10, text: "词")])
        XCTAssertEqual(lyrics.leadingSilence, 7.5, accuracy: 1e-9)
    }

    func testEmptyInput() {
        let lyrics = LyricsAdapter.makeLyrics(from: [])
        XCTAssertTrue(lyrics.lines.isEmpty)
        XCTAssertEqual(lyrics.type, .static)
    }

    // MARK: - 逐字单元的字符范围

    /// 解析器对首尾做过 trim，直接按长度累加会错位，所以是顺序查找。
    func testSyllableRangesSurviveTrimming() {
        let syllables = [TextLine.SyllableTiming(text: " 可", startTime: 0, endTime: 1),
                         TextLine.SyllableTiming(text: "我", startTime: 1, endTime: 2)]
        let ranges = SBS_TextContentLayer.syllableRanges(in: "可我", syllables: syllables)
        XCTAssertNil(ranges, "找不到就整条放弃——宁可不做逐字，不做错")

        let clean = [TextLine.SyllableTiming(text: "可", startTime: 0, endTime: 1),
                     TextLine.SyllableTiming(text: "我", startTime: 1, endTime: 2)]
        XCTAssertEqual(SBS_TextContentLayer.syllableRanges(in: "可我", syllables: clean),
                       [0..<1, 1..<2])
    }

    func testSyllableRangesSkipLeadingGap() {
        let syllables = [TextLine.SyllableTiming(text: "we", startTime: 0, endTime: 1),
                         TextLine.SyllableTiming(text: "go", startTime: 1, endTime: 2)]
        XCTAssertEqual(SBS_TextContentLayer.syllableRanges(in: "we go", syllables: syllables),
                       [0..<2, 3..<5])
    }

    // MARK: - 对唱分栏

    /// 名册规模决定 `vocalistsType`
    func testVocalistsTypeFromRosterSize() {
        func type(_ voices: [Int]) -> Lyrics.VocalistsType {
            LyricsAdapter.makeLyrics(from: voices.enumerated().map {
                line($0.offset, Double($0.offset), Double($0.offset) + 1,
                     text: "句", vocalist: voice($0.element))
            }).vocalistsType
        }
        XCTAssertEqual(LyricsAdapter.makeLyrics(from: [line(0, 0, 1, text: "句")]).vocalistsType, .single)
        XCTAssertEqual(type([0, 0]), .single)
        XCTAssertEqual(type([0, 1]), .duet)
        // [实测] BIGBANG《BANG BANG BANG》名册 5 人
        XCTAssertEqual(type([0, 1, 2, 3, 4]), .group)
    }

    /// 每换一次人就换一次边，从左起；同一位歌手连着唱的几句留在同一边
    func testAlignmentFlipsOnEveryVocalistChange() {
        let source = [0, 0, 1, 1, 0, 2].enumerated().map {
            line($0.offset, Double($0.offset), Double($0.offset) + 1,
                 text: "句", vocalist: voice($0.element))
        }
        let alignments = LyricsAdapter.makeLyrics(from: source).lines
            .compactMap { ($0 as? TextLine)?.agentAlignment }
        XCTAssertEqual(alignments, [.normal, .normal, .flipped, .flipped, .normal, .flipped])
    }

    /// 换边是按段落发生的：同一位歌手再出场时落在哪边由「他前面是谁」决定
    func testAlignmentIsPerSegmentNotPerVocalist() {
        // 甲 → 乙 → 丙 → 甲：甲第二次出场时前面是丙，所以翻到右边
        let source = [0, 1, 2, 0].enumerated().map {
            line($0.offset, Double($0.offset), Double($0.offset) + 1,
                 text: "句", vocalist: voice($0.element))
        }
        let alignments = LyricsAdapter.makeLyrics(from: source).lines
            .compactMap { ($0 as? TextLine)?.agentAlignment }
        XCTAssertEqual(alignments, [.normal, .flipped, .normal, .flipped])
    }

    /// 间奏与第一条提示之前的行没有归属：留在左边，也不打乱换边节奏
    func testAlignmentIsNormalBeforeFirstCue() {
        let source = [
            line(0, 0, 3, text: "前奏后的第一句"),
            line(1, 3, 6, kind: .interlude),
            line(2, 6, 9, text: "甲", vocalist: voice(0)),
            line(3, 9, 12, kind: .interlude),
            line(4, 12, 15, text: "乙", vocalist: voice(1)),
        ]
        let alignments = LyricsAdapter.makeLyrics(from: source).lines
            .map { ($0 as? TextLine)?.agentAlignment }
        XCTAssertEqual(alignments, [.normal, nil, .normal, nil, .flipped])
    }

    /// 现状回归：没有歌手提示行的歌一律贴左
    func testNoVocalistMeansNormalAlignment() {
        let source = (0..<3).map { line($0, Double($0), Double($0) + 1, text: "句") }
        let lyrics = LyricsAdapter.makeLyrics(from: source)
        XCTAssertEqual(lyrics.vocalistsType, .single)
        XCTAssertTrue(lyrics.lines.allSatisfy { ($0 as? TextLine)?.agentAlignment == .normal })
    }

    // MARK: - 无时间戳的纯文本

    private func plain(_ index: Int, _ text: String,
                       translation: String? = nil,
                       startsParagraph: Bool = false) -> LyricLine {
        LyricLine(index: index, time: 0, end: 0, text: text, translation: translation,
                  kind: .plain, startsParagraph: startsParagraph)
    }

    /// 整份无戳 ⇒ 静态档：每行都是 `TextLine`，时间非有限（永不选中、点击跳转天然被挡），
    /// 没有逐字也没有能力位。
    func testUntimedBecomesStaticTextLines() throws {
        let lyrics = LyricsAdapter.makeLyrics(from: [plain(0, "一", startsParagraph: true),
                                                    plain(1, "二")])
        XCTAssertEqual(lyrics.type, .static)
        XCTAssertEqual(lyrics.lines.count, 2)
        for mapped in lyrics.lines {
            let text = try XCTUnwrap(mapped as? TextLine)
            XCTAssertFalse(text.startTime.isFinite)
            XCTAssertFalse(text.endTime.isFinite)
            XCTAssertTrue(text.syllables.isEmpty)
            XCTAssertEqual(text.capabilities, [])
        }
    }

    /// 本模块的头号不变量在新分支上重测一遍
    func testUntimedIndicesMatchArrayPositions() {
        let source = (0..<5).map { plain($0, "第\($0)句") }
            + [line(5, 0, 0, text: "创作者：甲", kind: .credits)]
        let lyrics = LyricsAdapter.makeLyrics(from: source)
        XCTAssertEqual(lyrics.lines.count, 6)
        for (position, mapped) in lyrics.lines.enumerated() {
            XCTAssertEqual(mapped.index, position)
        }
    }

    /// 尾行仍是 `SongwritersLine`，`songwriters` 非空
    func testUntimedKeepsSongwritersLine() {
        let lyrics = LyricsAdapter.makeLyrics(from: [plain(0, "一"),
                                                     line(1, 0, 0, text: "创作者：甲", kind: .credits)])
        XCTAssertEqual(lyrics.type, .static, "尾部那条 credits 不把整份赶出静态档")
        XCTAssertTrue(lyrics.lines[1] is SongwritersLine)
        XCTAssertEqual(lyrics.songwriters, ["创作者：甲"])
    }

    /// 段落位是**解析层给的结构信息**（纯文本里的空行），原样透传，不在这里猜
    func testParagraphFlagPassesThrough() {
        let source = [plain(0, "一", startsParagraph: true),
                      plain(1, "二"),
                      plain(2, "三", startsParagraph: true)]
        let flags = LyricsAdapter.makeLyrics(from: source).lines
            .map { ($0 as? TextLine)?.isFirstLineOfParagraph }
        XCTAssertEqual(flags, [true, false, true])
    }

    /// 无戳的译文照旧落到副行上
    func testUntimedTranslationIsCarriedOver() {
        let lyrics = LyricsAdapter.makeLyrics(from: [plain(0, "一", translation: "one")])
        XCTAssertEqual((lyrics.lines[0] as? TextLine)?.translation, "one")
    }

    /// 新分支没有劫持老路：带戳输入仍是 `.timedLines` / `.timedWords`
    func testTimedInputIsNotHijacked() {
        XCTAssertEqual(LyricsAdapter.makeLyrics(from: [line(0, 0, 3, text: "整行")]).type, .timedLines)
        let syllables = [LyricSyllable(text: "逐", time: 0, duration: 0.5),
                         LyricSyllable(text: "字", time: 0.5, duration: 0.5)]
        XCTAssertEqual(LyricsAdapter.makeLyrics(
            from: [line(0, 0, 3, text: "逐字", syllables: syllables)]).type, .timedWords)
        // 带戳正文 + 尾部 credits：仍是同步档
        let mixed = [line(0, 0, 3, text: "整行"),
                     line(1, 3, 23, text: "创作者：甲", kind: .credits)]
        XCTAssertEqual(LyricsAdapter.makeLyrics(from: mixed).type, .timedLines)
    }

    /// 空歌词是「确认没词」，不能翻进静态档
    func testEmptyLyricsAreNotUntimed() {
        XCTAssertFalse([LyricLine]().isUntimed)
        XCTAssertTrue([LyricLine(index: 0, time: 0, end: 0, text: "一", kind: .plain)].isUntimed)
        XCTAssertFalse([LyricLine(index: 0, time: 0, end: 3, text: "一")].isUntimed)
    }
}

// MARK: - LyricsStore

/// 歌词缓存：侧栏与整窗共用一份取词结果。
///
/// 三条不变量——命中不再打网络、「确认没词」也算命中、同一首并发只发一条请求。
@MainActor
final class LyricsStoreTests: XCTestCase {

    /// 取词的闸门：`load` 进来先记一笔，然后停住，等测试放行。
    /// 用它把「同一首并发要两次」这件事变成确定的，不靠 sleep 猜时序。
    private final class LoadGate {
        private(set) var calls = 0
        private var resume: (() -> Void)?

        func load() async -> [LyricLine] {
            calls += 1
            await withCheckedContinuation { continuation in
                resume = { continuation.resume() }
            }
            return [LyricLine(index: 0, time: 0, end: 3, text: "一句")]
        }

        func release() {
            resume?()
            resume = nil
        }
    }

    private func track(_ id: String) -> Track {
        Track(id: id, kind: .qq, title: id, artistName: "某人", artistId: nil,
              albumName: "某碟", albumId: nil, artworkURL: nil, duration: 200)
    }

    private func line(_ text: String) -> [LyricLine] {
        [LyricLine(index: 0, time: 0, end: 3, text: text)]
    }

    func testCacheHitSkipsSecondLoad() async {
        let store = LyricsStore()
        let song = track("qq:1")
        var calls = 0
        let first = await store.lyrics(for: song) { calls += 1; return self.line("一句") }
        XCTAssertEqual(first.map(\.text), ["一句"])

        let second = await store.lyrics(for: song) { calls += 1; return self.line("不该被调到") }
        XCTAssertEqual(second.map(\.text), ["一句"], "第二次要走缓存")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.cachedLyrics(for: song)?.map(\.text), ["一句"],
                       "同步查询要能直接拿到，视图才不闪空")
    }

    /// 「这首确认没有词」也要缓存，否则没词的歌每次开面板都白打一趟。
    func testNegativeResultIsCached() async {
        let store = LyricsStore()
        let song = track("qq:2")
        var calls = 0
        _ = await store.lyrics(for: song) { calls += 1; return [] }
        _ = await store.lyrics(for: song) { calls += 1; return [] }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.cachedLyrics(for: song), [], "空数组是命中，不是没缓存")
    }

    func testInFlightRequestIsShared() async {
        let store = LyricsStore()
        let song = track("qq:3")
        let gate = LoadGate()

        let first = Task { await store.lyrics(for: song) { await gate.load() } }
        // 等第一条真的进到 load 里（登记完 inFlight），再发第二条。
        var spins = 0
        while gate.calls == 0 && spins < 1000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertEqual(gate.calls, 1)

        let second = Task { await store.lyrics(for: song) { await gate.load() } }
        await Task.yield()
        gate.release()

        let (a, b) = (await first.value, await second.value)
        XCTAssertEqual(a.map(\.text), ["一句"])
        XCTAssertEqual(b.map(\.text), ["一句"], "第二条等的是同一条请求")
        XCTAssertEqual(gate.calls, 1, "同一首并发只许发一条")
    }

    /// LRU：超过上限先扔最久没用到的那首。
    func testEvictsLeastRecentlyUsed() async {
        let store = LyricsStore(capacity: 2)
        let (a, b, c) = (track("qq:a"), track("qq:b"), track("qq:c"))
        _ = await store.lyrics(for: a) { self.line("A") }
        _ = await store.lyrics(for: b) { self.line("B") }
        // 回头再用一次 A，最久没用的就轮到 B。
        XCTAssertNotNil(store.cachedLyrics(for: a))
        _ = await store.lyrics(for: c) { self.line("C") }

        XCTAssertNotNil(store.cachedLyrics(for: a), "刚用过，不该被扔")
        XCTAssertNil(store.cachedLyrics(for: b), "最久没用的那首被扔掉")
        XCTAssertNotNil(store.cachedLyrics(for: c))
    }

}
