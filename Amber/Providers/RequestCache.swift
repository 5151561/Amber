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
        }
        return value as? T
    }
}
