import XCTest
@testable import Amber

/// 阶段 8：`search_index` 上线之后的**接线**——表跟着增删改走，七处搜索收成一个口。
///
/// 这里与 `LibrarySearchTests` 分工明确：那边测的是三个纯函数在一张**自己搭的** FTS5 表上
/// 的语义（切分、拼音、邻近、元字符），这边测的是**真的那张表**——由 `LibraryStore` 的
/// 落库助手维护、由 `LibraryStore.searchFilter` 查询。所以这边每一条都必须经过 store，
/// 一条也不许直接拿 `LibrarySearch` 对答案：语义早就钉过了，这边要钉的是「有没有接上」。
///
/// `LibraryStore` 注入临时目录，绝不碰真实的 `~/Library/Application Support/Amber/`。
@MainActor
final class LibrarySearchIndexTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySearchIndexTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 语料

    /// 一份把用例矩阵全覆盖住的小资料库。
    ///
    /// 排布是**故意**的，不是随手挑的歌：
    ///
    /// - `帶你飛` 的末字「飛」紧挨着艺人 `周杰倫` 的首字「周」——跨字段短语要冒头就冒在这儿
    ///   （`飛周` 必须零命中，`飛 周` 必须命中）；
    /// - `七里香` 给拼音三形态（`qlx` / `qili` / `qilixiang`）；
    /// - `带你飞` 与 `帶你飛` 简繁一对，靠拼音互通；
    /// - 假名、西里尔、带 `%` 的标题各一条。
    private struct Fixture {
        let store: LibraryStore
        let album: Album           // 葉惠美 / 周杰倫
        let latinAlbum: Album      // Fearless / Taylor Swift
    }

    private func makeAlbum(_ id: String, name: String, artist: String) -> Album {
        Album(id: id, kind: .qq, name: name, artistName: artist, artistId: nil,
              artworkURL: nil, publishDate: "2004-08-03", trackCount: 0, description: nil)
    }

    private func makeTrack(_ id: String, title: String, artist: String,
                           album: Album, number: Int) -> Track {
        Track(id: id, kind: .qq, title: title, artistName: artist, artistId: nil,
              albumName: album.name, albumId: album.id, artworkURL: nil, duration: 180,
              trackNumber: number, discNumber: 1)
    }

    private func makeFixture() -> Fixture {
        let store = LibraryStore(directory: directory)
        let album = makeAlbum("qq:albumA", name: "葉惠美", artist: "周杰倫")
        store.addAlbumToLibrary(album, tracks: [
            makeTrack("qq:t1", title: "帶你飛", artist: "周杰倫", album: album, number: 1),
            makeTrack("qq:t2", title: "七里香", artist: "周杰倫", album: album, number: 2),
        ])
        let latinAlbum = makeAlbum("qq:albumB", name: "Fearless", artist: "Taylor Swift")
        store.addAlbumToLibrary(latinAlbum, tracks: [
            makeTrack("qq:t3", title: "Love Story", artist: "Taylor Swift",
                      album: latinAlbum, number: 1),
        ])
        // 未随碟入库的单曲：假名、西里尔、带 % 的标题各一条。
        let loose = makeAlbum("qq:albumC", name: "前前前世", artist: "RADWIMPS")
        store.addToLibrary(makeTrack("qq:t4", title: "君の名は", artist: "RADWIMPS",
                                     album: loose, number: 1))
        store.addToLibrary(makeTrack("qq:t5", title: "ЧАЙКОВСКИЙ", artist: "ÉCOUTE",
                                     album: loose, number: 2))
        store.addToLibrary(makeTrack("qq:t6", title: "50% Off", artist: "Mr. Children",
                                     album: loose, number: 3))
        store.createPlaylist(name: "帶你飛")
        store.createPlaylist(name: "七里香")
        return Fixture(store: store, album: album, latinAlbum: latinAlbum)
    }

    /// 走的就是七处搜索走的那条路：`searchFilter` 拿 id 集合 → 自己筛手里那份数组。
    private func songs(_ store: LibraryStore, _ word: String) -> [String] {
        let matches = store.searchFilter(word, kind: .track)
        return store.libraryTracks
            .filter { matches.keeps($0.id, [$0.title, $0.artistName, $0.albumName]) }
            .map(\.title)
    }

    private func albums(_ store: LibraryStore, _ word: String) -> [String] {
        let matches = store.searchFilter(word, kind: .album)
        return store.libraryAlbums
            .filter { matches.keeps($0.id, [$0.name, $0.artistName]) }
            .map(\.name)
    }

    private func playlists(_ store: LibraryStore, _ word: String) -> [String] {
        let matches = store.searchFilter(word, kind: .playlist)
        return store.playlists
            .filter { matches.keeps($0.id, [$0.name, $0.source?.creatorName ?? ""]) }
            .map(\.name)
    }

    private func artists(_ store: LibraryStore, _ word: String) -> [String] {
        let matches = store.searchFilter(word, kind: .artist)
        return store.libraryArtists()
            .filter { matches.keeps($0.id, [$0.name]) }
            .map(\.name)
    }

    /// store 与测试共用同一条连接（`AmberDatabase.shared(directory:)` 按目录记忆化）。
    private func connection() throws -> SQLiteDatabase {
        try AmberDatabase.shared(directory: directory).sqlite
    }

    private func indexRows(_ kind: String) throws -> Int {
        Int(try connection().value("SELECT COUNT(*) FROM search_index WHERE owner_kind = ?",
                                   [kind]) { $0.int(0) } ?? 0)
    }

    // MARK: - 用例矩阵

    /// 中文子串：默认分词器把整串汉字当一个 token，不垫空格的话这两条都是零命中。
    func testIdeographSubstring() {
        let store = makeFixture().store
        XCTAssertEqual(songs(store, "你飛"), ["帶你飛"])
        XCTAssertEqual(songs(store, "里香"), ["七里香"])
    }

    /// 反序零命中——**邻近约束没退化成 AND** 的那道闸。
    /// 这条一旦变绿成「命中」，说明短语被拆成了一堆 AND，搜什么都能搜出一堆。
    func testReversedIdeographsDoNotMatch() {
        let store = makeFixture().store
        XCTAssertEqual(songs(store, "飛你"), [])
        XCTAssertEqual(songs(store, "香里"), [])
    }

    /// **连着敲 vs 敲空格**——这一对的对比就是「正文必须分列」那条规则的全部意义。
    ///
    /// `帶你飛` 的末字与艺人 `周杰倫` 的首字相邻。正文合成一列时短语能跨过字段边界，
    /// 于是 `飛周` 冒出一条假阳性；分列之后短语不跨列，它归零。
    /// 而用户**自己敲了空格**的 `飛 周` 是两组、组间 AND，AND 跨列 —— 该命中。
    func testAdjacentRunsVersusUserTypedSpace() {
        let store = makeFixture().store
        XCTAssertEqual(songs(store, "飛周"), [], "跨字段短语不该成立")
        XCTAssertEqual(songs(store, "飛 周"), ["帶你飛"], "用户敲的空格就是 AND")
        // 专辑那一侧同理：「倫」是艺人末字、「葉」是专辑名首字。
        XCTAssertEqual(albums(store, "倫葉"), [])
        XCTAssertEqual(albums(store, "倫 葉"), ["葉惠美"])
    }

    /// 中英混搜：一个拉丁词组 + 一个汉字短语，组间 AND。
    func testMixedLatinAndIdeograph() {
        let store = makeFixture().store
        XCTAssertEqual(songs(store, "Taylor Love"), ["Love Story"])
        XCTAssertEqual(songs(store, "周杰倫 七里"), ["七里香"])
        // 两组都得中，缺一条就零命中。
        XCTAssertEqual(songs(store, "Taylor 七里"), [])
    }

    /// 假名也逐字垫空格，所以子串搜得到。
    func testKanaSubstring() {
        let store = makeFixture().store
        XCTAssertEqual(songs(store, "の名"), ["君の名は"])
    }

    /// 拼音三形态：空格全拼 / 连写全拼 / 首字母。
    func testPinyinInThreeForms() {
        let store = makeFixture().store
        for word in ["qi li xiang", "qili", "qilixiang", "qlx"] {
            XCTAssertEqual(songs(store, word), ["七里香"], "拼音「\(word)」没命中")
        }
    }

    /// 简繁互搜，**桥是拼音那条通道**，不是汉字那条。
    ///
    /// 「帶你飛」与「带你飞」的码点没有一个字相同，正文那条 unigram 路两边碰不上面；
    /// 但两边的拼音 token 一模一样，所以敲 `dainifei` / `dai ni fei` 两边都命中。
    ///
    /// **直接敲另一种字形是不通的**（`带你飞` 搜不到「帶你飛」）：CJK 查询生成的是
    /// 一个由**该字形的单字**组成的短语，它只跟同字形的正文对得上。
    /// 要让它通，得在入库与查询两侧都做一次繁简归一化——那是改 `LibrarySearch`
    /// 那一层的语义，不是接线。这条用例把**现在的**行为钉住，免得被当成 bug 顺手改掉，
    /// 也免得被当成「已经支持了」。
    func testSimplifiedAndTraditionalSearchEachOther() {
        let store = makeFixture().store
        store.createPlaylist(name: "带你飞")

        // 拼音那条桥（`foldHan` 之前就成立的那条）照旧。
        for word in ["dainifei", "dai ni fei", "dnf"] {
            XCTAssertEqual(songs(store, word), ["帶你飛"], "拼音「\(word)」没把繁体那条桥起来")
            XCTAssertEqual(Set(playlists(store, word)), ["帶你飛", "带你飞"],
                           "拼音「\(word)」该同时命中简繁两份列表")
        }

        // **汉字那条路也要互通**：正文与查询都经 `foldHan` 归一成简体，
        // 于是敲哪种字形都落到同一个 token 上。用户并不知道自己库里存的是哪种字形
        //（两家音源给的不一样，本地导入的文件标签更是什么都有）。
        XCTAssertEqual(songs(store, "带你飞"), ["帶你飛"], "敲简体要搜得到库里那首繁体的")
        XCTAssertEqual(songs(store, "帶你飛"), ["帶你飛"])
        for word in ["带你飞", "帶你飛"] {
            XCTAssertEqual(Set(playlists(store, word)), ["帶你飛", "带你飞"],
                           "「\(word)」该同时命中简繁两份列表")
        }
        // 子串同样互通（短语邻近在归一之后的 token 序列上成立）。
        XCTAssertEqual(songs(store, "你飞"), ["帶你飛"])
        XCTAssertEqual(songs(store, "你飛"), ["帶你飛"])
        // 归一不该顺手放宽别的：反序照旧零命中。
        XCTAssertEqual(songs(store, "飞你"), [])
    }

    /// 归一方向只能是「繁→简」，因为繁简映射是多对一。
    /// 往多的那头折会丢信息（实测 `Hans-Hant` 把「周杰伦」折成「周傑倫」）。
    /// 多对一的代价是召回变宽——搜「后」会同时命中「皇后」与「以後」，
    /// 这是简繁互搜这件事本身的语义，钉在这儿免得以后被当成假阳性「修」掉。
    func testFoldingIsManyToOneOnPurpose() {
        XCTAssertEqual(LibrarySearch.foldHan("帶你飛"), "带你飞")
        XCTAssertEqual(LibrarySearch.foldHan("皇后 以後"), "皇后 以后")
        XCTAssertEqual(LibrarySearch.foldHan("带你飞"), "带你飞", "已经是简体的原样不动")
        XCTAssertEqual(LibrarySearch.foldHan("Taylor Swift"), "Taylor Swift", "拉丁不碰")
        XCTAssertEqual(LibrarySearch.foldHan("君の名は"), "君の名は", "假名不碰")
    }

    /// 西里尔大小写与变音符由 `unicode61` 自己折（SQL 的 `lower()` 只折 ASCII）。
    func testCyrillicCaseAndDiacritics() {
        let store = makeFixture().store
        XCTAssertEqual(songs(store, "чайков"), ["ЧАЙКОВСКИЙ"])
        XCTAssertEqual(songs(store, "ecoute"), ["ЧАЙКОВСКИЙ"])   // 艺人列 ÉCOUTE
    }

    /// 元字符不许把 MATCH 顶出语法错。抛出来的表现是「搜索框一敲 `*` 整页空白」，
    /// 而 `searchFilter` 的兜底会把它变成子串筛选——所以这里连**兜底都不许走到**：
    /// 断言用的是「结果与预期一致」，抛错时兜底给的答案不一样，会被抓住。
    func testMetacharactersNeverThrow() {
        let store = makeFixture().store
        for word in ["*", "\"", "AND", "-abc", "50%", "^", "(", "NEAR", "a*b", "\"帶你飛\""] {
            XCTAssertNoThrow(songs(store, word), "「\(word)」把查询顶崩了")
        }
        // 带 % 的标题照样搜得到：`%` 只是 LIKE 的通配，FTS5 里它是普通字符。
        XCTAssertEqual(songs(store, "50%"), ["50% Off"])
        // 引号被中和成字面量，不再是 FTS5 的短语定界符。
        XCTAssertEqual(songs(store, "\"帶你飛\""), ["帶你飛"])
    }

    /// 空串（与纯空白）**在进 MATCH 之前**就被拦掉，走「不加筛选、返回全部」那条路。
    /// 实测裸空串报 `fts5: syntax error near ""`。
    func testBlankQueryReturnsEverything() {
        let store = makeFixture().store
        let all = store.libraryTracks.map(\.title)
        for word in ["", "   ", "\n\t"] {
            XCTAssertEqual(songs(store, word), all, "「\(word.debugDescription)」该返回全部")
        }
        XCTAssertEqual(albums(store, ""), store.libraryAlbums.map(\.name))
        XCTAssertEqual(playlists(store, ""), store.playlists.map(\.name))
        XCTAssertEqual(artists(store, ""), store.libraryArtists().map(\.name))
    }

    /// **拉丁文字从「任意子串」收窄为「词前缀」，这是有意的，别当 bug 改回去。**
    ///
    /// 从前 `localizedCaseInsensitiveContains` 让 `aylor` 也能搜到 `Taylor`；
    /// FTS5 做不到（`taylor` 能）。Apple Music 自己就是词前缀匹配，这算更正确。
    /// 这一条与 `LibrarySearchTests.testLatinMatchesWordPrefixNotArbitrarySubstring` 成对：
    /// 那边钉纯函数，这边钉真正上屏的那条路。
    func testLatinNarrowsToWordPrefix() {
        let store = makeFixture().store
        XCTAssertEqual(songs(store, "taylor"), ["Love Story"])
        XCTAssertEqual(songs(store, "tay"), ["Love Story"])
        XCTAssertEqual(songs(store, "aylor"), [], "拉丁是词前缀，不是任意子串")
        // 收窄只在拉丁那一侧；表意文字仍然是任意子串（靠 unigram + 短语）。
        XCTAssertEqual(songs(store, "你飛"), ["帶你飛"])
    }

    // MARK: - 七处一个口

    /// **七处同一个词得同一份结果**——「收成一个口」这件事本身的证明。
    ///
    /// 七处现在都是同一个形状：`library.searchFilter(词, kind:)` 拿 id 集合，
    /// 再拿 `keeps(id, 字段)` 筛自己手里那份数组。所以这张表把七处各自的
    /// **对象类别 + 参与匹配的字段**逐行列出来，同一个词跑一遍，看命中的是不是同一批东西。
    ///
    /// 断言的不是「七处返回同一个数组」（各页装的本来就不是同一类对象），而是
    /// **同一个对象在任何一页都得到同一个判决**：`帶你飛` 这首歌在歌曲页、列表详情页、
    /// 搜索页资料库范围三处都得留下；`葉惠美` 那张碟在专辑页、最近添加、搜索页三处都得留下。
    ///
    /// 用的是 store 这一层而不是真把七个 `NSViewController` 建出来：
    /// 那要一整个 `AppState`，而它会去开真实的 `~/Library/Application Support/Amber/`。
    func testSevenSitesAgreeOnTheSameWord() throws {
        let store = makeFixture().store
        let word = "你飛"

        let track = try XCTUnwrap(store.libraryTracks.first { $0.title == "帶你飛" })
        let album = try XCTUnwrap(store.libraryAlbums.first { $0.name == "葉惠美" })
        let playlist = try XCTUnwrap(store.playlists.first { $0.name == "帶你飛" })

        let trackMatches = store.searchFilter(word, kind: .track)
        let albumMatches = store.searchFilter(word, kind: .album)
        let playlistMatches = store.searchFilter(word, kind: .playlist)
        let artistMatches = store.searchFilter(word, kind: .artist)

        // 曲目三处（歌曲页 / 列表详情 / 搜索页）用的是同一个 kind、同一组字段。
        for site in ["歌曲页", "列表详情页", "搜索页·资料库"] {
            XCTAssertTrue(
                trackMatches.keeps(track.id,
                                   [track.title, track.artistName, track.albumName]),
                "\(site) 把「帶你飛」筛掉了")
        }
        // 专辑两处（专辑页 / 最近添加）+ 搜索页的专辑段：这张碟不含「你飛」，三处都不留。
        for site in ["专辑页", "最近添加", "搜索页·资料库"] {
            XCTAssertFalse(albumMatches.keeps(album.id, [album.name, album.artistName]),
                           "\(site) 多留了一张不该命中的碟")
        }
        // 歌单页：同名的那份列表该留下。
        XCTAssertTrue(
            playlistMatches.keeps(playlist.id,
                                  [playlist.name, playlist.source?.creatorName ?? ""]))
        // 艺人页：没有叫「…你飛…」的艺人。
        for artist in store.libraryArtists() {
            XCTAssertFalse(artistMatches.keeps(artist.id, [artist.name]))
        }

        // 换一个词再跑一遍，这次命中的是艺人与专辑那几处。
        let artistWord = "周杰"
        let byArtist = store.searchFilter(artistWord, kind: .artist)
        XCTAssertEqual(artists(store, artistWord), ["周杰倫"])
        XCTAssertTrue(byArtist.keeps(Artist.libraryIDPrefix + "周杰倫", ["周杰倫"]))
        // 同一个词在曲目与专辑两处命中的是「艺人是他」的那些行——
        // 三处（歌曲页 / 专辑页 / 搜索页）拿到的是同一批 id。
        XCTAssertEqual(songs(store, artistWord), ["帶你飛", "七里香"])
        XCTAssertEqual(albums(store, artistWord), ["葉惠美"])
    }

    // MARK: - 维护：增

    func testAddedTrackIsSearchableImmediately() {
        let store = makeFixture().store
        XCTAssertEqual(songs(store, "浮夸"), [])
        let loose = makeAlbum("qq:albumD", name: "U87", artist: "陳奕迅")
        store.addToLibrary(makeTrack("qq:t9", title: "浮誇", artist: "陳奕迅",
                                     album: loose, number: 1))
        XCTAssertEqual(songs(store, "浮誇"), ["浮誇"])
        XCTAssertEqual(songs(store, "fk"), ["浮誇"], "拼音首字母也该跟着进去")
    }

    func testAddedAlbumAndItsArtistAreSearchable() {
        let store = makeFixture().store
        let album = makeAlbum("qq:albumE", name: "告五人", artist: "告五人")
        store.addAlbumToLibrary(album, tracks: [
            makeTrack("qq:t10", title: "唯一", artist: "告五人", album: album, number: 1),
        ])
        XCTAssertEqual(albums(store, "五人"), ["告五人"])
        XCTAssertEqual(artists(store, "五人"), ["告五人"])
        XCTAssertEqual(artists(store, "gwr"), ["告五人"])
    }

    func testCreatedPlaylistIsSearchable() {
        let store = makeFixture().store
        store.createPlaylist(name: "夜曲")
        XCTAssertEqual(playlists(store, "夜曲"), ["夜曲"])
        XCTAssertEqual(playlists(store, "yq"), ["夜曲"])
    }

    // MARK: - 维护：改

    /// 改名之后：新名字搜得到、**旧名字搜不到**。
    /// 后一半才是重点——只补不撤的话，索引会攒下一堆搜得到却打不开的幽灵。
    func testRenamedPlaylistLosesItsOldName() {
        let store = makeFixture().store
        let playlist = store.createPlaylist(name: "夜曲")
        store.renamePlaylist(id: playlist.id, to: "以父之名")
        XCTAssertEqual(playlists(store, "以父"), ["以父之名"])
        XCTAssertEqual(playlists(store, "夜曲"), [])
    }

    /// 「显示简介」面板改曲名 / 艺人名之后，搜索跟着换。
    func testEditedTrackTitleAndArtistFollow() {
        let store = makeFixture().store
        _ = store.updateTrack(id: "qq:t2") { track in
            track.title = "夜曲"
            track.artistName = "周杰倫"
        }
        XCTAssertEqual(songs(store, "夜曲"), ["夜曲"])
        XCTAssertEqual(songs(store, "七里香"), [], "旧曲名还搜得到，说明只补没撤")
        XCTAssertEqual(songs(store, "qlx"), [], "旧拼音也该跟着撤")
    }

    /// 改掉资料库里最后一首某艺人的歌，那位艺人从索引里消失、新艺人补进来。
    /// 艺人是派生的，没有自己的增删改调用点，这条守的就是那次「对账」。
    func testArtistIndexFollowsRenames() {
        let store = makeFixture().store
        XCTAssertEqual(artists(store, "RADWIMPS"), ["RADWIMPS"])
        _ = store.updateTrack(id: "qq:t4") { $0.artistName = "米津玄師" }
        XCTAssertEqual(artists(store, "RADWIMPS"), [], "没人引用的艺人还留在索引里")
        XCTAssertEqual(artists(store, "米津"), ["米津玄師"])
        // 与艺人页现算的那份是同一批人（同一份 `artists(from:)` 规则）。
        XCTAssertEqual(Set(artists(store, "")), Set(store.libraryArtists().map(\.name)))
    }

    // MARK: - 维护：删

    func testRemovedAlbumLeavesTheIndex() {
        let fixture = makeFixture()
        let store = fixture.store
        XCTAssertEqual(albums(store, "惠美"), ["葉惠美"])
        store.removeAlbumFromLibrary(fixture.album, tracks: store.tracks(in: fixture.album))
        XCTAssertEqual(albums(store, "惠美"), [])
        XCTAssertEqual(artists(store, "周杰"), [], "碟与歌都没了，艺人也该跟着撤")
    }

    func testDeletedPlaylistLeavesTheIndex() throws {
        let store = makeFixture().store
        let playlist = try XCTUnwrap(store.playlists.first { $0.name == "七里香" })
        store.deletePlaylist(id: playlist.id)
        XCTAssertEqual(playlists(store, "七里香"), [])
        XCTAssertEqual(try indexRows("playlist"), 1)
    }

    /// 整批改列表（账号同步走的就是这条）摘掉的那几份，索引也要跟着摘。
    /// 这条路不经过 `deletePlaylist`，走的是 `persistAllPlaylists` 里那个删除循环。
    func testBulkPlaylistUpdateDropsRemovedRowsFromTheIndex() throws {
        let store = makeFixture().store
        store.updatePlaylists { $0.removeAll { $0.name == "七里香" } }
        XCTAssertEqual(playlists(store, "七里香"), [])
        XCTAssertEqual(try indexRows("playlist"), 1)
        // 同一次里补进来的那份要在。
        store.updatePlaylists { $0.append(.local(name: "東風破", tracks: [])) }
        XCTAssertEqual(playlists(store, "東風破"), ["東風破"])
    }

    /// **退库不删索引里那条曲目**，这是有意的：`track` 表故意不做 GC，索引与它一一对应。
    /// 多出来的 id 不会凭空多出一行——七处搜索筛的是各自手里那份数组，
    /// 而这首歌已经不在 `libraryTracks` 里了。
    func testRemovedTrackStaysIndexedButDisappearsFromThePage() throws {
        let store = makeFixture().store
        let track = try XCTUnwrap(store.libraryTracks.first { $0.title == "帶你飛" })
        let before = try indexRows("track")
        store.removeFromLibrary(track)
        XCTAssertEqual(try indexRows("track"), before, "曲目索引跟着退库走了，与 track 表对不上")
        XCTAssertEqual(songs(store, "你飛"), [], "页面上还留着这首歌")
    }

    // MARK: - 重建

    /// 重建是**幂等**的：连跑两次，行数与命中一个不差。
    /// 这条撑着「哪天要再修一次，加一条升级链调同一个函数即可」那句话。
    func testRebuildIsIdempotent() throws {
        let store = makeFixture().store
        let db = try connection()
        let before = try db.value("SELECT COUNT(*) FROM search_index") { $0.int(0) }

        try LibrarySearchIndex.rebuild(in: db)
        XCTAssertEqual(try db.value("SELECT COUNT(*) FROM search_index") { $0.int(0) }, before)
        try LibrarySearchIndex.rebuild(in: db)
        XCTAssertEqual(try db.value("SELECT COUNT(*) FROM search_index") { $0.int(0) }, before)
        XCTAssertEqual(songs(store, "你飛"), ["帶你飛"])
        XCTAssertEqual(artists(store, "周杰"), ["周杰倫"])
    }

    /// 重建覆盖四类对象，一类不落。
    func testRebuildCoversAllFourKinds() throws {
        let store = makeFixture().store
        let db = try connection()
        try db.run("DELETE FROM search_index")
        try LibrarySearchIndex.rebuild(in: db)

        XCTAssertEqual(try indexRows("track"), store.libraryTracks.count)
        XCTAssertEqual(try indexRows("album"), store.libraryAlbums.count)
        XCTAssertEqual(try indexRows("playlist"), store.playlists.count)
        XCTAssertEqual(try indexRows("artist"), store.libraryArtists().count)
    }

    /// 重建之后**维护还能接着走**：`LibraryStore` 那份内存指纹是开库时从表里现读的，
    /// 而重建发生在开库路径上（v4）——顺序反了的话，指纹会以为某些行已经在表里而跳过写入。
    func testMaintenanceStillWorksOnAReopenedStore() throws {
        do {
            let store = makeFixture().store
            store.flushNow()
        }
        let reopened = LibraryStore(directory: directory)
        XCTAssertEqual(songs(reopened, "你飛"), ["帶你飛"])
        reopened.createPlaylist(name: "夜曲")
        XCTAssertEqual(playlists(reopened, "夜曲"), ["夜曲"])
        // 重开之后改名也要能撤掉旧行（指纹读对了才撤得掉）。
        let playlist = try XCTUnwrap(reopened.playlists.first { $0.name == "七里香" })
        reopened.renamePlaylist(id: playlist.id, to: "東風破")
        XCTAssertEqual(playlists(reopened, "七里香"), [])
        XCTAssertEqual(playlists(reopened, "東風破"), ["東風破"])
    }

    // MARK: - 退路

    /// **写库失败之后搜索仍然搜得到东西。**
    ///
    /// 与阶段 7 的 `mirrorIsStale` 同一个口径：表只是加速器、内存数组仍是真值，
    /// 绝不能让一次故障表现成「搜什么都没有」。竖着陈旧位时 `searchFilter` 退回
    /// 内存子串筛选——那正是这次改造之前那套，召回只会更宽（`aylor` 又能搜到 `Taylor`）。
    func testFallsBackToSubstringAfterAFailedWrite() throws {
        let store = makeFixture().store
        XCTAssertFalse(store.mirrorIsStale)

        let db = try connection()
        try db.execute("PRAGMA query_only = ON")
        defer { try? db.execute("PRAGMA query_only = OFF") }
        store.createPlaylist(name: "夜曲")          // 落库失败，陈旧位竖起来
        XCTAssertTrue(store.mirrorIsStale)

        // 内存里有这份新列表，表里没有——退路答的是内存那份。
        XCTAssertEqual(playlists(store, "夜曲"), ["夜曲"])
        XCTAssertEqual(songs(store, "帶你飛"), ["帶你飛"])
        // 退路是子串匹配，所以那条「拉丁收窄为词前缀」的规则在这条路上不成立。
        XCTAssertEqual(songs(store, "aylor"), ["Love Story"])
        // 空串照旧返回全部。
        XCTAssertEqual(songs(store, ""), store.libraryTracks.map(\.title))
    }

    /// 库根本没开起来（或者查询抛错）也走同一条退路。这里把表整个删掉来造查询错误。
    func testFallsBackWhenTheQueryThrows() throws {
        let store = makeFixture().store
        try connection().execute("DROP TABLE search_index")
        XCTAssertEqual(songs(store, "帶你飛"), ["帶你飛"])
        XCTAssertEqual(albums(store, "葉惠美"), ["葉惠美"])
    }
}
