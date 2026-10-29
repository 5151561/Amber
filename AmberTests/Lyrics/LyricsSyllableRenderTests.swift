import SwiftUI
import QuartzCore
import CoreText
import XCTest
@testable import Amber

/// 逐字渲染：渐变几何、羽化夹紧、抬升与强调。
@MainActor
final class LyricsSyllableRenderTests: XCTestCase, LyricsKitFixtures {

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
        unsafe CTLineGetTypographicBounds(row.ctLine, &ascent, &descent, &leading)
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
        // 实心区与软边条同样纵向外扩 pad：抬升会把已唱字顶出 bounds，贴合会切墨。
        XCTAssertEqual(frames.fill, CGRect(x: 0, y: -6, width: 170, height: 62))
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
        XCTAssertEqual(width, 6 + specs().lineProgressionGradientFeather + 160)
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
        XCTAssertEqual(geom.feather, specs().lineProgressionGradientFeather)
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

        XCTAssertEqual(geom.feather, specs().lineProgressionGradientFeather)
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
        XCTAssertEqual(geom.feather, specs().lineProgressionGradientFeather)
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
        XCTAssertEqual(geom1.feather, specs().lineProgressionGradientFeather)
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

        XCTAssertEqual(geom.feather, specs().lineProgressionGradientFeather)
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
        XCTAssertEqual(geom.feather, specs().lineProgressionGradientFeather)
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

    /// 放行之后还要分清「逐帧步进」与「seek」：抬升只在前者走弹簧。
    /// 倒退一律算跳——放回原位本来就是 seek 的收尾。
    func testContinuousAdvanceGatesLiftAnimation() {
        XCTAssertTrue(SBS_TextContentLayer.isContinuousAdvance(newProgress: 10.016, current: 10))
        XCTAssertTrue(SBS_TextContentLayer.isContinuousAdvance(newProgress: 10.25, current: 10))
        XCTAssertFalse(SBS_TextContentLayer.isContinuousAdvance(newProgress: 10.9, current: 10))
        XCTAssertFalse(SBS_TextContentLayer.isContinuousAdvance(newProgress: 10, current: 10))
        XCTAssertFalse(SBS_TextContentLayer.isContinuousAdvance(newProgress: 9.4, current: 10))
    }

    // MARK: - §8.1 抬升 / 强调

    /// 抬升那条弹簧要的是**慢**：ω₀ = 3.742、ζ = 0.935，九成落位约 0.66 s——
    /// Apple Music 的观感是「慢慢漂浮」，调硬就变成逐字弹跳。
    func testSyllableLiftUsesMeasuredSpring() {
        let spring = SpringTimingParameters.syllableEmphasis
        XCTAssertEqual(spring.mass, 1)
        XCTAssertEqual(spring.stiffness, 14)
        XCTAssertEqual(spring.damping, 7)
        let omega = (spring.stiffness / spring.mass).squareRoot()
        XCTAssertEqual(omega, 3.742, accuracy: 1e-3)
        XCTAssertLessThan(spring.damping / (2 * (spring.stiffness * spring.mass).squareRoot()), 1)
    }

    /// 播放中一个音节轮到了，那 2pt 必须挂动画慢慢飘；seek 落点则当场落位。
    /// 漏了这条，`animated: false` 会把弹簧整条短路成瞬移，观感就是逐字弹跳。
    func testLiftAnimatesOnlyOnContinuousAdvance() throws {
        func makeLayer() -> SBS_TextContentLayer {
            var line = TextLine()
            line.text = "歌词"
            line.startTime = 0
            line.endTime = 2
            line.capabilities = [.gradient, .lift]
            line.syllables = [
                .init(text: "歌", startTime: 0, endTime: 1),
                .init(text: "词", startTime: 1, endTime: 2),
            ]
            let layer = SBS_TextContentLayer()
            layer.specs = specs()
            layer.setLine(line)
            layer.setSelected(true, animated: false)
            layer.bounds = CGRect(x: 0, y: 0, width: 300, height: 80)
            layer.layoutSublayers()
            return layer
        }

        // 逐帧步进越过第二个音节的起唱点：挂着 position 动画，模型值已是抬升位。
        //
        // 注意 `animationHeadstart = 0.10`：下发给几何的时间是 `progress + 0.10`
        // （`animationHeadstart` 那条提前量），所以步进要落在 0.90 之前，才在第二次步进时越过 1.0。
        let playing = makeLayer()
        let base = try XCTUnwrap(playing.rows.first?.syllables[safe: 1]?.base)
        let restingY = base.position.y
        playing.setProgress(0.88, animated: true)
        playing.setProgress(0.91, animated: true)
        XCTAssertNotNil(base.animation(forKey: "position"))
        XCTAssertEqual(base.position.y, restingY - specs().syllableLift, accuracy: 1e-6)

        // 同一个起唱点，这次是 seek 过去的：一步到位，不起飞。
        let seeked = makeLayer()
        let seekedBase = try XCTUnwrap(seeked.rows.first?.syllables[safe: 1]?.base)
        let seekedRestingY = seekedBase.position.y
        seeked.setProgress(1.01, animated: true)
        XCTAssertNil(seekedBase.animation(forKey: "position"))
        XCTAssertEqual(seekedBase.position.y, seekedRestingY - specs().syllableLift, accuracy: 1e-6)
    }

