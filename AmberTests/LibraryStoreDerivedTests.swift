import XCTest
@testable import Amber

/// 资料库派生数据（LibraryViews 接入用的三件）与「最近添加」分段的测试。
///
/// `LibraryStore` 注入临时目录，绝不碰真实的 `~/Library/Application Support/Amber/`。
@MainActor
final class LibraryStoreDerivedTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> LibraryStore { LibraryStore(directory: directory) }

    private func makeAlbum(_ id: String, name: String, artist: String,
                           artwork: String? = nil) -> Album {
        Album(id: id, kind: .qq, name: name, artistName: artist, artistId: nil,
              artworkURL: artwork ?? "https://example.com/\(id).jpg", publishDate: "2025-06-06",
              trackCount: 0, description: nil)
    }

    private func makeTrack(_ id: String, title: String, artist: String, album: Album,
                           trackNumber: Int? = nil, discNumber: Int? = nil) -> Track {
        Track(id: id, kind: .qq, title: title, artistName: artist, artistId: nil,
              albumName: album.name, albumId: album.id, artworkURL: nil, duration: 180,
              trackNumber: trackNumber, discNumber: discNumber)
    }

    // MARK: - 艺人派生

    func testArtistsDerivedFromAlbumsThenTracks() {
        let store = makeStore()
        let album = makeAlbum("qq:a1", name: "帶你飛", artist: "告五人")
        store.addAlbumToLibrary(album, tracks: [makeTrack("qq:t1", title: "又到天黑",
                                                          artist: "告五人", album: album)])
        // 未随碟入库的单曲也派生艺人
        let single = makeTrack("qq:t2", title: "孤曲", artist: "宇多田光",
                               album: makeAlbum("qq:s1", name: "单曲", artist: "宇多田光"))
        store.addToLibrary(single)

        let artists = store.libraryArtists()
        // 「告」(U+544A) 与「宇」(U+5B87) 的拼音序与码点序一致，跨 locale 稳定。
        XCTAssertEqual(artists.map(\.name), ["告五人", "宇多田光"])
        // 头像由界面层按艺人名向音源解析，store 不给——不能拿专辑封面顶替。
        XCTAssertNil(artists[0].avatarURL)
        XCTAssertEqual(artists[0].id, "library-artist:告五人")
    }

    func testAlbumsAndTracksByArtist() {
        let store = makeStore()
        let albumA = makeAlbum("qq:a1", name: "第一张", artist: "告五人")
        let albumB = makeAlbum("qq:a2", name: "第二张", artist: "告五人")
        store.addAlbumToLibrary(albumA, tracks: [
            makeTrack("qq:t1", title: "曲一", artist: "告五人", album: albumA, trackNumber: 2),
            makeTrack("qq:t2", title: "曲二", artist: "告五人", album: albumA, trackNumber: 1),
        ])
        store.addAlbumToLibrary(albumB, tracks: [
            makeTrack("qq:t3", title: "曲三", artist: "告五人", album: albumB, trackNumber: 1),
        ])

        XCTAssertEqual(store.albums(byArtist: "告五人").map(\.name), ["第二张", "第一张"])
        // 碟内按音轨号排
        XCTAssertEqual(store.tracks(in: albumA).map(\.title), ["曲二", "曲一"])
        // 全部曲目按「最近添加的碟在前」，碟内按曲序
        XCTAssertEqual(store.tracks(byArtist: "告五人").map(\.title),
                       ["曲三", "曲二", "曲一"])
    }

    // MARK: - 排序切成 SQL + Swift 两半之后

    /// **同一张碟、同一个音轨号、标题里带数字**：逼最后那道比较子出场，
    /// 钉住它排的是**自然序**而不是字节序。
    ///
    /// `tracks(byArtist:)` 的排序现在切成两半——碟序与碟内曲序由 SQL 排，
    /// 标题那一级在 Swift 里对「SQL 认为并列」的那一撮做。标题那级用的是
    /// `localizedStandardCompare`：数字按值比，`第2首` 在 `第10首` 前面。
    /// 换成 SQLite 的 `ORDER BY title` 就是 UTF-8 字节序，`'1' < '2'`，
    /// `第10首` 会跑到前面去。
    ///
    /// **危险的地方在于大部分歌看起来还是对的**：音轨号一路唯一时最后那道比较子
    /// 根本不出场，改坏了也没人报 bug。所以这里三首歌的音轨号故意撞在一起——
    /// 不撞就什么都测不到。第三首（`第1首`、音轨号 2）守的是另一半：
    /// 标题只在并列的那一撮里说话，不许越过音轨号那一级。
    func testTitlesTiedOnDiscAndNumberSortNaturallyNotByBytes() {
        let store = makeStore()
        let album = makeAlbum("qq:a1", name: "同一张碟", artist: "告五人")
        store.addAlbumToLibrary(album, tracks: [
            makeTrack("qq:t1", title: "第10首", artist: "告五人", album: album, trackNumber: 1),
            makeTrack("qq:t2", title: "第2首", artist: "告五人", album: album, trackNumber: 1),
            makeTrack("qq:t3", title: "第1首", artist: "告五人", album: album, trackNumber: 2),
        ])

        XCTAssertEqual(store.tracks(byArtist: "告五人").map(\.title),
                       ["第2首", "第10首", "第1首"],
                       "标题那一级不是自然序了（字节序会排成 第10首 / 第2首）")
    }

    /// 碟号那一级由 SQL 排，`COALESCE(disc_number, 0)` 对应内存那版的 `discNumber ?? 0`：
    /// 没写碟号的算第 0 碟，排在第 2 碟前面。碟号相同才轮到音轨号。
    func testDiscNumberOrdersBeforeTrackNumber() {
        let store = makeStore()
        let album = makeAlbum("qq:a1", name: "双碟", artist: "告五人")
        store.addAlbumToLibrary(album, tracks: [
            makeTrack("qq:d2t1", title: "二碟首曲", artist: "告五人", album: album,
                      trackNumber: 1, discNumber: 2),
            makeTrack("qq:d1t9", title: "一碟末曲", artist: "告五人", album: album,
                      trackNumber: 9, discNumber: 1),
            makeTrack("qq:d0t5", title: "没写碟号", artist: "告五人", album: album,
                      trackNumber: 5),
        ])

        XCTAssertEqual(store.tracks(byArtist: "告五人").map(\.title),
                       ["没写碟号", "一碟末曲", "二碟首曲"])
    }

    /// 艺人的音源取自**第一张**挂这个名字的入库专辑，专辑都没有才退到单曲——
    /// 这份「先专辑后单曲」的优先级现在由 SQL 那条 `UNION ALL` 的 `tier` 列表达，
    /// 去重与排序仍在 Swift 里。
    func testArtistKindComesFromAlbumNotTrack() {
        let store = makeStore()
        let album = Album(id: "nc:a1", kind: .netease, name: "网易的碟", artistName: "告五人",
                          artistId: nil, artworkURL: nil, publishDate: nil, trackCount: 1,
                          description: nil)
        store.addAlbumToLibrary(album, tracks: [])
        // 同名艺人的一首 QQ 单曲：晚于专辑，抢不走音源
        store.addToLibrary(Track(id: "qq:t1", kind: .qq, title: "单曲", artistName: "告五人",
                                 artistId: nil, albumName: "别的碟", albumId: nil,
                                 artworkURL: nil, duration: 180))

        XCTAssertEqual(store.libraryArtists().map(\.kind), [.netease])
    }

    /// **写库失败之后，界面读到的仍然是对的。**
    ///
    /// 这是关系查询从读内存数组换成读表之后多出来的失败形状：`persist` 吞错只记日志
    ///（理由见它自己的注释），一次写失败会让表落在内存后面，而读表的查询当场就答错
    /// ——刚入库的碟不出现在艺人页上，不用等重启。处置是 `LibraryStore.mirrorIsStale`：
    /// 写失败就把读路径退回内存那份现算，口径回到「写库失败只丢持久化，不丢当场的正确性」。
    ///
    /// 失败是真造出来的：把连接设成 `query_only`，`persist` 里那句 `BEGIN IMMEDIATE`
    /// 当场拿到 `SQLITE_READONLY`（实测：query_only 下写事务开都开不起来）。
    func testDerivedQueriesFallBackToMemoryAfterAFailedWrite() throws {
        let store = makeStore()
        let first = makeAlbum("qq:a1", name: "第一张", artist: "告五人")
        store.addAlbumToLibrary(first, tracks: [
            makeTrack("qq:t1", title: "曲一", artist: "告五人", album: first, trackNumber: 1),
        ])
        XCTAssertFalse(store.mirrorIsStale)

        // store 与这里共用同一条连接（`AmberDatabase.shared(directory:)` 按目录记忆化）
        let database = try AmberDatabase.shared(directory: directory)
        try database.sqlite.execute("PRAGMA query_only = ON")
        defer { try? database.sqlite.execute("PRAGMA query_only = OFF") }

        let second = makeAlbum("nc:a2", name: "第二张", artist: "宇多田光")
        store.addAlbumToLibrary(second, tracks: [
            makeTrack("nc:t2", title: "曲二", artist: "宇多田光", album: second, trackNumber: 1),
        ])
        XCTAssertTrue(store.mirrorIsStale, "落库失败了却没把陈旧位竖起来")

        // 表里只有第一张碟，内存里有两张——三条派生查询都必须答内存那份
        XCTAssertEqual(store.libraryArtists().map(\.name), ["告五人", "宇多田光"])
        XCTAssertEqual(store.albums(byArtist: "宇多田光").map(\.name), ["第二张"])
        XCTAssertEqual(store.tracks(byArtist: "宇多田光").map(\.title), ["曲二"])
    }

    // MARK: - 同名专辑不串曲目

    /// 资料库里同时有两张《太阳之子》：一张「文件 › 导入…」进来的本地碟（无封面）、
    /// 一张 QQ 的（有封面）。早先 `tracks(in:)` 是「id 相同 **或** 专辑名相同」，
    /// 那个 `||` 把两张碟串成一份并集——艺人页上两个块列的曲目一模一样。
    func testSameNamedAlbumsKeepTheirOwnTracks() {
        let store = makeStore()
        let imported = Album(id: Album.localIDPrefix + "sun", kind: .qq, name: "太阳之子",
                             artistName: "告五人", artistId: nil, artworkURL: nil,
                             publishDate: nil, trackCount: 1, description: nil)
        let online = makeAlbum("qq:sun", name: "太阳之子", artist: "告五人",
                               artwork: "https://example.com/sun.jpg")
        store.addAlbumToLibrary(imported, tracks: [
            Track(id: Track.localIDPrefix + "f1", kind: .qq, title: "本地曲", artistName: "告五人",
                  artistId: nil, albumName: "太阳之子", albumId: nil, artworkURL: nil,
                  duration: 180),
        ])
        store.addAlbumToLibrary(online, tracks: [
            makeTrack("qq:t1", title: "在线曲", artist: "告五人", album: online),
        ])

        XCTAssertEqual(store.tracks(in: imported).map(\.title), ["本地曲"])
        XCTAssertEqual(store.tracks(in: online).map(\.title), ["在线曲"])
        // 入库时 `stamped` 会补上 albumId，两首各自认得回自己那张碟。
        for track in store.tracks(in: imported) {
            XCTAssertEqual(store.album(for: track)?.id, imported.id)
            XCTAssertNil(store.album(for: track)?.artworkURL, "本地碟拿到了 QQ 那张的封面")
        }
        XCTAssertEqual(store.album(for: store.tracks(in: online)[0])?.id, online.id)
    }

    /// 没有 `albumId` 的曲目（音源的歌单/搜索结果常常不带专辑节点）按名字归位时，
    /// **艺人得对得上**：同名不同艺人的两张碟不能互相认领。
    func testNamelessFallbackNeedsMatchingArtist() {
        let store = makeStore()
        let mine = makeAlbum("qq:a1", name: "同名碟", artist: "告五人")
        let theirs = makeAlbum("qq:a2", name: "同名碟", artist: "另一个人")
        store.addAlbumToLibrary(mine, tracks: [])
        store.addAlbumToLibrary(theirs, tracks: [])

        func loose(_ artist: String) -> Track {
            Track(id: "qq:x-\(artist)", kind: .qq, title: "曲", artistName: artist, artistId: nil,
                  albumName: "同名碟", albumId: nil, artworkURL: nil, duration: 180)
        }
        // 两张碟各自查得到自己那张——后入库的那张不该被前一张挡住。
        XCTAssertEqual(store.album(for: loose("告五人"))?.id, mine.id)
        XCTAssertEqual(store.album(for: loose("另一个人"))?.id, theirs.id)
        // 大小写与前后空白无关。
        XCTAssertEqual(store.album(for: loose("  告五人 "))?.id, mine.id)
        // 谁的艺人都对不上：宁可答 nil，也不拿一张同名的顶上。
        XCTAssertNil(store.album(for: loose("第三个人")))

        // 归位判定与 `album(for:)` 同解：入了库也只落在自己那张碟下。
        store.addToLibrary(loose("告五人"))
        store.addToLibrary(loose("第三个人"))
        XCTAssertEqual(store.tracks(in: mine).map(\.artistName), ["告五人"])
        XCTAssertTrue(store.tracks(in: theirs).isEmpty, "同名不同艺人的碟把别人的歌认领了")
    }

    /// 曲目带着一个资料库里没有的 `albumId`（在目录里翻到的碟还没入库）：
    /// 不再退回按名字查——那只会给出一张同名碟的曲风/封面，认错人比查不到更糟。
    func testUnknownAlbumIdDoesNotFallBackToName() {
        let store = makeStore()
        let album = makeAlbum("qq:a1", name: "太阳之子", artist: "告五人")
        store.addAlbumToLibrary(album, tracks: [])
        let stranger = Track(id: "ne:9", kind: .netease, title: "曲", artistName: "告五人",
                             artistId: nil, albumName: "太阳之子", albumId: "ne:404",
                             artworkURL: nil, duration: 180)
        XCTAssertNil(store.album(for: stranger))
        XCTAssertTrue(store.tracks(in: album).isEmpty)
    }

    // MARK: - 专辑添加时间（最近添加分段的数据源）

    func testAlbumAddedDatePersists() {
        let store = makeStore()
        let album = makeAlbum("qq:a1", name: "帶你飛", artist: "告五人")
        store.addAlbumToLibrary(album, tracks: [])
        store.flushNow()   // 写盘是防抖的，断言磁盘内容前先同步落一次

        let restored = makeStore()
        XCTAssertNotNil(restored.albumAddedDate(for: album))
    }

    /// 老存档只有曲目的 addedAt（没有 albumAddedAt 键）：回落取碟内曲目的最大值。
    ///
    /// **回落算在哪儿变了，断言一个字没改。** 从前它是 `albumAddedDate(for:)` 里
    /// 每问一次就扫一遍 `libraryTracks` 的 O(n) 兜底（「最近添加」一屏 40 张碟 = 40 遍全表扫）；
    /// 现在迁移时算一次、写死进 `library_album.added_at`，运行期那段兜底删掉了。
    /// fixture 里那个手算的 `timeIntervalSinceReferenceDate` 仍然有效——
    /// SQLite 这边存的也是同一个纪元的 REAL 秒数（见 `SQLBindable` 对 `Date` 那条扩展）。
    func testAlbumAddedDateFallsBackToTracks() throws {
        // 注意 JSONEncoder 对 Date 的默认编码是「2001 参考日期以来的秒数」。
        let added = Date(timeIntervalSinceNow: -86_400).timeIntervalSinceReferenceDate
        let json = """
        {"favorites":[],"recents":[],
         "libraryTracks":[{"id":"qq:t1","kind":"qq","title":"曲一","artistName":"告五人",
                           "artistId":null,"albumName":"帶你飛","albumId":"qq:a1",
                           "artworkURL":null,"duration":180}],
         "libraryAlbums":[{"id":"qq:a1","kind":"qq","name":"帶你飛","artistName":"告五人",
                           "artistId":null,"artworkURL":null,"publishDate":"2025-06-06",
                           "trackCount":1,"description":null}],
         "addedAt":{"qq:t1":\(added)}}
        """
        try json.data(using: .utf8)!.write(to: directory.appendingPathComponent("library.json"))

        let store = makeStore()
        let album = store.libraryAlbums[0]
        XCTAssertNotNil(store.albumAddedDate(for: album))
        XCTAssertEqual(store.tracks(in: album).count, 1)
    }

    // MARK: - 收藏艺人（目录艺人页 hero 上那枚 ★）

    private func makeArtist(_ id: String, name: String) -> Artist {
        Artist(id: id, kind: .qq, name: name, avatarURL: nil, description: nil)
    }

    func testFavoriteArtistPersists() {
        let store = makeStore()
        let artist = makeArtist("qq:ar1", name: "告五人")
        XCTAssertFalse(store.isFavoriteArtist(artist))

        store.toggleFavoriteArtist(artist)
        XCTAssertTrue(store.isFavoriteArtist(artist))
        store.flushNow()   // 写盘是防抖的，断言磁盘内容前先同步落一次

        XCTAssertTrue(makeStore().isFavoriteArtist(artist))

        // 再切一次就是取消收藏，同样要落盘
        store.toggleFavoriteArtist(artist)
        store.flushNow()
        XCTAssertFalse(makeStore().isFavoriteArtist(artist))
    }

    /// 旧存档没有 `favoriteArtists` 键：迁移不能坏，其余字段照常搬进库里。
    ///
    /// 同构地搬了家：缺键 → 对应那张表 0 行。从前这条守的是 `Storage` 里一串
    /// `decodeIfPresent`，现在守的是 `LegacyLibraryArchive` 那 17 个可选字段——
    /// 它们的可选性表达的是「这个键可能根本不在文件里」，不是「这个值可以为空」。
    func testLegacyArchiveWithoutFavoriteArtistsDecodes() throws {
        let json = """
        {"favorites":[],"recents":[],"favoriteAlbums":["qq:a1"]}
        """
        try json.data(using: .utf8)!.write(to: directory.appendingPathComponent("library.json"))

        let store = makeStore()
        XCTAssertEqual(store.favoriteArtistIDs, [])
        XCTAssertEqual(store.favoriteAlbumIDs, ["qq:a1"])
        XCTAssertFalse(store.isFavoriteArtist(makeArtist("qq:ar1", name: "告五人")))
    }

    // MARK: - 最近添加分段

    func testRecentBucketOrdering() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        // 固定「现在」：2026-09-30 15:00 周三。gregorian 默认周日起步，
        // 本周 = 09-27（周日）… 10-03（周六）。挑月末的日子，本月里才有
        // 「已出本周」的过去日期可测 thisMonth。
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15))!
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
        }

        XCTAssertEqual(RecentAddedBucket.bucket(of: now, calendar: calendar, now: now), .today)
        XCTAssertEqual(RecentAddedBucket.bucket(of: at(2026, 9, 29), calendar: calendar, now: now),
                       .yesterday)
        // 本周日（09-27），不与今天/昨天重叠
        XCTAssertEqual(RecentAddedBucket.bucket(of: at(2026, 9, 27), calendar: calendar, now: now),
                       .thisWeek)
        // 上周六（09-26）
        XCTAssertEqual(RecentAddedBucket.bucket(of: at(2026, 9, 26), calendar: calendar, now: now),
                       .lastWeek)
        // 本月 09-15（已出上周，还在九月）
        XCTAssertEqual(RecentAddedBucket.bucket(of: at(2026, 9, 15), calendar: calendar, now: now),
                       .thisMonth)
        // 今年 8-1（上月已过）
        XCTAssertEqual(RecentAddedBucket.bucket(of: at(2026, 8, 1), calendar: calendar, now: now),
                       .thisYear)
        // 去年
        XCTAssertEqual(RecentAddedBucket.bucket(of: at(2025, 12, 31), calendar: calendar, now: now),
                       .earlier)
    }

    func testBucketTitles() {
        XCTAssertEqual(RecentAddedBucket.allCases.map(\.title),
                       ["今天", "昨天", "本周", "上周", "本月", "今年", "更早"])
    }

    // MARK: - 幽灵空专辑清理与艺人跳转

    func testRemoveLastTrackPrunesEmptyAlbum() {
        let store = makeStore()
        let album = makeAlbum("qq:a1", name: "带你飞", artist: "告五人")
        let track = makeTrack("qq:t1", title: "又到天黑", artist: "告五人", album: album)
        store.addAlbumToLibrary(album, tracks: [track])
        XCTAssertEqual(store.libraryAlbums.count, 1)

        store.removeFromLibrary(track)
        XCTAssertTrue(store.libraryAlbums.isEmpty, "移出最后一首歌后所属空专辑应被清理")
        XCTAssertFalse(store.isAlbumInLibrary(album))
    }

    /// 启动载入时清掉没有曲目的本地幽灵碟。
    ///
    /// **这条规则留在 `load()` 里，没有搬进迁移器。** 计划里说把它写成迁移末尾一条
    /// `DELETE … WHERE NOT EXISTS`，但那样只管得着「从 JSON 迁过来的那一刻」——
    /// 这条用例走的正是另一条路：库早就建好了，之后才加进一张空的本地碟、退出、重开，
    /// 迁移一次都不会再跑。语义一字不改，只是清完顺手把表里那几行也删掉。
    func testOrphanLocalAlbumPrunedOnLoad() {
        let store = makeStore()
        let localAlbum = Album(id: Album.localIDPrefix + "ghost", kind: .qq, name: "幽灵碟",
                               artistName: "告五人", artistId: nil, artworkURL: nil,
                               publishDate: nil, trackCount: 0, description: nil)
        store.addAlbumToLibrary(localAlbum, tracks: [])
        store.flushNow()

        let restored = makeStore()
        XCTAssertFalse(restored.libraryAlbums.contains(where: { $0.id == localAlbum.id }),
                       "启动载入时没有曲目的本地幽灵专辑应被清理")
    }

    func testTrackCanGoToArtist() {
        let onlineWithID = Track(id: "qq:t1", kind: .qq, title: "歌", artistName: "告五人",
                                 artistId: "qq:artist:1", albumName: "碟", albumId: nil,
                                 artworkURL: nil, duration: 180)
        XCTAssertTrue(onlineWithID.canGoToArtist)

        let localWithName = Track(id: Track.localIDPrefix + "t1", kind: .qq, title: "歌",
                                  artistName: "告五人", artistId: nil, albumName: "碟",
                                  albumId: nil, artworkURL: nil, duration: 180)
        XCTAssertTrue(localWithName.canGoToArtist)

        let unknownArtist = Track(id: Track.localIDPrefix + "t2", kind: .qq, title: "歌",
                                  artistName: ImportService.unknownArtist, artistId: nil,
                                  albumName: "碟", albumId: nil, artworkURL: nil, duration: 180)
        XCTAssertFalse(unknownArtist.canGoToArtist)

        let emptyArtist = Track(id: Track.localIDPrefix + "t3", kind: .qq, title: "歌",
                                artistName: "   ", artistId: nil, albumName: "碟",
                                albumId: nil, artworkURL: nil, duration: 180)
        XCTAssertFalse(emptyArtist.canGoToArtist)
    }
}
