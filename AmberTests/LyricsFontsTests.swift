import SwiftUI
import QuartzCore
import CoreText
import XCTest
@testable import Amber

/// 副行字体：TextStyles 那一链、四档缩放，以及「更大字体」两档。
@MainActor
final class LyricsFontsTests: XCTestCase, LyricsKitFixtures {

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
}


// MARK: - 「更大字体」从设置到行视图的整条路

/// 设置 › 通用 ›「更大字体」是**歌词与发音同屏时谁更大**，与译文无关。
///
/// 这一组走的是真实宿主路径：`AppSettings.shared` → `SyncedLyricsView`
/// （`NSHostingView` 里的 representable）→`SyncedLyricsViewController.setLyrics`
/// → 行视图的内容层，最后读内容层真正拿去排版的那两个字体。
/// 单测 spec 那一层（上面 `LyricsFontsTests` 里那几条）过不了这一关：
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
}
