import AppKit
import CoreGraphics

/// 按用途向 provider 请求不同尺寸的封面。
///
/// Music.app 不是所有地方都拉同一张图：`desiredArtworkPixelSizeForItem:` 这个 selector
/// 在十来个模型上各返回一个值，从实测得到的一整套阶梯是（music-metrics 笔记）：
///
/// | 类 | 值 | 对应场景 |
/// | --- | ---: | --- |
/// | `ArtworkCell` | 40 | 列表行的小封面 |
/// | `ArtistInfoModel` | 44 | 信息行里的艺人小头像 |
/// | `ArtistAvatarModel` | 150 | 艺人页圆形头像 |
/// | `EpisodeITItemWrapperModel` / `MovieITItemWrapperModel` | 225 / 400 | 网格卡片两档 |
/// | `PlaylistArtworkLoader` | 400 | 歌单/专辑详情页头部 |
/// | `ITMPMetadataModel` | 800 | 全屏播放器 |
///
/// Amber 原先两个 provider 都写死 `300×300`：迷你播放器 34pt 的封面拉 300px 是浪费，
/// 专辑头 270pt @2x = 540px 又不够清晰。
enum ArtworkSize {
    /// 列表行小封面 [实测] `ArtworkCell.desiredArtworkPixelSizeForItem:` → 40
    static let row: CGFloat = 40
    /// 信息行艺人小头像 [实测] `ArtistInfoModel` → 44
    static let inlineAvatar: CGFloat = 44
    /// 艺人页头像 [实测] `ArtistAvatarModel` → 150
    static let artistAvatar: CGFloat = 150
    /// 网格卡片 [实测] `*ITItemWrapperModel` 的小档 → 225
    static let gridItem: CGFloat = 225
    /// 详情页头部 [实测] `PlaylistArtworkLoader` → 400
    static let header: CGFloat = 400
    /// 全屏播放器 [实测] `ITMPMetadataModel` → 800
    static let fullPlayer: CGFloat = 800

    /// QQ 音乐 CDN 实际支持的封面边长（像素），2026-08-16 逐档探测所得。
    private static let qqSizes = [90, 150, 300, 500, 800, 1200]

    /// 屏幕像素倍率——阶梯是按 point 记的，落到 URL 上要乘回像素。
    private static var scale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }

    /// 把 provider 给的封面地址改写成指定档位。
    ///
    /// 两家的尺寸都写在 URL 里，规则不同：
    /// - 网易云：`…/xxx.jpg?param=300y300`
    /// - QQ 音乐：`…/photo_new/T002R300x300M000{mid}.jpg`
    ///
    /// 认不出来的地址原样返回（本地文件、已带其它查询参数的第三方地址等）。
    static func url(_ urlString: String?, points: CGFloat) -> String? {
        guard let rawURL = urlString, !rawURL.isEmpty else { return nil }
        // 规避 ATS 拦截
        let urlString = rawURL.httpsUpgraded
        let pixels = Int((points * scale).rounded())

        // 网易云：param=WxH（分隔符是 y）
        if let range = urlString.range(of: #"[?&]param=\d+y\d+"#, options: .regularExpression) {
            let prefix = urlString[range.lowerBound]   // 匹配是从 ? 或 & 开始的，原样留住
            return urlString.replacingCharacters(in: range, with: "\(prefix)param=\(pixels)y\(pixels)")
        }
        // QQ：T00xR{size}x{size}M000。
        // T003（榜单/电台头图）CDN 只支持 150/300/500，请求 800 会 404；
        // T002（专辑）支持 90/150/300/500/800/1200。
        if let range = urlString.range(of: #"R\d+x\d+M"#, options: .regularExpression) {
            let isT003 = urlString.contains("/T003")
            let availableSizes = isT003 ? [150, 300, 500] : qqSizes
            let snapped = availableSizes.first { $0 >= pixels } ?? availableSizes[availableSizes.count - 1]
            return urlString.replacingCharacters(in: range, with: "R\(snapped)x\(snapped)M")
        }
        return urlString
    }
}
