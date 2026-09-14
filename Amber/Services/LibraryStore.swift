import AppKit
import Foundation

/// 本地资料库：资料库歌曲与专辑 + 心水 + 最近播放，JSON 持久化到 Application Support。
///
/// Music.app 把「添加到资料库」与「心水」当成两件事：
/// 前者决定专辑页用哪种形态（有星级 / 只有加号），后者只是行首那颗星。
@MainActor
final class LibraryStore: ObservableObject {

    /// 已添加到资料库的歌曲，最新添加的在前（「最近添加」直接用这个顺序）。
    @Published private(set) var libraryTracks: [Track] = []
    /// 已添加到资料库的专辑，最新添加的在前。
    @Published private(set) var libraryAlbums: [Album] = []
    @Published private(set) var favoriteTracks: [Track] = []
    @Published private(set) var recentTracks: [Track] = []
    /// 已喜爱的专辑 id（Music.app 在专辑标题后显示 ★）
    @Published private(set) var favoriteAlbumIDs: Set<String> = []
    /// 已收藏的艺人 id（目录艺人页 hero 上那枚 ★，参考图 design-ref/ui-spec/pages/catalog-artist.png）
    @Published private(set) var favoriteArtistIDs: Set<String> = []
    /// 评分表：键为曲目或专辑 id，值 1...5。Music.app 的星级同样是本地资料库属性。
    @Published private(set) var ratings: [String: Int] = [:]
    /// 播放次数：键为曲目 id。资料库「歌曲」表有「播放次数」一列，0 次显示空白。
    @Published private(set) var playCounts: [String: Int] = [:]
    /// 跳过次数：一首歌没放完就被切走算一次（Music 的「跳过次数」同义）。
    @Published private(set) var skipCounts: [String: Int] = [:]
    /// 「添加日期 / 上次播放时间 / 上次跳过时间」三列的时间戳，键为曲目 id。
    @Published private(set) var addedAt: [String: Date] = [:]
    @Published private(set) var lastPlayedAt: [String: Date] = [:]
    @Published private(set) var lastSkippedAt: [String: Date] = [:]
    /// 专辑的添加时间，键为专辑 id。资料库「最近添加」按它分「昨天 / 本周 / …」段。
    /// 旧存档没有这个键：回落取这张碟里曲目 addedAt 的最大值。
    @Published private(set) var albumAddedAt: [String: Date] = [:]
    /// 资料库里的播放列表：自建的、从目录加进来的、账号同步来的，最新在前。
    @Published private(set) var playlists: [LibraryPlaylist] = []
    /// 用户主动从资料库里删掉的账号歌单 id：下次同步不要再把它们加回来。
    private var dismissedAccountPlaylistIDs: Set<String> = []

    /// 曲目被移出资料库时的旁路通知，参数是这一批曲目 id。
    /// 由 AppState 接到 `DownloadStore`：Music 里歌一从资料库删掉，本地那份下载也一起没了。
    /// 做成回调而不是让每个删除入口自己调，是因为删除入口有好几处（单曲/整张碟/表格），
    /// 少接一处就会留下一个再也没人认领的音频文件。
    var onTracksRemoved: (([String]) -> Void)?

    /// 曲目**进**资料库时的旁路通知，与 `onTracksRemoved` 对称。
    /// 由 AppState 接到 `DownloadStore`：设置 › 通用 ›「自动下载」开着时进库即落地。
    /// 同样做成回调——入库入口有单曲 / 整张碟 / 歌单同步（开了「添加与删除播放列表歌曲」）
    /// 好几处，逐处调必漏。
    var onTracksAdded: (([Track]) -> Void)?

    /// 与 libraryTracks 同步的 id 集合，供逐行判定用（列表里每行都要查一次）。
    private var libraryTrackIDs: Set<String> = []
    private var libraryAlbumIDs: Set<String> = []
    /// 与 favoriteTracks 同步的 id 集合：`isFavorite` 是表格排序比较器里逐行调的。
    private var favoriteTrackIDs: Set<String> = []
    /// 设置 › 通用 ›「歌曲列表复选框」那一列里**取消勾选**的曲目 id。
    ///
    /// 记「没勾的」而不是「勾了的」：Music/iTunes 里新歌一进来就是勾着的，
    /// 记正集的话每加一首歌都得同步补一条，漏一处就是「新歌默认不放」。
    /// 未勾选的歌自动顺播/随机时跳过，双击照放（见 `PlayerController.nextStep`）。
    ///
    /// 不是 `@Published`：它逐行被`isChecked` 查（与`favoriteTrackIDs` 同性质），
    /// 而改动是用户级动作，改完由 `setChecked` 手动发一次`objectWillChange`——
    /// 每行一个 `@Published` 字典只会让整页在滚动时白重画。
    private var uncheckedTrackIDs: Set<String> = []
    /// 已经对音源说过「减少推荐」的曲目 id 与艺人 id。
    ///
    /// **这只是本地镜像，不是真值**：口味写在音源账号里（QQ 的不喜欢名单、
    /// 网易云的「不感兴趣」）。菜单要在弹开的那一瞬决定摆「减少推荐」还是
    /// 「撤销减少推荐」，为这个去打一条网络请求是不可能的，所以记在本地。
    ///
    /// 已知的三处不准，都是明知的取舍：换账号后仍留着上一位的记号；在音源自家 App
    /// 里点的不喜欢这边不知道；网易云连读名单的接口都没有，对不回来。
    /// 代价很小——写请求本身幂等，多说一遍也只是再说一遍。
    /// 与 `uncheckedTrackIDs` 同样不是`@Published`：改动是用户级动作，改完手动发一声。
    private var suggestLessTrackIDs: Set<String> = []
    private var suggestLessArtistIDs: Set<String> = []
    /// 本地文件已经不在 `localPath` 指的位置上的曲目 id（照 Music.app：条目留着，只打标记）。
    ///
    /// **这份集合是「已经发现的」，不是「全部的」**：`[实测]` `library 规格`
    /// §10.1 的判据是**懒判定**，批次 45 已由实测坐实——失联弹窗那个函数
    /// 整个原版 7 个调用方，唯一具名的是
    /// `-[AppStartPlaybackManager startPlayingPlaylistItem:allowUserInteraction:…]`，
    /// 判定挂在**播放（使用）路径**上，全库没有后台扫描；触发文案说的也正是「因为找不到…
    /// 所以无法**使用**该歌曲」（代码写 res 500 idx 56，运行期按 kind 换到歌曲那张 501 表，
    /// §10.10.2）。所以这里只由两处写：取流取不到文件时 `markFileMissing`，
    /// 以及用户主动发起的批量查找 `missingLocalTracks()`。
    ///
    /// **故意不落盘**，`Storage` 里也不加这个键：文件在不在是磁盘此刻的事实，不是资料库属性。
    /// 存进 library.json 只会带出「上次退出时盘没插、这次启动盘插着却还标着感叹号」这种
    /// 陈旧假象。
    ///
    /// 与 `uncheckedTrackIDs` 同性质地**不是**`@Published`：歌曲表每一行都要查一次
    /// `isFileMissing`，做成`@Published` 只会让整页在滚动时白重画；改动自己手动发一声。
    private var missingFileTrackIDs: Set<String> = []
    /// libraryAlbums 的两张查表：按 id、按「归位键」。`album(for:)` 被
    /// 「类型/专辑艺人/年份…」那几列的比较器逐行调用，线性扫描会把排序拖成 O(n²)。
    ///
    /// 第二张表的键**不是专辑名**：同名碟在资料库里是常态（本地导入的那张与音源那张、
    /// 不同艺人的同名碟），只按名字建表的话第二张碟整个查不到，第一张碟还会被
    /// 别人的曲目认领。键改成 `fallbackKey`（名 + 艺人 + 音源 + 本地性），
    /// 撞键的仍旧取数组里靠前的那张——同一把键下的两张碟，界面上本来就分不出。
    private var albumsByID: [String: Album] = [:]
    private var albumsByFallbackKey: [String: Album] = [:]

