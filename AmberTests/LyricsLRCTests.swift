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
