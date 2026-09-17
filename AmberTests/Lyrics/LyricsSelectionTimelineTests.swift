import SwiftUI
import QuartzCore
import CoreText
import XCTest
@testable import Amber

/// 选行状态机：时间基准、准入 / 淘汰、时间源防抖。
@MainActor
final class LyricsSelectionTimelineTests: XCTestCase, LyricsKitFixtures {

    // MARK: - §1.2 时间基准

    func testTimeBasisSubtractsSpatialOffset() {
        let manager = makeManager(lead: 0.1)
        manager.elapsedTimeProvider = { 30 }
        manager.isPlayingSpatial = true
        let basis = manager.timeBasis(spatialLyricsOffset: 0.4, candidateLineDuration: 3)
        // [实测] fsub d8, d8, d10
        XCTAssertEqual(basis.elapsed, 29.6, accuracy: 1e-9)
        // [实测] fadd d10, d8, d9：cutoff = elapsed + animationDuration(行时长)
        XCTAssertEqual(basis.cutoff, 29.7, accuracy: 1e-9)
    }

    func testTimeBasisIgnoresSpatialOffsetWhenNotSpatial() {
        let manager = makeManager()
        manager.elapsedTimeProvider = { 12 }
        let basis = manager.timeBasis(spatialLyricsOffset: 5, candidateLineDuration: nil)
        XCTAssertEqual(basis.elapsed, 12, accuracy: 1e-9)
    }

    // MARK: - §1.3 准入与淘汰

    /// 准入条件是 `elapsed > startTime − maxEndTimeOffset`。
    /// [实测] 的在**相等时也跳过**，所以恰好相等不准入。
    func testAdmissionBoundaryExcludesEquality() {
        let manager = makeManager()
        let line = textLine(start: 10, end: 14)
        XCTAssertFalse(manager.shouldAdmit(line: line, elapsed: 9.5))
        XCTAssertFalse(manager.shouldAdmit(line: line, elapsed: 9.4999))
        XCTAssertTrue(manager.shouldAdmit(line: line, elapsed: 9.5001))
    }

    /// 不足 `maxSelectedLines` 不淘汰；满了才比`endTime` 与 cutoff，
    /// `endTime >= cutoff` 保留。[实测]
    func testEvictionRequiresFullSelection() {
        let manager = makeManager()
        XCTAssertFalse(manager.shouldEvictOldestSelectedLine(
            oldestEndTime: 0, cutoff: 100, selectedCount: 1))
        XCTAssertTrue(manager.shouldEvictOldestSelectedLine(
            oldestEndTime: 9.99, cutoff: 10, selectedCount: 2))
        XCTAssertFalse(manager.shouldEvictOldestSelectedLine(
            oldestEndTime: 10, cutoff: 10, selectedCount: 2))
    }

    /// [实测]：`endTime >= elapsed` 表示还没唱完。
    func testHasFinishedBoundary() {
        let manager = makeManager()
        let line = textLine(start: 1, end: 5)
        XCTAssertFalse(manager.hasFinished(line: line, elapsed: 5))
        XCTAssertTrue(manager.hasFinished(line: line, elapsed: 5.0001))
    }

    /// 句与句交界处两行同亮。
    ///
    /// 两个时刻夹出的窗口：新行在 `startTime − 0.5` 进场，旧行在`endTime − lead`
    /// 出局。所以同亮的前提是 `下一句起点 − 上一句终点 < 0.5 − lead`——
    /// 这里 gap = 0.2、lead = 0.1，窗口是 [9.7, 9.9)。
    func testTwoLinesSelectedAtSentenceBoundary() {
        let manager = makeManager(lead: 0.1)
        var lyrics = Lyrics()
        lyrics.lines = [textLine(index: 0, start: 0, end: 10),
                        textLine(index: 1, start: 10.2, end: 14)]
        manager.setLyrics(lyrics)

        manager.elapsedTimeProvider = { 9.8 }
        manager.update()
        XCTAssertEqual(manager.selectedLines.map(\.index), [0, 1])
    }

    /// 旧行的退场判据是 `endTime < cutoff`，与「唱完后再亮 0.5 秒」无关。
    ///
    /// 照「旧行延后 0.5 秒」实现的话，5.2 秒时第 0 行还亮着（要到 5.5 才灭）；
    /// 按 cutoff 实现则 4.9 秒就该出局。§1.3 特意更正过这一条：
    /// `maxEndTimeOffset` 是**减在下一行的`startTime`** 上的。
    func testOldLineLeavesByCutoffNotByGracePeriod() {
        let manager = makeManager(lead: 0.1)
        var lyrics = Lyrics()
        lyrics.lines = [textLine(index: 0, start: 0, end: 5),
                        textLine(index: 1, start: 5.2, end: 9)]
        manager.setLyrics(lyrics)

        manager.elapsedTimeProvider = { 4.85 }     // 4.7 起两行同亮，4.9 才出局
        manager.update()
        XCTAssertEqual(manager.selectedLines.map(\.index), [0, 1])

        manager.elapsedTimeProvider = { 5.2 }
        manager.update()
        XCTAssertEqual(manager.selectedLines.map(\.index), [1])
    }

    /// 只剩一行时不淘汰——`maxSelectedLines` 那道闸在前面（的），
    /// 所以间奏前的最后一句会一直亮到间奏行进场为止，中间不会出现「谁都不亮」。
    func testSoleSelectedLineIsNeverEvicted() {
        let manager = makeManager(lead: 0.1)
        var lyrics = Lyrics()
        lyrics.lines = [textLine(index: 0, start: 0, end: 5)]
        manager.setLyrics(lyrics)
        manager.elapsedTimeProvider = { 30 }
        manager.update()
        XCTAssertEqual(manager.selectedLines.map(\.index), [0])
    }

    // MARK: - §1.4 时间源防抖

    func testTimingProviderGateThresholds() {
        let now = Date()
        var gate = TimingProviderGate(lastTapDate: nil)
        // 在浮点比较下含相等 → 差 0.5 也忽略
        XCTAssertEqual(gate.decide(newElapsed: 10.5, currentElapsed: 10, now: now), .ignoreTooClose)
        XCTAssertEqual(gate.decide(newElapsed: 10.51, currentElapsed: 10, now: now), .accept)

        gate.lastTapDate = now.addingTimeInterval(-0.99)
        XCTAssertEqual(gate.decide(newElapsed: 20, currentElapsed: 10, now: now), .ignoreRecentTap)
        gate.lastTapDate = now.addingTimeInterval(-1.01)
        XCTAssertEqual(gate.decide(newElapsed: 20, currentElapsed: 10, now: now), .accept)
    }
}
