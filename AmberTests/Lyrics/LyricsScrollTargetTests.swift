import SwiftUI
import QuartzCore
import CoreText
import XCTest
@testable import Amber

/// 滚动焦点位：目标原点、让位时刻、提前准入的行何时亮起、逐行位移。
@MainActor
final class LyricsScrollTargetTests: XCTestCase, LyricsKitFixtures {

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
    /// **六种空档形态（宽 / 窄 / 贴着 / 交错）的时长都只在这一条里钉**，
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

    // MARK: - 逐行独立位移

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

        // 3. 逐行下发动画器，延迟照 `LineStagger.sharedFirstPair` 派（那张表由
        //    `testLineStaggerFormulas` 钉，这里只验它确实接上了）。
        XCTAssertFalse(controller.currentAnimators.isEmpty, "必须建出逐行 LayerPropertyAnimator")
        let delays = controller.currentAnimators.map(\.delay).sorted()
        let stagger = LineStagger.sharedFirstPair(controller.specs.lineDelay)
        XCTAssertEqual(delays,
                       (0..<delays.count).map { stagger.delay(movedOrdinal: 0, affectedOrdinal: $0) })

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
