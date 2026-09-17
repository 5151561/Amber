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

    /// 本地封面的档位标记，写在 URL 片段里。只有 `ImageCache` 认它，见 `url(_:points:scale:)`。
    static let localPixelMarker = "amber-px="

    /// 没人给倍率时的兜底。阶梯是按 point 记的，落到 URL 上要乘回像素。
    ///
    /// 取的是**全部屏幕里最大的那个倍率**，不是 `NSScreen.main`：主屏的定义是
    /// 「菜单栏在哪块」，跟这张封面要画在哪块屏上没有关系——1× 外接 + 2× 内置的
    /// 机器上按主屏取，有一半时间取错档。两个方向的错法代价不对称：多取像素只是
    /// 浪费带宽与内存，少取是 2× 屏上当场发虚，所以兜底往大的取。`[推]`
    ///
    /// 能问出所在窗口的调用点一律传 `scale:`（`view.amberWindow?.backingScaleFactor`），
    /// 别让它落到这条兜底上。
    static var defaultScale: CGFloat {
        NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
    }

    /// 把 provider 给的封面地址改写成指定档位。
    ///
    /// 两家的尺寸都写在 URL 里，规则不同：
    /// - 网易云：`…/xxx.jpg?param=300y300`
    /// - QQ 音乐：`…/photo_new/T002R300x300M000{mid}.jpg`
    ///
    /// 本地文件（`file://`）地址里没有档位段可改，改成把「我只要这么大」写进
    /// **URL 片段**：`ImageCache` 认这一句去降采样，顺带让缓存键自带档位——
    /// 40pt 的行与 400pt 的头不再共用同一张 3000px 的位图。
    /// 片段不参与文件定位（[实测 probe] `Data(contentsOf:)` 与
    /// `URLSession.data(from:)` 拿到 `file://…/x.png#amber-px=80` 都照读原文件），
    /// 所以路过别的消费方也不会坏。地址自己已经带片段的不动它。
    ///
    /// 其余认不出来的地址原样返回（已带其它查询参数的第三方地址等）。
    ///
    /// - Parameter scale: 这张图要画在哪块屏上的背衬倍率。给不出时退到 `defaultScale`。
    static func url(_ urlString: String?, points: CGFloat, scale: CGFloat? = nil) -> String? {
        guard let rawURL = urlString, !rawURL.isEmpty else { return nil }
        // 规避 ATS 拦截
        let urlString = rawURL.httpsUpgraded
        let pixels = Int((points * (scale ?? defaultScale)).rounded())

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
        // 本地文件：档位写进片段，交给 `ImageCache` 降采样。
        if urlString.hasPrefix("file:"), !urlString.contains("#"), pixels > 0 {
            return "\(urlString)#\(localPixelMarker)\(pixels)"
        }
        return urlString
    }
}
