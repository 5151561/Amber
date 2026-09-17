import Foundation
import os

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

// MARK: - 连接类失败

extension URLError {
    /// 「网络本身没打通」的那一类，与「服务端收到了、然后拒绝」分开。
    ///
    /// 这一份名单同时决定两件事，所以只能有一份：**要不要重试**（前提是「这次没打通、
    /// 下次可能打通」），以及**界面上说不说「网络不可用」**（`CatalogSlotResult.failure`）。
    ///
    /// 业务错误一条都不在里面，这是硬要求而不是偏好：QQ 的 104003（匿名态点 VIP 曲目）
    /// 走的是 `ProviderError.api`，退避三次再报错的话，用户点一下下载要盯着三秒才看见
    /// 提示——上一轮验收第 33 条钉的就是这件事。
    ///
    /// `.secureConnectionFailed`（TLS 握手失败）**故意不收**：它既不是「没网」，
    /// 重试也治不好（证书/协议不匹配下一次还是那样），收进来只会白等两轮退避。
    var isConnectionFailure: Bool {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}

/// 只对连接类失败重试的小包装：**首次 + 最多 2 次重试，指数退避 0.3 s / 0.6 s**。
///
/// 三个收口点共用这一份（`QQAPI.musicu`、`NeteaseAPI.get(base:_:params:)`、
/// `NeteaseAPI.eapiRaw`），别在三处各抄一遍——名单一旦分叉，「哪种错会白等三秒」
/// 就变成得逐处去读的事。
///
/// 包在**传输那一句**上而不是整条请求上：`URLError` 只可能从 `URLSession.data` 里出来，
/// 重试建请求体没有意义；而业务错误（`ProviderError.api`）压根不是 `URLError`，
/// 就算把整条请求包进来也不会被重试。
///
/// 退避用 `Task.sleep` 而不是 `Thread.sleep`：这一层跑在协作线程池上
/// （`MusicProvider` 的 `@concurrent`，理由见下面协议的注释），阻塞式等待会占着
/// 池里的一根线程不放，而目录页一次就有 4 条请求在跑。`Task.sleep` 也顺带把取消
/// 传下去——换音源时 `reloadTask.cancel()` 不必等退避睡完。
///
/// 函数本身不标 `@concurrent`：它要跟调用方待在同一个隔离域里（SE-0461 的默认行为），
/// 否则每次重试都多一次无谓的执行器跳转。
func withConnectionRetry<T>(_ operation: () async throws -> T) async throws -> T {
    for attempt in 0..<2 {
        do {
            return try await operation()
        } catch let error as URLError where error.isConnectionFailure {
            try await Task.sleep(for: .milliseconds(300 << attempt))
        }
    }
    // 最后一次不再兜。连接类失败在这里**顺手记进** `CatalogFailureSink`：
    // 目录页那两条取数接口（`catalogItems` / `playlists(tag:)`）按设计不抛错
    // （见它们各自的注释），错误码到不了界面层，只能在这儿留个记号。
    do {
        return try await operation()
    } catch {
        if let urlError = error as? URLError, urlError.isConnectionFailure {
            CatalogFailureSink.record(urlError)
        }
        throw error
    }
}

/// 目录格子「取不到」的上报口：网络层把最终的连接类失败放进来，
/// `catalogItems` 在出口处取走，填进 `CatalogSlotResult.failure`。
///
/// 为什么需要这么一条旁路：`catalogItems` 一格底下常常是七八条请求
/// （QQ 的 `.topPicks` 就是「新碟 + 电台分组」两路各自再分叉），中间每一层都用
/// `try?` 吞掉失败换取「这一段交不出来就整段省掉」——把错误改成层层上抛，
/// 等于把三十来个辅助函数全改一遍签名，只为了在出口处回答一个是非题。
enum CatalogFailureSink {

    /// 一次 `catalogItems` 调用期间共用的那一格。
    ///
    /// `@TaskLocal` 而不是 API 对象上的属性：一页十几格是**并发**在跑的
    /// （`CatalogFeedModel.performReload` 的 `withTaskGroup`，上限 4），
    /// 放在实例上会串味。任务局部量按**调用树**划界，`async let` 与 `withTaskGroup`
    /// 开出去的子任务自动继承，正好就是「这一格」的范围。
    ///
    /// **一处已知的不精确**：`RequestCache` 同键去重时，后到的那一格 `await` 的是
    /// 先到那一格建的 `Task`，失败因此记在**先到者**的格子里。断网时每一格都会自己
    /// 发请求、自己记一次，消费端问的又是「这一页有没有任何一格连接失败」，
    /// 所以这点偏差不改变结论；写在这里是免得下次有人拿单格去对账。
    @TaskLocal private static var current: Box?

    private final class Box: Sendable {
        let error = OSAllocatedUnfairLock<URLError?>(initialState: nil)
    }

    /// 网络层调用。只留**第一条**：同一格里后续请求的失败多半是同一个原因，
    /// 留哪条都一样，留第一条省一次写锁。
    static func record(_ error: URLError) {
        current?.error.withLock { if $0 == nil { $0 = error } }
    }

    /// provider 的 `catalogItems` 在出口处套这一层。
    ///
    /// 只在**这一格什么都没交出来**时才贴 `failure`：格子里有内容就说明该拿的拿到了，
    /// 某条支线超时不该让整页被判成「网络不可用」。这也正是 `failure` 那个字段
    /// 写着的语义——「这一格取不到」，不是「这一格里出过错」。
    static func attach(_ body: () async -> CatalogSlotResult) async -> CatalogSlotResult {
        let box = Box()
        var result = await $current.withValue(box) { await body() }
        if result.items.isEmpty { result.failure = box.error.withLock { $0 } }
        return result
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
    ///
    /// 这一条**不抛错**是有意的：`.empty` 对它是有意义的返回值（很多格子音源本来就不供）。
    /// 「没这一格」与「取不到」靠 `CatalogSlotResult.failure` 分开，两家实现都把整个
    /// 函数体套进 `CatalogFailureSink.attach`，别漏。
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
