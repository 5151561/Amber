import XCTest
@testable import Amber

/// LRC 序列化：写进音频标签的那一份歌词长什么样。
final class LyricsLRCTests: XCTestCase {

    private func line(_ index: Int, _ time: TimeInterval, _ text: String,
                      translation: String? = nil, transliteration: String? = nil,
                      kind: LyricLine.Kind = .lyric) -> LyricLine {
        LyricLine(index: index, time: time, end: time + 3, text: text,
                  translation: translation, transliteration: transliteration, kind: kind)
    }

    // MARK: - 时间戳

    func testTimestampFormat() {
        let out = LyricsLRC.text(from: [
            line(0, 0, "零秒"),
            line(1, 5.5, "五秒半"),
            line(2, 65.07, "一分零五"),
        ])
        XCTAssertEqual(out, """
            [00:00.00]零秒
            [00:05.50]五秒半
            [01:05.07]一分零五
            """)
    }

    /// 分钟不回绕：62 分 3.1 秒写成 `[62:03.10]`，不是 `[02:03.10]`。
    func testMinutesDoNotWrapPastAnHour() {
        XCTAssertEqual(LyricsLRC.text(from: [line(0, 62 * 60 + 3.1, "长音轨")]),
                       "[62:03.10]长音轨")
    }

    /// 百分秒进位要一路带上去，不能只在自己那一格四舍五入。
    func testHundredthsCarry() {
        XCTAssertEqual(LyricsLRC.text(from: [line(0, 9.999, "进位")]), "[00:10.00]进位")
        XCTAssertEqual(LyricsLRC.text(from: [line(0, 59.999, "跨分钟")]), "[01:00.00]跨分钟")
        XCTAssertEqual(LyricsLRC.text(from: [line(0, 3599.999, "跨小时")]), "[60:00.00]跨小时")
    }

    /// 负数与 NaN 当 0——上游算出来的偏移偶尔会是这两种，别让它写出 `[-1:-3.-0]`。
    func testNonsenseTimesFallBackToZero() {
        XCTAssertEqual(LyricsLRC.text(from: [line(0, -12, "负数")]), "[00:00.00]负数")
        XCTAssertEqual(LyricsLRC.text(from: [line(0, .nan, "NaN")]), "[00:00.00]NaN")
        XCTAssertEqual(LyricsLRC.text(from: [line(0, .infinity, "无穷")])?.hasSuffix("无穷"), true)
    }

    // MARK: - 取哪些

    /// 双语：译文紧跟正文，同一个时间戳。
    func testTranslationFollowsBodyWithSameTimestamp() {
        let out = LyricsLRC.text(from: [
            line(0, 1, "Hello", translation: "你好"),
            line(1, 2, "World"),
        ])
        XCTAssertEqual(out, """
            [00:01.00]Hello
            [00:01.00]你好
            [00:02.00]World
            """)
    }

    /// 发音副行是界面上的东西，不进文件。
    func testTransliterationIsDropped() {
        XCTAssertEqual(LyricsLRC.text(from: [line(0, 1, "甘い", transliteration: "amai")]),
                       "[00:01.00]甘い")
    }

    /// 间奏与尾部创作者是 Amber 自己造的占位/收尾，不是歌词原文。
    func testInterludeAndCreditsAreFiltered() {
        let out = LyricsLRC.text(from: [
            line(0, 1, "第一句"),
            line(1, 2, "•••", kind: .interlude),
            line(2, 30, "第二句"),
            line(3, 60, "词：某某\n曲：某某", kind: .credits),
        ])
        XCTAssertEqual(out, """
            [00:01.00]第一句
            [00:30.00]第二句
            """)
    }

    func testWhitespaceIsTrimmedAndEmptyBodiesSkipped() {
        let out = LyricsLRC.text(from: [
            line(0, 1, "  留白两端  "),
            line(1, 2, "   "),
            line(2, 3, "", translation: "孤儿译文"),
            line(3, 4, "正常"),
        ])
        XCTAssertEqual(out, """
            [00:01.00]留白两端
            [00:04.00]正常
            """)
    }

    // MARK: - 返回 nil 的两种情况

    func testEmptyInputReturnsNil() {
        XCTAssertNil(LyricsLRC.text(from: []))
    }

    func testOnlyInterludeOrBlankReturnsNil() {
        XCTAssertNil(LyricsLRC.text(from: [
            line(0, 1, "•••", kind: .interlude),
            line(1, 2, "词：某某", kind: .credits),
            line(2, 3, "  "),
        ]))
    }

    // MARK: - 排序

