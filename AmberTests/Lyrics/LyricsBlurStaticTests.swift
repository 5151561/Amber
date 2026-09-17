import SwiftUI
import QuartzCore
import CoreText
import XCTest
@testable import Amber

/// 模糊闸、无戳纯文本那面「墙」，以及动画器的登记与剔除。
@MainActor
final class LyricsBlurStaticTests: XCTestCase, LyricsKitFixtures {

    // MARK: - §9.6 模糊

    /// 加模糊会被「禁用 / 高对比度」挡住，去模糊永远允许；上限写死 4。
    ///
    /// 非聚焦行取 2.0 而不是 [实测] 3.0：3.0 在 Amber 上会把副行（翻译/发音，
    /// 侧栏 12pt）糊到读不出来，`[实机]` 2026-09-07 用户逐档判读定在 1.5、
    /// 2026-09-17 上调到 2.0，
    /// 缘由见 `SyncedLyricsVisualExperienceManager.deselectedBlurRadius` 那段注释。
    func testBlurRadiusIsClampedAndGated() {
        XCTAssertEqual(SyncedLyricsVisualExperienceManager.maxBlurRadius, 4)
        XCTAssertEqual(SyncedLyricsVisualExperienceManager.deselectedBlurRadius, 2.0)

        let manager = SyncedLyricsVisualExperienceManager()
        manager.specs.lineBlurEnabled = false
        let view = SyncedLyricsLineView()
        view.configure(line: textLine(start: 0, end: 1), specs: manager.specs)
        manager.setBlurRadius(3, on: view, animated: false)
        XCTAssertTrue(manager.blurredLineViews.isEmpty)
    }

    // MARK: - 无戳纯文本：静态档那面「墙」

    /// 静态档夹具：整份无时间戳的纯文本（`LyricsAdapter` 对 `.plain` 的产出——
    /// 时间恒 ∞、无音节、无能力位，`lyrics.type == .static`）。
    ///
    /// scrollView 必须**先有真实的非零尺寸**再 `setLyrics`：宽度 0 时灌行数据
    /// 有过爆内存的先例。
    private func makeStaticWallFixture(lineCount: Int = 6)
        -> (SyncedLyricsViewController, SyncedLyricsVisualExperienceManager) {
        let controller = SyncedLyricsViewController()
        controller.specs.renderingMode = .static
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 260)
        controller.view.layoutSubtreeIfNeeded()

        let visual = SyncedLyricsVisualExperienceManager()
        visual.viewController = controller
        visual.specs = controller.specs
        controller.manager = visual

        var lyrics = Lyrics()
        lyrics.type = .static
        lyrics.lines = (0..<lineCount).map { index in
            var line = TextLine()
            line.index = index
            line.startTime = .infinity
            line.endTime = .infinity
            line.primaryVocalsStartTime = .infinity
            line.primaryVocalsEndTime = .infinity
            line.capabilities = []
            line.text = "第\(index)行纯文本"
            return line
        }
        controller.setLyrics(lyrics)
        return (controller, visual)
    }

    /// 最决定性的一条：静态档的行**诞生即选中，且不进选行状态机**。
    ///
    /// 同步档那套「带着模糊出生、由选行去模糊」在这一档没有驱动源（没有时间轴），
    /// 照抄就是一面白 α0.175 + 1.5 模糊的看不见的墙。而修法只能走图层直连——
    /// 一旦经 `selectLine` 进了 `selectedLineViews`，淘汰、滚动焦点和
    /// `unblurredLineViewIDs` 三件事全被这面墙污染。
    func testStaticWallIsBornSelectedAndStaysOutOfTheSelectionMachine() {
        let (_, visual) = makeStaticWallFixture()
        XCTAssertEqual(visual.lineViews.count, 6)

        for (index, view) in visual.lineViews.enumerated() {
            XCTAssertEqual(view.lineLayer?.blurRadius, 0, "第 \(index) 行不许带模糊出生")
            XCTAssertTrue(view.lineLayer?.isSelected == true, "第 \(index) 行该是满亮的")
        }
        XCTAssertTrue(visual.blurredLineViews.isEmpty, "不进模糊集合")
        XCTAssertTrue(visual.selectedLineViews.isEmpty, "更不进选行状态机")
    }

    /// 播放/暂停切一次，墙不许糊掉。
    ///
    /// `restoreBlurAfterPause` 按 `unblurredLineViewIDs`（这一档恒空）把「其余行」
    /// 糊回去，也就是整面墙。闸在 `syncBlurToPlaybackState()` 开头。
    func testStaticWallSurvivesPauseAndResume() {
        let (_, visual) = makeStaticWallFixture()
        let timing = StubTimingProvider()
        visual.timingProvider = timing

        timing.isPaused = true
        visual.syncBlurToPlaybackState()
        timing.isPaused = false
        visual.syncBlurToPlaybackState()

        for (index, view) in visual.lineViews.enumerated() {
            XCTAssertEqual(view.lineLayer?.blurRadius, 0, "第 \(index) 行在恢复播放后仍该清晰")
        }
        XCTAssertTrue(visual.blurredLineViews.isEmpty)
    }

    /// 松手三秒后也不许糊掉。
    ///
    /// `beginScrollingAppearance` 早就有闸，它的反面 `endScrollingAppearance` 没有；
    /// 而 `scrollViewWillBeginScrolling` 在这一档照样跑、照样起那个 3 秒计时器。
    func testStaticWallSurvivesScrollingRoundTrip() {
        let (_, visual) = makeStaticWallFixture()

        visual.beginScrolling()
        XCTAssertEqual(visual.mode, .scroll, "拖动这条路在静态档照样走到")
        visual.returnControlToPlayback()        // 3 秒计时器到点走的就是它

        for (index, view) in visual.lineViews.enumerated() {
            XCTAssertEqual(view.lineLayer?.blurRadius, 0, "第 \(index) 行在松手之后仍该清晰")
            XCTAssertTrue(view.lineLayer?.isSelected == true, "亮度也不许掉回去")
        }
        XCTAssertTrue(visual.blurredLineViews.isEmpty)
    }

    /// 静态档不启动每帧驱动：没有时间轴可走查，起了也只是空转。
    func testStaticModeDoesNotStartDisplayLink() {
        let (controller, _) = makeStaticWallFixture()
        controller.isVisible = true
        controller.isActive = true
        controller.updateDisplayLink()
        XCTAssertNil(controller.displayLink, "静态档即使又可见又在跟随，也不该起链")
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
}
