import AppKit
import QuartzCore

/// 歌词图层树的渲染倍率。
///
/// 行图层会开 `shouldRasterize`（§9.4 的聚焦动画收尾），而 `CALayer` 的
/// `rasterizationScale` 默认是 **1.0**——不跟着设，缓存位图就按 1× 画好再放大到
/// 屏幕倍率，Retina 上整行字直接糊掉一半。`contentsScale` 同理：新建的子层默认 1.0，
/// AppKit 只会替**视图自己的背衬层**跟随窗口倍率，手工挂上去的子层一律不管。
///
/// 还有一个连带后果：图层滤镜跑在图层自己的渲染空间里，`contentsScale = 1` 时
/// `CIGaussianBlur.inputRadius = 3` 落到 2× 屏上视觉半径翻倍——非当前行糊得比
/// Music 重一倍就是这么来的。倍率设对，字清晰和模糊量两件事一起归位。
enum LyricsRenderingScale {
    /// 还没上屏时的缺省值。
    ///
    /// 真值由 `SyncedLyricsLineView.applyBackingScale` 按**所在窗口**灌下来
    /// （`viewDidChangeBackingProperties` / `viewDidMoveToWindow` 两个口子），
    /// 这里只管「还没有窗口可问」的那一小段。
    ///
    /// 取的是**全部屏幕里最大的那个倍率**，不是 `NSScreen.main`：主屏的定义是
    /// 「菜单栏在哪块」，跟这棵层树要画在哪块屏上没有关系。两个方向的错法代价
    /// 不对称——多取只是这一小段多画几个像素，少取是 2× 屏上首帧整行字发糊
    /// （连带模糊量也按 §9.6 那段翻倍）。`[推]`
    static var current: CGFloat {
        NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
    }
}

extension CALayer {
    /// 把渲染倍率灌进整棵子层树（含 mask）。
    func applyRenderingScale(_ scale: CGFloat) {
        guard scale > 0 else { return }
        if contentsScale != scale { contentsScale = scale }
        if rasterizationScale != scale { rasterizationScale = scale }
        mask?.applyRenderingScale(scale)
        sublayers?.forEach { $0.applyRenderingScale(scale) }
    }
}
