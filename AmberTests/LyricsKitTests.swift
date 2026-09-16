import SwiftUI
import QuartzCore
import CoreText
import XCTest
@testable import Amber

/// `Amber/Lyrics/` 的纯函数部分。
///
/// 每条断言都对着 lyrics 规格里的指令地址写——
/// 这些数值的唯一出处是实测，测试的作用是把「读出来的那个值」钉住，
/// 免得以后手滑改成「看起来更合理的」那个。
@MainActor
final class LyricsKitTests: XCTestCase {

    private func specs() -> LyricsSpecs { LyricsSpecs() }

    private func textLine(index: Int = 0,
                          start: TimeInterval,
                          end: TimeInterval) -> TextLine {
        var line = TextLine()
        line.index = index
        line.startTime = start
        line.endTime = end
        return line
    }

    private func makeManager(lead: TimeInterval = 0.1) -> SyncedLyricsManager {
        var configuration = SyncedLyricsManager.Configuration(
            finishLineAnimationDuration: 0.25, maxEndTimeOffset: 0.5)
        configuration.animationDuration = { _ in lead }
        return SyncedLyricsManager(configuration: configuration)
    }

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

    // MARK: - §2.4 / §9.1 弹簧

    /// [实测]：ω = 2π / response（那个常量是 π 不是 2π），
    /// stiffness = m·ω²，damping = ζ·2·√(k·m)。与 SwiftUI 的
    /// `Spring(response:dampingRatio:)` 一字不差。
    func testSpringFromDampingRatioAndResponse() {
        let spring = SpringTimingParameters(dampingRatio: 0.9, response: 0.5)
        let omega = 2 * Double.pi / 0.5
        XCTAssertEqual(spring.stiffness, omega * omega, accuracy: 1e-9)
        XCTAssertEqual(spring.dampingRatio, 0.9, accuracy: 1e-9)
        XCTAssertEqual(spring.angularFrequency, omega, accuracy: 1e-9)
    }

    /// 逐字歌词的翻行弹簧：唱得越快，阻尼比越低、周期越长。
    /// 下端 (ζ = 0.90) 正好接上 specs 那条 (1, 100, 18)。
    func testDerivedLineChangeSpringEndpoints() {
        let slow = SyncedLyricsVisualExperienceManager.derivedLineChangeSpring(speed: 0)
        XCTAssertEqual(slow.dampingRatio, 0.9, accuracy: 1e-6)
        let baseline = LyricsSpecs().lineChangeSpringTimingParameters
        XCTAssertEqual(baseline.dampingRatio, 0.9, accuracy: 1e-3)

        let fast = SyncedLyricsVisualExperienceManager.derivedLineChangeSpring(speed: 0.75)
        XCTAssertEqual(fast.dampingRatio, 0.78, accuracy: 1e-6)
        // response 0.48 → 0.75，ω 随之变小
        XCTAssertLessThan(fast.angularFrequency, slow.angularFrequency)
    }

    /// 点击驱动那条把 ζ 推过 1：过阻尼、不回弹。
    func testTapDrivenSpringIsOverdamped() {
        XCTAssertGreaterThan(SpringTimingParameters.tapDriven.dampingRatio, 1)
        XCTAssertLessThan(LyricsSpecs().lineChangeSpringTimingParameters.dampingRatio, 1)
    }

    /// §2.8 duration hack：命中就压 delay，弹簧本体不动。
    func testDurationHack() {
        XCTAssertTrue(DurationHack.isTriggered(lineTime: 1.0, maxEndTimeOffset: 0.5,
                                               baseOffset: 0.2, settlingDuration: 0.6))
        XCTAssertFalse(DurationHack.isTriggered(lineTime: 4.0, maxEndTimeOffset: 0.5,
                                                baseOffset: 0.2, settlingDuration: 0.6))
        XCTAssertEqual(DurationHack.delay(lineTime: 1.0, maxEndTimeOffset: 0.5, baseOffset: 0.2),
                       0.3, accuracy: 1e-9)
    }

    // MARK: - §2.5 目标位置

    func testScrollOriginTopClampsToZero() {
        let controller = SyncedLyricsViewController()
        controller.specs.selectedLinePosition = .top(12)
        controller.topInset = 40
        // y = max(0, minY − topInset)，x 恒为 0
        let near = controller.scrollOrigin(forLineFrame: CGRect(x: 5, y: 10, width: 100, height: 30))
        XCTAssertEqual(near, .zero)
        let far = controller.scrollOrigin(forLineFrame: CGRect(x: 5, y: 100, width: 100, height: 30))
        XCTAssertEqual(far, CGPoint(x: 0, y: 60))
    }

    /// B 路减的是「行 minY 与容器 minY 之差」，不是中心差。
    func testScrollOriginCenterSubtractsContainerMinY() {
        let controller = SyncedLyricsViewController()
        let container = CGRect(x: 0, y: 80, width: 400, height: 300)
        controller.specs.selectedLinePosition = .center(rect: container)
        let origin = controller.scrollOrigin(
            forLineFrame: CGRect(x: 0, y: 500, width: 300, height: 40))
        // 500 − (300 − 40)/2 − 80
        XCTAssertEqual(origin, CGPoint(x: 0, y: 500 - 130 - 80))
    }

    /// §17.3：tag ≥ 0 的两档（`top` / `topRelative`）在这个函数里**行为完全一样**，
    /// 载荷都不读；只有 `center` 才居中。基线版式是`.topRelative`，所以是贴顶。
    func testScrollOriginTopRelativeSticksToTop() throws {
        let controller = SyncedLyricsViewController()
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 260)
        controller.view.layoutSubtreeIfNeeded()
        controller.topInset = 40

        let frame = CGRect(x: 0, y: 100, width: 100, height: 30)
        controller.specs.selectedLinePosition = .top(12)
        let top = controller.scrollOrigin(forLineFrame: frame)
        controller.specs.selectedLinePosition = .topRelative(12, cardHeightPercentage: 0)
        XCTAssertEqual(controller.scrollOrigin(forLineFrame: frame), top)
        XCTAssertEqual(top, CGPoint(x: 0, y: 60))