    private struct Storage: Codable {
        var favorites: [Track] = []
        var recents: [Track] = []
        /// 后加的字段：旧文件里没有，解码时用 decodeIfPresent 回落到空值。
        var favoriteAlbums: [String]?
        /// 同上，后加的可选字段：旧文件里没有 `favoriteArtists` 键，解码回落到 nil。
        var favoriteArtists: [String]?
        var ratings: [String: Int]?
        var libraryTracks: [Track]?
        var libraryAlbums: [Album]?
        var playCounts: [String: Int]?
        var skipCounts: [String: Int]?
        var addedAt: [String: Date]?
        var lastPlayedAt: [String: Date]?
        var lastSkippedAt: [String: Date]?
        var albumAddedAt: [String: Date]?
        var playlists: [LibraryPlaylist]?
        var dismissedAccountPlaylists: [String]?
        /// 后加的可选字段：旧文件里没有这个键，解码回落到 nil ＝ 全部勾选。
        var uncheckedTracks: [String]?
        /// 同上，后加的可选字段：「减少推荐」的本地镜像（见 `suggestLessTrackIDs`）。
        var suggestLessTracks: [String]?
        var suggestLessArtists: [String]?
    }

    private let fileURL: URL
    /// 待落盘的防抖任务：每次改动重新计时，到期才真写一次。
    private var pendingSave: Task<Void, Never>?
    private var terminationObserver: (any NSObjectProtocol)?
    /// 写盘防抖时长。连点星级、整张碟入库这种一串连续改动会并成一次写；
    /// 半秒短到「改完随手退出」几乎必然已经落盘，真没落也有 willTerminate 兜底。
    private static let saveDebounce: UInt64 = 500_000_000
    /// 串行写盘队列：防抖到期的异步写与 flushNow 的同步写共用一条，
    /// 避免旧快照后到、把新数据盖回去。
    private static let writeQueue = DispatchQueue(label: "Amber.LibraryStore.write", qos: .utility)