    func testEmphasisScaleIsLinear() {
        let s = specs()
        XCTAssertEqual(SyncedLyricsLineLayer.SyllableEmphasis.scale(progress: 0, specs: s), 1.0)
        XCTAssertEqual(SyncedLyricsLineLayer.SyllableEmphasis.scale(progress: 1, specs: s), 1.14,
                       accuracy: 1e-9)
        XCTAssertEqual(SyncedLyricsLineLayer.SyllableEmphasis.scale(progress: 0.5, specs: s), 1.07,
                       accuracy: 1e-9)
    }

    /// `syllableLift` 是直接从纵向落点里减掉的常量位移，不是动画幅度。
    func testGlyphPositionSubtractsLift() {
        let s = specs()
        let withLift = SyncedLyricsLineLayer.SyllableEmphasis.glyphPosition(
            origin: CGPoint(x: 10, y: 20), scaledSize: CGSize(width: 30, height: 40),
            scale: 1, specs: s)
        XCTAssertEqual(withLift.x, (30 + 10 + 10) * 0.5, accuracy: 1e-9)
        XCTAssertEqual(withLift.y, (40 + 20 + 20) * 0.25 - s.syllableLift, accuracy: 1e-9)
    }

    // MARK: - §1.1 强调缩放的两条时刻

    /// 零点在**音节开唱**那一刻（不是唱完），逐字形错峰 `stagger·i`，
    /// 回收比鼓起晚 `span/(n/2)`。三个数都是实测出来的时刻表参数，
    /// 其中没有任何 `end` 加法——所以放大与高亮同时起步。
    func testEmphasisWindowsStaggerFromSyllableStart() {
        let windows = SyncedLyricsLineLayer.SyllableEmphasis.windows(
            start: 10, span: 2, glyphCount: 6,
            range: specs().emphasizingScaleRange)
        XCTAssertEqual(windows.count, 6)

        // stagger = min(2/6 × 0.4, 0.4) = 0.1333…
        let stagger = 2.0 / 6 * 0.4
        // hold = min(2/(6/2), 2) = 0.6667
        let hold = 2.0 / 3
        for (i, window) in windows.enumerated() {
            XCTAssertEqual(window.grow, 10 + stagger * Double(i), accuracy: 1e-9)
            XCTAssertEqual(window.shrink, 10 + hold + stagger * Double(i), accuracy: 1e-9)
            XCTAssertEqual(window.span, 2, accuracy: 1e-9)
        }
        // 首字母先鼓：末字母起步时首字母已经在收（实测 7.37s → 8.03s 的差就是它）。
        XCTAssertLessThan(windows[0].grow, windows[5].grow)
        XCTAssertGreaterThan(windows[0].shrink, windows[5].grow - 1e-9)
    }

