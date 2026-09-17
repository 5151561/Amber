import SwiftUI
import QuartzCore
import CoreText
import XCTest
@testable import Amber

/// 行几何与排版：折行、行距、边缘淡出，以及测量路径上的缓存。
@MainActor
final class LyricsLineGeometryTests: XCTestCase, LyricsKitFixtures {

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

        // 静态档（整份无戳纯文本）没有「当前行」，三种落点档一律让位给
        // `staticTopContentInset`(=22)：整份词从顶部内边距起铺。
        // 两处宿主都传 `.center(rect:)`，少了这一档整窗下首行上方会空出 330。
        specs.renderingMode = .static
        for position in [LyricsSpecs.SelectedLinePosition.top(12),
                         .topRelative(12, cardHeightPercentage: 0),
                         .center(rect: rect)] {
            specs.selectedLinePosition = position
            XCTAssertEqual(LyricsLineGeometry.firstLineY(specs: specs, lineHeight: 40,
                                                         containerHeight: 600),
                           specs.staticTopContentInset)
        }
        XCTAssertEqual(specs.staticTopContentInset, 22)
    }

    /// 边缘淡出只看几何：行被视口切掉多少就淡多少。
    ///
    /// 调用方传的是**呈现层**算出来的上沿（见 `updateLineAlphasForViewportEdges`）——
    /// 间奏展开那条路第一帧就把模型 frame 写成终值、再用叠加动画退回去，
    /// 拿模型值算会让亮度比位置早半秒到位。这条断言只钉算式本身。
    func testEdgeAlphaFollowsHowMuchOfTheLineTheViewportKeeps() {
        let viewport = CGRect(x: 0, y: 100, width: 400, height: 200)   // 100…300
        XCTAssertEqual(LyricsLineGeometry.edgeAlpha(lineMinY: 150, lineHeight: 40,
                                                    viewport: viewport), 1)
        XCTAssertEqual(LyricsLineGeometry.edgeAlpha(lineMinY: 40, lineHeight: 40,
                                                    viewport: viewport), 0)
        XCTAssertEqual(LyricsLineGeometry.edgeAlpha(lineMinY: 320, lineHeight: 40,
                                                    viewport: viewport), 0)
        XCTAssertEqual(LyricsLineGeometry.edgeAlpha(lineMinY: 70, lineHeight: 40,
                                                    viewport: viewport), 0.25, accuracy: 0.0001)
        XCTAssertEqual(LyricsLineGeometry.edgeAlpha(lineMinY: 280, lineHeight: 40,
                                                    viewport: viewport), 0.5, accuracy: 0.0001)
        // 收起态的间奏行是 0 高（§16.1），没有「被切掉多少」可言
        XCTAssertEqual(LyricsLineGeometry.edgeAlpha(lineMinY: 150, lineHeight: 0,
                                                    viewport: viewport), 0)
        // 比视口还高的行：夹在 1，不许超
        XCTAssertEqual(LyricsLineGeometry.edgeAlpha(lineMinY: 50, lineHeight: 400,
                                                    viewport: viewport), 0.5, accuracy: 0.0001)
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

    /// 多行的行高要按**画它的那个引擎**算。
    ///
    /// TextKit 折 3 行的中文报 150（每行 50，按回退到的苹方算），
    /// `CATextLayer`（CoreText）画出来是 174（每行 58.89，按基准字体 SF 算）。
    /// 按 150 建行框就会把最后小半行裁在框外。这条把「测出来的高度装得下画出来的字」
    /// 钉住：**把硬换行那串真画进一张位图，最后一行的墨迹不许碰到底边。**
    ///
    /// 不要改成「比 TextKit 的 usedRect 大多少」之类的比例断言——那是拿系数凑；
    /// 这里验的是画出来到底裁没裁。
    func testMultiLineHeightFitsWhatCoreTextDraws() throws {
        let font = NSFont.systemFont(ofSize: 50, weight: .bold)
        let text = "一天到晚命令王宮裡的裁縫師們，替他做各種不同款式的新衣"
        let width: CGFloat = 645
        let attributes = LyricsTextLayout.attributes(
            for: text, font: font, color: CGColor(gray: 1, alpha: 1))
        let wrapped = LyricsTextLayout.wrap(text, attributes: attributes, width: width)
        XCTAssertGreaterThan(wrapped.fragments.count, 1, "样本必须折出不止一行，否则这条什么都没验")

        let height = LyricsTextLayout.size(text, attributes: attributes, width: width).height
        let layer = CATextLayer()
        layer.contentsScale = 1
        layer.isWrapped = true
        layer.string = LyricsTextLayout.hardWrapped(text, attributes: attributes, width: width)
        layer.frame = CGRect(x: 0, y: 0, width: width, height: height)

        let image = NSImage(size: CGSize(width: width, height: height))
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext { layer.render(in: context) }
        image.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))

        func hasInk(row y: Int) -> Bool {
            stride(from: 0, to: rep.pixelsWide, by: 4).contains {
                (rep.colorAt(x: $0, y: y)?.brightnessComponent ?? 0) > 0.5
            }
        }
        // 底边那一行像素不许有墨：有就说明最后一行正贴着框边被裁。
        XCTAssertFalse(hasInk(row: rep.pixelsHigh - 1))
        // 而且最后一行确实画出来了（不是整行都没画）。
        XCTAssertTrue((0..<rep.pixelsHigh).contains { $0 > rep.pixelsHigh * 2 / 3 && hasInk(row: $0) })
    }

    /// 单行不受上面那条影响：没有「行与行」，两个引擎给的高度本来就一样，
    /// 走的还是 TextKit 那条老路——既有的行距规格一点不动。
    func testSingleLineHeightStaysOnTheTextKitPath() {
        let font = lyricsFont()
        let text = "我们在夜色里唱着歌"
        let width: CGFloat = 645
        let attributes = LyricsTextLayout.attributes(
            for: text, font: font, color: CGColor(gray: 1, alpha: 1))
        let wrapped = LyricsTextLayout.wrap(text, attributes: attributes, width: width)
        XCTAssertEqual(wrapped.fragments.count, 1)
        XCTAssertEqual(LyricsTextLayout.size(text, attributes: attributes, width: width).height,
                       LyricsTextLayout.rasterSafeHeight(wrapped.usedSize.height, font: font))
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

    /// 硬换行那串字**不许进缓存**：同一段文字会被不同的明暗各要一次——
    /// 行几何量它时用白色，落到图层上时用当前行的色——而
    /// `CATextLayer` 拿到属性串之后 `foregroundColor` 就不生效了，
    /// 颜色只能跟着串走。存一份共用的话，副行会永远停在先来那一次的色上
    /// （实机症状：非当前行的译文也一直是满亮的白）。
    func testHardWrappedCarriesEachCallersOwnColor() throws {
        let font = lyricsFont()
        let text = "我们在夜色里唱着无人听见的歌谣直到天亮才肯散场"
        let width: CGFloat = 200

        // 先用白色走一遍——行几何测高就是这么问的，缓存由它填上。
        let measuring = LyricsTextLayout.attributes(
            for: text, font: font, color: CGColor(gray: 1, alpha: 1))
        _ = LyricsTextLayout.size(text, attributes: measuring, width: width)

        // 再用暗色要那串字：拿回来的必须是暗色这一份。
        let dim = CGColor(gray: 1, alpha: 0.175)
        let painting = LyricsTextLayout.attributes(for: text, font: font, color: dim)
        let string = LyricsTextLayout.hardWrapped(text, attributes: painting, width: width)
        let color = try unsafe XCTUnwrap(
            string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(color.cgColor.alpha, 0.175, accuracy: 0.001)
    }

    /// 而高度**要**进缓存：它与颜色无关，且 `size` 被行几何对全表每行调用、
    /// 一次翻行至少两遍，`CTFramesetter` 建一次的开销与 TextKit 折行同量级。
    func testDrawnHeightRidesTheWrapCache() {
        let font = lyricsFont()
        let width: CGFloat = 200

        let multi = "我们在夜色里唱着无人听见的歌谣直到天亮才肯散场"
        let multiAttributes = LyricsTextLayout.attributes(
            for: multi, font: font, color: CGColor(gray: 1, alpha: 1))
        let wrappedMulti = LyricsTextLayout.wrap(multi, attributes: multiAttributes, width: width)
        XCTAssertGreaterThan(wrappedMulti.fragments.count, 1)
        XCTAssertGreaterThan(wrappedMulti.drawnHeight, wrappedMulti.usedSize.height,
                             "多行：CoreText 排得比 TextKit 高，这个差就是会被裁掉的那截")
        XCTAssertEqual(
            LyricsTextLayout.size(multi, attributes: multiAttributes, width: width).height,
            LyricsTextLayout.rasterSafeHeight(wrappedMulti.drawnHeight, font: font))

        // 单行不改口径，仍是 TextKit 那份——既有的行距规格一点不动。
        let single = "我们在夜色里唱着歌"
        let singleAttributes = LyricsTextLayout.attributes(
            for: single, font: font, color: CGColor(gray: 1, alpha: 1))
        let wrappedSingle = LyricsTextLayout.wrap(single, attributes: singleAttributes, width: 645)
        XCTAssertEqual(wrappedSingle.fragments.count, 1)
        XCTAssertEqual(wrappedSingle.drawnHeight, wrappedSingle.usedSize.height)
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

    /// 对唱翻转侧的行在行盒里顶右；普通行贴左（行盒右缘本来就压在栏右缘）。
    func testFlippedRowIsFlushRight() {
        let x = { (isFlipped: Bool, rowWidth: CGFloat) in
            SBS_TextContentLayer.rowOriginX(rowWidth: rowWidth, boxWidth: 510, isFlipped: isFlipped)
        }
        XCTAssertEqual(x(false, 200), 0)
        XCTAssertEqual(x(false, 510), 0)
        XCTAssertEqual(x(true, 200), 310)   // 510 − 200
        XCTAssertEqual(x(true, 510), 0)
        // 墨迹比盒子还宽（测量与渲染差一点）时不许倒着挪
        XCTAssertEqual(x(true, 560), 0)
    }

    /// ★ 顶右与「从右往左扫」是两件事：翻转侧仍从左往右唱。
    func testFlippedLineStillSweepsLeftToRight() {
        var flipped = TextLine()
        flipped.agentAlignment = .flipped
        XCTAssertEqual(flipped.direction, .leftToRight)

        var rtl = TextLine()
        rtl.direction = .rightToLeft
        XCTAssertEqual(rtl.agentAlignment, .normal, "书写方向不该顺带把行推到右栏去")
    }

    /// 解析 → 适配 → 几何：对唱行一路走到行宽收窄那一档
    func testDuetLineIsVocalGroupEndToEnd() {
        let lrc = """
        [00:00.00]甲：
        [00:02.00]甲唱的
        [00:06.00]乙：
        [00:08.00]乙唱的
        """
        let lyrics = LyricsAdapter.makeLyrics(from: LyricParser.parse(lrc))
        XCTAssertEqual(lyrics.vocalistsType, .duet)
        let texts = lyrics.lines.compactMap { $0 as? TextLine }
        XCTAssertEqual(texts.map(\.text), ["甲唱的", "乙唱的"])
        XCTAssertFalse(LyricsLineGeometry.isVocalGroup(texts[0]))
        XCTAssertTrue(LyricsLineGeometry.isVocalGroup(texts[1]))
        XCTAssertEqual(LyricsLineGeometry.lineAlignment(agent: texts[1].agentAlignment,
                                                        textAlignment: nil), .flipped)
    }

    /// 可用宽度 = documentView 宽 − 左右边距；[PX] 实测 margins ≈ 0。
    func testAvailableWidthSubtractsMargins() {
        XCTAssertEqual(LyricsLineGeometry.availableWidth(documentWidth: 683,
                                                         margins: NSEdgeInsets()), 683)
        XCTAssertEqual(LyricsLineGeometry.availableWidth(
            documentWidth: 683,
            margins: NSEdgeInsets(top: 0, left: 19, bottom: 0, right: 19)), 645)
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
                        unsafe CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
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
}
