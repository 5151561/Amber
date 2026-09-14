import AppKit
import QuartzCore

/// 三种内容层的公共面。
///
/// [实测] 选中态是经由存在体（`any …ContentLayer`）派发到`setSelected(_:animated:)` 的，
/// 也就是说 `contentLayer` 在原版里并不是某个具体类；间奏那一档另有一次到间奏内容层的
/// 动态转型。
///
/// 除了 `setSelected` 那一条是实测确认的，其余三条是排版与拖动要用的口子，
/// 原版一定有对应物（行几何要调 `sizeThatFits:`、§9.9 第二段要把「正在拖」转告内容层），
/// 但确切签名未定。`[补]`
protocol SyncedLyricsContentLayer: CALayer {
    /// `(selected, animated)`。
    func setSelected(_ selected: Bool, animated: Bool)
    /// 浏览期间的外观：非播放行提到 40%，当前播放行保留高亮进度。
    /// `animated` 由调用方按「这一行此刻在不在视口里」给：屏外的行直接落值，
    /// 建一条谁也看不见的 0.12s 淡变没有意义（拖动第一帧是全表一起下发的）。
    func setScrolling(_ scrolling: Bool, animated: Bool)
    /// 给定可用宽度，内容要占多大。行几何拿它测行高。
    func sizeThatFits(width: CGFloat) -> CGSize
    /// 外观（高对比度与否）变了要重新解析颜色。
    func updateAppearance(specs: LyricsSpecs, appearance: NSAppearance?)
    /// 只换了「翻译 / 发音显不显示」这两个开关时的更新口。
    /// 默认就是 `updateAppearance`；能只动副行那几层的内容层自己覆盖。
    func applySecondaryLineVisibility(specs: LyricsSpecs, appearance: NSAppearance?)
}

extension SyncedLyricsContentLayer {

    /// 默认实现：整行档与间奏层没什么可省的——整行档的 `updateAppearance`
    /// 本来就只是切一下可见性再请一次布局，间奏层压根没有副行。
    func applySecondaryLineVisibility(specs: LyricsSpecs, appearance: NSAppearance?) {
        updateAppearance(specs: specs, appearance: appearance)
    }
}
