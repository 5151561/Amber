import XCTest
@testable import Amber

/// 「发音贴在字底下」的块切分。数据是从 QQ 实拉的（a子《モナリザ》）。
final class RubyLayoutTests: XCTestCase {

    private func blocks(_ qrc: String, roma: String) -> [RubyLayout.Block] {
        let lines = LyricParser.parse(qrc, transliteration: roma)
            .filter { $0.kind == .lyric }
        guard let line = lines.first else { return [] }
        let syllables = line.syllables.map {
            TextLine.SyllableTiming(text: $0.text, startTime: $0.time, endTime: $0.end,
                                    transliteration: $0.transliteration)
        }
        return RubyLayout.blocks(text: line.text, syllables: syllables, specs: LyricsSpecs())
    }

    /// 建一个内容层，喂进这行歌词，返回它的折行结果。
    private func rows(_ qrc: String, roma: String, width: CGFloat)
        -> [SBS_TextContentLayer.RubyRow] {
        guard let parsed = LyricParser.parse(qrc, transliteration: roma)
            .first(where: { $0.kind == .lyric }) else { return [] }
        var line = TextLine()
        line.text = parsed.text
        line.syllables = parsed.syllables.map {
            TextLine.SyllableTiming(text: $0.text, startTime: $0.time, endTime: $0.end,
                                    transliteration: $0.transliteration)
        }
        let layer = SBS_TextContentLayer()
        layer.updateAppearance(specs: LyricsSpecs(), appearance: nil)
        layer.setLine(line)
        return layer.rubyRows(width: width)
    }

    private static let line =
        "[16917,3025]ハ(16917,160)イ(17077,152)ウ(17229,104)ェ(17333,104)イ(17437,104)"
        + "が(17541,199)伸(17740,209)び(17949,208)る(18157,124)こ(18281,248)の(18529,196)"
        + "街(18933,585)で(19518,424)"
    private static let roma =
        "[16917,3025]ha (16917,160)i (17077,152)e (17229,103)i (17437,104)ga (17541,199)"
        + "no (17740,209)bi (17949,208)ru (18157,124)ko (18281,248)no (18529,196)"
        + "ma (18933,208)chi (19141,377)de (19518,424)"

    /// 切出来的块拼回去必须等于原文，一个字都不能丢——块之外的字符不渲染。
    func testBlocksCoverWholeLine() {
        let blocks = blocks(Self.line, roma: Self.roma)
        XCTAssertFalse(blocks.isEmpty)
        XCTAssertEqual(blocks.map(\.text).joined(), "ハイウェイが伸びるこの街で")
    }

    /// 成块的粒度是词，不是音节：13 个音节切出来的块要明显少于 13。
    func testBlocksAreWordsNotSyllables() {
        let blocks = blocks(Self.line, roma: Self.roma)
        XCTAssertGreaterThan(blocks.count, 1)
        XCTAssertLessThan(blocks.count, 13)
        XCTAssertEqual(blocks.map { $0.syllables.count }.reduce(0, +), 13)
    }

    /// 块的发音 = 块内各音节的发音顺次拼接；没注上音的那一拍（`ェ`）自然被跳过。
    func testBlockRubyConcatenatesSyllables() {
        let blocks = blocks(Self.line, roma: Self.roma)
        XCTAssertEqual(blocks.map(\.ruby).joined(), "haieiganobirukonomachide")
        // 「街」那个字的 machi 必须整个落在它自己那一块里，不能被切开。
        let machi = blocks.first { $0.text.contains("街") }
        XCTAssertNotNil(machi)
        XCTAssertTrue(machi?.ruby.contains("machi") == true)
    }

    /// 块宽取正文与发音里宽的那个——「发音比字宽就把后面顶开」全靠它。
    func testAdvanceTakesTheWiderSide() {
        let blocks = blocks(Self.line, roma: Self.roma)
        for block in blocks {
            XCTAssertEqual(block.advance, max(block.textWidth, block.rubyWidth))
            XCTAssertGreaterThan(block.textWidth, 0)
        }
        // 块内音节的局部 x 是递增的，且不超出块宽。
        for block in blocks {
            var cursor: CGFloat = -1
            for syllable in block.syllables {
                XCTAssertGreaterThan(syllable.minX, cursor)
                cursor = syllable.minX
                XCTAssertLessThanOrEqual(syllable.minX + syllable.width,
                                         block.textWidth + 0.5)
            }
        }
    }

