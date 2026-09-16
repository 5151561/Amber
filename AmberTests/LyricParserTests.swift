import XCTest
@testable import Amber

final class LyricParserTests: XCTestCase {

    /// 只取正文行，方便断言时忽略间奏与尾部创作者
    private func lyricLines(_ lines: [LyricLine]) -> [LyricLine] {
        lines.filter { $0.kind == .lyric }
    }

    // MARK: - 时间戳

    func testBasicLRC() {
        let lrc = """
        [ti:标题]
        [ar:歌手]
        [00:10.50]第一行
        [00:20.00]第二行
        """
        let lines = lyricLines(LyricParser.parse(lrc))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].time, 10.5, accuracy: 0.001)
        XCTAssertEqual(lines[0].text, "第一行")
        XCTAssertEqual(lines[1].time, 20.0, accuracy: 0.001)
    }

    func testMultipleTimestampsPerLine() {
        let lrc = "[00:12.00][00:34.50]重复段落"
        let lines = lyricLines(LyricParser.parse(lrc))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].time, 12.0, accuracy: 0.001)
        XCTAssertEqual(lines[1].time, 34.5, accuracy: 0.001)
        XCTAssertEqual(lines[0].text, "重复段落")
    }

    func testUnsortedInputIsSorted() {
        let lrc = """
        [00:30.00]第三行
        [00:10.00]第一行
        [00:20.00]第二行
        """
        let lines = lyricLines(LyricParser.parse(lrc))
        XCTAssertEqual(lines.map(\.text), ["第一行", "第二行", "第三行"])
    }

    func testMinuteOverflowHandled() {
        let lrc = "[01:05.00]一分零五秒"
        let lines = lyricLines(LyricParser.parse(lrc))
        XCTAssertEqual(lines[0].time, 65.0, accuracy: 0.001)
    }

    func testFractionDigits() {
        let lrc = """
        [00:01.5]一位小数
        [00:02.500]三位小数
        """
        let lines = lyricLines(LyricParser.parse(lrc))
        XCTAssertEqual(lines[0].time, 1.5, accuracy: 0.001)
        XCTAssertEqual(lines[1].time, 2.5, accuracy: 0.001)
    }

    func testTranslationMergedByTime() {
        let lrc = """
        [00:10.00]Hello
        [00:20.00]World
        """
        let translation = """
        [00:10.20]你好
        [00:20.10]世界
        """
        let lines = lyricLines(LyricParser.parse(lrc, translation: translation))
        XCTAssertEqual(lines[0].translation, "你好")
        XCTAssertEqual(lines[1].translation, "世界")
    }

    func testTransliterationMergedByTime() {
        let lrc = """
        [00:10.00]AAA
        [00:20.00]BBB
        """
        let roma = """
        [00:10.20]aaa
        [00:20.10]bbb
        """
        let lines = lyricLines(LyricParser.parse(lrc, transliteration: roma))
        XCTAssertEqual(lines[0].transliteration, "aaa")
        XCTAssertEqual(lines[1].transliteration, "bbb")
        XCTAssertNil(lines[0].translation)
    }

    /// 译文与发音各走各的，互不顶替。
    func testTranslationAndTransliterationCoexist() {
        let lrc = "[00:10.00]AAA"
        let lines = lyricLines(LyricParser.parse(lrc,
                                                 translation: "[00:10.00]TTT",
                                                 transliteration: "[00:10.00]rrr"))
        XCTAssertEqual(lines[0].translation, "TTT")
        XCTAssertEqual(lines[0].transliteration, "rrr")
    }

    // MARK: - 发音落到音节上
    //
    // 下面几条的数据是从 QQ 实拉的（a子《モナリザ》），不是编的：roma 与正文
    // 同一套时间戳，只是切得更细。

    private static let realLine =
        "[16917,3025]ハ(16917,160)イ(17077,152)ウ(17229,104)ェ(17333,104)イ(17437,104)"
        + "が(17541,199)伸(17740,209)び(17949,208)る(18157,124)こ(18281,248)の(18529,196)"
        + "街(18933,585)で(19518,424)"
    private static let realRoma =
        "[16917,3025]ha (16917,160)i (17077,152)e (17229,103)i (17437,104)ga (17541,199)"
        + "no (17740,209)bi (17949,208)ru (18157,124)ko (18281,248)no (18529,196)"
        + "ma (18933,208)chi (19141,377)de (19518,424)"

    /// 一个汉字对上好几个罗马音音节：`街(18933,585)` 收下 `ma(18933)` 与 `chi(19141)`。
    func testTransliterationAttachesToSyllables() {
        let lines = lyricLines(LyricParser.parse(Self.realLine,
                                                 transliteration: Self.realRoma))
        let syllables = lines[0].syllables
        XCTAssertEqual(syllables.count, 13)
        XCTAssertEqual(syllables[11].text, "街")
        XCTAssertEqual(syllables[11].transliteration, "machi")
        XCTAssertEqual(syllables[0].transliteration, "ha")
        XCTAssertEqual(syllables[12].transliteration, "de")
        // 落到音节上之后整行那条副行就撤了，不然同一份发音要写两遍。
        XCTAssertNil(lines[0].transliteration)
    }

    /// 拗音的后半拍（`ェ`）在 roma 里是并进前一拍的，它自己没有对应音节——
    /// 这很常见，不该让整行的发音都作废。
    func testTransliterationToleratesUnmatchedSmallKana() {
        let lines = lyricLines(LyricParser.parse(Self.realLine,
                                                 transliteration: Self.realRoma))
        XCTAssertEqual(lines[0].syllables[3].text, "ェ")
        XCTAssertNil(lines[0].syllables[3].transliteration)
        XCTAssertEqual(lines[0].syllables[2].transliteration, "e")
    }

    /// 促音那一拍 QQ 给的是前置撇号的 `'t`——撇号是「辅音接到下一拍开头」的标记，
    /// 不是罗马字。留着会排出 `no't ta`。
    func testGeminateApostropheStripped() {
        let line = "[20074,3260]乗(20987,200)っ(21187,200)た(21387,415)"
        let roma = "[20074,3260]no (20987,200)'t (21187,200)ta (21387,415)"
        let lines = lyricLines(LyricParser.parse(line, transliteration: roma))
        XCTAssertEqual(lines[0].syllables.map(\.transliteration), ["no", "t", "ta"])
    }

    /// QQ 的 roma / trans 里有 `[119759,1248](119759,1248)` 这种「有时间、没文字」的
    /// 占位行。以前会把整个 body 当文字兜底，于是时间标记本身被排上屏。
    func testEmptySyllableLineIsDropped() {
        let line = "[119000,2000]Oh(119000,2000)"
        let roma = "[119759,1248](119759,1248)"
        let lines = lyricLines(LyricParser.parse(line, transliteration: roma))
        XCTAssertEqual(lines[0].text, "Oh")
        XCTAssertNil(lines[0].transliteration)
    }

    /// 「这一行没有译文」QQ 给的是 `//`，不是空串。
    func testSlashPlaceholderIsDropped() {
        let lines = lyricLines(LyricParser.parse("[00:10.00]Oh",
                                                 translation: "[00:10.00]//",
                                                 transliteration: "[00:10.00]/"))
        XCTAssertNil(lines[0].translation)
        XCTAssertNil(lines[0].transliteration)
    }

    /// 发音落到音节上之后整行那条会撤掉——菜单「显示发音」的可用性判据
    /// 不能只认整行那条，不然发音明明有，菜单项却是灰的。
    func testHasTransliterationSeesSyllableLevel() {
        let lines = LyricParser.parse(Self.realLine, transliteration: Self.realRoma)
        XCTAssertNil(lyricLines(lines)[0].transliteration)
        XCTAssertTrue(lines.hasTransliteration)
    }

    /// 歌手提示行（`G-DRAGON：`）与下一句只差 0.546 秒。各行独立「找最近的一条」
    /// 时它会把下一句的译文抢过来，两行显示同一句译文。
    func testAgentLineDoesNotStealNextLineSecondaries() {
        let lyric = """
        [54748,546]G-DRAGON：(54748,546)
        [55294,2000]총 (55294,500)맞은 (55794,700)것처럼(56494,800)
        """
        let trans = """
        [00:54.74]//
        [00:55.29]好似被中枪一般
        """
        let roma = """
        [54748,546] (54748,546)
        [55294,2000]chong (55294,500)ma jeun (55794,700)geot cheo reom(56494,800)
        """
        let lines = lyricLines(LyricParser.parse(lyric, translation: trans, transliteration: roma))
        XCTAssertEqual(lines.count, 2)
        XCTAssertNil(lines[0].translation)
        XCTAssertNil(lines[0].transliteration)
        XCTAssertTrue(lines[0].syllables.allSatisfy { $0.transliteration == nil })
        XCTAssertEqual(lines[1].translation, "好似被中枪一般")
    }

    /// 副行的占位行要留着占位：丢掉的话后面每一行都可能去认领上一条。
    func testPlaceholderLinesStillAlign() {
        let lyric = "[1000,500]A(1000,500)\n[1600,500]B(1600,500)"
        let lines = lyricLines(LyricParser.parse(
            lyric, translation: "[00:01.00]//\n[00:01.60]乙"))
        XCTAssertNil(lines[0].translation)
        XCTAssertEqual(lines[1].translation, "乙")
    }

    /// 拉丁正文不注音：底下再写一遍一模一样的东西没有意义。
    func testLatinLyricsGetNoTransliteration() {
        let lrc = "[52664,2764]I (52664,130)am (52794,147)a (52941,267)villain (53208,581)"
        let roma = "[52664,2764]I (52664,130)am (52794,147)a (52941,267)villain (53208,581)"
        let lines = lyricLines(LyricParser.parse(lrc, transliteration: roma))
        XCTAssertTrue(lines[0].syllables.allSatisfy { $0.transliteration == nil })
        // 归不进去就退回整行那条副行。
        XCTAssertNotNil(lines[0].transliteration)
    }

    /// roma 与正文根本不是同一首（时间全错）：覆盖率过不了，退回整行副行。
    func testMismatchedTransliterationFallsBackToWholeLine() {
        let lrc = "[10000,3000]ハ(10000,500)イ(10500,500)街(11000,500)で(11500,500)"
        let roma = "[10000,3000]xx (10000,3000)"
        let lines = lyricLines(LyricParser.parse(lrc, transliteration: roma))
        XCTAssertTrue(lines[0].syllables.allSatisfy { $0.transliteration == nil })
        XCTAssertEqual(lines[0].transliteration, "xx")
    }

    /// 只有一边有内容时，另一边保持 nil——菜单那两项的置灰就靠这个判据。
    func testMissingTransliterationStaysNil() {
        let lines = lyricLines(LyricParser.parse("[00:10.00]AAA",
                                                 translation: "[00:10.00]TTT"))
        XCTAssertEqual(lines[0].translation, "TTT")
        XCTAssertNil(lines[0].transliteration)
        XCTAssertTrue(lines.hasTranslation)
        XCTAssertFalse(lines.hasTransliteration)
    }

    func testEmptyInput() {
        XCTAssertEqual(LyricParser.parse(""), [])
        XCTAssertEqual(LyricParser.parse("[ti:只有元数据]"), [])
    }

    func testMetadataLinesIgnored() {
        let lrc = """
        [ti:歌名]
        [offset:500]
        [00:05.00]正文
        """
        let lines = lyricLines(LyricParser.parse(lrc))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "正文")
    }

    // MARK: - 逐字（QRC）

    func testQRCSyllables() {
        let qrc = "[10000,2000]故(10000,400)事(10400,400)的(10800,400)小(11200,400)黄(11600,400)花(12000,400)"
        let lines = lyricLines(LyricParser.parse(qrc))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "故事的小黄花")
        XCTAssertEqual(lines[0].time, 10.0, accuracy: 0.001)
        XCTAssertEqual(lines[0].end, 12.0, accuracy: 0.001)
        XCTAssertEqual(lines[0].syllables.count, 6)
        XCTAssertEqual(lines[0].syllables[0].text, "故")
        XCTAssertEqual(lines[0].syllables[1].time, 10.4, accuracy: 0.001)
        XCTAssertEqual(lines[0].syllables[1].duration, 0.4, accuracy: 0.001)
    }

    /// LRC 行里混进逐字括号时没有可靠的绝对时间，只取文字、不造音节
    func testQRCInlineTagsInLRCLineKeepTextOnly() {
        let lrc = "[00:15.20]每(500,100)个(500,100)字(500,100)带(500,100)标(500,100)记"
        let lines = lyricLines(LyricParser.parse(lrc))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "每个字带标记")
        XCTAssertTrue(lines[0].syllables.isEmpty)
    }

    /// 音节时间轴不单调就整行退回，不要半吊子的逐字
    func testNonMonotonicSyllablesFallBackToWholeLine() {
        let qrc = "[10000,2000]乱(11000,400)序(10000,400)"
        let lines = lyricLines(LyricParser.parse(qrc))
        XCTAssertEqual(lines[0].text, "乱序")
        XCTAssertTrue(lines[0].syllables.isEmpty)
    }

    // MARK: - 逐字（YRC，网易）

    /// 网易把音节时间戳写在字**前面**，QQ 写在字后面；同一条解析路要认两种。
    func testYRCSyllables() {
        let yrc = "[10000,1200](10000,300,0)孤(10300,300,0)勇(10600,300,0)者(10900,300,0)！"
        let lines = lyricLines(LyricParser.parse(yrc))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "孤勇者！")
        XCTAssertEqual(lines[0].time, 10.0, accuracy: 0.001)
        XCTAssertEqual(lines[0].end, 11.2, accuracy: 0.001)
        XCTAssertEqual(lines[0].syllables.count, 4)
        XCTAssertEqual(lines[0].syllables[0].text, "孤")
        XCTAssertEqual(lines[0].syllables[1].time, 10.3, accuracy: 0.001)
        XCTAssertEqual(lines[0].syllables[1].duration, 0.3, accuracy: 0.001)
    }

    /// YRC 的正文与 `ytlrc` / `yromalrc` 同源，副行照旧按时间认领
    func testYRCSecondariesAttach() {
        let yrc = "[10000,600](10000,300,0)明(10300,300,0)天"
        let ytlrc = "[10000,600](10000,600,0)tomorrow"
        let lines = lyricLines(LyricParser.parse(yrc, translation: ytlrc))
        XCTAssertEqual(lines[0].text, "明天")
        XCTAssertEqual(lines[0].translation, "tomorrow")
    }

    /// 网易的制作人信息是 JSON 行，不是歌词：整块摘掉，但词曲要进尾部「创作者」
    func testNeteaseJSONCreditLinesStripped() {
        let yrc = """
        {"t":0,"c":[{"tx":"作词: "},{"tx":"唐恬","li":"http://p1.music.126.net/x.jpg","or":"orpheus://nm/artist/home?id=1"}]}
        {"t":0,"c":[{"tx":"作曲: "},{"tx":"钱雷"}]}
        {"t":0,"c":[{"tx":"人声录音室: "},{"tx":"雅旺录音室"}]}
        [10000,600](10000,600,0)爱你孤身走暗巷
        """
        let lines = LyricParser.parse(yrc)
        XCTAssertEqual(lyricLines(lines).map(\.text), ["爱你孤身走暗巷"])
        XCTAssertEqual(lines.filter { $0.kind == .credits }.map(\.text), ["创作者：唐恬、钱雷"])
    }

    // MARK: - 创作者

    func testLeadingCreditsStrippedAndAppendedAtEnd() {
        let lrc = """
        [00:00.00]晴天 - 周杰伦 (Jay Chou)
        [00:02.25]词：周杰伦
        [00:04.50]曲：周杰伦
        [00:06.75]编曲：钟兴民
        [00:09.00]制作人：周杰伦
        [00:29.26]故事的小黄花
        [00:32.71]从出生那年就飘着
        """
        let lines = LyricParser.parse(lrc)
        XCTAssertEqual(lyricLines(lines).map(\.text), ["故事的小黄花", "从出生那年就飘着"])

        let credits = lines.filter { $0.kind == .credits }
        XCTAssertEqual(credits.count, 1)
        // Music 只出一行「创作者」：词在前、曲在后，词曲同一个人不重复，编曲与制作人不展示
        XCTAssertEqual(credits[0].text, "创作者：周杰伦")
        XCTAssertEqual(credits[0].index, lines.count - 1, "创作者必须挂在最尾部")
    }

    /// 词曲不是同一个人就并列；一栏里挂了多个人也拆开
    func testCreditsJoinLyricistAndComposer() {
        let lrc = """
        [00:02.25]词：林夕/黄伟文
        [00:04.50]曲：陈奕迅
        [00:29.26]正文
        """
        let credits = LyricParser.parse(lrc).filter { $0.kind == .credits }
        XCTAssertEqual(credits.map(\.text), ["创作者：林夕、黄伟文、陈奕迅"])
    }

    /// `编曲` 不能被 `曲` 命中
    func testArrangerIsNotComposer() {
        let lrc = """
        [00:00.00]编曲：钟兴民
        [00:20.00]正文
        """
        let credits = LyricParser.parse(lrc).filter { $0.kind == .credits }
        XCTAssertTrue(credits.isEmpty)
    }

    /// 制作表整块都得摘干净：中英对照的角色名、没收录的角色名、OP/SP 一个都不许排上屏
    func testBilingualAndUncoveredCreditRolesStripped() {
        let lrc = """
        [00:00.00]词：某某
        [00:01.00]弦乐编写：林一凡
        [00:02.00]录音混音：刘森（WoWooo studio）
        [00:03.00]母带：刘英（刘英音乐工作室）
        [00:04.00]OP：步虚工作室
        [00:05.00]SP：为音乐
        [00:06.00]制作人 Producer：黄乐乐
        [00:07.00]编曲 Arranger：黄乐乐
        [00:08.00]吉他 Guitar：黄乐乐
        [00:09.00]和声Backing Vocal：黄乐乐
        [00:10.00]录音师 Recording Engineer：黄乐乐
        [00:11.00]混音 Mixing：黄乐乐
        [00:12.00]母带处理 Mastering：黄乐乐
        [00:13.00]音乐企划 Creative Planning：唐勇
        [00:14.00]封面设计 Cover Designer：曾昭玮
        [00:15.00]推广 Marketing：为音乐
        [00:30.00]正文第一句
        """
        let lines = LyricParser.parse(lrc)
        XCTAssertEqual(lyricLines(lines).map(\.text), ["正文第一句"])
        XCTAssertEqual(lines.filter { $0.kind == .credits }.map(\.text), ["创作者：某某"])
    }

    /// 角色名列不完：认不出的那条夹在块中间时，靠后面认得出的那条一起带走
    func testUnknownRoleInsideCreditBlockIsStripped() {
        let lrc = """
        [00:00.00]词：甲
        [00:01.00]灵感来源：乙
        [00:02.00]OP：丙
        [00:20.00]正文
        """
        XCTAssertEqual(lyricLines(LyricParser.parse(lrc)).map(\.text), ["正文"])
    }

    /// 「中文 + 英文」只在制作表内部算角色名：开头的双语歌手提示行是正文
    func testBilingualSpeakerLineIsNotCredit() {
        let lrc = """
        [00:00.00]权志龙 G-DRAGON：Let's go
        [00:04.00]第二句
        """
        XCTAssertEqual(lyricLines(LyricParser.parse(lrc)).map(\.text),
                       ["权志龙 G-DRAGON：Let's go", "第二句"])
    }

    /// 正文里的「XX：YY」不能被当成创作者摘掉
    func testColonInsideBodyIsNotTreatedAsCredit() {
        let lrc = """
        [00:00.00]词：某人
        [00:10.00]第一句
        [00:14.00]他说：我不走了
        """
        let lines = lyricLines(LyricParser.parse(lrc))
        XCTAssertEqual(lines.map(\.text), ["第一句", "他说：我不走了"])
    }

    // MARK: - 间奏

    func testLongIntroBecomesInterlude() {
        let lrc = """
        [00:00.00]晴天 - 周杰伦
        [00:02.25]词：周杰伦
        [00:29.26]故事的小黄花
        """
        let lines = LyricParser.parse(lrc)
        XCTAssertEqual(lines[0].kind, .interlude, "摘掉创作者后开头的长前奏要变成三个点")
        XCTAssertEqual(lines[0].time, 0, accuracy: 0.001)
        XCTAssertEqual(lines[0].end, 29.26, accuracy: 0.001)
    }

    func testLongGapBetweenLinesBecomesInterlude() {
        // 首句落在 2 秒，短于间奏门槛，开头不会另插一行
        let lrc = """
        [00:02.00]上半段最后一句
        [01:00.00]下半段第一句
        """
        let lines = LyricParser.parse(lrc)
        XCTAssertEqual(lines.map(\.kind), [.lyric, .interlude, .lyric])
        // 间奏从上一句唱完接到下一句起点
        XCTAssertEqual(lines[1].time, lines[0].end, accuracy: 0.001)
        XCTAssertEqual(lines[1].end, 60.0, accuracy: 0.001)
    }

    func testShortGapIsNotInterlude() {
        let lrc = """
        [00:02.00]一句
        [00:05.00]接着一句
        """
        XCTAssertEqual(LyricParser.parse(lrc).map(\.kind), [.lyric, .lyric])
    }

    /// 前奏只要够长就插三个点，哪怕歌词里根本没有创作者块
    func testLongIntroWithoutCreditsStillBecomesInterlude() {
        let lines = LyricParser.parse("[00:10.00]第一句")
        XCTAssertEqual(lines.map(\.kind), [.interlude, .lyric])
        XCTAssertEqual(lines[0].time, 0, accuracy: 0.001)
        XCTAssertEqual(lines[0].end, 10.0, accuracy: 0.001)
    }

    /// 行的结束时刻不能越过下一行的起点，否则会出现两行同时高亮
    func testLineEndNeverOverlapsNextLine() {
        let lrc = """
        [00:10.00]很长很长很长很长很长很长很长很长的一句歌词
        [00:11.00]紧接着的下一句
        """
        let lines = lyricLines(LyricParser.parse(lrc))
        XCTAssertEqual(lines[0].end, 11.0, accuracy: 0.001)
    }

    // MARK: - 尾部制作表

    /// 结尾那一块制作表也要整块摘掉：正文末句必须还在
    func testTrailingCreditBlockStripped() {
        let lrc = """
        [00:02.23]从未见过的海 - 告五人
        [00:04.40]词：告五人云安 Pan Pan An
        [00:06.82]曲：告五人云安 Pan Pan An
        [00:47.71]今早的闹钟唤醒
        [04:06.84]告诉我们不要再等待
        [04:10.86]制作人Produer：陈君豪 Howe@成绩好工作室
        [04:11.79]编曲Arrangement：告五人 Accusefive
        [04:12.42]小号Trumpet：David Smith
        [04:15.55]录音师Recording Engineer：叶育轩 YuHsuan Yeh/蔡周翰 Chou Han Tsay
        [04:16.44]混音师Mixing Engineer：黄文萱 Ziya Huang
        """
        let lines = LyricParser.parse(lrc)
        XCTAssertEqual(lyricLines(lines).map(\.text), ["今早的闹钟唤醒", "告诉我们不要再等待"])
        XCTAssertEqual(lines.filter { $0.kind == .credits }.map(\.text), ["创作者：告五人云安 Pan Pan An"])
    }

    /// 双语角色名的长度由形态决定，不由字符数决定
    /// [实测]「人声/吉他录音师 Vocal/Guitar Recording Engineer」是 40 个字符的真角色名
    func testLongBilingualCreditKeyStillRecognized() {
        let lrc = """
        [00:00.21]词 Lyric：告五人云安 Pan Pan An
        [00:01.58]正文
        [04:15.24]人声/吉他录音师 Vocal/Guitar Recording Engineer：叶育轩 YuHsuan Yeh
        [04:15.55]鼓录音室 Drum Recording Studio：112F Studio
        [04:16.44]制作助理 Production Assistant：林颉 Jie Lin
        """
        XCTAssertEqual(lyricLines(LyricParser.parse(lrc)).map(\.text), ["正文"])
    }

    /// 尾块的扫描方向朝着正文去，认不出的末行不能被上面认得出的那条带走
    func testTrailingCreditsDoNotEatLastLyricLine() {
        let lrc = """
        [00:00.00]词：某人
        [00:20.00]第一句
        [00:24.00]他说：我不走了
        """
        XCTAssertEqual(lyricLines(LyricParser.parse(lrc)).map(\.text), ["第一句", "他说：我不走了"])
    }

    /// 头块有词曲时，尾块那份重复的不覆盖
    func testTrailingCreditsOnlyFillMissingSongwriters() {
        let lrc = """
        [00:00.00]词：甲
        [00:01.00]曲：乙
        [00:20.00]正文
        [03:00.00]作词：丙
        [03:01.00]作曲：丁
        """
        let lines = LyricParser.parse(lrc)
        XCTAssertEqual(lyricLines(lines).map(\.text), ["正文"])
        XCTAssertEqual(lines.filter { $0.kind == .credits }.map(\.text), ["创作者：甲、乙"])
    }

    /// 词曲只写在结尾的歌（独立厂牌常见排法）也要排得出创作者
    func testTrailingCreditsSupplyMissingSongwriters() {
        let lrc = """
        [00:20.00]正文
        [03:00.00]词：甲
        [03:01.00]曲：乙
        [03:02.00]混音：丙
        """
        let lines = LyricParser.parse(lrc)
        XCTAssertEqual(lyricLines(lines).map(\.text), ["正文"])
        XCTAssertEqual(lines.filter { $0.kind == .credits }.map(\.text), ["创作者：甲、乙"])
    }

    /// 整首都像「键：值」时尾块一行不摘——宁可漏，不能把歌吃光
    func testTrailingBlockNotStrippedWhenItWouldEatAll() {
        let lrc = """
        [00:00.00]词：甲
        [00:01.00]曲：乙
        [00:02.00]编曲：丙
        """
        XCTAssertTrue(lyricLines(LyricParser.parse(lrc)).isEmpty)
    }

    // MARK: - 版权声明行

    /// 声明行不中断块扫描：它和它上面已认的两行要一起摘干净
    func testNoticeLineDoesNotBreakCreditBlock() {
        let lrc = """
        [00:00.00]我天生-有梦版 - 告五人
        [00:00.21]词 Lyric：告五人云安 Pan Pan An
        [00:00.44]曲 Compose：告五人云安 Pan Pan An
        [00:00.68]【本作品声明，著作权权利保留。未经著作权人书面许可，不得以任何方式（包括翻唱、翻录等）使用。】
        [00:01.58]我天生有病才会喜欢你
        """
        let lines = LyricParser.parse(lrc)
        XCTAssertEqual(lyricLines(lines).map(\.text), ["我天生有病才会喜欢你"])
        XCTAssertEqual(lines.filter { $0.kind == .credits }.map(\.text),
                       ["创作者：告五人云安 Pan Pan An"])
    }

    /// ★ 圆括号那一族是真·和声与旁白，一个都不许摘
    func testParenthesizedBackingVocalLineSurvives() {
        let lrc = """
        [00:00.00]词：周杰伦
        [00:20.00]正文
        [00:24.00]（斑驳的家徽擦拭了一夜。）
        [00:28.00]（哎呦不错哦）
        """
        XCTAssertEqual(lyricLines(LyricParser.parse(lrc)).map(\.text),
                       ["正文", "（斑驳的家徽擦拭了一夜。）", "（哎呦不错哦）"])
    }

    /// 合取规则的边界：只有括号、没有句号的段落标记不摘
    func testSectionMarkerWithoutSentenceEndSurvives() {
        let lrc = """
        [00:20.00]正文
        [00:24.00]【副歌】
        """
        XCTAssertEqual(lyricLines(LyricParser.parse(lrc)).map(\.text), ["正文", "【副歌】"])
    }
}
