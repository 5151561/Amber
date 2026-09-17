import Combine
import Foundation

/// 资料库的一次改动动了哪几份数据。
///
/// `objectWillChange` 是**整座库的一个出口**：28 个`@Published` 加 5 处手工发声全打在它上面，
/// 于是给一张专辑点一次喜爱 ★，资料库四页 + 歌曲页各自把全库重算一遍。
/// 那个出口必须留着（仓库别处、SwiftUI 叶子还订着它），这一层是**叠在它旁边**的细分出口：
/// 谁读哪几份就订哪几位，与自己无关的写入根本不会把它叫醒。
///
/// 位按「界面上哪几件会跟着变」划，不按存储字段划：`.playbackStats` 罩着的四份
///（播放次数 / 上次播放 / 逐曲历史 / 容器台账）永远是同一次记账一起动的，
/// 拆开只会逼每个消费方写四条一模一样的订阅。
struct LibraryChange: OptionSet, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    /// 资料库曲目集合：入库、退库，以及 `updateTrack` 改到的曲目字段。
    static let tracks = LibraryChange(rawValue: 1 << 0)
    /// 资料库专辑集合与 `albumAddedAt`（「最近添加」的分段键）。
    static let albums = LibraryChange(rawValue: 1 << 1)
    /// 播放列表集合：增删、改名、列表内曲目增删与重排、账号同步。
    static let playlists = LibraryChange(rawValue: 1 << 2)
    /// 心水歌曲（`favoriteTracks`）。
    static let favorites = LibraryChange(rawValue: 1 << 3)
    static let favoriteAlbums = LibraryChange(rawValue: 1 << 4)
    static let favoriteArtists = LibraryChange(rawValue: 1 << 5)
    /// 星级（曲目与专辑共用 `ratings` 一张表）。
    static let ratings = LibraryChange(rawValue: 1 << 6)
    /// 播放与跳过的记账：`playCounts` / `skipCounts` / `lastPlayedAt` / `lastSkippedAt` /
    /// `recentTracks` / `recentContainers`。
    static let playbackStats = LibraryChange(rawValue: 1 << 7)
    /// 歌曲列表那一列复选框（`uncheckedTrackIDs`）。
    static let checkmarks = LibraryChange(rawValue: 1 << 8)
    /// 本地文件失联标记（`missingFileTrackIDs`）。
    static let fileMissing = LibraryChange(rawValue: 1 << 9)
    /// 「减少推荐」的本地镜像。
    static let suggestLess = LibraryChange(rawValue: 1 << 10)
}

/// 本地资料库：资料库歌曲与专辑 + 心水 + 最近播放，落在 `library.sqlite` 主库里。
///
/// Music.app 把「添加到资料库」与「心水」当成两件事：
/// 前者决定专辑页用哪种形态（有星级 / 只有加号），后者只是行首那颗星。
///
/// ## 内存模型与表的关系
///
/// 下面那 28 个 `@Published` 全部保留，**内存这一份是真值，表跟着它镜像**。
/// 启动时一趟 SELECT 把它们填满，之后每一次改动当场往对应的那几行写一笔定向写。
///
/// 从前这里是「整份 `Storage` 编码成 JSON、防抖 500 ms、`.atomic` 覆盖原文件」。
/// 换掉它的理由按重要性排：
///
/// 1. **那条覆盖路径会毁数据。** 载入是 `try?` + `guard else { return }`：一个 enum case
///    解不出来就静默空库，随后用户随手点个心水触发一次写，空快照把原文件整个盖掉。
///    现在「读不出来」由 `AmberDatabaseMigration` 在建库那一步就拦下（旧 JSON 一个字不动、
///    弹阻塞式警告），而写入是定向的——没有任何一条语句能用一份空快照覆盖全库。
/// 2. **写放大随规模爆炸。** 一次播放记两笔账（起播顶「最近播放」、曲末 +1 播放次数），
///    中间隔着一整首歌，500 ms 防抖合并不了，于是每首歌两次整份重写。
///    现在曲末那一笔是一条单行 UPSERT。
@MainActor
final class LibraryStore: ObservableObject {

    /// 已添加到资料库的歌曲，最新添加的在前（「最近添加」直接用这个顺序）。
    @Published private(set) var libraryTracks: [Track] = []
    /// 已添加到资料库的专辑，最新添加的在前。
    @Published private(set) var libraryAlbums: [Album] = []
    @Published private(set) var favoriteTracks: [Track] = []
    @Published private(set) var recentTracks: [Track] = []
    /// 「最近播放」的**容器台账**：在哪儿听的（歌单 / 心水 / 艺人 / 专辑 / 散曲），最近的在前。
    ///
    /// 与上面那份逐曲历史是**两个粒度、两张表**，各有各的上限（见`RecentContainer`）：
    /// 逐曲那份 200 条喂相似种子与月度统计；这份 50 条只给货架与二级页当格子用。
    /// 合成一份再分组的话，听完一张 200 首的歌单就会把逐曲窗口整个占满，
    /// 货架塌成一张卡，更早的格子被整个挤掉。
    @Published private(set) var recentContainers: [RecentContainer] = []
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
    /// 本地文件已经不在下载索引记着的位置上的曲目 id（照 Music.app：条目留着，只打标记）。
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
    /// **故意不落盘**，主库里连表都不建：文件在不在是磁盘此刻的事实，不是资料库属性。
    /// 存下来只会带出「上次退出时盘没插、这次启动盘插着却还标着感叹号」这种陈旧假象。
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

    // MARK: 细分变更出口

    /// 细分出口的底座（见 `LibraryChange`）。**私有**：消费方只能经`changes(affecting:)`
    /// 报出「我读哪几份」才拿得到事件，不留一条「订上就什么都收」的口子——
    /// 那条口子正是 `objectWillChange` 今天这副样子的由来。
    private let changeSubject = PassthroughSubject<LibraryChange, Never>()

    /// 订这几位里任意一位的变更。事件带的是**这一次**动到的完整集合，
    /// 要按类别分支处理的消费方可以再看一眼。
    ///
    /// 与 `objectWillChange` 的时序差：这一层在值**落定之后**才发（`objectWillChange`
    /// 是 `@Published` 的 willSet，在值变之前）。即便如此，界面侧仍应把响应合批到
    /// 下一轮 runloop 再读——页面自己那份模型（搜索词、筛选、排序）还是 willSet 语义，
    /// 两条路合到同一个刷新入口上时得按更严的那一条来。
    func changes(affecting mask: LibraryChange) -> AnyPublisher<LibraryChange, Never> {
        changeSubject.filter { !$0.isDisjoint(with: mask) }.eraseToAnyPublisher()
    }

    /// 发一次细出口。空集合（什么都没真的改）不发。
    private func notify(_ change: LibraryChange) {
        guard !change.isEmpty else { return }
        changeSubject.send(change)
    }

    /// 主库连接。
    ///
    /// **nil ＝ 开库这一步就失败了**（磁盘满、目录没权限）。此时内存这一份照常能用，
    /// 只是这一程的改动落不了盘——比拿一份空库把用户的东西覆盖掉好得多。
    /// App 里走不到这里：`AppState` 先一步跑迁移，失败会弹阻塞式警告并且不以空库启动。
    private let database: AmberDatabase?

    /// `search_index` 那张表的维护者。曲目 / 专辑 / 歌单的增删改都从下面那十来个
    /// 落库助手里顺手带它一把，艺人那一档由 `persist` 末尾的对账带（见 `artistIndexDirty`）。
    private let searchIndex = LibrarySearchIndex()

    /// `directory` 供测试注入临时目录；默认落`~/Library/Application Support/Amber/`。
    init(directory: URL? = nil) {
        // 开库之前先把迁移跑到：库不在就从旧 JSON 造一份，JSON 也不在就是一个空库。
        //
        // **`mediaFolder` 原样跟着 `directory` 走**，这一条不能省：它的默认值是
        // 设置里那个「媒体」文件夹，而测试注入的是临时目录——不传的话，几十条用例
        // 会一齐去读开发者本机真实的 `~/Music/Amber/媒体/index.json`，
        // 把十几条真实的本机文件灌进一个临时库里。测试里注入的那个目录同时当媒体夹用，
        // 与 `DownloadStore(directory:)` 的约定一致。
        //
        // 生产路径上 `AppState` 已经先跑过一次（那一次才有窗口可以弹错），
        // 所以这里永远撞上「库已存在」那条幂等分支，`try?` 吞掉的只可能是测试里的畸形目录。
        try? AmberDatabaseMigration.runIfNeeded(directory: directory, mediaFolder: directory,
                                                renameLegacyOnSuccess: true)
        database = try? AmberDatabase.shared(directory: directory)
        load()
        // **没有 willTerminate 观察者了。** 从前那一个是防抖写盘的兜底（退出前把还没到期
        // 的那次改动同步落下去）；现在每一次改动当场落库，没有「还没写的」。
        // 退出前唯一要收的是 WAL 旁文件，那一处观察者归 `AmberDatabase` 自己（三个 store 合一处）。
    }

    // MARK: - 资料库

    func isInLibrary(_ track: Track) -> Bool { libraryTrackIDs.contains(track.id) }

    func addToLibrary(_ track: Track) {
        guard insert(track) else { return }
        onTracksAdded?([track])
        persist("入库") { db in
            try self.moveToFront([track], of: .library, in: db)
            // `insert` 刚记下的添加时间。
            try self.persistStat(id: track.id, in: db)
        }
        notify(.tracks)
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
        // 退库会顺带动到播放列表 / 心水 / 勾选 / 空碟，各自动没动由两个 prune 自己报，
        // 别在这里一律按最坏情况发一整套（那就又退回「一个出口」了）。
        var change: LibraryChange = .tracks
        let pruned = pruneAfterLibraryRemoval([track.id])
        change.formUnion(pruned)
        change.formUnion(pruneEmptyAlbums())
        onTracksRemoved?([track.id])
        persist("退库") { db in
            try self.remove([track.id], from: .library, in: db)
            try self.persistLibraryRemoval([track.id], pruned, in: db)
            // 空碟清理：`pruneEmptyAlbums` 已经把内存那份摘干净了，表跟着对齐。
            if change.contains(.albums) { try self.pruneAlbumRows(in: db) }
        }
        notify(change)
    }

    func toggleLibrary(_ track: Track) {
        isInLibrary(track) ? removeFromLibrary(track) : addToLibrary(track)
    }

    func isAlbumInLibrary(_ album: Album) -> Bool { libraryAlbumIDs.contains(album.id) }

