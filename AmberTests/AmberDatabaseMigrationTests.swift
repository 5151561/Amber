import XCTest
@testable import Amber

/// 「旧 JSON 存档 → SQLite 主库」这一次性迁移。
///
/// 全部用**自己造的 fixture 写进临时目录**，一行都不碰用户真实的
/// `~/Library/Application Support/Amber/`。
///
/// 用例分三类：
///
/// 1. **搬对了没有**（计数、去重、position、六种台账 case、搜索索引）；
/// 2. **搬不动的时候会不会把数据搞坏**——这一类才是迁移器真正的价值所在。今天
///    `LibraryStore.load()` 解不动就静默空库，随后任意一次写操作用空快照 `.atomic`
///    覆盖原文件，心水 / 评分 / 播放次数 / 几十份歌单一次全没。
///    `testCorruptLibraryArchiveAbortsAndTouchesNothing` 钉的就是「读不出来永远不能
///    变成写空的」；
/// 3. **那几道故意加的闸**（死 `localPath` 不进库、游离账不清理、`.playlist` 与
///    `.libraryPlaylist` 共用前缀）——它们每一条在代码审查里都长得像「可以顺手整理一下」。
@MainActor
final class AmberDatabaseMigrationTests: XCTestCase {

    /// Application Support 那一份（library.json / trackinfo.json / loudness.json）。
    private var support: URL!
    /// 媒体文件夹（index.json 住在这里，**与上面那个目录不是同一个**）。
    private var media: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmberMigrationTests-\(UUID().uuidString)", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)
        media = root.appendingPathComponent("媒体", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support.deletingLastPathComponent())
    }

    // MARK: - fixture

    /// 旧 `trackinfo.json` 的形状（迁移器里那份是 private，这里另写一份**只用来造 fixture**）。
    private struct TrackInfoArchiveFixture: Codable {
        var infos: [String: TrackInfo] = [:]
        var resumePositions: [String: TimeInterval]?
    }

    /// 旧 `index.json` 里的一条，同上。
    private struct DownloadEntryFixture: Codable {
        var path: String
        var bytes: Int
        var date: Date
        var quality: String?
        var tagged: Bool?
        var tagVersion: Int?
    }

    private var archiveURL: URL { support.appendingPathComponent("library.json") }
    private var trackInfoURL: URL { support.appendingPathComponent("trackinfo.json") }
    private var loudnessURL: URL { support.appendingPathComponent("loudness.json") }
    private var indexURL: URL { media.appendingPathComponent("index.json") }
    private var databaseURL: URL { support.appendingPathComponent("library.sqlite") }
    private var sidecarURL: URL { support.appendingPathComponent("library.sqlite.new") }

    private func write(_ value: some Encodable, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url)
    }

    private func makeTrack(_ id: String, title: String = "某曲", artist: String = "某人",
                           album: String = "某碟", albumId: String? = "ne:album:1",
                           trackNumber: Int? = 1, discNumber: Int? = 1,
                           mediaMid: String? = nil, lossless: Bool? = nil,
                           localPath: String? = nil) -> LegacyTrack {
        let json: [String: Any?] = [
            "id": id, "kind": "netease", "title": title, "artistName": artist,
            "artistId": "ne:artist:1", "albumName": album, "albumId": albumId,
            "artworkURL": "https://example.com/\(id).jpg", "duration": 201.5,
            "trackNumber": trackNumber, "discNumber": discNumber, "mediaMid": mediaMid,
            "losslessAvailable": lossless, "localPath": localPath,
        ]
        return decodeTrack(json)
    }

    /// `LegacyTrack` 的属性全是 `let`、没有 memberwise init（它是**存档形状的快照**，
    /// 不是给别人构造的模型），所以 fixture 走一趟 JSON——顺便也就钉住了「这个形状真能
    /// 从 JSON 解出来」。
    private func decodeTrack(_ json: [String: Any?]) -> LegacyTrack {
        let compacted = json.compactMapValues { $0 }
        let data = try! JSONSerialization.data(withJSONObject: compacted)
        return try! JSONDecoder().decode(LegacyTrack.self, from: data)
    }

    private func makePlaylist(_ id: String, name: String,
                              tracks: [LegacyTrack],
                              source: Playlist? = nil) -> LegacyLibraryPlaylist {
        LegacyLibraryPlaylist(id: id, name: name, origin: source == nil ? .local : .added,
                              source: source, tracks: tracks, coverURL: nil, description: nil,
                              createdAt: Date(timeIntervalSinceReferenceDate: 1000),
                              addedAt: Date(timeIntervalSinceReferenceDate: 2000))
    }

    private func makeAlbum(_ id: String, name: String = "某碟",
                           artist: String = "某人") -> Album {
        Album(id: id, kind: .netease, name: name, artistName: artist, artistId: "ne:artist:1",
              artworkURL: nil, publishDate: "2025-06-06", trackCount: 2, description: nil,
              genre: "Mandopop", albumType: "录音室专辑")
    }

    @discardableResult
    private func migrate(renameLegacy: Bool = false) throws -> AmberDatabaseMigration.Report {
        try AmberDatabaseMigration.runIfNeeded(directory: support, mediaFolder: media,
                                               renameLegacyOnSuccess: renameLegacy)
    }

    /// 打开迁移出来的库。**不走 `AmberDatabase.shared`**：那张按目录记忆化的表是给
    /// 四个 store 共用一条连接用的，测试里灌进去只会让下一条用例读到上一条的连接。
    private func openDatabase() throws -> AmberDatabase {
        try AmberDatabase(directory: support)
    }

    // MARK: - 完整 fixture

    /// 四份文件齐全的一次完整迁移：每一张表的行数都对得上。
    ///
    /// 这条同时是别的用例的底座——下面那些只改动其中一样再看差异。
    func testFullFixtureMigratesEveryTable() throws {
        let live = try makeLiveFile(named: "在的.flac")

        let t1 = makeTrack("ne:1", title: "帶你飛", artist: "Taylor Swift", album: "某碟")
        let t2 = makeTrack("ne:2", title: "七里香", artist: "周杰倫", album: "七里香",
                           albumId: "ne:album:2", trackNumber: 2)
        let t3 = makeTrack("local:abc", title: "本地歌", artist: "某人", album: "",
                           albumId: nil, localPath: live.path)
        let t4 = makeTrack("qq:4", title: "外面那首", album: "某碟")

        var archive = LegacyLibraryArchive()
        archive.libraryTracks = [t1, t2, t3]
        archive.favorites = [t1]
        archive.recents = [t2, t1]
        archive.libraryAlbums = [makeAlbum("ne:album:1"), makeAlbum("ne:album:2", name: "七里香",
                                                                   artist: "周杰倫")]
        archive.playlists = [makePlaylist("local:P1", name: "自建", tracks: [t1, t4])]
        archive.ratings = ["ne:1": 5, "ne:album:1": 3]
        archive.playCounts = ["ne:1": 7, "ne:9": 2]
        archive.skipCounts = ["ne:2": 1]
        archive.addedAt = ["ne:1": Date(timeIntervalSinceReferenceDate: 100)]
        archive.lastPlayedAt = ["ne:1": Date(timeIntervalSinceReferenceDate: 200)]
        archive.lastSkippedAt = [:]
        archive.albumAddedAt = ["ne:album:1": Date(timeIntervalSinceReferenceDate: 300)]
        archive.favoriteAlbums = ["ne:album:1"]
        archive.favoriteArtists = ["ne:artist:1"]
        archive.uncheckedTracks = ["ne:2"]
        archive.suggestLessTracks = ["ne:2"]
        archive.suggestLessArtists = []
        archive.dismissedAccountPlaylists = ["qq:dismissed"]
        archive.recentContainers = [.favorites, .track(t3.asTrack)]
        try write(archive, to: archiveURL)

        var info = TrackInfo()
        info.composer = "某作曲"
        info.bpm = 128
        try write(TrackInfoArchiveFixture(infos: ["ne:1": info],
                                         resumePositions: ["ne:2": 42.5]), to: trackInfoURL)
        try write(["ne:1": LoudnessEntry(lufs: -14.2, peakDB: -1.0, measuredAt: Date())],
                  to: loudnessURL)
        try write([
            "ne:1": DownloadEntryFixture(path: "网易云/帶你飛.flac", bytes: 1024,
                                         date: Date(), quality: "无损", tagged: true,
                                         tagVersion: 2),
            "qq:4": DownloadEntryFixture(path: "/Users/someone/外面那首.mp3", bytes: 2048,
                                         date: Date()),
            "mv:ne:1": DownloadEntryFixture(path: "MV/帶你飛.mp4", bytes: 4096, date: Date()),
        ], to: indexURL)

        let report = try migrate()
        XCTAssertTrue(report.didRun)
        XCTAssertTrue(report.warnings.isEmpty, "不该有告警：\(report.warnings)")

        // 成功之后 sidecar 连同它的 `-wal` / `-shm` 一个都不许剩下。剩了的话
        // 「只拷 .sqlite」会拿到一份陈旧的库，而且下次启动会看到一个语义不明的孤儿。
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path + suffix), suffix)
        }

        // 曲目池 = 五处的并集去重：t1/t2/t3（资料库）+ t4（只在歌单里）。
        XCTAssertEqual(report.counts["track"], 4)
        XCTAssertEqual(report.counts["library_track"], 3)
        XCTAssertEqual(report.counts["favorite_track"], 1)
        XCTAssertEqual(report.counts["recent_track"], 2)
        XCTAssertEqual(report.counts["library_album"], 2)
        XCTAssertEqual(report.counts["playlist"], 1)
        XCTAssertEqual(report.counts["playlist_track"], 2)
        XCTAssertEqual(report.counts["recent_container"], 2)
        // 五本账取键的并集：ne:1（四本都有）、ne:9（只有 playCounts）、ne:2（只有 skipCounts）。
        XCTAssertEqual(report.counts["track_stat"], 3)
        XCTAssertEqual(report.counts["rating"], 2)
        XCTAssertEqual(report.counts["favorite_album"], 1)
        XCTAssertEqual(report.counts["favorite_artist"], 1)
        XCTAssertEqual(report.counts["unchecked_track"], 1)
        XCTAssertEqual(report.counts["suggest_less_track"], 1)
        XCTAssertEqual(report.counts["suggest_less_artist"], 0)
        XCTAssertEqual(report.counts["dismissed_account_playlist"], 1)
        XCTAssertEqual(report.counts["track_info"], 1)
        XCTAssertEqual(report.counts["track_resume"], 1)
        XCTAssertEqual(report.counts["loudness"], 1)
        // index.json 三条 + t3 的活 localPath 补一条。
        XCTAssertEqual(report.counts["local_file"], 4)
        // 4 首曲目 + 2 张专辑 + 1 份歌单 + 3 位派生艺人（某人 / 周杰倫 / Taylor Swift）。
        XCTAssertEqual(report.counts["search_index"], 4 + 2 + 1 + 3)

        // 抽一条把字段落位也看一眼：INSERT 的列清单与 VALUES 的绑定顺序错一位时，
        // 上面那些计数会全对，而每首歌的专辑名都成了艺人名。
        let database = try openDatabase()
        let row = try database.sqlite.value("""
            SELECT title, artist_name, album_name, duration, track_number, media_mid,
                   lossless_available
            FROM track WHERE id = 'ne:2'
            """) { (title: $0.text(0), artist: $0.text(1), album: $0.text(2),
                    duration: $0.double(3), number: $0.optInt(4), mid: $0.optText(5),
                    lossless: $0.optBool(6)) }
        XCTAssertEqual(row?.title, "七里香")
        XCTAssertEqual(row?.artist, "周杰倫")
        XCTAssertEqual(row?.album, "七里香")
        XCTAssertEqual(row?.duration, 201.5)
        XCTAssertEqual(row?.number, 2)
        // 三态列：旧存档里没有这两格 → NULL，不是 "" 也不是 false。
        XCTAssertNil(row?.mid)
        XCTAssertNil(row?.lossless)
    }

    /// `library.json` 根本不存在（全新用户）：建一个空库，**不报错**。
    func testMissingArchiveBuildsEmptyDatabase() throws {
        let report = try migrate()
        XCTAssertTrue(report.didRun)
        XCTAssertEqual(report.counts["track"], 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    /// 除了 `favorites` / `recents` 之外 17 个键全缺：一个都不能炸，对应表 0 行。
    ///
    /// 这就是那 17 个 `Optional` 的全部意义——合成的 `Decodable` 对**非可选**属性缺键会
    /// 直接抛错，而抛错在迁移器这边等于「整份存档解不动」，用户会看到一句阻塞式警告。
    func testArchiveWithOnlyTheTwoRequiredKeysMigrates() throws {
        let json = #"{"favorites":[],"recents":[]}"#
        try json.data(using: .utf8)!.write(to: archiveURL)

        let report = try migrate()
        XCTAssertTrue(report.didRun)
        for table in ["track", "library_track", "library_album", "playlist", "recent_container",
                      "track_stat", "rating", "unchecked_track", "suggest_less_track"] {
            XCTAssertEqual(report.counts[table], 0, table)
        }
    }

    // MARK: - 幂等

    /// 库已经在了：第二次调用什么都不做，**磁盘上那份库一个字节都不变**。
    ///
    /// 光断言 `didRun == false` 不够——真正要防的是「以为自己没跑、其实把库重建了一遍」，
    /// 那种错只有比对字节才看得见。所以第二次跑之前故意把 JSON 改了：
    /// 库要是被重建，内容必然跟着变。
    func testSecondRunIsANoOp() throws {
        var archive = LegacyLibraryArchive()
        archive.libraryTracks = [makeTrack("ne:1")]
        try write(archive, to: archiveURL)

        XCTAssertTrue(try migrate().didRun)
        let before = try Data(contentsOf: databaseURL)

        archive.libraryTracks = [makeTrack("ne:1"), makeTrack("ne:2")]
        try write(archive, to: archiveURL)

        let second = try migrate()
        XCTAssertFalse(second.didRun)
        XCTAssertTrue(second.counts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: databaseURL), before)
    }

    // MARK: - 失败策略

    /// **整份用例里最重要的一条。**
    ///
    /// `library.json` 在、非空、解不动 → 不建库、JSON 一个字节没变、抛的是能被调用方
    /// 单独认出来的那个 case。今天这条路径的行为是「静默空库 + 随后覆盖原文件」，
    /// 用户的心水 / 评分 / 播放次数 / 几十份歌单一次全没。
    func testCorruptLibraryArchiveAbortsAndTouchesNothing() throws {
        let corrupt = Data(#"{"favorites":[{"id":"ne:1","kind":"#.utf8)
        try corrupt.write(to: archiveURL)
        // 另外三份是好的：证明中止是 `library.json` 一家说了算，不是「有一份坏就全停」。
        try write(TrackInfoArchiveFixture(infos: ["ne:1": TrackInfo()], resumePositions: nil),
                  to: trackInfoURL)

        XCTAssertThrowsError(try migrate()) { error in
            guard let failure = error as? AmberDatabaseMigration.Failure,
                  case .archiveUnreadable = failure else {
                return XCTFail("要的是 archiveUnreadable，拿到 \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path), "不许建库")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path), "不许留 sidecar")
        XCTAssertEqual(try Data(contentsOf: archiveURL), corrupt, "JSON 必须一个字节没变")
    }

    /// 0 字节的 `library.json` 按「没有存档」算，不按「坏掉的存档」算。
    ///
    /// 那是一次没写完的 `.atomic` 留下的空壳。按坏档处理会把全新用户拦在门外，
    /// 而它里面本来就没有任何东西可丢。
    func testEmptyArchiveFileCountsAsMissing() throws {
        try Data().write(to: archiveURL)
        XCTAssertTrue(try migrate().didRun)
    }

    /// 另外三份解不动：各贡献 0 条，迁移照常完成，报告里记一笔。
    ///
    /// 与 `library.json` 的区别是**这三份丢了不致命**——简介、响度、下载索引都能重建
    /// （索引甚至每次启动都按磁盘现况校一遍），而资料库本身重建不出来。
    func testOtherArchivesUnreadableStillMigrate() throws {
        var archive = LegacyLibraryArchive()
        archive.libraryTracks = [makeTrack("ne:1")]
        try write(archive, to: archiveURL)
        for url in [trackInfoURL, loudnessURL, indexURL] {
            try Data("{{{ 不是 JSON".utf8).write(to: url)
        }

        let report = try migrate()
        XCTAssertTrue(report.didRun)
        XCTAssertEqual(report.counts["track"], 1)
        XCTAssertEqual(report.counts["track_info"], 0)
        XCTAssertEqual(report.counts["track_resume"], 0)
        XCTAssertEqual(report.counts["loudness"], 0)
        XCTAssertEqual(report.counts["local_file"], 0)
        XCTAssertEqual(Set(report.warnings), [
            .trackInfoUnreadable(trackInfoURL),
            .loudnessUnreadable(loudnessURL),
            .downloadIndexUnreadable(indexURL),
        ])
    }

    /// 写库中途出错（这里用同一份数组里两条同 id 的曲目撞主键）：
    /// sidecar 连同它的 `-wal` / `-shm` 一起删掉，磁盘上**没有半份库**，JSON 不动。
    ///
    /// 「校验不过」走的是同一条收尾路径（`runIfNeeded` 里那个 `catch`），而从 fixture
    /// 造不出一次真的校验失败——每张表的插入都与源数组一一对应，对不上之前就已经抛了。
    /// 所以这里钉的是那条**收尾路径**本身。
    func testWriteFailureLeavesNoHalfDatabase() throws {
        var archive = LegacyLibraryArchive()
        let duplicate = makeTrack("ne:1")
        archive.libraryTracks = [duplicate, duplicate]
        try write(archive, to: archiveURL)
        let before = try Data(contentsOf: archiveURL)

        XCTAssertThrowsError(try migrate()) { error in
            guard let failure = error as? AmberDatabaseMigration.Failure,
                  case .write = failure else {
                return XCTFail("要的是 write，拿到 \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path + "-shm"))
        XCTAssertEqual(try Data(contentsOf: archiveURL), before)
    }

    /// 上一次崩在半路留下的孤儿 sidecar：先清掉再重来，不许往它上面接着灌。
    ///
    /// 不清的话 `AmberDatabase` 会读到那份库里已经是 1 的 `user_version`，建表那段
    /// 一条都不跑，然后往**半份数据**上继续写——校验多半拦得住，但那是靠运气不是靠设计。
    func testOrphanSidecarFromACrashIsDiscarded() throws {
        var archive = LegacyLibraryArchive()
        archive.libraryTracks = [makeTrack("ne:1")]
        try write(archive, to: archiveURL)

        // 造一个「上次崩在半路」的现场：sidecar 里已经有一首别的歌。
        do {
            let stale = try AmberDatabase(fileURL: sidecarURL)
            try stale.sqlite.run("""
                INSERT INTO track (id, kind, title, artist_name, album_name, duration, album_key)
                VALUES ('ne:上次那首','netease','半截','某人','某碟',1,'k')
                """)
        }

        let report = try migrate()
        XCTAssertEqual(report.counts["track"], 1)
        let database = try openDatabase()
        let ids = try database.sqlite.query("SELECT id FROM track") { $0.text(0) }
        XCTAssertEqual(ids, ["ne:1"], "孤儿 sidecar 里的东西不许混进来")
    }

    /// 这一轮 JSON **一律不改名**（`renameLegacyOnSuccess` 默认 false）：
    /// 迁出来的库没人读，JSON 仍是唯一真值源，随时可以把库删了当无事发生。
    func testLegacyJSONIsKeptByDefault() throws {
        try write(LegacyLibraryArchive(), to: archiveURL)
        try migrate()
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    /// 打开开关之后：改名只发生在 Application Support 那边，媒体夹的 `index.json`
    /// **原样留着**——它是媒体文件夹的自解释清单，不是 Amber 的存档，
    /// 换一台机器挂上这个文件夹还要靠它。
    ///
    /// （改名具体落到哪几份，见 `testRenameOnlyTouchesArchivesWhoseStoreHasMoved`。）
    func testRenameLegacyOnSuccessKeepsMediaManifest() throws {
        try write(LegacyLibraryArchive(), to: archiveURL)
        try write(TrackInfoArchiveFixture(), to: trackInfoURL)
        try write([String: DownloadEntryFixture](), to: indexURL)

        try migrate(renameLegacy: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path), "清单不改名")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: support.path)
        XCTAssertTrue(leftovers.contains { $0.hasPrefix("library.json.migrated-") }, "\(leftovers)")
    }

    // MARK: - 曲目去重

    /// 同一首歌同时躺在 libraryTracks / favorites / recents / 歌单里：
    /// `track` 表只有一行，四张关系表各一行。
    ///
    /// 这就是整件事的核心——实测用户库 247 份完整副本收成 199 首唯一曲目，
    /// `updateTrack` 从「同步五处」变成「改一行」。
    func testSameTrackAcrossFiveSourcesCollapsesToOneRow() throws {
        let track = makeTrack("ne:1")
        var archive = LegacyLibraryArchive()
        archive.libraryTracks = [track]
        archive.favorites = [track]
        archive.recents = [track]
        archive.playlists = [makePlaylist("local:P1", name: "自建", tracks: [track])]
        archive.recentContainers = [.track(track.asTrack)]
        try write(archive, to: archiveURL)

        let report = try migrate()
        XCTAssertEqual(report.counts["track"], 1)
        XCTAssertEqual(report.counts["library_track"], 1)
        XCTAssertEqual(report.counts["favorite_track"], 1)
        XCTAssertEqual(report.counts["recent_track"], 1)
        XCTAssertEqual(report.counts["playlist_track"], 1)
        XCTAssertEqual(report.counts["recent_container"], 1)
    }

    /// 五处的字段打架时按 libraryTracks > favorites > recents > 歌单 > 台账。
    ///
    /// 它们理论上由 `updateTrack` 同步、实测也一致，但「理论上一致」不是规则：
    /// 没有确定的顺序，同一份存档在不同机器上能迁出不同的库。
    func testFieldPriorityPrefersLibraryTracks() throws {
        var archive = LegacyLibraryArchive()
        archive.libraryTracks = [makeTrack("ne:1", title: "资料库那份")]
        archive.favorites = [makeTrack("ne:1", title: "心水那份")]
        archive.recents = [makeTrack("ne:1", title: "最近那份")]
        try write(archive, to: archiveURL)
        try migrate()

        let database = try openDatabase()
        let title = try database.sqlite.value("SELECT title FROM track WHERE id = 'ne:1'") {
            $0.text(0)
        }
        XCTAssertEqual(title, "资料库那份")
    }

    /// `position` 就是数组下标原样物化：这几份在界面上是有序列表，不是集合。
    func testPositionsReflectArrayOrder() throws {
        var archive = LegacyLibraryArchive()
        archive.libraryTracks = [makeTrack("ne:1"), makeTrack("ne:2"), makeTrack("ne:3")]
        archive.playlists = [makePlaylist("local:P1", name: "自建",
                                          tracks: [makeTrack("ne:3"), makeTrack("ne:1")])]
        try write(archive, to: archiveURL)
        try migrate()

        let database = try openDatabase()
        let library = try database.sqlite.query(
            "SELECT track_id FROM library_track ORDER BY position") { $0.text(0) }
        XCTAssertEqual(library, ["ne:1", "ne:2", "ne:3"])
        let playlist = try database.sqlite.query(
            "SELECT track_id FROM playlist_track ORDER BY position") { $0.text(0) }
        XCTAssertEqual(playlist, ["ne:3", "ne:1"])
    }

    /// 同一首歌允许在一份列表里出现多次（Music 就是这样，`addTracks` 明写不去重）。
    /// 主键是 `(playlist_id, position)`，不是 `(playlist_id, track_id)`。
    func testPlaylistKeepsDuplicateTracks() throws {
        let track = makeTrack("ne:1")
        var archive = LegacyLibraryArchive()
        archive.playlists = [makePlaylist("local:P1", name: "自建", tracks: [track, track])]
        try write(archive, to: archiveURL)

        XCTAssertEqual(try migrate().counts["playlist_track"], 2)
    }

    // MARK: - 游离的账

    /// 听过但没入库的歌也有账：`playCounts` 的键不在任何数组里，照样进 `track_stat`。
    ///
    /// 实测 `lastPlayedAt` 121 个键 vs `libraryTracks` 57 条。「账按 id 记，与在不在
    /// 资料库里无关」是现有语义——这几张表故意没有外键，迁移时也故意不按曲目池过滤。
    func testOrphanLedgerKeysSurvive() throws {
        var archive = LegacyLibraryArchive()
        archive.libraryTracks = [makeTrack("ne:1")]
        archive.playCounts = ["ne:1": 3, "ne:从没入过库": 9]
        try write(archive, to: archiveURL)

        XCTAssertEqual(try migrate().counts["track_stat"], 2)
        let database = try openDatabase()
        let count = try database.sqlite.value(
            "SELECT play_count FROM track_stat WHERE track_id = 'ne:从没入过库'") { $0.int(0) }
        XCTAssertEqual(count, 9)
    }

    // MARK: - 专辑的添加时间

    /// `albumAddedAt` 有记录就用记录值。
    func testAlbumAddedAtUsesStampWhenPresent() throws {
        let stamp = Date(timeIntervalSinceReferenceDate: 12345)
        var archive = LegacyLibraryArchive()
        archive.libraryAlbums = [makeAlbum("ne:album:1")]
        archive.albumAddedAt = ["ne:album:1": stamp]
        archive.libraryTracks = [makeTrack("ne:1")]
        archive.addedAt = ["ne:1": Date(timeIntervalSinceReferenceDate: 999_999)]
        try write(archive, to: archiveURL)
        try migrate()

        XCTAssertEqual(try albumAddedAt("ne:album:1"), stamp.timeIntervalSinceReferenceDate)
    }

    /// 缺键时回落「碟内曲目 `addedAt` 的最大值」，**迁移时算好写死**。
    ///
    /// 今天这是 `albumAddedDate(for:)` 里每问一次就全表扫一遍的 O(n) 兜底；
    /// 算进列里之后运行时那一段可以整个删掉。
    func testAlbumAddedAtFallsBackToLatestTrack() throws {
        var archive = LegacyLibraryArchive()
        archive.libraryAlbums = [makeAlbum("ne:album:1")]
        archive.libraryTracks = [makeTrack("ne:1"), makeTrack("ne:2")]
        archive.addedAt = ["ne:1": Date(timeIntervalSinceReferenceDate: 100),
                           "ne:2": Date(timeIntervalSinceReferenceDate: 500)]
        try write(archive, to: archiveURL)
        try migrate()

        XCTAssertEqual(try albumAddedAt("ne:album:1"), 500)
    }

    /// 没有 `albumId` 的曲目按 `fallbackKey`（名 + 艺人 + 音源 + 本地性）归位，
    /// 回落照样算得出来。这一条钉的是迁移器里那份 `belongs` 与 `LibraryStore` 同解。
    func testAlbumAddedAtFallbackMatchesByFallbackKey() throws {
        var archive = LegacyLibraryArchive()
        archive.libraryAlbums = [makeAlbum("ne:album:1", name: "某碟", artist: "某人")]
        archive.libraryTracks = [makeTrack("ne:1", album: " 某碟 ", albumId: nil)]
        archive.addedAt = ["ne:1": Date(timeIntervalSinceReferenceDate: 777)]
        try write(archive, to: archiveURL)
        try migrate()

        // 归一化会把前后空白与大小写抹平，所以「 某碟 」认得回「某碟」。
        XCTAssertEqual(try albumAddedAt("ne:album:1"), 777)
    }

    /// 一首碟内曲目都没有、也没记过时间：`added_at` 是 NULL，不是 0。
    func testAlbumAddedAtStaysNullWhenNothingToFallBackOn() throws {
        var archive = LegacyLibraryArchive()
        archive.libraryAlbums = [makeAlbum("ne:album:1")]
        try write(archive, to: archiveURL)
        try migrate()

        XCTAssertNil(try albumAddedAt("ne:album:1"))
    }

    private func albumAddedAt(_ id: String) throws -> Double? {
        let database = try openDatabase()
        return try database.sqlite.value("SELECT added_at FROM library_album WHERE id = ?",
                                         [id]) { $0.optDouble(0) } ?? nil
    }

    // MARK: - 最近播放台账

    /// 六个 case 各走一遍：kind / ref_id / payload 三列的落法各不相同。
    func testRecentContainerCoversAllSixCases() throws {
        let track = makeTrack("ne:1")
        let source = Playlist(id: "qq:p9", kind: .qq, name: "音源歌单", coverURL: nil,
                              description: nil, playCount: 0, trackCount: 3,
                              creatorName: "某位用户")
        var archive = LegacyLibraryArchive()
        archive.libraryTracks = [track]
        archive.recentContainers = [
            .track(track.asTrack),
            .libraryPlaylist(id: "local:P1"),
            .playlist(source),
            .album(makeAlbum("ne:album:1")),
            .artist(id: "ne:artist:7", kind: .netease, name: "某人",
                    avatarURL: "https://example.com/a.jpg"),
            .favorites,
        ]
        try write(archive, to: archiveURL)
        try migrate()

        let database = try openDatabase()
        let rows = try database.sqlite.query("""
            SELECT position, dedupe_key, kind, ref_id, payload FROM recent_container
            ORDER BY position
            """) { (position: Int($0.int(0)), key: $0.text(1), kind: $0.text(2),
                    ref: $0.optText(3), payload: $0.optText(4)) }
        XCTAssertEqual(rows.map(\.position), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(rows.map(\.kind),
                       ["track", "libraryPlaylist", "playlist", "album", "artist", "favorites"])
        XCTAssertEqual(rows.map(\.key), ["track:ne:1", "playlist:local:P1", "playlist:qq:p9",
                                         "album:ne:album:1", "artist:ne:artist:7", "favorites"])

        // 曲目从 `track` 表取，台账里不存副本——这一下删掉 `updateTrack` 的第五处写入点。
        XCTAssertEqual(rows[0].ref, "ne:1")
        XCTAssertNil(rows[0].payload)
        // 资料库歌单只存 id：名字 / 封面 / 还在不在都实时解析，存快照必然发霉。
        XCTAssertEqual(rows[1].ref, "local:P1")
        XCTAssertNil(rows[1].payload)
        // 音源歌单与专辑**故意是快照**：它们不在资料库里，没有表可以指。
        XCTAssertEqual(rows[2].ref, "qq:p9")
        XCTAssertTrue(rows[2].payload?.contains("某位用户") == true, "\(rows[2].payload ?? "－")")
        XCTAssertEqual(rows[3].ref, "ne:album:1")
        XCTAssertTrue(rows[3].payload?.contains("Mandopop") == true)
        // 艺人：ref_id 与 payload 都有，payload 只存卡片与 Route 要的那四项。
        XCTAssertEqual(rows[4].ref, "ne:artist:7")
        XCTAssertTrue(rows[4].payload?.contains("avatarURL") == true)
        // 心水是虚拟列表，没有 id 可存，两列都是 NULL。
        XCTAssertNil(rows[5].ref)
        XCTAssertNil(rows[5].payload)
    }

    /// `.playlist` 与 `.libraryPlaylist` **故意共用 `playlist:` 前缀**：同一份歌单有两条路
    /// 进来（资料库歌单页 / 目录页），而 `LibraryPlaylist.from` 沿用的就是音源歌单的 id。
    /// 按 case 拆开前缀就会把同一份歌单摆成两张卡。
    ///
    /// 于是它们在台账里会**收成一条**——存档里本来就留着这种「同一格的两种身份」，
    /// 而 `dedupe_key` 上有 `UNIQUE`，不收就是一条插不进去的语句、整份迁移当场中止。
    func testPlaylistAndLibraryPlaylistSharePrefixAndCollapse() throws {
        let source = Playlist(id: "qq:p9", kind: .qq, name: "同一份歌单")
        var archive = LegacyLibraryArchive()
        archive.recentContainers = [.libraryPlaylist(id: "qq:p9"), .playlist(source)]
        try write(archive, to: archiveURL)

        XCTAssertEqual(try migrate().counts["recent_container"], 1)
        let database = try openDatabase()
        let row = try database.sqlite.value("SELECT dedupe_key, kind FROM recent_container") {
            (key: $0.text(0), kind: $0.text(1))
        }
        XCTAssertEqual(row?.key, "playlist:qq:p9")
        // 靠前（更近）的那条赢，与 `LibraryStore.deduplicated` 同解。
        XCTAssertEqual(row?.kind, "libraryPlaylist")
    }

    /// 旧存档根本没有 `recentContainers` 这个键 → 按老规则回灌一份（货架不至于空着）；
    /// 键在、但是空数组 → 不回灌。**那个 `Optional` 就是为了分出这两件事。**
    func testMissingContainerKeyIsBackfilledButEmptyArrayIsNot() throws {
        var archive = LegacyLibraryArchive()
        archive.recents = [makeTrack("ne:1"), makeTrack("ne:2")]
        archive.recentContainers = nil
        try write(archive, to: archiveURL)
        // 两首同一张碟（albumId 都是 ne:album:1）→ 老规则去重成一张专辑卡。
        XCTAssertEqual(try migrate().counts["recent_container"], 1)

        // 连旁文件一起清，好让第二次跑走的还是「库不存在」那一路。
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
        archive.recentContainers = []
        try write(archive, to: archiveURL)
        XCTAssertEqual(try migrate().counts["recent_container"], 0)
    }

    // MARK: - 本机文件

    /// `index.json` 每条一行，`path` 以 `/` 开头的是原地引用 → `scope='external'`，
    /// 其余是媒体夹内的相对路径 → `scope='media'`。判据就是 `DownloadStore.isExternal` 本人。
    func testDownloadIndexSeedsScopeByPathShape() throws {
        try write(LegacyLibraryArchive(), to: archiveURL)
        try write([
            "ne:1": DownloadEntryFixture(path: "网易云/a.flac", bytes: 10, date: Date()),
            "qq:2": DownloadEntryFixture(path: "/Users/someone/b.mp3", bytes: 20, date: Date()),
        ], to: indexURL)
        try migrate()

        let database = try openDatabase()
        let scopes = try database.sqlite.query(
            "SELECT key, scope FROM local_file ORDER BY key") { ($0.text(0), $0.text(1)) }
        XCTAssertEqual(scopes.map(\.0), ["ne:1", "qq:2"])
        XCTAssertEqual(scopes.map(\.1), ["media", "external"])
    }

    /// **`fileExists` 这道闸。** 实测用户本机 8 条带 `localPath` 的曲目全部指向改名前的
    /// `~/Music/AM/媒体`、8 条文件全不存在。不加闸就等于把一份已经腐败的真值原样灌进
    /// 新库，而新库是要当权威用的。
    func testDeadLocalPathIsNotSeeded() throws {
        var archive = LegacyLibraryArchive()
        archive.libraryTracks = [
            makeTrack("local:dead", albumId: nil,
                      localPath: media.appendingPathComponent("早就没了.flac").path),
        ]
        try write(archive, to: archiveURL)

        XCTAssertEqual(try migrate().counts["local_file"], 0)
    }

    /// 反过来：文件真在、索引里又没有这一条 → 补一行 `scope='external'`。
    func testLiveLocalPathSeedsExternalRow() throws {
        let live = try makeLiveFile(named: "真在.flac")
        var archive = LegacyLibraryArchive()
        archive.libraryTracks = [makeTrack("local:live", albumId: nil, localPath: live.path)]
        try write(archive, to: archiveURL)

        XCTAssertEqual(try migrate().counts["local_file"], 1)
        let database = try openDatabase()
        let row = try database.sqlite.value("""
            SELECT scope, relative_path, bytes FROM local_file WHERE key = 'local:live'
            """) { (scope: $0.text(0), path: $0.text(1), bytes: Int($0.int(2))) }
        XCTAssertEqual(row?.scope, "external")
        // external 存的是绝对路径（搬媒体夹不搬它，删歌也不删它）。
        XCTAssertEqual(row?.path, live.path)
        XCTAssertGreaterThan(row?.bytes ?? 0, 0)
    }

    /// 索引里已经有这个 id 了：**不补**第二行。清单是权威，`localPath` 只是补漏。
    func testLocalPathDoesNotDuplicateAnIndexedEntry() throws {
        let live = try makeLiveFile(named: "两边都有.flac")
        var archive = LegacyLibraryArchive()
        archive.libraryTracks = [makeTrack("local:both", albumId: nil, localPath: live.path)]
        try write(archive, to: archiveURL)
        try write(["local:both": DownloadEntryFixture(path: "本地/两边都有.flac", bytes: 7,
                                                      date: Date())], to: indexURL)

        XCTAssertEqual(try migrate().counts["local_file"], 1)
        let database = try openDatabase()
        let scope = try database.sqlite.value(
            "SELECT scope FROM local_file WHERE key = 'local:both'") { $0.text(0) }
        XCTAssertEqual(scope, "media", "以清单为准")
    }

    private func makeLiveFile(named name: String) throws -> URL {
        let url = media.appendingPathComponent(name)
        try Data("这是一份真的存在的文件".utf8).write(to: url)
        return url
    }

    // MARK: - 搜索索引

    /// 索引这一轮就填好，而且真能 MATCH 到。
    ///
    /// 「里香」这一条是重点：默认的 `unicode61` 分词器把整串汉字当**一个** token，
    /// 不逐字垫空格的话「里香」搜不到「七里香」——那是功能回归。
    func testSearchIndexIsPopulatedAndMatches() throws {
        var archive = LegacyLibraryArchive()
        archive.libraryTracks = [makeTrack("ne:2", title: "七里香", artist: "周杰倫",
                                           album: "七里香", albumId: "ne:album:2")]
        archive.libraryAlbums = [makeAlbum("ne:album:2", name: "七里香", artist: "周杰倫")]
        archive.playlists = [makePlaylist("local:P1", name: "开车听的", tracks: [])]
        try write(archive, to: archiveURL)
        try migrate()

        let database = try openDatabase()
        func match(_ input: String) throws -> Set<String> {
            guard let query = LibrarySearch.ftsQuery(input) else { return [] }
            return Set(try database.sqlite.query(
                "SELECT owner_kind || ':' || owner_id FROM search_index WHERE search_index MATCH ?",
                [query]) { $0.text(0) })
        }

        // 汉字子串：靠逐字垫空格 + 短语邻近。
        XCTAssertTrue(try match("里香").contains("track:ne:2"))
        XCTAssertTrue(try match("里香").contains("album:ne:album:2"))
        // 反序不命中——邻近约束就是「没退化成 AND」的那道闸。
        XCTAssertTrue(try match("香里").isEmpty)
        // 拼音三形态是白送的附加召回通道。
        XCTAssertTrue(try match("qlx").contains("track:ne:2"))
        // 艺人是从入库专辑 / 曲目的艺人名派生的，id 是 library-artist:<名字>。
        XCTAssertTrue(try match("周杰倫").contains("artist:\(Artist.libraryIDPrefix)周杰倫"))
        // 歌单也在同一张表里。
        XCTAssertTrue(try match("开车").contains("playlist:local:P1"))
    }
    // MARK: - 改名只能跟着 store 走

    /// 打开改名开关之后，Application Support 里那**三份**存档全部改名留底。
    ///
    /// 改名的含义是「这份存档已经没人读了」，所以它只能跟着对应的 store 真的改读 SQL
    /// 那一刻走：阶段 3 只有 `library.json`（那一轮这条用例断言另外两份必须原地不动），
    /// 阶段 4 `TrackInfoStore` / `LoudnessStore` 也并进主库，两份才跟上来。
    ///
    /// [实测 2026-09-17] 提前改名跑过一次实机：`loudness.json` 从 15 条变成 6 条——
    /// 那时 `LoudnessStore` 还在读它，被改名之后当成空的从头开始，又把空的写了回去。
    /// 所以这条用例钉的不是洁癖，是一次真的数据回退：**下一次再加存档，也要等它的 store
    /// 真的搬完了才许进那个数组。**
    func testRenameOnlyTouchesArchivesWhoseStoreHasMoved() throws {
        try write(LegacyLibraryArchive(), to: archiveURL)
        try write(TrackInfoArchiveFixture(), to: trackInfoURL)
        try write(["qq:1": LoudnessEntry(lufs: -14.2, peakDB: -1.0, measuredAt: Date())],
                  to: loudnessURL)
        try write([String: DownloadEntryFixture](), to: indexURL)

        _ = try AmberDatabaseMigration.runIfNeeded(
            directory: support, mediaFolder: media, renameLegacyOnSuccess: true)

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: archiveURL.path), "library.json 该改名了")
        XCTAssertFalse(fm.fileExists(atPath: trackInfoURL.path),
                       "trackinfo.json 该改名了——TrackInfoStore 已经改读主库")
        XCTAssertFalse(fm.fileExists(atPath: loudnessURL.path),
                       "loudness.json 该改名了——LoudnessStore 已经改读主库")
        XCTAssertTrue(fm.fileExists(atPath: indexURL.path),
                      "index.json 是媒体夹的清单，任何阶段都不改名")
        let leftovers = try fm.contentsOfDirectory(atPath: support.path)
        for name in ["library.json", "trackinfo.json", "loudness.json"] {
            XCTAssertTrue(leftovers.contains { $0.hasPrefix("\(name).migrated-") },
                          "\(name) 要留底，目录里现在是 \(leftovers)")
        }
    }

    // MARK: - 谁先开库谁负责迁移

    /// **这条用例守的是 `AppState` 里那个构造顺序。**
    ///
    /// `AppState` 的几个 store 一度是「带默认值的存储属性」，而 Swift 会在 `init` 体
    /// 跑起来之前就把它们造好——也就是在 `prepareDatabase()` 之前。它们一旦开主库，
    /// 第一个被造出来的那个就会先建出一个空的 `library.sqlite`，而迁移器的幂等判据
    /// 只有「库文件在，一切免谈」这一条，于是迁移**整个不跑**：用户的 `library.json`
    /// 原封不动躺在那儿，App 打开却是一个空资料库。本机看不出来（库早迁好了），
    /// 在任何全新安装上就是整份资料库静默消失。
    ///
    /// 所以那三行挪进了 `init` 体、挪到 `prepareDatabase()` 后面；而这里钉的是**更强的
    /// 那一条**——不管哪个 store 先被造出来，旧 JSON 都已经搬完了。以后再往 `AppState`
    /// 加一个 store，顺序写错的代价也只是少一次警告，不会是空库。
    func testStoreConstructedBeforeMigrationStillEndsUpWithAFullDatabase() throws {
        var archive = LegacyLibraryArchive()
        archive.libraryTracks = [makeTrack("ne:1", title: "迁过来的")]
        try write(archive, to: archiveURL)
        var infos = TrackInfoArchiveFixture()
        var info = TrackInfo()
        info.comments = "手打的注释"
        infos.infos = ["ne:1": info]
        try write(infos, to: trackInfoURL)
        try write(["ne:1": LoudnessEntry(lufs: -14.2, peakDB: -1.0, measuredAt: Date())],
                  to: loudnessURL)

        // 故意让 `LoudnessStore` 第一个开库（就是从前那个「存储属性先于 init 体」的顺序）。
        let loudness = LoudnessStore(directory: support)
        let trackInfo = TrackInfoStore(directory: support)
        let library = LibraryStore(directory: support)

        XCTAssertEqual(library.libraryTracks.map(\.title), ["迁过来的"], "资料库不该是空的")
        XCTAssertEqual(trackInfo.infos["ne:1"]?.comments, "手打的注释")
        XCTAssertEqual(loudness["ne:1"]?.lufs, -14.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path),
                       "迁移真的跑过了（旧存档已经改名留底）")
    }

}
