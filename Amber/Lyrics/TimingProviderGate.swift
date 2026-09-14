import Foundation

/// 换时间源时的防抖闸门。
///
/// 复现 `SyncedLyricsViewController` 里的时间源更新逻辑。
///
/// 三条判据全部 [实测]：
///
/// 1. 新旧两个 provider 的 `elapsedTime` **绝对差 ≤ 0.5s 就忽略**。
///    注意是「小于等于」：在浮点比较下含相等。
/// 2. `Date.timeIntervalSince(lastTap)` —— **距上次点击 < 1s 就忽略**（取 ≥1s 那条才放行）。
/// 3. 1 秒内没有新的 provider 就回退到旧的。
struct TimingProviderGate {

    /// 判据 1 的阈值。[实测]
    static let minimumElapsedDifference: TimeInterval = 0.5
    /// 判据 2 的阈值。[实测]
    static let minimumIntervalSinceTap: TimeInterval = 1.0
    /// 判据 3 的回退窗口。[实测]
    static let staleProviderTimeout: TimeInterval = 1.0

    enum Decision: Sendable, Equatable {
        case accept
        case ignoreTooClose        // 差值 ≤ 0.5s
        case ignoreRecentTap       // 距点击 < 1s
    }

    var lastTapDate: Date?

    init(lastTapDate: Date? = nil) { self.lastTapDate = lastTapDate }

    /// 判据顺序照原版：先比时间差，再比距上次点击。
    func decide(newElapsed: TimeInterval,
                       currentElapsed: TimeInterval,
                       now: Date = Date()) -> Decision {
        if abs(newElapsed - currentElapsed) <= Self.minimumElapsedDifference {
            return .ignoreTooClose
        }
        if let tap = lastTapDate,
           now.timeIntervalSince(tap) < Self.minimumIntervalSinceTap {
            return .ignoreRecentTap
        }
        return .accept
    }
}