    /// 加专辑等于把整张碟的歌一并入库——与 Music.app 的「添加到资料库」一致。
    func addAlbumToLibrary(_ album: Album, tracks: [Track]) {
        var change: LibraryChange = []
        let isNewAlbum = !libraryAlbumIDs.contains(album.id)
        if isNewAlbum {
            libraryAlbumIDs.insert(album.id)
            libraryAlbums.insert(album, at: 0)
            rebuildAlbumIndex()
            albumAddedAt[album.id] = Date()
            change.insert(.albums)
        } else {
            if albumAddedAt[album.id] == nil {
                albumAddedAt[album.id] = Date()
                change.insert(.albums)
            }
            // 已经在库里的那张只补封面，别整条覆盖（用户改过的评分、喜爱都挂在原条目上）。
            // 本地导入常常是「先导了一首没封面的，回头又导了同碟里带内嵌图的那首」，
            // 补这一下，专辑页那格才不会一直空着。
            if let artwork = album.artworkURL, !artwork.isEmpty,
               let index = libraryAlbums.firstIndex(where: { $0.id == album.id }),
               libraryAlbums[index].artworkURL?.isEmpty != false {
                libraryAlbums[index] = Self.copy(libraryAlbums[index], artworkURL: artwork)
                rebuildAlbumIndex()
                change.insert(.albums)
            }
        }
        // 逐首插到最前，倒序遍历后整张碟在「最近添加」里保持原曲序。
        var added: [Track] = []
        for track in tracks.reversed() {
            let stampedTrack = stamped(track, with: album)
            if insert(stampedTrack) { added.append(stampedTrack) }
        }
        // 于是数组最前面那一段的顺序就是 `added` 反过来——落库那一趟要的正是这一份。
        let front: [Track] = added.reversed()
        if !front.isEmpty {
            onTracksAdded?(front)
            change.insert(.tracks)
        }
        persist("专辑入库") { db in
            if isNewAlbum {
                try self.prependAlbum(album, in: db)
            } else if change.contains(.albums) {
                // 已经在库里那张只补了封面 / 补了添加时间，位置不动。
                // 用内存里那一份（封面可能刚被 `copy` 换过），不是传进来的 `album`。
                if let stored = self.albumsByID[album.id] { try self.updateAlbum(stored, in: db) }
            }
            try self.moveToFront(front, of: .library, in: db)
            for track in front { try self.persistStat(id: track.id, in: db) }
        }
        notify(change)
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
        var change: LibraryChange = [.albums, .tracks]
        let pruned = pruneAfterLibraryRemoval(ids)
        change.formUnion(pruned)
        onTracksRemoved?(Array(ids))
        persist("专辑退库") { db in
            try self.pruneAlbumRows(in: db)
            try self.remove(ids, from: .library, in: db)
            try self.persistLibraryRemoval(ids, pruned, in: db)
        }
        notify(change)
    }

    /// 设置 › 高级那两条「添加与删除…」开关的**删除侧**：歌从资料库出去时，
    /// 顺手从本地播放列表 / 心水里也清掉。
    ///
    /// 只清 `.local` 播放列表：音源歌单与账号歌单是只读镜像，本地删一首下次同步就回来了，
    /// 清了反而是「看起来生效、其实没有」。开关关着时两边互不相干（Music 同）。
    ///
    /// 返回值是**真被动到的那几位**，交给调用方并进它自己那一次细出口：
    /// 两条开关都关着时这里其实什么都没做，不该让播放列表页与心水页跟着醒一次。
    @discardableResult
    private func pruneAfterLibraryRemoval(_ ids: Set<String>) -> LibraryChange {
        var change: LibraryChange = []
        // 勾选状态不受那两条开关管：歌都不在资料库里了，留着「它没勾」这条记录
        // 只会在同一首歌被重新加进来时把上次的取消勾选带回来。
        if !uncheckedTrackIDs.isDisjoint(with: ids) {
            uncheckedTrackIDs.subtract(ids)
            change.insert(.checkmarks)
        }
        let values = AppSettings.shared.values
        if values.syncPlaylistSongsWithLibrary {
            for index in playlists.indices where playlists[index].origin == .local {
                let before = playlists[index].tracks.count
                playlists[index].tracks.removeAll { ids.contains($0.id) }
                if playlists[index].tracks.count != before { change.insert(.playlists) }
            }
        }
        if values.syncFavoriteSongsWithLibrary {
            if !favoriteTrackIDs.isDisjoint(with: ids) {
                favoriteTracks.removeAll { ids.contains($0.id) }
                favoriteTrackIDs.subtract(ids)
                change.insert(.favorites)
            }
        }
        return change
    }

    /// 歌移出资料库后，若所属专辑在资料库里已经没有任何歌了，连带把这张空碟也移出资料库，
    /// 避免资料库留下幽灵专辑（无曲目占位、或者本地导入后删除了所有曲目残留的空碟）。
    @discardableResult
    private func pruneEmptyAlbums() -> LibraryChange {
        let emptyAlbums = libraryAlbums.filter { album in
            !libraryTracks.contains { Self.belongs($0, to: album) }
        }
        guard !emptyAlbums.isEmpty else { return [] }
        let emptyIDs = Set(emptyAlbums.map(\.id))
        libraryAlbumIDs.subtract(emptyIDs)
        libraryAlbums.removeAll { emptyIDs.contains($0.id) }
        for id in emptyIDs {
            albumAddedAt.removeValue(forKey: id)
        }
        rebuildAlbumIndex()
        return .albums
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
        persist("新建列表") { db in
            try db.run("UPDATE playlist SET position = position + 1")
            try self.persistPlaylistRow(playlist, position: 0, in: db)
            try self.persistPlaylistTracks(playlist, in: db)
        }
        notify(.playlists)
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
        let renamed = playlists[index]
        persist("列表改名") { db in
            try db.run("UPDATE playlist SET name = ? WHERE id = ?", [trimmed, id])
            // 这一路没走 `persistPlaylistRow`（改名只该动一列，不该把 position 之类
            // 一起重写），所以索引要在这儿自己补一下。
            try self.searchIndex.upsert(.playlist, id: id, name: trimmed,
                                        artist: renamed.source?.creatorName ?? "", in: db)
        }
        notify(.playlists)
    }

    /// 从资料库里删掉一份列表。账号同步来的要记一笔，否则下次同步又冒出来。
    func deletePlaylist(id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let wasAccountPlaylist = playlists[index].origin == .account
        if wasAccountPlaylist {
            dismissedAccountPlaylistIDs.insert(id)
        }
        playlists.remove(at: index)
        persist("删列表") { db in
            if wasAccountPlaylist {
                try self.persistIDSet("dismissed_account_playlist", adding: [id], removing: [],
                                      in: db)
            }
            // `playlist_track` 那边由 `ON DELETE CASCADE` 跟着走。索引没有外键，要自己撤。
            try db.run("DELETE FROM playlist WHERE id = ?", [id])
            try self.searchIndex.delete(.playlist, id: id, in: db)
        }
        notify(.playlists)
    }