    /// 分词给的是形态素，「なかった」会断在「なかっ」+「た」——促音收不了尾，
    /// 真按这个断点成块，发音会排成 `nakat ta`。同块拼接才是 `nakatta`。
    func testGeminateStaysInOneBlock() {
        let line = "[20074,3260]乗(20987,200)っ(21187,200)た(21387,415)"
        let roma = "[20074,3260]no (20987,200)'t (21187,200)ta (21387,415)"
        let result = blocks(line, roma: roma)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "乗った")
        XCTAssertEqual(result[0].ruby, "notta")
    }

    /// 分词器的词典里没有「モナリザ」，会切成「モナ」+「リザ」——片假名连写是
    /// 一个外来语词，断开的话发音排成 `mona riza`。
    func testKatakanaRunStaysInOneBlock() {
        let line = "[0,3000]モ(0,500)ナ(500,500)リ(1000,500)ザ(1500,500)"
        let roma = "[0,3000]mo (0,500)na (500,500)ri (1000,500)za (1500,500)"
        let result = blocks(line, roma: roma)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].ruby, "monariza")
    }

    /// 实拉的一行：分词是 もう|いっぱい|ある|けど，块也该是这四个。
    func testRealLineBlockSplit() {
        let line = "[38028,5288]も(38028,776)う(38804,776)い(39580,252)っ(39833,252)"
            + "ぱ(40085,199)い(40284,328)あ(40612,523)る(41135,245)け(41380,688)ど(42068,1248)"
        let roma = "[38027,5288]mo (38027,776)u (38804,776)i (39580,252)'p (39832,252)"
            + "pa (40084,199)i (40284,327)a (40611,522)ru (41134,245)ke (41380,687)do (42068,1248)"
        let result = blocks(line, roma: roma)
        XCTAssertEqual(result.map(\.text), ["もう", "いっぱい", "ある", "けど"])
        XCTAssertEqual(result.map(\.ruby), ["mou", "ippai", "aru", "kedo"])
    }

    /// 「を(30404,**20**)」只有 20ms 长。对齐若带容差，容差一旦大过这 20ms
    /// 就会把下一拍的 `mi` 抢过来，排成 `womi`。
    func testShortSyllableKeepsItsOwnReading() {
        let line = "[29374,1794]を(30404,20)見(30424,473)た(30897,207)"
        let roma = "[29374,1794]wo (30404,20)mi (30424,473)ta (30897,207)"
        XCTAssertEqual(blocks(line, roma: roma).map(\.ruby).joined(), "womita")
    }

    /// Beautiful World 1:33 那行：`け(97173,1600) (98773,**0**)叶(98773,842)`——
    /// 零时长的空格音节与「叶」时间戳完全相同，roma 那边也有两项同为 98773。
    /// 平手一律不前进的话，「叶」之后整个后半行都注不上音。
    func testZeroLengthSpaceDoesNotStallAlignment() {
        let line = "[92813,8520]け(97173,1600) (98773,0)叶(98773,842)う(99615,382)"
            + "な(99997,608)ら(100605,408)"
        let roma = "[92813,8519]ke (97172,1600)  (98773,0)ka (98773,319)na (99093,521)"
            + "u (99614,382)na (99997,608)ra (100605,407)"
        let result = blocks(line, roma: roma)
        XCTAssertEqual(result.map(\.ruby).joined(), "kekanaunara")
        // 「叶う」= かなう：「叶」吃 ka+na，「う」吃 u。
        XCTAssertTrue(result.contains { $0.text.contains("叶") && $0.ruby.contains("kana") })
    }

    /// `transliterationMinWordSpacing` 是**发音之间**的最小间距，不是块之间的
    /// 恒定间距。当成恒定间距的话，这行八个块凭空多出 35pt，
    /// Apple Music 一行放得下的句子在我们这儿会被挤成两行。
    func testNarrowReadingsKeepTextTight() {
        let line = "[92813,8520]も(92813,640)し(93453,424)も(93877,448)願(94325,672)"
            + "い(94997,483)一(95480,917)つ(96397,219)だ(96616,557)け(97173,1600)"
            + " (98773,0)叶(98773,842)う(99615,382)な(99997,608)ら(100605,408)"
        let roma = "[92813,8519]mo (92813,639)shi (93453,423)mo (93876,447)ne (94324,257)"
            + "ga (94582,415)i (94997,483)hi (95480,467)to (95947,449)tsu (96397,218)"
            + "da (96615,556)ke (97172,1600)  (98773,0)ka (98773,319)na (99093,521)"
            + "u (99614,382)na (99997,608)ra (100605,407)"
        let parts = blocks(line, roma: roma)
        let tight = parts.map(\.textWidth).reduce(0, +)
        let laid = rows(line, roma: roma, width: 10_000)

        XCTAssertEqual(laid.count, 1)
        // 正文该紧排：读法多数比它底下的字窄，个别块（`tsu`、`shi` 这种三四个
        // 字母的）会把自己那一块顶宽一点，但**绝不该多出「块间距 × 块数」**——
        // 那是把 `transliterationMinWordSpacing` 当成恒定块间距的那种排法。
        let spacing = LyricsSpecs().transliterationMinWordSpacing
        XCTAssertGreaterThan(parts.count, 4)
        XCTAssertLessThan(laid[0].width, tight + spacing * Double(parts.count - 1))
    }

    /// 没有音节级发音就不成块，调用方退回原来那条 TextKit 排版。
    func testNoSyllableTransliterationMeansNoBlocks() {
        let plain = "[16917,3025]ハ(16917,160)イ(17077,152)街(18933,585)"
        XCTAssertTrue(blocks(plain, roma: "[00:16.91]haistreet").isEmpty)
    }
}
