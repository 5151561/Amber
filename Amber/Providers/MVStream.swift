import Foundation

/// MV 的一档画质。
///
/// 两家音源给的都是**明文 https 渐进式 mp4**（H.264 + AAC，`Content-Type: video/mp4`，
/// 对 `Range` 回 206），直接交给 `AVPlayer` 就能播，跟音频那条路一样不需要解密。
/// [实测 2026-09-07 curl]
struct MVVariant: Equatable, Sendable {
    /// 画面高度（360 / 480 / 720 / 1080…）。选档、命名、报文案都只认它。
    let height: Int
    let url: URL
    /// 服务端报的字节数；没给就是 0。
    var bytes: Int = 0
}

extension MVVariant {

    /// 按画质上限挑一档：不超过上限的最高一档；`maxHeight == nil` 就是有多高要多高。
    ///
    /// 整个阶梯都高于上限时**给最低的那一档**——上限是「别浪费带宽」的意思，
    /// 不是「宁可放不了」；音频那条路的降级阶梯也是这个脾气（`StreamQuality.ladder`）。
    static func pick(_ variants: [MVVariant], maxHeight: Int?) -> MVVariant? {
        let sorted = variants.sorted { $0.height > $1.height }
        guard let maxHeight else { return sorted.first }
        return sorted.first { $0.height <= maxHeight } ?? sorted.last
    }
}

// MARK: - 设置里的两档 → 画面高度上限

extension VideoStreamQuality {
    /// 设置 › 播放 ›「视频质量 › 流播放」的画面高度上限。nil = 不封顶。
    ///
    /// 「较佳」「最佳」的括号是 Music 自己写的（最高1080p / 最高4K），照抄即可；
    /// 「良好」Music 没写数字，[推] 封到 480p——那是两家音源都稳定给得出的最低一档
    ///（QQ filetype 20 = 848×476，网易 r=480），再往下 360p 已经糊到没法看。
    var maxHeight: Int? {
        switch self {
        case .good: return 480
        case .better: return 1080
        case .best: return nil
        }
    }
}

extension VideoDownloadQuality {
    /// 设置 › 播放 ›「视频质量 › 下载」的画面高度上限。nil = 不封顶。
    ///
    /// 「最兼容的格式」在 Music 那边指的是 H.264 + AAC 的 mp4（老 iPod/AppleTV 也能放）；
    /// **两家音源本来就只发这一种容器**（QQ 的 `format=264`、网易的 vod mp4，
    /// [实测 2026-09-07] 响应头 `vcodec=h264 acodec=aac`），所以这一档在 Amber 里
    /// 只剩「挑一档保守的分辨率」这一层意思，[推] 封到 720p。
    var maxHeight: Int? {
        switch self {
        case .hd: return 1080
        case .sd: return 480
        case .compatible: return 720
        }
    }
}
