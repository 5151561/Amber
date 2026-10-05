import XCTest
@testable import Amber

/// 艺人那一档的**增量**对账（`LibrarySearchIndex.reconcileTouchedArtists`）与全量对账逐字一致。
///
/// 做法：拿一个定种子的随机数，对 store 打一长串入库 / 退库 / 整碟进出 / 改艺人名 / 起播带新元数据 /
/// 撤销 / 重开，**每一步之后**：
///
/// 1. 读出表里艺人那一档的整行（四列正文 + id）——这是增量维护出来的结果；
/// 2. 在一个事务里另起一份 `LibrarySearchIndex`（从同一张表读指纹）跑一遍**全量**
///    `reconcileArtists(derivedArtists)`，再读一遍——这是对照组；然后回滚，不留痕；
/// 3. 两份逐字相等，且与「按派生艺人现算的索引行」逐字相等。
///
/// 跑两遍：一遍名字全是 NFC（增量那条路一直在走），一遍掺进规范等价、字节不同的拼写
///（分解式 `é` 与预组合 `é`、开尔文符号与 `K`）——那是增量判定（逐字节 `=`）与全量去重
///（Swift `==`）会分叉的唯一地方，退回全量那条路要被走到。
///
/// 全程临时目录，不碰真实资料库；`undoManager` 是测试自己 new 的，不碰任何全局状态。
@MainActor
final class LibraryArtistReconcileTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryArtistReconcileTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// SplitMix64：定种子，失败了能原样复现。
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 全是 NFC 的名字池：增量那条路一直走着（只有每次开库后的第一次对账是全量）。
    private static let nfcNames = [
        "周杰倫", "周杰伦", "Taylor Swift", "RADWIMPS", "陳奕迅", "", "Mr. Children",
        "Beyonc\u{E9}", "Kraftwerk",
    ]

    /// 再掺进规范等价、字节不同的拼写：库里一旦有它们，就该退回全量。
    private static let mixedNames = nfcNames + [
        "Beyonce\u{301}",   // 分解式 é，与预组合那条规范等价
        "\u{212A}raftwerk", // 开尔文符号 K
    ]

    /// owner_id、name、artist、album、phonetic 五列拼成一串，非 ASCII 一律转义成 `\u{…}`：
    /// Swift 的 `==` 按规范等价比，不转义的话两种拼写在断言里会「相等」，测的就不是逐字一致了。
    private typealias IndexRow = String

    private static func exact(_ columns: [String]) -> IndexRow {
        columns.map { $0.unicodeScalars.map { $0.escaped(asASCII: true) }.joined() }
            .joined(separator: " | ")
    }

    private func artistRows(_ db: SQLiteDatabase) throws -> [IndexRow] {
        try db.query("""
            SELECT owner_id, name, artist, album, phonetic FROM search_index
             WHERE owner_kind = 'artist'
            """, [], { Self.exact([$0.text(0), $0.text(1), $0.text(2), $0.text(3), $0.text(4)]) })
            .sorted()
    }

    /// 对照组：同一份库状态上跑全量对账，读完回滚。
    private func fullReconcileRows(_ db: SQLiteDatabase) throws -> [IndexRow] {
        try db.execute("BEGIN")
        defer { try? db.execute("ROLLBACK") }
        let control = LibrarySearchIndex()
        try control.load(from: db)
        try control.reconcileArtists(LibrarySearchIndex.derivedArtists(in: db), in: db)
        return try artistRows(db)
    }

    /// 从派生艺人直接现算出来的索引行（与 `rebuild` 写的同一份）。
    private func expectedRows(_ db: SQLiteDatabase) throws -> [IndexRow] {
        try LibrarySearchIndex.derivedArtists(in: db).map { artist in
            let row = LibrarySearch.indexRow(name: artist.name)
            return Self.exact([artist.id, row.name, row.artist, row.album, row.phonetic])
        }
        .sorted()
    }

    func testIncrementalMatchesFullAfterEveryStepWithNFCNames() throws {
        try runSequence(names: Self.nfcNames, seed: 20_261_006, in: directory)
    }

    func testIncrementalMatchesFullAfterEveryStepWithMixedSpellings() throws {
        try runSequence(names: Self.mixedNames, seed: 20_261_007, in: directory)
    }

    private func runSequence(names: [String], seed: UInt64, in directory: URL) throws {
        var rng = Seeded(state: seed)
        let undo = UndoManager()
        undo.groupsByEvent = false
        func open() -> LibraryStore {
            let store = LibraryStore(directory: directory)
            store.undoManager = undo
            return store
        }
        var store = open()
        let db = try AmberDatabase.shared(directory: directory).sqlite
        var serial = 0

        func randomName() -> String { names.randomElement(using: &rng)! }
        func makeTrack(artist: String, album: Album?) -> Track {
            serial += 1
            return Track(id: "qq:t\(serial)", kind: .qq, title: "Song \(serial)",
                         artistName: artist, artistId: nil,
                         albumName: album?.name ?? "Loose \(serial)", albumId: album?.id,
                         artworkURL: nil, duration: 180, trackNumber: serial, discNumber: 1)
        }

        for step in 0..<400 {
            let label: String
            let action = Int.random(in: 0..<100, using: &rng)
            switch action {
            case 0..<22:
                label = "单曲入库"
                let track = makeTrack(artist: randomName(), album: nil)
                store.withUndoGrouping(label) { store.addToLibrary(track) }
            case 22..<34:
                label = "整碟入库"
                serial += 1
                let artist = randomName()
                let album = Album(id: "qq:album\(serial)", kind: .qq, name: "Album \(serial)",
                                  artistName: artist, artistId: nil, artworkURL: nil,
                                  publishDate: nil, trackCount: 3, description: nil)
                // 碟里的歌有时挂别的艺人（合辑），专辑艺人与曲目艺人各算一个来源。
                let tracks = (0..<3).map { _ in
                    makeTrack(artist: Bool.random(using: &rng) ? artist : randomName(), album: album)
                }
                store.withUndoGrouping(label) { store.addAlbumToLibrary(album, tracks: tracks) }
            case 34..<52:
                label = "批量退库"
                let picked = store.libraryTracks.filter { _ in Int.random(in: 0..<4, using: &rng) == 0 }
                store.withUndoGrouping(label) { store.removeFromLibrary(picked) }
            case 52..<60:
                label = "整碟退库"
                guard let album = store.libraryAlbums.randomElement(using: &rng) else { continue }
                let tracks = store.libraryTracks.filter { $0.albumId == album.id }
                store.withUndoGrouping(label) { store.removeAlbumFromLibrary(album, tracks: tracks) }
            case 60..<75:
                label = "改艺人名"
                guard let track = store.libraryTracks.randomElement(using: &rng) else { continue }
                let name = randomName()
                store.withUndoGrouping(label) {
                    _ = store.updateTrack(id: track.id) { $0.artistName = name }
                }
            case 75..<83:
                // 起播带着音源新给的元数据走曲目漏斗：资料库曲目的艺人名就这么被改了，
                // 而这条路跟「资料库」不相干（从前的全量对账这一步也是漏的）。
                label = "起播带新艺人名"
                guard var track = store.libraryTracks.randomElement(using: &rng) else { continue }
                track.artistName = randomName()
                store.noteStarted(track)
            case 83..<95:
                label = "撤销"
                guard undo.canUndo else { continue }
                undo.undo()
            default:
                label = "重开"
                store.flushNow()
                undo.removeAllActions()  // 撤销栈里的目标是旧 store，重开之后不能再调
                store = open()
            }

            let incremental = try artistRows(db)
            let full = try fullReconcileRows(db)
            XCTAssertEqual(incremental, full, "第 \(step) 步（\(label)）之后增量 ≠ 全量")
            XCTAssertEqual(incremental, try expectedRows(db), "第 \(step) 步（\(label)）之后 ≠ 派生艺人")
            if incremental != full { return }  // 第一处分叉就停，后面的全是连带
        }
        // 走到这里说明 400 步都对上了；顺带确认语料真的造出了艺人（不是空跑）。
        XCTAssertFalse(try artistRows(db).isEmpty)
    }

    /// 只有 NFC 名字的库：增量路真被走到（不是一路退回全量混过去的）。
    ///
    /// 可观察的证据：绕开触发器把一首资料库曲目从 `library_track` 里摘掉，它的艺人就成了
    /// 「指纹里有、却没人挂着、也不在动到的名字里」的一行——全量对账会删它，增量不碰它。
    /// 之后动到一个非 NFC 名字，退回全量，它才被清掉。
    func testIncrementalPathIsTakenForNFCNames() throws {
        let store = LibraryStore(directory: directory)
        let db = try AmberDatabase.shared(directory: directory).sqlite
        func track(_ id: String, _ artist: String) -> Track {
            Track(id: id, kind: .qq, title: id, artistName: artist, artistId: nil,
                  albumName: "", albumId: nil, artworkURL: nil, duration: 1)
        }
        func ids(_ names: String...) -> [String] {
            names.map { Self.exact([Artist.libraryIDPrefix + $0]) }.sorted()
        }
        store.addToLibrary(track("qq:a", "周杰倫"))  // 第一次对账：全量，判出「全是 NFC」
        store.addToLibrary(track("qq:b", "陳奕迅"))
        XCTAssertEqual(try ownerIDs(db), ids("周杰倫", "陳奕迅"))

        try db.execute("DROP TRIGGER temp.artist_touched_ltrack_del")
        try db.run("DELETE FROM library_track WHERE track_id = 'qq:a'")
        try LibrarySearchIndex.installArtistTouchLog(in: db)

        store.addToLibrary(track("qq:c", "Taylor Swift"))  // 增量：只核对 Taylor Swift
        XCTAssertEqual(try ownerIDs(db), ids("Taylor Swift", "周杰倫", "陳奕迅"))

        store.addToLibrary(track("qq:d", "Beyonce\u{301}"))  // 非 NFC → 全量，周杰倫被清掉
        XCTAssertEqual(try ownerIDs(db), ids("Beyonce\u{301}", "Taylor Swift", "陳奕迅"))
    }

    private func ownerIDs(_ db: SQLiteDatabase) throws -> [String] {
        try db.query("SELECT owner_id FROM search_index WHERE owner_kind = 'artist'", [],
                     { Self.exact([$0.text(0)]) }).sorted()
    }
}
