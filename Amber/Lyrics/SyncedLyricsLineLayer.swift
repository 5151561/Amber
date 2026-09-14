import CoreImage
import QuartzCore

/// 一行的图层。三种内容层三选一，外面统一挂逐行模糊与亮度滤镜。
///
/// 对应 `SyncedLyricsLineLayer`（源文件`SyncedLyricsLineLayer.swift`）。
final class SyncedLyricsLineLayer: CALayer {

    var specs = LyricsSpecs()                 // +8
    var line: (any LyricsLine)?               // +888

    /// 三选一，见 `ContentKind`。存在体（`any SyncedLyricsContentLayer`）——
    /// 同一个字段槽指的是**两个连续槽**（对象 + 类型槽），
    /// 直接取调
    /// `setSelected(_:animated:)`。
    var contentLayer: (any SyncedLyricsContentLayer)?  // +

    /// 逐行模糊 + 逐行亮度，按 `isLineFocused` 二值切换，`previousBlurRadius` 做插值。
    ///
    /// 原版这两个是 `CAFilter`（私有类）。Amber 不碰私有 API，换成同名的`CIFilter`：
    /// 把 `CIFilter.name` 设成`gaussianBlur` / `colorBrightness` 之后，
    /// `CALayer` 就按这个名字在`filters` 数组里找它，于是 ASM 里那两条 keyPath
    /// 字面量可以原样保留（亮度那条的**输入键**不同，见 `+Focus.swift`）。
    var blurFilter: CIFilter?
    var brightnessFilter: CIFilter?
    var blurRadius: CGFloat = 0
    /// 未接线：`setBlurRadius` 每次都写它，但没有读口——Amber 的模糊动画直接从
    /// `blurRadius` 的旧值起跳，不需要额外记一份。
    var previousBlurRadius: CGFloat = 0

    /// 整行（含内容层）的渲染倍率，见 `LyricsRenderingScale`。
    /// 由 `SyncedLyricsLineView` 按所在窗口的`backingScaleFactor` 灌下来。
    var renderingScale: CGFloat = LyricsRenderingScale.current {
        didSet {
            guard renderingScale != oldValue else { return }
            applyRenderingScale(renderingScale)
        }
    }

    var isSelected = false
    /// 未接线：`setHovered` 会写它，但外观全由`isLineFocused` 那一路决定，没有读口。
    var isHighlighted = false
    var isLineFocused = false
    /// 未接线：`applyScrolling` 写它并同时转告内容层，判色用的是**内容层自己**
    /// 那份 `isScrolling`（同一个字段槽，见 §9.9 第二段），这份没有读口。
    var isScrolling = false

    /// 行图层比文字盒四周各大这么多，专门留给滤镜溢出。
    ///
    /// `filters` 的输出被**滤镜所在图层的 bounds** 裁掉，而行几何给出的
    /// frame 恰好贴着文字盒——模糊糊出去的那一圈会被切平，未轮到的行在
    /// 最左边、最下边看得到一条硬边。这里让行图层四周各外扩 12pt
    /// （= 模糊半径上限 4 的 3 倍，足够 `CIGaussianBlur` 铺完），
    /// `layoutSublayers` 再把内容层内缩同样的量，文字落点一点不变。
    static let filterBleed: CGFloat = 12

    /// 内容层三选一。
    enum ContentKind: Sendable {
        case sbsText        // 逐字：Line → Word → Syllable → Glyph 四层
        case despacito      // 整行：主 / 翻译 / 音译三个 TextContentLayer
        case instrumental   // 间奏三个点，见 InstrumentalContentLayer.swift
    }

    // 批次 9：聚焦（悬停）外观见 SyncedLyricsLineLayer+Focus.swift，
    //   选中态与模糊见 SyncedLyricsLineLayer+Selection.swift，规格 §9.4 / §9.6。
    // 批次 7：四层结构（Line/Word/Syllable/Glyph）与逐字进度见
    //   SyncedLyricsLineLayer+Progress.swift，规格 §7。
    // 批次 8：（抬升 / 强调 / 去辉光）见
    //   LineProgressGradientLayer+Layout.swift 的 SyllableEmphasis，规格 §8.1。
}
