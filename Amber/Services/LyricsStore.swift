import Foundation

/// 歌词缓存：侧栏歌词与整窗歌词共用同一份取词结果。
///
/// 两处面板要的是同一首歌的同一份词，但各自都直接打音源——在侧栏与整窗之间来回切，
/// 每切一次就重走一趟网络。QQ 那条尤其贵：先请求逐字（`qrc=1`）、要不到再退一次行级，
/// 两条请求各带一遍 3DES 变体解密 + inflate + XML 解析。
///
/// 缓存的是**最终交给视图的那个 `[LyricLine]`**（正文 + 翻译 + 发音都已经并进去了），
/// 不是任何半成品，两处面板拿到的东西完全一致。
///
/// 三件事：
/// - **负结果照缓存**：`[]` 表示「这首确认没有词」。不缓存的话没词的歌每次开面板都白打一趟。
/// - **同首去重**：侧栏与整窗同时要同一首，只发一条请求，后到的等前一条。
/// - **LRU 上限**：50 首。歌词是纯文本，一首几 KB 量级，50 首覆盖得住一次听歌会话里
///   来回切的范围，又不会让长时间挂着的进程无限长。
///
/// 对外有**两个口**，别混：`lyrics(for:using:)` / `cachedLyrics(for:)` 是「音源那一份」
///（简介面板拿它当编辑底稿），`displayLyrics(for:using:)` / `cachedDisplayLyrics(for:)`
/// 是「面板该画的那一份」——自定义歌词优先。面板一律走后者。
@MainActor
final class LyricsStore: ObservableObject {

    /// 整窗歌词由 `NowPlayingViewModel` 构造的 `NowPlayingLyrics` 驱动，那条路上拿不到
    /// `AppState`，所以缓存本体是进程级的一份；`AppState.lyricsStore` 指的就是它。
    static let shared = LyricsStore()

    /// 内存里最多留几首。
    static let defaultCapacity = 50

    private let capacity: Int
    private var entries: [String: [LyricLine]] = [:]
    /// LRU 顺序，最近用到的在末尾。50 条的数组，线性操作比再维护一张链表划算。
    private var recency: [String] = []
    private var inFlight: [String: Task<[LyricLine], Never>] = [:]

