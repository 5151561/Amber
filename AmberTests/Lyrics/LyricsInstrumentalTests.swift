import SwiftUI
import QuartzCore
import CoreText
import XCTest
@testable import Amber

/// 间奏行：三个点的时序与几何，以及「上下展开」那一路的行流重排。
@MainActor
final class LyricsInstrumentalTests: XCTestCase, LyricsKitFixtures {

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

    /// 点阵的原点是**行张开**那一刻，不是撑开落定那一刻。
    ///
    /// 两者差一个展开动画（`scrollLead ≈ 0.89 s`）。合成一个字段的话点会白等它一次：
    /// 5 秒的间奏里「点真正在动」的窗口（第一个点亮起 → 淡出起跑）从 2.2 秒
    /// 塌到 0.4 秒，而一个点淡入就要 `initialDotAnimationDuration`（0.8 秒）。
    /// 呼吸门槛跟着从「空档 ≥ 5.8 s」抬到 ≥ 7.6 s——门槛变长就是这条断了的信号。
    func testInstrumentalDotsAreAnchoredOnWhenTheRowOpens() throws {
        let lead = LyricsSpecs().scrollLead
        // 一段 5 秒空档经适配层之后：张开 0、落定 lead、收起 5 − lead。
        let source = [
            LyricLine(index: 0, time: 0, end: 8, text: "上一句"),
            LyricLine(index: 1, time: 8, end: 13, text: "", kind: .interlude),
            LyricLine(index: 2, time: 13, end: 18, text: "下一句"),
        ]
        let line = LyricsAdapter.makeLyrics(from: source, handover: lead).lines[1]
        let instrumental = try XCTUnwrap(line as? InstrumentalLine)
        XCTAssertEqual(try XCTUnwrap(instrumental.openTime), 8, accuracy: 1e-9, "行张开 = 空档起点")
        XCTAssertEqual(instrumental.startTime, 8 + lead, accuracy: 1e-9, "落定晚一个展开动画")

        let layer = InstrumentalContentLayer()
        layer.line = instrumental
        layer.makeDots()
        layer.reset()
        XCTAssertEqual(layer.openStartTime, 8, accuracy: 1e-9)

        // 「点真正在动」的窗口：第一个点亮起 → 淡出起跑。
        let active = (instrumental.endTime - InstrumentalContentLayer.fadeOutLeadTime)
            - (layer.openStartTime + InstrumentalContentLayer.firstDotDelay)
        XCTAssertGreaterThan(active, InstrumentalContentLayer.initialDotAnimationDuration,
                             "窄到装不下一个点的淡入就是塌了")
    }

    /// 点阵的时间窗与行的可见寿命是**对齐**的，这条不变量靠间奏行的三个字段成立：
    ///
    /// - `openTime` = 行张开那一刻（行高瞬时变 40，点从这里起就在屏幕上）——
    ///   `firstDotDelay` 的 1.0 秒从它量（[PX]：行 3.13 开始 / 3.67 落定 / 点 4.05）；
    /// - `startTime` = 展开动画跑完那一刻，选行状态机读的是它；
    /// - `endTime` = 收起动画**起跑**那一刻（间奏行被淘汰、行高 40 → 0）。
    ///   收起是瞬时落值，点会被当场切掉，所以淡出必须整段落在它之前。
    func testInstrumentalDotsFinishFadingBeforeTheRowCollapses() {
        let layer = InstrumentalContentLayer()
        var line = InstrumentalLine()
        line.startTime = 10
        line.endTime = 30
        layer.line = line
        layer.makeDots()
        layer.reset()
        layer.setSelected(true, animated: false)

        let cue = line.endTime - InstrumentalContentLayer.fadeOutLeadTime
        XCTAssertFalse(layer.update(elapsed: cue - 0.01).contains(.cueFadeOut))
        XCTAssertTrue(layer.update(elapsed: cue + 0.01).contains(.cueFadeOut))

        // 退出不是单纯淡透明：先放大，随后淡出并缩到 0.2。三段 delay 是 0 / 1 / 1。
        let stages = InstrumentalContentLayer.fadeOutCurves
        XCTAssertEqual(stages.map(\.delay), [0, 1, 1])
        XCTAssertEqual(InstrumentalContentLayer.fadeOutScale, 0.2)
        let tail = stages.map(\.delay).max() ?? 0
        XCTAssertLessThan(cue + tail, line.endTime,
                          "淡出必须在收起之前跑完，否则点会胀着被整行切掉")
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

        // 那张表由 `testLineStaggerFormulas` 钉，这里只验它确实接上了。
        let delays = controller.currentAnimators.map(\.delay)
        XCTAssertGreaterThan(delays.count, 1)
        let stagger = LineStagger.linear(controller.specs.lineDelay)
        for (ordinal, delay) in delays.enumerated() {
            XCTAssertEqual(delay, stagger.delay(movedOrdinal: ordinal, affectedOrdinal: 0),
                           accuracy: 1e-9)
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

    /// 展开这条路**接管视口**，必须把还在跑的翻行滚动的收尾作废。
    ///
    /// `animateLineScroll` 在完成回调里调 `reconcileDisplacedLines(to:)`，
    /// 那一步会 `setScrollOrigin` 到**它自己**那个目标；那道闸只认
    /// `scrollAnimationGeneration`。展开把视口挪走之后若不改代次，
    /// 旧回调一到就把视口再挪一格回去——实测屏幕上所有行当场整体跳 90pt
    /// （= `instrumentalBreakViewHeight + lineSpacing`），跳完再由各自的叠加偏移
    /// 滑回来，观感就是「间奏点附近闪一下」。
    func testExpansionInvalidatesTheInFlightScrollReconcile() throws {
        let (controller, visual) = makeExpansionFixture(instrumentalAt: 2)
        let target = visual.lineViews[2]
        visual.instrumentalBreakVisibleView = target

        // 假装上一次翻行滚动还在跑：留着它的收尾目标与受影响行。
        controller.pendingScrollTargetOrigin = CGPoint(x: 0, y: 1234)
        controller.displacedLineViews = Set(visual.lineViews.prefix(3))
        let generationBefore = controller.scrollAnimationGeneration

        controller.animateInstrumentalExpansion(
            affected: Array(visual.lineViews.prefix(4)),
            anchorIndex: 2,
            deltaY: 40,
            animation: SyncedLyricsLineLayer.SelectionAnimation(
                spring: SpringTimingParameters(mass: 1, stiffness: 100, damping: 20)),
            stagger: .sharedFirstPair(controller.specs.lineDelay))

        XCTAssertNotEqual(controller.scrollAnimationGeneration, generationBefore,
                          "代次必须推进，旧滚动的完成回调才进不来")
        XCTAssertNil(controller.pendingScrollTargetOrigin, "旧的收尾目标必须清掉")
        XCTAssertTrue(controller.displacedLineViews.isEmpty, "旧的位移行集合一并清掉")
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
        // 整窗覆盖项：居中版式 + 行距 48（见 InspectorLyricsViewController.makeSpecs）
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
}
