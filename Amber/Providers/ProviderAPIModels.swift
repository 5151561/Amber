import Foundation

// 两家音源都能交出来的那几类数据，模型统一放这儿；只有一家有的（网易的云盘、
// QQ 的不喜欢名单）留在各自的扩展文件里，不往这儿凑。
//
// 移植来源：
// - 网易云 <https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced> `module/*.js`
// - QQ 音乐 <https://github.com/l-1124/QQMusicApi> `qqmusic_api/modules/*.py`
// 每条接口的路径、参数、以及「匿名能不能打通」都写在各自方法的注释里。

// MARK: - 收藏

/// 一次收藏/取消收藏的目标。id 是 Amber 的带前缀 id（`ne:123` / `qq:004xxx`），
/// 各家实现自己 `rawID` 剥前缀——调用方拿到的永远是模型里那一个 id，不用记谁要数字谁要 mid。
enum FavoriteTarget: Hashable, Sendable {
    case track(String)
    case album(String)
    case artist(String)
    case playlist(String)
    case mv(String)
    /// 电台/播客（网易的 djradio；QQ 侧暂无对应写接口）
    case radio(String)
}

/// 账号里各类收藏的条目数（资料库侧边栏的角标）。给不出的项是 nil，不折成 0。
struct FavoriteCounts: Sendable {
    var tracks: Int?
    var albums: Int?
    var artists: Int?
    var playlists: Int?
    var mvs: Int?
    var radios: Int?
}

/// 往音源账号里**写**的能力。两家都只实现自己真有接口的那几条，
/// 其余落到默认实现上抛 `.unavailable`——调用点按抛出与否决定菜单项灰不灰。
///
/// 与 `MusicProvider` 分开一层，是因为「读目录」和「改账号数据」的失败代价差着量级：
/// 目录取不到就少一段内容，写错了是把用户账号里的歌单改坏。所有写方法一律 `throws`，
/// 没有「悄悄失败返回空」的口子。
protocol MusicLibraryWriting: MusicProvider {
    /// 收藏 / 取消收藏。`favorite == false` 是取消。
    func setFavorite(_ target: FavoriteTarget, favorite: Bool) async throws
    /// 账号里「喜欢的歌曲」的 id 表（Amber 前缀形式）。红心状态靠它一次性拉全，
    /// 不给每首歌各打一条查询。
    func favoriteTrackIDs() async throws -> [String]
    func favoriteAlbums() async throws -> [Album]
    func favoriteArtists() async throws -> [Artist]
    func favoriteMVs() async throws -> [MV]
    func favoriteCounts() async throws -> FavoriteCounts

    func createPlaylist(name: String, isPrivate: Bool) async throws -> Playlist
    func deletePlaylist(_ playlistID: String) async throws
    func renamePlaylist(_ playlistID: String, name: String) async throws
    func updatePlaylistDescription(_ playlistID: String, description: String) async throws
    func addTracks(_ trackIDs: [String], to playlistID: String) async throws
    func removeTracks(_ trackIDs: [String], from playlistID: String) async throws
}

extension MusicLibraryWriting {
    func favoriteAlbums() async throws -> [Album] { throw ProviderError.unavailable("这个音源没有收藏专辑接口") }
    func favoriteArtists() async throws -> [Artist] { throw ProviderError.unavailable("这个音源没有关注歌手接口") }
    func favoriteMVs() async throws -> [MV] { throw ProviderError.unavailable("这个音源没有收藏 MV 接口") }
    func favoriteCounts() async throws -> FavoriteCounts { FavoriteCounts() }
    func renamePlaylist(_ playlistID: String, name: String) async throws {
        throw ProviderError.unavailable("这个音源不支持改歌单名")
    }
    func updatePlaylistDescription(_ playlistID: String, description: String) async throws {
        throw ProviderError.unavailable("这个音源不支持改歌单简介")
    }
}

// MARK: - 口味反馈

/// 把「这个别再推给我」写回音源账号的能力，对应菜单里的「减少推荐 / 撤销减少推荐」
/// （[实测] contextmenu spec §3.2 的 `SuggestLessItemsAction` / `UndoSuggestLessItemsAction`：
/// 判据同一个、方向相反，永远只出现一个）。
///
/// 与 `MusicLibraryWriting` 分成两个协议，是因为改的东西不是一码事：那边动的是账号里的
/// **收藏数据**（歌单、红心），这边动的是**推荐口味**。两家的接口形状也对不齐——
/// QQ 有一份可加可撤的「不喜欢名单」，网易云只有一记单向的「不感兴趣」。
/// 所以能力由两个布尔量报，`false` 的那条在菜单里根本不摆（`MenuSpec` 的禁用即隐藏）。
protocol MusicTasteWriting: MusicProvider {
    /// 撤不撤得回来。QQ 的 `CancelDislike` 能，网易云没有对应接口。
    var supportsUndoSuggestLess: Bool { get }
    /// 能不能对**歌手**减少推荐（QQ 的不喜欢名单收歌手，网易云不收）。
    var supportsArtistSuggestLess: Bool { get }

