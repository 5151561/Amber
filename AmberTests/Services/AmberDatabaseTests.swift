import XCTest
@testable import Amber

/// 主库的 schema 与连接管理。
///
/// 这里的用例分两类：一类钉住「建出来的库长什么样」（表、索引、版本号、幂等），
/// 另一类钉住 schema 里那几条**故意不这么建**的决定——它们每一条都对应一次实测，
/// 而「顺手补上一个外键 / 一个唯一约束」在代码审查里看起来永远像是在做好事，
/// 只有测试能说明那会改掉什么。
final class AmberDatabaseTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmberDatabaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 建库

    /// v1 建完之后，全部表与索引都在。
    ///
    /// 用超集判定而不是逐字相等：FTS5 会另建 `search_index_data` 一族影子表，
    /// 把它们写进期望清单等于把 FTS5 的内部实现钉进测试里。
    @MainActor
    func testSchemaCreatesAllTablesAndIndexes() throws {
        let database = try AmberDatabase(directory: directory)

        let tables = Set(try database.sqlite.query(
            "SELECT name FROM sqlite_master WHERE type IN ('table','view')") { $0.text(0) })
        let expectedTables: Set<String> = [
            "track",
            "library_track", "favorite_track", "recent_track",
            "library_album", "playlist", "playlist_track",
            "search_index",
            "recent_container",
            "track_stat", "rating",
            "favorite_album", "favorite_artist", "unchecked_track",
            "suggest_less_track", "suggest_less_artist", "dismissed_account_playlist",
            "track_info", "track_resume", "loudness",
            "local_file",
        ]
        XCTAssertTrue(expectedTables.isSubset(of: tables),
                      "缺表：\(expectedTables.subtracting(tables).sorted())")

        let indexes = Set(try database.sqlite.query(
            "SELECT name FROM sqlite_master WHERE type = 'index'") { $0.text(0) })
        let expectedIndexes: Set<String> = [
            "track_album_id", "track_album_key", "track_artist",
            "library_track_pos",
            "library_album_key", "library_album_artist",
            "playlist_track_track",
            "track_stat_last_played",
            "local_file_scope", "local_file_volume", "local_file_tier",
        ]
        XCTAssertTrue(expectedIndexes.isSubset(of: indexes),
                      "缺索引：\(expectedIndexes.subtracting(indexes).sorted())")

        // missingFileTrackIDs 没有表，而且不该有：文件在不在是磁盘此刻的事实。
        XCTAssertFalse(tables.contains("missing_file"))
    }

    /// 版本号跟着升级链走。
    ///
    /// 写死数字而不是拿代码里那个常量对——拿常量对是同义反复，永远绿。
    /// 每加一步升级链就改这里一次，顺手确认那一步真的跑过了（下面那条列检查）。
    @MainActor
    func testUserVersionIsCurrent() throws {
        let database = try AmberDatabase(directory: directory)
        XCTAssertEqual(try database.userVersion(), 5)
    }

    /// v3 那一步：`track.local_path` **拆了**。
    ///
    /// 这条用例从前是反的（断言那一列在），留在那儿就是为了在拆的那一天变红提醒。
    /// 现在它守的是另一头：本地性只有 `local_file` 一处回答，`track` 表上不许再长出
    /// 第二份「这首歌的文件在哪」——那份副本实测会腐败（用户本机 8 条全部指向
    /// 改名前的媒体夹、8 个文件全不存在，同期 `index.json` 里 14 条是活的）。
    @MainActor
    func testTrackNoLongerHasLocalPathColumn() throws {
        let database = try AmberDatabase(directory: directory)
        let columns = Set(try database.sqlite.query(
            "SELECT name FROM pragma_table_info('track')") { $0.text(0) })
        XCTAssertFalse(columns.contains("local_path"))
    }

    /// 停在 v2 的老库（用户手上那份）升到 v3：**先留一份底，再 DROP**。
    ///
    /// 两件事一起钉：升级链对已经存在的库是从中途接着跑的（不是重建），
    /// 以及非加法那一步的 `backup` 标志真的落成了一个文件。
    @MainActor
    func testUpgradeFromV2DropsColumnAndLeavesBackup() throws {
        let file = directory.appendingPathComponent("library.sqlite")
        // 手工造一份停在 v2 的库：建 v1 的表、补 v2 那一列、版本号钉在 2。
        do {
            let database = try AmberDatabase(directory: directory)
            try database.sqlite.execute("PRAGMA user_version = 2")
            try database.sqlite.run("""
                INSERT INTO track (id, kind, title, artist_name, album_name, duration, album_key)
                VALUES (?,?,?,?,?,?,?)
                """, ["local:1", "qq", "曲", "某人", "某碟", 1.0, "某碟|某人"])
            try database.sqlite.execute("ALTER TABLE track ADD COLUMN local_path TEXT")
            database.checkpoint()
        }

        let upgraded = try AmberDatabase(fileURL: file)
        XCTAssertEqual(try upgraded.userVersion(), 5)
        let columns = Set(try upgraded.sqlite.query(
            "SELECT name FROM pragma_table_info('track')") { $0.text(0) })
        XCTAssertFalse(columns.contains("local_path"))
        // 行本身一条不少：DROP COLUMN 只摘一列。
        XCTAssertEqual(try count(upgraded, "track"), 1)

        let backup = directory.appendingPathComponent("library.sqlite.bak-v2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path),
                      "非加法升级之前要先留一份底")
        // 底是升级前那一份：那一列还在。
        let old = try SQLiteDatabase(path: backup)
        let backedUpColumns = Set(try old.query(
            "SELECT name FROM pragma_table_info('track')") { $0.text(0) })
        XCTAssertTrue(backedUpColumns.contains("local_path"))
    }

    /// v4 那一步：停在 v3 的库（用户手上那份）开起来时，搜索索引被**全量重建**一次。
    ///
    /// `search_index` 从阶段 3 起就没人维护了——建库那一刻灌满，此后入库、退库、改名、
    /// 删列表全都不动它。这条用例造的正是那种库：曲目行在、索引行是陈旧的（这里直接清空，
    /// 实机上更常见的是「名字对不上」）。升级链跑完索引要与 `track` 表一一对应。
    ///
    /// 顺带钉住这一步**在事务里**：版本号与索引行是一起提交的，不会出现
    /// 「版本号到了 4、索引还是空的」这种从此再也不会自愈的中间态。
    @MainActor
    func testUpgradeToV4RebuildsStaleSearchIndex() throws {
        let file = directory.appendingPathComponent("library.sqlite")
        do {
            let database = try AmberDatabase(directory: directory)
            try database.sqlite.run("""
                INSERT INTO track (id, kind, title, artist_name, album_name, duration, album_key)
                VALUES (?,?,?,?,?,?,?)
                """, ["qq:1", "qq", "七里香", "周杰倫", "葉惠美", 1.0, "葉惠美|周杰倫"])
            // 陈旧成什么样都行，这里清空是最好断言的一种。
            try database.sqlite.run("DELETE FROM search_index")
            try database.sqlite.execute("PRAGMA user_version = 3")
            database.checkpoint()
        }

        let upgraded = try AmberDatabase(fileURL: file)
        XCTAssertEqual(try upgraded.userVersion(), 5)
        XCTAssertEqual(try count(upgraded, "search_index"), 1)
        // 重建用的是 `LibrarySearch.indexRow`，所以中文子串与拼音两条路都该通。
        for word in ["里香", "qlx"] {
            let query = try XCTUnwrap(LibrarySearch.ftsQuery(word))
            let hits = try LibrarySearchIndex.matchedIDs(.track, query: query,
                                                         in: upgraded.sqlite)
            XCTAssertEqual(hits, ["qq:1"], "重建之后「\(word)」该命中")
        }
    }

    /// 全新的空库不留备份：那一份拷出来也是 0 行，只是在每个临时目录里多一个文件。
    @MainActor
    func testFreshDatabaseLeavesNoBackup() throws {
        _ = try AmberDatabase(directory: directory)
        let backup = directory.appendingPathComponent("library.sqlite.bak-v2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    /// 重复开同一个目录不会再建一次表。
    ///
    /// DDL 里故意没写 `IF NOT EXISTS`，所以「第二次开库不炸」本身就是
    /// 「版本号闸住了建表那一段」的证据；顺带确认第一次写进去的行还在。
    @MainActor
    func testReopenIsIdempotent() throws {
        do {
            let first = try AmberDatabase(directory: directory)
            try first.sqlite.run("INSERT INTO rating (id, value) VALUES (?, ?)", ["qq:1", 5])
            first.checkpoint()
        }

        let second = try AmberDatabase(directory: directory)
        XCTAssertEqual(try second.userVersion(), 5)
        let value = try second.sqlite.value(
            "SELECT value FROM rating WHERE id = ?", ["qq:1"]) { $0.int(0) }
        XCTAssertEqual(value, 5)
    }

    // MARK: - 连接注册表

    /// 同一个目录拿到同一条连接——四个 store 的构造器签名一个字不改，全靠这一条。
    @MainActor
    func testSharedReturnsSameInstanceForSameDirectory() throws {
        let a = try AmberDatabase.shared(directory: directory)
        let b = try AmberDatabase.shared(directory: directory)
        XCTAssertTrue(a === b)

        // 路径的两种写法（末尾斜杠、`.` 组件）也要算同一个目录：
        // 不同一的话两条连接各有各的 WAL 读快照，表现为「刚写进去的行读不到」。
        let noisy = directory.appendingPathComponent("sub/..")
        let c = try AmberDatabase.shared(directory: noisy)
        XCTAssertTrue(a === c)
    }

    @MainActor
    func testSharedReturnsDistinctInstancesForDistinctDirectories() throws {
        let other = directory.appendingPathComponent("other", isDirectory: true)
        let a = try AmberDatabase.shared(directory: directory)
        let b = try AmberDatabase.shared(directory: other)
        XCTAssertFalse(a === b)
        XCTAssertNotEqual(a.fileURL.path, b.fileURL.path)
    }

    /// 注册表拿的是弱引用：没人持有之后条目自然掉，不会把进程里的连接与文件句柄漏光。
    ///
    /// 断言的是「注册表没把它强引用住」，不是「第二次拿到的是另一个对象」——
    /// 后者靠比 `ObjectIdentifier` 判不出来：第一条刚释放，第二条极可能被分配到
    /// 同一个地址上，实测就这么翻车过一次。
    @MainActor
    func testRegistryHoldsDatabaseWeakly() throws {
        weak var released: AmberDatabase?
        do {
            let first = try AmberDatabase.shared(directory: directory)
            released = first
            XCTAssertNotNil(released)
        }
        XCTAssertNil(released, "注册表把连接强引用住了——每个临时目录都会漏一个文件句柄")

        // 空壳条目不会挡住下一次开库。
        let second = try AmberDatabase.shared(directory: directory)
        XCTAssertEqual(try second.userVersion(), 5)
    }

    // MARK: - 外键：该级联的级联

    /// 删一份歌单，它的 `playlist_track` 行跟着没。
    /// 同时也是 `PRAGMA foreign_keys = ON` 真的生效了的证据——默认是关着的，
    /// 不显式打开的话那条 CASCADE 就只是一句没人执行的注释。
    @MainActor
    func testDeletingPlaylistCascadesToPlaylistTracks() throws {
        let database = try AmberDatabase(directory: directory)
        try insertTrack(database, id: "qq:1")
        try insertPlaylist(database, id: "local:p1")
        try database.sqlite.run(
            "INSERT INTO playlist_track (playlist_id, track_id, position) VALUES (?, ?, ?)",
            ["local:p1", "qq:1", 0])

        try database.sqlite.run("DELETE FROM playlist WHERE id = ?", ["local:p1"])

        XCTAssertEqual(try count(database, "playlist_track"), 0)
        // 曲目本身不受影响：歌单没了不等于这首歌没听过。
        XCTAssertEqual(try count(database, "track"), 1)
    }

    // MARK: - 外键：该不级联的不许级联

    /// **反向守卫**：删一条 `track`，`track_stat` 的行必须还在。
    ///
    /// playCounts 今天就是游离 id 键（实测 `lastPlayedAt` 121 个键 vs `libraryTracks`
    /// 57 条）。给 `track_stat` 补一个 `REFERENCES track(id) ON DELETE CASCADE`
    /// 看起来是在补全约束，实际是把「账按 id 记、与在不在资料库里无关」这条语义改掉，
    /// 而且改法是静默抹掉用户这辈子的播放次数。这条用例就是拦它的。
    @MainActor
    func testDeletingTrackKeepsTrackStat() throws {
        let database = try AmberDatabase(directory: directory)
        try insertTrack(database, id: "qq:1")
        try database.sqlite.run(
            "INSERT INTO track_stat (track_id, play_count) VALUES (?, ?)", ["qq:1", 7])

        try database.sqlite.run("DELETE FROM track WHERE id = ?", ["qq:1"])

        XCTAssertEqual(try count(database, "track"), 0)
        let plays = try database.sqlite.value(
            "SELECT play_count FROM track_stat WHERE track_id = ?", ["qq:1"]) { $0.int(0) }
        XCTAssertEqual(plays, 7, "track_stat 被外键连坐了——那条『故意不设外键』没落地")
    }

    /// 同理：`track_stat` 允许记一条资料库里根本没有的曲目。
    /// 有外键的话这条 INSERT 会直接失败，而它正是今天 121 vs 57 的那 64 条。
    @MainActor
    func testTrackStatAcceptsUnknownTrackID() throws {
        let database = try AmberDatabase(directory: directory)
        XCTAssertNoThrow(try database.sqlite.run(
            "INSERT INTO track_stat (track_id, play_count, last_played_at) VALUES (?, ?, ?)",
            ["ne:from-a-playlist-never-added", 3, Date()]))
        XCTAssertEqual(try count(database, "track_stat"), 1)
    }

    // MARK: - 唯一约束：该重的要能重

    /// 同一首歌在同一份列表里出现两次是合法的（Music 就是这样）。
    /// 加 `UNIQUE(playlist_id, track_id)` 会把这条产品行为改掉，且是插入时静默失败。
    @MainActor
    func testPlaylistAllowsDuplicateTrack() throws {
        let database = try AmberDatabase(directory: directory)
        try insertTrack(database, id: "qq:1")
        try insertPlaylist(database, id: "local:p1")

        try database.sqlite.run(
            "INSERT INTO playlist_track (playlist_id, track_id, position) VALUES (?, ?, ?)",
            ["local:p1", "qq:1", 0])
        XCTAssertNoThrow(try database.sqlite.run(
            "INSERT INTO playlist_track (playlist_id, track_id, position) VALUES (?, ?, ?)",
            ["local:p1", "qq:1", 1]))

        XCTAssertEqual(try count(database, "playlist_track"), 2)
    }

    // MARK: - 搜索索引

    /// FTS5 能建、能插、能 MATCH、能按 owner_id 删，正文各段落在对的列里。
    ///
    /// 「按 owner_id 删」是选普通表而不是 external content 表的直接原因：
    /// external content 表不支持对内容表之外的条件做 DELETE。
    @MainActor
    func testSearchIndexInsertMatchAndDelete() throws {
        let database = try AmberDatabase(directory: directory)
        try insertSearchRow(database, name: "七 里 香", artist: "周 杰 倫",
                            phonetic: "qi li xiang qilixiang qlx zhou jie lun zhoujielun zjl",
                            ownerID: "qq:1")
        try insertSearchRow(database, name: "帶 你 飛", artist: "Taylor Swift",
                            phonetic: "dai ni fei dainifei dnf", ownerID: "qq:2")

        // 邻近约束：正序命中、反序不命中。
        XCTAssertEqual(try match(database, "\"里 香\""), ["qq:1"])
        XCTAssertEqual(try match(database, "\"香 里\""), [])
        // 拼音三形态之一（首字母）走前缀匹配。
        XCTAssertEqual(try match(database, "\"qlx\"*"), ["qq:1"])
        // 拉丁词前缀。
        XCTAssertEqual(try match(database, "\"Tay\"*"), ["qq:2"])

        // 下面四条钉的是 **schema 本身**（分列），不是 LibrarySearch 的切分：
        // 「香」是 name 末字、「周」是 artist 首字。旧的单列 + 分隔符 schema 下，
        // 分隔符被 unicode61 丢掉且不占 token 位置，这个短语会跨字段成立、凭空多一条命中。
        // 分列之后 FTS5 的短语不跨列，它零命中；而 AND 跨列，两段都还找得到。
        XCTAssertEqual(try match(database, "\"香 周\""), [])
        XCTAssertEqual(try match(database, "\"里 香\" AND \"周 杰 倫\""), ["qq:1"])
        // 列限定语法直接问某一段在不在指定列里。
        XCTAssertEqual(try match(database, "artist:\"周 杰 倫\""), ["qq:1"])
        XCTAssertEqual(try match(database, "name:\"周 杰 倫\""), [])

        try database.sqlite.run("DELETE FROM search_index WHERE owner_id = ?", ["qq:1"])
        XCTAssertEqual(try match(database, "\"qlx\"*"), [])
        XCTAssertEqual(try match(database, "\"Tay\"*"), ["qq:2"])
    }

    // MARK: - 本机文件

    /// 一张表同时装 media（投影）与 external（权威）两种行，
    /// 而投影重建那条 DELETE 只扫得到 media 那些。
    ///
    /// **这是「一张表 + scope 列」这个选择的核心不变量**：表边界没了之后，
    /// 「external 不被投影重建碰掉」就全靠这条 WHERE 写对——所以它得有一条测试。
    @MainActor
    func testProjectionRebuildLeavesExternalRowsAlone() throws {
        let database = try AmberDatabase(directory: directory)
        let volume = "1A2B-3C4D"
        try insertLocalFile(database, key: "qq:1", scope: "media",
                            path: "周杰倫/七里香/01 七里香.flac", volume: volume)
        try insertLocalFile(database, key: "mv:9", scope: "media",
                            path: "MV/七里香.mp4", volume: volume)
        try insertLocalFile(database, key: "local:abc", scope: "external",
                            path: "/Volumes/Music/别处/某首.flac", volume: volume)

        try database.sqlite.run(
            "DELETE FROM local_file WHERE scope = 'media' AND volume_uuid = ?", [volume])

        let rows = try database.sqlite.query(
            "SELECT key, scope FROM local_file ORDER BY key") { ($0.text(0), $0.text(1)) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.0, "local:abc")
        XCTAssertEqual(rows.first?.1, "external")
    }

    /// MV 用 `mv:<id>` 前缀键与曲目共用这张表，那些键在 `track` 里没有对应行——
    /// 这正是 `local_file` 不能对 `track(id)` 建外键的原因。
    @MainActor
    func testLocalFileAcceptsMVKeyWithoutTrackRow() throws {
        let database = try AmberDatabase(directory: directory)
        XCTAssertNoThrow(try insertLocalFile(database, key: "mv:9", scope: "media",
                                             path: "MV/七里香.mp4", volume: nil))
        XCTAssertEqual(try count(database, "local_file"), 1)
        XCTAssertEqual(try count(database, "track"), 0)
    }

    // MARK: - 夹具

    @MainActor
    private func insertTrack(_ database: AmberDatabase, id: String) throws {
        try database.sqlite.run("""
            INSERT INTO track (id, kind, title, artist_name, artist_id, album_name, album_id,
                               artwork_url, duration, track_number, disc_number, media_mid,
                               lossless_available, album_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [id, "qq", "七里香", "周杰倫", SQLValue.null, "七里香", SQLValue.null,
                  SQLValue.null, 299.0, SQLValue.null, SQLValue.null, SQLValue.null,
                  SQLValue.null, "七里香\u{1}周杰倫\u{1}qq\u{1}0"])
    }

    @MainActor
    private func insertPlaylist(_ database: AmberDatabase, id: String) throws {
        try database.sqlite.run("""
            INSERT INTO playlist (id, name, origin, source_json, cover_url, description,
                                  created_at, added_at, position)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [id, "我的列表", "local", SQLValue.null, SQLValue.null, SQLValue.null,
                  Date(), Date(), 0])
    }

    @MainActor
    private func insertLocalFile(_ database: AmberDatabase, key: String, scope: String,
                                 path: String, volume: String?) throws {
        try database.sqlite.run("""
            INSERT INTO local_file (key, scope, relative_path, volume_uuid, bytes, mtime,
                                    added_at, quality, codec, sample_rate, bit_depth, tier,
                                    tagged, tag_version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [key, scope, path, volume, 40_000_000, Date(), Date(),
                  "无损 · 44.1 kHz 16 位 FLAC", "flac", 44_100.0, 16, "lossless",
                  SQLValue.null, SQLValue.null])
    }

    @MainActor
    private func count(_ database: AmberDatabase, _ table: String) throws -> Int64 {
        try database.sqlite.value("SELECT COUNT(*) FROM \(table)") { $0.int(0) } ?? -1
    }

    @MainActor
    private func insertSearchRow(_ database: AmberDatabase, name: String, artist: String,
                                 phonetic: String, ownerID: String) throws {
        try database.sqlite.run("""
            INSERT INTO search_index (name, artist, album, phonetic, owner_kind, owner_id)
            VALUES (?, ?, ?, ?, ?, ?)
            """, [name, artist, "", phonetic, "track", ownerID])
    }

    @MainActor
    private func match(_ database: AmberDatabase, _ expression: String) throws -> [String] {
        try database.sqlite.query(
            "SELECT owner_id FROM search_index WHERE search_index MATCH ? ORDER BY owner_id",
            [expression]) { $0.text(0) }
    }
}
