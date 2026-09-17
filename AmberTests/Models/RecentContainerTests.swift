import Combine
import XCTest
@testable import Amber

/// 「最近播放」的容器台账（`RecentContainer` + `LibraryStore.recentContainers`）：
/// 歌 → 格子的映射在**记账那一刻**就定下来，展示层不再按 `albumId` 反推分组。
///
/// 两处宿主环境的坑照 `LocalFileMissingTests` 的两条防线躲开：
/// - `LibraryStore` 注入临时目录，绝不碰真实的`~/Library/Application Support/Amber/`；
/// - 记账受「使用听歌历史记录」开关管，而那条开关读的是**真实**偏好（测试宿主就是
///   Amber 本身），所以整份存下来、跑完原样还回去。
@MainActor
final class RecentContainerTests: XCTestCase {

    private var directory: URL!
    private var savedValues: SettingsValues!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentContainerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        savedValues = AppSettings.shared.values
        AppSettings.shared.values.useListeningHistory = true
    }

    override func tearDownWithError() throws {
        AppSettings.shared.values = savedValues
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> LibraryStore { LibraryStore(directory: directory) }

    private func makeTrack(_ suffix: String, albumId: String? = "ne:album:1",
                           albumName: String = "某碟") -> Track {
        Track(id: "ne:\(suffix)", kind: .netease, title: "曲 \(suffix)",
              artistName: "某人", artistId: "ne:artist:1", albumName: albumName,
              albumId: albumId, artworkURL: nil, duration: 200)
    }

    private func makePlaylist(_ id: String = "ne:playlist:9") -> Playlist {
        Playlist(id: id, kind: .netease, name: "某单", creatorName: "某人")
    }

    // MARK: - 映射表：source 说了算，说不出才看这首歌自己

    /// 需求本体：在歌单里听的收成歌单卡，**压过**这首歌自己的`albumId`。
    func testPlaylistSourceBeatsAlbumID() {
        let playlist = makePlaylist()
        let container = RecentContainer.resolve(
            track: makeTrack("1"),
            source: .init(title: playlist.name, route: .playlist(playlist)))
        XCTAssertEqual(container, .playlist(playlist))
        XCTAssertEqual(container.id, "playlist:ne:playlist:9")
    }

    /// 资料库歌单只落 id：名字/封面/还在不在都留给展示层实时解析。
    func testLibraryPlaylistSourceKeepsOnlyID() {
        let container = RecentContainer.resolve(
            track: makeTrack("1"),
            source: .init(title: "我的单", route: .libraryPlaylist(id: "local:ABC")))
        XCTAssertEqual(container, .libraryPlaylist(id: "local:ABC"))
        XCTAssertEqual(container.id, "playlist:local:ABC")
    }

    /// 心水歌曲那一页：它是虚拟列表，只认 `id == "favorites"` 这一个落点。
    func testFavoritesSourceResolvesToFavorites() {
        let list = LocalTrackList(id: "favorites", title: "心水歌曲", tracks: [])
        let container = RecentContainer.resolve(
            track: makeTrack("1"),
            source: .init(title: "心水歌曲", route: .localTracks(list)))
        XCTAssertEqual(container, .favorites)
    }

    /// 别的本地列表（「音乐回忆」那种）不是容器，回落按这首歌自己收。
    func testOtherLocalTrackListFallsBack() {
        let list = LocalTrackList(id: "memories", title: "上个月的热门音乐", tracks: [])
        let container = RecentContainer.resolve(
            track: makeTrack("1"),
            source: .init(title: "上个月的热门音乐", route: .localTracks(list)))
        XCTAssertEqual(container.id, "album:ne:album:1")
    }

    func testArtistSourceResolvesToArtist() {
        let artist = Artist(id: "ne:artist:7", kind: .netease, name: "某人",
                            avatarURL: "https://x/a.jpg", description: nil)
        let container = RecentContainer.resolve(
            track: makeTrack("1"), source: .init(title: artist.name, route: .artist(artist)))
        XCTAssertEqual(container, .artist(id: "ne:artist:7", kind: .netease,
                                          name: "某人", avatarURL: "https://x/a.jpg"))
    }

    /// 资料库派生艺人（`library-artist:` 前缀）没有艺人页可去，收成艺人卡点了没处落，回落。
    func testLibraryDerivedArtistFallsBackToAlbum() {
        let artist = Artist(id: "\(Artist.libraryIDPrefix)某人", kind: .netease,
                            name: "某人", avatarURL: nil, description: nil)
        let container = RecentContainer.resolve(
            track: makeTrack("1"), source: .init(title: "某人", route: .artist(artist)))
        XCTAssertEqual(container.id, "album:ne:album:1")
    }

    /// 只有名字、没有落点的 source（专辑页起播也走这条回落）：按这首歌自己收。
    func testSourceWithoutRouteFallsBack() {
        let container = RecentContainer.resolve(track: makeTrack("1"),
                                                source: .init(title: "某碟"))
        XCTAssertEqual(container.id, "album:ne:album:1")
    }

    /// 没有 source（单点播的一首歌、自动连播续上的那几首）：照旧收成它的专辑卡。
    func testNoSourceFallsBackToAlbum() {
        let container = RecentContainer.resolve(track: makeTrack("1"), source: nil)
        guard case .album(let album) = container else { return XCTFail("该落成专辑") }
        XCTAssertEqual(album.id, "ne:album:1")
        XCTAssertEqual(album.name, "某碟")
    }

    /// 连专辑都没有的散曲各占一格。
    func testTrackWithoutAlbumResolvesToTrack() {
        let track = makeTrack("1", albumId: nil, albumName: "")
        XCTAssertEqual(RecentContainer.resolve(track: track, source: nil), .track(track))
    }

    /// 网易播客单集的 `albumId` 是电台节目本身，落成歌单（判定复用`Route.album(of:)`）。
    func testDJRadioAlbumIDResolvesToPlaylist() {
        let track = makeTrack("1", albumId: "ne:djradio:123", albumName: "某节目")
        let container = RecentContainer.resolve(track: track, source: nil)
        guard case .playlist(let playlist) = container else { return XCTFail("该落成歌单") }
        XCTAssertEqual(playlist.id, "ne:djradio:123")
        XCTAssertEqual(playlist.name, "某节目")
    }

    // MARK: - upsert：同一个格子只占一格，最近的在前

    /// 在一份歌单里连听 20 首：台账仍旧只有那一张卡。
    func testSameContainerStaysSingleEntry() {
        let store = makeStore()
        let playlist = makePlaylist()
        for index in 0..<20 {
            store.noteStarted(makeTrack("\(index)"), container: .playlist(playlist))
        }
        XCTAssertEqual(store.recentContainers.count, 1)
        XCTAssertEqual(store.recentContainers.first, .playlist(playlist))
        // 逐曲历史是另一个粒度，20 首照旧各记一条。
        XCTAssertEqual(store.recentTracks.count, 20)
    }

    /// 同一份歌单的**两种身份**要收成同一格：资料库那份歌单页起播给`.libraryPlaylist`，
    /// 目录页（以及 `playLibraryPlaylist` 转手给`playPlaylist`）给`.playlist`，
    /// 而 `LibraryPlaylist.from` 沿用的就是音源歌单的 id。不认这一条，
    /// 「我喜欢」这种两头都能进的歌单会在货架上并排摆两张一模一样的卡。
    func testLibraryAndCatalogPlaylistShareOneEntry() {
        let store = makeStore()
        let playlist = makePlaylist("qq:2667748991")
        store.noteStarted(makeTrack("1"), container: .playlist(playlist))
        store.noteStarted(makeTrack("2"), container: .album(Album(
            id: "qq:album", kind: .qq, name: "别的碟", artistName: "别人", artistId: nil,
            artworkURL: nil, publishDate: nil, trackCount: 0, description: nil)))
        store.noteStarted(makeTrack("3"), container: .libraryPlaylist(id: "qq:2667748991"))

        XCTAssertEqual(store.recentContainers.count, 2)
        XCTAssertEqual(store.recentContainers.first, .libraryPlaylist(id: "qq:2667748991"))
        XCTAssertFalse(store.recentContainers.contains(.playlist(playlist)),
                       "后记的那一种身份顶掉前一种，不该两种并存")
    }

    /// 同一格里接着听**一声通知都不发**：主页目录页订阅着这份台账，
    /// 每发一次就重灌一遍整页快照（悬浮态被清、货架横向位置回到最左）。
    func testSameContainerDoesNotRepublish() {
        let store = makeStore()
        let playlist = makePlaylist()
        var emissions = 0
        let token = store.$recentContainers.dropFirst().sink { _ in emissions += 1 }
        defer { token.cancel() }

        store.noteStarted(makeTrack("1"), container: .playlist(playlist))
        XCTAssertEqual(emissions, 1, "第一首把这张卡记进台账，该发一声")
        for index in 2...10 {
            store.noteStarted(makeTrack("\(index)"), container: .playlist(playlist))
        }
        XCTAssertEqual(emissions, 1, "同一份歌单接着听，台账没变，不该再发")

        store.noteStarted(makeTrack("11"), container: .favorites)
        XCTAssertEqual(emissions, 2, "换了一格才该再发一声")
    }

    /// 穿插了别的容器之后再听回来：那张卡置顶，总数不增。
    func testRepeatedContainerMovesToFrontWithoutGrowing() {
        let store = makeStore()
        let playlist = makePlaylist()
        store.noteStarted(makeTrack("1"), container: .playlist(playlist))
        store.noteStarted(makeTrack("2"), container: .favorites)
        store.noteStarted(makeTrack("3"), container: .libraryPlaylist(id: "local:A"))
        XCTAssertEqual(store.recentContainers.count, 3)

        store.noteStarted(makeTrack("4"), container: .playlist(playlist))
        XCTAssertEqual(store.recentContainers.count, 3)
        XCTAssertEqual(store.recentContainers.first, .playlist(playlist))
    }

    /// 上限 50（逐曲历史那份是 200，两个粒度各有各的窗口）。
    func testContainerListIsCappedAtFifty() {
        let store = makeStore()
        for index in 0..<60 {
            store.noteStarted(makeTrack("\(index)"),
                              container: .libraryPlaylist(id: "local:\(index)"))
        }
        XCTAssertEqual(store.recentContainers.count, LibraryStore.recentContainerLimit)
        XCTAssertEqual(store.recentContainers.first, .libraryPlaylist(id: "local:59"))
        XCTAssertEqual(store.recentContainers.last, .libraryPlaylist(id: "local:10"))
    }

    // MARK: - 「使用听歌历史记录」关掉

    /// 开关关掉之后两张表都不动，已经记下的原样保留（同 `recentTracks` 的口径）。
    func testDisabledHistoryRecordsNothingAndKeepsWhatsThere() {
        let store = makeStore()
        store.noteStarted(makeTrack("1"), container: .favorites)

        AppSettings.shared.values.useListeningHistory = false
        store.noteStarted(makeTrack("2"), container: .libraryPlaylist(id: "local:A"))

        XCTAssertEqual(store.recentContainers, [.favorites])
        XCTAssertEqual(store.recentTracks.count, 1)
    }

    // MARK: - 迁移：旧存档回灌，新存档不回灌
    //
    // 这两条用例现在钉的是 `AmberDatabaseMigration`：写一份旧 JSON 进临时目录、
    // 开一个 store（构造时会把迁移跑到），断言台账是什么样。**fixture 内容一律不改。**

    /// 旧存档只有逐曲历史（没有 `recentContainers` 这个键）：按老规则回灌成专辑卡 / 散曲卡。
    ///
    /// **这条规则的家搬了，断言一个字没改。** 从前它守的是「`Storage.recentContainers`
    /// 这个可选字段是 nil」，现在守的是 `AmberDatabaseMigration`——旧 JSON 里没有这个键
    /// 就回灌一份写进 `recent_container` 表。fixture 的内容一个字节都没动：
    /// 它本来就是一份「旧存档」，只是读它的人换了。守迁移器比守一个可选字段值钱得多，
    /// 因为迁移只有一次机会。
    func testLegacyArchiveIsBackfilled() throws {
        // 同一张碟的两首 + 一首散曲：老规则是「albumId 去重、没有专辑的各成一格」。
        try writeArchive(LegacyArchive(recents: [
            makeTrack("1"), makeTrack("2"),
            makeTrack("3", albumId: nil, albumName: ""),
        ]))
        let store = makeStore()
        XCTAssertEqual(store.recentContainers.map(\.id),
                       ["album:ne:album:1", "track:ne:3"])
    }

    /// 新存档里台账确实是空的（用户刚清空 / 一直没听）：**不**回灌。
    ///
    /// 与上一条是一对，分的是「键根本不在」与「键在、值是空数组」。
    /// `LegacyLibraryArchive.recentContainers` 做成可选就是为了分出这两种情况——
    /// 压成同一种处置的话，用户清空一次「最近播放」，下次启动它就自己长回来了。
    func testEmptyContainersInArchiveAreNotBackfilled() throws {
        try writeArchive(CurrentArchive(recents: [makeTrack("1")], recentContainers: []))
        XCTAssertTrue(makeStore().recentContainers.isEmpty)
    }

    // MARK: - 经 recent_container 表往返

    /// 六种 case 全走一遍 `recent_container` 表的往返。
    ///
    /// 走的是 `RecentContainer.storageRow` / `.make(kind:refID:payload:track:)` 那一对
    /// （迁移器写进去用的也是同一对）。顺带钉住两件事：`.playlist` / `.album` / `.artist`
    /// 那几个**故意是快照**的 case 的 payload 编码不变；`.track` 只落 id、
    /// 曲目从 `track` 表取回来——哪怕那首散曲不在任何一张关系表里。
    func testContainersSurviveRoundTrip() {
        let track = makeTrack("9", albumId: nil, albumName: "")
        let containers: [RecentContainer] = [
            .track(track),
            .artist(id: "ne:artist:7", kind: .netease, name: "某人", avatarURL: "https://x/a.jpg"),
            .favorites,
            .album(Album(id: "ne:album:1", kind: .netease, name: "某碟", artistName: "某人",
                         artistId: nil, artworkURL: nil, publishDate: nil,
                         trackCount: 10, description: nil)),
            .libraryPlaylist(id: "local:A"),
            .playlist(makePlaylist()),
        ]
        let store = makeStore()
        // 倒着记，台账里就是上面这个顺序（最近的在前）。
        for (index, container) in containers.reversed().enumerated() {
            store.noteStarted(makeTrack("r\(index)"), container: container)
        }
        store.flushNow()

        XCTAssertEqual(makeStore().recentContainers, containers)
    }

    // MARK: - 存档助手

    /// 旧存档：`Storage` 里非可选的那两个键得有，别的一概没有。
    private struct LegacyArchive: Encodable {
        var favorites: [Track] = []
        var recents: [Track]
    }

    private struct CurrentArchive: Encodable {
        var favorites: [Track] = []
        var recents: [Track]
        var recentContainers: [RecentContainer]
    }

    private func writeArchive(_ archive: some Encodable) throws {
        try JSONEncoder().encode(archive)
            .write(to: directory.appendingPathComponent("library.json"), options: .atomic)
    }
}