        // `center(rect: nil)`（tag 0x81）才居中，参照`scrollView.frame`，且不减 minY。
        controller.specs.selectedLinePosition = .center(rect: nil)
        let container = try XCTUnwrap(controller.scrollView).frame
        XCTAssertEqual(controller.scrollOrigin(forLineFrame: frame),
                       CGPoint(x: 0, y: 100 - (container.height - 30) / 2))
    }

    /// §17.3：基线 spec 实测是 `.topRelative(12, cardHeightPercentage: 0)`（tag 字节 0x40）。
    func testBaselineSelectedLinePositionIsTopRelative() {
        guard case .topRelative(let offset, let percentage) = LyricsSpecs().selectedLinePosition
        else { return XCTFail("基线版式应当是 .topRelative") }
        XCTAssertEqual(offset, 12)
        XCTAssertEqual(percentage, 0)
    }

    /// 让位时刻正好比下一句开唱早**一个滚动动画**：滚动跑完那一刻就是开唱那一刻。
    /// 提前量取自翻行弹簧的 `settlingDuration`，不是写死的数。
    func testScrollTargetHandsOverOneScrollAnimationBeforeNextLine() throws {
        var elapsed: TimeInterval = 0
        let (controller, visual, _) = makeScrubFixture { elapsed }
        controller.setLyrics(Self.makeTextLyrics([(0, 8), (10, 15)]))
        let view0 = visual.lineViews[0]
        let view1 = visual.lineViews[1]
        view0.lineLayer?.apply(selected: true, animation: nil)
        visual.selectedLineViews = [view0, view1]
        let animation = SyncedLyricsLineLayer.SelectionAnimation(
            spring: controller.specs.lineChangeSpringTimingParameters)

        // 提前量的上限 = 这条弹簧跑完要多久，与 `ScrollSpring` 用的是同一个数。
        let lead = visual.scrollLead
        XCTAssertEqual(lead,
                       controller.specs.lineChangeSpringTimingParameters.settlingDuration,
                       accuracy: 1e-9)
        XCTAssertEqual(lead, animation.settlingDuration, accuracy: 1e-9,
                       "提前量必须等于真正下发的那条滚动动画的时长")
        XCTAssertGreaterThan(lead, 0)
        // 空档 2 s（8 → 10）比上限宽：这一次按上限走，不拉长。
        let line0 = try XCTUnwrap(view0.lineLayer?.line)
        let line1 = try XCTUnwrap(view1.lineLayer?.line)
        XCTAssertEqual(visual.handoverDuration(from: line0, to: line1), lead, accuracy: 1e-9)

        elapsed = 10 - lead - 0.01
        XCTAssertTrue(visual.scrollTargetLineView(at: elapsed) === view0, "还没到起跑时刻：焦点位仍是 A")
        controller.scrollToSelectedLine(animation: animation, animated: false)
        XCTAssertEqual(try XCTUnwrap(controller.scrollView?.contentView.bounds.origin),
                       controller.targetOrigin(for: view0))

        elapsed = 10 - lead
        XCTAssertTrue(visual.scrollTargetLineView(at: elapsed) === view1,
                      "提前一个滚动动画就让位，滚完正好赶上 B 开唱")
        controller.scrollToSelectedLine(animation: animation, animated: false)
        XCTAssertEqual(try XCTUnwrap(controller.scrollView?.contentView.bounds.origin),
                       controller.targetOrigin(for: view1))
    }

    /// 两句重叠（A 唱到 12、B 从 10 起）：判据仍只看 B 的开唱时刻，照样提前一个滚动动画。
    func testScrollTargetHandsOverBeforeOverlappingNextLineStarts() throws {
        let (controller, visual, _) = makeScrubFixture { 0 }
        controller.setLyrics(Self.makeTextLyrics([(0, 12), (10, 15)]))
        let a = visual.lineViews[0], b = visual.lineViews[1]
        a.lineLayer?.apply(selected: true, animation: nil)
        let lead = visual.scrollLead
        XCTAssertEqual(visual.handoverDuration(from: try XCTUnwrap(a.lineLayer?.line),
                                               to: try XCTUnwrap(b.lineLayer?.line)),
                       lead, accuracy: 1e-9, "空档为负：没有空档可占，照上限提前滚")

        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b], at: 10 - lead - 0.01) === a,
                      "还没到起跑时刻")
        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b], at: 10 - lead) === b,
                      "A 还在唱也照样起跑——滚完正好是 B 开唱")
        b.lineLayer?.apply(selected: true, animation: nil)
        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b], at: 11.0) === b, "两句同亮时停在后一句")
    }

    /// 句间停顿比一整条弹簧还宽：上一句一直亮着、焦点也一直停在它身上，
    /// 直到该为下一句起跑才让位——起跑点按上限算，不因为空档宽就拖长。
    func testScrollTargetStaysOnFinishedLineUntilItIsTimeToRun() throws {
        let (controller, visual, _) = makeScrubFixture { 0 }
        // A 8 s 唱完，B 11 s 才开唱：中间空 3 s。
        controller.setLyrics(Self.makeTextLyrics([(0, 8), (11, 16)]))
        let a = visual.lineViews[0], b = visual.lineViews[1]
        a.lineLayer?.apply(selected: true, animation: nil)
        let lead = visual.scrollLead

        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b], at: 8.0) === a, "唱完不等于该走")
        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b], at: 11 - lead - 0.01) === a,
                      "停顿里焦点一直停在 A 上")
        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b], at: 11 - lead) === b, "到点才起跑")
    }

    /// 首尾相接的短句（空档 0）：让位正好落在每一句的开唱时刻，一句一句来，不跳号。
    /// 没有空档可占，这一次就不滚——`scrollFocusPlan` 给出的时长是 0。
    func testTouchingShortLinesHandOverExactlyAtEachStart() throws {
        let (controller, visual, _) = makeScrubFixture { 0 }
        controller.setLyrics(Self.makeTextLyrics([(0, 1), (1, 1.3), (1.3, 1.6)]))
        let a = visual.lineViews[0], b = visual.lineViews[1], c = visual.lineViews[2]
        a.lineLayer?.apply(selected: true, animation: nil)
        XCTAssertGreaterThan(visual.scrollLead, 0.3, "这条用例要的就是「句长 < 提前量上限」")

        // 一行都没点亮（歌开头 / seek 落在句前）：停在第一条，判据根本走不到。
        XCTAssertTrue(visual.scrollTargetLineView(in: [b, c], at: 0.9) === b)

        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b, c], at: 0.99) === a, "A 还在唱")
        let plan = try XCTUnwrap(visual.scrollFocusPlan(in: [a, b, c], at: 1.0))
        XCTAssertTrue(plan.view === b, "A 一唱完、B 一开唱就让位")
        XCTAssertEqual(plan.duration, 0, accuracy: 1e-9, "没有空档可占：原地换行，不滚")

        // C 的开唱时刻还没到，不许跳号。
        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b, c], at: 1.2) === b, "最多领先一行")
        b.lineLayer?.apply(selected: true, animation: nil)
        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b, c], at: 1.29) === b, "B 还在唱")
        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b, c], at: 1.3) === c, "轮到下一句了")

        // 没有未点亮的下一句：停在正在唱的那句。
        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b], at: 1.5) === b)
    }

    /// 真交错的短句才提前滚，而且焦点位最多领先正在唱的那句一行——
    /// 按「谁最新准入就滚向谁」会连着往下翻，把正在唱的那句推出视口（2026-09-15 的「行错位」）。
    func testScrollTargetNeverRunsAheadOnShortOverlappingLines() throws {
        let (controller, visual, _) = makeScrubFixture { 0 }
        // A 唱到 1.2、B 从 1.0 起、C 从 1.3 起：两处都真交错。
        controller.setLyrics(Self.makeTextLyrics([(0, 1.2), (1, 1.4), (1.3, 1.6)]))
        let a = visual.lineViews[0], b = visual.lineViews[1], c = visual.lineViews[2]
        a.lineLayer?.apply(selected: true, animation: nil)
        let lead = visual.scrollLead
        XCTAssertEqual(visual.handoverDuration(from: try XCTUnwrap(a.lineLayer?.line),
                                               to: try XCTUnwrap(b.lineLayer?.line)),
                       lead, accuracy: 1e-9, "交错：照上限提前滚")

        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b, c], at: 1 - lead - 0.01) === a)
        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b, c], at: 1 - lead) === b, "该为 B 起跑了")
        // **只能到 B**：C 的起跑时刻早就过了（1.3 − lead < 1 − lead），也不许跳号。
        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b, c], at: 0.8) === b, "最多领先一行")
        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b, c], at: 1.0) === b, "还是只能到 B")

        // B 点亮之后焦点才轮到 C——整条时间轴整体提前了一个 lead，但翻行仍是逐句的。
        b.lineLayer?.apply(selected: true, animation: nil)
        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b, c], at: 1.0) === c, "轮到下一句了")
    }

    /// 换行时间按句间空档现算：空档比一整条弹簧窄就缩到空档那么宽，
    /// 于是滚动从上一句唱完起跑、到下一句开唱落位，不占别人的时间。**只缩不放。**
    func testHandoverDurationShrinksToFitTheGap() throws {
        let (controller, visual, _) = makeScrubFixture { 0 }
        let lead = visual.scrollLead
        XCTAssertGreaterThan(lead, 0.5)

        func duration(endingAt end: TimeInterval, nextStart: TimeInterval) throws -> TimeInterval {
            controller.setLyrics(Self.makeTextLyrics([(0, end), (nextStart, nextStart + 5)]))
            return visual.handoverDuration(
                from: try XCTUnwrap(visual.lineViews[0].lineLayer?.line),
                to: try XCTUnwrap(visual.lineViews[1].lineLayer?.line))
        }

        // 空档比上限宽：走上限，不拉长。
        XCTAssertEqual(try duration(endingAt: 8, nextStart: 8 + lead + 1), lead, accuracy: 1e-9)
        XCTAssertEqual(try duration(endingAt: 8, nextStart: 8 + lead), lead, accuracy: 1e-9)
        // 空档比上限窄：缩到空档那么宽。
        XCTAssertEqual(try duration(endingAt: 8, nextStart: 8.3), 0.3, accuracy: 1e-9)
        XCTAssertEqual(try duration(endingAt: 8, nextStart: 8.05), 0.05, accuracy: 1e-9)
        // 贴着（endTime == 下一句的 startTime）**不算重叠**：照缩到 0，原地换行。
        XCTAssertEqual(try duration(endingAt: 8, nextStart: 8), 0, accuracy: 1e-9)
        // 只有真交错（endTime 越过了下一句的 startTime）才算重叠：照上限提前滚，两句同亮。
        XCTAssertEqual(try duration(endingAt: 9, nextStart: 8), lead, accuracy: 1e-9)
        XCTAssertEqual(try duration(endingAt: 8.01, nextStart: 8), lead, accuracy: 1e-9)
    }

    /// 空档窄时让位时刻跟着往后挪：起跑点正好落在上一句唱完那一刻，落位正好是下一句开唱。
    func testHandoverStartsWhenPreviousLineEndsOnNarrowGap() throws {
        let (controller, visual, _) = makeScrubFixture { 0 }
        // A 唱到 8，B 从 8.3 起：空档 0.3 s，比一整条弹簧窄得多。
        controller.setLyrics(Self.makeTextLyrics([(0, 8), (8.3, 13)]))
        let a = visual.lineViews[0], b = visual.lineViews[1]
        a.lineLayer?.apply(selected: true, animation: nil)

        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b], at: 7.99) === a, "A 还在唱，不抢")
        XCTAssertTrue(visual.scrollTargetLineView(in: [a, b], at: 8.0) === b, "A 一唱完就起跑")
        let plan = try XCTUnwrap(visual.scrollFocusPlan(in: [a, b], at: 8.0))
        XCTAssertEqual(plan.duration, 0.3, accuracy: 1e-9, "这一次只跑 0.3 s，正好落在 8.3")
    }

    /// 压短的那条弹簧**确实**只跑这么久，而且阻尼比不变（过冲那点性格原样保留）。
    func testCompressedSpringSettlesInTheGivenDuration() throws {
        let (_, visual, _) = makeScrubFixture { 0 }
        let base = visual.makeLineChangeAnimation(speed: 0, useSpecsSpring: true)

        let short = try XCTUnwrap(visual.makeLineChangeAnimation(settlingIn: 0.3))
        XCTAssertEqual(short.settlingDuration, 0.3, accuracy: 1e-9)
        XCTAssertEqual(short.spring.settlingDuration, 0.3, accuracy: 1e-6,
                       "描述符上写的时长必须就是这条弹簧真跑的时长")
        XCTAssertEqual(short.spring.dampingRatio, base.spring.dampingRatio, accuracy: 1e-9,
                       "只压时间轴，不改阻尼比")

        // 只压不放：比原装还长的目标原样返回。
        let long = try XCTUnwrap(visual.makeLineChangeAnimation(settlingIn: base.settlingDuration + 1))
        XCTAssertEqual(long.spring, base.spring)
        // 时长为 0（贴着的两句）：没有可占的时间，退化成瞬时落位。
        XCTAssertNil(visual.makeLineChangeAnimation(settlingIn: 0))
        XCTAssertNil(visual.makeLineChangeAnimation(settlingIn: -1))
    }

    /// 准入窗口必须跟着 `scrollLead` 一起放宽：要滚过去，那一行得先在选中集合里。
    /// 而且一次只多放一行——`scrollLead` 比密集说唱的句长还大，不压上限就会一帧灌进好几行。
    func testAdmissionWindowFollowsScrollLead() throws {
        var elapsed: TimeInterval = 0
        let (controller, visual, timeline) = makeScrubFixture { elapsed }
        controller.setLyrics(Self.makeTextLyrics([(0, 8), (11, 16)]))
        let lead = visual.scrollLead
        XCTAssertGreaterThan(lead, controller.specs.maxEndTimeOffset,
                             "这条用例的前提是提前量比 [实测] 的 0.5 s 还大")

        elapsed = 4
        timeline.resync(at: elapsed)
        XCTAssertEqual(timeline.selectedLines.map(\.index), [0], "离 B 还早")

        elapsed = 11 - lead - 0.01
        timeline.update()
        XCTAssertEqual(timeline.selectedLines.map(\.index), [0], "还没到起跑时刻，B 不准入")

        elapsed = 11 - lead + 0.01
        timeline.update()
        XCTAssertTrue(timeline.selectedLines.contains { $0.index == 1 }, "该起跑了，B 准入")

        // 密集短句：一帧只放一行进来，选中集合不超过上限。
        let dense = SyncedLyricsManager(configuration: .init(specs: controller.specs),
                                        maxSelectedLines: controller.specs.maxSelectedLines)
        dense.setLyrics(Self.makeTextLyrics([(0, 0.3), (0.3, 0.6), (0.6, 0.9), (0.9, 1.2)]))
        dense.elapsedTimeProvider = { 0.1 }
        dense.update()
        XCTAssertLessThanOrEqual(dense.selectedLines.count, controller.specs.maxSelectedLines,
                                 "句长比提前量短也不许一帧灌进好几行")
    }

    /// 句间停顿里每一帧都会走一次倒带判据：队首可能是提前放进来、`startTime` 还在后头的那条，
    /// 照裸提前量判会被认成倒带，焦点位刚让过去又被拽回来。
    func testPreAdmittedHeadIsNotMistakenForRewind() throws {
        var elapsed: TimeInterval = 0
        let (controller, visual, timeline) = makeScrubFixture { elapsed }
        controller.setLyrics(Self.makeTextLyrics([(0, 8), (11, 16)]))
        let lead = visual.scrollLead
        let viewB = visual.lineViews[1]

        elapsed = 4
        timeline.resync(at: elapsed)
        elapsed = 11 - lead + 0.01
        timeline.update()
        // 队首此刻已经是 B（A 唱完被淘汰），而 elapsed 还没到 B 的 startTime。
        XCTAssertEqual(timeline.selectedLines.map(\.index), [1])

        for step in stride(from: 11 - lead + 0.02, to: 11.0, by: 0.05) {
            elapsed = step
            timeline.update()
            XCTAssertEqual(timeline.selectedLines.map(\.index), [1],
                           "t=\(step) 不该被认成倒带重排")
            XCTAssertTrue(visual.scrollTargetLineView(at: step) === viewB,
                          "t=\(step) 焦点位不该被拽回上一句")
        }
    }

    /// 提前滚动的下一句随滚动亮起浅色遮罩（isSelected == true）且去模糊；
    /// 暂停恢复与松手这两条回填模糊的路径也不许把它糊回去。
    func testPreScrolledLineLightsUpWithScrollAndStaysUnblurred() throws {
        var elapsed: TimeInterval = 0
        let (controller, visual, timeline) = makeScrubFixture { elapsed }
        controller.setLyrics(Self.makeTextLyrics([(0, 8), (11, 16), (16, 20)]))
        let lead = visual.scrollLead
        let viewB = visual.lineViews[1], viewC = visual.lineViews[2]

        elapsed = 4
        timeline.resync(at: elapsed)
        elapsed = 11 - lead + 0.01
        timeline.update()

        XCTAssertTrue(visual.selectedLineViews.contains { $0 === viewB }, "B 已提前就位")
        XCTAssertEqual(viewB.lineLayer?.blurRadius, 0, "提前就位的 B 是清晰的，可以预读")
        XCTAssertTrue(viewB.lineLayer?.isSelected == true, "随着滚动起跑，浅色遮罩同步亮起")

        visual.followScrollTarget(at: elapsed)
        XCTAssertTrue(visual.scrollTargetView === viewB, "焦点位已经在 B 上")

        let unblurred = visual.unblurredLineViewIDs
        XCTAssertTrue(unblurred.contains(ObjectIdentifier(viewB)), "提前就位的 B 留在清晰那一组")
        XCTAssertFalse(unblurred.contains(ObjectIdentifier(viewC)), "还没入列的 C 不在清晰那一组")

        // 松手回填模糊。
        visual.mode = .scroll
        visual.endScrollingAppearance()
        XCTAssertEqual(viewB.lineLayer?.blurRadius, 0, "松手不许把提前就位的 B 糊回去")
        XCTAssertEqual(viewC.lineLayer?.blurRadius,
                       SyncedLyricsVisualExperienceManager.deselectedBlurRadius)

        // 暂停 → 恢复播放：同一条判据。
        visual.mode = .regular
        let timing = StubTimingProvider()
        visual.timingProvider = timing
        timing.isPaused = true
        visual.syncBlurToPlaybackState()
        timing.isPaused = false
        visual.syncBlurToPlaybackState()
        XCTAssertEqual(viewB.lineLayer?.blurRadius, 0, "恢复播放也不许把 B 糊回去")
        XCTAssertEqual(viewC.lineLayer?.blurRadius,
                       SyncedLyricsVisualExperienceManager.deselectedBlurRadius)

        // 开唱那一刻保持亮起。
        elapsed = 11.0
        timeline.update()
        visual.activateDueLines(at: elapsed)
        XCTAssertTrue(viewB.lineLayer?.isSelected == true, "开唱保持亮起")
    }

    /// 当上一句仍在唱（空档窄）且下一句提前准入时：准入时刻因上一句未唱完尚不起跑，下一句仅去模糊、暂不选中；
    /// 当上一句唱完（handover时刻到达）并触发 followScrollTarget 起跑时，下一句随着滚动同步激活选中（浅色遮罩亮起）。
    func testLineLightsUpWhenHandoverScrollStarts() throws {
        var elapsed: TimeInterval = 0
        let (controller, visual, timeline) = makeScrubFixture { elapsed }
        // A 唱到 10，B 在 10.5 开唱（空档 0.5s < lead）
        controller.setLyrics(Self.makeTextLyrics([(0, 10), (10.5, 15)]))
        let viewA = visual.lineViews[0], viewB = visual.lineViews[1]

        elapsed = 5
        timeline.resync(at: elapsed)
        XCTAssertTrue(viewA.lineLayer?.isSelected == true)

        // 9.8s：已进入 10.5 - lead 的准入窗口，但 A 仍在唱（endTime=10.0，switchAt=10.0）
        elapsed = 9.8
        timeline.update()
        XCTAssertTrue(visual.selectedLineViews.contains { $0 === viewB }, "B 已准入")
        XCTAssertEqual(viewB.lineLayer?.blurRadius, 0, "B 预读去模糊")
        XCTAssertFalse(viewB.lineLayer?.isSelected == true, "A 仍在唱，尚未起跑，B 暂不亮浅色遮罩")

        // 10.0s：A 唱完，handover 到达，followScrollTarget 起跑
        elapsed = 10.0
        timeline.update()
        visual.followScrollTarget(at: elapsed)
        XCTAssertTrue(visual.scrollTargetView === viewB, "焦点位切到 B")
        XCTAssertTrue(viewB.lineLayer?.isSelected == true, "随着滚动起跑，B 的浅色遮罩同步亮起")
    }

    /// 正跑着的滚动弹簧目标没变就不重启（句间准入一次、淘汰一次连着两回滚向同一处）。
    func testScrollToSameTargetKeepsRunningSpring() throws {
        let (controller, _) = makeExpansionFixture(instrumentalAt: 5)
        let spring = controller.specs.lineChangeSpringTimingParameters
        controller.scroll(to: CGPoint(x: 0, y: 300), spring: spring, delay: 0)
        let first = try XCTUnwrap(controller.scrollSpring)
        controller.scroll(to: CGPoint(x: 0, y: 300.4), spring: spring, delay: 0)
        XCTAssertEqual(controller.scrollSpring?.startTime, first.startTime, "同一目标：沿用在跑的那条")
        controller.scroll(to: CGPoint(x: 0, y: 500), spring: spring, delay: 0)
        XCTAssertEqual(controller.scrollSpring?.to, 500, "目标换了才重起")
    }

    private static func makeTextLyrics(_ spans: [(TimeInterval, TimeInterval)]) -> Lyrics {
        var lyrics = Lyrics()
        lyrics.lines = spans.enumerated().map { index, span in
            var line = TextLine()
            line.index = index
            line.startTime = span.0
            line.endTime = span.1
            line.text = "第\(index)句"
            return line
        }
        return lyrics
    }

    /// 提前 0.5s 准入的行在开唱前（elapsed < startTime）不高亮，
    /// 等到到达开唱时刻（elapsed >= startTime）才激活高亮。
    func testUpcomingLineIsNotHighlightedUntilStartTime() throws {
        var currentElapsed: TimeInterval = 9.6
        let (controller, visual, _) = makeScrubFixture { currentElapsed }

        var lines: [any LyricsLine] = []
        var line0 = TextLine()
        line0.index = 0
        line0.startTime = 0
        line0.endTime = 10
        line0.text = "第一句"
        lines.append(line0)

        var line1 = TextLine()
        line1.index = 1
        line1.startTime = 10
        line1.endTime = 15
        line1.text = "第二句"
        lines.append(line1)

        var lyrics = Lyrics()
        lyrics.lines = lines
        controller.setLyrics(lyrics)

        // 模拟 9.6s（距离第二句开唱还有 0.4s，已进入提前准入窗口）
        currentElapsed = 9.6
        visual.selectLine(line1, animation: nil, deselectingOthers: false, updatesInstrumentalTime: false)

        let targetView = visual.lineViews[1]
        XCTAssertTrue(visual.selectedLineViews.contains { $0 === targetView }, "已加入选中行集合以触发滚动")
        XCTAssertFalse(targetView.lineLayer?.isSelected == true, "未到开唱时刻不得激活高亮")
        XCTAssertEqual(targetView.lineLayer?.blurRadius, 0, "提前就位时应当清除模糊，保持清晰可读")

        // 推进到 10.0s（开唱时刻）
        currentElapsed = 10.0
        visual.activateDueLines(at: 10.0)
        XCTAssertTrue(targetView.lineLayer?.isSelected == true, "到达开唱时刻应当激活高亮")
    }

    // MARK: - §3.2 / §3.3 间奏

    /// 两个时长全部由这一行的时长推出来，`LyricsSpecs` 里没有它们。
    func testInstrumentalDurationsAreDerivedFromLine() {
        let layer = InstrumentalContentLayer()
        var line = InstrumentalLine()
        line.startTime = 0
        line.endTime = 21.8            // end' = 20，span = 20
        layer.line = line
        layer.makeDots()
        layer.reset()

        // breathDuration = span / floor(span / 4) / 2 = 20 / 5 / 2
        XCTAssertEqual(layer.breathDuration, 2, accuracy: 1e-9)
        // dotFadeInDuration = (end' − start − 1.0) / dotCount = 19 / 3
        XCTAssertEqual(layer.dotFadeInDuration, 19.0 / 3.0, accuracy: 1e-9)
    }

    /// `span < 4` 时`floor` 得 0，原版没有防护，`breathDuration` 变成 +inf，
    /// 呼吸这一档直接失效。照抄不补——这条测试是为了让「它确实是无穷」有据可查。
    func testInstrumentalShortBreakLeavesBreathDurationInfinite() {
        let layer = InstrumentalContentLayer()
        var line = InstrumentalLine()
        line.startTime = 0
        line.endTime = 4.8             // end' = 3，span = 3 < 4
        layer.line = line
        layer.makeDots()
        layer.reset()
        XCTAssertTrue(layer.breathDuration.isInfinite)
    }

    /// 倒带：应亮的点数比已亮的少 → 整体复位。这是唯一的回退路径。
    func testInstrumentalRewindResets() {
        let layer = InstrumentalContentLayer()
        var line = InstrumentalLine()
        line.startTime = 0
        line.endTime = 21.8
        layer.line = line
        layer.makeDots()
        layer.reset()
        layer.setSelected(true, animated: false)

        _ = layer.prepare(at: 14)                      // 先走独立的摆点入口
        CATransaction.flush()

        let preparationDeadline = Date().addingTimeInterval(1.5)
        while layer.totalDotsFadedIn != layer.specs.instrumentalBreakCountdownDotCount,
              preparationDeadline.timeIntervalSinceNow > 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(layer.totalDotsFadedIn,
                       layer.specs.instrumentalBreakCountdownDotCount)

        _ = layer.update(elapsed: 14)                  // 三个点该全亮了
        XCTAssertGreaterThan(layer.totalDotsCompleted, 1)
        let actions = layer.update(elapsed: 0.5)       // 拖回第一个点之前
        XCTAssertEqual(actions.first, .reset)
        XCTAssertTrue(actions.contains { action in
            if case .prepareDots(activeCount: 0, curve: _, stagger: _, delay: _) = action { return true }
            return false
        })
        XCTAssertEqual(layer.totalDotsCompleted, 0)
    }

    /// 独立的摆点入口：未到第一个点时间时，三个点都以 10% 亮度进入；
    /// 入场时长 0.8 秒、错开 0.06 秒，并同时起第一拍 1.2 倍呼吸。
    ///
    /// 入场还要**等行开始后 1.0s**（`firstDotDelay`）才起跑——[PX] Music 实测点是在
    /// 撑开完全落定之后才浮出来的，不是跟着撑开一起出现。
    func testInstrumentalInitialAppearanceMatchesAssembly() {
        let layer = InstrumentalContentLayer()
        var line = InstrumentalLine()
        line.startTime = 10
        line.endTime = 31.8
        layer.line = line
        layer.makeDots()
        layer.reset()

        let actions = layer.prepareActions(at: 10)
        XCTAssertTrue(actions.contains(
            .prepareDots(activeCount: 0,
                         curve: .linear(InstrumentalContentLayer.initialDotAnimationDuration),
                         stagger: InstrumentalContentLayer.initialDotStagger,
                         delay: InstrumentalContentLayer.firstDotDelay)),
                      "行刚开始 ⇒ 入场要等满 1.0s")

        // 中途 seek 进间奏：已经越过那一刻，立刻摆点，不再等。
        layer.reset()
        let late = layer.prepareActions(at: 12)
        XCTAssertTrue(late.contains { action in
            if case .prepareDots(_, _, _, let delay) = action { return delay == 0 }
            return false
        }, "seek 进间奏中段不该再等 1 秒")
        XCTAssertTrue(actions.contains(
            .breathe(curve: .easeOut(layer.breathDuration
                                     - InstrumentalContentLayer.breathAnimationTrim),
                     delay: InstrumentalContentLayer.breathAnimationDelay,
                     scale: InstrumentalContentLayer.breathScaleRange.upperBound)))
        // 「显示」与「填充」是两件事（§13.10）：没填充的点也要看得见（0.1），
        // 否则整排全透明，点会从看不见的地方一个个冒出来，和 Music 对不上。
        XCTAssertEqual(InstrumentalContentLayer.dotUnfilledOpacity, 0.1)
        XCTAssertEqual(InstrumentalContentLayer.dotFilledOpacity, 1)

        // 初次摆点的三个完成回调还没齐时，逐点填充必须关着；否则第一个点会
        // 在 0.8 秒入场动画中途抢亮。
        XCTAssertFalse(layer.update(elapsed: 10.5).contains { action in
            if case .fadeInDots = action { return true }
            return false
        })
    }

    /// 半周期奇数去 1.2、偶数回 0.9。此前实现取了更新后的计数再判偶，方向正好反了。
    func testInstrumentalBreathAlternatesFromExpandedToContracted() {
        let layer = InstrumentalContentLayer()
        var line = InstrumentalLine()
        line.startTime = 0
        line.endTime = 21.8
        layer.line = line
        layer.makeDots()
        layer.reset()
        _ = layer.prepareActions(at: 0) // 第一拍已经去 1.2，计数 = 1

        let actions = layer.update(elapsed: layer.breathDuration + 0.01)
        XCTAssertTrue(actions.contains { action in
            if case .breathe(curve: _, delay: _, scale: let scale) = action {
                return scale == InstrumentalContentLayer.breathScaleRange.lowerBound
            }
            return false
        })
    }

    /// 退出不是单纯淡透明：先放大，随后淡出并缩到 0.2。
    func testInstrumentalFadeOutStages() {
        XCTAssertEqual(InstrumentalContentLayer.fadeOutCurves.count, 3)
        XCTAssertEqual(InstrumentalContentLayer.fadeOutCurves[0].delay, 0)
        XCTAssertEqual(InstrumentalContentLayer.fadeOutCurves[1].delay, 1)
        XCTAssertEqual(InstrumentalContentLayer.fadeOutCurves[2].delay, 1)
        XCTAssertEqual(InstrumentalContentLayer.fadeOutScale, 0.2)
    }

    /// 淡出只发一次，窗口是最后 1.8 秒。
    func testInstrumentalFadeOutIsCuedOnce() {
        let layer = InstrumentalContentLayer()
        var line = InstrumentalLine()
        line.startTime = 0
        line.endTime = 21.8
        layer.line = line
        layer.makeDots()
        layer.reset()

        XCTAssertFalse(layer.update(elapsed: 19).contains(.cueFadeOut))   // 还没进窗口
        XCTAssertTrue(layer.update(elapsed: 21).contains(.cueFadeOut))
        XCTAssertFalse(layer.update(elapsed: 21.5).contains(.cueFadeOut))
    }

    /// 整排宽度 = n·length + (n−1)·margin，基线 3·12 + 2·8 = 52。[实测]
    func testInstrumentalDotsWidth() {
        let layer = InstrumentalContentLayer()
        layer.specs = specs()
        XCTAssertEqual(layer.dotsWidth, 52)
    }

    /// §15.5 `alignment` 的写入器：值没变直接早退，什么都不做；变了才「没点就建点」
    /// 再重排。**三个点是在这一次赋值时出现的，不在 init 里**。
    func testInstrumentalDotsAreCreatedByAlignmentWriter() {
        let layer = InstrumentalContentLayer()
        layer.specs = specs()
        XCTAssertTrue(layer.dots.isEmpty)

        // 值没变（默认就是 .natural）→ 早退，不建点。
        layer.alignment = .natural
        XCTAssertTrue(layer.dots.isEmpty)

        // 值变了 → 建点。
        layer.alignment = .center
        XCTAssertEqual(layer.dots.count, 3)

        // 再赋同一个值不重建（对象身份不变）。
        let identities = layer.dots.map(ObjectIdentifier.init)
        layer.alignment = .center
        XCTAssertEqual(layer.dots.map(ObjectIdentifier.init), identities)
    }

    /// §13.6 的三值分支：1 居中、2 右，其余靠左。整排宽 52。
    func testInstrumentalDotOriginsFollowAlignment() {
        let layer = InstrumentalContentLayer()
        layer.specs = specs()
        layer.alignment = .center           // 顺带把点建出来
        layer.bounds = CGRect(x: 0, y: 0, width: 200, height: 40)

        XCTAssertEqual(layer.dotOrigins(inWidth: 200, height: 40).map(\.x),
                       [74, 94, 114])       // (200 − 52) / 2 = 74，步长 20
        layer.alignment = .right
        XCTAssertEqual(layer.dotOrigins(inWidth: 200, height: 40).map(\.x),
                       [148, 168, 188])     // 200 − 52 = 148
        layer.alignment = .natural
        XCTAssertEqual(layer.dotOrigins(inWidth: 200, height: 40).map(\.x),
                       [0, 20, 40])
        // y 恒是垂直居中：(40 − 12) / 2 = 14
        XCTAssertEqual(layer.dotOrigins(inWidth: 200, height: 40).map(\.y), [14, 14, 14])
    }

    /// 行自带的书写方向决定三点靠哪一边，不是全局设置。
    func testInstrumentalAlignmentComesFromLineDirection() {
        XCTAssertEqual(InstrumentalContentLayer.dotAlignment(for: .leftToRight), .natural)
        XCTAssertEqual(InstrumentalContentLayer.dotAlignment(for: .rightToLeft), .right)
    }

    /// §15.3 第一支：`renderingMode == .static`（侧栏）根本不建间奏层，内容层置空。
    func testStaticModeHasNoInstrumentalLayer() {
        var staticSpecs = specs()
        staticSpecs.renderingMode = .static
        var line = InstrumentalLine()
        line.endTime = 20

        let lineLayer = SyncedLyricsLineLayer()
        lineLayer.configure(line: line, specs: staticSpecs, appearance: nil)
        XCTAssertNil(lineLayer.contentLayer)

        // 同步模式下照常建。
        lineLayer.configure(line: line, specs: specs(), appearance: nil)
        XCTAssertTrue(lineLayer.contentLayer is InstrumentalContentLayer)
    }

    /// §15.3 第二支：行视图复用时**就地复用**已有的间奏层，点不重建——重建会闪一下。
    func testInstrumentalLayerIsReusedWithoutRebuildingDots() throws {
        let lineLayer = SyncedLyricsLineLayer()
        var line = InstrumentalLine()
        line.endTime = 20
        lineLayer.configure(line: line, specs: specs(), appearance: nil)

        let first = try XCTUnwrap(lineLayer.contentLayer as? InstrumentalContentLayer)
        XCTAssertEqual(first.dots.count, 3)
        let identities = first.dots.map(ObjectIdentifier.init)
        first.setSelected(true, animated: false)

        var next = InstrumentalLine()
        next.index = 4
        next.startTime = 30
        next.endTime = 50
        lineLayer.configure(line: next, specs: specs(), appearance: nil)

        let reused = try XCTUnwrap(lineLayer.contentLayer as? InstrumentalContentLayer)
        XCTAssertTrue(reused === first)                                  // 同一个层
        XCTAssertEqual(reused.dots.map(ObjectIdentifier.init), identities)  // 同一批点
        XCTAssertFalse(reused.isSelected)                                // 回填后复位
        XCTAssertNil(reused.currentElapsedTime)
        XCTAssertNil(reused.totalDotsFadedIn)
        XCTAssertEqual(reused.line?.startTime, 30)
    }

    /// §9 收起间奏行：逐行错开量是**线性累加**的 `序号 × 0.05`，不是固定错开。
    func testInstrumentalDismissStaggersLinesLinearly() throws {
        let controller = SyncedLyricsViewController()
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 260)
        controller.view.layoutSubtreeIfNeeded()

        let visual = SyncedLyricsVisualExperienceManager()
        visual.viewController = controller
        visual.specs = controller.specs
        controller.manager = visual

        var lines: [any LyricsLine] = []
        for index in 0..<6 {
            var text = TextLine()
            text.index = index
            text.startTime = Double(index) * 10
            text.endTime = text.startTime + 5
            text.text = "第\(index)行歌词"
            lines.append(text)
        }
        var lyrics = Lyrics()
        lyrics.lines = lines
        controller.setLyrics(lyrics)

        // 让每一行都要移动：整体往下挪一格，重排就得把它们收回去。
        for view in visual.lineViews { view.frame.origin.y += 30 }

        controller.currentAnimators = []
        controller.relayout(affected: visual.lineViews,
                            animation: .init(spring: controller.specs.lineChangeSpringTimingParameters),
                            animated: true,
                            stagger: .linear(controller.specs.lineDelay))

        let delays = controller.currentAnimators.map(\.delay)
        XCTAssertGreaterThan(delays.count, 1)
        for (ordinal, delay) in delays.enumerated() {
            XCTAssertEqual(delay, Double(ordinal) * 0.05, accuracy: 1e-9)
        }
    }

    /// §8 的死区：小于 1pt 的滚动直接不动，免得间奏进出时抖。
    func testScrollDeadZoneSwallowsSubPointMoves() {
        let controller = SyncedLyricsViewController()
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 260)
        controller.view.layoutSubtreeIfNeeded()
        let base = controller.scrollView?.contentView.bounds.origin.y ?? 0

        let spring = controller.specs.lineChangeSpringTimingParameters
        controller.scroll(to: CGPoint(x: 0, y: base + 0.6), spring: spring, delay: 0)
        XCTAssertNil(controller.scrollSpring)

        controller.scroll(to: CGPoint(x: 0, y: base + 1.4), spring: spring, delay: 0)
        XCTAssertNotNil(controller.scrollSpring)
    }

    /// [实测] §6.1：点击驱动滚动后，`needsTapHandling` 必须立即撤旗，后续滚动恢复弹性阶梯延迟。
    func testAnimateLineScrollResetsNeedsTapHandling() {
        let controller = SyncedLyricsViewController()
        controller.loadView()
        let visual = SyncedLyricsVisualExperienceManager()
        visual.specs = controller.specs
        controller.manager = visual

        var line0 = TextLine()
        line0.index = 0
        line0.startTime = 0
        line0.endTime = 5
        line0.text = "Line 0"

        var line1 = TextLine()
        line1.index = 1
        line1.startTime = 5
        line1.endTime = 10
        line1.text = "Line 1"

        var lyrics = Lyrics()
        lyrics.lines = [line0, line1]
        controller.setLyrics(lyrics)
        visual.needsTapHandling = true

        controller.animateLineScroll(to: CGPoint(x: 0, y: 100),
                                      anchorLine: line1,
                                      spring: controller.specs.lineChangeSpringTimingParameters)

        XCTAssertFalse(visual.needsTapHandling, "needsTapHandling must be cleared after line scroll")
    }

    /// 呼吸会让两侧圆点探出行宽，但**不为此留内边距**：[PX] Music 的首个点静止
    /// 左沿就压在歌词左沿上。留了 padding 三个点会整体右缩十来 pt。
    func testInstrumentalDotsDoNotReserveBreathingOverflow() throws {
        let layer = InstrumentalContentLayer()
        layer.specs = specs()
        layer.makeDots()
        layer.setSelected(true, animated: false)
        let size = layer.sizeThatFits(width: 300)
        XCTAssertEqual(size.width, 52)

        layer.bounds = CGRect(origin: .zero, size: size)
        layer.layoutSublayers()
        XCTAssertEqual(try XCTUnwrap(layer.dots.first).frame.minX, 0, accuracy: 1e-9)
    }

    /// 间奏展开会移动它后面的所有歌词，不只是当前可见的几行。屏外 frame 若仍是
    /// 旧值，滚过去就会出现大空档，开头是间奏时尤其明显。
    func testInstrumentalRelayoutCommitsOffscreenLineFrames() throws {
        let controller = SyncedLyricsViewController()
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 260)
        controller.view.layoutSubtreeIfNeeded()

        let visual = SyncedLyricsVisualExperienceManager()
        visual.viewController = controller
        visual.specs = controller.specs
        controller.manager = visual

        var instrumental = InstrumentalLine()
        instrumental.index = 0
        instrumental.startTime = 0
        instrumental.endTime = 10
        var lines: [any LyricsLine] = [instrumental]
        for index in 1...8 {
            var text = TextLine()
            text.index = index
            text.startTime = Double(index * 10)
            text.endTime = text.startTime + 5
            text.text = "第\(index)行歌词"
            lines.append(text)
        }
        var lyrics = Lyrics()
        lyrics.lines = lines
        controller.setLyrics(lyrics)

        let dots = try XCTUnwrap(
            visual.lineViews.first?.lineLayer?.contentLayer as? InstrumentalContentLayer)
        let oldLastFrame = try XCTUnwrap(visual.lineViews.last?.frame)
        dots.setSelected(true, animated: false)
        // 行高的闸是 `instrumentalBreakVisibleView`（§16.1），不是内容层的 isSelected。
        visual.instrumentalBreakVisibleView = visual.lineViews.first
        controller.relayout(
            affected: [try XCTUnwrap(visual.lineViews.first)],
            animation: .init(spring: controller.specs.lineChangeSpringTimingParameters),
            animated: false)

        XCTAssertNotEqual(visual.lineViews.last?.frame, oldLastFrame)
        for (index, view) in visual.lineViews.enumerated() {
            XCTAssertEqual(view.frame, controller.lineFrames[index])
        }
    }

    // MARK: - 批次 16 / 17：间奏「上下展开」

    /// 一条间奏 + 若干文本行的行流。间奏落在 `instrumentalIndex`。
    private func makeExpansionFixture(instrumentalAt instrumentalIndex: Int,
                                      lineCount: Int = 9)
        -> (SyncedLyricsViewController, SyncedLyricsVisualExperienceManager) {
        let controller = SyncedLyricsViewController()
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 260)
        controller.view.layoutSubtreeIfNeeded()

        let visual = SyncedLyricsVisualExperienceManager()
        visual.viewController = controller
        visual.specs = controller.specs
        controller.manager = visual

        var lines: [any LyricsLine] = []
        for index in 0..<lineCount {
            let start = Double(index) * 10
            if index == instrumentalIndex {
                var instrumental = InstrumentalLine()
                instrumental.index = index
                instrumental.startTime = start
                instrumental.endTime = start + 10
                lines.append(instrumental)
            } else {
                var text = TextLine()
                text.index = index
                text.startTime = start
                text.endTime = start + 5
                text.text = "第\(index)行歌词"
                lines.append(text)
            }
        }
        var lyrics = Lyrics()
        lyrics.lines = lines
        controller.setLyrics(lyrics)
        return (controller, visual)
    }

    /// §16.1：间奏行的行高是**条件值**，闸是 `instrumentalBreakVisibleView` 指着谁，
    /// 不是内容层自己的 `isSelected`——「同一时刻至多一行撑开」这条不变量由此而来。
    func testInstrumentalRowHeightIsConditional() throws {
        let (controller, visual) = makeExpansionFixture(instrumentalAt: 2)
        let line = try XCTUnwrap(controller.lyrics?.lines[2])

        XCTAssertEqual(controller.lineHeight(for: line, measured: 40), 0, "没打开 ⇒ 0")
        visual.instrumentalBreakVisibleView = visual.lineViews[0]
        XCTAssertEqual(controller.lineHeight(for: line, measured: 40), 0, "打开的是别人 ⇒ 0")

        visual.instrumentalBreakVisibleView = visual.lineViews[2]
        XCTAssertEqual(controller.lineHeight(for: line, measured: 0),
                       controller.specs.instrumentalBreakViewHeight,
                       "打开的就是它 ⇒ 40，且不看 measured")

        // 侧栏那一档（`.static`）恒 0：的第一道闸。
        controller.specs.renderingMode = .static
        XCTAssertEqual(controller.lineHeight(for: line, measured: 40), 0)

        // 普通行不吃这套，照样用测出来的高度。
        controller.specs.renderingMode = .synced
        let text = try XCTUnwrap(controller.lyrics?.lines[3])
        XCTAssertEqual(controller.lineHeight(for: text, measured: 37), 37)
    }

    /// §16.1 + §16.2：打开那一刻，间奏行之后的每一行整体下移 `40 + 25 = 65`；
    /// 它之前的行一动不动，它自己的落点也不变——变的只有高度。
    func testOpeningInstrumentalPushesFollowingLinesByOneSlot() throws {
        let (controller, visual) = makeExpansionFixture(instrumentalAt: 2)
        let before = visual.lineViews.map(\.frame)
        XCTAssertEqual(before[2].height, 0, "收起态既不占高度")
        XCTAssertEqual(before[3].minY, before[2].maxY, "也不占行距")

        visual.instrumentalBreakVisibleView = visual.lineViews[2]
        controller.recomputeLineFrames()

        let slot = controller.specs.instrumentalBreakViewHeight + controller.specs.lineSpacing
        XCTAssertEqual(slot, 65)
        for (index, frame) in controller.lineFrames.enumerated() {
            switch index {
            case ..<2:
                XCTAssertEqual(frame.minY, before[index].minY, accuracy: 1e-9, "上方不动")
            case 2:
                XCTAssertEqual(frame.minY, before[2].minY, accuracy: 1e-9, "间奏行自己的落点不变")
                XCTAssertEqual(frame.height, 40, accuracy: 1e-9)
            default:
                XCTAssertEqual(frame.minY, before[index].minY + slot, accuracy: 1e-9,
                               "第 \(index) 行该下移一格")
            }
        }
    }

    /// §16.4 / §17.1：受影响的行是围绕目标行的**一段连续行**，两趟都「首次不相交即停」，
    /// 返回前按下标升序排序；并集含「滚动后」的视口，所以 `delta` 越大收得越多。
    func testAffectedLinesAreAContiguousSortedRun() throws {
        let (controller, visual) = makeExpansionFixture(instrumentalAt: 2, lineCount: 24)
        let indices = { (views: [SyncedLyricsLineView]) -> [Int] in
            views.map { view in visual.lineViews.firstIndex { $0 === view } ?? -1 }
        }

        let near = indices(controller.affectedLineViews(aroundLineAt: 2, deltaY: 0))
        XCTAssertFalse(near.isEmpty)
        XCTAssertEqual(near, near.sorted(), "要按下标升序——它决定逐行错开的顺序")
        XCTAssertEqual(near, Array(near[0]...near[near.count - 1]), "必须是连续的一段")
        XCTAssertTrue(near.contains(2), "目标行自己在集合里（0 高也要收进来）")
        XCTAssertLessThan(near.count, visual.lineViews.count, "不是全表")

        // 视口向下滚 400pt：并集把「滚动后才露出来」的那几行也算进来。
        let far = indices(controller.affectedLineViews(aroundLineAt: 2, deltaY: 400))
        XCTAssertEqual(far, far.sorted())
        XCTAssertGreaterThan(far.count, near.count)
        XCTAssertEqual(far.last! > near.last!, true, "并集往下延伸")
    }

    /// §16.5 的 `delta`：只有主项与死区。
    ///
    /// [PX] 那条 `(新高 − 旧高) × 0.5` 的修正项实测不成立（见
    /// `instrumentalOpenDelta(for:)` 的注释）：整窗是居中版式，加上它 delta 会超过
    /// 撑开量，间奏行下方的行就跟着上移，而 Music 是**被往下推一点**。
    func testInstrumentalOpenDeltaIsPlainDifferenceWithDeadZone() throws {
        let controller = SyncedLyricsViewController()
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 260)
        controller.view.layoutSubtreeIfNeeded()
        let base = try XCTUnwrap(controller.scrollView?.contentView).bounds.origin.y

        let row = SyncedLyricsLineView()
        row.frame = CGRect(x: 0, y: base, width: 300, height: 0)      // 收起态：0 高
        XCTAssertEqual(controller.instrumentalOpenDelta(for: row), 0, "已经到位")

        row.frame.origin.y = base + 0.6
        XCTAssertEqual(controller.instrumentalOpenDelta(for: row), 0, "0.6pt 落进死区")

        row.frame.origin.y = base + 20
        XCTAssertEqual(controller.instrumentalOpenDelta(for: row), 20, accuracy: 1e-9)

        // 居中版式（整窗那档）**也不补**半个高度差：delta 就是目标 origin 与当前之差。
        controller.specs.selectedLinePosition = .center(rect: nil)
        let centered = controller.scrollOrigin(forLineFrame: row.frame).y - base
        XCTAssertEqual(controller.instrumentalOpenDelta(for: row), centered, accuracy: 1e-9)
    }

    /// 整窗那档（居中版式、行距 48、间奏行 40）：`delta` 必须**小于**撑开量，
    /// 否则间奏行下方的行会跟着上移，而不是被往下推一点。
    ///
    /// [PX] Music 实测 delta ≈ 上一句行盒/2 + 行距，撑开量 = 间奏行高 + 行距。
    func testFullWindowInstrumentalPushesFollowingLinesDown() throws {
        let (controller, visual) = makeExpansionFixture(instrumentalAt: 6, lineCount: 12)
        // 整窗覆盖项：居中版式 + 行距 48（见 SyncedLyricsView.makeSpecs）
        controller.specs.lineSpacing = 48
        controller.specs.selectedLinePosition =
            .center(rect: CGRect(x: 0, y: 0, width: 683, height: 700))
        visual.specs = controller.specs
        controller.recomputeLineFrames()
        for (i, view) in visual.lineViews.enumerated() { view.frame = controller.lineFrames[i] }

        // 上一句停在它的目标位置上（这才是「换行前」的常态）。
        let previousRow = visual.lineViews[5]
        controller.setScrollOrigin(controller.scrollOrigin(forLineFrame: previousRow.frame))

        let slot = controller.specs.instrumentalBreakViewHeight + controller.specs.lineSpacing
        let delta = controller.instrumentalOpenDelta(for: visual.lineViews[6])
        XCTAssertGreaterThan(delta, 0, "间奏行在下方，视口要往下走")
        XCTAssertLessThan(delta, slot,
                          "delta 必须小于撑开量，下方的行才是被推开（\(slot) − \(delta)）")
        // 上方上移 delta、下方下移 slot − delta，两侧不相等。
        XCTAssertEqual(delta, previousRow.frame.height / 2 + controller.specs.lineSpacing,
                       accuracy: 0.5, "delta = 上一句行盒/2 + 行距")
    }

    /// §17.1：展开的逐行错开是 `lineDelay × (max(i,1) − 1)`——**前两行共享 delay 0**；
    /// 收起那条（§3.5）是线性累加。两条公式不能混用。
    func testLineStaggerFormulas() {
        let expand = LineStagger.sharedFirstPair(0.05)
        XCTAssertEqual(expand.delay(movedOrdinal: 0, affectedOrdinal: 0), 0)
        XCTAssertEqual(expand.delay(movedOrdinal: 0, affectedOrdinal: 1), 0)
        XCTAssertEqual(expand.delay(movedOrdinal: 0, affectedOrdinal: 2), 0.05, accuracy: 1e-9)
        XCTAssertEqual(expand.delay(movedOrdinal: 0, affectedOrdinal: 5), 0.20, accuracy: 1e-9)

        let dismiss = LineStagger.linear(0.05)
        XCTAssertEqual(dismiss.delay(movedOrdinal: 0, affectedOrdinal: 9), 0)
        XCTAssertEqual(dismiss.delay(movedOrdinal: 3, affectedOrdinal: 0), 0.15, accuracy: 1e-9)

        XCTAssertEqual(LineStagger.none.delay(movedOrdinal: 4, affectedOrdinal: 4), 0)
        XCTAssertFalse(LineStagger.none.isStaggered)
        XCTAssertTrue(expand.isStaggered)
    }

    /// §16.6：轮到间奏行时，`selecting line` 在建动画**之前**同步跑掉——
    /// 颠倒的话闭包量到的高度还是 0，展开完全不发生。
    func testSelectingInstrumentalOpensRowBeforeAnimating() throws {
        let (controller, visual) = makeExpansionFixture(instrumentalAt: 2)
        let before = visual.lineViews.map(\.frame)
        let delta = controller.instrumentalOpenDelta(for: visual.lineViews[2])
        let affected = controller.affectedLineViews(aroundLineAt: 2, deltaY: delta)
        controller.currentAnimators = []

        let outcome = visual.select(try XCTUnwrap(controller.lyrics?.lines[2]))
        XCTAssertEqual(outcome, .selectedInPlace)
        XCTAssertTrue(visual.instrumentalBreakVisibleView === visual.lineViews[2])
        XCTAssertEqual(controller.lineFrames[2].height, 40, accuracy: 1e-9)
        XCTAssertEqual(controller.lineFrames[3].minY, before[3].minY + 65, accuracy: 1e-9)
        XCTAssertEqual(controller.lineFrames[1].minY, before[1].minY, accuracy: 1e-9)

        // 逐行错开：受影响的行**每一行都动**（上方 −delta、下方 +撑开量−delta），
        // delay 按它们在受影响的行里的位置算：`lineDelay × (max(i,1) − 1)`。
        let expected = affected.enumerated().map { ordinal, _ in
            controller.specs.lineDelay * Double(max(ordinal, 1) - 1)
        }
        let delays = controller.currentAnimators.map(\.delay)
        XCTAssertGreaterThan(delays.count, 1)
        XCTAssertEqual(delays.count, expected.count)
        for (delay, want) in zip(delays, expected) {
            XCTAssertEqual(delay, want, accuracy: 1e-9)
        }
    }

    /// ★ 展开的动画结构（§16.3 / §17.2 / §6.5）：**布局与视口第一帧就是真值**，
    /// 动画层只挂一条叠加偏移把「看起来还在原处」退回 0。
    ///
    /// 两条都要成立，缺一条就是屏幕上能一眼看出的 bug：
    /// - 视口**不起弹簧**（跟着滚 ⇒ 晚起跑的下方行被拖着先跟上去再回落）；
    /// - 用**叠加**偏移而不是临时坐标（用临时坐标 ⇒ 上一句被淘汰时那次 `relayout`
    ///   会把行按真值写回、而视口还没挪，上一句当场往下跳 delta，压在三个点上）。
    func testInstrumentalExpansionIsAdditiveAndSurvivesConcurrentRelayout() throws {
        let (controller, visual) = makeExpansionFixture(instrumentalAt: 6, lineCount: 12)
        let previous = try XCTUnwrap(controller.lyrics?.lines[5])
        visual.selectLine(previous, animation: nil,
                          deselectingOthers: true, updatesInstrumentalTime: false)
        controller.setScrollOrigin(controller.scrollOrigin(forLineFrame: visual.lineViews[5].frame))

        let clip = try XCTUnwrap(controller.scrollView?.contentView)
        let originBefore = clip.bounds.origin.y
        let screenBefore = visual.lineViews.map { $0.frame.minY - originBefore }
        let delta = controller.instrumentalOpenDelta(for: visual.lineViews[6])
        XCTAssertGreaterThan(delta, 0)
        let affected = controller.affectedLineViews(aroundLineAt: 6, deltaY: delta)
        let indices = affected.compactMap { view in visual.lineViews.firstIndex { $0 === view } }
        XCTAssertTrue(indices.contains(6))
        XCTAssertTrue(indices.contains(where: { $0 > 6 }), "下方要有行参与")

        controller.scrollSpring = nil
        visual.select(try XCTUnwrap(controller.lyrics?.lines[6]))

        // 一、视口不起弹簧，而是一次到位 += delta。
        XCTAssertNil(controller.scrollSpring, "视口不参与插值")
        XCTAssertEqual(clip.bounds.origin.y, originBefore + delta, accuracy: 1e-9)

        // 二、模型值就是真实布局——所以并发重排写的是同一份值。
        for (index, view) in visual.lineViews.enumerated() {
            XCTAssertEqual(view.frame, controller.lineFrames[index], "第 \(index) 行不是真值")
        }

        // 三、叠加偏移：上方 +delta（上移），下方 −(撑开量 − delta)（下移）。
        let slot = controller.specs.instrumentalBreakViewHeight + controller.specs.lineSpacing
        for index in indices {
            let layer = try XCTUnwrap(visual.lineViews[index].layer)
            let anim = try XCTUnwrap(layer.animation(forKey: "position") as? CABasicAnimation,
                                     "第 \(index) 行没挂动画")
            XCTAssertTrue(anim.isAdditive, "必须是叠加式，否则并发重排会打架")
            let offset = try XCTUnwrap(anim.fromValue as? NSValue).pointValue
            XCTAssertEqual(try XCTUnwrap(anim.toValue as? NSValue).pointValue, .zero)
            if index <= 6 {
                XCTAssertEqual(offset.y, delta, accuracy: 1e-9, "上方上移 delta")
            } else {
                XCTAssertEqual(offset.y, -(slot - delta), accuracy: 1e-9,
                               "下方下移 撑开量 − delta")
            }
            // 动画起点 = 模型值 + 偏移 ⇒ 这一帧屏幕上一动不动。
            XCTAssertEqual(visual.lineViews[index].frame.minY + offset.y - clip.bounds.origin.y,
                           screenBefore[index], accuracy: 1e-9)
        }

        // 四、上一句被时间轴淘汰（`deselectLine → relayout` 会重算并立即提交全部行）
        //     ——这条路正是截图里那个 bug 的触发点：行一格都不许动，视口也不许动。
        let frames = visual.lineViews.map(\.frame)
        visual.deselectLine(previous)
        XCTAssertEqual(visual.lineViews.map(\.frame), frames, "并发重排把行挪动了")
        XCTAssertEqual(clip.bounds.origin.y, originBefore + delta, accuracy: 1e-9,
                       "视口被拉回上一句了")
    }

    // MARK: - 拖进度条穿过间奏

    /// 搭一套「控制器 + 视觉管理器 + 时间轴」，行是 文本/间奏 交替。
    private func makeScrubFixture(elapsed: @escaping () -> TimeInterval)
        -> (SyncedLyricsViewController, SyncedLyricsVisualExperienceManager, SyncedLyricsManager) {
        let controller = SyncedLyricsViewController()
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 260)
        controller.view.layoutSubtreeIfNeeded()

        let visual = SyncedLyricsVisualExperienceManager()
        visual.viewController = controller
        visual.specs = controller.specs
        controller.manager = visual

        let timeline = SyncedLyricsManager(configuration: .init(specs: controller.specs),
                                           maxSelectedLines: controller.specs.maxSelectedLines)
        timeline.delegate = controller
        timeline.elapsedTimeProvider = elapsed
        visual.manager = timeline

        var lines: [any LyricsLine] = []
        for index in 0..<8 {
            let start = Double(index) * 20
            if index % 2 == 1 {
                var instrumental = InstrumentalLine()
                instrumental.index = index
                instrumental.startTime = start
                instrumental.endTime = start + 20
                lines.append(instrumental)
            } else {
                var text = TextLine()
                text.index = index
                text.startTime = start
                text.endTime = start + 20
                text.text = "第\(index)行歌词"
                lines.append(text)
            }
        }
        var lyrics = Lyrics()
        lyrics.lines = lines
        controller.setLyrics(lyrics)
        return (controller, visual, timeline)
    }

    /// 模拟一帧结束时的布局提交：AppKit 的视图布局 + Core Animation 的图层布局。
    private func runLayoutPass(_ controller: SyncedLyricsViewController) {
        controller.view.layoutSubtreeIfNeeded()
        CATransaction.flush()
    }

    /// 每一行间奏的「撑开」与「点可见」必须和它自己的选中态一致。
    private func assertInstrumentalRowsConsistent(_ visual: SyncedLyricsVisualExperienceManager,
                                                  at elapsed: TimeInterval,
                                                  line: UInt = #line) {
        for (index, view) in visual.lineViews.enumerated() {
            guard let dots = view.lineLayer?.contentLayer as? InstrumentalContentLayer
            else { continue }
            let expanded = view.frame.height > 0
            XCTAssertEqual(expanded, dots.isSelected,
                           "t=\(elapsed) 第 \(index) 行：撑开=\(expanded) 选中=\(dots.isSelected)",
                           line: line)
        }
        let expanded = visual.lineViews.filter { view in
            (view.lineLayer?.contentLayer as? InstrumentalContentLayer)?.isSelected == true
        }
        XCTAssertLessThanOrEqual(expanded.count, 1,
                                 "t=\(elapsed) 同时撑开了 \(expanded.count) 段间奏",
                                 line: line)
        XCTAssertLessThanOrEqual(visual.selectedLineViews.count, 2,
                                 "t=\(elapsed) selectedLineViews=\(visual.selectedLineViews.count)",
                                 line: line)
    }

    /// 逐帧驱动：和 `displayLinkFired` 同一条路（时间轴走查 + 间奏状态机推进）。
    private func tick(_ controller: SyncedLyricsViewController) {
        controller.displayLinkFired()
        runLayoutPass(controller)
        for view in controller.manager?.lineViews ?? [] {
            view.lineLayer?.layoutIfNeeded()
            (view.lineLayer?.contentLayer as? InstrumentalContentLayer)?.layoutIfNeeded()
        }
    }

    /// 没轮到的间奏行：整层藏起来、三个点全熄。
    ///
    /// 自然播完那一路 `cueFadeOut` 会把点的模型值写成 0，看不出问题；
    /// **中途拖时间条离开间奏**走的是「取消选中 + 重排」，淡出根本没起跑——
    /// 点若不熄不藏，就会留在原地压着别的歌词，且拖过几段就留几段。
    private func assertIdleInstrumentalsAreDark(_ visual: SyncedLyricsVisualExperienceManager,
                                                at elapsed: TimeInterval,
                                                line: UInt = #line) {
        for (index, view) in visual.lineViews.enumerated() {
            guard let dots = view.lineLayer?.contentLayer as? InstrumentalContentLayer,
                  !dots.isSelected else { continue }
            XCTAssertTrue(dots.isHidden,
                          "t=\(elapsed) 第 \(index) 行：没轮到却没藏起来", line: line)
            XCTAssertEqual(view.frame.height, 0, accuracy: 1e-9,
                           "t=\(elapsed) 第 \(index) 行：没轮到却还占着高度", line: line)
            for (dot, layer) in dots.dots.enumerated() {
                XCTAssertEqual(layer.opacity, 0, accuracy: 1e-6,
                               "t=\(elapsed) 第 \(index) 行第 \(dot) 个点还亮着", line: line)
            }
        }
    }

    /// 行图层带着未选中态的 0.98 缩放，几何**不能**因此虚胖。
    ///
    /// `CALayer.frame` 的 setter 会把缩放反除进`bounds`：写`frame` 的话
    /// 0 高的间奏行会得到 `24 / 0.98 − 24 = 0.49` 的内容层高度，
    /// 「折叠了就藏起来」那道闸判不出来，三个点就永远留在屏幕上。
    func testDeselectedLineLayerGeometryIgnoresScaleTransform() throws {
        let view = SyncedLyricsLineView()
        var line = InstrumentalLine()
        line.index = 0
        line.startTime = 0
        line.endTime = 10
        view.configure(line: line, specs: specs())
        let lineLayer = try XCTUnwrap(view.lineLayer)

        lineLayer.apply(selected: true, animation: nil)
        view.frame = CGRect(x: 0, y: 0, width: 52, height: 40)
        view.layout()
        let bleed = SyncedLyricsLineLayer.filterBleed
        XCTAssertEqual(lineLayer.bounds.height, 40 + 2 * bleed, accuracy: 1e-9)

        // 取消选中会挂上 `deselectedTransform`(0.98)，行随之折叠成 0 高。
        lineLayer.apply(selected: false, animation: nil)
        view.frame = CGRect(x: 0, y: 0, width: 52, height: 0)
        view.layout()
        XCTAssertEqual(lineLayer.bounds.height, 2 * bleed, accuracy: 1e-9)
        lineLayer.layoutSublayers()
        let dots = try XCTUnwrap(lineLayer.contentLayer as? InstrumentalContentLayer)
        XCTAssertEqual(dots.bounds.height, 0, accuracy: 1e-9)
        XCTAssertTrue(dots.isHidden)
    }

    /// 拖时间条离开正在亮着的间奏：那一段必须立刻熄灭并藏起来。
    func testScrubbingAwayFromLitInstrumentalClearsDots() throws {
        var now: TimeInterval = 0
        let (controller, visual, _) = makeScrubFixture(elapsed: { now })

        // 播到第一段间奏中段：三个点已经摆上来（未到时的停在 10%）。
        // 注意逐点淡入那一档要等入场动画的完成回调，测试环境里 Core Animation
        // 不走时钟，所以这里只断言「点是看得见的」，不断言具体亮到几成。
        for t in stride(from: 0.0, through: 30.0, by: 0.25) {
            now = t
            tick(controller)
        }
        let first = try XCTUnwrap(
            visual.lineViews[1].lineLayer?.contentLayer as? InstrumentalContentLayer)
        XCTAssertTrue(first.isSelected)
        XCTAssertFalse(first.fadeOutCued, "淡出还没起跑，点是亮着的")
        XCTAssertTrue(first.dots.allSatisfy { $0.opacity > 0 },
                      "三个点应当一起浮出来")

        // 一次 seek 拖到下一段间奏中段（进度条是松手才回调，只有一跳）。
        now = 70
        tick(controller)
        assertIdleInstrumentalsAreDark(visual, at: now)
        XCTAssertFalse(first.isSelected)
        XCTAssertTrue(first.isHidden)

        // 再拖回第一段：状态机得重新摆一次点，而不是沿用上一轮的账本。
        for t in stride(from: 70.0, through: 78.0, by: 0.25) {
            now = t
            tick(controller)
        }
        now = 25
        tick(controller)
        assertIdleInstrumentalsAreDark(visual, at: now)
        XCTAssertTrue(first.isSelected)
        XCTAssertFalse(first.isHidden)
        // 拖走时被复位成全透明，拖回来必须重新摆一次点——沿用上一轮账本的话
        // `prepareActions` 会因为`totalDotsFadedIn != nil` 整个空转，点仍是 0。
        XCTAssertTrue(first.dots.allSatisfy { $0.opacity > 0 },
                      "拖回间奏后三个点应当重新浮出来")
    }

    /// 拖时间条穿过若干段间奏：任何时刻最多只有当前那一段是撑开的。
    func testScrubbingAcrossInstrumentalsKeepsRowsConsistent() {
        var now: TimeInterval = 0
        let (controller, visual, timeline) = makeScrubFixture(elapsed: { now })

        // 先正常播到第一段间奏中段。
        for t in stride(from: 0.0, through: 30.0, by: 0.5) {
            now = t
            tick(controller)
        }
        assertInstrumentalRowsConsistent(visual, at: now)
        XCTAssertEqual(timeline.selectedLines.map(\.index), [1])

        // 拖：往后甩、往回拖、再落在别的间奏里。逐帧喂，模拟按住滑块。
        let scrub: [TimeInterval] = [32, 36, 41, 45, 52, 58, 63, 70, 78, 90, 110, 130,
                                     125, 100, 74, 55, 43, 30, 22, 10, 5, 25, 45, 65]
        for t in scrub {
            now = t
            tick(controller)
            assertInstrumentalRowsConsistent(visual, at: t)
            assertIdleInstrumentalsAreDark(visual, at: t)
        }

        // 松手后继续播一会儿。
        for t in stride(from: 65.0, through: 95.0, by: 0.5) {
            now = t
            tick(controller)
        }
        assertInstrumentalRowsConsistent(visual, at: now)
    }

    /// 间奏未轮到时不预留高度；选中后才把 40pt 的行撑开。
    func testInstrumentalHeightExpandsOnlyWhenSelected() {
        let layer = InstrumentalContentLayer()
        layer.specs = specs()

        XCTAssertEqual(layer.sizeThatFits(width: 300).height, 0)
        layer.setSelected(true, animated: true)
        XCTAssertEqual(layer.sizeThatFits(width: 300).height,
                       layer.specs.instrumentalBreakViewHeight)
        layer.setSelected(false, animated: true)
        XCTAssertEqual(layer.sizeThatFits(width: 300).height, 0)
    }

    /// §16.2：y 从上一行的 maxY 现算，**上一行高度为 0 时不加行距**。
    /// 折叠的间奏连自己的尾随行距也不占，否则两句之间仍会多出 25pt 空白。
    func testZeroHeightPreviousLineContributesNoSpacing() {
        // 第一行落在 firstLineStartingPosition
        XCTAssertEqual(LyricsLineGeometry.originY(
            after: nil, firstLineStartingPosition: 60, lineSpacing: 25), 60)
        // 收起态的间奏行（0 高）：下一行紧贴它的 maxY，不补行距
        let collapsed = CGRect(x: 0, y: 200, width: 300, height: 0)
        XCTAssertEqual(LyricsLineGeometry.originY(
            after: collapsed, firstLineStartingPosition: 60, lineSpacing: 25), 200)
        // 打开后它占 40、又补 25 的行距 —— 后面的行整体下移 65
        let expanded = CGRect(x: 0, y: 200, width: 300, height: 40)
        XCTAssertEqual(LyricsLineGeometry.originY(
            after: expanded, firstLineStartingPosition: 60, lineSpacing: 25), 265)
    }

    /// §16.2：首行 y 在 .center 下落到让第 0 行在 origin=0 时居中于目标锚点的高度。
    func testFirstLineStartingPositionRespectsSelectedLinePosition() {
        var specs = LyricsSpecs()
        specs.firstLineStartingPosition = 60
        specs.selectedLinePosition = .topRelative(12, cardHeightPercentage: 0)
        XCTAssertEqual(LyricsLineGeometry.firstLineY(specs: specs, lineHeight: 40, containerHeight: 600), 60)

        // 居中有载荷矩形：(rect.height - line0.height)/2 + rect.minY
        let rect = CGRect(x: 0, y: 100, width: 400, height: 500)
        specs.selectedLinePosition = .center(rect: rect)
        // 100 + (500 - 40)/2 = 100 + 230 = 330
        XCTAssertEqual(LyricsLineGeometry.firstLineY(specs: specs, lineHeight: 40, containerHeight: 600), 330)

        // 居中无载荷矩形：(containerHeight - line0.height)/2
        specs.selectedLinePosition = .center(rect: nil)
        // (600 - 40)/2 = 280
        XCTAssertEqual(LyricsLineGeometry.firstLineY(specs: specs, lineHeight: 40, containerHeight: 600), 280)
    }

    /// [PX] §22.3：侧栏检查器以 0.381 视口高作为焦点锚点，并取整避免微小抖动。
    func testSidebarSelectedLineRectCalculatesCorrectCenterAndRounds() throws {
        let rect = try XCTUnwrap(LyricsBaseline.sidebarSelectedLineRect(panelHeight: 700.4, panelWidth: 280.2))
        XCTAssertEqual(rect.height, 700)
        XCTAssertEqual(rect.width, 280)
        // 700 * 0.381 = 266.7 -> rounded to 267
        // rect.minY = 267 - 700/2 = -83
        XCTAssertEqual(rect.minY, -83)
    }

    // MARK: - §2.6 折行 / 行几何

    private func lyricsFont() -> NSFont { .systemFont(ofSize: 26, weight: .bold) }

    /// [实测] 段落样式的 `lineBreakStrategy` 是 rawValue 3
    /// = `[.pushOut, .hangulWordPriority]`，断词一律交给系统。
    func testParagraphStyleUsesPushOutAndHangulWordPriority() throws {
        let attributes = LyricsTextLayout.attributes(
            for: "Nothing really matters", font: lyricsFont(), color: CGColor(gray: 1, alpha: 1))
        let style = try XCTUnwrap(attributes[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(style.lineBreakStrategy.rawValue, 3)
        XCTAssertEqual(style.lineBreakStrategy, [.pushOut, .hangulWordPriority])
        XCTAssertEqual(style.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(style.alignment, .natural)      // nil = natural
    }

    /// CJK 的字形与断点开关：不设 `languageIdentifier` 排出来跟官方不一样。
    func testLanguageIdentifierFollowsScript() {
        // 汉字一律按简体：这条路在主线程排版里，不做需要加载模型的语言识别。
        XCTAssertEqual(LyricsTextLayout.languageIdentifier(for: "我们在夜色里唱着歌"), "zh-Hans")
        XCTAssertEqual(LyricsTextLayout.languageIdentifier(for: "きみのことが好きだ"), "ja")
        XCTAssertEqual(LyricsTextLayout.languageIdentifier(for: "너를 생각하며"), "ko")
        // 拉丁文本不设——这个属性只对 CJK / 南亚文字有意义。
        XCTAssertNil(LyricsTextLayout.languageIdentifier(for: "Nothing really matters"))
    }

    /// 断行策略真的落到了折行上：同一段韩文换成系统默认策略断点会变。
    /// （`CTTypesetterSuggestLineBreak` 压根不认这个字段，所以折行必须走 TextKit。）
    func testHangulWordPriorityChangesBreakPoints() {
        let text = "나는 오늘도 너를 생각하며 길을 걸었다 아무 말 없이"
        let font = lyricsFont()
        let withStrategy = LyricsTextLayout.attributes(
            for: text, font: font, color: CGColor(gray: 1, alpha: 1))

        let plain = NSMutableParagraphStyle()
        plain.lineBreakMode = .byWordWrapping
        plain.lineBreakStrategy = []
        var withoutStrategy = withStrategy
        withoutStrategy[.paragraphStyle] = plain

        let strategyRanges = LyricsTextLayout.wrap(text, attributes: withStrategy, width: 300)
            .fragments.map(\.range)
        let plainRanges = LyricsTextLayout.wrap(text, attributes: withoutStrategy, width: 300)
            .fragments.map(\.range)
        XCTAssertNotEqual(strategyRanges, plainRanges)
    }

    /// 折行结果要覆盖整段文本、每段都放得下，且不限行数。
    func testWrapFragmentsCoverTextAndFitWidth() {
        let text = "我们在夜色里唱着无人听见的歌谣直到天亮才肯散场"
        let attributes = LyricsTextLayout.attributes(
            for: text, font: lyricsFont(), color: CGColor(gray: 1, alpha: 1))
        let wrapped = LyricsTextLayout.wrap(text, attributes: attributes, width: 200)
        XCTAssertGreaterThan(wrapped.fragments.count, 1)
        var cursor = 0
        for fragment in wrapped.fragments {
            XCTAssertEqual(fragment.range.location, cursor)
            XCTAssertLessThanOrEqual(fragment.usedWidth, 200)
            cursor = NSMaxRange(fragment.range)
        }
        XCTAssertEqual(cursor, (text as NSString).length)
        XCTAssertLessThanOrEqual(wrapped.usedSize.width, 200)
    }

    /// 交给 `CATextLayer` 的字符串按 TextKit 的断点加了硬换行——
    /// 图层自己折行走 CoreText，不认策略，断得比测量多一行就会被裁掉。
    func testHardWrappedFreezesTextKitBreakPoints() {
        let text = "我们在夜色里唱着无人听见的歌谣直到天亮才肯散场"
        let attributes = LyricsTextLayout.attributes(
            for: text, font: lyricsFont(), color: CGColor(gray: 1, alpha: 1))
        let fragments = LyricsTextLayout.wrap(text, attributes: attributes, width: 200).fragments
        let wrapped = LyricsTextLayout.hardWrapped(text, attributes: attributes, width: 200)
        XCTAssertEqual(wrapped.string.components(separatedBy: "\n").count, fragments.count)
        XCTAssertEqual(wrapped.string.replacingOccurrences(of: "\n", with: ""), text)
    }

    /// 超高字符（藏文 / 天城文等）额外补一份字体外延到行距上；纯中英文不触发。
    func testTallScriptsAddLineSpacingOutsets() throws {
        let font = lyricsFont()
        XCTAssertGreaterThan(LyricsTextLayout.tallScriptOutsets(for: "བོད་སྐད", font: font), 0)
        XCTAssertGreaterThan(LyricsTextLayout.tallScriptOutsets(for: "नमस्ते", font: font), 0)
        XCTAssertEqual(LyricsTextLayout.tallScriptOutsets(for: "我们在夜色里", font: font), 0)
        XCTAssertEqual(LyricsTextLayout.tallScriptOutsets(for: "Nothing", font: font), 0)

        let style = try XCTUnwrap(LyricsTextLayout.attributes(
            for: "བོད་སྐད", font: font,
            color: CGColor(gray: 1, alpha: 1))[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(style.lineSpacing,
                       LyricsTextLayout.tallScriptOutsets(for: "བོད་སྐད", font: font))
    }

    /// 分组判据：对唱翻转侧或带和声都收窄到 85%，普通行用满宽。
    func testVocalGroupCoefficient() {
        var flipped = TextLine()
        flipped.agentAlignment = .flipped
        var harmony = TextLine()
        harmony.backgroundVocals = TextLine.BackgroundVocals()
        let plain = TextLine()

        XCTAssertTrue(LyricsLineGeometry.isVocalGroup(flipped))
        XCTAssertTrue(LyricsLineGeometry.isVocalGroup(harmony))
        XCTAssertFalse(LyricsLineGeometry.isVocalGroup(plain))
        XCTAssertFalse(LyricsLineGeometry.isVocalGroup(InstrumentalLine()))

        let specs = specs()
        XCTAssertEqual(LyricsLineGeometry.widthCoefficient(isVocalGroup: true, specs: specs), 0.85)
        XCTAssertEqual(LyricsLineGeometry.widthCoefficient(isVocalGroup: false, specs: specs), 1.0)
    }

    /// 三路水平落点：默认贴左（不是居中），翻转侧右推 0.15 × 可用宽。
    func testHorizontalOffsetIsLeftByDefault() {
        let offset = { (alignment: LyricsLineGeometry.LineAlignment, coefficient: CGFloat) in
            LyricsLineGeometry.horizontalOffset(availableWidth: 600, usedWidth: 400,
                                                coefficient: coefficient, alignment: alignment)
        }
        XCTAssertEqual(offset(.left, 1.0), 0)
        XCTAssertEqual(offset(.center, 1.0), 100)
        XCTAssertEqual(offset(.flipped, 0.85), 90, accuracy: 1e-9)   // 0.15 × 600

        XCTAssertEqual(LyricsLineGeometry.lineAlignment(agent: .normal, textAlignment: nil), .left)
        XCTAssertEqual(LyricsLineGeometry.lineAlignment(agent: .normal, textAlignment: .left), .left)
        XCTAssertEqual(LyricsLineGeometry.lineAlignment(agent: .normal, textAlignment: .center),
                       .center)
        XCTAssertEqual(LyricsLineGeometry.lineAlignment(agent: .flipped, textAlignment: .center),
                       .flipped)
    }

    /// 可用宽度 = documentView 宽 − 左右边距；[PX] 实测 margins ≈ 0。
    func testAvailableWidthSubtractsMargins() {
        XCTAssertEqual(LyricsLineGeometry.availableWidth(documentWidth: 683,
                                                         margins: NSEdgeInsets()), 683)
        XCTAssertEqual(LyricsLineGeometry.availableWidth(
            documentWidth: 683,
            margins: NSEdgeInsets(top: 0, left: 19, bottom: 0, right: 19)), 645)
    }

    // MARK: - §7.3 / §8.2 渐变

    /// SF 的字形框会越过 descender；按 typographic height 卡死 `CATextLayer`
    /// 会让 g/p/y 及部分回退字体在底边少一两个像素。
    func testTextLayerMeasurementIncludesGlyphOverflowPadding() throws {
        let font = specs().font
        let expectedPadding = ceil(max(0, font.boundingRectForFont.maxY - font.ascender)
            + max(0, font.descender - font.boundingRectForFont.minY))
        XCTAssertGreaterThan(expectedPadding, 0)
        XCTAssertEqual(LyricsTextLayout.verticalRasterPadding(for: font), expectedPadding)

        let row = try XCTUnwrap(
            SBS_TextContentLayer.measureRows(text: "gypqj", font: font, width: 300).first)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        CTLineGetTypographicBounds(row.ctLine, &ascent, &descent, &leading)
        XCTAssertEqual(row.height, ceil(ascent + descent + leading) + expectedPadding)
    }

    /// 软边是一个**定宽子层**，不是渐变铺满整层。
    func testGradientSublayerFrames() {
        let frames = LineProgressGradientLayer.sublayerFrames(
            bounds: CGRect(x: 0, y: 0, width: 200, height: 50),
            featherWidth: 30,
            isRightToLeft: false,
            outerPadding: CGSize(width: 30, height: 6))
        XCTAssertEqual(frames.gradient, CGRect(x: 170, y: -6, width: 30, height: 62))
        XCTAssertEqual(frames.fill, CGRect(x: 0, y: 0, width: 170, height: 50))
        // 横向余量层的高度是 2·outer.height，**不含** bounds.height
        XCTAssertEqual(frames.horizontalPadding, CGRect(x: -30, y: -6, width: 30, height: 12))
    }

    func testGradientSkipsHorizontalPaddingWhenNil() {
        let frames = LineProgressGradientLayer.sublayerFrames(
            bounds: CGRect(x: 0, y: 0, width: 100, height: 40),
            featherWidth: 30, isRightToLeft: true, outerPadding: nil)
        XCTAssertNil(frames.horizontalPadding)
        XCTAssertEqual(frames.gradient.minX, 0)         // RTL：软边贴左端
    }

    /// 唱完之后渐变的右端是**墨迹宽**不是行宽——照行宽铺会多亮一截。
    func testFinishedWidthUsesInkNotLineWidth() {
        let width = LineProgressGradientGeometry.finishedWidth(
            lastWordMinX: 120, lastSyllableMaxX: 40,
            verticalPadding: 6, specs: specs())
        XCTAssertEqual(width, 6 + 16 + 160)
    }

    /// 纵向余量要罩住强调峰值（1.14 倍）与半径 5 的辉光。
    func testVerticalPaddingCoversEmphasisAndGlow() {
        let s = specs()
        let font = s.font
        let ink = font.ascender + abs(font.descender)
        let expected = abs(ink * 1.14 + 10 - 40) * 0.5
        XCTAssertEqual(
            LineProgressGradientGeometry.verticalPadding(font: font, lineHeight: 40, specs: s),
            expected, accuracy: 1e-9)
    }

    // MARK: - §7.3 逐字渐变几何与羽化夹紧

    func testSweptGeometryNotStarted() {
        let layoutLine = SyncedLyricsLineLayer.LayoutLine()
        let geom = LineProgressGradientGeometry.sweptGeometry(
            of: layoutLine, state: .notStarted, progress: 0, verticalPadding: 6, specs: specs())
        XCTAssertEqual(geom.width, 0)
        XCTAssertEqual(geom.feather, 16)
    }

    /// 首音节起跑阶段（ratio == 0，如暂停时跳转到音节起点）：
    /// 遮罩前沿必须严格等于首音节起始坐标 sylMinX，绝不得叠加 feather，
    /// 确保音节内部 alpha 恒为 0，防止暂停跳转到该句时首字母提前透出高亮。
    func testSweptGeometryAtStartOfSyllableHasZeroHighlightLeak() {
        let layoutLine = SyncedLyricsLineLayer.LayoutLine()
        layoutLine.startTime = 10
        layoutLine.endTime = 14

        var syl = SyncedLyricsLineLayer.Syllable()
        syl.startTime = 10
        syl.endTime = 12
        syl.frame = CGRect(x: 0, y: 0, width: 40, height: 50)
        var word = SyncedLyricsLineLayer.Word()
        word.frame = CGRect(x: 100, y: 0, width: 40, height: 50)
        word.syllables = [syl]
        layoutLine.words = [word]

        let state = layoutLine.progressState(at: 10)
        XCTAssertEqual(state, .singing(syllableIndexInWord: 0, wordIndex: 0))

        let geom = LineProgressGradientGeometry.sweptGeometry(
            of: layoutLine, state: state, progress: 10, verticalPadding: 6, specs: specs())

        XCTAssertEqual(geom.feather, 16)
        // 遮罩右端严格停在首音节起始坐标 100，不得侵入音节内部 [100, 140]
        XCTAssertEqual(geom.width, word.frame.minX)
        // 在音节区域内 [100, 140]，遮罩 alpha 严格为 0，零高亮泄漏
        XCTAssertLessThanOrEqual(geom.width, word.frame.minX)
    }

    /// 音节间停顿阶段：遮罩前沿不得越过下一个未唱音节的起始坐标，
    /// 无论停顿多久，遮罩稳定停驻在字间空白内，下一个未唱字零高亮泄漏。
    func testSweptGeometryDoesNotLeakIntoNextSyllableDuringPause() {
        let layoutLine = SyncedLyricsLineLayer.LayoutLine()
        layoutLine.startTime = 10
        layoutLine.endTime = 16

        // 第一个词 / 音节：“装”，位置 [160, 200]
        var firstSyl = SyncedLyricsLineLayer.Syllable()
        firstSyl.startTime = 10
        firstSyl.endTime = 12
        firstSyl.frame = CGRect(x: 0, y: 0, width: 40, height: 50)
        var firstWord = SyncedLyricsLineLayer.Word()
        firstWord.frame = CGRect(x: 160, y: 0, width: 40, height: 50)
        firstWord.syllables = [firstSyl]

        // 第二个词 / 音节：“你”，位置 [208, 248]（中间有 8pt 空白）
        var secondSyl = SyncedLyricsLineLayer.Syllable()
        secondSyl.startTime = 14
        secondSyl.endTime = 16
        secondSyl.frame = CGRect(x: 0, y: 0, width: 40, height: 50)
        var secondWord = SyncedLyricsLineLayer.Word()
        secondWord.frame = CGRect(x: 208, y: 0, width: 40, height: 50)
        secondWord.syllables = [secondSyl]

        layoutLine.words = [firstWord, secondWord]

        // 在 t = 13s（“装”唱完、“你”未唱的停顿期）：
        let state = layoutLine.progressState(at: 13)
        XCTAssertEqual(state, .singing(syllableIndexInWord: 0, wordIndex: 0))

        let geom = LineProgressGradientGeometry.sweptGeometry(
            of: layoutLine, state: state, progress: 13, verticalPadding: 6, specs: specs())

        // 羽化恒为 16pt
        XCTAssertEqual(geom.feather, 16)
        // 遮罩右端 208 严格不越过“你”的起始位置 208，alpha 在 >= 208 为 0，“你”零高亮泄漏
        XCTAssertLessThanOrEqual(geom.width, secondWord.frame.minX)
        XCTAssertEqual(geom.width, 208, accuracy: 1e-6)
    }

    /// 连贯歌唱中：前后音节的交界严格连续（startWidth(N+1) == targetWidth(N)），匀速平滑推进，绝不锁死或跳跃。
    func testSweptGeometryContinuousSingingIsSmoothAndContinuous() {
        let layoutLine = SyncedLyricsLineLayer.LayoutLine()
        layoutLine.startTime = 10
        layoutLine.endTime = 14

        // 单个词内部的两个音节：“伪”(10~12s, [100, 140]), “装”(12~14s, [140, 180])
        var syl1 = SyncedLyricsLineLayer.Syllable()
        syl1.startTime = 10
        syl1.endTime = 12
        syl1.frame = CGRect(x: 0, y: 0, width: 40, height: 50)

        var syl2 = SyncedLyricsLineLayer.Syllable()
        syl2.startTime = 12
        syl2.endTime = 14
        syl2.frame = CGRect(x: 40, y: 0, width: 40, height: 50)

        var word = SyncedLyricsLineLayer.Word()
        word.frame = CGRect(x: 100, y: 0, width: 80, height: 50)
        word.syllables = [syl1, syl2]
        layoutLine.words = [word]

        let s = specs()
        let pad: CGFloat = 6
        // 音节 1 的 target 与音节 2 的 start 严格相等
        let target1 = LineProgressGradientGeometry.targetWidth(for: layoutLine, wordIndex: 0, syllableIndex: 0, specs: s, padding: pad)
        let start2 = LineProgressGradientGeometry.startWidth(for: layoutLine, wordIndex: 0, syllableIndex: 1, specs: s, padding: pad)
        XCTAssertEqual(target1, start2)

        // t = 11.5s（syl1 唱了 75%）
        let state1 = layoutLine.progressState(at: 11.5)
        let geom1 = LineProgressGradientGeometry.sweptGeometry(
            of: layoutLine, state: state1, progress: 11.5, verticalPadding: pad, specs: s)
        XCTAssertEqual(geom1.feather, 16)
        // start(100) + (140 - 100) * 0.75 = 130
        XCTAssertEqual(geom1.width, 130, accuracy: 1e-6)

        // t = 12.0s（交界点）：音节 1 唱完与音节 2 开唱的位置完全一致
        let geomEnd1 = LineProgressGradientGeometry.sweptGeometry(
            of: layoutLine, state: state1, progress: 12.0, verticalPadding: pad, specs: s)
        XCTAssertEqual(geomEnd1.width, 140, accuracy: 1e-6)
    }

    /// 行尾最后一个音节唱完时推进至 finishedWidth。
    func testSweptGeometryLastSyllableUsesFinishedWidth() {
        let layoutLine = SyncedLyricsLineLayer.LayoutLine()
        layoutLine.startTime = 10
        layoutLine.endTime = 12

        var syl = SyncedLyricsLineLayer.Syllable()
        syl.startTime = 10
        syl.endTime = 12
        syl.frame = CGRect(x: 0, y: 0, width: 50, height: 50)

        var word = SyncedLyricsLineLayer.Word()
        word.frame = CGRect(x: 50, y: 0, width: 50, height: 50)
        word.syllables = [syl]
        layoutLine.words = [word]

        let pad: CGFloat = 6
        let s = specs()
        let expectedTarget = LineProgressGradientGeometry.finishedWidth(
            lastWordMinX: 50, lastSyllableMaxX: 50, verticalPadding: pad, specs: s)

        // 唱到 100%
        let state = layoutLine.progressState(at: 12.0)
        let geom = LineProgressGradientGeometry.sweptGeometry(
            of: layoutLine, state: state, progress: 12.0, verticalPadding: pad, specs: s)

        XCTAssertEqual(geom.feather, 16)
        XCTAssertEqual(geom.width, expectedTarget)
    }

    /// finished 状态返回 finishedWidth 且羽化为默认值。
    func testSweptGeometryFinishedState() {
        let layoutLine = SyncedLyricsLineLayer.LayoutLine()
        layoutLine.startTime = 10
        layoutLine.endTime = 12

        var syl = SyncedLyricsLineLayer.Syllable()
        syl.startTime = 10
        syl.endTime = 12
        syl.frame = CGRect(x: 0, y: 0, width: 50, height: 50)

        var word = SyncedLyricsLineLayer.Word()
        word.frame = CGRect(x: 50, y: 0, width: 50, height: 50)
        word.syllables = [syl]
        layoutLine.words = [word]

        let geom = LineProgressGradientGeometry.sweptGeometry(
            of: layoutLine, state: .finished, progress: 13, verticalPadding: 6, specs: specs())

        let expectedWidth = LineProgressGradientGeometry.finishedWidth(
            lastWordMinX: 50, lastSyllableMaxX: 50, verticalPadding: 6, specs: specs())
        XCTAssertEqual(geom.width, expectedWidth)
        XCTAssertEqual(geom.feather, 16)
    }

    // MARK: - §7.2 逐字走查

    func testLayoutLineProgressStateBoundaries() {
        let layoutLine = SyncedLyricsLineLayer.LayoutLine()
        layoutLine.startTime = 10
        layoutLine.endTime = 14
        var syllable = SyncedLyricsLineLayer.Syllable()
        syllable.startTime = 10
        syllable.endTime = 12
        var word = SyncedLyricsLineLayer.Word()
        word.syllables = [syllable]
        layoutLine.words = [word]

        XCTAssertEqual(layoutLine.progressState(at: 9.9), .notStarted)
        XCTAssertEqual(layoutLine.progressState(at: 11), .singing(syllableIndexInWord: 0, wordIndex: 0))
        // endTime <= elapsed 才算唱完
        XCTAssertEqual(layoutLine.progressState(at: 14), .finished)
    }

    /// QRC 音节之间可能有静音空档。空档中应停在上一个音节末端，不能把整行
    /// 退回未开始，否则渐变遮罩会瞬间清零。
    func testLayoutLineProgressHoldsAcrossSyllableGap() {
        let layoutLine = SyncedLyricsLineLayer.LayoutLine()
        layoutLine.startTime = 10
        layoutLine.endTime = 15

        var first = SyncedLyricsLineLayer.Syllable()
        first.startTime = 10
        first.endTime = 11
        var second = SyncedLyricsLineLayer.Syllable()
        second.startTime = 12
        second.endTime = 15

        var firstWord = SyncedLyricsLineLayer.Word()
        firstWord.syllables = [first]
        var secondWord = SyncedLyricsLineLayer.Word()
        secondWord.syllables = [second]
        layoutLine.words = [firstWord, secondWord]

        XCTAssertEqual(layoutLine.progressState(at: 11.5),
                       .singing(syllableIndexInWord: 0, wordIndex: 0))
        XCTAssertEqual(layoutLine.progressState(at: 12.5),
                       .singing(syllableIndexInWord: 0, wordIndex: 1))
    }

    /// Word 存排版行坐标，Syllable 存 Word 内局部坐标。两者若都存绝对坐标，
    /// 行末完成公式会把最后一个单元的 x 加两遍，造成结束瞬间闪跳。
    func testSyllableFramesAreLocalToWords() throws {
        var line = TextLine()
        line.text = "A B"
        line.startTime = 0
        line.endTime = 3
        line.syllables = [
            .init(text: "A", startTime: 0, endTime: 1),
            .init(text: "B", startTime: 2, endTime: 3),
        ]

        let layer = SBS_TextContentLayer()
        layer.specs = specs()
        layer.setLine(line)
        layer.bounds = CGRect(x: 0, y: 0, width: 300, height: 80)
        layer.layoutSublayers()

        let row = try XCTUnwrap(layer.layoutLines.first)
        XCTAssertEqual(row.words.count, 2)
        XCTAssertGreaterThan(row.words[1].frame.minX, 0)
        XCTAssertEqual(row.words[1].syllables[0].frame.minX, 0)
        XCTAssertEqual(row.words[1].frame.minX + row.words[1].syllables[0].frame.maxX,
                       row.words[1].frame.maxX, accuracy: 1e-9)
    }

    /// 浏览态不应熄灭当前播放行的已唱图层。
    func testScrollingKeepsSelectedWordHighlightVisible() throws {
        var line = TextLine()
        line.text = "歌词"
        line.startTime = 0
        line.endTime = 2
        line.syllables = [.init(text: "歌词", startTime: 0, endTime: 2)]

        let layer = SBS_TextContentLayer()
        layer.specs = specs()
        layer.setLine(line)
        layer.setSelected(true, animated: false)
        layer.setScrolling(true, animated: true)
        layer.bounds = CGRect(x: 0, y: 0, width: 300, height: 80)
        layer.layoutSublayers()

        XCTAssertEqual(try XCTUnwrap(layer.rows.first).sung.opacity, 1)
    }

    /// 往前永远下发；往回只有退超过 0.5 才下发。漏了它，时间源一抖渐变就回缩。
    func testProgressForwardingThreshold() {
        XCTAssertTrue(SBS_TextContentLayer.shouldForward(newProgress: 10.01, current: 10))
        XCTAssertFalse(SBS_TextContentLayer.shouldForward(newProgress: 10, current: 10))
        XCTAssertFalse(SBS_TextContentLayer.shouldForward(newProgress: 9.6, current: 10))
        XCTAssertTrue(SBS_TextContentLayer.shouldForward(newProgress: 9.5, current: 10))
    }

    // MARK: - §8.1 抬升 / 强调

    func testEmphasisScaleIsLinear() {
        let s = specs()
        XCTAssertEqual(SyncedLyricsLineLayer.SyllableEmphasis.scale(progress: 0, specs: s), 1.0)
        XCTAssertEqual(SyncedLyricsLineLayer.SyllableEmphasis.scale(progress: 1, specs: s), 1.14,
                       accuracy: 1e-9)
        XCTAssertEqual(SyncedLyricsLineLayer.SyllableEmphasis.scale(progress: 0.5, specs: s), 1.07,
                       accuracy: 1e-9)
    }

    /// `syllableLift = 2` 是直接从纵向落点里减掉的常量位移，不是动画幅度。
    func testGlyphPositionSubtractsLift() {
        let s = specs()
        let withLift = SyncedLyricsLineLayer.SyllableEmphasis.glyphPosition(
            origin: CGPoint(x: 10, y: 20), scaledSize: CGSize(width: 30, height: 40),
            scale: 1, specs: s)
        XCTAssertEqual(withLift.x, (30 + 10 + 10) * 0.5, accuracy: 1e-9)
        XCTAssertEqual(withLift.y, (40 + 20 + 20) * 0.25 - 2, accuracy: 1e-9)
    }

    // MARK: - 滚动弹簧

    /// 翻行那条欠阻尼（会过冲），点击那条过阻尼（不回弹）。
    func testScrollSpringOvershootDependsOnDampingRatio() {
        let underdamped = LyricsSpecs().lineChangeSpringTimingParameters
        let samples = stride(from: 0.05, through: 1.5, by: 0.01).map {
            ScrollSpring.decay(t: $0, parameters: underdamped)
        }
        XCTAssertTrue(samples.contains { $0 < -1e-4 }, "ζ=0.9 应当过冲到负位移")

        let overdamped = SpringTimingParameters.tapDriven
        let noOvershoot = stride(from: 0.01, through: 2.0, by: 0.01).allSatisfy {
            ScrollSpring.decay(t: $0, parameters: overdamped) >= -1e-9
        }
        XCTAssertTrue(noOvershoot, "ζ>1 不该过冲")
    }

    func testScrollSpringStartsAtOriginAndSettlesAtTarget() {
        let spring = ScrollSpring(from: 0, to: 100,
                                  parameters: LyricsSpecs().lineChangeSpringTimingParameters,
                                  delay: 0, startTime: 0)
        XCTAssertEqual(spring.value(at: 0), 0)
        XCTAssertEqual(spring.value(at: spring.settlingDuration + 1), 100)
        XCTAssertTrue(spring.isFinished(at: spring.settlingDuration + 0.001))
    }

    func testScrollSpringHonoursDelay() {
        let spring = ScrollSpring(from: 0, to: 100,
                                  parameters: LyricsSpecs().lineChangeSpringTimingParameters,
                                  delay: 0.3, startTime: 0)
        XCTAssertEqual(spring.value(at: 0.2), 0)
        XCTAssertNotEqual(spring.value(at: 0.4), 0)
    }

    // MARK: - §9.6 模糊

    /// 加模糊会被「禁用 / 高对比度」挡住，去模糊永远允许；上限写死 4。
    ///
    /// 非聚焦行取 1.5 而不是 [实测] 3.0：3.0 在 Amber 上会把副行（翻译/发音，
    /// 侧栏 12pt）糊到读不出来，`[实机]` 2026-09-07 用户逐档判读定的值，
    /// 缘由见 `SyncedLyricsVisualExperienceManager.deselectedBlurRadius` 那段注释。
    func testBlurRadiusIsClampedAndGated() {
        XCTAssertEqual(SyncedLyricsVisualExperienceManager.maxBlurRadius, 4)
        XCTAssertEqual(SyncedLyricsVisualExperienceManager.deselectedBlurRadius, 1.5)

        let manager = SyncedLyricsVisualExperienceManager()
        manager.specs.lineBlurEnabled = false
        let view = SyncedLyricsLineView()
        view.configure(line: textLine(start: 0, end: 1), specs: manager.specs)
        manager.setBlurRadius(3, on: view, animated: false)
        XCTAssertTrue(manager.blurredLineViews.isEmpty)
    }

    // MARK: - 排版行量度的缓存（测量路径不得改变结果）

    /// `measureRows` 现在按 (文本, 字体, 宽度) 缓存，测量路径因此不再每次重建
    /// `CTLine`。这条断言把「缓存命中的结果」和「照原来那段代码现算的结果」
    /// **逐像素**比一遍：宽、高、ascent、以及每段的字符范围都必须一模一样。
    func testMeasureRowsMatchesCoreTextReference() {
        let font = LyricsSpecs().font
        let samples = [
            "Hello there, this is a fairly long English lyric line that has to wrap",
            "这是一句需要折行的中文歌词，长度足够撑到第二行甚至第三行为止",
            "はじめての かなしみ でした",
            "短",
        ]
        for width in [120.0 as CGFloat, 260, 480] {
            for text in samples {
                // 参照实现＝缓存之前 `measureRows` 的原样：整段属性字串 + 逐 fragment
                // `CTLineCreateWithAttributedString` + `CTLineGetTypographicBounds`。
                let attributes = LyricsTextLayout.attributes(
                    for: text, font: font, color: CGColor(gray: 1, alpha: 1))
                let attributed = NSAttributedString(string: text, attributes: attributes)
                let reference = LyricsTextLayout
                    .wrap(text, attributes: attributes, width: width)
                    .fragments.map { fragment -> (NSRange, CGFloat, CGFloat, CGFloat) in
                        let ctLine = CTLineCreateWithAttributedString(
                            attributed.attributedSubstring(from: fragment.range))
                        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                        CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
                        return (fragment.range,
                                fragment.usedWidth,
                                LyricsTextLayout.rasterSafeHeight(ascent + descent + leading,
                                                                  font: font),
                                ascent)
                    }

                // 连着问两次：第一次建表，第二次必然命中缓存，两次都要与参照相等。
                for pass in 0..<2 {
                    let rows = SBS_TextContentLayer.measureRows(text: text, font: font,
                                                                width: width)
                    XCTAssertEqual(rows.count, reference.count,
                                   "第 \(pass) 次：段数不一致 w=\(width) “\(text)”")
                    guard rows.count == reference.count else { continue }
                    for (row, expected) in zip(rows, reference) {
                        XCTAssertEqual(row.range, expected.0)
                        XCTAssertEqual(row.width, expected.1)
                        XCTAssertEqual(row.height, expected.2)
                        XCTAssertEqual(row.ascent, expected.3)
                    }
                }
            }
        }
    }

    /// 折行缓存改成了真正的 LRU（上限 1024，超限丢最旧的一半），
    /// 不再是「一超 256 就整张 `removeAll`」。这里只钉住「反复量同一批文本，
    /// 结果始终一致」——淘汰发生与否都不该改变返回值。
    func testWrapCacheEvictionKeepsResultsStable() {
        let font = LyricsSpecs().font
        let attributes = LyricsTextLayout.attributes(
            for: "锚", font: font, color: CGColor(gray: 1, alpha: 1))
        let probe = "这是一句用来验证折行缓存淘汰之后仍然算得出同一结果的歌词"
        let baseline = LyricsTextLayout.size(probe, attributes: attributes, width: 200)

        // 灌够撑爆上限的条目，逼它至少淘汰一轮。
        for i in 0..<(LyricsTextLayout.wrapCacheLimit + 200) {
            _ = LyricsTextLayout.size("填充\(i)号句子，用来把缓存顶到上限以上",
                                      attributes: attributes, width: 200)
        }
        XCTAssertEqual(LyricsTextLayout.size(probe, attributes: attributes, width: 200),
                       baseline)
    }

    // MARK: - 动画器登记与剔除

    /// `currentAnimators` 原来只有「用户开拖」那一条清空路径，翻一行涨一批。
    /// `track(_:)` 登记时先剔一遍已经落位的，`cancelRunningAnimations` 的语义不变。
    func testTrackPrunesFinishedAnimators() {
        let controller = SyncedLyricsViewController()

        // 一条动画都没建就 `finishDispatch` ⇒ 当场跑完回调，算已完成。
        let done = LayerPropertyAnimator(curve: .linear(0.1))
        controller.track([done])
        done.finishDispatch {}
        XCTAssertTrue(done.isFinished)

        // 还没下发的（间奏展开那一路就停在这个状态）不能被当成完成品摘走，
        // 否则用户随后开拖时 `cancelRunningAnimations` 撤不掉它。
        let pending = LayerPropertyAnimator(curve: .linear(0.1))
        pending.totalAnimations = 1
        XCTAssertFalse(pending.isFinished)

        controller.track([pending])
        XCTAssertEqual(controller.currentAnimators.count, 1)
        XCTAssertTrue(controller.currentAnimators.first === pending)

        controller.cancelRunningAnimations()
        XCTAssertTrue(controller.currentAnimators.isEmpty)
        XCTAssertEqual(pending.state, .idle)
    }

    // MARK: - 副行字体

    /// 七处 TextStyle 字体后面都还有一道 bold trait，`.bold` 在 ≤15pt 上被 SF
    /// 解析成 Semibold——所以「主行 Bold、副行 Semibold」是同一条 trait 链在不同
    /// optical size 上的结果，不是两套 weight。写死 weight 就会在辅助功能字号下分岔。
    func testSecondaryFontsAreTextStylesWithBoldTrait() {
        let specs = specs()
        func isBold(_ font: NSFont) -> Bool {
            font.fontDescriptor.symbolicTraits.contains(.bold)
        }
        func size(_ style: NSFont.TextStyle) -> CGFloat {
            NSFont.preferredFont(forTextStyle: style).pointSize
        }
        XCTAssertEqual(specs.font.pointSize, size(.largeTitle))
        XCTAssertEqual(specs.transliterationFont.pointSize, size(.title3))
        XCTAssertEqual(specs.translationLargeFont.pointSize, size(.title3))
        XCTAssertEqual(specs.translationSmallFont.pointSize, size(.callout))
        XCTAssertEqual(specs.backgroundVocalsFont.pointSize, size(.title2))
        XCTAssertEqual(specs.transliterationFontBackgroundVocals.pointSize, size(.subheadline))
        for font in [specs.font, specs.backgroundVocalsFont, specs.transliterationFont,
                     specs.transliterationFontBackgroundVocals, specs.translationSmallFont,
                     specs.translationLargeFont, specs.automaticallyCreatedDisclaimerFont] {
            XCTAssertTrue(isBold(font), "\(font.fontName) 少了 bold trait")
        }
        // 全表唯一不走 Dynamic Type 的一处：固定 14pt，weight 直接给。
        XCTAssertEqual(specs.translationFontBackgroundVocals.pointSize, 14)
    }

    /// 译文两档由「同屏有没有音译」二选一（nil → large），
    /// **发音成块贴在字底下的那种也算有音译**——那时候行级 `transliteration`
    /// 被解析器清成了 nil，只看行级就会把这些行判反，译文错升一档。
    func testTranslationFontFollowsTransliterationPresence() {
        let specs = specs()
        var bare = TextLine()
        bare.text = "You taught me how"
        XCTAssertFalse(specs.hasTransliteration(bare))
        XCTAssertEqual(specs.translationFont(hasTransliteration: specs.hasTransliteration(bare)),
                       specs.translationLargeFont)

        var wholeLine = bare
        wholeLine.transliteration = "ashita no imagoro ni wa"
        XCTAssertTrue(specs.hasTransliteration(wholeLine))

        // 成块那一路：行级是 nil，发音在音节上。
        var ruby = TextLine()
        ruby.text = "動き出そうとしてる"
        ruby.syllables = [
            .init(text: "動", startTime: 0, endTime: 1, transliteration: "ugo"),
            .init(text: "き", startTime: 1, endTime: 2, transliteration: "ki"),
        ]
        XCTAssertNil(ruby.transliteration)
        XCTAssertTrue(specs.hasTransliteration(ruby))
        XCTAssertEqual(specs.translationFont(hasTransliteration: specs.hasTransliteration(ruby)),
                       specs.translationSmallFont)

        // 关掉音译开关，同屏就真的没有音译了，译文升回大档。
        var off = specs
        off.showsTransliteration = false
        XCTAssertFalse(off.hasTransliteration(ruby))
        XCTAssertEqual(off.translationFont(hasTransliteration: off.hasTransliteration(ruby)),
                       off.translationLargeFont)
    }

    /// 整窗四档换字号时副行要跟着走：基线那五个字体配的是侧栏 24–26pt 的正文，
    /// 不缩放的话 72pt 的正文底下压着一条 12pt 的译文，宽度拉到底也不动。
    /// [资源] 10205–10208 的四档 13/17/20/24 由 `transliterationFont` 落点。
    func testSecondaryFontsScaleWithSizeClass() {
        let baseline = specs()
        for sizeClass in MusicMetrics.Lyrics.SizeClass.allCases where sizeClass != .sidebar {
            var specs = baseline
            specs.scaleSecondaryFonts(
                by: sizeClass.secondarySize / baseline.transliterationFont.pointSize)
            XCTAssertEqual(specs.transliterationFont.pointSize, sizeClass.secondarySize,
                           "\(sizeClass) 的音译行没落到 TextStyles 那一档")
            // bold trait 不能在换字号的路上掉了。
            for font in [specs.transliterationFont, specs.translationSmallFont,
                         specs.translationLargeFont, specs.transliterationFontBackgroundVocals] {
                XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold),
                              "\(font.fontName) 少了 bold trait")
            }
            // 两档译文的高低差要留着，否则「同屏有没有音译」那道 csel 等于不存在。
            XCTAssertLessThan(specs.translationSmallFont.pointSize,
                              specs.translationLargeFont.pointSize,
                              "\(sizeClass) 把两档译文压成了同一个字号")
        }

        // 四档之间必须严格递增，不能因为取整撞成同一个数。
        let sizes = MusicMetrics.Lyrics.SizeClass.allCases
            .filter { $0 != .sidebar }
            .map { sizeClass -> CGFloat in
                var specs = baseline
                specs.scaleSecondaryFonts(
                    by: sizeClass.secondarySize / baseline.transliterationFont.pointSize)
                return specs.translationSmallFont.pointSize
            }
        XCTAssertEqual(sizes, sizes.sorted())
        XCTAssertEqual(Set(sizes).count, sizes.count, "有两档译文撞成了同一个字号")

        // 倍率 1 是恒等：侧栏那一档走这条路不会被缩掉。
        var untouched = baseline
        untouched.scaleSecondaryFonts(by: 1)
        XCTAssertEqual(untouched.translationSmallFont.pointSize,
                       baseline.translationSmallFont.pointSize)

        // 留白一概不跟着缩：发音本来就贴着正文，`translationSpacing` /
        // `transliterationLineHeightAdjustment` 一放大就在中间硬塞一道缝。
        var scaled = baseline
        scaled.scaleSecondaryFonts(by: 1.6)
        XCTAssertEqual(scaled.translationSpacing, baseline.translationSpacing)
        XCTAssertEqual(scaled.translationBottomPadding, baseline.translationBottomPadding)
        XCTAssertEqual(scaled.transliterationLineHeightAdjustment,
                       baseline.transliterationLineHeightAdjustment)
        XCTAssertEqual(scaled.transliterationMinWordSpacing,
                       baseline.transliterationMinWordSpacing)
    }

    // MARK: - 「更大字体」两档

    /// 设置 › 通用 ›「更大字体」给那道 csel 定方向。默认 `.pronunciation` ＝ 原版行为，
    /// 上面那批测试全部照旧成立；这里只验 `.lyrics` 这一档换了什么、没换什么。
    func testLargerTextLyricsSwapsSecondaryFonts() {
        var specs = self.specs()
        XCTAssertEqual(specs.largerSecondary, .pronunciation, "默认必须是原版那道写死的 csel")
        specs.largerSecondary = .lyrics

        // 两条同屏：译文拿大档、发音让到小档，正好与 `.pronunciation` 对调。
        let swapped = specs.secondaryFonts(hasTranslation: true, hasTransliteration: true)
        XCTAssertEqual(swapped.translation.pointSize, specs.translationLargeFont.pointSize)
        XCTAssertEqual(swapped.transliteration.pointSize, specs.translationSmallFont.pointSize)
        XCTAssertLessThan(swapped.transliteration.pointSize, swapped.translation.pointSize)

        var pronunciation = self.specs()
        pronunciation.largerSecondary = .pronunciation
        let original = pronunciation.secondaryFonts(hasTranslation: true, hasTransliteration: true)
        XCTAssertEqual(original.translation.pointSize, swapped.transliteration.pointSize)
        XCTAssertEqual(original.transliteration.pointSize, swapped.translation.pointSize)

        // 换字号的路上 bold trait 不能掉。
        for font in [swapped.translation, swapped.transliteration] {
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        }
    }

    /// 译文不参与这道选择：不管哪一档，只有译文在屏上时它都占大档。
    ///
    /// 发音那一侧则**不看译文**——「同时显示」说的是歌词与发音同屏。
    /// 早先这里写的是「只有两条副行同屏两档才有区别」，那正是用户报的那个 bug：
    /// 最常见的一屏（开了发音、没开翻译）两档同形。
    func testLargerTextLeavesTranslationOnlyLinesAlone() {
        for target in [LargerTextTarget.pronunciation, .lyrics] {
            var specs = self.specs()
            specs.largerSecondary = target
            let translationOnly = specs.secondaryFonts(hasTranslation: true,
                                                       hasTransliteration: false)
            XCTAssertEqual(translationOnly.translation.pointSize,
                           specs.translationLargeFont.pointSize, "\(target) 单译文那档变了")
        }

        // 只开发音：`.pronunciation` 停在原版基线，`.lyrics` 让到小档。
        var pronunciation = self.specs()
        pronunciation.largerSecondary = .pronunciation
        XCTAssertEqual(pronunciation.secondaryFonts(hasTranslation: false,
                                                    hasTransliteration: true)
                        .transliteration.pointSize,
                       pronunciation.transliterationFont.pointSize)
        var lyrics = self.specs()
        lyrics.largerSecondary = .lyrics
        XCTAssertEqual(lyrics.secondaryFonts(hasTranslation: false, hasTransliteration: true)
                        .transliteration.pointSize,
                       lyrics.translationSmallFont.pointSize)
    }

    /// 按行取字号的那条便捷入口与显隐开关一致：**发音成块贴在字底下也算有音译**，
    /// 关掉任一条开关就退回「只有一条副行」的形。
    func testSecondaryFontsForLineFollowsVisibilitySwitches() {
        var specs = self.specs()
        specs.largerSecondary = .lyrics

        var ruby = TextLine()
        ruby.text = "動き出そうとしてる"
        ruby.translation = "开始动起来了"
        ruby.syllables = [
            .init(text: "動", startTime: 0, endTime: 1, transliteration: "ugo"),
            .init(text: "き", startTime: 1, endTime: 2, transliteration: "ki"),
        ]
        XCTAssertNil(ruby.transliteration, "成块那一路行级发音会被清成 nil")
        let both = specs.secondaryFonts(for: ruby)
        XCTAssertEqual(both.translation.pointSize, specs.translationLargeFont.pointSize)
        XCTAssertEqual(both.transliteration.pointSize, specs.translationSmallFont.pointSize)

        // 关掉发音：同屏只剩译文，译文照旧是大档。
        var noTransliteration = specs
        noTransliteration.showsTransliteration = false
        let single = noTransliteration.secondaryFonts(for: ruby)
        XCTAssertEqual(single.translation.pointSize, specs.translationLargeFont.pointSize)

        // 关掉翻译：发音仍旧按「更大字体」那一档走，不因为译文不在屏上就跳回基线。
        var noTranslation = specs
        noTranslation.showsTranslation = false
        XCTAssertEqual(noTranslation.secondaryFonts(for: ruby).transliteration.pointSize,
                       specs.translationSmallFont.pointSize)
    }

    /// 整窗四档缩放之后对调仍旧成立：两档字号是按同一个倍率缩的，
    /// 换位换的还是同两个数，不会多出第三档。
    func testLargerTextSurvivesSizeClassScaling() {
        for sizeClass in MusicMetrics.Lyrics.SizeClass.allCases where sizeClass != .sidebar {
            var specs = self.specs()
            specs.largerSecondary = .lyrics
            specs.scaleSecondaryFonts(
                by: sizeClass.secondarySize / specs.transliterationFont.pointSize)
            let fonts = specs.secondaryFonts(hasTranslation: true, hasTransliteration: true)
            XCTAssertEqual(fonts.translation.pointSize, sizeClass.secondarySize,
                           "\(sizeClass) 的译文没落到 TextStyles 那一档")
            XCTAssertLessThan(fonts.transliteration.pointSize, fonts.translation.pointSize,
                              "\(sizeClass) 把两条副行压成了同一个字号")
        }
    }

    // MARK: - 提前滚动与高亮零延迟

    func testSBS_TextContentLayerSungOpacityPreparation() {
        let layer = SBS_TextContentLayer()
        var line = TextLine()
        line.text = "Hello world"
        line.syllables = [
            .init(text: "Hello ", startTime: 10.0, endTime: 11.0),
            .init(text: "world", startTime: 11.0, endTime: 12.0),
        ]
        layer.setLine(line)
        layer.bounds = CGRect(x: 0, y: 0, width: 300, height: 50)
        layer.layoutSublayers()

        XCTAssertFalse(layer.isSelected)
        XCTAssertFalse(layer.isSungPrepared)
        XCTAssertEqual(layer.rows.first?.sung.opacity, 0)

        // 预热：opacity 立刻置 1
        layer.prepareSungOpacity()
        XCTAssertTrue(layer.isSungPrepared)
        XCTAssertEqual(layer.rows.first?.sung.opacity, 1)

        // 取消预热：opacity 恢复为 0
        layer.cancelSungPreparation()
        XCTAssertFalse(layer.isSungPrepared)
        XCTAssertEqual(layer.rows.first?.sung.opacity, 0)
    }

    func testSBS_TextContentLayerSelectionHasNoOpacityAnimation() {
        let layer = SBS_TextContentLayer()
        var line = TextLine()
        line.text = "Hello world"
        line.syllables = [
            .init(text: "Hello ", startTime: 10.0, endTime: 11.0),
        ]
        layer.setLine(line)
        layer.bounds = CGRect(x: 0, y: 0, width: 300, height: 50)
        layer.layoutSublayers()

        // 选中时 opacity 瞬时置 1，不挂 opacity 动画
        layer.setSelected(true, animated: true)
        XCTAssertTrue(layer.isSelected)
        XCTAssertEqual(layer.rows.first?.sung.opacity, 1)
        XCTAssertNil(layer.rows.first?.sung.animation(forKey: "opacity"))
    }

    func testActivateDueLinesActivatesAtEffectiveStart() {
        var time = 0.0
        let (controller, visual, _) = makeScrubFixture(elapsed: { time })
        var line0 = TextLine()
        line0.index = 0
        line0.text = "First line"
        line0.startTime = 10.0
        line0.endTime = 15.0
        line0.syllables = [
            .init(text: "First", startTime: 9.8, endTime: 11.0),
        ]

        var lyrics = Lyrics()
        lyrics.lines = [line0]
        controller.setLyrics(lyrics)

        let target = visual.lineViews[0]
        visual.selectedLineViews = [target]
        target.lineLayer?.apply(selected: false, animation: nil)

        // 9.7s 尚未到 effectiveStart (9.8s)
        visual.activateDueLines(at: 9.7)
        XCTAssertEqual(target.lineLayer?.isSelected, false)

        // 9.8s 到达 effectiveStart
        visual.activateDueLines(at: 9.8)
        XCTAssertEqual(target.lineLayer?.isSelected, true)
    }

    // MARK: - 歌词动效复刻测试（Apple Music 逐行独立位移 + 阶梯延迟 + 零位移对账 + 物理弹簧）

    /// 逐字歌词动态弹簧端点与物理公式核验（sub_0x10110b814）。
    /// ζ = 0.78 + 0.12 * (1 - u), T = 0.48 + 0.27 * u
    func testDerivedLineChangeSpringEndpointsAndPhysics() {
        // 慢歌端点：speed <= 0.2 => u = 0, ζ = 0.90, T = 0.48
        let slowSpring = SpringTimingParameters.derivedLineChangeSpring(speed: 0.1)
        XCTAssertEqual(slowSpring.dampingRatio, 0.90, accuracy: 1e-4)
        XCTAssertEqual(2 * Double.pi / slowSpring.angularFrequency, 0.48, accuracy: 1e-4)

        // 快歌端点：speed >= 0.75 => u = 1, ζ = 0.780, T = 0.75
        let fastSpring = SpringTimingParameters.derivedLineChangeSpring(speed: 0.8)
        XCTAssertEqual(fastSpring.dampingRatio, 0.780, accuracy: 1e-4)
        XCTAssertEqual(2 * Double.pi / fastSpring.angularFrequency, 0.75, accuracy: 1e-4)

        // 中间值：speed = 0.475 => u = 0.5, ζ = 0.84, T = 0.615
        let midSpring = SpringTimingParameters.derivedLineChangeSpring(speed: 0.475)
        XCTAssertEqual(midSpring.dampingRatio, 0.84, accuracy: 1e-4)
        XCTAssertEqual(2 * Double.pi / midSpring.angularFrequency, 0.615, accuracy: 1e-4)

        // 点击驱动：过阻尼 (2, 260, 50), ζ ≈ 1.096 > 1
        let tap = SpringTimingParameters.tapDriven
        XCTAssertEqual(tap.mass, 2.0)
        XCTAssertEqual(tap.stiffness, 260.0)
        XCTAssertEqual(tap.damping, 50.0)
        XCTAssertGreaterThan(tap.dampingRatio, 1.0)
    }

    /// 逐行独立位移：视口在第一帧切换到 targetOrigin，各行挂载阶梯延迟的 additive 动画。
    func testAnimateLineScrollStaggeredAdditiveAnimations() throws {
        let (controller, _) = makeExpansionFixture(instrumentalAt: 10)
        let clip = try XCTUnwrap(controller.scrollView?.contentView)
        let initialOrigin = clip.bounds.origin.y

        guard let lines = controller.lyrics?.lines, lines.count > 4 else {
            XCTFail("Fixture lacks sufficient lines")
            return
        }

        let targetLine = lines[3]
        let targetOrigin = CGPoint(x: 0, y: initialOrigin + 120)

        // 启动逐行滚动动画
        controller.animateLineScroll(to: targetOrigin,
                                     anchorLine: targetLine,
                                     spring: controller.specs.lineChangeSpringTimingParameters,
                                     baseOffset: 0)

        // 1. 视口在第一帧立即就位，确保新进场行与出场行都在正确裁切范围内
        XCTAssertEqual(clip.bounds.origin.y, targetOrigin.y, accuracy: 1e-9)

        // 2. 圈定受影响行并已登记
        XCTAssertFalse(controller.displacedLineViews.isEmpty, "受影响行必须进入 displacedLineViews 集合")

        // 3. 逐行下发动画器，阶梯延迟单调递增
        XCTAssertFalse(controller.currentAnimators.isEmpty, "必须建出逐行 LayerPropertyAnimator")
        let sortedAnimators = controller.currentAnimators.sorted { $0.delay < $1.delay }
        if sortedAnimators.count >= 3 {
            XCTAssertEqual(sortedAnimators[0].delay, 0, accuracy: 1e-9, "第 1 行 delay 恒为 0")
            XCTAssertEqual(sortedAnimators[1].delay, 0, accuracy: 1e-9, "前两行共享 delay 0")
            XCTAssertEqual(sortedAnimators[2].delay, 0.05, accuracy: 1e-9, "第 3 行延迟 50ms")
        }
        if sortedAnimators.count >= 4 {
            XCTAssertEqual(sortedAnimators[3].delay, 0.10, accuracy: 1e-9, "第 4 行延迟 100ms")
        }

        // 4. 图层 position 动画必须为 isAdditive
        for animator in controller.currentAnimators {
            for layer in animator.layers {
                if let anim = layer.animation(forKey: "position") as? CABasicAnimation {
                    XCTAssertTrue(anim.isAdditive, "逐行位移动画必须是 isAdditive")
                }
            }
        }
    }

    /// 零位移对账测试：视口准确落到目标位置，状态清空。
    func testZeroDisplacementReconciliation() throws {
        let (controller, _) = makeExpansionFixture(instrumentalAt: 10)
        let clip = try XCTUnwrap(controller.scrollView?.contentView)
        let initialOrigin = clip.bounds.origin.y

        let delta: CGFloat = 100
        let targetOrigin = CGPoint(x: 0, y: initialOrigin + delta)

        controller.reconcileDisplacedLines(to: targetOrigin)
        XCTAssertEqual(clip.bounds.origin.y, targetOrigin.y, accuracy: 1e-9)
        XCTAssertTrue(controller.displacedLineViews.isEmpty)
    }
}


// MARK: - 「更大字体」从设置到行视图的整条路

/// 设置 › 通用 ›「更大字体」是**歌词与发音同屏时谁更大**，与译文无关。
///
/// 这一组走的是真实宿主路径：`AppSettings.shared` → `SyncedLyricsView`
/// （`NSHostingView` 里的 representable）→`SyncedLyricsViewController.setLyrics`
/// → 行视图的内容层，最后读内容层真正拿去排版的那两个字体。
/// 单测 spec 那一层（上面 `LyricsKitTests` 里那几条）过不了这一关：
/// 曾经的 bug 正是「spec 自己算对了，但要译文也在屏上才分岔」。
@MainActor
final class LargerTextPipelineTests: XCTestCase {

    /// 只有发音、没有译文的一行（QQ roma 归到音节上那条路，行级发音会被清成 nil）。
    private func pronunciationOnlyLine() -> LyricLine {
        LyricLine(index: 0, time: 0, end: 5, text: "動き出そうとしてる",
                  syllables: [
                    .init(text: "動", time: 0, duration: 1, transliteration: "ugo"),
                    .init(text: "き", time: 1, duration: 1, transliteration: "ki"),
                    .init(text: "出", time: 2, duration: 1, transliteration: "da"),
                    .init(text: "そう", time: 3, duration: 1, transliteration: "sou"),
                  ])
    }

    private func lineViews(in view: NSView) -> [SyncedLyricsLineView] {
        var found: [SyncedLyricsLineView] = []
        if let line = view as? SyncedLyricsLineView { found.append(line) }
        for sub in view.subviews { found += lineViews(in: sub) }
        return found
    }

    /// 等 SwiftUI 把 `objectWillChange` 推完一轮。
    private func pump() {
        for _ in 0..<60 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// 内容层真正拿去排版的发音字号。
    private func pronunciationSize(in host: NSView) -> CGFloat? {
        lineViews(in: host).lazy.compactMap {
            ($0.lineLayer?.contentLayer as? SBS_TextContentLayer)?
                .transliterationFontForMeasuring.pointSize
        }.first
    }

    /// **回归用**：只开了发音、没开翻译时，两档必须给出不同的发音字号。
    /// 这一屏正是选项说明里那句「同时显示时」说的那一屏（歌词 + 发音），
    /// 早先它落进 `guard hasTranslation, hasTransliteration` 的早退，两档同形。
    func testPronunciationResizesWithoutTranslationOnScreen() {
        for sizeClass in [MusicMetrics.Lyrics.SizeClass.sidebar, .medium] {
            func specs(_ target: LargerTextTarget) -> LyricsSpecs {
                var specs = LyricsSpecs()
                specs.largerSecondary = target
                // 侧栏档不缩（`LyricsSpecs` 那五个字体本来就是侧栏这一档），
                // 整窗档按 `SyncedLyricsView.makeSpecs()` 同一条倍率换档。
                if sizeClass != .sidebar {
                    specs.scaleSecondaryFonts(
                        by: sizeClass.secondarySize / specs.transliterationFont.pointSize)
                }
                return specs
            }
            func pronunciationSize(_ target: LargerTextTarget) -> CGFloat {
                specs(target).secondaryFonts(hasTranslation: false,
                                             hasTransliteration: true).transliteration.pointSize
            }
            // `.pronunciation` 是原版那道写死的 csel，字号必须停在基线档上。
            XCTAssertEqual(pronunciationSize(.pronunciation),
                           specs(.pronunciation).transliterationFont.pointSize,
                           "\(sizeClass)：默认档不该偏离原版")
            XCTAssertGreaterThan(pronunciationSize(.pronunciation),
                                 pronunciationSize(.lyrics),
                                 "\(sizeClass)：只开发音时两档给了同一个字号")
        }
    }

    /// 整条路：改 `AppSettings.shared` → 行视图上的发音字号跟着变。
    /// 侧栏档与整窗档各跑一遍（整窗那档还多一道 `scaleSecondaryFonts`）。
    func testSettingReachesLineViews() {
        for sizeClass in [MusicMetrics.Lyrics.SizeClass.sidebar, .medium] {
            let restore = AppSettings.shared.values.largerText
            defer { AppSettings.shared.values.largerText = restore }
            AppSettings.shared.values.largerText = .pronunciation

            let player = PlayerController()
            let host = NSHostingView(rootView: SyncedLyricsView(
                lyrics: [pronunciationOnlyLine()],
                player: player,
                showsTranslation: true,
                showsTransliteration: true,
                overrides: .init(horizontalMargin: 19, sizeClass: sizeClass)))
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: sizeClass == .sidebar ? 260 : 700, height: 600)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            pump()

            let big = pronunciationSize(in: host)
            XCTAssertNotNil(big, "\(sizeClass)：没建出逐字内容层")

            AppSettings.shared.values.largerText = .lyrics
            pump()
            host.layoutSubtreeIfNeeded()
            let small = pronunciationSize(in: host)
            XCTAssertNotNil(small)
            XCTAssertLessThan(small ?? 0, big ?? 0,
                              "\(sizeClass)：切到「歌词」之后发音没有让档")
            window.orderOut(nil)
        }
    }

    /// 「更大字体」不该动主行：正文两档都是同一个字号。
    /// 把正文与发音整个对调是另一套排版，没有实测依据之前不做。
    func testMainLineFontIsUntouched() {
        var lyrics = LyricsSpecs()
        lyrics.largerSecondary = .lyrics
        var pronunciation = LyricsSpecs()
        pronunciation.largerSecondary = .pronunciation
        XCTAssertEqual(lyrics.font.pointSize, pronunciation.font.pointSize)
    }
}


/// `syncBlurToPlaybackState()` 只读 `isPaused`，`elapsedTime` 走不到。
@MainActor
private final class StubTimingProvider: SyncedLyricsTimingProvider {
    var isPaused = false
    var elapsedTime: TimeInterval = 0
}
