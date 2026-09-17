import SwiftUI
import QuartzCore
import CoreText
import XCTest
@testable import Amber

/// 间奏点两侧的时序：走真的适配层，钉住进出场的先后。
@MainActor
final class LyricsInterludeTimelineTests: XCTestCase, LyricsKitFixtures {

    // MARK: - 间奏点两侧的时序

    /// 记下 `didSelect` / `didDeselect` 的**先后**，并转发给真正的委托。
    /// 「下一句先进、间奏后出」这条顺序是整套时序的承重结构，只看最终集合看不出来。
    @MainActor
    private final class SelectionOrderSpy: SyncedLyricsManagerDelegate {
        weak var forward: (any SyncedLyricsManagerDelegate)?
        private(set) var events: [String] = []
        /// 每次回调之后选中集合还剩几条——用来证明中间没有「一条都不亮」的那一帧。
        private(set) var countsAfterEachEvent: [Int] = []

        func syncedLyricsManager(_ manager: SyncedLyricsManager, didSelect line: any LyricsLine) {
            events.append("select \(line.index)")
            forward?.syncedLyricsManager(manager, didSelect: line)
            countsAfterEachEvent.append(manager.selectedLines.count)
        }

        func syncedLyricsManager(_ manager: SyncedLyricsManager, didDeselect line: any LyricsLine) {
            events.append("deselect \(line.index)")
            forward?.syncedLyricsManager(manager, didDeselect: line)
            countsAfterEachEvent.append(manager.selectedLines.count)
        }

        func syncedLyricsManager(_ manager: SyncedLyricsManager, didFinish line: any LyricsLine) {
            forward?.syncedLyricsManager(manager, didFinish: line)
        }

        func syncedLyricsManager(_ manager: SyncedLyricsManager, didResyncTo line: (any LyricsLine)?) {
            forward?.syncedLyricsManager(manager, didResyncTo: line)
        }
    }

    /// 上一句 [0,8] → 间奏 [8,20] → 下一句 [20,25]，一路走**真的适配层**，
    /// 好让间奏行两头的进出场余量参与进来。
    private func makeInterludeTimelineFixture(elapsed: @escaping () -> TimeInterval)
        -> (SyncedLyricsViewController, SyncedLyricsVisualExperienceManager,
            SyncedLyricsManager, SelectionOrderSpy) {
        let (controller, visual, timeline) = makeScrubFixture(elapsed: elapsed)
        let source = [
            LyricLine(index: 0, time: 0, end: 8, text: "上一句"),
            LyricLine(index: 1, time: 8, end: 20, text: "", kind: .interlude),
            LyricLine(index: 2, time: 20, end: 25, text: "下一句"),
        ]
        controller.setLyrics(LyricsAdapter.makeLyrics(from: source,
                                                      handover: controller.specs.scrollLead))
        let spy = SelectionOrderSpy()
        spy.forward = timeline.delegate
        timeline.delegate = spy
        return (controller, visual, timeline, spy)
    }

    /// 进间奏**不提前**：间奏是全曲最长的那段空档，没有「赶在开唱前落位」这回事，
    /// 上一句唱完那一刻才该起跑。
    ///
    /// 展开 + 滚动是在**准入**那一刻起跑的（`select(_:)` 的间奏支），所以这条用例
    /// 钉的就是准入时刻：早先间奏行两头贴死前后句，准入落在 `上一句唱完 − 0.89`，
    /// 上一句还在唱画面就开始往下走。
    func testInstrumentalOpensWhenThePreviousLineFinishes() throws {
        var elapsed: TimeInterval = 4
        let (_, _, timeline, spy) = makeInterludeTimelineFixture { elapsed }

        timeline.resync(at: elapsed)
        XCTAssertEqual(timeline.selectedLines.map(\.index), [0])

        elapsed = 8 - 0.01
        timeline.update()
        XCTAssertEqual(timeline.selectedLines.map(\.index), [0],
                       "上一句还没唱完，间奏一格都不许动")

        elapsed = 8 + 0.01
        timeline.update()
        XCTAssertEqual(timeline.selectedLines.map(\.index), [1], "唱完那一刻才轮到间奏")
        XCTAssertEqual(Array(spy.events.suffix(2)), ["select 1", "deselect 0"],
                       "间奏先进、上一句后出——集合才不会空一帧")
        XCTAssertFalse(spy.countsAfterEachEvent.contains(0))
    }