    /// 入参不保证有序，输出必须按时间递增。
    func testUnorderedInputIsSorted() {
        let out = LyricsLRC.text(from: [
            line(2, 30, "第三"),
            line(0, 1, "第一"),
            line(1, 5, "第二", translation: "second"),
        ])
        XCTAssertEqual(out, """
            [00:01.00]第一
            [00:05.00]第二
            [00:05.00]second
            [00:30.00]第三
            """)
    }

    /// 同一时刻的两行（合唱、叠句）按 index 稳住原有先后。
    func testSameTimeKeepsIndexOrder() {
        let out = LyricsLRC.text(from: [
            line(1, 10, "后一句"),
            line(0, 10, "前一句"),
        ])
        XCTAssertEqual(out, """
            [00:10.00]前一句
            [00:10.00]后一句
            """)
    }

    // MARK: - 无时间戳那一档

    private func plain(_ index: Int, _ text: String, translation: String? = nil,
                       transliteration: String? = nil) -> LyricLine {
        LyricLine(index: index, time: 0, end: 0, text: text,
                  translation: translation, transliteration: transliteration, kind: .plain)
    }

    /// 纯文本歌词写成纯文本：一个 `[` 都不该出现，行序与入参一致。
    /// 给每行补 `[00:00.00]` 会让规矩的播放器把整首当成第 0 秒的一行。
    func testUntimedLyricsAreWrittenWithoutTimestamps() {
        let out = LyricsLRC.text(from: [
            plain(0, "第一行"),
            plain(1, "第二行"),
            plain(2, "第三行"),
        ])
        XCTAssertEqual(out, """
            第一行
            第二行
            第三行
            """)
        XCTAssertEqual(out?.contains("["), false)
    }

    /// 无戳那一档**不排序**：文件顺序是纯文本仅有的顺序信息，index 乱序也照原样写。
    /// （带戳那支的排序由 `testUnorderedInputIsSorted` 守着，两条互不影响。）
    func testUntimedLyricsKeepInputOrder() {
        XCTAssertEqual(LyricsLRC.text(from: [
            plain(7, "先出现的"),
            plain(2, "后出现的"),
        ]), """
            先出现的
            后出现的
            """)
    }

    /// 双语纯文本：译文紧跟它那一行，而不是攒到末尾。
    func testUntimedTranslationFollowsItsLine() {
        XCTAssertEqual(LyricsLRC.text(from: [
            plain(0, "Hello", translation: "你好"),
            plain(1, "World", translation: "世界"),
        ]), """
            Hello
            你好
            World
            世界
            """)
    }

    /// 发音副行在这一档同样不写（沿用带戳那支的取舍）。
    func testUntimedTransliterationIsDropped() {
        XCTAssertEqual(LyricsLRC.text(from: [plain(0, "甘い", transliteration: "amai")]), "甘い")
    }

    /// 尾部创作者不写。只剩创作者时整份就没有正文了 ⇒ nil。
    func testUntimedCreditsAreDroppedAndCreditsOnlyReturnsNil() {
        XCTAssertEqual(LyricsLRC.text(from: [
            plain(0, "正文"),
            line(1, 0, "词：某某", kind: .credits),
        ]), "正文")
        XCTAssertNil(LyricsLRC.text(from: [line(0, 0, "词：某某", kind: .credits)]))
    }

    /// 无戳但正文全是空白 ⇒ nil，别给文件塞一串空行。
    func testUntimedAllBlankReturnsNil() {
        XCTAssertNil(LyricsLRC.text(from: [
            plain(0, "   "),
            plain(1, ""),
            plain(2, "\n"),
        ]))
    }

    /// `.plain` 混进带戳的一份里时（真实解析不会产出这种，防的是以后改坏）：
    /// 整份不算无戳，`.plain` 就被带戳那支的 `.lyric` 过滤挡在外面，一个字都不写。
    func testPlainLinesNeverLeakIntoTimedOutput() {
        XCTAssertEqual(LyricsLRC.text(from: [
            line(0, 1, "带戳的"),
            plain(1, "无戳的"),
        ]), "[00:01.00]带戳的")
    }

    // MARK: - 排序（续）

    /// 歌手提示行与间奏、创作者同档：它标的是结构，不是歌词原文，不写进标签
    func testAgentCueLinesAreNotWritten() {
        let lrc = """
        [00:00.00]某某：
        [00:02.00]第一句
        [00:06.00]第二句
        """
        XCTAssertEqual(LyricsLRC.text(from: LyricParser.parse(lrc)), """
            [00:02.00]第一句
            [00:06.00]第二句
            """)
    }
}