    /// 往本地列表里加歌。Music 允许同一首在一份列表里出现多次，这里跟它一致，不去重。
    func addTracks(_ tracks: [Track], toPlaylist id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }),
              playlists[index].isEditable, !tracks.isEmpty else { return }
        playlists[index].tracks.append(contentsOf: tracks)
        var change: LibraryChange = .playlists
        var front: [Track] = []
        // 设置 › 高级 ›「添加与删除播放列表歌曲」：加进本地列表的歌同时进资料库
        //（Music 那条开关的正向语义）。关着时列表与资料库互不相干。
        if AppSettings.shared.values.syncPlaylistSongsWithLibrary {
            var added: [Track] = []
            for track in tracks.reversed() where insert(track) { added.append(track) }
            if !added.isEmpty {
                front = added.reversed()
                onTracksAdded?(front)
                change.insert(.tracks)
            }
        }
        persist("列表加歌") { db in
            // 追加到末尾，已有的行一条不动。
            try self.appendPlaylistTracks(tracks, to: id, in: db)
            try self.moveToFront(front, of: .library, in: db)
            for track in front { try self.persistStat(id: track.id, in: db) }
        }
        notify(change)
    }

    func removeTracks(at offsets: IndexSet, fromPlaylist id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }),
              playlists[index].isEditable else { return }
        playlists[index].tracks.remove(atOffsets: offsets)
        let updated = playlists[index]
        persist("列表删歌") { try self.persistPlaylistTracks(updated, in: $0) }
        notify(.playlists)
    }

    func moveTracks(fromOffsets offsets: IndexSet, toOffset destination: Int, inPlaylist id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }),
              playlists[index].isEditable else { return }
        playlists[index].tracks.move(fromOffsets: offsets, toOffset: destination)
        // 重排没有增量写法——一次任意置换的最小描述就是新顺序本身，见 §position。
        // 重写的范围是**这一份列表**，不是整张 `playlist_track`。
        let updated = playlists[index]
        persist("列表重排") { try self.persistPlaylistTracks(updated, in: $0) }
        notify(.playlists)
    }

    // MARK: 音源歌单进资料库

    func isPlaylistInLibrary(_ playlist: Playlist) -> Bool {
        playlists.contains { $0.id == playlist.id }
    }

    func addPlaylistToLibrary(_ playlist: Playlist) {
        guard !isPlaylistInLibrary(playlist) else { return }
        dismissedAccountPlaylistIDs.remove(playlist.id)
        playlists.insert(.from(playlist, origin: .added), at: 0)
        let added = playlists[0]
        persist("音源歌单入库") { db in
            try self.persistIDSet("dismissed_account_playlist", adding: [],
                                  removing: [playlist.id], in: db)
            try db.run("UPDATE playlist SET position = position + 1")
            try self.persistPlaylistRow(added, position: 0, in: db)
        }
        notify(.playlists)
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
        // 任意变换，除了整份镜像没有别的忠实做法（见 §position）。代价是歌单份数，
        // 不是资料库大小；而且每份的曲目「顺序没变就一行不写」。
        persist("整批改列表") { db in
            try self.persistAllPlaylists(in: db)
            // `syncAccountPlaylists` 的 `resetDismissed` 会在调这个函数之前减掉一批。
            try self.persistDismissedPlaylists(in: db)
        }
        notify(.playlists)
    }

    // MARK: - 心水与评分

    func isFavorite(_ track: Track) -> Bool {
        favoriteTrackIDs.contains(track.id)
    }

    func toggleFavorite(_ track: Track) {
        var nowFavorite = true
        if let index = favoriteTracks.firstIndex(where: { $0.id == track.id }) {
            favoriteTracks.remove(at: index)
            favoriteTrackIDs.remove(track.id)
            nowFavorite = false
        } else {
            favoriteTracks.insert(track, at: 0)
            favoriteTrackIDs.insert(track.id)
            // 设置 › 高级 ›「添加与删除喜爱歌曲」：心水的歌同时进资料库。
            // 只有加心水这一侧——取消心水不把歌从资料库里删（Music 同：那是两件事，
            // 反向那条由 `pruneAfterLibraryRemoval` 从资料库那头做）。
            if AppSettings.shared.values.syncFavoriteSongsWithLibrary { addToLibrary(track) }
        }
        // 入库那一笔由 `addToLibrary` 自己落（它有自己的事务），这里只管心水这一张表。
        persist("心水") { db in
            if nowFavorite {
                try self.moveToFront([track], of: .favorite, in: db)
            } else {
                try self.remove([track.id], from: .favorite, in: db)
            }
        }
        // 入库那一声由 `addToLibrary` 自己发（它发的是 `.tracks`），这里只报心水这一位。
        notify(.favorites)
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
        let added = updated.subtracting(uncheckedTrackIDs)
        let removed = uncheckedTrackIDs.subtracting(updated)
        uncheckedTrackIDs = updated
        persist("勾选") { db in
            try self.persistIDSet("unchecked_track", adding: added, removing: removed, in: db)
        }
        notify(.checkmarks)
    }

    // MARK: - 本地文件失联（spec §10.1）

    /// 这条本地曲目**已经发现**文件不在下载索引记着的位置上了。
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
        notify(.fileMissing)
    }

    /// 撤标记：重新指路成功、或者批量查找把它找回来了。
    func clearFileMissing(_ trackID: String) {
        guard missingFileTrackIDs.contains(trackID) else { return }
        objectWillChange.send()
        missingFileTrackIDs.remove(trackID)
        notify(.fileMissing)
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
    ///
    /// **路径从哪儿来**：`downloads` 一处（主库 `local_file` 表的内存那一份）。
    /// 收成参数而不是让 store 长一个字段：这是全 App 唯一需要问下载索引的读点，
    /// 挂成可选闭包的话忘了接线就静默返回空清单——那正是这条链最不该有的失败形状。
    /// 返回值捎上 URL，调用方（`MissingFileLocator` 批量查找那一趟）不用再问一遍。
    @discardableResult
    func missingLocalTracks(downloads: DownloadStore) -> [(track: Track, url: URL)] {
        let fm = FileManager.default
        var missing: Set<String> = []
        var result: [(track: Track, url: URL)] = []
        // 卷可达性缓存，键是上级目录。一张碟几十首歌都在同一个目录下，逐首向上走一遍是白花钱；
        // 更要紧的是**同一次扫描里卷的状态必须前后一致**：真在扫的过程中被拔盘，
        // 缓存能保证这一轮要么整批跳过、要么整批判，不会一半标一半不标。
        var volumeReachable: [String: Bool] = [:]
        for track in localTracks {
            guard let url = downloads.absoluteURL(for: track.id) else { continue }
            let parent = url.deletingLastPathComponent().path
            let reachable = volumeReachable[parent]
                ?? Self.isVolumeReachable(for: url, fileManager: fm)
            volumeReachable[parent] = reachable
            guard reachable else {
                // 卷保护：维持原状——之前标过的继续标着（也继续算进「缺少的文件」那份清单，
                // 它本来就是标记的镜像），没标过的不新标。
                if missingFileTrackIDs.contains(track.id) {
                    if missing.insert(track.id).inserted { result.append((track, url)) }
                }
                continue
            }
            if !fm.fileExists(atPath: url.path) {
                if missing.insert(track.id).inserted { result.append((track, url)) }
            }
        }
        if missing != missingFileTrackIDs {
            objectWillChange.send()
            missingFileTrackIDs = missing
            notify(.fileMissing)
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

    /// 按 id 改一条曲目的字段。**五处数组 + 每份本地播放列表**都要改：
    /// `libraryTracks`、`favoriteTracks`、`recentTracks`、最近播放台账里的散曲格
    /// （`recentContainers` 的`.track` 那一 case），以及每份播放列表的`tracks`。
    /// 曲目是**值类型、各存各的副本**，漏掉哪一处，那一处的行就还是旧值——
    /// 表格里刚改好的歌，切到「最近播放」又是老标题，重新指过路的还会再次播放失败。
    ///
    /// 改的是数组的**整份替换**而不是逐条下标赋值：`@Published` 的 willSet 会在每次
    /// 下标赋值时多留一份数组引用，写时复制就真的复制了（理由同 `updatePlaylists`）。
    ///
    /// `transform` 改完与原值相等的那一份不动（也就不发`objectWillChange`、不排落盘）：
    /// 「显示简介」面板提交时五个字段里往往只动了一个，其余四个原样写回来。
    ///
    /// 返回值：真改了任何一处没有。
    @discardableResult
    func updateTrack(id: String, transform: (inout Track) -> Void) -> Bool {
        /// 改完的那一份。五处副本理应字字相同（这个函数每次都把五处一起改，就是为了这条），
        /// 所以碰上的第一份就是权威，它就是要写进 `track` 表的那一行。
        var canonical: Track?

        /// 改完返回新数组；这一份里没有要改的就返回 nil，好让调用处别去碰 `@Published`。
        func rewritten(_ tracks: [Track]) -> [Track]? {
            var changed = false
            let updated = tracks.map { track -> Track in
                guard track.id == id else { return track }
                var edited = track
                transform(&edited)
                guard edited != track else { return track }
                changed = true
                if canonical == nil { canonical = edited }
                return edited
            }
            return changed ? updated : nil
        }

        // 内存这五处照旧一起改：视图层读的是数组，一处不改那一页就还是旧值。
        if let updated = rewritten(libraryTracks) { libraryTracks = updated }
        if let updated = rewritten(favoriteTracks) { favoriteTracks = updated }
        if let updated = rewritten(recentTracks) { recentTracks = updated }
        // 第五处：台账里的散曲格。其余 case 的载荷（专辑 / 歌单 / 艺人 / 心水）
        // 不含可变的曲目字段，改不到它们头上。不补这一处的话，本地文件改名或重新指路之后，
        // 货架上那张散曲卡还是旧标题、还指着老路。
        //
        // **表那边不用管这一格**：`recent_container` 里 `.track` 只存 `ref_id`，
        // 曲目从 `track` 表取——底下那条 `persistTracks` 就把它一起改了。
        // 这是「247 份副本收成 199 行」买下来的第一笔：第五处写入点没有了。
        var workingContainers = recentContainers
        var containersChanged = false
        for index in workingContainers.indices {
            guard case .track(let stored) = workingContainers[index], stored.id == id else { continue }
            var edited = stored
            transform(&edited)
            guard edited != stored else { continue }
            workingContainers[index] = .track(edited)
            containersChanged = true
            if canonical == nil { canonical = edited }
        }
        if containersChanged { recentContainers = workingContainers }
        var workingPlaylists = playlists
        var playlistsChanged = false
        for index in workingPlaylists.indices {
            if let updated = rewritten(workingPlaylists[index].tracks) {
                workingPlaylists[index].tracks = updated
                playlistsChanged = true
            }
        }
        if playlistsChanged { playlists = workingPlaylists }

        guard let canonical else {
            // 一处都没真改（面板提交时五个字段里往往只动了一个，其余四个原样写回来）：
            // 不发通知、不落盘，与从前一字不差。
            return false
        }
        let change = relationMask(of: id)
        persist("改曲目") { db in
            // 改的可能正是艺人名（「显示简介」面板里那一栏），而资料库曲目的艺人名
            // 是艺人那一档的来源之一。改完之后老艺人可能整个没人引用了，要对一遍账。
            self.artistIndexDirty = true
            try self.persistTracks([canonical], in: db)
        }
        notify(change)
        return true
    }

    /// 这个 id 落在哪几张关系表里 → 这一次改动该叫醒哪几位。
    ///
    /// **掩码语义从「哪几个数组真变了」改成了「id 落在哪几张关系表」。** 两者等价的前提是
    /// 「同一首歌在各处的副本字字相同」——那正是 `updateTrack` 存在的理由，也是它每次都
    /// 把各处一起改的原因。于是「这一份里那条记录变了」⟺「这一份里有这条记录，
    /// 且这次改动不是空操作」，而后者调用方已经判过了（`canonical` 非 nil 才走到这儿）。
    ///
    /// 为什么值得改：曲目字段从五份副本收成了一行，「哪几个数组变了」这个问法的载体
    /// 正在消失，而「这首歌在哪几张表里」问的是同一件事，且以后不依赖内存数组还在不在。
    private func relationMask(of id: String) -> LibraryChange {
        guard let db = database?.sqlite else { return [] }
        func exists(_ sql: String) -> Bool {
            ((try? db.value(sql, [id], { $0.int(0) })) ?? 0) != 0
        }
        var change: LibraryChange = []
        if exists("SELECT EXISTS(SELECT 1 FROM library_track WHERE track_id = ?)") {
            change.insert(.tracks)
        }
        if exists("SELECT EXISTS(SELECT 1 FROM favorite_track WHERE track_id = ?)") {
            change.insert(.favorites)
        }
        if exists("SELECT EXISTS(SELECT 1 FROM playlist_track WHERE track_id = ?)") {
            change.insert(.playlists)
        }
        // 逐曲历史与台账里的散曲格合报 `.playbackStats`——那一位罩着的几份本来就是
        // 同一次记账一起动的，拆开只会逼每个消费方写两条一模一样的订阅。
        if exists("SELECT EXISTS(SELECT 1 FROM recent_track WHERE track_id = ?)")
            || exists("""
                SELECT EXISTS(SELECT 1 FROM recent_container
                              WHERE kind = 'track' AND ref_id = ?)
                """) {
            change.insert(.playbackStats)
        }
        return change
    }

    // **这里没有 `relocateLocalTrack`。** 重新指路从前要写两处（资料库四份副本里的
    // `localPath`，外加下载索引），`MissingFileLocator.relocate` 两个都调，
    // 漏一个的表现是「指完路还是播不出来」。本地性收到 `local_file` 一处之后，
    // 一次重新指路就是一次 `DownloadStore.adoptLocalFile` + 一次 `clearFileMissing`，
    // 没有第二份要同步的真相，也就没有这个函数存在的理由了。

    /// 本机有文件的那些曲目——`missingLocalTracks` 要扫的就是这一份。
    ///
    /// `SELECT … JOIN local_file`：「这首歌在本机有没有文件」只有那张表回答得了，
    /// 而 `track` 表故意不做 GC，所以掉出「最近播放」窗口、也不在资料库里的那几首
    /// 照样在。[实测 2026-09-10] 用户库里`recents` 那 101 条中有 5 条不在资料库中——
    /// 从前得把四处数组合起来再去重才能捞到它们，现在是主键天然去重的一条查询。
    ///
    /// `mv:<id>` 那些键 JOIN 不到 `track` 行（MV 与曲目共用这张表），自然被排除在外。
    private var localTracks: [Track] {
        guard let db = database?.sqlite else { return [] }
        let sql = """
            \(Self.trackSelect)
            JOIN local_file f ON f.key = track.id
            """
        return (try? db.query(sql, [], Self.decodeTrack)) ?? []
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
        let added = updated.subtracting(suggestLessTrackIDs)
        let removed = suggestLessTrackIDs.subtracting(updated)
        suggestLessTrackIDs = updated
        persist("减少推荐") { db in
            try self.persistIDSet("suggest_less_track", adding: added, removing: removed, in: db)
        }
        notify(.suggestLess)
    }

    func setSuggestedLessArtist(_ artistID: String, _ on: Bool) {
        let updated = on ? suggestLessArtistIDs.union([artistID])
                         : suggestLessArtistIDs.subtracting([artistID])
        guard updated != suggestLessArtistIDs else { return }
        objectWillChange.send()
        suggestLessArtistIDs = updated
        persist("减少推荐（艺人）") { db in
            try self.persistIDSet("suggest_less_artist", adding: on ? [artistID] : [],
                                  removing: on ? [] : [artistID], in: db)
        }
        notify(.suggestLess)
    }

    func isFavoriteAlbum(_ album: Album) -> Bool {
        favoriteAlbumIDs.contains(album.id)
    }

    func toggleFavoriteAlbum(_ album: Album) {
        let nowFavorite = !favoriteAlbumIDs.contains(album.id)
        if nowFavorite {
            favoriteAlbumIDs.insert(album.id)
        } else {
            favoriteAlbumIDs.remove(album.id)
        }
        persist("喜爱专辑") { db in
            try self.persistIDSet("favorite_album", adding: nowFavorite ? [album.id] : [],
                                  removing: nowFavorite ? [] : [album.id], in: db)
        }
        notify(.favoriteAlbums)
    }

    /// 收藏这位艺人。与专辑的「喜爱」同一个性质：只是一个本地标记，
    /// 不像「添加到资料库」那样往库里塞内容。
    func isFavoriteArtist(_ artist: Artist) -> Bool {
        favoriteArtistIDs.contains(artist.id)
    }

    func toggleFavoriteArtist(_ artist: Artist) {
        let nowFavorite = !favoriteArtistIDs.contains(artist.id)
        if nowFavorite {
            favoriteArtistIDs.insert(artist.id)
        } else {
            favoriteArtistIDs.remove(artist.id)
        }
        persist("收藏艺人") { db in
            try self.persistIDSet("favorite_artist", adding: nowFavorite ? [artist.id] : [],
                                  removing: nowFavorite ? [] : [artist.id], in: db)
        }
        notify(.favoriteArtists)
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
        persist("星级") { try self.persistRating(id: id, in: $0) }
        notify(.ratings)
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
        // 按 id 挂的一行账，单行 UPSERT（清掉的那两格写回 0 / NULL）。
        persist("重设播放次数") { try self.persistStat(id: id, in: $0) }
        notify(.playbackStats)
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
        persist("跳过记账") { try self.persistStat(id: track.id, in: $0) }
        notify(.playbackStats)
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
    ///
    /// **这两个重载不再是 `private`。** `album_key` 现在是一个**落盘的列**
    /// （`track.album_key` / `library_album.album_key`，见 `AmberDatabase` 的 schema），
    /// 算它的函数就不再是 `LibraryStore` 的实现细节。`AmberDatabaseMigration` 必须调
    /// 同一个它——自己抄一份等于给一个已经持久化的键制造第二份真相，
    /// 两边哪天漂移了（归一化口径变了、键里多带一段）专辑会静默认不出来，不报错。
    ///
    /// `normalizedForMatching` 与 `belongs(_:to:)` 照旧 `private`：前者只有这里调，
    /// 后者收的是内存模型 `Track`，迁移器解的是旧存档的 `LegacyTrack`，够不着也不该够着。
    static func fallbackKey(name: String, artist: String,
                            kind: ProviderKind, isLocal: Bool) -> String {
        [normalizedForMatching(name), normalizedForMatching(artist),
         kind.rawValue, isLocal ? "1" : "0"].joined(separator: "\u{1}")
    }

    static func fallbackKey(for track: Track) -> String {
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
    ///
    /// `container` 是这一首落进的格子（在哪儿听的，见`RecentContainer`）：非 nil 时
    /// 按 `container.id` 去重、顶到台账最前。默认值 nil 是**给测试用的**——
    /// 现有那几处调用点不关心台账，生产侧只有 `AppState` 那一个调用点，且永远传非 nil。
    /// 顶上那条「使用听歌历史记录」的 guard 已经把台账一并罩住，不加第二条开关。
    func noteStarted(_ track: Track, container: RecentContainer? = nil) {
        guard AppSettings.shared.values.useListeningHistory else { return }
        var containersChanged = false
        recentTracks.removeAll { $0.id == track.id }
        recentTracks.insert(track, at: 0)
        if recentTracks.count > 200 {
            recentTracks = Array(recentTracks.prefix(200))
        }
        // 已经是台账首位那一格＝同一份歌单/专辑里接着听：整份数组不会有任何变化，
        // 却照样会发一次 `@Published`，主页目录页于是每首歌重灌一遍快照
        // （悬浮态被清、货架横向位置回到最左）。没变就不动。
        if let container, recentContainers.first != container {
            // 先在本地数组上改完再**整份替换**（同 `updateTrack`）：`@Published` 每次
            // 原地改动都发一声 willSet，逐条改的话一次记账要发三声，
            // 订阅方（主页目录页）就得连着重灌三遍快照。
            var updated = recentContainers
            updated.removeAll { $0.id == container.id }
            updated.insert(container, at: 0)
            if updated.count > Self.recentContainerLimit {
                updated = Array(updated.prefix(Self.recentContainerLimit))
            }
            recentContainers = updated
            containersChanged = true
        }
        persist("起播记账") { db in
            // 逐曲历史：把这一首挪到第一格，再截到 200。
            try self.moveToFront([track], of: .recent, in: db)
            try self.cap(.recent, to: 200, in: db)
            // 台账没变就一个字都不写（同一份歌单接着听是常态）。
            if containersChanged { try self.persistRecentContainers(in: db) }
        }
        notify(.playbackStats)
    }

    /// 台账上限。逐曲历史那份是 200：两个粒度各有各的窗口，见 `recentContainers`。
    static let recentContainerLimit = 50

    /// 按去重键收一遍，靠前（更近）的那条赢。
    static func deduplicated(_ containers: [RecentContainer]) -> [RecentContainer] {
        var seen = Set<String>()
        return containers.filter { seen.insert($0.id).inserted }
    }

    /// 首次升级时的回灌：旧存档只有逐曲历史，按**老的展示规则**（原
    /// `CatalogFeedModel.recentGroups`：`albumId` 去重、没有专辑的各成一格）现算一份台账，
    /// 货架不至于是空的。老历史里没有来源信息，回灌出来的只可能是专辑卡 / 歌单卡 / 散曲卡——
    /// 这是明知的取舍，口径就是「已有历史照老规则保留，不清空」。
    static func backfilledContainers(from tracks: [Track]) -> [RecentContainer] {
        var seen = Set<String>()
        var result: [RecentContainer] = []
        for track in tracks {
            // source 传 nil ＝ 走 `resolve` 的回落那一路，与老规则逐字等价。
            let container = RecentContainer.resolve(track: track, source: nil)
            guard seen.insert(container.id).inserted else { continue }
            result.append(container)
            if result.count == recentContainerLimit { break }
        }
        return result
    }

    /// 一首歌**播到了结尾**：播放次数 +1、记下这一刻。由播放器在切下一首之前调，
    /// 单曲循环每绕一遍算一次（见 `PlayerController.handleTrackEnded`）。
    func notePlayed(_ track: Track) {
        guard AppSettings.shared.values.useListeningHistory else { return }
        playCounts[track.id, default: 0] += 1
        lastPlayedAt[track.id] = Date()
        // **整个改造最核心的那一下**：一次记账 = 一条单行 UPSERT。
        // 从前这里是「整份资料库重新编码一遍写盘」，而起播（`noteStarted`）与曲末
        //（这里）是同一次播放的两笔账、中间隔着一整首歌——500 ms 防抖合并不了它们，
        // 于是每首歌两次整份重写。
        persist("播放记账") { try self.persistStat(id: track.id, in: $0) }
        notify(.playbackStats)
    }

    // MARK: - 载入

    /// 载入成功了没有。
    ///
    /// **没成功就一个字都不许往回写。** 写入全是「按内存现值镜像」，而载入失败时内存
    /// 是空的——一次 `updatePlaylists` 就能把 `playlist` 表整个清空。
    /// 这一位是「读不出来永远不能变成写空的」在运行期这一侧的落点
    ///（建库那一侧的落点在 `AmberDatabaseMigration`）。
    private var isLoaded = false

    /// 启动时把主库读进内存那几份 `@Published`。
    private func load() {
        guard let db = database?.sqlite else { return }
        do {
            try loadFromDatabase(db)
        } catch {
            NSLog("[LibraryStore] 读库失败，这一程只读不写（库里那份一个字没动）：%@",
                  String(describing: error))
        }
    }

    /// 一趟 SELECT 填满内存模型。
    ///
    /// **先全读进局部变量，最后一次性赋值。** 读到一半抛错时一个属性都不许动过——
    /// 半份内存模型会被随后的任何一次改动当成真值镜像回表里。
    private func loadFromDatabase(_ db: SQLiteDatabase) throws {
        // 曲目池：五张关系表存的都是 id，行本身只有这一份（原来是摊在五处的完整副本）。
        var pool: [String: Track] = [:]
        for track in try db.query(Self.trackSelect, [], { Self.decodeTrack($0) }) {
            pool[track.id] = track
        }
        /// 关系表 → 曲目数组。取不到行的 id 直接跳过：五张表都对 `track(id)` 有外键，
        /// 走到这一步只可能是有人拿 `sqlite3` 手工动过库。
        func ordered(_ table: String) throws -> [Track] {
            try db.query("SELECT track_id FROM \(table) ORDER BY position", [], { $0.text(0) })
                .compactMap { pool[$0] }
        }
        let loadedLibraryTracks = try ordered("library_track")
        let loadedFavoriteTracks = try ordered("favorite_track")
        let loadedRecentTracks = try ordered("recent_track")

        var loadedAlbums: [Album] = []
        var loadedAlbumAddedAt: [String: Date] = [:]
        for row in try db.query(Self.albumSelect, [], { Self.decodeAlbum($0) }) {
            loadedAlbums.append(row.album)
            // 缺键回落（扫碟内曲目 addedAt 的最大值）在**迁移那一刻**算好写死了，
            // 运行期不再有那个每问一次就全表扫一遍的 O(n) 兜底。
            if let stamped = row.addedAt { loadedAlbumAddedAt[row.album.id] = stamped }
        }

        var playlistTracks: [String: [Track]] = [:]
        for (id, trackID) in try db.query(
            "SELECT playlist_id, track_id FROM playlist_track ORDER BY playlist_id, position", [],
            { ($0.text(0), $0.text(1)) }) {
            guard let track = pool[trackID] else { continue }
            playlistTracks[id, default: []].append(track)
        }
        let loadedPlaylists = try db.query(Self.playlistSelect, [], {
            Self.decodePlaylist($0)
        }).map { playlist -> LibraryPlaylist in
            var result = playlist
            result.tracks = playlistTracks[playlist.id] ?? []
            return result
        }

        // 台账：再按去重键收一遍。库里那份**不会**有重复（`dedupe_key` 上有 UNIQUE），
        // 收这一遍是为了与从前逐字同解——这条规则本身还要管旧存档迁过来的那一份。
        let loadedContainers = Self.deduplicated(
            try db.query("SELECT kind, ref_id, payload FROM recent_container ORDER BY position",
                         [], { ($0.text(0), $0.optText(1), $0.optText(2)) })
                .compactMap { RecentContainer.make(kind: $0.0, refID: $0.1, payload: $0.2,
                                                   track: { pool[$0] }) })

        var loadedPlayCounts: [String: Int] = [:]
        var loadedSkipCounts: [String: Int] = [:]
        var loadedAddedAt: [String: Date] = [:]
        var loadedLastPlayedAt: [String: Date] = [:]
        var loadedLastSkippedAt: [String: Date] = [:]
        for stat in try db.query("""
            SELECT track_id, play_count, skip_count, added_at, last_played_at, last_skipped_at
            FROM track_stat
            """, [], { (id: $0.text(0), play: Int($0.int(1)), skip: Int($0.int(2)),
                        added: $0.date(3), played: $0.date(4), skipped: $0.date(5)) }) {
            // **0 不进字典。** 从前这几本账是 `[String: Int]`，键只在真的记过一笔时才有
            //（`resetPlayCount` 是 `removeValue`，不是置 0）。表里那一行是五本账合并来的，
            // 「只记过添加时间」的曲目照样有一行、play_count 是 0。
            // 把 0 也灌进字典的话，`resetPlayCount` 的「什么都没有就别白发通知」那条 guard 会失效。
            if stat.play != 0 { loadedPlayCounts[stat.id] = stat.play }
            if stat.skip != 0 { loadedSkipCounts[stat.id] = stat.skip }
            if let value = stat.added { loadedAddedAt[stat.id] = value }
            if let value = stat.played { loadedLastPlayedAt[stat.id] = value }
            if let value = stat.skipped { loadedLastSkippedAt[stat.id] = value }
        }

        var loadedRatings: [String: Int] = [:]
        for (id, value) in try db.query("SELECT id, value FROM rating", [],
                                        { ($0.text(0), Int($0.int(1))) }) {
            loadedRatings[id] = value
        }
        func idSet(_ table: String) throws -> Set<String> {
            Set(try db.query("SELECT id FROM \(table)", [], { $0.text(0) }))
        }
        let loadedFavoriteAlbums = try idSet("favorite_album")
        let loadedFavoriteArtists = try idSet("favorite_artist")
        let loadedUnchecked = try idSet("unchecked_track")
        let loadedSuggestLessTracks = try idSet("suggest_less_track")
        let loadedSuggestLessArtists = try idSet("suggest_less_artist")
        let loadedDismissed = try idSet("dismissed_account_playlist")

        // 搜索索引那份正文指纹。放在读的这一段里：它自己也是「读完了才赋值」，
        // 而且必须在下面那次 `persist("清理幽灵碟")` 之前就绪——那一次写会去删索引行。
        try searchIndex.load(from: db)

        // ── 到这里一条 SQL 都不会再抛了，才开始动内存 ──────────────────────────────
        libraryTracks = loadedLibraryTracks
        favoriteTracks = loadedFavoriteTracks
        recentTracks = loadedRecentTracks
        libraryAlbums = loadedAlbums
        albumAddedAt = loadedAlbumAddedAt
        playlists = loadedPlaylists
        recentContainers = loadedContainers
        playCounts = loadedPlayCounts
        skipCounts = loadedSkipCounts
        addedAt = loadedAddedAt
        lastPlayedAt = loadedLastPlayedAt
        lastSkippedAt = loadedLastSkippedAt
        ratings = loadedRatings
        favoriteAlbumIDs = loadedFavoriteAlbums
        favoriteArtistIDs = loadedFavoriteArtists
        uncheckedTrackIDs = loadedUnchecked
        suggestLessTrackIDs = loadedSuggestLessTracks
        suggestLessArtistIDs = loadedSuggestLessArtists
        dismissedAccountPlaylistIDs = loadedDismissed
        libraryTrackIDs = Set(libraryTracks.map(\.id))
        libraryAlbumIDs = Set(libraryAlbums.map(\.id))
        favoriteTrackIDs = Set(favoriteTracks.map(\.id))
        isLoaded = true

        // 清理没有曲目残留的空本地专辑（导入后被删除曲目的残留）。
        //
        // **这一段留在载入路径上，没有搬去迁移器。** 计划里说把它写成迁移末尾一条
        // `DELETE … WHERE NOT EXISTS`，但那样只管得着「从 JSON 迁过来的那一刻」：
        // 库建好之后再加一张空的本地碟、退出、重开，迁移一次都不会再跑，那张幽灵碟
        // 就永远留着了（`LibraryStoreDerivedTests.testOrphanLocalAlbumPrunedOnLoad`
        // 走的正是这条路）。语义一字不改，只是顺手把表里那几行也删掉。
        let orphanLocalAlbums = libraryAlbums.filter { album in
            album.isLocal && !libraryTracks.contains { Self.belongs($0, to: album) }
        }
        if !orphanLocalAlbums.isEmpty {
            let orphanIDs = Set(orphanLocalAlbums.map(\.id))
            libraryAlbums.removeAll { orphanIDs.contains($0.id) }
            libraryAlbumIDs.subtract(orphanIDs)
            for id in orphanIDs { albumAddedAt.removeValue(forKey: id) }
            persist("清理幽灵碟") { try self.pruneAlbumRows(in: $0) }
        }

        rebuildAlbumIndex()
    }

    /// `decodeTrack` 认的那份列序，**只此一份**。
    ///
    /// `prefix` 是 SQL 里 `track` 表的别名加点（`"t."`）：连接查询里 `library_album`
    /// 有 `id`/`kind`/`artist_name` 等同名列，不加前缀 SQLite 报 ambiguous。
    /// 抄一份带前缀的常量出来是行不通的——列序与 `decodeTrack` 的序号一一对应，
    /// 两份哪天漂移半列，读出来的是「艺人名当标题」这种编译器抓不到的错。
    private static func trackColumns(prefix: String = "") -> String {
        ["id", "kind", "title", "artist_name", "artist_id", "album_name", "album_id",
         "artwork_url", "duration", "track_number", "disc_number", "media_mid",
         "lossless_available"].map { prefix + $0 }.joined(separator: ", ")
    }

    private static let trackSelect = "SELECT \(trackColumns()) FROM track"

    /// 列序就是上面那条 `SELECT` 的书写顺序（`Row` 按序号取，见它的注释）。
    ///
    /// 三态列一律走 `optInt` / `optBool`：`trackNumber` 是「音源没给」还是「第 0 首」、
    /// `losslessAvailable` 是「不知道」还是「明确不是无损」，都是两件事。
    private static func decodeTrack(_ row: Row) -> Track {
        Track(id: row.text(0),
              // 未知 rawValue 只可能来自手工改库。回落到默认音源而不是丢掉整首歌：
              // 丢掉的话这首在库里的位置会静默空一格。
              kind: ProviderKind(rawValue: row.text(1)) ?? .netease,
              title: row.text(2), artistName: row.text(3), artistId: row.optText(4),
              albumName: row.text(5), albumId: row.optText(6), artworkURL: row.optText(7),
              duration: row.double(8), trackNumber: row.optInt(9).map(Int.init),
              discNumber: row.optInt(10).map(Int.init), mediaMid: row.optText(11),
              losslessAvailable: row.optBool(12))
    }

    /// `decodeAlbum` 认的那份列序，只此一份（理由同 `trackColumns`）。
    /// 与落库那头的 `albumColumns`（`SET` 子句）不是一回事：那份不含 `id`、多一列 `album_key`。
    private static let albumSelectColumns = """
        id, kind, name, artist_name, artist_id, artwork_url, publish_date, track_count,
        description, genre, album_type, added_at
        """

    private static let albumSelect = """
        SELECT \(albumSelectColumns) FROM library_album ORDER BY position
        """

    private static func decodeAlbum(_ row: Row) -> (album: Album, addedAt: Date?) {
        (Album(id: row.text(0), kind: ProviderKind(rawValue: row.text(1)) ?? .netease,
               name: row.text(2), artistName: row.text(3), artistId: row.optText(4),
               artworkURL: row.optText(5), publishDate: row.optText(6),
               trackCount: Int(row.int(7)), description: row.optText(8),
               genre: row.optText(9), albumType: row.optText(10)),
         row.date(11))
    }

    private static let playlistSelect = """
        SELECT id, name, origin, source_json, cover_url, description, created_at, added_at
        FROM playlist ORDER BY position
        """

    /// 曲目那一格由调用方补（它们在 `playlist_track` 里，另一条 SELECT）。
    private static func decodePlaylist(_ row: Row) -> LibraryPlaylist {
        LibraryPlaylist(
            id: row.text(0), name: row.text(1),
            origin: LibraryPlaylist.Origin(rawValue: row.text(2)) ?? .local,
            // `source` 整块存 JSON：它是音源歌单的原样快照，没有任何查询按它的内部字段筛。
            source: row.optText(3).flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(Playlist.self, from: $0) },
            tracks: [], coverURL: row.optText(4), description: row.optText(5),
            createdAt: Date(timeIntervalSinceReferenceDate: row.double(6)),
            addedAt: Date(timeIntervalSinceReferenceDate: row.double(7)))
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

    /// 退出前把 wal 并回主库。
    ///
    /// **名字与全部调用点保留。** 从前它是「立刻把防抖中的那份 JSON 同步写下去」；
    /// 现在每一次改动当场落库，没有「还没写的」，剩下要收的只有 WAL 旁文件
    ///（只拷走 `.sqlite` 会拿到一份陈旧的库，见`AmberDatabase.checkpoint()`）。
    /// 测试里那几处「断言磁盘内容前先同步落一次」照旧成立，只是它现在落的是 wal。
    func flushNow() { database?.checkpoint() }

    // MARK: - 落库
    //
    // **内存那几份数组是真值，表跟着镜像。** 24 个改动点不各写各的 SQL，
    // 全部经下面这十来个助手落库——散成 24 段裸 SQL 等于给自己留 24 次
    //「忘了同步某一张表」的机会，而那一类 bug 编译器抓不到、测试也未必覆盖得全。
    //
    // ## position 列怎么处置
    //
    // **不变量只有一条：`ORDER BY position` 排出来的顺序 == 内存数组的顺序。**
    // 不保证 position 等于数组下标，也不保证连续——删除留下的空洞原样留着。
    //
    // 于是「加到最前面」是一条 `UPDATE … SET position = position + k` 加 k 条单行
    // `INSERT`，**不是**「整表删了重灌」。后者在 57 首时看不出区别，在 5 万首时就是把
    // JSON 的整份重写原样搬进 SQLite，这次改造最主要的那条动机当场作废。
    // 「删除」是一条 `DELETE … WHERE track_id = ?`，空洞不补：补空洞要重排它后面的
    // 每一行，那又是一次全表写，而空洞对「按 position 排」没有任何影响。
    //
    // 三处例外，各有各的理由，都不是偷懒：
    //
    // - **`recent_container` 整表重灌。** 它的 `position` 是`INTEGER PRIMARY KEY`
    //   （＝ rowid），逐行 +1 会在中途撞主键（0 → 1 时 1 还占着），躲开要先整体搬到负区
    //   再搬回来，两趟全表 UPDATE。而这张表由 `recentContainerLimit` 硬封在 **50 行**、
    //   只在**换容器**时才写（同一份歌单接着听一个字都不写，见 `noteStarted`），
    //   50 行重灌比两趟 UPDATE 又便宜又清楚。上限是设计的一部分，不会长。
    // - **`playlist_track` 的重排整份重写。** 一次任意置换的最小描述**就是**新顺序本身，
    //   没有增量写法。重写的范围是**那一份列表**，不是整张表；而且先比一次 id 序列，
    //   顺序没真变就一行不写（账号同步每次都会走到这儿，而它一首歌都没动过）。
    // - **`updatePlaylists` 整份镜像。** 它收的是一个任意变换（摘一批、逐条改字段、
    //   再补一批），除了整份镜像没有别的忠实做法。代价是**歌单份数**（本机 24），
    //   不是资料库大小。
    //
    // 还有一条没走的路，写在这儿免得以后被当成「忘了优化」：前插那条 `UPDATE` 是 O(n) 行写，
    // 换成「position 取 `MIN(position) - 1`」就是 O(1)。没换的理由是那样 position 会一路
    // 往负数跑、与迁移器写下的 0…n−1 不是一副面孔，而前插只发生在用户点一下的路径上
    // （起播那条热路径落在 `recent_track`，它有 200 行的硬上限）。真等到有人拿五万首的库
    // 抱怨「加一首歌要卡一下」，再换不迟——不变量是同一条，换的时候不动别的代码。

    /// 写库的唯一出口：一个事务 + 出错只记一笔。
    ///
    /// **不把错误抛给调用方**：24 个改动点全是「用户点了一下」的路径，磁盘满的时候让
    /// 点一次心水抛个异常出去，界面层没有任何有意义的处置。内存那份照常是对的，
    /// 而下面的助手全是「按内存现值整行写」、不是增量累加，所以下一次成功的写会把它补齐。
    ///
    /// `isLoaded` 那道闸见它自己的注释：**读不出来的时候一个字都不许往回写。**
    private func persist(_ label: String, _ body: (SQLiteDatabase) throws -> Void) {
        guard isLoaded, let db = database?.sqlite else { return }
        artistIndexDirty = false
        do {
            try db.transaction {
                try body(db)
                // 艺人是**派生**的，没有自己的增删改调用点，只能在动过它那两个来源
                //（`library_album` / `library_track` 的艺人名）之后对一遍账。
                // 与那次写在同一个事务里：对账写了一半失败要跟着一起回滚，
                // 否则表里留下的是「专辑回滚掉了、艺人却留着」这种半边账。
                if artistIndexDirty {
                    try searchIndex.reconcileArtists(
                        LibrarySearchIndex.derivedArtists(in: db), in: db)
                }
            }
        } catch {
            // 这一刻起表可能与内存对不上了。读路径里读表的那几条派生查询要知道
            // 这件事，否则界面当场就是错的（见 `mirrorIsStale`）。
            mirrorIsStale = true
            NSLog("[LibraryStore] %@ 落库失败：%@", label, String(describing: error))
        }
    }

    /// 主库这份镜像还信不信得过。
    ///
    /// **这是「关系查询下沉 SQL」那一步多出来的失败形状，从前没有。** 派生查询读内存数组
    /// 的年代，一次 `persist` 写失败（磁盘满、IO 错、库被谁设成只读）只丢持久化——
    /// 界面当场还是对的，助手全是「按内存现值整行写」，下一次成功的写会把它补齐。
    /// 读路径换成表之后，同一次写失败会让**这一屏当场就是错的**：刚入库的碟不出现在
    /// 艺人页上、刚删掉的歌还列着，不用等重启。写库失败从「只丢持久化」变成了
    /// 「连当场的正确性一起丢」，而 `persist` 是**吞错只记日志**的（见它自己的注释），
    /// 用户连一声都听不到。
    ///
    /// 处置：写失败就把这一位竖起来，几条读表的派生查询一律退回内存那份现算。
    /// **内存数组仍然是真值，SQL 只是加速器。**
    ///
    /// 为什么是这个处置而不是别的：
    ///
    /// - **退回内存不是为这条失败形状新造的机关。** 读路径本来就得有个兜底——库没开
    ///   起来（`AmberDatabase.shared` 失败时 `database` 就是 nil）、查询抛错，都得答得
    ///   出东西来。兜底答什么是唯一的选择题，而「答空数组」是把一次写失败放大成
    ///   「资料库看着像空的」。既然非有不可，就让它答对的那份。
    /// - **不自愈、也不重试。** 要让表追上内存，得把内存整份重新镜像一遍，而那正是
    ///   阶段 3 拆掉的「整份重写」——为一条错误路径把它请回来，等于给这次改造最主要的
    ///   那条动机留了个后门。持久化这一头的损失照旧由下一次成功的写补齐（写失败多半
    ///   不是一次性的：磁盘满就是满着），当场的正确性这一头由这一位兜住。
    /// - **不向界面报错。** 24 个改动点全是「用户点了一下」的路径，界面层对
    ///   「落库失败」没有任何有意义的处置，这一条与 `persist` 吞错是同一个判断。
    ///
    /// 于是这一步之后的口径与这一步之前逐字相同：**写库失败只丢持久化，不丢当场的正确性。**
    private(set) var mirrorIsStale = false

    /// 这一次写动没动到艺人那一档的来源（`library_album` / `library_track` 的艺人名）。
    ///
    /// 由几个落库助手自己举手（`moveToFront`/`remove` 的 `.library` 那一路、三个专辑助手、
    /// 改曲目），`persist` 在事务末尾看它决定要不要对账。**不在每一次写之后都对账**：
    /// 起播记账、播放记账、星级、勾选这些一秒钟能来好几次的路径与艺人毫无关系，
    /// 让它们每次都去扫两张表算一遍候选，是白花钱。
    private var artistIndexDirty = false

    /// 派生查询走 SQL 那条路的唯一入口：走得通答结果，走不通答 nil。
    ///
    /// 三种走不通：这一程写失败过（表可能陈旧，见 `mirrorIsStale`）、库根本没开起来、
    /// 查询抛错。调用方收到 nil 就退回内存那份现算——那份是语义的定义，SQL 是加速器。
    private func derived<T>(_ sql: String, _ binds: [any SQLBindable],
                            _ decode: (Row) -> T) -> [T]? {
        guard !mirrorIsStale, let db = database?.sqlite else { return nil }
        do {
            return try db.query(sql, binds, decode)
        } catch {
            NSLog("[LibraryStore] 派生查询失败，这一次退回内存现算：%@", String(describing: error))
            return nil
        }
    }

    // MARK: 曲目主表

    private static let trackUpsert = """
        INSERT INTO track (id, kind, title, artist_name, artist_id, album_name, album_id,
                           artwork_url, duration, track_number, disc_number, media_mid,
                           lossless_available, album_key)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          kind = excluded.kind, title = excluded.title, artist_name = excluded.artist_name,
          artist_id = excluded.artist_id, album_name = excluded.album_name,
          album_id = excluded.album_id, artwork_url = excluded.artwork_url,
          duration = excluded.duration, track_number = excluded.track_number,
          disc_number = excluded.disc_number, media_mid = excluded.media_mid,
          lossless_available = excluded.lossless_available, album_key = excluded.album_key
        """

    /// 曲目主表。**只 upsert，不删**——`track` 表故意不做 GC（见 schema 注释）：
    /// 掉出「最近播放」窗口的歌行留着，上界是「这辈子见过的曲目数」，约 200 B/行。
    ///
    /// 五张关系表都对 `track(id)` 有外键，所以**任何关系表写入之前先过这一趟**，
    /// 否则插进去的是一条外键立不住的行，当场抛。下面几个助手自己会调它，
    /// 调用点不用记这件事——这正是「把同步收在十来处」要买下的东西。
    private func persistTracks(_ tracks: [Track], in db: SQLiteDatabase) throws {
        for track in tracks {
            try db.run(Self.trackUpsert, [
                track.id, track.kind.rawValue, track.title, track.artistName, track.artistId,
                track.albumName, track.albumId, track.artworkURL, track.duration,
                track.trackNumber, track.discNumber, track.mediaMid, track.losslessAvailable,
                // 物化的 `album_key`：SQL 里不重算（`lower()` 只折 ASCII，算出来的
                // 与 Swift 算的不是一个东西，专辑归位会静默错）。
                Self.fallbackKey(for: track),
            ])
            // 搜索索引跟着走。挂在这儿而不是各个调用点上，理由与上面那段一样：
            // 这是曲目行写入的**唯一**漏斗，挂在漏斗上就不可能漏掉某一条路。
            // 正文没变时 `upsert` 一条语句都不发，所以起播、列表重写这些常路是白走。
            try searchIndex.upsert(.track, id: track.id, name: track.title,
                                   artist: track.artistName, album: track.albumName, in: db)
        }
    }

    // MARK: 三张有序关系表

    /// 原来是三份数组的那三张表。
    private enum TrackRelation: String {
        case library = "library_track"
        case favorite = "favorite_track"
        case recent = "recent_track"
    }

    /// 把这几条挪到最前面（不在表里的就是纯粹的前插）。见上面 §position。
    ///
    /// `tracks` 的顺序就是它们在数组最前面的顺序。先逐条删一次是为了让这个助手
    /// **幂等**：`noteStarted` 要的正是「已经在里面的那首挪到第一格」。
    private func moveToFront(_ tracks: [Track], of relation: TrackRelation,
                             in db: SQLiteDatabase) throws {
        guard !tracks.isEmpty else { return }
        // 资料库曲目是艺人的第二个来源（第一个是入库专辑），动了它就要对一遍艺人的账。
        if relation == .library { artistIndexDirty = true }
        try persistTracks(tracks, in: db)
        let deleteSQL = "DELETE FROM \(relation.rawValue) WHERE track_id = ?"
        for track in tracks { try db.run(deleteSQL, [track.id]) }
        try db.run("UPDATE \(relation.rawValue) SET position = position + ?", [tracks.count])
        let insertSQL = "INSERT INTO \(relation.rawValue) (track_id, position) VALUES (?,?)"
        for (offset, track) in tracks.enumerated() { try db.run(insertSQL, [track.id, offset]) }
    }

    private func remove(_ ids: some Sequence<String>, from relation: TrackRelation,
                        in db: SQLiteDatabase) throws {
        if relation == .library { artistIndexDirty = true }
        let sql = "DELETE FROM \(relation.rawValue) WHERE track_id = ?"
        for id in ids { try db.run(sql, [id]) }
        // 索引里那条曲目**不删**：`track` 表故意不做 GC，退库只是把它从 `library_track`
        // 里摘掉，行还在。索引与 `track` 表一一对应，跟着摘反而对不上了——
        // 而多出来的 id 不会凭空多出一行，七处搜索筛的是各自手里那份数组。
    }

    /// 截顶：只留最前面 `limit` 条。
    ///
    /// 用 OFFSET 找到第 `limit` 条的 position 再删它后面的——position 允许有空洞
    /// （删除不补洞，见 §position），所以**不能**写成 `WHERE position >= limit`。
    /// 行数不足时子查询返回 NULL，`position > NULL` 求值是 NULL，一行都不删。
    private func cap(_ relation: TrackRelation, to limit: Int, in db: SQLiteDatabase) throws {
        try db.run("""
            DELETE FROM \(relation.rawValue) WHERE position > (
              SELECT position FROM \(relation.rawValue) ORDER BY position LIMIT 1 OFFSET ?
            )
            """, [limit - 1])
    }

    // MARK: 资料库专辑

    private static let albumColumns = """
        kind = ?, name = ?, artist_name = ?, artist_id = ?, artwork_url = ?, publish_date = ?,
        track_count = ?, description = ?, genre = ?, album_type = ?, added_at = ?, album_key = ?
        """

    private func albumBinds(_ album: Album) -> [any SQLBindable] {
        [album.kind.rawValue, album.name, album.artistName, album.artistId, album.artworkURL,
         album.publishDate, album.trackCount, album.description, album.genre, album.albumType,
         albumAddedAt[album.id],
         Self.fallbackKey(name: album.name, artist: album.artistName,
                          kind: album.kind, isLocal: album.isLocal)]
    }

    /// 新入库的一张碟：整表让一格，再插一行。
    private func prependAlbum(_ album: Album, in db: SQLiteDatabase) throws {
        artistIndexDirty = true
        try db.run("UPDATE library_album SET position = position + 1")
        try db.run("""
            INSERT INTO library_album (id, kind, name, artist_name, artist_id, artwork_url,
                                       publish_date, track_count, description, genre, album_type,
                                       added_at, album_key, position)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,0)
            """, [album.id] + albumBinds(album))
        try searchIndex.upsert(.album, id: album.id, name: album.name,
                               artist: album.artistName, in: db)
    }

    /// 已经在库里那张：只按内存现值改字段，**position 一格不动**
    ///（用户改过的评分、喜爱都挂在原条目上，位置也是原来的位置）。
    private func updateAlbum(_ album: Album, in db: SQLiteDatabase) throws {
        artistIndexDirty = true
        try db.run("UPDATE library_album SET \(Self.albumColumns) WHERE id = ?",
                   albumBinds(album) + [album.id])
        try searchIndex.upsert(.album, id: album.id, name: album.name,
                               artist: album.artistName, in: db)
    }

    /// 把表里已经不在 `libraryAlbums` 里的行删掉（退库、清空碟、载入时清幽灵碟共用）。
    ///
    /// 不写成 `DELETE … WHERE id NOT IN (…)`：那个 IN 列表的长度是资料库里碟的张数。
    /// 先读一遍 id（只有一列、张数级别）再逐条删，删的条数才是真正变了的那几条。
    private func pruneAlbumRows(in db: SQLiteDatabase) throws {
        artistIndexDirty = true
        let alive = Set(libraryAlbums.map(\.id))
        for id in try db.query("SELECT id FROM library_album", [], { $0.text(0) })
        where !alive.contains(id) {
            try db.run("DELETE FROM library_album WHERE id = ?", [id])
            // 专辑与索引里那一行是一一对应的，摘掉一张碟就要撤掉它那一条
            //（曲目那边不是这样，见 `remove(_:from:in:)`）。
            try searchIndex.delete(.album, id: id, in: db)
        }
    }

    // MARK: 播放列表

    private static let playlistUpsert = """
        INSERT INTO playlist (id, name, origin, source_json, cover_url, description,
                              created_at, added_at, position)
        VALUES (?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          name = excluded.name, origin = excluded.origin, source_json = excluded.source_json,
          cover_url = excluded.cover_url, description = excluded.description,
          created_at = excluded.created_at, added_at = excluded.added_at,
          position = excluded.position
        """

    /// 一份列表的表头（不含曲目）。
    private func persistPlaylistRow(_ playlist: LibraryPlaylist, position: Int,
                                    in db: SQLiteDatabase) throws {
        let sourceJSON = playlist.source
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        try db.run(Self.playlistUpsert, [
            playlist.id, playlist.name, playlist.origin.rawValue, sourceJSON,
            playlist.coverURL, playlist.description, playlist.createdAt, playlist.addedAt,
            position,
        ])
        // 索引里歌单那一行的 `artist` 列放的是**创建者**（本地自建列表没有，写空串）——
        // 与「歌单页搜索匹配歌单名与创建者名」那条既有规则一致。
        try searchIndex.upsert(.playlist, id: playlist.id, name: playlist.name,
                               artist: playlist.source?.creatorName ?? "", in: db)
    }

    /// 一份列表的曲目，整份重写。
    ///
    /// **顺序真变了才写**：先把表里那份 id 序列读出来比一比。账号同步每次都会走整份镜像，
    /// 而它一首歌都没动过——不比这一下，每次同步都要把每份本地列表的曲目全重灌一遍。
    private func persistPlaylistTracks(_ playlist: LibraryPlaylist,
                                       in db: SQLiteDatabase) throws {
        let existing = try db.query(
            "SELECT track_id FROM playlist_track WHERE playlist_id = ? ORDER BY position",
            [playlist.id], { $0.text(0) })
        guard existing != playlist.tracks.map(\.id) else { return }
        try persistTracks(playlist.tracks, in: db)
        try db.run("DELETE FROM playlist_track WHERE playlist_id = ?", [playlist.id])
        let sql = "INSERT INTO playlist_track (playlist_id, track_id, position) VALUES (?,?,?)"
        // 主键是 (playlist_id, position) **不是** (playlist_id, track_id)：
        // Music 允许同一首歌在一份列表里出现多次，`addTracks` 明写不去重。
        for (position, track) in playlist.tracks.enumerated() {
            try db.run(sql, [playlist.id, track.id, position])
        }
    }

    /// 追加到一份列表末尾：已有的行一条不动。
    ///
    /// 与上面那个整份重写分开，就为了这一条常路——往一份几千首的列表里加一首歌，
    /// 不该把那几千行重灌一遍。
    private func appendPlaylistTracks(_ tracks: [Track], to id: String,
                                      in db: SQLiteDatabase) throws {
        guard !tracks.isEmpty else { return }
        try persistTracks(tracks, in: db)
        let last = try db.value(
            "SELECT IFNULL(MAX(position), -1) FROM playlist_track WHERE playlist_id = ?",
            [id], { Int($0.int(0)) }) ?? -1
        let sql = "INSERT INTO playlist_track (playlist_id, track_id, position) VALUES (?,?,?)"
        for (offset, track) in tracks.enumerated() {
            try db.run(sql, [id, track.id, last + 1 + offset])
        }
    }

    /// 整份镜像（表头 + 每份的曲目 + 摘掉数组里已经没有的）。
    /// 只给 `updatePlaylists` 用，理由见 §position。
    private func persistAllPlaylists(in db: SQLiteDatabase) throws {
        let alive = Set(playlists.map(\.id))
        for id in try db.query("SELECT id FROM playlist", [], { $0.text(0) })
        where !alive.contains(id) {
            // `playlist_track` 那边由 `ON DELETE CASCADE` 跟着走（`foreign_keys` 是开着的）。
            // 索引没有外键，要自己撤。
            try db.run("DELETE FROM playlist WHERE id = ?", [id])
            try searchIndex.delete(.playlist, id: id, in: db)
        }
        for (position, playlist) in playlists.enumerated() {
            try persistPlaylistRow(playlist, position: position, in: db)
            try persistPlaylistTracks(playlist, in: db)
        }
    }

    // MARK: 最近播放台账

    /// 台账整表重灌。上限 50、只在换容器时写，理由见 §position。
    private func persistRecentContainers(in db: SQLiteDatabase) throws {
        try db.run("DELETE FROM recent_container")
        let sql = """
            INSERT INTO recent_container (position, dedupe_key, kind, ref_id, payload)
            VALUES (?,?,?,?,?)
            """
        for (position, container) in recentContainers.enumerated() {
            // `.track` 那一格只落 id，曲目本身从 `track` 表取——所以那行得先在。
            // 台账里的散曲**不一定**在任何一张关系表里（听过一首没入库的散曲就是这样），
            // 少了这一步，重开之后那张卡会整个消失。
            if case .track(let track) = container { try persistTracks([track], in: db) }
            let row = container.storageRow
            try db.run(sql, [position, container.id, row.kind, row.refID, row.payload])
        }
    }

    // MARK: 按 id 挂的账

    /// 一首歌的播放统计，**一条单行 UPSERT**。
    ///
    /// 这是整个改造最核心的那一下：从前 `notePlayed` 一次记账要把整份资料库重编码
    /// 一遍写盘，而起播与曲末是同一次播放的两笔账、中间隔着一整首歌，500 ms 防抖
    /// 合并不了。现在是一行。
    ///
    /// 写的是**内存现值**而不是 `play_count = play_count + 1`：内存那份才是真值，
    /// 而且这样这个助手对四个调用点（入库记添加时间、曲末 +1、跳过 +1、重设次数）
    /// 是同一条语句，还顺手把一行漂了的账改回来。
    ///
    /// 这几本账**故意没有外键**：`lastPlayedAt` 的键数远多于资料库曲目数
    /// （听过但没入库的、入库后又移出的都在里面），「账按 id 记，与在不在资料库里无关」
    /// 是现有语义。
    private func persistStat(id: String, in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO track_stat (track_id, play_count, skip_count, added_at,
                                    last_played_at, last_skipped_at)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(track_id) DO UPDATE SET
              play_count = excluded.play_count, skip_count = excluded.skip_count,
              added_at = excluded.added_at, last_played_at = excluded.last_played_at,
              last_skipped_at = excluded.last_skipped_at
            """, [id, playCounts[id] ?? 0, skipCounts[id] ?? 0,
                  addedAt[id], lastPlayedAt[id], lastSkippedAt[id]])
    }

    /// 星级，同样是按 id 挂的一行。清空（0 星）在内存里是 `removeValue`，这里就是 DELETE。
    private func persistRating(id: String, in db: SQLiteDatabase) throws {
        if let value = ratings[id] {
            try db.run("""
                INSERT INTO rating (id, value) VALUES (?,?)
                ON CONFLICT(id) DO UPDATE SET value = excluded.value
                """, [id, value])
        } else {
            try db.run("DELETE FROM rating WHERE id = ?", [id])
        }
    }

    /// 几张只有 id 一列的集合表（心水专辑 / 收藏艺人 / 取消勾选 / 减少推荐 / 已删账号歌单）。
    ///
    /// 收的是**差集**而不是整份集合：取消勾选那一份可以很大（菜单里「取消勾选所选项」
    /// 一次就能框住上千首），整份重灌等于又把写放大搬回来了。
    /// 调用点本来就在算这个差集（`updated` 与旧集合一比），原样递进来即可。
    private func persistIDSet(_ table: String, adding: some Sequence<String>,
                              removing: some Sequence<String>, in db: SQLiteDatabase) throws {
        let deleteSQL = "DELETE FROM \(table) WHERE id = ?"
        for id in removing { try db.run(deleteSQL, [id]) }
        // `OR IGNORE`：这几张表是**集合**，同一个 id 再加一次就是同一件事。
        let insertSQL = "INSERT OR IGNORE INTO \(table) (id) VALUES (?)"
        for id in adding { try db.run(insertSQL, [id]) }
    }

    /// 「用户主动删过的账号歌单」整份镜像。账号同步的 `resetDismissed` 会一次减掉一批，
    /// 差集算起来比镜像还绕；而这份集合的大小是「用户删过几份账号歌单」，个位数。
    private func persistDismissedPlaylists(in db: SQLiteDatabase) throws {
        try db.run("DELETE FROM dismissed_account_playlist")
        for id in dismissedAccountPlaylistIDs.sorted() {
            try db.run("INSERT INTO dismissed_account_playlist (id) VALUES (?)", [id])
        }
    }

    /// `pruneAfterLibraryRemoval` 在内存里做的那几件事，逐件落库。
    ///
    /// 传的是它**返回的那份 change**：两条「同步」开关关着时它一件都没做，
    /// 这里也就一行都不许写——照最坏情况全写一遍的话，开关关着时表和内存当场对不上。
    private func persistLibraryRemoval(_ ids: Set<String>, _ change: LibraryChange,
                                       in db: SQLiteDatabase) throws {
        if change.contains(.checkmarks) {
            try persistIDSet("unchecked_track", adding: [], removing: ids, in: db)
        }
        if change.contains(.favorites) { try remove(ids, from: .favorite, in: db) }
        if change.contains(.playlists) {
            // 哪几份列表被动到了不再另记一笔：`persistPlaylistTracks` 顺序没变就一行不写，
            // 于是「扫一遍本地列表」的代价是每份一条 SELECT，而写只落在真变了的那几份上。
            for playlist in playlists where playlist.origin == .local {
                try persistPlaylistTracks(playlist, in: db)
            }
        }
    }

    // MARK: - 搜索

    /// **七处搜索的唯一入口**：一个词在这一类对象里命中了哪些 id。
    ///
    /// 从前歌曲页、专辑页、最近添加、歌单页、艺人页、列表详情、搜索页的资料库范围
    /// 各写各的 `localizedCaseInsensitiveContains`，七份规则各自漂。现在一份：
    /// 切词、拼音、查询串全在 `LibrarySearch`，表在 `LibrarySearchIndex`，
    /// 调用方拿回的是 `LibraryTextFilter`——**筛的还是自己手里那份数组**，
    /// 各自的排序、分组、与别的筛选条件的先后一个字不用动。
    ///
    /// 三条守住的行为：
    ///
    /// 1. **空 / 纯空白查询返回 `.all`**，压根不进 MATCH（实测裸空串报
    ///    `fts5: syntax error near ""`）。这一判由 `ftsQuery` 返回 nil 表达。
    /// 2. **库开不了 / 查询抛错 / `mirrorIsStale` 竖着 → 退回内存子串筛选**，
    ///    也就是这次改造之前那套。与阶段 7 同一个理由：表只是加速器、内存数组仍是真值，
    ///    绝不能让一次故障表现成「搜什么都没有」。
    /// 3. **拉丁文字从「任意子串」收窄为「词前缀」**：`aylor` 不再命中 `Taylor`
    ///    （`taylor` 命中）。这是**有意的**变化，Apple Music 自己就是词前缀匹配，
    ///    别当 bug 改回去——`LibrarySearchTests.testLatinMatchesWordPrefixNotArbitrarySubstring`
    ///    专门钉住它。退路那一条走的仍是子串，所以故障时召回只会更宽、不会更窄。
    func searchFilter(_ raw: String, kind: LibrarySearchIndex.Kind) -> LibraryTextFilter {
        let keyword = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let query = LibrarySearch.ftsQuery(keyword) else { return .all }
        guard !mirrorIsStale, let db = database?.sqlite else { return .substring(keyword) }
        do {
            return .ids(try LibrarySearchIndex.matchedIDs(kind, query: query, in: db))
        } catch {
            NSLog("[LibraryStore] 搜索查询失败，这一次退回内存筛选：%@", String(describing: error))
            return .substring(keyword)
        }
    }

    // MARK: - 资料库派生（艺人页）

    /// 专辑的添加时间。没有记录（从未记过时间）就是 nil。
    ///
    /// **那个 O(n) 的兜底没有了。** 从前这里缺键时会去扫一遍 `libraryTracks`、
    /// 取碟内曲目 `addedAt` 的最大值，而「最近添加」那一页是逐张碟问的——一屏 40 张碟
    /// 就是 40 遍全表扫。那条回落只为旧存档服务（它们没有 `albumAddedAt` 这个键），
    /// 现在它搬进了迁移器：迁移时算一次，写死进 `library_album.added_at`。
    func albumAddedDate(for album: Album) -> Date? { albumAddedAt[album.id] }

    /// 资料库专辑里属于这张碟的歌。判定见 `belongs(_:to:)`：**有`albumId` 就只认 id**，
    /// 没有的才按名字归位，且要艺人对得上、不跨本地/在线与音源。
    ///
    /// 早先是「id 相同 **或** 专辑名相同」，那个 `||` 会把同名碟整个串起来：
    /// 资料库里两张《太阳之子》（本地导入的一张、QQ 的一张）时，
    /// 艺人页上两个《太阳之子》块各自列的都是**两张碟的曲目并集**。
    ///
    /// ## 这一条还没有下沉 SQL，是有意留着的
    ///
    /// 旁边三条（`libraryArtists()` / `albums(byArtist:)` / `tracks(byArtist:)`）都换成
    /// 读表了，这条没换：它有**三个逐行调用点**，而「一次绘制一行就查一次库」是明令
    /// 不许出现的形状——
    ///
    /// - `LibraryArtistsViewController.tableView(_:heightOfRow:)`：`reloadData` 会对
    ///   **每一行**问一次高度，一屏 40 张碟就是 40 次；
    /// - 同一个类的 `tableView(_:viewFor:row:)`：滚动时每滚进一行问一次；
    /// - `ArtistPageCards.ArtistReleaseCardView.apply(_:)`：集合视图的条目复用点，
    ///   同样是滚一行走一次。
    ///
    /// 要下沉得先把它从这三处提出来（在 `updateDetailContent()` 建 `detailRows` 时
    /// 一次算好、连着行一起带下去），而那是改资料库 VC 的 refresh 结构——
    /// 这次改造明确不碰的东西。**先提再沉，顺序反了就是把一次查询塞进滚动路径。**
    ///
    /// 顺带记一笔免得被当成「反正现在也慢」：今天这条是 `libraryTracks` 全扫，
    /// 没有 `albumId` 的曲目每首还要现算一次 `fallbackKey`（trim + lowercase + join），
    /// 所以逐行调用**今天就已经是 O(曲目总数)**。下沉之后走的是 `track_album_id`
    /// 索引，量大了反而更快——这三处要修的是形状，不是「SQL 比内存慢」。
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
    ///
    /// **候选从哪儿来交给 SQL，去重与排序留在这儿。** 最后那一道
    /// `localizedStandardCompare` 是自然序 + 本地化，SQLite 的 `ORDER BY` 给不出来
    /// （理由见 `sortedByTitleWithinGroups`），所以 SQL 只负责按入库先后把
    /// 「专辑的艺人名在前、单曲的在后」这份候选序列吐出来。
    func libraryArtists() -> [Artist] {
        guard let candidates = derived(Self.artistCandidatesSelect, [], {
            (name: $0.text(0), kind: ProviderKind(rawValue: $0.text(1)) ?? .netease)
        }) else {
            return Self.artists(from: libraryAlbums.map { ($0.artistName, $0.kind) }
                                + libraryTracks.map { ($0.artistName, $0.kind) })
        }
        return Self.artists(from: candidates)
    }

    /// 艺人候选：入库专辑在前（`tier = 0`）、资料库曲目在后，各自按 `position`。
    ///
    /// 空艺人名不在 SQL 里筛掉——`artists(from:)` 本来就跳过它们，
    /// 筛在哪一头是个选择，而**让两条路吃同一份规则**比省几行扫描重要。
    ///
    /// **不是 `private`**：`LibrarySearchIndex` 维护索引里艺人那一档时要按同一份规则
    /// 派生同一批 id。抄一份过去的话，哪天改了去重口径就会出现「艺人页上有这个人、
    /// 搜他的名字却搜不到」这种查无可查的不一致。
    static let artistCandidatesSelect = """
        SELECT name, kind FROM (
            SELECT artist_name AS name, kind, 0 AS tier, position AS ord FROM library_album
            UNION ALL
            SELECT t.artist_name, t.kind, 1, lt.position
              FROM library_track lt JOIN track t ON t.id = lt.track_id
        ) ORDER BY tier, ord
        """

    /// 候选序列 →（首次出现者赢的去重、按名称排序、成型）。
    ///
    /// **SQL 那条路与内存那条路共用这一段**，两条路的差别只剩「候选从哪儿来」。
    /// 抄成两份的话，哪天改了去重口径（比如改成大小写无关）就会出现「表里那份艺人页
    /// 与写失败之后那份艺人页不一样」这种查无可查的不一致。
    ///
    /// 第三位用户是 `LibrarySearchIndex.derivedArtists`：索引里艺人那一档的 id
    /// 必须与这里派生出来的一模一样，否则就是「艺人页上有这个人、搜他的名字却搜不到」。
    /// 它也是这个函数不是 `private` 的原因。
    static func artists(from candidates: [(name: String, kind: ProviderKind)]) -> [Artist] {
        var kinds: [String: ProviderKind] = [:]
        var names: [String] = []
        for candidate in candidates {
            guard !candidate.name.isEmpty, kinds[candidate.name] == nil else { continue }
            kinds[candidate.name] = candidate.kind
            names.append(candidate.name)
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
    ///
    /// SQLite 的 `=` 是逐字节比，Swift 的 `==` 是 Unicode 规范等价——分解式的 `é`
    /// 与预组合的 `é` 在 Swift 里相等、在 SQL 里不等。这里两头的名字都来自同一份数据
    /// （`libraryArtists()` 派生出来的名字就是 `library_album.artist_name` 本身），
    /// 字节一样，所以这道差别落不到实处；真要有一天名字来自用户输入，
    /// 得在**写入时**归一化成一列，而不是在 SQL 里折（见 `SQLiteDatabase` 的第 4 条要点）。
    func albums(byArtist name: String) -> [Album] {
        derived(Self.albumsByArtistSelect, [name], { Self.decodeAlbum($0).album })
            ?? libraryAlbums.filter { $0.artistName == name }
    }

    private static let albumsByArtistSelect = """
        SELECT \(albumSelectColumns) FROM library_album WHERE artist_name = ? ORDER BY position
        """

    /// 某位艺人在资料库里的全部曲目（含未随整张碟入库的单曲），碟内按曲序、碟间按添加先后。
    ///
    /// 排序切成两半：**SQL 排碟序与碟内曲序，标题那一级在 Swift 里**——
    /// 为什么非这么切不可，见 `sortedByTitleWithinGroups`。
    func tracks(byArtist name: String) -> [Track] {
        guard let rows = derived(Self.tracksByArtistSelect, [name], {
            (track: Self.decodeTrack($0), albumOrder: $0.optInt(13))
        }) else { return tracksByArtistInMemory(name) }
        return Self.sortedByTitleWithinGroups(rows)
    }

    /// 碟序那一道的三种情形照 `tracksByArtistInMemory` 逐字对：
    ///
    /// - 两边都落在资料库专辑上 → 按 `library_album.position` 比；
    /// - 一边落不上（没有 `albumId`，或那张碟不在资料库里）→ **落不上的排在前面**。
    ///   `ORDER BY (a.position IS NOT NULL)` 给 NULL 那边 0、有值那边 1，正是这个方向。
    ///   （内存那份是 `case (.some, .none): return false` / `(.none, .some): return true`，
    ///   看着反直觉，但它是现行行为，这次只搬家不改语义。）
    private static let tracksByArtistSelect = """
        SELECT \(trackColumns(prefix: "t.")), a.position
          FROM library_track lt
          JOIN track t ON t.id = lt.track_id
          LEFT JOIN library_album a ON a.id = t.album_id
         WHERE t.artist_name = ?
         ORDER BY (a.position IS NOT NULL), a.position,
                  COALESCE(t.disc_number, 0), COALESCE(t.track_number, 0)
        """

    /// SQL 走不通时的那条路，同时也是上面那条查询的**语义定义**。
    private func tracksByArtistInMemory(_ name: String) -> [Track] {
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

    /// 补上最后一道比较子：**标题**。入参必须已经按前几道（碟序、碟号、音轨号）排好。
    ///
    /// ## 为什么标题这一级不能交给 SQLite
    ///
    /// 原来的第三道比较子是 `lhs.title.localizedStandardCompare(rhs.title)`
    /// ——**自然序 + 本地化**：数字按值比（「第 2 首」排在「第 10 首」前面）、
    /// 中文按本地化规则。SQLite 的 `ORDER BY title` 是按 UTF-8 **字节序**，
    /// 「第 10 首」会跑到「第 2 首」前面。
    ///
    /// 危险的不是它错，是它**大部分歌看起来还对**：音轨号一路唯一时第三道比较子
    /// 根本不出场，只有「同碟、同号、不同名」的那几首才轮得到它说话——碟号缺失的
    /// 导入碟、音源没给曲号的歌单碟，正是这种。这一类改坏了没有人会报 bug。
    ///
    /// 所以切法是固定的：**SQL 只排到碟号与音轨号，标题这一级在 Swift 里、
    /// 对已经缩到「SQL 认为并列」的那一小撮做。** 每一撮通常是 1 个元素
    /// （`sorted` 都不会调用），代价与「让 SQLite 多排一列」没有可比性。
    private static func sortedByTitleWithinGroups(
        _ rows: [(track: Track, albumOrder: Int64?)]) -> [Track] {
        /// SQL 认为这两行并列吗——它认为并列的，才轮得到标题说话。
        func tied(_ lhs: (track: Track, albumOrder: Int64?),
                  _ rhs: (track: Track, albumOrder: Int64?)) -> Bool {
            lhs.albumOrder == rhs.albumOrder
                && (lhs.track.discNumber ?? 0) == (rhs.track.discNumber ?? 0)
                && (lhs.track.trackNumber ?? 0) == (rhs.track.trackNumber ?? 0)
        }
        var result: [Track] = []
        result.reserveCapacity(rows.count)
        var start = rows.startIndex
        while start < rows.endIndex {
            var end = rows.index(after: start)
            while end < rows.endIndex, tied(rows[start], rows[end]) { end = rows.index(after: end) }
            if rows.index(after: start) == end {
                result.append(rows[start].track)
            } else {
                result.append(contentsOf: rows[start..<end].map(\.track).sorted {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                })
            }
            start = end
        }
        return result
    }
}
