import XCTest
@testable import Amber

/// 「减少推荐」的本地镜像（`LibraryStore.suggestLessTrackIDs`）。
///
/// 真值在音源账号里，这份镜像只决定菜单弹开时摆「减少推荐」还是「撤销减少推荐」，
/// 所以要验的就两件事：改完读得到、重启之后还在。
///
/// `LibraryStore` 注入临时目录，绝不碰真实的 `~/Library/Application Support/Amber/`。
@MainActor
final class SuggestLessMirrorTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SuggestLessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> LibraryStore { LibraryStore(directory: directory) }

    private func makeTracks(_ count: Int) -> [Track] {
        (0..<count).map {
            Track(id: "qq:suggest\($0)", kind: .qq, title: "歌 \($0)", artistName: "艺人",
                  artistId: nil, albumName: "碟", albumId: nil, artworkURL: nil, duration: 200)
        }
    }

    /// 没说过就是没说过：默认全是「减少推荐」那一侧。
    func testNothingIsSuggestedLessByDefault() {
        let store = makeStore()
        XCTAssertFalse(makeTracks(1).contains { store.isSuggestedLess($0) })
        XCTAssertFalse(store.isSuggestedLessArtist("qq:0025NhlN2yWrP4"))
    }

    func testTrackMirrorRoundTripsThroughDisk() {
        let tracks = makeTracks(3)
        let store = makeStore()
        store.setSuggestedLess([tracks[0], tracks[1]], true)
        store.setSuggestedLess([tracks[1]], false)
        store.flushNow()

        let restored = makeStore()
        XCTAssertTrue(restored.isSuggestedLess(tracks[0]))
        XCTAssertFalse(restored.isSuggestedLess(tracks[1]))
        XCTAssertFalse(restored.isSuggestedLess(tracks[2]))
    }

    func testArtistMirrorRoundTripsThroughDisk() {
        let store = makeStore()
        store.setSuggestedLessArtist("qq:0025NhlN2yWrP4", true)
        store.flushNow()

        let restored = makeStore()
        XCTAssertTrue(restored.isSuggestedLessArtist("qq:0025NhlN2yWrP4"))
        restored.setSuggestedLessArtist("qq:0025NhlN2yWrP4", false)
        restored.flushNow()

        XCTAssertFalse(makeStore().isSuggestedLessArtist("qq:0025NhlN2yWrP4"))
    }

    /// 旧存档里没有这两个键（`suggestLessTracks` / `suggestLessArtists`）：
    /// 缺键要回落成「那两张表 0 行」，而不是整份存档解不动——与 `uncheckedTracks` 同一个坑。
    ///
    /// 这条现在守的是 `AmberDatabaseMigration`（fixture 一个字节没动）。
    /// 值钱的地方在于：从前「缺这个键」与「这个键解坏了」被压成同一种处置（一律回落默认值），
    /// 数据出问题时一声不响；迁移器把「主存档解不动」单拎出来当致命错，不再静默。
    func testOldArchiveWithoutTheKeysStillLoads() throws {
        let legacy = """
        {"favorites":[],"recents":[]}
        """
        try legacy.write(to: directory.appendingPathComponent("library.json"),
                         atomically: true, encoding: .utf8)
        let store = makeStore()
        XCTAssertFalse(store.isSuggestedLess(makeTracks(1)[0]))
    }
}
