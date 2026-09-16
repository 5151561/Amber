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
        let playing = makeLayer()
        let base = try XCTUnwrap(playing.rows.first?.syllables[safe: 1]?.base)
        let restingY = base.position.y
        playing.setProgress(0.99, animated: true)
        playing.setProgress(1.01, animated: true)
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
}