    /// 出间奏**要提前一整条翻行弹簧**：收起 + 滚到下一句跑的就是那条弹簧，
    /// 提前它这么久起跑，跑完那一刻正好是下一句开唱。
    ///
    /// 早先这一步由 `endTime − animationHeadstart`（0.1 s）触发，
    /// 却要跑 0.89 s 的弹簧 —— 落位比开唱晚 0.79 s，「唱起来了画面才开始动」。
    func testInstrumentalHandsOverOneScrollAnimationBeforeTheNextLine() throws {
        var elapsed: TimeInterval = 10
        let (controller, _, timeline, spy) = makeInterludeTimelineFixture { elapsed }
        let lead = controller.specs.scrollLead

        timeline.resync(at: elapsed)
        XCTAssertEqual(timeline.selectedLines.map(\.index), [1])

        elapsed = 20 - lead - 0.01
        timeline.update()
        XCTAssertEqual(timeline.selectedLines.map(\.index), [1], "还没到起跑时刻")

        elapsed = 20 - lead + 0.01
        timeline.update()
        XCTAssertEqual(timeline.selectedLines.map(\.index), [2],
                       "提前一整条弹簧让位，跑完正好是开唱")
        XCTAssertEqual(spy.events.suffix(2), ["select 2", "deselect 1"],
                       "下一句先进、间奏后出——`deselectLine` 才找得到滚动的落点")
        XCTAssertFalse(spy.countsAfterEachEvent.contains(0))
    }

    /// 回归守卫：间奏行两侧的空档都得是**一整条翻行弹簧**。
    ///
    /// 解析器给的间奏是 `[上一句唱完, 下一句开唱]`，两头贴死 —— 照那个区间走，
    /// 这两个数都会是 **0**：进间奏退化成「提前 0.89 s 起跑」（`scrollFocusPlan`
    /// 的重叠分支），出间奏退化成**瞬时跳格**。
    func testHandoverAcrossInstrumentalIsAFullScrollLead() throws {
        var elapsed: TimeInterval = 0
        let (controller, visual, _, _) = makeInterludeTimelineFixture { elapsed }
        let lines = try XCTUnwrap(controller.lyrics?.lines)
        let lead = visual.scrollLead

        XCTAssertEqual(visual.handoverDuration(from: lines[0], to: lines[1]), lead,
                       accuracy: 1e-9, "进间奏：整条，不是 0")
        XCTAssertEqual(visual.handoverDuration(from: lines[1], to: lines[2]), lead,
                       accuracy: 1e-9, "出间奏：整条，不是 0（0 就是瞬时跳格）")
    }

    /// 展开动画期间**视口归它自己管**（§16.3 的理由二、commit 789d029）。
    ///
    /// 间奏准入的同一帧上一句就被淘汰（集合这才满 2），而
    /// `deselectLine → relayout → scrollToSelectedLine` 的锚点正是刚展开的那一行。
    /// 那条路必须让开，否则展开跑到一半被插一脚、屏幕整块跳一格。
    func testOpenInstrumentalKeepsTheViewportForTheExpansion() throws {
        let (controller, visual) = makeExpansionFixture(instrumentalAt: 2)
        visual.select(try XCTUnwrap(controller.lyrics?.lines[2]))
        XCTAssertTrue(visual.instrumentalBreakVisibleView === visual.lineViews[2])

        let origin = try XCTUnwrap(controller.scrollView?.contentView.bounds.origin)
        let generation = controller.scrollAnimationGeneration
        controller.currentAnimators = []

        controller.scrollToSelectedLine(
            animation: .init(spring: controller.specs.lineChangeSpringTimingParameters),
            animated: true)

        XCTAssertEqual(controller.scrollView?.contentView.bounds.origin, origin, "视口一格不许动")
        XCTAssertEqual(controller.scrollAnimationGeneration, generation, "也不许推进代次")
        XCTAssertNil(controller.pendingScrollTargetOrigin)
        XCTAssertTrue(controller.currentAnimators.isEmpty, "压根不该下发滚动")
    }

    /// 收起间奏那一路自己带着一次滚动（`relayout` 的`defer`），焦点位要当场登记。
    /// 不登记的话下一帧 `followScrollTarget` 认为目标换了，对同一个目标**再滚一次**
    /// —— 第二条弹簧从静止起跑，把第一条的动势抹平。
    func testDeselectingInstrumentalTakesOverTheScrollTarget() throws {
        let (controller, visual) = makeExpansionFixture(instrumentalAt: 2)
        let interlude = try XCTUnwrap(controller.lyrics?.lines[2])
        let next = try XCTUnwrap(controller.lyrics?.lines[3])
        visual.select(interlude)
        visual.selectLine(next, animation: nil, deselectingOthers: false,
                          updatesInstrumentalTime: false)

        visual.deselectLine(interlude)
        XCTAssertNil(visual.instrumentalBreakVisibleView, "收起了")
        XCTAssertTrue(visual.scrollTargetView === visual.lineViews[3], "焦点位当场登记")
        XCTAssertTrue(visual.lineViews[3].lineLayer?.isSelected == true, "起跑即亮起")

        controller.currentAnimators = []
        visual.followScrollTarget(at: visual.currentElapsedTime())
        XCTAssertTrue(controller.currentAnimators.isEmpty, "同一个目标不许再滚一次")
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
}