    init(capacity: Int = LyricsStore.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// 缓存键：`Track.id` 本来就带音源前缀（`ne:` / `qq:`），再拼一次 kind 是为了
    /// 万一某个音源以后给出不带前缀的 id 也不会串味。
    static func key(for track: Track) -> String { "\(track.kind.rawValue)|\(track.id)" }

    /// 命中缓存时的同步查询：视图首帧就能把词画出来，不必先闪一下空态或转圈。
    /// 未命中返回 nil——与「缓存里存着空数组（确认没词）」区分开。
    func cachedLyrics(for track: Track) -> [LyricLine]? {
        let key = Self.key(for: track)
        guard let hit = entries[key] else { return nil }
        touch(key)
        return hit
    }

    /// 取词：先查缓存，再看有没有同首在跑，都没有才真发请求。
    ///
    /// 取词失败（网络错误）与「没有词」都归成 `[]`——与改造前两处面板
    /// `try?` + 空数组的处理一致，视图只认「有词 / 没词」。
    @discardableResult
    func lyrics(for track: Track, using provider: any MusicProvider) async -> [LyricLine] {
        await lyrics(for: track) { (try? await provider.lyrics(track: track)) ?? [] }
    }

    /// 取词的核心，`load` 是真正打音源的那一步（测试从这里注入）。
    func lyrics(for track: Track, load: @escaping () async -> [LyricLine]) async -> [LyricLine] {
        let key = Self.key(for: track)
        if let hit = entries[key] {
            touch(key)
            return hit
        }
        if let running = inFlight[key] { return await running.value }
        // 非结构化 Task：**不继承调用方的取消**。切歌时某一处面板的 `.task` 被取消，
        // 已经发出去的这条请求照样跑完并进缓存，另一处（或切回来）直接命中。
        let task = Task { [weak self] () -> [LyricLine] in
            let lines = await load()
            self?.finish(key, lines: lines)
            return lines
        }
        inFlight[key] = task
        return await task.value
    }

    // MARK: - 显示口（自定义歌词优先）

    /// 面板真正要画的那一份词：先看「显示简介 › 歌词」里有没有勾「自定义歌词」，
    /// 有就用用户手打的那份，没有才回落到上面那条音源路。
    ///
    /// **自定义词一律不进 LRU 缓存**：它随时会被面板改（按「好」就是新的一份），
    /// 不缓存就不必做失效——没有缓存就没有陈旧数据这件事。代价是每次显示都重解析一遍
    /// 几十行纯文本，与查一次字典在同一量级，不值得为它再引一套失效逻辑。
    ///
    /// 与 `lyrics(for:using:)` / `cachedLyrics(for:)` 分开而不是就地改那两条：
    /// 简介面板正是拿那两条取「音源那一份」当编辑底稿的
    ///（`InfoPanelWindowController.loadLyrics` 的 `providerLyrics`），
    /// 让它们返回自定义词就成了自我循环——编辑框里显示的会是上一次自己存进去的东西。
    func displayLyrics(for track: Track, using provider: any MusicProvider) async -> [LyricLine] {
        if let custom = customLines(for: track) { return custom }
        return await lyrics(for: track, using: provider)
    }

    /// 显示口的同步版。语义与 `cachedLyrics(for:)` 一致：nil = 还没有现成的结果，
    /// 得走异步那条。自定义词永远是现成的，所以有自定义词时必定不是 nil。
    func cachedDisplayLyrics(for track: Track) -> [LyricLine]? {
        if let custom = customLines(for: track) { return custom }
        return cachedLyrics(for: track)
    }

    /// `.task(id:)` 用的复合键：**换歌**要重取，**改完自定义歌词**也要重取。
    /// 只认 `track.id` 的话，在简介面板里改完词不换歌，面板上永远还是旧的那份。
    ///
    /// 键里直接放歌词原文而不是它的哈希：这个值只用来比「变没变」，
    /// 哈希省下的那点比较开销换不回碰撞时漏更新的风险。
    ///
    /// `trackInfo` 显式传进来而不是就地读 `TrackInfoStore.shared`：调用方必须把那份 store
    /// 以 `@ObservedObject` 持在视图上，`infos` 一变 body 才会重算出新键——
    /// 在这里偷读 shared 的话，视图与 store 之间没有依赖，键永远不会被重新算。
    static func displayToken(for track: Track?, trackInfo: TrackInfoStore) -> String? {
        guard let track else { return nil }
        // `\u{0}` 当分隔符：歌词原文里不会有它，拼不出歧义。
        return track.id + "\u{0}" + (trackInfo.customLyrics(for: track.id) ?? "")
    }

    /// 勾了「自定义歌词」时用户手打的那份。nil = 没勾。
    ///
    /// 勾了但清空了内容 ⇒ 解析出空数组，照样返回（不回落音源）：那是用户明确表示
    /// 「这首就是没有词」，与负结果缓存同一个含义。
    ///
    /// 手打的文本里若带 `[mm:ss]`，`LyricParser` 照旧把它解析成同步歌词——
    /// 白得的，不用为自定义词另写一条解析。
    private func customLines(for track: Track) -> [LyricLine]? {
        TrackInfoStore.shared.customLyrics(for: track.id).map { LyricParser.parse($0) }
    }

    /// 清空缓存（设置 › 高级 › 还原缓存）。在跑的请求不取消——它们落回来时
    /// 照旧进缓存，那属于「清完之后又取的」。
    func clear() {
        entries.removeAll()
        recency.removeAll()
    }

    private func finish(_ key: String, lines: [LyricLine]) {
        inFlight.removeValue(forKey: key)
        entries[key] = lines
        touch(key)
        while recency.count > capacity {
            let evicted = recency.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }

    private func touch(_ key: String) {
        if let index = recency.firstIndex(of: key) { recency.remove(at: index) }
        recency.append(key)
    }
}
