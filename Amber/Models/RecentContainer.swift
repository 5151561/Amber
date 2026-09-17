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
        // **与 `.playlist` 同一个前缀**：同一份歌单有两条路进来——从资料库那份歌单页
        // 起播给的是 `.libraryPlaylist`，从目录页、或`playLibraryPlaylist` 转手给
        // `playPlaylist` 时给的是`.playlist`——而`LibraryPlaylist.from` 沿用的就是
        // 音源歌单的 id（见`Models.swift`）。键不一致的话同一份歌单会摆出两张卡。
        // 本地自建列表的 id 是 `local:<UUID>`，撞不上音源 id。
        case .libraryPlaylist(let id): return "playlist:\(id)"
        case .album(let album): return "album:\(album.id)"
        case .favorites: return "favorites"
        case .artist(let id, _, _, _): return "artist:\(id)"
        case .track(let track): return "track:\(track.id)"
        }
    }
}

// MARK: - 与 recent_container 表的互转

extension RecentContainer {

    /// 一格台账在 `recent_container` 表里占的那三列。
    ///
    /// **这份映射只有这一处。** 迁移器写进去、`LibraryStore` 读出来与写回去，
    /// 三条路都走它——抄成两份的话，以后往上面加一个 case 只改了一头，
    /// 表现是「那一格存进去了、读回来没了」，不报错。
    struct StorageRow {
        /// 六个 case 的判别符。**取值是持久化契约**，改一个字等于让旧库里那些行认不出来。
        let kind: String
        /// 指向别的表的 id（`.track` → `track.id`，`.libraryPlaylist` → 歌单 id）。
        let refID: String?
        /// 故意存成快照的那几个 case 的原样 Codable JSON。
        let payload: String?
    }

    /// `.artist` 的 payload：只有这四项。
    ///
    /// **不存整个 `Artist`**：它不落盘（非可选属性缺键会让合成的 Decodable 抛错），
    /// 卡片与 `Route` 要的也就这四项，展示时现造一个。
    /// 字段名与 `.artist` 的关联值同名，逐个对得上。
    struct ArtistPayload: Codable {
        let id: String
        let kind: ProviderKind
        let name: String
        let avatarURL: String?
    }

    var storageRow: StorageRow {
        func json(_ value: some Encodable) -> String? {
            (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        }
        switch self {
        case .track(let track):
            // 曲目从 `track` 表取。**这一下删掉 `updateTrack` 的第五处写入点**：
            // 改一首歌的标题不必再翻一遍 50 条台账。
            return StorageRow(kind: "track", refID: track.id, payload: nil)
        case .libraryPlaylist(let id):
            // 资料库歌单只存 id：名字 / 封面 / 还在不在都实时解析，存快照必然发霉。
            return StorageRow(kind: "libraryPlaylist", refID: id, payload: nil)
        case .playlist(let playlist):
            // 音源那份歌单**故意是快照**：它不在资料库里，没有表可以指。
            return StorageRow(kind: "playlist", refID: playlist.id, payload: json(playlist))
        case .album(let album):
            return StorageRow(kind: "album", refID: album.id, payload: json(album))
        case .artist(let id, let kind, let name, let avatarURL):
            return StorageRow(kind: "artist", refID: id,
                              payload: json(ArtistPayload(id: id, kind: kind, name: name,
                                                          avatarURL: avatarURL)))
        case .favorites:
            // 心水是一份虚拟列表，没有 id 可存，所以两列都是 NULL。
            return StorageRow(kind: "favorites", refID: nil, payload: nil)
        }
    }

    /// 从表里那三列还原。认不出来（kind 是未来版本写的、payload 解不动、
    /// `.track` 指的那行不在了）就返回 nil，调用方跳过这一格——
    /// 一格台账认不出来只是货架上少一张卡，不该让整份台账连坐。
    ///
    /// - Parameter track: 按 id 取曲目（`.track` 那一格要用）。
    static func make(kind: String, refID: String?, payload: String?,
                     track resolve: (String) -> Track?) -> RecentContainer? {
        func decode<T: Decodable>(_ type: T.Type) -> T? {
            payload.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
        switch kind {
        case "track": return refID.flatMap(resolve).map { .track($0) }
        case "libraryPlaylist": return refID.map { .libraryPlaylist(id: $0) }
        case "playlist": return decode(Playlist.self).map { .playlist($0) }
        case "album": return decode(Album.self).map { .album($0) }
        case "artist":
            guard let payload = decode(ArtistPayload.self) else { return nil }
            return .artist(id: payload.id, kind: payload.kind, name: payload.name,
                           avatarURL: payload.avatarURL)
        case "favorites": return .favorites
        default: return nil
        }
    }
}