    /// `directory` 供测试注入临时目录；默认落`~/Library/Application Support/Amber/`。
    init(directory: URL? = nil) {
        let support = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!.appendingPathComponent("Amber", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("library.json")
        load()
        // 防抖写盘的兜底：退出前把还没到期的那次改动同步落下去。
        // 通知在主线程投递，queue 传 nil 保证同步执行（走 .main 队列会排到退出之后）。
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushNow() }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: - 资料库

    func isInLibrary(_ track: Track) -> Bool { libraryTrackIDs.contains(track.id) }

    func addToLibrary(_ track: Track) {
        guard insert(track) else { return }
        onTracksAdded?([track])
        save()
    }

    /// 只落数据，不落盘也不发通知。批量入库（整张碟、歌单同步）先各自收齐再一次性
    /// `onTracksAdded`：自动下载那头收到一条 N 首的通知才好按并发闸门排队。
    private func insert(_ track: Track) -> Bool {
        guard !libraryTrackIDs.contains(track.id) else { return false }
        libraryTrackIDs.insert(track.id)
        libraryTracks.insert(track, at: 0)
        addedAt[track.id] = Date()
        return true
    }

    func removeFromLibrary(_ track: Track) {
        guard libraryTrackIDs.remove(track.id) != nil else { return }
        libraryTracks.removeAll { $0.id == track.id }
        pruneAfterLibraryRemoval([track.id])
        pruneEmptyAlbums()
        onTracksRemoved?([track.id])
        save()
    }

    func toggleLibrary(_ track: Track) {
        isInLibrary(track) ? removeFromLibrary(track) : addToLibrary(track)
    }

    func isAlbumInLibrary(_ album: Album) -> Bool { libraryAlbumIDs.contains(album.id) }

    /// 加专辑等于把整张碟的歌一并入库——与 Music.app 的「添加到资料库」一致。
    func addAlbumToLibrary(_ album: Album, tracks: [Track]) {
        if !libraryAlbumIDs.contains(album.id) {
            libraryAlbumIDs.insert(album.id)
            libraryAlbums.insert(album, at: 0)
            rebuildAlbumIndex()
            albumAddedAt[album.id] = Date()
        } else {
            if albumAddedAt[album.id] == nil { albumAddedAt[album.id] = Date() }
            // 已经在库里的那张只补封面，别整条覆盖（用户改过的评分、喜爱都挂在原条目上）。
            // 本地导入常常是「先导了一首没封面的，回头又导了同碟里带内嵌图的那首」，
            // 补这一下，专辑页那格才不会一直空着。
            if let artwork = album.artworkURL, !artwork.isEmpty,
               let index = libraryAlbums.firstIndex(where: { $0.id == album.id }),
               libraryAlbums[index].artworkURL?.isEmpty != false {
                libraryAlbums[index] = Self.copy(libraryAlbums[index], artworkURL: artwork)
                rebuildAlbumIndex()
            }
        }
        // 逐首插到最前，倒序遍历后整张碟在「最近添加」里保持原曲序。
        var added: [Track] = []
        for track in tracks.reversed() {
            let stampedTrack = stamped(track, with: album)
            if insert(stampedTrack) { added.append(stampedTrack) }
        }
        if !added.isEmpty { onTracksAdded?(added.reversed()) }
        save()
    }

    /// `Album.artworkURL` 是`let`，换封面只能整条重造一份。
    private static func copy(_ album: Album, artworkURL: String?) -> Album {
        Album(id: album.id, kind: album.kind, name: album.name, artistName: album.artistName,
              artistId: album.artistId, artworkURL: artworkURL, publishDate: album.publishDate,
              trackCount: album.trackCount, description: album.description,
              genre: album.genre, albumType: album.albumType)
    }

    /// 音源的专辑曲目列表常常不带专辑节点，入库时用所属专辑补齐，
    /// 免得资料库「歌曲」表的「专辑 / 类型」两列永远空着。
    private func stamped(_ track: Track, with album: Album) -> Track {
        var result = track
        if result.albumName.isEmpty { result.albumName = album.name }
        if result.albumId == nil { result.albumId = album.id }
        return result
    }

    /// 移出专辑时连带移出这张碟里的歌，避免资料库留下无主曲目。
    func removeAlbumFromLibrary(_ album: Album, tracks: [Track]) {
        libraryAlbumIDs.remove(album.id)
        libraryAlbums.removeAll { $0.id == album.id }
        rebuildAlbumIndex()
        albumAddedAt.removeValue(forKey: album.id)
        let ids = Set(tracks.map(\.id))
        libraryTrackIDs.subtract(ids)
        libraryTracks.removeAll { ids.contains($0.id) }
        pruneAfterLibraryRemoval(ids)
        onTracksRemoved?(Array(ids))
        save()
    }

    /// 设置 › 高级那两条「添加与删除…」开关的**删除侧**：歌从资料库出去时，
    /// 顺手从本地播放列表 / 心水里也清掉。
    ///
    /// 只清 `.local` 播放列表：音源歌单与账号歌单是只读镜像，本地删一首下次同步就回来了，
    /// 清了反而是「看起来生效、其实没有」。开关关着时两边互不相干（Music 同）。
    private func pruneAfterLibraryRemoval(_ ids: Set<String>) {
        // 勾选状态不受那两条开关管：歌都不在资料库里了，留着「它没勾」这条记录
        // 只会在同一首歌被重新加进来时把上次的取消勾选带回来。
        uncheckedTrackIDs.subtract(ids)
        let values = AppSettings.shared.values
        if values.syncPlaylistSongsWithLibrary {
            for index in playlists.indices where playlists[index].origin == .local {
                playlists[index].tracks.removeAll { ids.contains($0.id) }
            }
        }
        if values.syncFavoriteSongsWithLibrary {
            favoriteTracks.removeAll { ids.contains($0.id) }
            favoriteTrackIDs.subtract(ids)
        }
    }

    /// 歌移出资料库后，若所属专辑在资料库里已经没有任何歌了，连带把这张空碟也移出资料库，
    /// 避免资料库留下幽灵专辑（无曲目占位、或者本地导入后删除了所有曲目残留的空碟）。
    private func pruneEmptyAlbums() {
        let emptyAlbums = libraryAlbums.filter { album in
            !libraryTracks.contains { Self.belongs($0, to: album) }
        }
        guard !emptyAlbums.isEmpty else { return }
        let emptyIDs = Set(emptyAlbums.map(\.id))
        libraryAlbumIDs.subtract(emptyIDs)
        libraryAlbums.removeAll { emptyIDs.contains($0.id) }
        for id in emptyIDs {
            albumAddedAt.removeValue(forKey: id)
        }
        rebuildAlbumIndex()
    }

    // MARK: - 播放列表

    func playlist(id: String) -> LibraryPlaylist? { playlists.first { $0.id == id } }

    /// 能被「添加到播放列表」收歌的列表：只有 Amber 自己建的那些
    /// （音源歌单是只读镜像，Amber 没有写回音源的能力）。
    var editablePlaylists: [LibraryPlaylist] { playlists.filter(\.isEditable) }

    /// 新建一份本地播放列表，返回它（调用方拿 id 直接跳过去）。
    @discardableResult
    func createPlaylist(name: String, tracks: [Track] = []) -> LibraryPlaylist {
        let playlist = LibraryPlaylist.local(name: name, tracks: tracks)
        playlists.insert(playlist, at: 0)
        save()
        return playlist
    }

    /// 新建时的默认名。Music 是「新建播放列表」，重名时补序号。
    func defaultNewPlaylistName() -> String {
        let base = "新建播放列表"
        let taken = Set(playlists.map(\.name))
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    func renamePlaylist(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }),
              playlists[index].isEditable else { return }
        playlists[index].name = trimmed
        save()
    }

    /// 从资料库里删掉一份列表。账号同步来的要记一笔，否则下次同步又冒出来。
    func deletePlaylist(id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        if playlists[index].origin == .account {
            dismissedAccountPlaylistIDs.insert(id)
        }
        playlists.remove(at: index)
        save()
    }

