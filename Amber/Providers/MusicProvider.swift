import Foundation

enum ProviderError: Error, LocalizedError {
    case invalidResponse
    case unavailable(String)
    case api(String)
    /// 本地曲目的原始文件不在下载索引记着的位置上了。
    ///
    /// 单独一条而不是混在 `.unavailable` 里：它是唯一一种「不该报 toast、也不该静默跳过」
    /// 的失败——用户主动点播的那一首要弹「你想要查找它吗？」（spec §10.1，
    /// 见 `MissingFileLocator`），而能判出「是本地文件没了」的只有取流那一处。
    case localFileMissing(trackID: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "接口返回异常"
        case .unavailable(let reason): return reason
        case .api(let message): return message
        // 走到这一句就说明没人接住这条（预取那一路、或者界面层没接线）：
        // 报原因即可，别把 Music 那句带「你想要查找它吗？」的问句塞进 toast——
        // toast 上没有可点的「查找」。
        case .localFileMissing: return "找不到原始文件"
        }
    }
}

/// 统一的音乐源协议。实现均为无 UI 依赖的纯网络层，可在后台线程调用。
///
/// 每个 async 要求都标了 `@concurrent`：SE-0461 之后非隔离 async 函数默认**继承调用方的
/// 隔离域**，而这一层的调用方几乎都是 `@MainActor` 的状态对象（`CatalogFeedModel`、
/// `ArtistPageModel`、`AppState`…），不标的话取回来的 JSON 解析与整表映射就全都落在
/// 主线程上——目录页一次并发十来个请求，那是要掉帧的。标上等于把这一层钉回协作线程池，
/// 也就是 Swift 5 时代本来的跑法，只不过现在是写出来的而不是靠默认值。
protocol MusicProvider: Sendable {
    var kind: ProviderKind { get }

    @concurrent
    func searchTracks(keyword: String, limit: Int, offset: Int) async throws -> [Track]
    @concurrent
    func searchAlbums(keyword: String, limit: Int, offset: Int) async throws -> [Album]
    @concurrent
    func searchArtists(keyword: String, limit: Int, offset: Int) async throws -> [Artist]
    @concurrent
    func searchPlaylists(keyword: String, limit: Int, offset: Int) async throws -> [Playlist]
    @concurrent
    func searchMVs(keyword: String, limit: Int, offset: Int) async throws -> [MV]

    /// 目录页（主页/新发现/广播）的一个格子。**栏目结构照 Apple Music 写死在
    /// `CatalogPages` 里**，音源只按 slot 交数据；交不出来就返回`.empty`，
    /// 页面会把那一段整段省掉，不要为了填满而拿别的内容顶。
    @concurrent
    func catalogItems(_ slot: CatalogSlot) async -> CatalogSlotResult

    /// 分类浏览页（「探索更多」的落点）：某个歌单分类标签下的歌单。
    /// 标签本身来自 `catalogItems(.browseGroups)`，id 是音源自己的键。
    @concurrent
    func playlists(tag: CatalogTagRef) async -> [Playlist]

    @concurrent
    func playlistDetail(_ playlist: Playlist) async throws -> PlaylistDetail
    @concurrent
    func albumDetail(_ album: Album) async throws -> AlbumDetail
    @concurrent
    func artistDetail(_ artist: Artist) async throws -> ArtistDetail

    /// 相似艺人。音源交不出来（接口没有 / 未登录 / 出错）就返回空，
    /// 艺人页整段省掉——与 `catalogItems` 的`.empty` 同一个原则。
    @concurrent
    func similarArtists(_ artist: Artist) async -> [Artist]

    /// 相似歌曲。自动连播（队列面板顶部那颗 ∞）用它续队列，**这是唯一的候选源**。
    /// 音源交不出来（接口没有 / 未登录 / 出错）就返回空——与 `similarArtists` 同一个口径。
    ///
    /// `limit` 只是「最多要这么多」，音源给不够不算失败：
    /// [实测 2026-09-09 curl] 网易云匿名态下 `limit` 传多少都只回 5 条。
    ///
    /// **不要再往下接第二条召回。** 2026-09-09 接错过一次：给网易云串了
    /// 「相似歌曲 → 心动模式 → 私人 FM」三层，理由是「simiSong 一次只给 5 首，放完就断」。
    /// 那一轮的教训有三条，都写在这儿免得重演：
    ///
    /// 1. **相似性是这个功能对用户的承诺。** 队列面板自动播放分区头上的文案是
    ///    「将播放类似歌曲」（`PLAY_QUEUE_AUTOPLAY_SUBTITLE`，实测自 Music 的 zh_CN
    ///    `UserInterface.strings`），掺进跟种子无关的歌就是骗人。实机 dump 就是证据：
    ///    种子「起风了」，simiSong 给的是「在你的身边／还是分开／哪里都是你」，
    ///    FM 垫的是「MONTAGEM XONADA／DAY1／荒漠上行走」，风马牛不相及。
    /// 2. **私人 FM（`/api/v1/radio/get`）与心动模式（`/api/playmode/intelligence/list`）
    ///    在网易云都是独立的一种播放模式**，不是「找相似」的接口：FM 是服务端按用户口味
    ///    发歌、与种子无关；心动模式必须带 `playlistId`，语义是「在某张歌单里按心动顺序
    ///    往下播」。将来真要做它们，是连着 UI 一起设计的两个功能，见 `design-ref/todo.md`。
    /// 3. **「5 首放完就断」这个前提本身就不成立。** 种子跟着当前曲往前走
    ///    （`PlayerController.refillAutoplayIfNeeded`），每播一首新歌就再问一批 5 首，
    ///    这条路本来就是无限的——别再因为「量不够」把那两条加回来。
    @concurrent
    func similarTracks(_ track: Track, limit: Int) async -> [Track]

