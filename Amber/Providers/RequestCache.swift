import Foundation

/// 目录类请求的短时缓存 + 同键去重。
///
/// 首页/新发现/广播每页十来个格子并发取数，好几个格子要的是**同一条**接口
///（QQ 的个性电台表被 5 个格子各要一遍，网易云的心情歌单自己就是 7 条并发请求、
/// 又被两个格子各要一遍）。两家的 URLSession 都设了 `reloadIgnoringLocalCacheData`
///（取流/登录这些接口必须拿新的，不能让系统缓存兜底），所以去重与缓存只能自己做。
///
/// 只给目录类接口用：搜索、播放地址、登录态相关（账号歌单、VIP 判定）、歌词都不进这里。
actor RequestCache {

    /// 目录类接口的默认存活时长。一次浏览会话里页面来回切、格子反复出现都能命中；
    /// 5 分钟又短到「新碟上架」「巅峰榜」这类日更内容不会停在旧的一版上。
    static let catalogTTL: TimeInterval = 300

    /// 条目上限。超了就先扫过期的，还超就按到期时间从最早的开始扔。
    ///
    /// 为什么需要上限：键带分页参数（`start` / `offset` / tag），一次长会话里越翻越多，
    /// 而从前**过期条目只会被同键覆盖**——没人翻回第 3 页，第 3 页那条就永远留着。
    /// 一条目录响应几十到几百 KB，攒够几百条就是几十 MB 白占。
    ///
    /// 200 取自这层缓存的实际用量：三个目录页每页十来条接口，来回切页、翻几页，
    /// 一次正常浏览会话的活跃键不到 100；200 给足了余量又不至于让它无限长。
    private static let capacity = 200

    private var entries: [String: (value: any Sendable, expiresAt: Date)] = [:]
    private var inFlight: [String: Task<(any Sendable)?, Never>] = [:]

    /// 取值：命中未过期的缓存直接返回；同键已有在跑的请求就等它，不再发一条。
    ///
    /// `load` 返回 nil 表示这次没取到——**不缓存**，下次照旧重试
    ///（跟原先「失败就回空、下次再要」的行为一致）。
    func value<T: Sendable>(for key: String,
                            ttl: TimeInterval = RequestCache.catalogTTL,
                            load: @escaping @Sendable () async -> T?) async -> T? {
        if let entry = entries[key], entry.expiresAt > Date(), let hit = entry.value as? T {
            return hit
        }
        if let running = inFlight[key] {
            return await running.value as? T
        }
        let task = Task<(any Sendable)?, Never> { await load() }
        inFlight[key] = task
        let value = await task.value
        inFlight.removeValue(forKey: key)
        if let value {
            entries[key] = (value, Date().addingTimeInterval(ttl))
            evictIfNeeded()
        }
        return value as? T
    }

    /// 只在**新写入一条**之后跑，不在读路径上跑：读是热路径（每个格子每次露面都问一次），
    /// 写是冷路径（一次真网络之后才有一条）。
    private func evictIfNeeded() {
        guard entries.count > Self.capacity else { return }
        let now = Date()
        entries = entries.filter { $0.value.expiresAt > now }
        guard entries.count > Self.capacity else { return }
        // 全都还没过期：按到期时间扔掉最早的那几条（同一个 TTL 下等价于「最早写进来的」）。
        let doomed = entries.sorted { $0.value.expiresAt < $1.value.expiresAt }
            .prefix(entries.count - Self.capacity)
        for (key, _) in doomed { entries.removeValue(forKey: key) }
    }
}
