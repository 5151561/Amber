import XCTest
@testable import Amber

/// 搜索层：`segment` / `pinyinTokens` / `ftsQuery` 三个纯函数，外加它们在一张真 FTS5 表上
/// 端到端的表现。
///
/// 这里的每一条都是**只看代码看不出来**的：邻近约束有没有退化成 AND、拼音按段还是按整串产、
/// 元字符会不会把 MATCH 顶出语法错，都得让 SQLite 自己说了算。所以不 mock，
/// 直接建一张 `fts5` 表灌语料再搜。
///
/// 库开在临时目录而不是 `:memory:`：走的是 `SQLiteDatabase` 正常那条开库路径
/// （WAL、语句缓存、`SQLITE_TRANSIENT` 绑参），顺带保证测的就是 App 里跑的那套。
final class LibrarySearchTests: XCTestCase {

    /// 语料每条同时当 owner_id 用，断言里直接看得见命中了哪首。
    private static let corpus = [
        "帶你飛 (Live)",
        "周杰倫 七里香",
        "Taylor Swift 帶你飛",
        "带你飞",
        "君の名は",
        "ЧАЙКОВСКИЙ",
        "ÉCOUTE",
        "Mr. Children",
        "50% Off",
        "陈奕迅 浮夸",
    ]

    /// 分列专用的小语料：每条的三段**故意首尾相接**，跨字段短语才有机会冒出来。
    /// `帶你飛` 末字「飛」紧挨 `周杰倫` 首字「周」，`周杰倫` 末字「倫」紧挨 `葉惠美` 首字「葉」。
    private static let splitCorpus = [
        ("帶你飛", "周杰倫", "葉惠美"),
        ("Love Story", "Taylor Swift", "Fearless"),
    ]

