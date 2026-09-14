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
                      syllables: [LyricSyllable] = []) -> LyricLine {
        LyricLine(index: index, time: time, end: end, text: text,
                  translation: translation, syllables: syllables, kind: kind)
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