    /// 往本地列表里加歌。Music 允许同一首在一份列表里出现多次，这里跟它一致，不去重。
    func addTracks(_ tracks: [Track], toPlaylist id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }),
              playlists[index].isEditable, !tracks.isEmpty else { return }
        playlists[index].tracks.append(contentsOf: tracks)
        // 设置 › 高级 ›「添加与删除播放列表歌曲」：加进本地列表的歌同时进资料库
        //（Music 那条开关的正向语义）。关着时列表与资料库互不相干。
        if AppSettings.shared.values.syncPlaylistSongsWithLibrary {
            var added: [Track] = []
            for track in tracks.reversed() where insert(track) { added.append(track) }
            if !added.isEmpty { onTracksAdded?(added.reversed()) }
        }
        save()
    }

    func removeTracks(at offsets: IndexSet, fromPlaylist id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }),
              playlists[index].isEditable else { return }
        playlists[index].tracks.remove(atOffsets: offsets)
        save()
    }

    func moveTracks(fromOffsets offsets: IndexSet, toOffset destination: Int, inPlaylist id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }),
              playlists[index].isEditable else { return }
        playlists[index].tracks.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    // MARK: 音源歌单进资料库

    func isPlaylistInLibrary(_ playlist: Playlist) -> Bool {
        playlists.contains { $0.id == playlist.id }
    }

    func addPlaylistToLibrary(_ playlist: Playlist) {
        guard !isPlaylistInLibrary(playlist) else { return }
        dismissedAccountPlaylistIDs.remove(playlist.id)
        playlists.insert(.from(playlist, origin: .added), at: 0)
        save()
    }

    /// 把登录账号在音源里的歌单并进资料库。
    ///
    /// 同步是**幂等**的：已经在库里的按 id 更新名字/封面/曲目数，新的补进来，
    /// 账号里已经没有了的从库里摘掉——但只摘 `.account` 那些，
    /// 用户自建的和手动加进来的不受影响。用户主动删过的不再加回来——除非是手动点了
    /// 「刷新账号歌单」（`resetDismissed`）：那是把删掉的重新拉回来的唯一路子，
    /// 否则删过的账号歌单在 Amber 里就再也见不到了。
    func syncAccountPlaylists(_ remote: [Playlist], kind: ProviderKind, resetDismissed: Bool = false) {
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if resetDismissed {
            dismissedAccountPlaylistIDs.subtract(remoteByID.keys)
        }
        let dismissed = dismissedAccountPlaylistIDs
        updatePlaylists { playlists in
            // 摘掉账号里已经没有的
            playlists.removeAll { $0.origin == .account && $0.source?.kind == kind
                && remoteByID[$0.id] == nil }
            // 更新已有的
            for index in playlists.indices {
                guard playlists[index].origin == .account,
                      let fresh = remoteByID[playlists[index].id] else { continue }
                playlists[index].name = fresh.name
                playlists[index].source = fresh
                playlists[index].coverURL = fresh.coverURL
                playlists[index].description = fresh.description
            }
            // 补新的（保持音源给的顺序，接在现有列表后面）
            let known = Set(playlists.map(\.id))
            for playlist in remote where !known.contains(playlist.id)
                && !dismissed.contains(playlist.id) {
                playlists.append(.from(playlist, origin: .account))
            }
        }
    }

    /// 一次改动整份播放列表数组。
    ///
    /// 直接对 `playlists` 连着写（摘一批、逐条改字段、再补一批）的话，每一笔都要发一次
    /// `objectWillChange`、让侧栏与所有列表页重画一遍，而且`@Published` 的 willSet 会在
    /// 每次下标赋值时多留一份数组引用，写时复制就真的复制了——一次账号同步几十份列表
    /// 就是几十次全量拷贝。这里在局部变量上改完再整份换回去：一次通知、一次拷贝、一次落盘。
    func updatePlaylists(_ mutate: (inout [LibraryPlaylist]) -> Void) {
        var working = playlists
        mutate(&working)
        playlists = working
        save()
    }

    // MARK: - 心水与评分

    func isFavorite(_ track: Track) -> Bool {
        favoriteTrackIDs.contains(track.id)
    }

    func toggleFavorite(_ track: Track) {
        if let index = favoriteTracks.firstIndex(where: { $0.id == track.id }) {
            favoriteTracks.remove(at: index)
            favoriteTrackIDs.remove(track.id)
        } else {
            favoriteTracks.insert(track, at: 0)
            favoriteTrackIDs.insert(track.id)
            // 设置 › 高级 ›「添加与删除喜爱歌曲」：心水的歌同时进资料库。
            // 只有加心水这一侧——取消心水不把歌从资料库里删（Music 同：那是两件事，
            // 反向那条由 `pruneAfterLibraryRemoval` 从资料库那头做）。
            if AppSettings.shared.values.syncFavoriteSongsWithLibrary { addToLibrary(track) }
        }
        save()
    }

    // MARK: - 歌曲列表复选框

    /// 这首歌勾着没有。没有记录就是勾着——见 `uncheckedTrackIDs` 的取反存法。
    func isChecked(_ track: Track) -> Bool { !uncheckedTrackIDs.contains(track.id) }

    /// 勾上 / 取消勾选一首。
    func setChecked(_ track: Track, _ checked: Bool) { setChecked([track], checked) }

    /// 整批改（菜单「勾选所选项 / 取消勾选所选项」走这条）。
    ///
    /// 一批只发一次 `objectWillChange`、只排一次落盘：逐首调单曲版的话，
    /// 全选一千首就是一千次通知 + 一千次防抖续期。
    func setChecked(_ tracks: [Track], _ checked: Bool) {
        let ids = Set(tracks.map(\.id))
        guard !ids.isEmpty else { return }
        let updated = checked ? uncheckedTrackIDs.subtracting(ids)
                              : uncheckedTrackIDs.union(ids)
        guard updated != uncheckedTrackIDs else { return }
        // 手动发：这份集合不是 `@Published`，而歌曲表要靠这一声重画勾选列
        // （`LibrarySongsViewController.bind` 订的就是`objectWillChange`）。
        objectWillChange.send()
        uncheckedTrackIDs = updated
        save()
    }

    // MARK: - 本地文件失联（spec §10.1）

    /// 这条本地曲目**已经发现**文件不在 `localPath` 指的位置上了。
    ///
    /// 没有记录 ＝ **还没发现**，不等于「文件一定在」——判定是懒的（见
    /// `missingFileTrackIDs`），一首从没被播过、也没被批量查找扫到的歌，文件早没了这里也是假。
    ///
    /// 取 id 而不是 `Track`：调用它的是表格的逐行绘制，那里手上常常只有一个 id。
    func isFileMissing(_ trackID: String) -> Bool { missingFileTrackIDs.contains(trackID) }

    /// 拿这条曲目去用（取流）的时候发现文件不在原处：打标记。
    ///
    /// 这是 §10.1 里两个写入点中的一个，也是**唯一的日常入口**：Music 的
    /// 「could not be **used**」就是这一下。取流那条路每一首都会走到，
    /// 所以自动连播撞上的、预取撞上的也照样打标——弹不弹对话框是另一件事（那条只给
    /// 用户主动点播的那一首，见 `MissingFileLocator`）。
    func markFileMissing(_ trackID: String) {
        guard !missingFileTrackIDs.contains(trackID) else { return }
        // 手动发：这份集合不是 `@Published`，而歌曲表要靠这一声重画那枚感叹号
        //（与 `setChecked` 同一条路，`LibrarySongsViewController.bind` 订的就是`objectWillChange`）。
        objectWillChange.send()
        missingFileTrackIDs.insert(trackID)
    }

    /// 撤标记：重新指路成功、或者批量查找把它找回来了。
    func clearFileMissing(_ trackID: String) {
        guard missingFileTrackIDs.contains(trackID) else { return }
        objectWillChange.send()
        missingFileTrackIDs.remove(trackID)
    }

    /// 扫一遍资料库里的本地曲目，返回**此刻确实找不到文件**的那些，并把标记对齐到这份结果。
    ///
    /// **只由用户主动发起的那条链调用**（res 143 idx 19「你想要使用“X”的位置来查找资料库中
    /// 缺少的其他文件吗？」→ idx 20「正在查找丢失的文件…」）。不要拿它做启动重扫或定时轮询：
    /// spec §10.1.2 已实测坐实 Music 的失联判定挂在播放路径上、没有后台全量扫描，
    /// 加一条就等于给用户一屏它本来不会给的红叹号（最典型的是外接盘还没挂上的那几秒）。
    ///
    /// 判据是**两段**的，少一段就是误报一整片：
    ///
    /// 1. 先看这条路径所在的**卷**通不通。不通——外接盘没插、网络卷断了——那不是
    ///    文件没了，是路还没通。这种情况下该卷上的曲目**一律维持原状**（保留上一轮的
    ///    判定），绝不新标。只判 `fileExists(atPath: 文件)` 的话，拔一次移动硬盘就会把
    ///    上面几百首歌整片标成「文件缺失」，插回来之前用户看到的是一屏红。
    /// 2. 卷通着、而文件不在，才算真缺失。
    ///
    /// **锚点必须是卷，不能是文件的上级目录**——这条曾经写错过，用真实的库一验就漏：
    /// 「媒体」文件夹是按 `艺人/专辑/曲目` 摆的（`DownloadStore.relativePath`），
    /// 一张碟的文件被删干净，那张碟的目录就空了、跟着被清掉，艺人目录也一样。
    /// [实测 2026-09-10] 用户库里 11 条失效路径，10 条的上级目录已经不存在——
    /// 拿上级目录当锚点，等于把「文件真被删了」这件事本身当成「路没通」，一条都报不出来。
    /// 中间目录消失是删歌的**伴生现象**，不是判据。
    ///
    /// 反过来也要成立：文件被放回原处、或者刚被重新指了路，这一轮就要把标记**撤掉**——
    /// 所以是整份重算后替换，而不是往集合里只加不减。
    ///
    /// **已知边界**：这段在主线程上逐条 `stat`。本地 APFS 上几百条是毫秒级；挂着一个
    /// 无响应的网络卷时单次 `stat` 能卡到几十秒。调用它的那条链自己带着一张
    /// 「正在查找丢失的文件…」的进度页签（`MissingFileLocator`），卡在那儿至少是有说法的。
    @discardableResult
    func missingLocalTracks() -> [Track] {
        let fm = FileManager.default
        var missing: Set<String> = []
        var result: [Track] = []
        // 卷可达性缓存，键是上级目录。一张碟几十首歌都在同一个目录下，逐首向上走一遍是白花钱；
        // 更要紧的是**同一次扫描里卷的状态必须前后一致**：真在扫的过程中被拔盘，
        // 缓存能保证这一轮要么整批跳过、要么整批判，不会一半标一半不标。
        var volumeReachable: [String: Bool] = [:]
        for track in localTracks {
            guard let url = track.localURL else { continue }
            let parent = url.deletingLastPathComponent().path
            let reachable = volumeReachable[parent]
                ?? Self.isVolumeReachable(for: url, fileManager: fm)
            volumeReachable[parent] = reachable
            guard reachable else {
                // 卷保护：维持原状——之前标过的继续标着（也继续算进「缺少的文件」那份清单，
                // 它本来就是标记的镜像），没标过的不新标。
                if missingFileTrackIDs.contains(track.id) {
                    if missing.insert(track.id).inserted { result.append(track) }
                }
                continue
            }
            if !fm.fileExists(atPath: url.path) {
                if missing.insert(track.id).inserted { result.append(track) }
            }
        }
        if missing != missingFileTrackIDs {
            objectWillChange.send()
            missingFileTrackIDs = missing
        }
        return result
    }

    /// 这条路径所在的卷通不通——`missingLocalTracks` 的卷保护判据。
    ///
    /// 做法是从文件往上走，找**第一个还存在的祖先**：
    ///
    /// - 走到的是 `/Volumes` 本身 → 这条路径要的那个卷没挂载（macOS 上外接盘与网络卷
    ///   都挂在这儿，卷一走 `/Volumes/<名字>` 整个消失，只剩`/Volumes` 这个空壳）。
    ///   路没通，跳过。
    /// - 走到的是别的目录 → 卷在。中间少掉的那几层是文件被删时跟着空掉的专辑/艺人目录，
    ///   属于删除的伴生现象，不是「路没通」。
    ///
    /// 不用 `mountedVolumeURLs` 做最长前缀匹配：拔盘之后`/Volumes/MyDisk` 已经不在那份
    /// 清单里，最长匹配会一路退回根卷 `/`，于是判成「卷在」——正好把要挡的那种情况放过去。
    /// 而 `/Volumes` 这个空壳恰恰是「卷本该在这儿、现在不在」的现场证据。
    nonisolated static func isVolumeReachable(for url: URL,
                                              fileManager fm: FileManager) -> Bool {
        var directory = url.standardizedFileURL.deletingLastPathComponent()
        while !fm.fileExists(atPath: directory.path) {
            let parent = directory.deletingLastPathComponent()
            // 到根了还没找到存在的祖先。真实文件系统上不会发生（`/` 总在），
            // 兜底判成「不可达」——宁可漏报一条，也不要凭一条走不通的路去标一片。
            guard parent.path != directory.path else { return false }
            directory = parent
        }
        return directory.path != "/Volumes"
    }

    /// 按 id 改一条曲目的字段。**四处数组 + 每份本地播放列表**都要改：
    /// `libraryTracks`、`favoriteTracks`、`recentTracks`、以及每份播放列表的`tracks`。
    /// 曲目是**值类型、各存各的副本**，漏掉哪一处，那一处的行就还是旧值——
    /// 表格里刚改好的歌，切到「最近播放」又是老标题，重新指过路的还会再次播放失败。
    ///
    /// 改的是数组的**整份替换**而不是逐条下标赋值：`@Published` 的 willSet 会在每次
    /// 下标赋值时多留一份数组引用，写时复制就真的复制了（理由同 `updatePlaylists`）。
    ///
    /// `transform` 改完与原值相等的那一份不动（也就不发`objectWillChange`、不排落盘）：
    /// 「显示简介」面板提交时五个字段里往往只动了一个，其余四个原样写回来。
    ///
    /// 返回值：真改了任何一处没有。`relocateLocalTrack` 拿它决定要不要手动补一声通知。
    @discardableResult
    func updateTrack(id: String, transform: (inout Track) -> Void) -> Bool {
        /// 改完返回新数组；这一份里没有要改的就返回 nil，好让调用处别去碰 `@Published`。
        func rewritten(_ tracks: [Track]) -> [Track]? {
            var changed = false
            let updated = tracks.map { track -> Track in
                guard track.id == id else { return track }
                var edited = track
                transform(&edited)
                guard edited != track else { return track }
                changed = true
                return edited
            }
            return changed ? updated : nil
        }

        var changed = false
        if let updated = rewritten(libraryTracks) { libraryTracks = updated; changed = true }
        if let updated = rewritten(favoriteTracks) { favoriteTracks = updated; changed = true }
        if let updated = rewritten(recentTracks) { recentTracks = updated; changed = true }
        var workingPlaylists = playlists
        var playlistsChanged = false
        for index in workingPlaylists.indices {
            if let updated = rewritten(workingPlaylists[index].tracks) {
                workingPlaylists[index].tracks = updated
                playlistsChanged = true
            }
        }
        if playlistsChanged {
            playlists = workingPlaylists
            changed = true
        }
        if changed { save() }
        return changed
    }

    /// 重新指路：把这条曲目的 `localPath` 改到新位置（用户在「查找」面板里选的那份文件，
    /// 或者批量查找按同一条位移规律推出来的那份）。
    ///
    /// 四处数组怎么改见 `updateTrack`；这里只剩「撤 missing 标记」那段收尾。
    func relocateLocalTrack(id: String, to url: URL) {
        let path = url.standardizedFileURL.path
        let changed = updateTrack(id: id) { $0.localPath = path }

        // 当场撤标记：面板一关表格就该恢复正常，否则用户看到的是「指了路还是红的」——
        // 那看着就像没生效，会被再指一遍。万一真指错了（指到一个不存在的路径），
        // 下一次拿它取流会重新标上。
        let hadMark = missingFileTrackIDs.remove(id) != nil
        // 路径没变、也没标记可撤，就什么都没发生，别白发通知白排一次落盘。
        guard changed || hadMark else { return }
        // 只有 `@Published` 那三处没动、单纯撤标记时才要手动发——否则`updateTrack`
        // 里的赋值已经发过了（落盘也已经由它排过）。
        if !changed { objectWillChange.send() }
    }

    /// 按 id 找一条本地曲目（重新指路之后要拿改完的那份去更新下载索引）。
    ///
    /// 与 `localTracks` 同样四处都找：`recents` 里那几首常常不在资料库中（见下面那条注释）。
    func track(withID id: String) -> Track? {
        localTracks.first { $0.id == id }
    }

    /// 资料库里所有带 `localPath` 的曲目，四处合起来、按 id 去重。
    ///
    /// 只扫 `libraryTracks` 是不够的：[实测 2026-09-10] 用户当前的库里，`libraryTracks`
    /// 54 条中 6 条 `localPath` 已失效，而`recents` 那 101 条里**另有** 5 条不在资料库中。
    /// 漏掉 recents，「最近播放」里那几行就永远不会变灰、批量查找也永远修不到它们。
    private var localTracks: [Track] {
        var seen = Set<String>()
        var result: [Track] = []
        func collect(_ tracks: [Track]) {
            for track in tracks where track.localPath != nil {
                if seen.insert(track.id).inserted { result.append(track) }
            }
        }
        collect(libraryTracks)
        collect(favoriteTracks)
        collect(recentTracks)
        for playlist in playlists { collect(playlist.tracks) }
        return result
    }

    // MARK: - 减少推荐（音源口味的本地镜像）

    /// 这首歌有没有说过「减少推荐」。见 `suggestLessTrackIDs`：本地镜像，不是音源那边的真值。
    func isSuggestedLess(_ track: Track) -> Bool { suggestLessTrackIDs.contains(track.id) }

    func isSuggestedLessArtist(_ artistID: String) -> Bool {
        suggestLessArtistIDs.contains(artistID)
    }

    /// 记下（或抹掉）一批曲目的「减少推荐」。**只有音源那边写成功了才调**——
    /// 由 `AppState.suggestLess` 在`try await` 之后调，失败就不记，
    /// 免得镜像里躺着一条根本没写出去的记号。
    func setSuggestedLess(_ tracks: [Track], _ on: Bool) {
        let ids = Set(tracks.map(\.id))
        guard !ids.isEmpty else { return }
        let updated = on ? suggestLessTrackIDs.union(ids) : suggestLessTrackIDs.subtracting(ids)
        guard updated != suggestLessTrackIDs else { return }
        objectWillChange.send()
        suggestLessTrackIDs = updated
        save()
    }

    func setSuggestedLessArtist(_ artistID: String, _ on: Bool) {
        let updated = on ? suggestLessArtistIDs.union([artistID])
                         : suggestLessArtistIDs.subtracting([artistID])
        guard updated != suggestLessArtistIDs else { return }
        objectWillChange.send()
        suggestLessArtistIDs = updated
        save()
    }

    func isFavoriteAlbum(_ album: Album) -> Bool {
        favoriteAlbumIDs.contains(album.id)
    }

    func toggleFavoriteAlbum(_ album: Album) {
        if favoriteAlbumIDs.contains(album.id) {
            favoriteAlbumIDs.remove(album.id)
        } else {
            favoriteAlbumIDs.insert(album.id)
        }
        save()
    }

    /// 收藏这位艺人。与专辑的「喜爱」同一个性质：只是一个本地标记，
    /// 不像「添加到资料库」那样往库里塞内容。
    func isFavoriteArtist(_ artist: Artist) -> Bool {
        favoriteArtistIDs.contains(artist.id)
    }

    func toggleFavoriteArtist(_ artist: Artist) {
        if favoriteArtistIDs.contains(artist.id) {
            favoriteArtistIDs.remove(artist.id)
        } else {
            favoriteArtistIDs.insert(artist.id)
        }
        save()
    }

    /// 0 表示未评分。
    func rating(for id: String) -> Int { ratings[id] ?? 0 }

    /// 再次点击当前星级会清空，与 Music.app 一致。
    func setRating(_ value: Int, for id: String) {
        let clamped = max(0, min(5, value))
        if clamped == 0 || ratings[id] == clamped {
            ratings.removeValue(forKey: id)
        } else {
            ratings[id] = clamped
        }
        save()
    }

    /// 该曲目被播放过的次数，0 表示从未播放。
    func playCount(for id: String) -> Int { playCounts[id] ?? 0 }

    /// 「显示简介 › 详细信息 › 播放次数」旁边那颗「重设」（[AX] `500,541,75,26`）。
    ///
    /// 次数与「上次播放时间」一起清——面板上它们是拼在一句里的
    /// （`4 （上次播放时间：星期四 17:25）`），清掉次数却留着时刻会拼出
    /// `0 （上次播放时间：…）` 这种自相矛盾的话。跳过次数不动：那是另一本账。
    func resetPlayCount(for id: String) {
        guard playCounts[id] != nil || lastPlayedAt[id] != nil else { return }
        playCounts.removeValue(forKey: id)
        lastPlayedAt.removeValue(forKey: id)
        save()
    }

    /// 该曲目被中途切走的次数。
    func skipCount(for id: String) -> Int { skipCounts[id] ?? 0 }

    /// 一首歌没放完就被切走：Music 记一次跳过并记下时刻。
    ///
    /// 通用页「使用听歌历史记录」关掉时直接返回：Music 关掉这条只是**停止记录**，
    /// 已经记下的跳过次数与时刻照旧留着，所以这里不清任何已有数据。
    func recordSkip(_ track: Track) {
        guard AppSettings.shared.values.useListeningHistory else { return }
        skipCounts[track.id, default: 0] += 1
        lastSkippedAt[track.id] = Date()
        save()
    }

    /// 曲目所属的资料库专辑。Track 模型只有专辑名/id，曲风、发行年、专辑艺人都得回查专辑。
    ///
    /// **有 `albumId` 就只认 id。** 早先这里是「id 查不到就退回按名字查」，
    /// 于是资料库里同时有两张《太阳之子》（一张「文件 › 导入…」进来的本地碟、
    /// 一张 QQ 的）时，那张只按名字建的表里只留得下先入库的那一张，另一张的曲目
    /// 连封面带曲风一起认错人——插图列画出来的是别人的封面（`artworkBlock` 取的正是
    /// `album?.artworkURL ?? track.artworkURL`）。id 查不到说明这张碟根本不在资料库里，
    /// 拿一张同名的顶上只会给出别人的信息，还不如答 nil，让调用方回落到曲目自己那份。
    func album(for track: Track) -> Album? {
        if let albumId = track.albumId { return albumsByID[albumId] }
        guard !track.albumName.isEmpty else { return nil }
        return albumsByFallbackKey[Self.fallbackKey(for: track)]
    }

    /// 没有 `albumId` 的曲目按这把键归位。光同名不够——同名碟在资料库里是常态
    /// （本地导入的那张与音源那张、翻唱与原版、不同艺人的同名碟），
    /// 所以键里还要带上艺人，并且不跨「本地 / 在线」与音源这两道边界：
    ///
    /// - `isLocal`：本地导入的曲目与在线曲目本来就是两批东西，永远不该互相归位。
    ///   （本地曲目的 `kind` 是导入时的默认音源，是个**真**音源——见`Track.localIDPrefix`——
    ///   所以单靠 `kind` 分不开本地碟与同一音源的在线碟，这一道必须单列。）
    /// - `kind`：两边都必然有音源，不同音源的同名碟一律不算同一张。
    /// - 艺人名与专辑名：大小写与前后空白无关（与 `ImportService.albumKey` 的归组口径一致）。
    private static func fallbackKey(name: String, artist: String,
                                    kind: ProviderKind, isLocal: Bool) -> String {
        [normalizedForMatching(name), normalizedForMatching(artist),
         kind.rawValue, isLocal ? "1" : "0"].joined(separator: "\u{1}")
    }

    private static func fallbackKey(for track: Track) -> String {
        fallbackKey(name: track.albumName, artist: track.artistName,
                    kind: track.kind, isLocal: track.isLocal)
    }

    private static func normalizedForMatching(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 一首歌是不是这张碟里的。`tracks(in:)` 与`albumAddedDate(for:)` 共用这一条，
    /// 两处判定必须同解——否则「碟里有几首」和「碟是什么时候加的」会各按各的算。
    private static func belongs(_ track: Track, to album: Album) -> Bool {
        if let albumId = track.albumId { return albumId == album.id }
        guard !album.name.isEmpty, !track.albumName.isEmpty else { return false }
        return fallbackKey(for: track) == fallbackKey(name: album.name, artist: album.artistName,
                                                      kind: album.kind, isLocal: album.isLocal)
    }

    /// 资料库「歌曲」表的「类型」列：Track 模型没有曲风，回落到这首歌所属专辑的曲风。
    func genre(for track: Track) -> String? { album(for: track)?.genre }

    /// 「专辑艺人」列：专辑挂名的艺人，可能与单曲艺人不同。
    func albumArtist(for track: Track) -> String? { album(for: track)?.artistName }

    /// 「发布日期」列：专辑发行日期原样（音源给的多是 2025-06-06 这种）。
    func releaseDate(for track: Track) -> String? { album(for: track)?.publishDate }

    /// 「专辑评分」列：星级挂在专辑 id 上，与曲目星级共用一张表。
    func albumRating(for track: Track) -> Int {
        guard let id = album(for: track)?.id else { return 0 }
        return rating(for: id)
    }

    /// 「年份」列：专辑发行日期取前四位。
    func year(for track: Track) -> String? {
        guard let date = album(for: track)?.publishDate, date.count >= 4 else { return nil }
        return String(date.prefix(4))
    }

    /// 「音乐回忆：你的热门音乐」用的月度统计：上个自然月听过的曲目，按播放次数从多到少。
    /// 口径是「**最后一次**播放落在上个月」——本地只有 lastPlayedAt 这一个时间戳，
    /// 没有逐次播放的流水，做不到「上个月播过的全部」。
    func topTracksLastMonth(limit: Int = 25) -> [Track] {
        let calendar = Calendar.current
        guard let thisMonth = calendar.dateInterval(of: .month, for: Date()),
              let lastMonth = calendar.dateInterval(of: .month,
                                                    for: thisMonth.start.addingTimeInterval(-1))
        else { return [] }
        // 曲目对象只在这三处留着（lastPlayedAt 存的是 id）
        var pool: [String: Track] = [:]
        for track in recentTracks + libraryTracks + favoriteTracks where pool[track.id] == nil {
            pool[track.id] = track
        }
        return lastPlayedAt
            .filter { lastMonth.contains($0.value) && pool[$0.key] != nil }
            .sorted {
                let (left, right) = (playCount(for: $0.key), playCount(for: $1.key))
                return left == right ? $0.value > $1.value : left > right
            }
            .prefix(limit)
            .compactMap { pool[$0.key] }
    }

    /// 开始听一首歌：把它顶到「最近播放」的最前面，**不动播放次数**。
    ///
    /// 与 `notePlayed` 分开是因为 Music 的两件事口径不同：「最近播放」是「点开过就算」，
    /// 播放次数要听完才算。合成一件（原先的 `recordPlay`）的后果是听两秒就切走的歌
    /// 同时被记一次播放和一次跳过。
    ///
    /// 同 `recordSkip`：「使用听歌历史记录」关掉时什么都不记，已有的历史原样保留。
    func noteStarted(_ track: Track) {
        guard AppSettings.shared.values.useListeningHistory else { return }
        recentTracks.removeAll { $0.id == track.id }
        recentTracks.insert(track, at: 0)
        if recentTracks.count > 200 {
            recentTracks = Array(recentTracks.prefix(200))
        }
        save()
    }

    /// 一首歌**播到了结尾**：播放次数 +1、记下这一刻。由播放器在切下一首之前调，
    /// 单曲循环每绕一遍算一次（见 `PlayerController.handleTrackEnded`）。
    func notePlayed(_ track: Track) {
        guard AppSettings.shared.values.useListeningHistory else { return }
        playCounts[track.id, default: 0] += 1
        lastPlayedAt[track.id] = Date()
        save()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let storage = try? JSONDecoder().decode(Storage.self, from: data) else { return }
        favoriteTracks = storage.favorites
        recentTracks = storage.recents
        favoriteAlbumIDs = Set(storage.favoriteAlbums ?? [])
        favoriteArtistIDs = Set(storage.favoriteArtists ?? [])
        ratings = storage.ratings ?? [:]
        libraryTracks = storage.libraryTracks ?? []
        libraryAlbums = storage.libraryAlbums ?? []
        playCounts = storage.playCounts ?? [:]
        skipCounts = storage.skipCounts ?? [:]
        addedAt = storage.addedAt ?? [:]
        lastPlayedAt = storage.lastPlayedAt ?? [:]
        lastSkippedAt = storage.lastSkippedAt ?? [:]
        albumAddedAt = storage.albumAddedAt ?? [:]
        playlists = storage.playlists ?? []
        dismissedAccountPlaylistIDs = Set(storage.dismissedAccountPlaylists ?? [])
        uncheckedTrackIDs = Set(storage.uncheckedTracks ?? [])
        suggestLessTrackIDs = Set(storage.suggestLessTracks ?? [])
        suggestLessArtistIDs = Set(storage.suggestLessArtists ?? [])
        libraryTrackIDs = Set(libraryTracks.map(\.id))
        libraryAlbumIDs = Set(libraryAlbums.map(\.id))
        favoriteTrackIDs = Set(favoriteTracks.map(\.id))

        // 清理没有曲目残留的空本地专辑（导入后被删除曲目的残留）
        let orphanLocalAlbums = libraryAlbums.filter { album in
            album.isLocal && !libraryTracks.contains { Self.belongs($0, to: album) }
        }
        if !orphanLocalAlbums.isEmpty {
            let orphanIDs = Set(orphanLocalAlbums.map(\.id))
            libraryAlbums.removeAll { orphanIDs.contains($0.id) }
            libraryAlbumIDs.subtract(orphanIDs)
            for id in orphanIDs { albumAddedAt.removeValue(forKey: id) }
        }

        rebuildAlbumIndex()
    }

    /// libraryAlbums 变了就重建两张查表。改动（入库/移出/载入）是用户级动作，
    /// 一次 O(n) 换掉排序时每行一次的线性扫描。
    private func rebuildAlbumIndex() {
        albumsByID = [:]
        albumsByFallbackKey = [:]
        albumsByID.reserveCapacity(libraryAlbums.count)
        for album in libraryAlbums {
            if albumsByID[album.id] == nil { albumsByID[album.id] = album }
            guard !album.name.isEmpty else { continue }
            let key = Self.fallbackKey(name: album.name, artist: album.artistName,
                                       kind: album.kind, isLocal: album.isLocal)
            if albumsByFallbackKey[key] == nil { albumsByFallbackKey[key] = album }
        }
    }

    /// 标脏并续期防抖：连续快速改动只在最后一次之后写一次盘。
    private func save() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounce)
            guard !Task.isCancelled, let self else { return }
            self.pendingSave = nil
            // 值类型快照在主线程取，编码与写盘扔给后台队列。
            let storage = self.snapshot()
            let url = self.fileURL
            Self.writeQueue.async { Self.write(storage, to: url) }
        }
    }

    /// 立刻同步落盘。退出前兜底与测试断言磁盘内容时用。
    func flushNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let storage = snapshot()
        let url = fileURL
        Self.writeQueue.sync { Self.write(storage, to: url) }
    }

    private func snapshot() -> Storage {
        Storage(favorites: favoriteTracks, recents: recentTracks,
                favoriteAlbums: Array(favoriteAlbumIDs),
                favoriteArtists: Array(favoriteArtistIDs), ratings: ratings,
                libraryTracks: libraryTracks, libraryAlbums: libraryAlbums,
                playCounts: playCounts, skipCounts: skipCounts,
                addedAt: addedAt, lastPlayedAt: lastPlayedAt,
                lastSkippedAt: lastSkippedAt, albumAddedAt: albumAddedAt,
                playlists: playlists,
                dismissedAccountPlaylists: Array(dismissedAccountPlaylistIDs),
                uncheckedTracks: Array(uncheckedTrackIDs),
                suggestLessTracks: Array(suggestLessTrackIDs),
                suggestLessArtists: Array(suggestLessArtistIDs))
    }

    private nonisolated static func write(_ storage: Storage, to url: URL) {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 资料库派生（艺人页）

    /// 专辑的添加时间。优先取记录值；旧存档没有时回落这张碟里曲目 addedAt 的最大值，
    /// 再没有（从未记过时间）返回 nil。
    func albumAddedDate(for album: Album) -> Date? {
        if let stamped = albumAddedAt[album.id] { return stamped }
        return libraryTracks
            .filter { Self.belongs($0, to: album) }
            .compactMap { addedAt[$0.id] }
            .max()
    }

    /// 资料库专辑里属于这张碟的歌。判定见 `belongs(_:to:)`：**有`albumId` 就只认 id**，
    /// 没有的才按名字归位，且要艺人对得上、不跨本地/在线与音源。
    ///
    /// 早先是「id 相同 **或** 专辑名相同」，那个 `||` 会把同名碟整个串起来：
    /// 资料库里两张《太阳之子》（本地导入的一张、QQ 的一张）时，
    /// 艺人页上两个《太阳之子》块各自列的都是**两张碟的曲目并集**。
    func tracks(in album: Album) -> [Track] {
        let tracks = libraryTracks.filter { Self.belongs($0, to: album) }
        if tracks.isEmpty { return tracks }
        return tracks.sorted { lhs, rhs in
            let leftDisc = lhs.discNumber ?? 0, rightDisc = rhs.discNumber ?? 0
            if leftDisc != rightDisc { return leftDisc < rightDisc }
            let leftNumber = lhs.trackNumber ?? 0, rightNumber = rhs.trackNumber ?? 0
            if leftNumber != rightNumber { return leftNumber < rightNumber }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    /// 资料库的艺人：从入库专辑（其次单曲）的艺人名去重派生，按名称排序。
    /// Music 的艺人数据来自资料库曲目的艺人树（`artists 规格` §5.3
    /// `ITArtistsSplitViewModel.buildArtistArray` 同一语义）。Amber 没有独立艺人条目，
    /// 更没有本地艺人照——头像由界面层按艺人名向音源解析（LibraryArtistsPage 与
    /// 搜索页资料库范围同法），这里一律给 nil，**不能**拿专辑封面顶替。
    func libraryArtists() -> [Artist] {
        var names: [String] = []
        var kinds: [String: ProviderKind] = [:]
        for album in libraryAlbums {
            let name = album.artistName
            guard !name.isEmpty else { continue }
            if kinds[name] == nil {
                kinds[name] = album.kind
                names.append(name)
            }
        }
        for track in libraryTracks {
            let name = track.artistName
            guard !name.isEmpty, kinds[name] == nil else { continue }
            kinds[name] = track.kind
            names.append(name)
        }
        return names
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                Artist(id: Artist.libraryIDPrefix + name,
                       kind: kinds[name] ?? .netease,
                       name: name,
                       avatarURL: nil,
                       description: nil)
            }
    }

    /// 某位艺人在资料库里的专辑（艺人名匹配），保持「最近添加」在前。
    func albums(byArtist name: String) -> [Album] {
        libraryAlbums.filter { $0.artistName == name }
    }

    /// 某位艺人在资料库里的全部曲目（含未随整张碟入库的单曲），碟内按曲序、碟间按添加先后。
    func tracks(byArtist name: String) -> [Track] {
        let albumOrder = Dictionary(uniqueKeysWithValues:
            libraryAlbums.enumerated().map { ($1.id, $0) })
        return libraryTracks
            .filter { $0.artistName == name }
            .sorted { lhs, rhs in
                let left = lhs.albumId.flatMap { albumOrder[$0] }
                let right = rhs.albumId.flatMap { albumOrder[$0] }
                switch (left, right) {
                case let (l?, r?) where l != r: return l < r
                case (.some, .none): return false
                case (.none, .some): return true
                default: break
                }
                let leftDisc = lhs.discNumber ?? 0, rightDisc = rhs.discNumber ?? 0
                if leftDisc != rightDisc { return leftDisc < rightDisc }
                let leftNumber = lhs.trackNumber ?? 0, rightNumber = rhs.trackNumber ?? 0
                if leftNumber != rightNumber { return leftNumber < rightNumber }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }
}
