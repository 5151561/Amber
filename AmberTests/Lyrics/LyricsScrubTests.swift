import SwiftUI
import QuartzCore
import CoreText
import XCTest
@testable import Amber

/// 拖进度条穿过间奏：任何时刻至多一段撑开，没轮到的一律熄灭并藏起。
@MainActor
final class LyricsScrubTests: XCTestCase, LyricsKitFixtures {

    // MARK: - 拖进度条穿过间奏


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

    /// 无论目标行是否在视口内、是否为间奏行，只要 animated 为真就允许动画，不产生瞬移硬跳。
    func testJumpShouldAnimateRespectsAnimatedFlag() {
        let (controller, _, _) = makeScrubFixture(elapsed: { 0 })
        let offScreenFrame = CGRect(x: 0, y: 5000, width: 300, height: 40)
        let inScreenFrame = CGRect(x: 0, y: 100, width: 300, height: 40)
        let textLine = controller.lyrics?.lines[0]
        let instrumentalLine = controller.lyrics?.lines[1]

        // animated 为 true 时均应为 true
        XCTAssertTrue(controller.jumpShouldAnimate(targetLineFrame: offScreenFrame,
                                                   targetLine: textLine,
                                                   animated: true))
        XCTAssertTrue(controller.jumpShouldAnimate(targetLineFrame: inScreenFrame,
                                                   targetLine: textLine,
                                                   animated: true))
        XCTAssertTrue(controller.jumpShouldAnimate(targetLineFrame: offScreenFrame,
                                                   targetLine: instrumentalLine,
                                                   animated: true))
        XCTAssertTrue(controller.jumpShouldAnimate(targetLineFrame: inScreenFrame,
                                                   targetLine: instrumentalLine,
                                                   animated: true))

        // animated 为 false 时为 false
        XCTAssertFalse(controller.jumpShouldAnimate(targetLineFrame: offScreenFrame,
                                                    targetLine: textLine,
                                                    animated: false))
        XCTAssertFalse(controller.jumpShouldAnimate(targetLineFrame: inScreenFrame,
                                                    targetLine: textLine,
                                                    animated: false))
    }

    /// 远距离跳转（目标行位移超出视口高）时，应启动 ScrollSpring 进行平滑视口滚动，而非瞬移或逐行卡顿。
    func testJumpOffScreenLineAnimatesSmoothlyViaScrollSpring() throws {
        let (controller, visual, _) = makeScrubFixture(elapsed: { 0 })
        runLayoutPass(controller)

        // 确保初始滚动位于顶部 0
        controller.setScrollOrigin(.zero)
        XCTAssertNil(controller.scrollSpring)

        // 跳转至第 7 行（远在几屏之外）
        let targetLine = try XCTUnwrap(controller.lyrics?.lines[7])
        controller.jump(to: targetLine, animated: true)

        // 验证：由于 delta 远超可视高度 (260)，交由 ScrollSpring 平滑滚动
        XCTAssertNotNil(controller.scrollSpring, "远距离跳转应启动 ScrollSpring 平滑滑动")

        // 模拟数帧后，滚动位置逐步靠近目标
        let initialY = controller.scrollView?.contentView.bounds.origin.y ?? 0
        let targetOrigin = controller.targetOrigin(for: visual.lineViews[7])

        controller.advanceScrollSpring(at: CACurrentMediaTime() + 0.1)
        let midY = controller.scrollView?.contentView.bounds.origin.y ?? 0
        XCTAssertGreaterThan(midY, initialY, "视口应在弹簧驱动下逐步平滑滚向目标")

        // 弹簧完成后顺利落位
        controller.advanceScrollSpring(at: CACurrentMediaTime() + 2.0)
        XCTAssertNil(controller.scrollSpring)
        let finalY = controller.scrollView?.contentView.bounds.origin.y ?? 0
        XCTAssertEqual(finalY, targetOrigin.y, accuracy: 1.0, "最终精准平滑落位于目标 origin")
    }
}
