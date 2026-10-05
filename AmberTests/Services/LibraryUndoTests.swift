import XCTest
@testable import Amber

/// 资料库的撤销（`LibraryStore.undoManager`）。
///
/// 口径与实机一致：注册全写在 store 的写入口里，调用点一行不动；没有 `undoManager`
/// （测试默认、以及迷你窗那种没有窗口委托的场合）时一条都不注册，写入路径原样。
///
/// **`groupsByEvent = false` + 每一步显式开合分组**：默认那条（`true`）靠 runloop
/// 在事件末尾收组，单测里不转 runloop，于是一个方法里的所有注册都落进同一组、
/// 一次 `undo()` 会把整串一起撤掉，分不出「每一步」。
/// [实测 probe 2026-09-17] 关掉之后逐步 undo / redo 都对得上，撤销执行中注册的
/// 反向操作也照常进重做栈。
///
/// `LibraryStore` 注入临时目录，绝不碰真实的 `~/Library/Application Support/Amber/`。
@MainActor
final class LibraryUndoTests: XCTestCase {

    private var directory: URL!
    private var manager: UndoManager!
    private var savedValues: SettingsValues!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryUndoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = UndoManager()
        manager.groupsByEvent = false
        // 两条「添加与删除…」开关读的是 `AppSettings.shared`，用例改完要还原
        //（同一个进程里跑的别的用例还指望着出厂值）。
        savedValues = AppSettings.shared.values
    }

    override func tearDown() async throws {
        AppSettings.shared.values = savedValues
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> LibraryStore { LibraryStore(directory: directory) }

    /// 布置场景时**先不挂**撤销登记处：那几步不该占撤销栈，挂上之后做的那一步才是被测的。
    private func attach(_ store: LibraryStore) { store.undoManager = manager }

    /// 一次「用户操作」＝ 一组。
    private func step(_ body: () -> Void) {
        manager.beginUndoGrouping()
        body()
        manager.endUndoGrouping()
    }

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

    // MARK: - 播放列表

    /// 删一份列表再撤销：整份（含曲目）回到**原来那一格**，不是被塞到最前面。
    func testDeletePlaylistUndoPutsItBackAtTheSameSlot() {
        let store = makeStore()
        _ = store.createPlaylist(name: "A")
        let middle = store.createPlaylist(name: "B", tracks: [makeTrack("1"), makeTrack("2")])
        _ = store.createPlaylist(name: "C")
        // `createPlaylist` 前插，所以数组是「最新的在前」。
        XCTAssertEqual(store.playlists.map(\.name), ["C", "B", "A"])

        attach(store)
        step { store.deletePlaylist(id: middle.id) }
        XCTAssertEqual(store.playlists.map(\.name), ["C", "A"])
        XCTAssertEqual(manager.undoActionName, "删除播放列表")

        manager.undo()
        XCTAssertEqual(store.playlists.map(\.name), ["C", "B", "A"])
        XCTAssertEqual(store.playlist(id: middle.id)?.tracks.map(\.id), ["1", "2"])

        manager.redo()
        XCTAssertEqual(store.playlists.map(\.name), ["C", "A"])
    }

    /// 撤销一条**已经被后续操作改过**的记录：同 id 的列表又在了，撤销什么都不做，
    /// 绝不放出第二份同 id 的列表。
    func testDeletePlaylistUndoIsNoOpWhenTheSameIDCameBack() {
        let store = makeStore()
        let playlist = store.createPlaylist(name: "B")

        attach(store)
        step { store.deletePlaylist(id: playlist.id) }
        XCTAssertTrue(store.playlists.isEmpty)

        // 用户自己又把同一份加了回来（音源歌单入库那条路不进撤销栈）。
        store.addPlaylistToLibrary(Playlist(id: playlist.id, kind: .qq, name: "B 的镜像",
                                            coverURL: nil, trackCount: 0, creatorName: "某人"))
        XCTAssertEqual(store.playlists.count, 1)

        manager.undo()
        XCTAssertEqual(store.playlists.filter { $0.id == playlist.id }.count, 1,
                       "同 id 已经在了，撤销必须原样放弃")
        XCTAssertEqual(store.playlists.first?.name, "B 的镜像")
    }

    func testRenamePlaylistUndoRestoresTheOldName() {
        let store = makeStore()
        let playlist = store.createPlaylist(name: "开车听的")

        attach(store)
        step { store.renamePlaylist(id: playlist.id, to: "夜路") }
        XCTAssertEqual(store.playlist(id: playlist.id)?.name, "夜路")
        XCTAssertEqual(manager.undoActionName, "重命名播放列表")

        manager.undo()
        XCTAssertEqual(store.playlist(id: playlist.id)?.name, "开车听的")

        manager.redo()
        XCTAssertEqual(store.playlist(id: playlist.id)?.name, "夜路")
    }

    /// 改名没真变就不占撤销栈（点了「确定」但一个字没改的那一下）。
    func testRenameWithTheSameNameRegistersNothing() {
        let store = makeStore()
        let playlist = store.createPlaylist(name: "开车听的")

        attach(store)
        store.renamePlaylist(id: playlist.id, to: "  开车听的  ")
        XCTAssertFalse(manager.canUndo)
    }

    func testRemoveTracksFromPlaylistUndoRestoresTheList() {
        let store = makeStore()
        let playlist = store.createPlaylist(name: "L")
        store.addTracks([makeTrack("1"), makeTrack("2"), makeTrack("3")], toPlaylist: playlist.id)

        attach(store)
        step { store.removeTracks(at: IndexSet(integer: 0), fromPlaylist: playlist.id) }
        XCTAssertEqual(store.playlist(id: playlist.id)?.tracks.map(\.id), ["2", "3"])
        XCTAssertEqual(manager.undoActionName, "从播放列表中删除")

        manager.undo()
        XCTAssertEqual(store.playlist(id: playlist.id)?.tracks.map(\.id), ["1", "2", "3"])

        manager.redo()
        XCTAssertEqual(store.playlist(id: playlist.id)?.tracks.map(\.id), ["2", "3"])
    }

    /// 列表内的撤销记的是**整份数组**，所以撤销之后这份列表就是删之前那个样子——
    /// 中间追加进来的那几首会被这一步盖掉。这是刻意的语义（下标会被后续增删作废，
    /// 「恢复成某个样子」不管中间发生过什么都说得通），钉在这里免得日后被当成 bug。
    func testPlaylistUndoRestoresTheWholeSnapshot() {
        let store = makeStore()
        let playlist = store.createPlaylist(name: "L")
        store.addTracks([makeTrack("1"), makeTrack("2")], toPlaylist: playlist.id)

        attach(store)
        step { store.removeTracks(at: IndexSet(integer: 0), fromPlaylist: playlist.id) }
        // `addTracks` 不进撤销栈，所以这一步不用开组。
        store.addTracks([makeTrack("9")], toPlaylist: playlist.id)
        XCTAssertEqual(store.playlist(id: playlist.id)?.tracks.map(\.id), ["2", "9"])

        manager.undo()
        XCTAssertEqual(store.playlist(id: playlist.id)?.tracks.map(\.id), ["1", "2"])
    }

    func testMoveTracksInPlaylistUndoRestoresTheOrder() {
        let store = makeStore()
        let playlist = store.createPlaylist(name: "L")
        store.addTracks([makeTrack("1"), makeTrack("2"), makeTrack("3")], toPlaylist: playlist.id)

        attach(store)
        step {
            store.moveTracks(fromOffsets: IndexSet(integer: 0), toOffset: 3,
                             inPlaylist: playlist.id)
        }
        XCTAssertEqual(store.playlist(id: playlist.id)?.tracks.map(\.id), ["2", "3", "1"])
        XCTAssertEqual(manager.undoActionName, "重新排序")

        manager.undo()
        XCTAssertEqual(store.playlist(id: playlist.id)?.tracks.map(\.id), ["1", "2", "3"])
    }

    // MARK: - 退库

    /// 退库的撤销要把**这一下连带动到的每一样**都放回去：曲目、心水、本地列表里的那一条、
    /// 勾选记号。放不回去的只有磁盘上的文件（见 `LibraryStore.LibraryRemoval` 的注释）。
    func testRemoveFromLibraryUndoRestoresEverythingItTouched() {
        set(playlistSync: true, favoriteSync: true)
        let store = makeStore()
        let track = makeTrack("1", title: "A")
        store.addToLibrary(track)
        store.addToLibrary(makeTrack("2", title: "B"))
        let playlist = store.createPlaylist(name: "L")
        store.addTracks([track], toPlaylist: playlist.id)
        store.toggleFavorite(track)
        store.setChecked(track, false)

        attach(store)
        step { store.removeFromLibrary(track) }
        XCTAssertFalse(store.isInLibrary(track))
        XCTAssertFalse(store.isFavorite(track))
        XCTAssertEqual(store.playlist(id: playlist.id)?.tracks.count, 0)
        XCTAssertTrue(store.isChecked(track), "退库会把「未勾选」那条记号一起清掉")
        XCTAssertEqual(manager.undoActionName, "从资料库中删除")

        manager.undo()
        XCTAssertTrue(store.isInLibrary(track))
        XCTAssertTrue(store.isFavorite(track))
        XCTAssertEqual(store.playlist(id: playlist.id)?.tracks.map(\.id), ["1"])
        XCTAssertFalse(store.isChecked(track))

        manager.redo()
        XCTAssertFalse(store.isInLibrary(track))
        XCTAssertFalse(store.isFavorite(track))
    }

    /// 撤销放回来的是**内存与库两头**，不是只改内存：重开一份 store（同一个目录）
    /// 照样看得见那首歌。
    func testRemoveFromLibraryUndoAlsoLands() {
        let store = makeStore()
        let track = makeTrack("1", title: "A")
        store.addToLibrary(track)

        attach(store)
        step { store.removeFromLibrary(track) }
        manager.undo()
        store.flushNow()

        let reopened = makeStore()
        XCTAssertEqual(reopened.libraryTracks.map(\.id), ["1"])
    }

    func testRemoveAlbumFromLibraryUndoRestoresAlbumAndItsTracks() {
        let store = makeStore()
        let album = makeAlbum()
        let tracks = [makeTrack("1", title: "A"), makeTrack("2", title: "B")]
        store.addAlbumToLibrary(album, tracks: tracks)
        XCTAssertEqual(store.libraryTracks.map(\.title), ["A", "B"])

        attach(store)
        step { store.removeAlbumFromLibrary(album, tracks: tracks) }
        XCTAssertTrue(store.libraryAlbums.isEmpty)
        XCTAssertTrue(store.libraryTracks.isEmpty)

        manager.undo()
        XCTAssertEqual(store.libraryAlbums.map(\.id), ["album"])
        XCTAssertEqual(store.libraryTracks.map(\.title), ["A", "B"])

        manager.redo()
        XCTAssertTrue(store.libraryAlbums.isEmpty)
        XCTAssertTrue(store.libraryTracks.isEmpty)
    }

    // MARK: - 心水与评分

    func testFavoriteUndoGoesBothWays() {
        let store = makeStore()
        let track = makeTrack("1")

        attach(store)
        step { store.toggleFavorite(track) }
        XCTAssertTrue(store.isFavorite(track))
        XCTAssertEqual(manager.undoActionName, "心水")

        manager.undo()
        XCTAssertFalse(store.isFavorite(track))

        manager.redo()
        XCTAssertTrue(store.isFavorite(track))
    }

    /// 撤销记的是「回到哪个状态」而不是「再取反一次」。
    ///
    /// 场景：注册之后用户自己又把它点了回去（这一下没进撤销栈）。取反那条会把它
    /// **推过头**变回心水，置位那条是一次干净的空操作。
    func testFavoriteUndoIsAStateNotAToggle() {
        let store = makeStore()
        let track = makeTrack("1")

        attach(store)
        step { store.toggleFavorite(track) }
        XCTAssertTrue(store.isFavorite(track))

        manager.disableUndoRegistration()
        store.toggleFavorite(track)
        manager.enableUndoRegistration()
        XCTAssertFalse(store.isFavorite(track))

        manager.undo()
        XCTAssertFalse(store.isFavorite(track), "已经是目标状态了，撤销该什么都不做")
    }

    func testRatingUndoRestoresThePreviousStar() {
        let store = makeStore()
        store.setRating(3, for: "1")

        attach(store)
        step { store.setRating(5, for: "1") }
        XCTAssertEqual(store.rating(for: "1"), 5)
        XCTAssertEqual(manager.undoActionName, "评分")

        manager.undo()
        XCTAssertEqual(store.rating(for: "1"), 3)

        manager.redo()
        XCTAssertEqual(store.rating(for: "1"), 5)
    }

    /// 再点一次当前星级 ＝ 清空（Music 同）；撤销把它写回去。
    func testRatingUndoAfterClearing() {
        let store = makeStore()
        store.setRating(4, for: "1")

        attach(store)
        step { store.setRating(4, for: "1") }
        XCTAssertEqual(store.rating(for: "1"), 0)

        manager.undo()
        XCTAssertEqual(store.rating(for: "1"), 4)
    }

    // MARK: - 批量与「没有登记处」

    /// 菜单里的批量心水一次能改几十首，撤销只该是**一步**。
    func testBatchFavoriteIsASingleUndoStep() {
        let store = makeStore()
        let tracks = (1...3).map { makeTrack("\($0)") }

        attach(store)
        store.withUndoGrouping("心水") {
            for track in tracks { store.toggleFavorite(track) }
        }
        XCTAssertEqual(store.favoriteTracks.count, 3)
        XCTAssertEqual(manager.undoActionName, "心水")

        manager.undo()
        XCTAssertTrue(store.favoriteTracks.isEmpty)
        XCTAssertFalse(manager.canUndo, "三首只该留一步撤销")
    }

    /// 没有登记处时（测试默认、迷你窗那种没有窗口委托的场合）写入路径原样，
    /// 一条都不注册，也不许崩。
    func testWritesAreUnchangedWithoutAnUndoManager() {
        let store = makeStore()
        let playlist = store.createPlaylist(name: "A")
        let track = makeTrack("1")
        store.addToLibrary(track)

        store.deletePlaylist(id: playlist.id)
        store.toggleFavorite(track)
        store.setRating(3, for: track.id)
        store.removeFromLibrary(track)

        XCTAssertTrue(store.playlists.isEmpty)
        XCTAssertFalse(store.isInLibrary(track))
        XCTAssertFalse(manager.canUndo)
    }

    // MARK: - 批量退库

    /// 批量退库（`removeFromLibrary(_: [Track])`）与逐首调**逐字同解**：删完、撤销、重做、
    /// 重开读盘，四个时刻的曲目 / 专辑 / 心水 / 列表都一样，**连撤销之后的数组顺序也一样**。
    ///
    /// 场景故意把几条容易走偏的路都铺上：不带 albumId、靠名字归碟的曲目（空碟检查的
    /// `fallbackKey` 那一路）、一张本来就空的占位碟（第一首删完时就被摘）、
    /// 两张在这一批的不同位置被删空的碟、给的顺序与库里顺序不一样、重复给的与不在库里的。
    func testBatchRemoveMatchesRemovingOneByOne() throws {
        set(playlistSync: true, favoriteSync: true)
        func album(_ id: String, _ name: String) -> Album {
            Album(id: id, kind: .qq, name: name, artistName: "某人", artistId: nil,
                  artworkURL: nil, publishDate: nil, trackCount: 2, description: nil)
        }
        func track(_ id: String, album: String, albumId: String?) -> Track {
            Track(id: id, kind: .qq, title: "歌\(id)", artistName: "某人", artistId: nil,
                  albumName: album, albumId: albumId, artworkURL: nil, duration: 200)
        }
        let a = album("A", "碟A"), b = album("B", "碟B"), c = album("C", "碟C")
        let empty = album("E", "空碟")
        let a1 = track("a1", album: "碟A", albumId: "A")
        let a2 = track("a2", album: "碟A", albumId: nil)  // 靠名字归碟
        let b1 = track("b1", album: "碟B", albumId: "B")
        let c1 = track("c1", album: "碟C", albumId: "C")
        let c2 = track("c2", album: "碟C", albumId: nil)
        let stray = track("x", album: "", albumId: nil)

        func build(_ directory: URL) -> LibraryStore {
            let store = LibraryStore(directory: directory)
            store.addAlbumToLibrary(empty, tracks: [])
            store.addAlbumToLibrary(a, tracks: [a1])
            store.addAlbumToLibrary(b, tracks: [b1])
            store.addAlbumToLibrary(c, tracks: [c1])
            for extra in [a2, c2, stray] { store.addToLibrary(extra) }
            let playlist = store.createPlaylist(name: "L")
            store.addTracks([c1, a2, b1], toPlaylist: playlist.id)
            store.toggleFavorite(b1)
            store.toggleFavorite(c2)
            store.toggleFavorite(a2)
            return store
        }
        // 给的顺序与库里顺序不同；a1 重复给、`ghost` 不在库里。
        let ghost = track("ghost", album: "碟A", albumId: "A")
        let picked = [c2, a1, b1, ghost, a2, a1, c1]

        let loopDirectory = directory.appendingPathComponent("loop", isDirectory: true)
        let batchDirectory = directory.appendingPathComponent("batch", isDirectory: true)
        let looped = build(loopDirectory)
        let batched = build(batchDirectory)

        func snapshot(_ store: LibraryStore) -> [[String]] {
            [store.libraryTracks.map(\.id), store.libraryAlbums.map(\.id),
             store.favoriteTracks.map(\.id), store.playlists.flatMap { $0.tracks.map(\.id) }]
        }
        XCTAssertEqual(snapshot(looped), snapshot(batched))

        let loopManager = UndoManager()
        loopManager.groupsByEvent = false
        looped.undoManager = loopManager
        loopManager.beginUndoGrouping()
        looped.withUndoGrouping("从资料库中删除") {
            for track in picked { looped.removeFromLibrary(track) }
        }
        loopManager.endUndoGrouping()

        attach(batched)
        step { batched.withUndoGrouping("从资料库中删除") { batched.removeFromLibrary(picked) } }

        XCTAssertEqual(snapshot(batched), snapshot(looped), "删完")
        XCTAssertEqual(batched.libraryAlbums.map(\.id), [], "四张碟都该被摘：A/B/C 删空、E 本来就空")
        XCTAssertEqual(batched.libraryTracks.map(\.id), ["x"])

        loopManager.undo()
        manager.undo()
        XCTAssertEqual(snapshot(batched), snapshot(looped), "撤销之后，连数组顺序都一样")

        loopManager.redo()
        manager.redo()
        XCTAssertEqual(snapshot(batched), snapshot(looped), "重做")

        loopManager.undo()
        manager.undo()
        looped.flushNow()
        batched.flushNow()
        XCTAssertEqual(snapshot(LibraryStore(directory: batchDirectory)),
                       snapshot(LibraryStore(directory: loopDirectory)), "落盘那份也一样")
    }
}
