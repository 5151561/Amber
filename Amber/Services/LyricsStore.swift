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