    /// 对这批曲目减少推荐；`less == false` 是撤销。id 是 Amber 的带前缀形式，
    /// 各家实现自己换算成音源要的 id（QQ 要数字 songid，Amber 手里是 mid）。
    func suggestLess(tracks trackIDs: [String], less: Bool) async throws
    /// 对这个歌手减少推荐。没有这条能力的音源落到默认实现上抛 `.unavailable`。
    func suggestLess(artist artistID: String, less: Bool) async throws
}

extension MusicTasteWriting {
    var supportsUndoSuggestLess: Bool { false }
    var supportsArtistSuggestLess: Bool { false }

    func suggestLess(artist artistID: String, less: Bool) async throws {
        throw ProviderError.unavailable("这个音源不能对歌手减少推荐")
    }
}

// MARK: - 搜索

/// 热搜榜的一条。
struct HotSearchItem: Identifiable, Hashable, Sendable {
    var id: String { keyword }
    /// 真正拿去搜的词
    let keyword: String
    /// 带高亮/别名的显示词，没有就等于 keyword
    let displayName: String
    /// 推荐语（网易 `content`）
    let note: String?
    /// 「热」「新」这类角标图（网易 `iconUrl`）
    let iconURL: String?
    /// 热度分，没有就是 0
    let score: Int
}

/// 搜索框下拉里的一条建议。
struct SearchSuggestion: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case keyword, track, album, artist, playlist, mv
    }
    let id: String
    let kind: Kind
    /// 主行文字（关键词本身，或歌名/专辑名/艺人名）
    let text: String
    /// 次行文字（歌手 - 专辑 这类）
    let subtitle: String?
}

/// 搜索侧的补充能力：建议、热搜、默认词。三条都「给不出就返回空」，
/// 与 `catalogItems` 的`.empty` 同一口径——搜索框少一个下拉不该让搜索本身失败。
protocol MusicSearchSuggesting: MusicProvider {
    func searchSuggestions(keyword: String) async -> [SearchSuggestion]
    func hotSearches() async -> [HotSearchItem]
    /// 搜索框的占位默认词（Music 的搜索框里那句灰字）。
    func defaultSearchKeyword() async -> String?
}

extension MusicSearchSuggesting {
    func defaultSearchKeyword() async -> String? { nil }
}

// MARK: - 评论

/// 评论挂在哪个资源上。参数是 Amber 的带前缀 id。
enum CommentTarget: Hashable, Sendable {
    case track(String)
    case album(String)
    case playlist(String)
    case mv(String)
    /// 电台节目（网易 `A_DJ_1_`）
    case radioProgram(String)
}

/// 一条评论。回复串只带「被回复的那一条」，不做整棵楼——
/// 详情页的评论区是一段展示，不是评论客户端。
struct MusicComment: Identifiable, Hashable, Sendable {
    let id: String
    let userID: String?
    let userName: String
    let avatarURL: String?
    let content: String
    let date: Date?
    let likeCount: Int
    /// 当前账号点没点过赞。未登录/接口不给时是 false。
    let liked: Bool
    /// IP 归属地（网易 `ipLocation.location`），没有就是 nil
    let ipLocation: String?
    /// 被回复那条的作者与正文（网易 `beReplied` / QQ 子评论）
    let repliedUserName: String?
    let repliedContent: String?
}

/// 一页评论。
struct CommentPage: Sendable {
    var hot: [MusicComment] = []
    var comments: [MusicComment] = []
    var total: Int = 0
    var hasMore: Bool = false
    /// 翻下一页要带回去的游标（网易 v2 的 `cursor`；QQ 的`last_comment_id`）
    var cursor: String?
}

protocol MusicCommenting: MusicProvider {
    func comments(for target: CommentTarget, limit: Int, cursor: String?) async throws -> CommentPage
}

// MARK: - 听歌记录与账号资料

/// 听歌排行/最近播放里的一条。
struct PlayRecordItem: Sendable {
    let track: Track
    /// 播放次数，接口不给就是 0
    let playCount: Int
    let lastPlayed: Date?
}

/// 音源账号的公开资料。给不出的项留 nil。
struct ProviderUserProfile: Sendable {
    let uid: String
    let nickname: String
    var avatarURL: String?
    var signature: String?
    /// 会员等级（网易 `vipType`；QQ 的绿钻等级）
    var vipLevel: Int?
    /// 账号等级（网易 `level`）
    var level: Int?
    var followCount: Int?
    var followerCount: Int?
    var playlistCount: Int?
}

/// 一条歌曲的创作者信息（作词/作曲/编曲/制作人…）。
/// 键名由音源给（两家都是中文角色名，逐曲不同），所以不做成枚举——
/// 与 `ArtistFact` 同一个理由。
struct TrackCredit: Hashable, Sendable {
    let role: String
    let names: [String]
}
