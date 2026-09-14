import XCTest
@testable import Amber

/// 过渡时长的计算与等功率折线。都是纯函数，不用起播放器。
final class CrossfadePlanTests: XCTestCase {

    /// N = min(6, 时长/4)，不足 12 秒不过渡。
    func testCrossfadeSeconds() {
        XCTAssertEqual(CrossfadeRamp.seconds(forDuration: 200), 6)
        XCTAssertEqual(CrossfadeRamp.seconds(forDuration: 24), 6)
        XCTAssertEqual(CrossfadeRamp.seconds(forDuration: 20), 5)
        XCTAssertEqual(CrossfadeRamp.seconds(forDuration: 12), 3)
        XCTAssertNil(CrossfadeRamp.seconds(forDuration: 11.9), "太短的音轨不过渡")
        XCTAssertNil(CrossfadeRamp.seconds(forDuration: .infinity), "时长未知不过渡")
    }

    /// 三段折线的四个节点上，两条曲线的功率和正好是 1。
    func testEqualPowerAtNodes() {
        for k in 0...3 {
            let t = Double(k) / 3
            let a = CrossfadeRamp.fadeInValue(at: t)
            let b = CrossfadeRamp.fadeOutValue(at: t)
            XCTAssertEqual(a * a + b * b, 1, accuracy: 0.005, "节点 \(k) 的功率和")
        }
    }

    /// 段内的凹陷不超过 0.35 dB（真正的等功率要 cos/sin，`setVolumeRamp` 只有线性）。
    func testEqualPowerDipInsideSegments() {
        var minimum = Double.infinity
        for i in 0...600 {
            let t = Double(i) / 600
            let a = CrossfadeRamp.fadeInValue(at: t)
            let b = CrossfadeRamp.fadeOutValue(at: t)
            minimum = min(minimum, a * a + b * b)
        }
        XCTAssertGreaterThan(minimum, 0.92, "功率凹陷 \(10 * log10(minimum)) dB")
        XCTAssertLessThanOrEqual(minimum, 1.0001)
    }

    /// 过渡起点与预取点：起点 = 时长 − N，预取再往前 20 秒。
    func testTimeline() {
        let duration: TimeInterval = 210
        let n = CrossfadeRamp.seconds(forDuration: duration)!
        XCTAssertEqual(duration - n, 204)
        XCTAssertEqual(duration - n - CrossfadeRamp.prefetchLead, 184)
    }

    // MARK: - 工作时长

    /// 三个候选一致（或只差一点）时用 item 报的那个。
    func testWorkingDurationUsesItemWhenCandidatesAgree() {
        let d = PlayerController.workingDuration(item: 210, meta: 209, assetTrack: 210.5)
        XCTAssertEqual(d, 210)
    }

    /// item 的估值明显短了（渐进式 MP3 常见）→ 取最长的那个，
    /// 否则过渡会提前十几秒开，歌没唱完就切了。
    func testWorkingDurationPrefersLongestWhenItemIsShort() {
        XCTAssertEqual(PlayerController.workingDuration(item: 200, meta: 213, assetTrack: nil), 213)
        XCTAssertEqual(PlayerController.workingDuration(item: 200, meta: nil, assetTrack: 214), 214)
    }

    /// item 报不出来（直播流 / 还没解析）就退回剩下的候选；一个都没有时是 0。
    func testWorkingDurationFallbacks() {
        XCTAssertEqual(PlayerController.workingDuration(item: nil, meta: 180, assetTrack: nil), 180)
        XCTAssertEqual(PlayerController.workingDuration(item: .infinity, meta: 180,
                                                        assetTrack: nil), 180)
        XCTAssertEqual(PlayerController.workingDuration(item: nil, meta: nil, assetTrack: nil), 0)
        XCTAssertEqual(PlayerController.workingDuration(item: nil, meta: 0, assetTrack: nil), 0)
    }

    // MARK: - 交叠的那道闸

    /// 位置确实到尾段了才开交叠。
    func testOverlapBeginsOnlyNearTheEnd() {
        XCTAssertTrue(PlayerController.shouldBeginOverlap(position: 204, workingDuration: 210,
                                                          fade: 6))
        XCTAssertTrue(PlayerController.shouldBeginOverlap(position: 202, workingDuration: 210,
                                                          fade: 6), "8 秒容差之内还算到尾了")
        XCTAssertFalse(PlayerController.shouldBeginOverlap(position: 195, workingDuration: 210,
                                                           fade: 6),
                       "还剩十几秒就开交叠，正是「歌没唱完就切了」")
        XCTAssertFalse(PlayerController.shouldBeginOverlap(position: .nan, workingDuration: 210,
                                                           fade: 6))
        XCTAssertFalse(PlayerController.shouldBeginOverlap(position: 100, workingDuration: 0,
                                                           fade: 6))
    }
}
