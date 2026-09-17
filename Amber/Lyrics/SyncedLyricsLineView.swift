import AppKit

/// 一行 = 一个 `NSControl`。悬停提亮、按下缩放、点击跳转都挂在这里。
///
/// 对应 `SyncedLyricsLineView`（源文件`SyncedLyricsLineView_AppKit.swift`）。
final class SyncedLyricsLineView: NSControl {

    var lineLayer: SyncedLyricsLineLayer?          // +8
    /// 未接线：原版字段。Amber 的行位移动画由 view controller 统一持有
    /// （`currentAnimators`），不挂在行视图上。
    var layoutAnimator: LayerPropertyAnimator?     // +16
    /// 未接线：原版字段。Amber 没有自建 AX 元素，行视图本身就是 `NSControl`。
    var lineAccessibilityElements: [Any] = []      // +24

    /// 文档视图是 flipped 的（y 往下长），行视图跟着翻，否则子层的纵向堆叠要倒过来算。
    override var isFlipped: Bool { true }

    /// [实测] `-[SyncedLyricsLineView sizeThatFits:]`——
    /// 行几何调的就是它，实际问的是内容层。
    override func sizeThatFits(_ size: NSSize) -> NSSize {
        lineLayer?.sizeThatFits(width: size.width) ?? .zero
    }

    /// [实测] `-[SyncedLyricsLineView layout]`。
    override func layout() {
        super.layout()
        guard let lineLayer else { return }
        // 外扩一圈给模糊/亮度滤镜溢出用，见 `SyncedLyricsLineLayer.filterBleed`。
        let bleed = SyncedLyricsLineLayer.filterBleed
        let rect = bounds.insetBy(dx: -bleed, dy: -bleed)
        // **不能写 `frame`**：行图层身上一直挂着缩放（未选中 0.98、按下 0.95），
        // 而 `frame` 的 setter 会把缩放反除进`bounds`——未选中行的几何因此比视图
        // 大 2%，0 高的间奏行到了这里是 `24 / 0.98 − 24 = 0.49` 高。
        // 内容层跟着虚胖，`bounds.height <= 0` 那道「折叠了就藏起来」的闸判不出来，
        // 中途 seek 离开间奏时三个点就留在原地压着别的歌词（同一个坑在
        // `InstrumentalContentLayer.layoutSublayers` 的注释里已经记过一次）。
        // 直接写 bounds + position：缩放只影响呈现，不回灌几何。
        lineLayer.bounds = CGRect(origin: .zero, size: rect.size)
        lineLayer.position = CGPoint(x: rect.midX, y: rect.midY)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        lineLayer?.applyAppearance(effectiveAppearance)
    }

    /// 换屏 / 换窗口时把渲染倍率跟上。
    ///
    /// AppKit 只替视图**自己的背衬层**跟随窗口倍率，`lineLayer` 是手工挂上去的
    /// 子层，一律不管——不自己传，整棵树停在 1×（见 `LyricsRenderingScale`）。
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBackingScale()
    }

    func applyBackingScale() {
        lineLayer?.renderingScale = amberWindow?.backingScaleFactor ?? LyricsRenderingScale.current
    }

    // 悬停三道闸与点击见 +Interaction.swift（§4.1 / §4.3），
    // 视图装配与鼠标追踪见 +View.swift。
}
