import Foundation

/// 「最近播放」台账里的一格：**在哪儿听的**，不是「听了哪一首」。
///
/// 「歌 → 格子」这件事在**记账那一刻**就定下来（映射规则见 `RecentContainer.resolve`，
/// 它要认 `Route`，所以住在 App 层）。展示层不再按`albumId` 反推分组——
/// 在一份歌单里连听十首，货架上该多的是一张歌单卡，而不是十张互不相干的专辑卡。
///
/// 与 `LibraryStore.recentTracks` 是**两个粒度、两张表**：那份逐曲历史照旧 200 条
/// （喂相似种子 / 月度统计 / 本地文件失联扫描），这份台账 50 条，只给货架与二级页当格子用。
///
/// **以后只能往后加 case，不能删改既有 case 的载荷。** `LibraryStore.load()` 是
/// `try? decode(Storage.self)`：一个 case 解不出来，整份存档就整份丢，
/// 用户的心水、评分、播放次数、播放列表会跟着一起没。
enum RecentContainer: Codable, Hashable {
    /// 音源那份歌单（目录歌单 / 榜单 / 网易电台节目单 `ne:djradio:`）：整份存。
    case playlist(Playlist)
    /// 资料库歌单：**只存 id**，名字 / 封面 / 还在不在都实时解析。
    /// 歌单会改名会被删，存快照必然发霉。
    case libraryPlaylist(id: String)
    case album(Album)
    /// 心水歌曲。它是一份虚拟列表，没有 id 可存，所以这个 case 不带载荷。
    case favorites
    /// 艺人。**不存整个 `Artist`**：`Artist` 不落盘（见`Models.swift` 里`facts` 那条注释——
    /// 非可选属性缺键会让合成的 Decodable 抛错）。只存卡片与 `Route` 要的这四项，
    /// 展示时现造一个 `Artist`。
    case artist(id: String, kind: ProviderKind, name: String, avatarURL: String?)
    /// 收不进任何容器的散曲（没有专辑的歌、本地导入的散曲）。
    case track(Track)

    /// 去重键，同时当卡片 id 用。
    var id: String {
        switch self {
        case .playlist(let playlist): return "playlist:\(playlist.id)"
        case .libraryPlaylist(let id): return "libplaylist:\(id)"
        case .album(let album): return "album:\(album.id)"
        case .favorites: return "favorites"
        case .artist(let id, _, _, _): return "artist:\(id)"
        case .track(let track): return "track:\(track.id)"
        }
    }
}
