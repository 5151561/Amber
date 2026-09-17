import XCTest
@testable import Amber

/// 资料库播放列表：自建列表的增删改、音源歌单入库、账号歌单同步。
///
/// `LibraryStore` 注入临时目录，绝不碰真实的 `~/Library/Application Support/Amber/`。
@MainActor
final class LibraryPlaylistStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryPlaylistTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> LibraryStore { LibraryStore(directory: directory) }

    private func makeTrack(_ id: String, title: String) -> Track {
        Track(id: id, kind: .qq, title: title, artistName: "某人", artistId: nil,
              albumName: "某碟", albumId: "album", artworkURL: nil, duration: 200)
    }

    private func makePlaylist(_ id: String, name: String) -> Playlist {
        Playlist(id: id, kind: .qq, name: name, coverURL: "https://example.com/\(id).jpg",
                 trackCount: 10, creatorName: "冬日森林")
    }

    // MARK: - 自建列表

    func testCreateRenameAddRemove() {
        let store = makeStore()
        let playlist = store.createPlaylist(name: "开车听的")
        XCTAssertEqual(store.playlists.count, 1)
        XCTAssertEqual(store.editablePlaylists.map(\.id), [playlist.id])

        store.addTracks([makeTrack("1", title: "A"), makeTrack("2", title: "B")],
                        toPlaylist: playlist.id)
        XCTAssertEqual(store.playlist(id: playlist.id)?.tracks.map(\.title), ["A", "B"])

        store.renamePlaylist(id: playlist.id, to: "  夜路  ")
        XCTAssertEqual(store.playlist(id: playlist.id)?.name, "夜路", "改名要去掉首尾空白")
        store.renamePlaylist(id: playlist.id, to: "   ")
        XCTAssertEqual(store.playlist(id: playlist.id)?.name, "夜路", "空名字不生效")

        store.removeTracks(at: IndexSet(integer: 0), fromPlaylist: playlist.id)
        XCTAssertEqual(store.playlist(id: playlist.id)?.tracks.map(\.title), ["B"])

        store.deletePlaylist(id: playlist.id)
        XCTAssertTrue(store.playlists.isEmpty)
    }

    /// Music 允许同一首歌在一份列表里出现多次，Amber 跟它一致，不去重。
    func testDuplicateTracksAllowed() {
        let store = makeStore()
        let playlist = store.createPlaylist(name: "循环")
        let track = makeTrack("1", title: "A")
        store.addTracks([track], toPlaylist: playlist.id)
        store.addTracks([track], toPlaylist: playlist.id)
        XCTAssertEqual(store.playlist(id: playlist.id)?.tracks.count, 2)
    }

    func testDefaultNameAvoidsCollision() {
        let store = makeStore()
        XCTAssertEqual(store.defaultNewPlaylistName(), "新建播放列表")
        store.createPlaylist(name: store.defaultNewPlaylistName())
        XCTAssertEqual(store.defaultNewPlaylistName(), "新建播放列表 2")
        store.createPlaylist(name: store.defaultNewPlaylistName())
        XCTAssertEqual(store.defaultNewPlaylistName(), "新建播放列表 3")
    }

    func testPersistedAcrossInstances() {
        let store = makeStore()
        let playlist = store.createPlaylist(name: "存盘", tracks: [makeTrack("1", title: "A")])
        store.addPlaylistToLibrary(makePlaylist("qq:123", name: "忧伤"))
        store.flushNow()   // 写盘是防抖的，断言磁盘内容前先同步落一次

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.playlists.count, 2)
        XCTAssertEqual(reloaded.playlist(id: playlist.id)?.tracks.count, 1)
        XCTAssertEqual(reloaded.playlist(id: "qq:123")?.origin, .added)
    }

    // MARK: - 音源歌单入库

    /// 音源镜像只读：加歌、改名都不该落地（Amber 没有写回音源的能力）。
    func testSourcePlaylistIsReadOnly() {
        let store = makeStore()
        let source = makePlaylist("qq:123", name: "忧伤")
        store.addPlaylistToLibrary(source)
        XCTAssertTrue(store.isPlaylistInLibrary(source))
        XCTAssertTrue(store.editablePlaylists.isEmpty)

        store.addTracks([makeTrack("1", title: "A")], toPlaylist: source.id)
        store.renamePlaylist(id: source.id, to: "改了")
        XCTAssertEqual(store.playlist(id: source.id)?.tracks.count, 0)
        XCTAssertEqual(store.playlist(id: source.id)?.name, "忧伤")

        store.addPlaylistToLibrary(source)
        XCTAssertEqual(store.playlists.count, 1, "重复添加同一张不该多出一条")
    }

    // MARK: - 账号歌单同步

    func testSyncIsIdempotentAndPrunesRemovedOnes() {
        let store = makeStore()
        let mine = store.createPlaylist(name: "自建的")
        store.addPlaylistToLibrary(makePlaylist("qq:900", name: "手动加的"))

        store.syncAccountPlaylists([makePlaylist("qq:1", name: "我喜欢"),
                                    makePlaylist("qq:2", name: "1207")], kind: .qq)
        XCTAssertEqual(store.playlists.count, 4)

        // 再同步一次：名字更新、不重复、账号里没有的那条被摘掉
        var renamed = makePlaylist("qq:1", name: "我喜欢（新）")
        renamed.coverURL = "https://example.com/new.jpg"
        store.syncAccountPlaylists([renamed], kind: .qq)
        XCTAssertEqual(store.playlist(id: "qq:1")?.name, "我喜欢（新）")
        XCTAssertEqual(store.playlist(id: "qq:1")?.coverURL, "https://example.com/new.jpg")
        XCTAssertNil(store.playlist(id: "qq:2"), "账号里没有了的账号歌单要摘掉")
        XCTAssertNotNil(store.playlist(id: mine.id), "自建的不受同步影响")
        XCTAssertNotNil(store.playlist(id: "qq:900"), "手动加进来的不受同步影响")
    }

    /// 删掉的账号歌单默认不再被同步拉回来；只有手动「刷新账号歌单」才拉回。
    func testDeletedAccountPlaylistStaysGoneUntilManualRefresh() {
        let store = makeStore()
        let remote = [makePlaylist("qq:1", name: "我喜欢")]
        store.syncAccountPlaylists(remote, kind: .qq)
        store.deletePlaylist(id: "qq:1")

        store.syncAccountPlaylists(remote, kind: .qq)
        XCTAssertNil(store.playlist(id: "qq:1"))

        store.syncAccountPlaylists(remote, kind: .qq, resetDismissed: true)
        XCTAssertNotNil(store.playlist(id: "qq:1"))
    }

    func testSyncOnlyTouchesItsOwnProvider() {
        let store = makeStore()
        store.syncAccountPlaylists([makePlaylist("qq:1", name: "QQ 的")], kind: .qq)
        store.syncAccountPlaylists([Playlist(id: "ne:1", kind: .netease, name: "网易云的")],
                                   kind: .netease)
        XCTAssertEqual(store.playlists.count, 2)

        store.syncAccountPlaylists([], kind: .netease)
        XCTAssertNotNil(store.playlist(id: "qq:1"), "清空网易云不该动到 QQ 的")
        XCTAssertNil(store.playlist(id: "ne:1"))
    }

    /// 一次账号同步要摘一批、改一批、补一批，中间不能每动一条就通知一次视图：
    /// 侧栏与所有列表页会跟着重画同样次数，`@Published` 的数组也会真的复制那么多份。
    func testBatchUpdateNotifiesOnce() async {
        let store = makeStore()
        store.createPlaylist(name: "一")
        store.createPlaylist(name: "二")
        store.createPlaylist(name: "三")

        // 以前数的是 `objectWillChange`；换 `@Observable` 之后没有那条大喇叭，
        // 数的是细出口 `changes(affecting: .playlists)`——侧栏与列表页订的就是这一条。
        var notifications = 0
        let changes = store.changes(affecting: .playlists)
        let watcher = Task { @MainActor in
            for await _ in changes { notifications += 1 }
        }
        defer { watcher.cancel() }
        await settleObservations()

        store.updatePlaylists { playlists in
            playlists.removeFirst()
            for index in playlists.indices { playlists[index].name += "!" }
            playlists.append(.local(name: "四"))
        }
        await settleObservations()
        XCTAssertEqual(notifications, 1, "整批改完只发一次")
        XCTAssertEqual(store.playlists.map(\.name), ["二!", "一!", "四"])
    }

    /// 账号同步走的就是上面那条批量通道。
    @MainActor
    func testAccountSyncNotifiesOnce() async {
        let store = makeStore()
        store.syncAccountPlaylists([makePlaylist("qq:1", name: "旧一"),
                                    makePlaylist("qq:2", name: "旧二")], kind: .qq)

        var notifications = 0
        let changes = store.changes(affecting: .playlists)
        let watcher = Task { @MainActor in
            for await _ in changes { notifications += 1 }
        }
        defer { watcher.cancel() }
        await settleObservations()

        store.syncAccountPlaylists([makePlaylist("qq:1", name: "新一"),
                                    makePlaylist("qq:3", name: "新三")], kind: .qq)
        await settleObservations()
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(store.playlists.map(\.name), ["新一", "新三"])
    }
}
