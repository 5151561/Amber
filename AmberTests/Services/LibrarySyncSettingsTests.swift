import XCTest
@testable import Amber

/// 设置 › 高级 的两条「添加与删除…」开关，以及自动下载要用的 `onTracksAdded`。
///
/// 这两条开关读的是 `AppSettings.shared`（`LibraryStore` 不是视图，拿不到环境对象），
/// 所以每个用例改完要还原——同一个进程里跑的别的用例还指望着出厂值。
@MainActor
final class LibrarySyncSettingsTests: XCTestCase {

    private var directory: URL!
    private var savedValues: SettingsValues!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        savedValues = AppSettings.shared.values
    }

    override func tearDownWithError() throws {
        AppSettings.shared.values = savedValues
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> LibraryStore { LibraryStore(directory: directory) }

    private func makeTrack(_ id: String, title: String = "歌") -> Track {
        Track(id: id, kind: .qq, title: title, artistName: "某人", artistId: nil,
              albumName: "某碟", albumId: "album", artworkURL: nil, duration: 200)
    }

    private func makeAlbum() -> Album {
        Album(id: "album", kind: .qq, name: "某碟", artistName: "某人", artistId: nil,
              artworkURL: nil, publishDate: nil, trackCount: 2, description: nil)
    }

    private func set(playlistSync: Bool? = nil, favoriteSync: Bool? = nil) {
        var values = AppSettings.shared.values
        if let playlistSync { values.syncPlaylistSongsWithLibrary = playlistSync }
        if let favoriteSync { values.syncFavoriteSongsWithLibrary = favoriteSync }
        AppSettings.shared.values = values
    }

    // MARK: - 添加与删除播放列表歌曲

    /// 开着时加进本地列表的歌同时进资料库，且保持原曲序（不是倒着进去）。
    func testPlaylistAddAlsoAddsToLibraryWhenOn() {
        set(playlistSync: true)
        let store = makeStore()
        let playlist = store.createPlaylist(name: "开车听的")

        store.addTracks([makeTrack("1", title: "A"), makeTrack("2", title: "B")],
                        toPlaylist: playlist.id)

        XCTAssertEqual(store.libraryTracks.map(\.title), ["A", "B"])
    }

    func testPlaylistAddLeavesLibraryAloneWhenOff() {
        set(playlistSync: false)
        let store = makeStore()
        let playlist = store.createPlaylist(name: "开车听的")

        store.addTracks([makeTrack("1")], toPlaylist: playlist.id)

        XCTAssertTrue(store.libraryTracks.isEmpty)
    }

    /// 删资料库时从本地列表里也清掉；音源/账号那种只读镜像不动
    ///（清了下次同步还会回来，等于「看着生效其实没有」）。
    func testRemoveFromLibraryPrunesLocalPlaylistsOnly() {
        set(playlistSync: true)
        let store = makeStore()
        let track = makeTrack("1")
        let local = store.createPlaylist(name: "开车听的", tracks: [track])
        store.updatePlaylists { playlists in
            playlists.append(LibraryPlaylist(
                id: "qq:mirror", name: "音源歌单", origin: .added,
                source: Playlist(id: "qq:mirror", kind: .qq, name: "音源歌单",
                                 coverURL: nil, trackCount: 1, creatorName: "谁"),
                tracks: [track], coverURL: nil, description: nil,
                createdAt: Date(), addedAt: Date()))
        }
        store.addToLibrary(track)

        store.removeFromLibrary(track)

        XCTAssertEqual(store.playlist(id: local.id)?.tracks.count, 0)
        XCTAssertEqual(store.playlist(id: "qq:mirror")?.tracks.count, 1)
    }

    func testRemoveFromLibraryKeepsPlaylistWhenOff() {
        set(playlistSync: false)
        let store = makeStore()
        let track = makeTrack("1")
        let local = store.createPlaylist(name: "开车听的", tracks: [track])
        store.addToLibrary(track)

        store.removeFromLibrary(track)

        XCTAssertEqual(store.playlist(id: local.id)?.tracks.count, 1)
    }

    // MARK: - 添加与删除喜爱歌曲

    func testFavoriteAlsoAddsToLibraryWhenOn() {
        set(favoriteSync: true)
        let store = makeStore()
        let track = makeTrack("1")

        store.toggleFavorite(track)

        XCTAssertTrue(store.isInLibrary(track))
        // 取消心水不反过来删资料库：那是两件事（Music 同）
        store.toggleFavorite(track)
        XCTAssertFalse(store.isFavorite(track))
        XCTAssertTrue(store.isInLibrary(track))
    }

    func testFavoriteLeavesLibraryAloneWhenOff() {
        set(favoriteSync: false)
        let store = makeStore()
        let track = makeTrack("1")

        store.toggleFavorite(track)

        XCTAssertTrue(store.isFavorite(track))
        XCTAssertFalse(store.isInLibrary(track))
    }

    func testRemoveFromLibraryAlsoUnfavoritesWhenOn() {
        set(favoriteSync: true)
        let store = makeStore()
        let track = makeTrack("1")
        store.toggleFavorite(track)

        store.removeFromLibrary(track)

        XCTAssertFalse(store.isFavorite(track))
        XCTAssertFalse(store.isInLibrary(track))
    }

    func testRemoveFromLibraryKeepsFavoriteWhenOff() {
        set(favoriteSync: false)
        let store = makeStore()
        let track = makeTrack("1")
        store.toggleFavorite(track)
        store.addToLibrary(track)

        store.removeFromLibrary(track)

        XCTAssertTrue(store.isFavorite(track))
    }

    /// 整张碟出库时同样按开关清（删除入口有好几处，走的是同一个 prune）。
    func testRemoveAlbumPrunesFavorites() {
        set(favoriteSync: true)
        let store = makeStore()
        let tracks = [makeTrack("1", title: "A"), makeTrack("2", title: "B")]
        store.addAlbumToLibrary(makeAlbum(), tracks: tracks)
        tracks.forEach { store.toggleFavorite($0) }

        store.removeAlbumFromLibrary(makeAlbum(), tracks: tracks)

        XCTAssertTrue(store.favoriteTracks.isEmpty)
    }

    // MARK: - onTracksAdded（自动下载的入口）

    /// 单曲一条、整张碟一条（按原曲序），已经在库里的不再报一次。
    func testOnTracksAddedFiresOncePerBatch() {
        set(playlistSync: false, favoriteSync: false)
        let store = makeStore()
        var batches: [[String]] = []
        store.onTracksAdded = { batches.append($0.map(\.title)) }

        store.addToLibrary(makeTrack("1", title: "A"))
        store.addToLibrary(makeTrack("1", title: "A"))
        store.addAlbumToLibrary(makeAlbum(),
                                tracks: [makeTrack("1", title: "A"), makeTrack("2", title: "B"),
                                         makeTrack("3", title: "C")])

        XCTAssertEqual(batches, [["A"], ["B", "C"]])
    }

    /// 开着「添加与删除播放列表歌曲」时，进歌单的歌也要走这条通知——
    /// 否则自动下载会漏掉从歌单进来的那些。
    func testOnTracksAddedFiresForPlaylistSync() {
        set(playlistSync: true)
        let store = makeStore()
        var batches: [[String]] = []
        store.onTracksAdded = { batches.append($0.map(\.title)) }
        let playlist = store.createPlaylist(name: "开车听的")

        store.addTracks([makeTrack("1", title: "A"), makeTrack("2", title: "B")],
                        toPlaylist: playlist.id)

        XCTAssertEqual(batches, [["A", "B"]])
    }
}