    private var directory: URL!
    private var db: SQLiteDatabase!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySearchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: directory.appendingPathComponent("search.sqlite"))
        // 与 schema 里的 search_index 同形：正文按字段分列 + 拼音一列 + 不参与索引的归属列。
        try db.execute("""
            CREATE VIRTUAL TABLE search_index
            USING fts5(name, artist, album, phonetic, owner_id UNINDEXED)
            """)
        // 主语料每条只填 name：这一组用例问的是切分、拼音、元字符，与分列无关。
        // 跨字段那几条另开一张 split_index，混进来只会让这里每条期望值都跟着变。
        for text in Self.corpus {
            try insert(into: "search_index", LibrarySearch.indexRow(name: text), ownerID: text)
        }

        try db.execute("""
            CREATE VIRTUAL TABLE split_index
            USING fts5(name, artist, album, phonetic, owner_id UNINDEXED)
            """)
        for row in Self.splitCorpus {
            try insert(into: "split_index",
                       LibrarySearch.indexRow(name: row.0, artist: row.1, album: row.2),
                       ownerID: row.0)
        }
    }

    private func insert(into table: String, _ row: LibrarySearch.IndexRow,
                        ownerID: String) throws {
        try db.run("""
            INSERT INTO \(table)(name, artist, album, phonetic, owner_id) VALUES(?,?,?,?,?)
            """, [row.name, row.artist, row.album, row.phonetic, ownerID])
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// 照调用方该有的样子走一遍：`ftsQuery` 给 nil 就是「不加筛选、返回全部」。
    private func search(_ input: String) throws -> [String] {
        guard let query = LibrarySearch.ftsQuery(input) else { return Self.corpus }
        return try db.query(
            "SELECT owner_id FROM search_index WHERE search_index MATCH ? ORDER BY rowid",
            [query]
        ) { $0.text(0) }
    }

    // MARK: - 中文子串

    /// 这条就是「不能裸上 FTS5」的正面证据：默认分词器把 `帶你飛` 当一个 token，
    /// `MATCH '你飛'` 零命中；垫成 unigram 之后才搜得到。
    func testIdeographSubstringMatches() throws {
        // 三条里「带你飞」是简体那份：正文与查询都经 `foldHan` 归一，简繁互相搜得到。
        XCTAssertEqual(try search("你飛"),
                       ["帶你飛 (Live)", "Taylor Swift 帶你飛", "带你飞"])
        XCTAssertEqual(try search("里香"), ["周杰倫 七里香"])
    }

    /// **全套用例里最要紧的一条。** 逐字垫空格之后，若查询串写成 `你 AND 飛`，
    /// `飛你` 会照样命中——搜索就此变成「这几个字都有就行」，顺序全丢。
    /// 靠的是把连续表意文字并成引号短语求**位置紧邻**，这条断言守的就是它没退化。
    func testReversedIdeographsDoNotMatch() throws {
        XCTAssertEqual(try search("飛你"), [])
        XCTAssertEqual(try search("香里"), [])
    }

    func testMixedLatinAndIdeographNarrowsToOneRow() throws {
        // 语料里两条含「帶你飛」，加上 Taylor 这一段就只剩一条。
        XCTAssertEqual(try search("Taylor 你飛"), ["Taylor Swift 帶你飛"])
    }

    /// 假名同样逐字垫空格：`の名` 跨了「の」和汉字，短语照样成立。
    func testKanaSubstringMatches() throws {
        XCTAssertEqual(try search("の名"), ["君の名は"])
    }

    // MARK: - 拼音

    func testPinyinMatchesInThreeForms() throws {
        XCTAssertEqual(try search("qlx"), ["周杰倫 七里香"])          // 首字母
        XCTAssertEqual(try search("qili"), ["周杰倫 七里香"])         // 连写全拼的前缀
        XCTAssertEqual(try search("qilixiang"), ["周杰倫 七里香"])    // 连写全拼
        XCTAssertEqual(try search("cyx"), ["陈奕迅 浮夸"])
        XCTAssertEqual(try search("fk"), ["陈奕迅 浮夸"])
    }

    /// 简繁互搜是拼音通道白送的：`带你飞` 与 `帶你飛` 正文一个字都不共享，
    /// 但两边的拼音 token 完全相同。
    ///
    /// 这里断言三条而不是两条，是因为本语料里含「帶你飛」的本来就有两条
    /// （`(Live)` 那条和 Taylor 那条）——都命中是对的，不是假阳性。
    func testPinyinBridgesSimplifiedAndTraditional() throws {
        let expected = ["帶你飛 (Live)", "Taylor Swift 帶你飛", "带你飞"]
        XCTAssertEqual(try search("dai ni fei"), expected)
        XCTAssertEqual(try search("dainifei"), expected)
    }

    /// 拼音必须按**汉字连续段**产。整串产会得到 `zjlqlx`，而用户敲的 `qlx` 是它
    /// 中间的子串，前缀匹配不上——这是第一版写错、实测才发现的。
    func testPinyinTokensAreGeneratedPerHanRun() throws {
        let tokens = LibrarySearch.pinyinTokens("周杰倫 七里香")
        XCTAssertEqual(tokens, ["zhou jie lun", "zhoujielun", "zjl",
                                "qi li xiang", "qilixiang", "qlx"])
        XCTAssertTrue(tokens.contains("zjl"))
        XCTAssertTrue(tokens.contains("qlx"))
        XCTAssertFalse(tokens.contains("zjlqlx"), "整串产的首字母会让 qlx 匹不上")
        // 空格全拼之外必须另存连写全拼，否则 `qili` 匹不上 token `qi`。
        XCTAssertTrue(tokens.contains("qilixiang"))
        // 只对汉字段产拼音，假名跳过。
        XCTAssertEqual(LibrarySearch.pinyinTokens("君の名は"), ["jun", "ming"])
    }

    // MARK: - Unicode 折叠

    /// `unicode61` 自带 Unicode 大小写折叠与去变音符，比 SQLite 的 `lower()`
    /// （只折 ASCII，实测 `LIKE '%чайков%'` 匹不上 `ЧАЙКОВСКИЙ`）强。
    func testUnicodeFoldingCoversCyrillicCaseAndDiacritics() throws {
        XCTAssertEqual(try search("чайков"), ["ЧАЙКОВСКИЙ"])
        XCTAssertEqual(try search("ecoute"), ["ÉCOUTE"])
    }

    // MARK: - 元字符与空串

    /// 搜索框里随手敲一个 `*` 或 `-` 就是一条 `SQLITE_ERROR`：FTS5 的查询串是有语法的。
    /// 引号包裹把元字符全中和掉——要么无命中、要么正常命中，**绝不抛错**。
    func testMetacharactersNeverThrow() throws {
        for input in ["\"", "*", "AND", "-abc", "^x", "NEAR(a b)", "(", "a OR b"] {
            XCTAssertNoThrow(try search(input), "输入 \(input) 顶出了 FTS5 语法错")
        }
        XCTAssertEqual(try search("\""), [])
        XCTAssertEqual(try search("*"), [])
        XCTAssertEqual(try search("AND"), [])
        XCTAssertEqual(try search("-abc"), [])
        // `%` 对 FTS5 不是元字符（那是 LIKE 的），分词后剩 `50`，正常命中。
        XCTAssertEqual(try search("50%"), ["50% Off"])
    }

    /// 裸空串进 MATCH 实测报 `fts5: syntax error near ""`，所以空 / 纯空白必须在
    /// 进 SQL 之前就返回 nil，由调用方走「不加筛选、返回全部」。
    func testBlankInputYieldsNilQuery() throws {
        XCTAssertNil(LibrarySearch.ftsQuery(""))
        XCTAssertNil(LibrarySearch.ftsQuery(" "))
        XCTAssertNil(LibrarySearch.ftsQuery("\t\n  "))
        XCTAssertEqual(try search("").count, Self.corpus.count)
    }

    // MARK: - 有意的行为变化

    /// **拉丁文字从「任意子串」收窄为「词前缀」。** 今天的
    /// `localizedCaseInsensitiveContains` 让 `aylor` 也能搜到 `Taylor`，FTS5 不能。
    /// Apple Music 自己就是词前缀匹配，这算更正确——但它是个**有意**的行为变化，
    /// 这条断言在这里就是为了防止以后有人把 `aylor` 当 bug 报、再把整条路改回 LIKE。
    func testLatinMatchesWordPrefixNotArbitrarySubstring() throws {
        XCTAssertEqual(try search("taylor"), ["Taylor Swift 帶你飛"])
        XCTAssertEqual(try search("Taylor"), ["Taylor Swift 帶你飛"])  // 大小写不敏感照旧
        XCTAssertEqual(try search("swi"), ["Taylor Swift 帶你飛"])     // 词前缀命中
        XCTAssertEqual(try search("aylor"), [])                        // 词中子串不命中
    }

    // MARK: - 入库侧

    /// 入库侧与查询侧共用同一个 `segment`——两边切法差一个空格，位置序列就对不上，
    /// 短语邻近当场失效，而表现是「搜不到」不是报错。这条把切法本身钉住。
    func testSegmentPadsIdeographsAndKeepsLatinWordsIntact() {
        // 输出是**折成简体**的：`segment` 开头就过 `foldHan`，入库与查询两侧同源。
        XCTAssertEqual(LibrarySearch.segment("帶你飛 (Live)"), "带 你 飞 (Live)")
        XCTAssertEqual(LibrarySearch.segment("Mr. Children"), "Mr. Children")
        XCTAssertEqual(LibrarySearch.segment("君の名は"), "君 の 名 は")
        XCTAssertEqual(LibrarySearch.segment("  多余   空白 "), "多 余 空 白")
    }

    /// `indexRow` 是入库侧唯一的出口：正文各段各自出列，拼音合成一列。
    ///
    /// 「各段出列」而不是「拼成一串」是这一版的核心——拼成一串时字段之间只能垫一个
    /// 分隔符，而分隔符不占 token 位置，短语就能跨字段成立（见下面 `飛周` 那两条）。
    func testIndexRowPutsEachFieldInItsOwnColumn() {
        let row = LibrarySearch.indexRow(name: "七里香", artist: "周杰倫", album: "葉惠美")
        XCTAssertEqual(row.name, "七 里 香")
        XCTAssertEqual(row.artist, "周 杰 伦")
        XCTAssertEqual(row.album, "叶 惠 美")
        // 拼音是三段各自 pinyinTokens 的并集：按段产、按段拼，顺序跟着字段走。
        XCTAssertEqual(row.phonetic,
                       "qi li xiang qilixiang qlx zhou jie lun zhoujielun zjl ye hui mei yehuimei yhm")

        // 用不上的字段出空串，不是 nil 也不是占位符：四种对象共用这几列。
        let bare = LibrarySearch.indexRow(name: "Taylor")
        XCTAssertEqual(bare.name, "Taylor")
        XCTAssertEqual(bare.artist, "")
        XCTAssertEqual(bare.album, "")
        XCTAssertEqual(bare.phonetic, "")
    }

    // MARK: - 跨字段

    private func splitSearch(_ input: String) throws -> [String] {
        guard let query = LibrarySearch.ftsQuery(input) else { return [] }
        return try splitMatch(query)
    }

    private func splitMatch(_ expression: String) throws -> [String] {
        try db.query(
            "SELECT owner_id FROM split_index WHERE split_index MATCH ? ORDER BY rowid",
            [expression]
        ) { $0.text(0) }
    }

    /// **这次改动的核心守卫。** 「飛」是曲名末字、「周」是艺人首字，两者在**不同字段**里，
    /// 谁也没挨着谁——搜 `飛周` 必须零命中。
    ///
    /// 单列 + `" ⧉ "` 分隔符的旧写法这里会各多一条假阳性：`unicode61` 把那个符号当
    /// 分隔符丢掉，而**丢掉的符号不占 token 位置**，于是曲名末字与艺人首字在位置序列上
    /// 直接相邻，短语邻近照样成立。分成两列之后 FTS5 的短语不跨列，它才真的零命中。
    /// `倫葉` 同理，钉的是 artist 与 album 之间那道边界。
    func testPhrasesDoNotSpanFields() throws {
        XCTAssertEqual(try splitSearch("飛周"), [], "曲名末字 + 艺人首字跨字段成了短语")
        XCTAssertEqual(try splitSearch("倫葉"), [], "艺人末字 + 专辑首字跨字段成了短语")
    }

    /// 邻近不跨列，但 **AND 跨列**——这才是分列要的完整语义。只守住前半条，
    /// 「一次输入横跨两个字段」就跟着被搜没了，那是把假阳性连着真召回一起铲。
    ///
    /// 两种问法都验：一种是调用方最终递给 MATCH 的表达式（`AND` 显式写着），
    /// 一种是用户在搜索框里真敲的字（`ftsQuery` 自己把两段连成 `AND`）。
    func testAndSpansFields() throws {
        // 这两条绕过 `ftsQuery` 直接手写 MATCH，所以要按**入库之后的样子**写：
        // 正文入库前过了 `foldHan`，表里存的是简体。经 `ftsQuery` 的那条路
        // 两种字形都行（见 `testSimplifiedAndTraditionalSearchEachOther`）。
        XCTAssertEqual(try splitMatch("\"带 你 飞\" AND \"周 杰 伦\""), ["帶你飛"])
        XCTAssertEqual(try splitMatch("\"周 杰 伦\" AND \"叶 惠 美\""), ["帶你飛"])
        // 拉丁词天生一词一组、组间 AND，所以搜索框输入就能横跨 album 与 artist。
        XCTAssertEqual(try splitSearch("fearless taylor"), ["Love Story"])
        XCTAssertEqual(try splitSearch("story swift"), ["Love Story"])
    }

    /// **「搜 艺人名 + 曲名」这条最常见的搜法。** 从前 `segment` 把用户打的空格和它自己为
    /// 表意文字垫出来的空格揉成同一种，`ftsQuery` 只看 token 相不相邻，于是把两段并成
    /// **一个**短语 `"周 杰 倫 帶 你 飛"`——正文分列之后短语不跨列，这么一横跨就是零命中。
    ///
    /// 现在分组依据换成了用户敲的空白：一个空格一道组边界，组间 `AND`，而 **AND 跨列**。
    func testUserSpaceBetweenIdeographRunsIsAnAnd() throws {
        XCTAssertEqual(LibrarySearch.ftsQuery("周杰倫 帶你飛"), "\"周 杰 伦\" AND \"带 你 飞\"")
        XCTAssertEqual(try splitSearch("周杰倫 帶你飛"), ["帶你飛"])
    }

    /// **这一对才是本次改动的全部意义，要一起读。** 同样是「飛」「周」两个字，敲不敲那个
    /// 空格给出两种语义：
    ///
    /// - `飛周`：用户没说这是两个词，那就按一个词处理 → 短语 `"飛 周"` → 短语不跨列，
    ///   曲名末字与艺人首字各在各的列里，零命中。跨字段假阳性那道闸**没松**。
    /// - `飛 周`：用户显式敲了空格，就是在说「这是两个词」 → `"飛"* AND "周"*` → 命中。
    ///
    /// 谁要是把上面那条 `AND` 改回并成一个短语，下面这条就会跟着红——反过来也一样。
    func testUserSpaceTurnsNeighborsIntoAndButRunsStayPhrases() throws {
        XCTAssertEqual(LibrarySearch.ftsQuery("飛周"), "\"飞 周\"")
        XCTAssertEqual(try splitSearch("飛周"), [], "没敲空格却跨字段成了 AND")

        XCTAssertEqual(LibrarySearch.ftsQuery("飛 周"), "\"飞\"* AND \"周\"*")
        XCTAssertEqual(try splitSearch("飛 周"), ["帶你飛"], "敲了空格还被并成短语")
    }

    /// 分列不该动「字段内」原有的两条行为：子串仍命中、反序仍不命中。
    func testWithinFieldSubstringAndOrderStillHold() throws {
        XCTAssertEqual(try splitSearch("你飛"), ["帶你飛"])
        XCTAssertEqual(try splitSearch("杰倫"), ["帶你飛"])
        XCTAssertEqual(try splitSearch("飛你"), [])
        XCTAssertEqual(try splitSearch("倫杰"), [])
    }

    /// 拼音合成一列照样三形态全通：它天生是 AND 连的前缀词组，没有邻近约束，
    /// 也就没有「跨字段泄漏」可言——这是 phonetic 敢合成一列的理由。
    func testPinyinStillMatchesAcrossMergedColumn() throws {
        XCTAssertEqual(try splitSearch("dainifei"), ["帶你飛"])   // 曲名，连写全拼
        XCTAssertEqual(try splitSearch("zjl"), ["帶你飛"])        // 艺人，首字母
        XCTAssertEqual(try splitSearch("ye hui mei"), ["帶你飛"]) // 专辑，空格全拼
        XCTAssertEqual(try splitSearch("zjl dnf"), ["帶你飛"])    // 两段拼音一起敲
    }
}
