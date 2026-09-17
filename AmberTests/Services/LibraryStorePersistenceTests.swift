import Combine
import XCTest
@testable import Amber

/// `LibraryStore` 把持久化从「整份 JSON 重写」换成「SQLite 定向写」之后，
/// 那几条**看不见的约定**：
///
/// 1. `ORDER BY position` 排出来的顺序 == 内存数组的顺序（不要求 position 连续）；
/// 2. 一次播放记账就是**一行** UPSERT，不是整张表重写；
/// 3. `updateTrack` 的 `LibraryChange` 掩码从「哪几个数组真变了」换成
///    「这个 id 落在哪几张关系表」之后**逐位等价**。
///
/// 第 1 条与第 3 条都是「写错了照样跑得动、界面上要过几天才看得出来」的那一类：
/// 顺序错了表现是「最近添加的歌跑到中间去了」，掩码错了表现是「改完标题那一页没刷新」
/// 或者反过来「改一首歌的标题，专辑网格白重排一次」。
///
/// `LibraryStore` 注入临时目录，绝不碰真实的 `~/Library/Application Support/Amber/`。
@MainActor
final class LibraryStorePersistenceTests: XCTestCase {

    private var directory: URL!
    private var savedValues: SettingsValues!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStorePersistence-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 记账受「使用听歌历史记录」开关管，而那条开关读的是**真实**偏好
        //（测试宿主就是 Amber 本身），所以整份存下来、跑完原样还回去。
        savedValues = AppSettings.shared.values
        AppSettings.shared.values.useListeningHistory = true
    }

    override func tearDown() async throws {
        AppSettings.shared.values = savedValues
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> LibraryStore { LibraryStore(directory: directory) }

    /// 与 store 同一条连接（`AmberDatabase` 按目录记忆化），可以直接查表核对。
    private func openDatabase() throws -> SQLiteDatabase {
        try AmberDatabase.shared(directory: directory).sqlite
    }

    private func makeTrack(_ suffix: String, title: String = "曲",
                           albumId: String? = "qq:album:1") -> Track {
        Track(id: "qq:\(suffix)", kind: .qq, title: title, artistName: "某人", artistId: nil,
              albumName: "某碟", albumId: albumId, artworkURL: nil, duration: 200)
    }

    private func ids(_ db: SQLiteDatabase, _ table: String) throws -> [String] {
        try db.query("SELECT track_id FROM \(table) ORDER BY position", [], { $0.text(0) })
    }

    // MARK: - position：顺序对得上，连续不连续无所谓

    /// 加到最前面就是加到最前面——三张有序关系表都按 `ORDER BY position` 与数组逐位相同。
    func testOrderedTablesMirrorArrayOrder() throws {
        let store = makeStore()
        let tracks = (0..<5).map { makeTrack("t\($0)", title: "曲\($0)") }
        for track in tracks {
            store.addToLibrary(track)
            store.toggleFavorite(track)
            store.noteStarted(track)
        }
        let db = try openDatabase()
        XCTAssertEqual(try ids(db, "library_track"), store.libraryTracks.map(\.id))
        XCTAssertEqual(try ids(db, "favorite_track"), store.favoriteTracks.map(\.id))
        XCTAssertEqual(try ids(db, "recent_track"), store.recentTracks.map(\.id))
        // 最新的在最前，四条数组与四张表是同一个方向。
        XCTAssertEqual(store.libraryTracks.first?.id, "qq:t4")
    }

    /// 删掉中间一条之后：**position 会留下空洞，这是有意的**——补洞要把它后面的每一行
    /// 都重排一次，那又是一次全表写，而空洞对「按 position 排」没有任何影响。
    /// 这条用例钉住的是「留洞」这个决定本身，免得以后有人顺手「整理一下」。
    func testRemovalLeavesAGapAndOrderStillHolds() throws {
        let store = makeStore()
        let tracks = (0..<4).map { makeTrack("t\($0)") }
        for track in tracks { store.addToLibrary(track) }
        store.removeFromLibrary(tracks[2])

        let db = try openDatabase()
        XCTAssertEqual(try ids(db, "library_track"), store.libraryTracks.map(\.id))
        let positions = try db.query("SELECT position FROM library_track ORDER BY position", [],
                                     { Int($0.int(0)) })
        XCTAssertEqual(positions.count, 3)
        XCTAssertNotEqual(positions, Array(0..<3), "空洞被补上了——那是一次白花的全表重排")
    }

    /// 整张碟入库时那一批歌只让一次位，而且碟内保持原曲序。
    func testAlbumBatchKeepsTrackOrder() throws {
        let store = makeStore()
        let album = Album(id: "qq:album:1", kind: .qq, name: "某碟", artistName: "某人",
                          artistId: nil, artworkURL: nil, publishDate: nil, trackCount: 3,
                          description: nil)
        let tracks = (0..<3).map { makeTrack("a\($0)", title: "第\($0)首") }
        store.addToLibrary(makeTrack("old", title: "老歌", albumId: nil))
        store.addAlbumToLibrary(album, tracks: tracks)

        let db = try openDatabase()
        XCTAssertEqual(try ids(db, "library_track"), store.libraryTracks.map(\.id))
        XCTAssertEqual(store.libraryTracks.map(\.title), ["第0首", "第1首", "第2首", "老歌"])
    }

    /// 列表里的重排落到 `playlist_track` 上。
    func testPlaylistReorderMirrors() throws {
        let store = makeStore()
        let tracks = (0..<4).map { makeTrack("p\($0)") }
        let playlist = store.createPlaylist(name: "单", tracks: tracks)
        store.moveTracks(fromOffsets: IndexSet(integer: 3), toOffset: 0, inPlaylist: playlist.id)

        let db = try openDatabase()
        let stored = try db.query("""
            SELECT track_id FROM playlist_track WHERE playlist_id = ? ORDER BY position
            """, [playlist.id], { $0.text(0) })
        XCTAssertEqual(stored, store.playlist(id: playlist.id)?.tracks.map(\.id))
        XCTAssertEqual(stored.first, "qq:p3")
    }

    /// 逐曲历史的 200 条上限在表那边也成立（position 有空洞，截顶不能按数字截）。
    func testRecentTracksAreCappedInTheTable() throws {
        let store = makeStore()
        for index in 0..<210 { store.noteStarted(makeTrack("r\(index)")) }
        let db = try openDatabase()
        let stored = try ids(db, "recent_track")
        XCTAssertEqual(stored.count, 200)
        XCTAssertEqual(stored, store.recentTracks.map(\.id))
        XCTAssertEqual(stored.first, "qq:r209")
    }

    // MARK: - 记账：一次播放一行

    /// `notePlayed` 是一条单行 UPSERT，不是整张 `track_stat` 重写。
    ///
    /// 断言的是结果侧的两件事：连放三遍只留**一行**，而那一行的次数是 3；
    /// 而且别的歌那一行**一个字没动**（整表重写的话，它的 `added_at` 会被顺手重写一遍）。
    func testNotePlayedUpsertsASingleRow() throws {
        let store = makeStore()
        let played = makeTrack("hot")
        let other = makeTrack("cold")
        store.addToLibrary(other)
        let db = try openDatabase()
        let otherAddedAt = try db.value("SELECT added_at FROM track_stat WHERE track_id = ?",
                                        [other.id], { $0.double(0) })

        for _ in 0..<3 { store.notePlayed(played) }

        let rows = try db.query("""
            SELECT play_count, last_played_at FROM track_stat WHERE track_id = ?
            """, [played.id], { (count: Int($0.int(0)), at: $0.date(1)) })
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.count, 3)
        XCTAssertNotNil(rows.first?.at)
        XCTAssertEqual(try db.value("SELECT added_at FROM track_stat WHERE track_id = ?",
                                    [other.id], { $0.double(0) }), otherAddedAt)

        // 曲末记账的 id **不必**在资料库里（那几本账故意没有外键）：
        // 听过但没入库的歌照样记得上。
        XCTAssertEqual(makeStore().playCount(for: played.id), 3)
    }

    /// 起播与曲末是同一次播放的两笔账，各写各的那一行，互不覆盖。
    /// 从前它们隔着一整首歌、500 ms 防抖合并不了，正是「整份重写」最贵的那个场景。
    func testStartedAndPlayedAreTwoIndependentWrites() throws {
        let store = makeStore()
        let track = makeTrack("both")
        store.noteStarted(track)
        store.notePlayed(track)

        let restored = makeStore()
        XCTAssertEqual(restored.recentTracks.first?.id, track.id)
        XCTAssertEqual(restored.playCount(for: track.id), 1)
        XCTAssertNotNil(restored.lastPlayedAt[track.id])
    }

    /// 「重设播放次数」把次数与上次播放时间一起清掉，添加日期留着（那是另一本账）。
    func testResetPlayCountKeepsAddedAt() throws {
        let store = makeStore()
        let track = makeTrack("reset")
        store.addToLibrary(track)
        store.notePlayed(track)
        store.resetPlayCount(for: track.id)

        let restored = makeStore()
        XCTAssertEqual(restored.playCount(for: track.id), 0)
        XCTAssertNil(restored.lastPlayedAt[track.id])
        XCTAssertNotNil(restored.addedAt[track.id], "添加日期被顺手清掉了")
    }

    // MARK: - updateTrack 的掩码：新旧语义逐位等价

    /// 旧语义的独立算法：改完之后哪几个数组的内容真的变了。
    private struct ArraysSnapshot {
        let library: [Track]
        let favorites: [Track]
        let recents: [Track]
        let containers: [RecentContainer]
        let playlists: [[Track]]

        @MainActor
        init(_ store: LibraryStore) {
            library = store.libraryTracks
            favorites = store.favoriteTracks
            recents = store.recentTracks
            containers = store.recentContainers
            playlists = store.playlists.map(\.tracks)
        }
    }

    /// 跑一次 `updateTrack`，把它报出来的那一份掩码与「哪几个数组真变了」逐位比。
    @discardableResult
    private func assertMaskMatchesArrays(_ store: LibraryStore, id: String, _ what: String,
                                         transform: @escaping (inout Track) -> Void,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) -> Bool {
        let before = ArraysSnapshot(store)
        var received: LibraryChange = []
        var emissions = 0
        // 订全部位：要看的就是它到底报了哪几位。
        let token = store.changes(affecting: LibraryChange(rawValue: ~0)).sink {
            received = $0
            emissions += 1
        }
        defer { token.cancel() }

        let changed = store.updateTrack(id: id, transform: transform)
        let after = ArraysSnapshot(store)

        var expected: LibraryChange = []
        if before.library != after.library { expected.insert(.tracks) }
        if before.favorites != after.favorites { expected.insert(.favorites) }
        if before.recents != after.recents { expected.insert(.playbackStats) }
        if before.containers != after.containers { expected.insert(.playbackStats) }
        if before.playlists != after.playlists { expected.insert(.playlists) }

        XCTAssertEqual(received.rawValue, expected.rawValue,
                       "\(what)：掩码对不上（报了 \(received.rawValue)，数组说该是 \(expected.rawValue)）",
                       file: file, line: line)
        XCTAssertEqual(changed, !expected.isEmpty, "\(what)：返回值与「有没有真改到」对不上",
                       file: file, line: line)
        XCTAssertEqual(emissions, expected.isEmpty ? 0 : 1,
                       "\(what)：空集合不该发，非空只该发一次", file: file, line: line)
        return changed
    }

    /// 一首歌可能落在五处里的任意几处，逐种组合都要报得一模一样。
    func testUpdateTrackMaskIsEquivalentToArrayDiff() throws {
        let store = makeStore()
        let onlyLibrary = makeTrack("m1")
        let libraryAndFavorite = makeTrack("m2")
        let onlyRecent = makeTrack("m3")
        let onlyPlaylist = makeTrack("m4")
        let everywhere = makeTrack("m5")
        // 只在台账里的散曲格：没有专辑，收不进任何容器，也没进资料库。
        let onlyContainer = makeTrack("m6", albumId: nil)

        store.addToLibrary(onlyLibrary)
        store.addToLibrary(libraryAndFavorite)
        store.toggleFavorite(libraryAndFavorite)
        store.noteStarted(onlyRecent)
        let playlist = store.createPlaylist(name: "单", tracks: [onlyPlaylist])
        store.addToLibrary(everywhere)
        store.toggleFavorite(everywhere)
        store.noteStarted(everywhere)
        store.addTracks([everywhere], toPlaylist: playlist.id)
        store.noteStarted(makeTrack("seed"),
                          container: .track(Track(id: onlyContainer.id, kind: .qq, title: "散曲",
                                                  artistName: "某人", artistId: nil,
                                                  albumName: "", albumId: nil, artworkURL: nil,
                                                  duration: 200)))

        for (id, what) in [(onlyLibrary.id, "只在资料库"),
                           (libraryAndFavorite.id, "资料库 + 心水"),
                           (onlyRecent.id, "只在最近播放"),
                           (onlyPlaylist.id, "只在播放列表"),
                           (everywhere.id, "四处都在"),
                           (onlyContainer.id, "只在台账的散曲格")] {
            assertMaskMatchesArrays(store, id: id, what) { $0.title += "!" }
        }
    }

    /// 改完与原值相等的那一次：一位都不发、返回 false、也不往库里写。
    /// 「显示简介」面板提交时五个字段里往往只动了一个，其余四个原样写回来。
    func testUpdateTrackWithNoRealChangeIsSilent() throws {
        let store = makeStore()
        let track = makeTrack("noop")
        store.addToLibrary(track)
        assertMaskMatchesArrays(store, id: track.id, "原样写回") { $0.title = track.title }
        // 库里也没被动过一个字。
        XCTAssertEqual(try openDatabase().value("SELECT title FROM track WHERE id = ?",
                                                [track.id], { $0.text(0) }), track.title)
    }

    /// 资料库里根本没有这个 id：什么都不该发生。
    func testUpdateUnknownTrackIsSilent() {
        let store = makeStore()
        assertMaskMatchesArrays(store, id: "qq:nobody", "库里没有这个 id") { $0.title = "改了" }
    }

    /// 台账里的散曲格现在只存 id，曲目从 `track` 表取——
    /// 于是 `updateTrack` 的**第五处写入点没有了**，改一行就够。
    func testContainerTrackFollowsTheTrackRow() throws {
        let store = makeStore()
        let loose = Track(id: "qq:loose", kind: .qq, title: "旧名", artistName: "某人",
                          artistId: nil, albumName: "", albumId: nil, artworkURL: nil,
                          duration: 200)
        store.noteStarted(loose, container: .track(loose))
        store.updateTrack(id: loose.id) { $0.title = "新名" }

        let restored = makeStore()
        guard case .track(let stored)? = restored.recentContainers.first else {
            return XCTFail("台账里那一格不见了")
        }
        XCTAssertEqual(stored.title, "新名")
    }

    // MARK: - 全量往返：改一遍、重开、每份 @Published 逐个对上

    /// **这一条守的是整个阶段 3 声称的那件事**：把资料库能改的地方挨个改一遍，
    /// 关掉再打开，界面看到的每一份数据原样回来。
    ///
    /// 上面那些用例各自盯着一张表的一条规则；这一条盯的是**没有哪一份被漏掉**。
    /// 从前一次 `save()` 把 19 份数据整份重写，漏不掉；换成 24 处定向写之后，
    /// 「这个改动点忘了写库」变成了一个编译器抓不到、单张表的用例也抓不到的失误——
    /// 它只在用户重启 App 之后才现形，而那时错的那份已经被当成真值写回去了。
    ///
    /// 所以断言写成「逐份比对」而不是抽查几份：以后新增一份 `@Published`，
    /// 这里不跟着加一行，它就是下一个被漏掉的。
    func testEveryPublishedSliceSurvivesAReopen() throws {
        let store = makeStore()

        // —— 资料库：一张碟连着曲目进来，再单独加一首散曲
        let album = Album(id: "qq:album:1", kind: .qq, name: "某碟", artistName: "某人",
                          artistId: "qq:artist:1", artworkURL: nil, publishDate: "2020-01-01",
                          trackCount: 2, description: nil)
        let a1 = makeTrack("a1", title: "碟内一")
        let a2 = makeTrack("a2", title: "碟内二")
        store.addAlbumToLibrary(album, tracks: [a1, a2])
        let loose = makeTrack("loose", title: "散曲", albumId: nil)
        store.addToLibrary(loose)

        // —— 心水、星级、复选框、减少推荐
        store.toggleFavorite(a1)
        store.toggleFavoriteAlbum(album)
        store.toggleFavoriteArtist(Artist(id: "qq:artist:1", kind: .qq, name: "某人",
                                          avatarURL: nil, description: nil))
        store.setRating(4, for: a1.id)
        store.setRating(3, for: album.id)
        store.setChecked(a2, false)
        store.setSuggestedLess([loose], true)
        store.setSuggestedLessArtist("qq:artist:9", true)

        // —— 歌单：自建一份、加歌、改名
        let playlist = store.createPlaylist(name: "我的单子", tracks: [a1, a2])
        store.addTracks([loose], toPlaylist: playlist.id)
        store.renamePlaylist(id: playlist.id, to: "改过名的单子")

        // —— 播放记账：起播（进最近播放 + 台账）、放完、跳过
        store.noteStarted(a1, container: .album(album))
        store.notePlayed(a1)
        store.recordSkip(a2)

        // —— 改一首歌的字段（第五处写入点消失之后，台账里那份也该跟着变）
        _ = store.updateTrack(id: a1.id) { $0.title = "改过的标题" }

        store.flushNow()

        let reopened = makeStore()

        // 逐份比对。用 id 序列而不是整条 Track 比，是因为断言失败时
        // 打印一行 id 看得出是哪几首，打印整条 Track 只能看到一屏字段。
        XCTAssertEqual(reopened.libraryTracks.map(\.id), store.libraryTracks.map(\.id),
                       "libraryTracks")
        XCTAssertEqual(reopened.libraryAlbums.map(\.id), store.libraryAlbums.map(\.id),
                       "libraryAlbums")
        XCTAssertEqual(reopened.favoriteTracks.map(\.id), store.favoriteTracks.map(\.id),
                       "favoriteTracks")
        XCTAssertEqual(reopened.recentTracks.map(\.id), store.recentTracks.map(\.id),
                       "recentTracks")
        XCTAssertEqual(reopened.recentContainers.map(\.id), store.recentContainers.map(\.id),
                       "recentContainers")
        XCTAssertEqual(reopened.favoriteAlbumIDs, store.favoriteAlbumIDs, "favoriteAlbumIDs")
        XCTAssertEqual(reopened.favoriteArtistIDs, store.favoriteArtistIDs, "favoriteArtistIDs")
        XCTAssertEqual(reopened.ratings, store.ratings, "ratings")
        XCTAssertEqual(reopened.playCounts, store.playCounts, "playCounts")
        XCTAssertEqual(reopened.skipCounts, store.skipCounts, "skipCounts")
        XCTAssertEqual(reopened.addedAt, store.addedAt, "addedAt")
        XCTAssertEqual(reopened.lastPlayedAt, store.lastPlayedAt, "lastPlayedAt")
        XCTAssertEqual(reopened.lastSkippedAt, store.lastSkippedAt, "lastSkippedAt")
        XCTAssertEqual(reopened.albumAddedAt, store.albumAddedAt, "albumAddedAt")
        XCTAssertEqual(reopened.playlists.map(\.id), store.playlists.map(\.id), "playlists")

        // 几份不是集合、光比 id 看不出来的，单独钉一下
        XCTAssertEqual(reopened.playlist(id: playlist.id)?.name, "改过名的单子", "歌单改名")
        XCTAssertEqual(reopened.playlist(id: playlist.id)?.tracks.map(\.id),
                       [a1.id, a2.id, loose.id], "歌单内曲目顺序")
        XCTAssertEqual(reopened.libraryTracks.first { $0.id == a1.id }?.title, "改过的标题",
                       "updateTrack 改的字段")
        XCTAssertEqual(reopened.playlist(id: playlist.id)?.tracks.first { $0.id == a1.id }?.title,
                       "改过的标题", "updateTrack 改的字段要一路改到歌单内那份副本")
        XCTAssertFalse(reopened.isChecked(a2), "复选框")
        XCTAssertTrue(reopened.isSuggestedLess(loose), "减少推荐（曲目）")
        XCTAssertTrue(reopened.isSuggestedLessArtist("qq:artist:9"), "减少推荐（艺人）")
        XCTAssertEqual(reopened.rating(for: a1.id), 4, "曲目星级")
        XCTAssertEqual(reopened.rating(for: album.id), 3, "专辑星级")
        XCTAssertEqual(reopened.playCount(for: a1.id), 1, "播放次数")
        XCTAssertEqual(reopened.skipCount(for: a2.id), 1, "跳过次数")
    }
}
