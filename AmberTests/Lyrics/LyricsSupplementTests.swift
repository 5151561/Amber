import XCTest
@testable import Amber

/// 行级歌词换另一家逐字版的三道闸。最要紧的是第三道：**不是同一个录音就不换**。
final class LyricsSupplementTests: XCTestCase {

    private func track(_ title: String, _ artist: String, _ duration: TimeInterval,
                       kind: ProviderKind = .netease) -> Track {
        Track(id: "\(kind == .netease ? "ne" : "qq"):\(title)", kind: kind, title: title,
              artistName: artist, artistId: nil, albumName: "", albumId: nil,
              artworkURL: nil, duration: duration)
    }

    private func lrc(_ pairs: [(TimeInterval, String)]) -> [LyricLine] {
        pairs.enumerated().map { index, pair in
            LyricLine(index: index, time: pair.0, end: pair.0 + 2, text: pair.1)
        }
    }

    private func qrc(_ pairs: [(TimeInterval, String)]) -> [LyricLine] {
        pairs.enumerated().map { index, pair in
            LyricLine(index: index, time: pair.0, end: pair.0 + 2, text: pair.1,
                      syllables: [LyricSyllable(text: pair.1, time: pair.0, duration: 2)])
        }
    }

    func testOnlyLineLevelTimedLyricsAreSupplemented() {
        XCTAssertTrue(LyricsSupplement.isLineLevel(lrc([(1, "一句")])))
        XCTAssertFalse(LyricsSupplement.isLineLevel(qrc([(1, "一句")])), "已经是逐字")
        XCTAssertFalse(LyricsSupplement.isLineLevel([]), "没词：没有可核对的时间轴")
        let plain = [LyricLine(index: 0, time: .infinity, end: .infinity, text: "纯文本", kind: .plain)]
        XCTAssertFalse(LyricsSupplement.isLineLevel(plain))
    }

    func testCandidateNeedsSameTitleSharedArtistAndCloseDuration() {
        let own = track("果实", "陈粒", 262)
        XCTAssertTrue(LyricsSupplement.isCandidate(track("果实", "陈粒", 263, kind: .qq), for: own))
        XCTAssertTrue(LyricsSupplement.isCandidate(track("果实", "陈粒/李卓", 262, kind: .qq), for: own),
                      "合作歌手只要有一人对上")
        XCTAssertTrue(LyricsSupplement.isCandidate(track("异心引力", "银河快递 (Galaxy Express)", 234, kind: .qq),
                                                   for: track("异心引力", "银河快递", 234)),
                      "别名挂在括号里也是同一个人")
        XCTAssertFalse(LyricsSupplement.isCandidate(track("果实 (Live)", "陈粒", 262, kind: .qq), for: own))
        XCTAssertFalse(LyricsSupplement.isCandidate(track("果实", "某翻唱", 262, kind: .qq), for: own))
        XCTAssertFalse(LyricsSupplement.isCandidate(track("果实", "陈粒", 280, kind: .qq), for: own),
                       "时长差出十几秒多半是剪辑版")
    }

    func testTimingMustAgreeLineByLine() {
        let own = lrc([(4.5, "一个一个拼凑简单的词语"), (7.98, "一秒一秒穿过混乱的世纪"),
                       (11.49, "给我安全的"), (13.26, "给我安全的岛屿")])
        // 同一录音：开唱时刻差零点几秒，标点空格不同不算差别
        let same = qrc([(4.62, "一个一个 拼凑简单的词语"), (8.1, "一秒一秒，穿过混乱的世纪"),
                        (11.6, "给我安全的"), (13.4, "给我安全的岛屿")])
        XCTAssertTrue(LyricsSupplement.timingAgrees(own, same))
        // 不同录音：词一样，前奏长了 6 秒
        let shifted = qrc([(10.5, "一个一个拼凑简单的词语"), (13.98, "一秒一秒穿过混乱的世纪"),
                           (17.49, "给我安全的"), (19.26, "给我安全的岛屿")])
        XCTAssertFalse(LyricsSupplement.timingAgrees(own, shifted))
        // 只对上一句：不够一半，可能是同名的另一首
        let unrelated = qrc([(4.5, "一个一个拼凑简单的词语"), (8, "别的词"), (12, "别的词二"), (14, "别的词三")])
        XCTAssertFalse(LyricsSupplement.timingAgrees(own, unrelated))
    }

    /// 副歌重复出现时取时间上最近的那一次配对，不能拿第一次出现去比。
    func testRepeatedLinesPairWithTheNearestOccurrence() {
        let own = lrc([(41.49, "飞满天"), (113.88, "飞满天"), (172.05, "飞满天")])
        let candidate = qrc([(41.6, "飞满天"), (114.0, "飞满天"), (172.2, "飞满天")])
        XCTAssertTrue(LyricsSupplement.timingAgrees(own, candidate))
    }

    func testTranslationIsCarriedOverOnlyWhereMissing() {
        let own = [LyricLine(index: 0, time: 1, end: 3, text: "Hello", translation: "你好"),
                   LyricLine(index: 1, time: 4, end: 6, text: "World", translation: "世界")]
        let candidate = [
            LyricLine(index: 0, time: 1.1, end: 3, text: "Hello",
                      syllables: [LyricSyllable(text: "Hello", time: 1.1, duration: 1)]),
            LyricLine(index: 1, time: 4.1, end: 6, text: "World", translation: "世界（QQ）",
                      syllables: [LyricSyllable(text: "World", time: 4.1, duration: 1)]),
        ]
        let merged = LyricsSupplement.carrySecondaryLines(from: own, into: candidate)
        XCTAssertEqual(merged[0].translation, "你好")
        XCTAssertEqual(merged[1].translation, "世界（QQ）", "另一家自己有的不覆盖")
        XCTAssertEqual(merged[0].syllables, candidate[0].syllables)
    }
}
