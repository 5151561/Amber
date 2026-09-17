import XCTest
@testable import Amber

/// 「从资料库中删除」时**文件去哪**（`library 规格` §10.2）。
///
/// 对话框本身是 `NSAlert`，测不了；能测也真正要钉住的是它选完之后动的那两件事——
/// `DownloadStore.trash(ids:)` / `forget(ids:)`，以及「该不该问」那条判据
/// `hasMediaFolderFile(_:)`。§10.2 的关键限制词是「仅“媒体”文件夹中的文件」，
/// 三条用例围着的就是这一句。
@MainActor
final class LibraryDeleteFilesTests: XCTestCase {

    /// 当「媒体」文件夹用。
    private var directory: URL!
    /// 用户自己的目录：原地引用（external）的文件放这儿，删歌一个字节都不许碰。
    private var outside: URL!

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryDeleteFilesTests-\(UUID().uuidString)",
                                    isDirectory: true)
        directory = root.appendingPathComponent("媒体", isDirectory: true)
        outside = root.appendingPathComponent("我的音乐", isDirectory: true)
        for url in [directory!, outside!] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func makeTrack(_ suffix: String) -> Track {
        Track(id: "\(Track.localIDPrefix)\(suffix)", kind: .qq, title: "曲 \(suffix)",
              artistName: "某人", artistId: nil, albumName: "某碟", albumId: nil,
              artworkURL: nil, duration: 200)
    }

    /// 造一份文件并让下载索引认领它，返回（曲目, 文件）。
    private func adopt(_ suffix: String, external: Bool,
                       into store: DownloadStore) throws -> (Track, URL) {
        let folder = external ? outside! : directory!
        let url = folder.appendingPathComponent("\(suffix).m4a")
        try Data("audio".utf8).write(to: url)
        let track = makeTrack(suffix)
        store.adoptLocalFile(at: url, for: track, external: external)
        return (track, url)
    }

    /// 「该不该问」：只有文件真在「媒体」文件夹里才问得起「移到废纸篓还是保留」。
    func testOnlyMediaFolderFilesAreAskedAbout() throws {
        let store = DownloadStore(directory: directory)
        let (inside, _) = try adopt("a", external: false, into: store)
        let (external, _) = try adopt("b", external: true, into: store)

        XCTAssertTrue(store.hasMediaFolderFile(inside.id))
        XCTAssertFalse(store.hasMediaFolderFile(external.id),
                       "原地引用的文件不归「媒体」文件夹管，删除时本来就不碰它")
        XCTAssertFalse(store.hasMediaFolderFile("\(Track.localIDPrefix)nobody"))
    }

    /// 「保留文件」：索引清掉，磁盘上那份原样留着。
    ///
    /// 清索引这一半不能省——条目都不在资料库里了，索引里却还记着一条「已下载」，
    /// 同一首歌再入库时会顶着一个指向旧文件的状态。
    func testForgetKeepsTheFileOnDisk() throws {
        let store = DownloadStore(directory: directory)
        let (track, url) = try adopt("c", external: false, into: store)

        store.forget(ids: [track.id])

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "用户选的是「保留文件」")
        XCTAssertEqual(store.state(for: track.id), .none)
        XCTAssertFalse(store.hasMediaFolderFile(track.id))
    }

    /// 「移到废纸篓」：媒体文件夹里的那份进废纸篓（不是永久删——用户还能捞回来），
    /// 索引清掉。
    func testTrashMovesMediaFolderFileToTrash() throws {
        let store = DownloadStore(directory: directory)
        let (track, url) = try adopt("d", external: false, into: store)

        store.trash(ids: [track.id])

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.state(for: track.id), .none)
    }

    /// 外部引用的文件：选了「移到废纸篓」也不许动它——那是用户自己的文件，
    /// §10.2 明写「仅“媒体”文件夹中的文件」。
    func testTrashNeverTouchesExternalFiles() throws {
        let store = DownloadStore(directory: directory)
        let (track, url) = try adopt("e", external: true, into: store)

        store.trash(ids: [track.id])

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "原地引用的是用户的文件，删歌不该把它扔进废纸篓")
        XCTAssertEqual(store.state(for: track.id), .none, "索引照旧要清")
    }
}