    /// 错峰有上限 0.4s，`span/(n/2)` 那一段则随字数变短——短词被按回去得更早。
    func testEmphasisWindowsClampStaggerAndHold() {
        let many = SyncedLyricsLineLayer.SyllableEmphasis.windows(
            start: 0, span: 9, glyphCount: 2,
            range: specs().emphasizingScaleRange)
        XCTAssertEqual(many[1].grow, 0.4, accuracy: 1e-9)          // stagger 被 0.4 夹住
        XCTAssertEqual(many[0].shrink, 9, accuracy: 1e-9)          // hold 被 span 夹住

        // 一个汉字的长音：`span/(n/2)` 会退化成 2·span，夹回 span。
        let single = SyncedLyricsLineLayer.SyllableEmphasis.windows(
            start: 5, span: 2, glyphCount: 1,
            range: specs().emphasizingScaleRange)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].grow, 5, accuracy: 1e-9)
        XCTAssertEqual(single[0].shrink, 7, accuracy: 1e-9)
    }

    /// **只有「唱住了」的音节才有窗口**，而「唱住了」和「拆不拆字形」是**同一个判据**。
    ///
    /// 这是第一版做坏的地方：把 `s = lo + t·(hi − lo)` 当成恒取上界，于是每个音节
    /// 唱完都跳一下 14%。正确的关系是——没被拆成字形层的短词，连窗口都不生成，
    /// `transform` 一次都不写。`hello`（2.0s）拆成 5 层、每层有窗口；
    /// `world`（0.5s）一层、没有窗口。
    func testEmphasisWindowsOnlyForHeldSyllables() throws {
        let range = specs().emphasizingScaleRange
        // 函数本身不做准入，短时长只用来证明 `windows` 不背这个判断。
        XCTAssertEqual(SyncedLyricsLineLayer.SyllableEmphasis.windows(
            start: 1, span: 0.25, glyphCount: 3, range: range).count, 3)
        XCTAssertTrue(SyncedLyricsLineLayer.SyllableEmphasis.windows(
            start: 1, span: 0, glyphCount: 3, range: range).isEmpty)

        // 真正的门在建层那一处：`hello ` 拆成 5 个字形、5 条窗口；
        // `world` 0.5s，不到 `heldSyllableThreshold`，一层且无窗口。
        let layer = makeHeldWordLayer()
        let row = try XCTUnwrap(layer.rows.first)
        XCTAssertEqual(row.syllables.count, 6)
        for index in 0..<5 {
            let window = try XCTUnwrap(row.emphasisWindows[index])
            XCTAssertEqual(window.scale, range.upperBound, accuracy: 1e-9)
            XCTAssertEqual(window.span, 2, accuracy: 1e-9)
        }
        XCTAssertNil(row.emphasisWindows[5])
    }

    func testEmphasisWindowsAreEmptyForZeroSpan() {
        XCTAssertTrue(SyncedLyricsLineLayer.SyllableEmphasis.windows(
            start: 3, span: 0, glyphCount: 4,
            range: specs().emphasizingScaleRange).isEmpty)
    }

    /// 三相就位：还没轮到 → 鼓着 → 被按回去。
    func testEmphasisWindowPhaseAt() {
        let window = SyncedLyricsLineLayer.SyllableEmphasis.Window(
            grow: 10, shrink: 11, span: 2, scale: 1.14)
        XCTAssertEqual(window.phase(at: 9.99), .idle)
        XCTAssertEqual(window.phase(at: 10), .grown)
        XCTAssertEqual(window.phase(at: 10.99), .grown)
        XCTAssertEqual(window.phase(at: 11), .shrunk)
    }

    /// 那条弹簧是**临界阻尼**：`mass 1`、`ω = 2π/min(span, 3)`、`c = 2ω`——
    /// 不弹，也是「鼓起来很稳」的原因。
    func testEmphasisSpringIsCriticallyDamped() {
        let spring = SyncedLyricsLineLayer.SyllableEmphasis.spring(span: 2)
        let omega = 2 * Double.pi / 2
        XCTAssertEqual(spring.mass, 1)
        XCTAssertEqual(spring.stiffness, omega * omega, accuracy: 1e-9)
        XCTAssertEqual(spring.damping, 2 * omega, accuracy: 1e-9)
        // ζ = c / (2√(km)) = 1
        XCTAssertEqual(spring.damping / (2 * (spring.stiffness * spring.mass).squareRoot()),
                       1, accuracy: 1e-9)

        // 长音节被 3s 截顶，短音节被 0.05s 兜底（不发散）。
        XCTAssertEqual(SyncedLyricsLineLayer.SyllableEmphasis.spring(span: 9).stiffness,
                       (2 * Double.pi / 3) * (2 * Double.pi / 3), accuracy: 1e-9)
        XCTAssertGreaterThan(SyncedLyricsLineLayer.SyllableEmphasis.spring(span: 0).stiffness, 0)
    }

    /// 接线的落点：长音词（`span > heldSyllableThreshold`）拆成字形层之后，
    /// **开唱那一刻**起逐字形鼓起来、再被按回去——放大与高亮同时起，不是之后。
    ///
    /// `beyond` 0…2s、6 个字形：`stagger = 2/6×0.4 = 0.133`、`hold = 2/3 = 0.667`，
    /// 于是 `grow_0 = 0`、`grow_5 = 0.667`、`shrink_0 = 0.667`、`shrink_5 = 1.333`。
    /// 也就是说末字母开始鼓的那一刻，正好是首字母被按回去的那一刻。
    func testEmphasisScalesGlyphsFromTheSyllableStart() throws {
        var line = TextLine()
        line.text = "beyond"
        line.startTime = 0
        line.endTime = 2
        line.capabilities = [.gradient, .lift]
        line.syllables = [.init(text: "beyond", startTime: 0, endTime: 2)]
        let layer = SBS_TextContentLayer()
        layer.specs = specs()
        layer.setLine(line)
        layer.setSelected(true, animated: false)
        layer.bounds = CGRect(x: 0, y: 0, width: 400, height: 80)
        layer.layoutSublayers()

        let row = try XCTUnwrap(layer.rows.first)
        XCTAssertEqual(row.syllables.count, 6, "长音词按字形各自成层")
        let first = row.syllables[0].base
        let last = row.syllables[5].base

        // 刚开唱：首字母已经鼓起来（与高亮同时），末字母还没轮到。
        layer.setProgress(0.05, animated: false)
        XCTAssertEqual(first.transform.m11, 1.14, accuracy: 1e-9, "开唱即鼓")
        XCTAssertEqual(last.transform.m11, 1, accuracy: 1e-9, "末字母还在排队")

        // 唱到一半：首字母早被按回去，末字母顶上（鼓包移到词尾）。
        layer.setProgress(1.0, animated: false)
        XCTAssertEqual(first.transform.m11, 1, accuracy: 1e-9)
        XCTAssertEqual(last.transform.m11, 1.14, accuracy: 1e-9)

        // 唱完之后hold 也走完了：全部归位。
        layer.setProgress(1.6, animated: false)
        XCTAssertEqual(first.transform.m11, 1, accuracy: 1e-9)
        XCTAssertEqual(last.transform.m11, 1, accuracy: 1e-9)

        // 往回拖：鼓包回到词头，词尾退回排队。
        layer.setProgress(0.05, animated: false)
        XCTAssertEqual(first.transform.m11, 1.14, accuracy: 1e-9)
        XCTAssertEqual(last.transform.m11, 1, accuracy: 1e-9)
    }

    /// **短词全程不放大**——这是用户两次否掉的那条（「100% 不是每个词都触发」）。
    ///
    /// `word` 只唱 0.4s，不到 `heldSyllableThreshold`，不拆字形层，也就没有窗口；
    /// 从开唱到唱完之后扫一整段进度，`transform` 必须一直是恒等。
    /// 上一版把 `s` 当恒定上界，这里每一帧都会是 1.14。
    func testShortWordNeverScales() throws {
        var line = TextLine()
        line.text = "word"
        line.startTime = 0
        line.endTime = 0.4
        line.capabilities = [.gradient, .lift]
        line.syllables = [.init(text: "word", startTime: 0, endTime: 0.4)]
        let layer = SBS_TextContentLayer()
        layer.specs = specs()
        layer.setLine(line)
        layer.setSelected(true, animated: false)
        layer.bounds = CGRect(x: 0, y: 0, width: 400, height: 80)
        layer.layoutSublayers()

        let row = try XCTUnwrap(layer.rows.first)
        XCTAssertEqual(row.syllables.count, 1, "短词不拆字形层")
        XCTAssertNil(row.emphasisWindows.first ?? nil, "短词没有强调窗口")

        let base = row.syllables[0].base
        for progress in stride(from: 0.0, through: 1.2, by: 0.05) {
            layer.setProgress(progress, animated: false)
            XCTAssertEqual(base.transform.m11, 1, accuracy: 1e-9, "progress = \(progress)")
            XCTAssertEqual(base.transform.m22, 1, accuracy: 1e-9, "progress = \(progress)")
        }
    }

    /// 正常的帧步进才走弹簧；seek 落点一律当场落位（与抬升同一条闸）。
    ///
    /// 这里顺带守住「模型值先写、动画后挂」：参数被写进模型，动画只是把画面追上去。
    func testEmphasisSpringIsDispatchedOnContinuousAdvance() throws {
        var line = TextLine()
        line.text = "beyond"
        line.startTime = 0
        line.endTime = 2
        line.capabilities = [.gradient, .lift]
        line.syllables = [.init(text: "beyond", startTime: 0, endTime: 2)]
        let layer = SBS_TextContentLayer()
        layer.specs = specs()
        layer.setLine(line)
        layer.setSelected(true, animated: false)
        layer.bounds = CGRect(x: 0, y: 0, width: 400, height: 80)
        layer.layoutSublayers()
        let row = try XCTUnwrap(layer.rows.first)
        let base = row.syllables[0].base

        // seek 到窗口里：不起弹簧，直接到上界（开唱那一刻首字母就该鼓）。
        layer.setProgress(0.05, animated: false)
        XCTAssertNil(base.animation(forKey: "transform"))
        XCTAssertEqual(base.transform.m11, 1.14, accuracy: 1e-9)

        // 退回去重来，这次按帧步进跨过首字母的**回收**时刻
        // （`start + span/(n/2) = 0 + 2/3 ≈ 0.667s`）。
        // 注意 `applyProgress` 只在 animated 那一路叠 `animationHeadstart`（0.10s），
        // 所以步到 0.75 一定有越线的那一帧，不依赖那个 0.1 有没有加。
        layer.setProgress(0.2, animated: true)
        for step in stride(from: 0.25, through: 0.75, by: 0.05) {
            layer.setProgress(step, animated: true)
        }
        let spring = try XCTUnwrap(base.animation(forKey: "transform") as? CASpringAnimation)
        // span = 2 → ω = 2π/2 = π，临界阻尼的 c = 2ω。
        XCTAssertEqual(spring.damping, 2 * Double.pi, accuracy: 1e-6)
        XCTAssertEqual(spring.stiffness, Double.pi * Double.pi, accuracy: 1e-6)
        XCTAssertGreaterThan(spring.duration, 0)
        // 模型值当场就是终点，动画跑完不会弹回。
        XCTAssertEqual(base.transform.m11, 1, accuracy: 1e-9)
    }

    /// 一句唱完、不再是当前行时，还鼓着的字要当场收回去。
    ///
    /// 不这么做的话：收起靠每帧比对时刻，而这行已经没有帧了，最后一个字会永远停在 1.14
    /// ——「上一句里有个字特别大」。
    func testEmphasisCollapsesWhenTheLineStopsBeingCurrent() throws {
        var line = TextLine()
        line.text = "beyond"
        line.startTime = 0
        line.endTime = 2
        line.capabilities = [.gradient, .lift]
        line.syllables = [.init(text: "beyond", startTime: 0, endTime: 2)]
        let layer = SBS_TextContentLayer()
        layer.specs = specs()
        layer.setLine(line)
        layer.setSelected(true, animated: false)
        layer.bounds = CGRect(x: 0, y: 0, width: 400, height: 80)
        layer.layoutSublayers()

        let row = try XCTUnwrap(layer.rows.first)
        // 取开唱后不久：首字母正鼓着（`shrink_0 = 0.667s` 之前）。
        layer.setProgress(0.3, animated: false)
        XCTAssertEqual(row.syllables[0].base.transform.m11, 1.14, accuracy: 1e-9)

        layer.setSelected(false, animated: false)
        XCTAssertEqual(row.syllables[0].base.transform.m11, 1, accuracy: 1e-9)
        XCTAssertEqual(row.syllables[0].sung?.transform.m11 ?? 1, 1, accuracy: 1e-9)
    }

    // MARK: - 亮字按需建

    /// 亮字 `CATextLayer` 只在看得见时存在：未选中没有、选中后与 base 逐个同位、
    /// 熄灭（含淡出落位）后拆掉。容器与遮罩一直都在，每帧照常推进。
    func testSungLayersAreBuiltOnDemandAndDiscardedAfterFadeOut() throws {
        var line = TextLine()
        line.text = "歌词"
        line.startTime = 0
        line.endTime = 2
        line.capabilities = [.gradient, .lift]
        line.syllables = [
            .init(text: "歌", startTime: 0, endTime: 1),
            .init(text: "词", startTime: 1, endTime: 2),
        ]
        let layer = SBS_TextContentLayer()
        layer.specs = specs()
        layer.setLine(line)
        layer.bounds = CGRect(x: 0, y: 0, width: 300, height: 80)
        layer.layoutSublayers()

        let row = try XCTUnwrap(layer.rows.first)
        XCTAssertFalse(row.hasSungLayers)
        XCTAssertTrue(row.syllables.allSatisfy { $0.sung == nil })
        XCTAssertTrue(row.sung.sublayers?.isEmpty ?? true)
        XCTAssertTrue(row.sung.mask === row.gradient, "容器与遮罩不随亮字拆建")

        // 未选中时已抬起一个音节（抬升挂着弹簧在飘）：之后现建的亮字要跟上落点与相位。
        layer.setProgress(0.99, animated: true)
        layer.setProgress(1.01, animated: true)
        XCTAssertNotNil(row.syllables[1].base.animation(forKey: "position"))

        layer.setSelected(true, animated: true)
        XCTAssertTrue(row.hasSungLayers)
        XCTAssertEqual(row.sung.opacity, 1)
        for pair in row.syllables {
            let sung = try XCTUnwrap(pair.sung)
            XCTAssertTrue(sung.superlayer === row.sung)
            XCTAssertEqual(sung.frame, pair.base.frame)
            XCTAssertEqual(sung.string as? String, pair.base.string as? String)
            XCTAssertEqual(sung.alignmentMode, pair.base.alignmentMode)
        }
        let lifted = try XCTUnwrap(row.syllables[1].sung)
        let flight = try XCTUnwrap(lifted.animation(forKey: "position"))
        let baseFlight = try XCTUnwrap(row.syllables[1].base.animation(forKey: "position"))
        XCTAssertEqual(flight.beginTime, baseFlight.beginTime, "同一条弹簧、同一相位")
        XCTAssertTrue((flight as? CAPropertyAnimation)?.isAdditive == true)

        // 预热重复进来不重建。
        layer.prepareSungOpacity()
        XCTAssertTrue(row.syllables[1].sung === lifted)

        // 淡出没建出动画（关着隐式动作 ⇒ 当场落值）时，收尾在 `finishDispatch` 里同步跑——
        // 与淡出落位走的是同一条拆层路径。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setSelected(false, animated: true)
        CATransaction.commit()
        XCTAssertFalse(row.hasSungLayers)
        XCTAssertTrue(row.syllables.allSatisfy { $0.sung == nil })
        XCTAssertTrue(row.sung.sublayers?.isEmpty ?? true)
        XCTAssertEqual(row.sung.opacity, 0)

        // 再选中：重新建一批，仍与 base 同位。
        layer.setSelected(true, animated: true)
        let rebuilt = try XCTUnwrap(row.syllables[1].sung)
        XCTAssertFalse(rebuilt === lifted)
        XCTAssertEqual(rebuilt.frame, row.syllables[1].base.frame)

        // 淡出：动画还在跑时亮字留着（画面上仍在淡）。
        layer.setSelected(false, animated: true)
        XCTAssertNotNil(row.sung.animation(forKey: "opacity"))
        XCTAssertTrue(row.hasSungLayers)

        // 淡出途中又被选中、又被瞬时熄灭：那条淡出还挂着，不许当场拆。
        layer.setSelected(true, animated: true)
        XCTAssertTrue(row.syllables[1].sung === rebuilt)
        layer.setSelected(false, animated: false)
        XCTAssertTrue(row.hasSungLayers)
        XCTAssertEqual(row.sung.opacity, 0)
    }

    /// 预热后取消（瞬时熄灭、没有淡出在跑）：当场拆。
    func testCancelledSungPreparationDiscardsSungLayers() throws {
        var line = TextLine()
        line.text = "Hello world"
        line.syllables = [
            .init(text: "Hello ", startTime: 10.0, endTime: 11.0),
            .init(text: "world", startTime: 11.0, endTime: 12.0),
        ]
        let layer = SBS_TextContentLayer()
        layer.specs = specs()
        layer.setLine(line)
        layer.bounds = CGRect(x: 0, y: 0, width: 300, height: 50)
        layer.layoutSublayers()

        layer.prepareSungOpacity()
        let row = try XCTUnwrap(layer.rows.first)
        XCTAssertTrue(row.syllables.allSatisfy { $0.sung?.frame == $0.base.frame })
        layer.cancelSungPreparation()
        XCTAssertFalse(row.hasSungLayers)
        XCTAssertTrue(row.syllables.allSatisfy { $0.sung == nil })

        // 选中状态下重排：新行直接带着亮字建。
        layer.setSelected(true, animated: false)
        layer.updateAppearance(specs: specs(), appearance: nil)
        layer.layoutSublayers()
        let rebuilt = try XCTUnwrap(layer.rows.first)
        XCTAssertFalse(rebuilt === row)
        XCTAssertTrue(rebuilt.hasSungLayers)
        XCTAssertTrue(rebuilt.syllables.allSatisfy { $0.sung?.frame == $0.base.frame })
    }

    /// 换行取消选中或唱完收尾时，`finishRemainingProgress` 立即将渐变遮罩模型宽度推到 `finishedWidth`，
    /// 保证上一行在淡出期间 100% 满高亮，不会停在半截。
    func testFinishRemainingProgressImmediatelyCommitsFullWidthOnDeselect() throws {
        let (controller, visual, _) = makeScrubFixture { 0.5 }
        var line0 = TextLine()
        line0.index = 0
        line0.startTime = 0
        line0.endTime = 2
        line0.text = "测试逐字歌词"
        line0.capabilities = [.gradient, .lift]
        line0.syllables = [
            .init(text: "测试", startTime: 0, endTime: 1),
            .init(text: "逐字歌词", startTime: 1, endTime: 2),
        ]
        var line1 = TextLine()
        line1.index = 1
        line1.startTime = 2
        line1.endTime = 4
        line1.text = "下一句歌词"
        line1.capabilities = [.gradient, .lift]
        line1.syllables = [
            .init(text: "下一句歌词", startTime: 2, endTime: 4),
        ]
        var lyrics = Lyrics()
        lyrics.type = .timedWords
        lyrics.lines = [line0, line1]
        controller.setLyrics(lyrics)

        let view = try XCTUnwrap(visual.lineViews.first)
        let content = try XCTUnwrap(view.lineLayer?.contentLayer as? SBS_TextContentLayer)
        content.bounds = CGRect(x: 0, y: 0, width: 300, height: 60)
        content.layoutSublayers()

        visual.selectLine(line0, animation: nil, deselectingOthers: true, updatesInstrumentalTime: false)
        content.setProgress(0.2, animated: false)

        let row = try XCTUnwrap(content.rows.first)
        let partialWidth = row.gradient.frame.width

        visual.deselectLine(line0)
        let fullWidth = row.gradient.frame.width
        XCTAssertGreaterThan(fullWidth, partialWidth, "取消选中时渐变遮罩模型宽度必须立刻推满到行末")
    }

    // MARK: - 长音词：逐字母抬升 + 辉光

    /// `hello ` 唱 2 秒（长音），`world` 唱 0.5 秒。
    private func makeHeldWordLayer() -> SBS_TextContentLayer {
        var line = TextLine()
        line.text = "hello world"
        line.startTime = 0
        line.endTime = 2.5
        line.capabilities = [.gradient, .lift]
        line.syllables = [
            .init(text: "hello ", startTime: 0, endTime: 2, emphasis: .factor(1)),
            .init(text: "world", startTime: 2, endTime: 2.5),
        ]
        let layer = SBS_TextContentLayer()
        layer.specs = specs()
        layer.setLine(line)
        layer.setSelected(true, animated: false)
        layer.bounds = CGRect(x: 0, y: 0, width: 400, height: 80)
        layer.layoutSublayers()
        return layer
    }

    /// 长音词按字形拆层（尾随空白并进最后一个字形），短词仍是一层。
    func testHeldWordSplitsIntoGlyphLayers() throws {
        let layer = makeHeldWordLayer()
        let row = try XCTUnwrap(layer.rows.first)
        XCTAssertEqual(row.syllables.count, 6)
        XCTAssertEqual(row.unitRanges, [0..<5, 5..<6])
        XCTAssertEqual(row.syllables.map { $0.base.string as? String },
                       ["h", "e", "l", "l", "o ", "world"])

        XCTAssertEqual(row.liftTimes.count, 6)
        XCTAssertEqual(row.liftTimes[0], 0, accuracy: 1e-9)
        for index in 1..<5 {
            XCTAssertGreaterThan(row.liftTimes[index], row.liftTimes[index - 1])
            XCTAssertLessThan(row.liftTimes[index], 2)
        }
        XCTAssertEqual(row.liftTimes[5], 2, accuracy: 1e-9)

        // 字形首尾相接：后一个的左缘就是前一个的左缘 + 字形宽。
        let xs = row.syllables.prefix(5).map(\.base.frame.minX)
        for index in 1..<xs.count { XCTAssertGreaterThan(xs[index], xs[index - 1]) }
        XCTAssertGreaterThan(row.syllables[5].base.frame.minX, xs[4])
    }

    /// 前沿扫到哪个字母哪个字母才抬；倒 seek 回词首之前全部回落。
    func testHeldWordLiftsLetterByLetter() throws {
        let layer = makeHeldWordLayer()
        let row = try XCTUnwrap(layer.rows.first)
        // 建层时进度是 0，首字母的抬升时刻也是 0、已经抬起来了；先退到词首之前再取基准。
        layer.setProgress(-1, animated: false)
        let resting = row.syllables.map(\.base.position.y)
        let lift = specs().syllableLift

        let midpoint = (row.liftTimes[2] + row.liftTimes[3]) / 2
        layer.setProgress(midpoint, animated: false)
        for index in 0...2 {
            XCTAssertEqual(row.syllables[index].base.position.y, resting[index] - lift, accuracy: 1e-6)
        }
        for index in 3..<6 {
            XCTAssertEqual(row.syllables[index].base.position.y, resting[index], accuracy: 1e-6)
        }

        layer.setProgress(-1, animated: false)
        for index in row.syllables.indices {
            XCTAssertEqual(row.syllables[index].base.position.y, resting[index], accuracy: 1e-6)
        }
    }

    /// 中文单字没法再拆：长音照旧一层，但辉光装上了。
    func testHeldChineseCharacterStaysSingleLayer() throws {
        var line = TextLine()
        line.text = "啊啊"
        line.startTime = 0
        line.endTime = 2.5
        line.capabilities = [.gradient, .lift]
        line.syllables = [
            .init(text: "啊", startTime: 0, endTime: 2, emphasis: .factor(1)),
            .init(text: "啊", startTime: 2, endTime: 2.5),
        ]
        let layer = SBS_TextContentLayer()
        layer.specs = specs()
        layer.setLine(line)
        layer.bounds = CGRect(x: 0, y: 0, width: 300, height: 80)
        layer.layoutSublayers()

        let row = try XCTUnwrap(layer.rows.first)
        XCTAssertEqual(row.syllables.count, 2)
        XCTAssertEqual(row.unitRanges, [0..<1, 1..<2])
        XCTAssertEqual(row.syllables[0].base.shadowRadius, specs().glowRadius)
        XCTAssertTrue(row.syllables[0].base.shouldRasterize)
        XCTAssertFalse(row.syllables[1].base.shouldRasterize)
    }

    /// 长音词一开唱，整词的每个字形都起一条奔向满强度的辉光 ramp。
    func testHeldWordGlowsAllGlyphs() throws {
        let layer = makeHeldWordLayer()
        let row = try XCTUnwrap(layer.rows.first)
        layer.setProgress(0.01, animated: true)
        XCTAssertEqual(Set(row.glows.keys), Set(0..<5))
        let full = SBS_TextContentLayer.glowIntensity(factor: 1, specs: specs())
        XCTAssertEqual(full, Float(specs().glowRange.upperBound), accuracy: 1e-6)
        for ramp in row.glows.values { XCTAssertEqual(ramp.to, full, accuracy: 1e-6) }
    }

    // MARK: - 强调辉光（§1.1.1）

    /// 强调时**额外**起一条 `shadowOpacity` 斜坡：与缩放同一相、同一条弹簧。
    ///
    /// [实测] 强调辉光在逐字形循环之前对音节层下发，回调本体只有
    /// `setShadowOpacity:`，所以它只推亮度、不加层。
    func testEmphasisGlowFollowsTheScalePhase() throws {
        let layer = makeHeldWordLayer()
        let row = try XCTUnwrap(layer.rows.first)
        let full = SBS_TextContentLayer.glowIntensity(factor: 1, specs: specs())

        // 开唱那一刻：首字母鼓起来的同时多一条强调辉光；词尾还在排队。
        // 断言落点用 `emphasisGlowResting`（ramp 的目标），不用瞬时值——
        // ramp 是按时钟推的，测试里两帧之间没有真实时间流逝。
        layer.setProgress(0.0, animated: false)
        XCTAssertEqual(try XCTUnwrap(row.emphasisGlowResting[0]), full, accuracy: 1e-6)
        XCTAssertNotNil(row.emphasisGlows[0], "该有一条在飞的 ramp")
        XCTAssertNil(row.emphasisGlowResting[4], "词尾还没轮到，不该起")
        XCTAssertEqual(row.syllables[0].base.transform.m11, 1.14, accuracy: 1e-9)

        // 首字母被收回：辉光目标转为 0，与缩放同相。
        layer.setProgress(1.0, animated: false)
        XCTAssertEqual(try XCTUnwrap(row.emphasisGlowResting[0]), 0, accuracy: 1e-6)
        XCTAssertEqual(row.syllables[0].base.transform.m11, 1, accuracy: 1e-9)

        // 词尾这时才轮到：辉光鼓包跟着缩放一起传到词末。
        XCTAssertEqual(try XCTUnwrap(row.emphasisGlowResting[4]), full, accuracy: 1e-6)
    }

    /// 短词既不复也不额外发光——准入是同一处判据，`emphasisGlows` 里不该有它。
    func testShortWordHasNoEmphasisGlow() throws {
        let layer = makeHeldWordLayer()
        let row = try XCTUnwrap(layer.rows.first)
        for progress in [0.0, 1.0, 2.1, 2.4] {
            layer.setProgress(progress, animated: false)
            XCTAssertNil(row.emphasisGlowResting[5], "\(progress)s：world 不该发光")
            XCTAssertNil(row.emphasisGlows[5], "\(progress)s：world 不该起 ramp")
        }
    }

    /// 两条 ramp 落在**同一个** `shadowOpacity` 上，取和、并被夹到 1。
    func testWordGlowAndEmphasisGlowCompose() throws {
        let layer = makeHeldWordLayer()
        let row = try XCTUnwrap(layer.rows.first)
        let spring = SBS_TextContentLayer.glowSpring(span: 2)
        let full = SBS_TextContentLayer.glowIntensity(factor: 1, specs: specs())

        // 两条都已跑完（`settlingDuration = 0`）：值恒为 `to`，相加落在层上。
        row.glows[0] = .init(from: 0, to: full, spring: spring,
                             settlingDuration: 0, startTime: 0)
        row.emphasisGlows[0] = .init(from: 0, to: full, spring: spring,
                                     settlingDuration: 0, startTime: 0)
        layer.advanceGlowRamps(in: row, now: 1)
        XCTAssertEqual(row.syllables[0].base.shadowOpacity,
                       full * 2, accuracy: 1e-6, "强调是再叠一道，不是替换")
        XCTAssertNil(row.glows[0], "两条都跑完就一起摘")
        XCTAssertNil(row.emphasisGlows[0])

        // 夹到 1：两条都满值时不会溢出。
        row.emphasisGlows[0] = .init(from: 0, to: 1, spring: spring,
                                     settlingDuration: 0, startTime: 0)
        row.glows[0] = .init(from: 0, to: 1, spring: spring,
                             settlingDuration: 0, startTime: 0)
        layer.advanceGlowRamps(in: row, now: 1)
        XCTAssertEqual(row.syllables[0].base.shadowOpacity, 1, accuracy: 1e-6)
    }

    /// 退场时强调辉光必须跟着清掉，否则共用 `shadowOpacity` 会漏一道光。
    func testEmphasisGlowClearedWhenTheLineStopsBeingCurrent() throws {
        let layer = makeHeldWordLayer()
        let row = try XCTUnwrap(layer.rows.first)
        layer.setProgress(0.2, animated: false)
        XCTAssertFalse(row.emphasisGlows.isEmpty)

        layer.setSelected(false, animated: false)
        XCTAssertTrue(row.emphasisGlows.isEmpty)
        XCTAssertTrue(row.emphasisGlowResting.isEmpty)
        XCTAssertEqual(row.syllables[0].base.shadowOpacity, 0, accuracy: 1e-6)
    }

    // MARK: - 放大与高亮同时起

    /// 放大**跟高亮同时**起，不是唱完之后（§1.1 第 9 条）。
    ///
    /// 这条替换掉了 `testGlyphsDoNotScaleWhileStillSinging`——那条是按
    /// 「零点在唱完」的错误模型写的，量的正是本次推翻的结论。
    /// 实测的两条延迟都是纯延迟（`stagger·i` / `span/(n/2) + stagger·i`），
    /// 没有任何 `end` 加法，所以下发时刻（音节成为当前音节那一帧）就是零点。
    func testHeldWordScalesFromTheStartAndShortWordNever() throws {
        let layer = makeHeldWordLayer()          // hello 0…2（5 个字形），world 2…2.5（1 层）
        let row = try XCTUnwrap(layer.rows.first)

        // 开唱即鼓：progress 0 时首字母已经是 1.14，与高亮同一帧。
        layer.setProgress(0.0, animated: false)
        XCTAssertEqual(row.syllables[0].base.transform.m11, 1.14, accuracy: 1e-9)
        XCTAssertEqual(row.syllables[0].sung?.transform.m11 ?? 1, 1.14, accuracy: 1e-9,
                       "亮字与暗底必须同步鼓，否则会露出重影")
        // 词尾字母还在排队（`grow_4 = stagger×4 = 0.64s`），此刻不该动。
        XCTAssertEqual(row.syllables[4].base.transform.m11, 1, accuracy: 1e-9)

        // 短词 `world` 全程不鼓：它没有窗口，`transform` 一次都不碰。
        for progress in [0.0, 1.0, 2.1, 2.4] {
            layer.setProgress(progress, animated: false)
            XCTAssertEqual(row.syllables[5].base.transform.m11, 1, accuracy: 1e-9,
                           "\(progress)s：world 只有 0.5s，不该鼓")
            XCTAssertEqual(row.syllables[5].base.transform.m22, 1, accuracy: 1e-9)
        }
    }

    // MARK: - 悬停底板

    /// 底板：圆角 16、四周外扩 16（以**文字盒**为基准，不是行图层 bounds）、
    /// 透明度 0↔1，文字整块压到 0.85。插在 index 0，永远在内容之下。
    func testHoverPlateGeometryAndLabelAlpha() throws {
        let layer = SyncedLyricsLineLayer()
        layer.specs = specs()
        layer.bounds = CGRect(x: 0, y: 0, width: 300, height: 60)

        layer.setHighlighted(true, animated: false)
        let plate = try XCTUnwrap(layer.backgroundLayer)
        layer.layoutSublayers()

        XCTAssertTrue(layer.sublayers?.first === plate, "底板必须在最底")
        XCTAssertEqual(plate.cornerRadius, layer.specs.highlightViewCornerRadius)
        XCTAssertEqual(plate.opacity, 1, accuracy: 1e-6)
        XCTAssertEqual(layer.containerLayer.opacity,
                       Float(layer.specs.highlightLabelAlpha), accuracy: 1e-6)

        let textBox = layer.bounds.insetBy(dx: SyncedLyricsLineLayer.filterBleed,
                                           dy: SyncedLyricsLineLayer.filterBleed)
        let margin = layer.specs.highlightViewMargin
        XCTAssertEqual(plate.frame, textBox.insetBy(dx: -margin, dy: -margin))

        layer.setHighlighted(false, animated: false)
        XCTAssertEqual(plate.opacity, 0, accuracy: 1e-6)
        XCTAssertEqual(layer.containerLayer.opacity, 1, accuracy: 1e-6)
    }

    /// 状态没变就直接返回，不重建底板也不重起动画。
    func testHighlightIsIdempotent() throws {
        let layer = SyncedLyricsLineLayer()
        layer.specs = specs()
        layer.setHighlighted(false, animated: false)
        XCTAssertNil(layer.backgroundLayer, "值没变时连底板都不该建")
        layer.setHighlighted(true, animated: false)
        let plate = try XCTUnwrap(layer.backgroundLayer)
        layer.setHighlighted(true, animated: false)
        XCTAssertTrue(layer.backgroundLayer === plate)
    }
}