    /// 这一首的流派（「显示简介 › 详细信息 › 类型」那一格）。
    ///
    /// **是曲目级的，不是专辑级的**：`LibraryStore.genre(for:)` 查的是所属专辑那一份，
    /// 而音源常常只在专辑节点上给流派、单曲接口不给（网易云）或者另有一条更细的
    /// 单曲详情（QQ）。面板先用专辑那份，空了才来问这条。
    ///
    /// 与 `similarArtists` 同一个口径：交不出来（没接口 / 没登录 / 出错）返回 nil，
    /// 面板那一格就留空——不编一个。
    @concurrent
    func trackGenre(_ track: Track) async -> String?

    /// 这个音源能不能做自动连播（＝有没有 `similarTracks` 的接口）。
    /// 队列面板顶部那颗 ∞ 的 enabled 绑它（[实测] playqueue spec §3.9
    /// `autoplay.enabled` → `viewModel.autoplayAvailable`），没能力就置灰。
    var supportsAutoplay: Bool { get }

    /// 这个音源当前是不是登录状态。没有登录能力的音源恒为 false（默认实现），
    /// 与 `accountPlaylists` 的默认空实现是同一件事的两面。
    var isLoggedIn: Bool { get }

    /// 已登录账号在音源里的歌单（自建 + 收藏），进资料库的「播放列表」。
    /// 没登录、或这个音源在 Amber 里还没有登录能力时返回空。
    @concurrent
    func accountPlaylists() async -> [Playlist]

    /// 解析可播放的流地址（匿名状态下 VIP/付费曲目会抛 unavailable）。
    ///
    /// `quality == nil` 走音源自己存着的那档（由 AppState 推进来，= 设置里的流播放档）；
    /// 传了值就用这一档当**起点**，降级阶梯不变。下载要的是「下载」那一档
    /// （设置 › 播放 › 下载 + 下载杜比全景声，两者与流播放各夹各的），
    /// 所以下载那条 resolver 显式传档，见 `AppState.downloadQuality`。
    @concurrent
    func trackStreamURL(track: Track, quality: StreamQuality?) async throws -> URL
    @concurrent
    func lyrics(track: Track) async throws -> [LyricLine]

    /// MV 的可播地址。`maxHeight` 是画面高度上限（设置 › 播放 › 视频质量），
    /// nil 表示「有多高给多高」。
    ///
    /// 两家的降级脾气不一样，所以这条由各自实现，不做统一的阶梯：
    /// - QQ 一次把所有档位（`filetype`）连地址一起发回来，客户端自己挑（`MVVariant.pick`）；
    /// - 网易云跟它的取流一样**服务端自己降级**，问一次就够，回来的 `r` 才是真实档位。
    @concurrent
    func mvStreamURL(mv: MV, maxHeight: Int?) async throws -> URL
}

extension MusicProvider {
    /// 默认没有登录能力（两家音源都各自覆写了：QQ 与网易云都有扫码登录）。
    var isLoggedIn: Bool { false }

    /// 默认没有账号歌单：没有登录能力的音源取不到「我的歌单」。
    func accountPlaylists() async -> [Playlist] { [] }

    /// 默认交不出相似艺人：这是锦上添花的一段，没有对应接口的音源不必为它写空实现。
    func similarArtists(_ artist: Artist) async -> [Artist] { [] }

    /// 默认交不出曲目级流派（同上，只读的一格，没接口就留空）。
    func trackGenre(_ track: Track) async -> String? { nil }

    /// 默认交不出相似歌曲，于是默认没有自动连播能力。两条要一起看：
    /// `supportsAutoplay` 为假时面板上那颗 ∞ 置灰，`similarTracks` 压根不会被问到。
    func similarTracks(_ track: Track, limit: Int) async -> [Track] { [] }
    var supportsAutoplay: Bool { false }

    /// 不指定档位＝按音源的全局档位取流（播放走这条）。
    func trackStreamURL(track: Track) async throws -> URL {
        try await trackStreamURL(track: track, quality: nil)
    }
}
