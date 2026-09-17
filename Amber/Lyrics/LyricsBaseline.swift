import AppKit

/// 歌词面板与整窗播放器之间那条桥剩下的东西：**当前行停在哪**。
///
/// Music 这条桥是 `LyricsViewController`（源文件名实测 **Music/Lyrics.swift:18**，
/// 见 nowplaying spec §8.1），桥上挂着三样：
///
/// ```
/// Lyrics       viewModel / options / lyricsViewController / footerButton / viewProvider
/// LyricsOptions                      _isVisible / _isActive / _buildOptionsMenu / _$observationRegistrar
/// LyricsViewController               lyrics: NSViewController / options / activeBaselineConstraint / offsetObservation
/// ```
///
/// 三件事在 Amber 这边各自归位，不再单立类型：
///
/// 1. **装配**（`viewDidLoad`：子 VC 的 view`addAndAlignSubview:` +
///    `addChildViewController:`）→`InspectorLyricsViewController` 直接持有
///    `SyncedLyricsViewController` 当子控制器。
/// 2. **弱引用宿主**（`swift_weakInit`）→ 歌词控制器不持有播放器，
///    时间由 `SyncedLyricsTimingProvider` 供给。
/// 3. **偏移观察 → 基线约束**（`offsetObservation +32` → `activeBaselineConstraint +24`）：
///    容器几何一变（抽屉开合、窗口缩放）就把新的基线传导给歌词布局
///    →`InspectorLyricsViewController.setArtworkCenter(offsetFromPanelTop:)`
///    + 每次 `viewDidLayout` 重算。本文件是那一步的换算。
///
/// [TYPE] `LyricsOptions` 那三个字段也都归了位：`_isVisible` = 容器当前摆的是哪一档
/// （`InspectorContainerViewController.mode`）、`_isActive` =
/// `InspectorLyricsViewController.isActive`、`_buildOptionsMenu` = 底栏那颗歌词键
/// 自己的 `NSMenu`。
///
/// [TYPE] nowplaying spec §8.3 那两个同名不同形的 `DurationSnapshot` 不用再造：
/// 时间由 `SyncedLyricsTimingProvider`（`PlayerController.elapsedTime` + `isPaused`）
/// 直接供给，防抖走 `TimingProviderGate`（lyrics spec §1.4）——正好对应主程序那份
/// 「播放时刻 + 是否暂停」的三字段快照。
///
/// 而「哪一行、怎么亮、怎么滚」全在 `Amber/Lyrics/` 那套歌词模块复刻里，本文件不碰。

// MARK: - 基线（offsetObservation → activeBaselineConstraint）

/// 歌词当前行停在哪个高度。
///
/// 实测给了两头：
/// - `LayoutHints` 实测**只有**`primaryArtworkCenterY` / `hostedContentMinY` 两个可选 CGFloat
///   （nowplaying spec §6.1）——布局与歌词要同步的锚点就这两个；
/// - 桥上挂着 `offsetObservation` + `activeBaselineConstraint`（§8.1）。
///
/// 两头一拼就知道基线是拿封面中心算的。对得上实测：
/// 基线窗口 923 高时封面顶 182、底 585.5 → 中心 **383.75**；
/// 而歌词侧 [PX] 量到的当前行墨迹中心 = 窗口高 × **0.417** = 384.9。
/// 两个独立量出来的数差 1.2pt——**当前行是与封面中心对齐的**，
/// 不是「窗口高的 0.417」那个巧合比例。
///
/// 换算出来的矩形喂给 `LyricsSpecs.selectedLinePosition = .center(rect:)`，
/// 也就是 lyrics spec §2.5 分派表里读载荷的那一支（B 路：行在载荷矩形里**垂直居中**，
/// `y = lineFrame.minY − (rect.height − lineFrame.height)/2 − rect.minY`）。
enum LyricsBaseline {
    /// 把「封面中心距歌词面板顶边多少」换算成歌词滚动视图坐标系里的载荷矩形。
    ///
    /// 载荷只有 `midY` 有意义（B 路的公式只用到`minY` 与`height`），
    /// 高度取面板高、宽度取面板宽，纯粹是为了读起来还是「那个容器」。
    /// 矩形可以探出视口（minY 为负），不影响。
    ///
    /// - Parameters:
    ///   - artworkCenterY: 封面中心在 `panel` 这个坐标系里的 y
    ///     （[实测] §6.1 `LayoutHints.primaryArtworkCenterY`）。
    ///   - panel: 歌词滚动区在同一坐标系里的矩形。
    /// - Returns: nil 表示面板尺寸尚未就绪（height <= 1）。
    static func selectedLineRect(artworkCenterY: CGFloat?, panel: CGRect) -> CGRect? {
        guard panel.height > 1 else { return nil }
        let targetY: CGFloat
        if let artworkCenterY {
            targetY = artworkCenterY - panel.minY        // 换算进滚动视图自己的坐标系
        } else {
            // 锚点尚未报上来时以 0.381 视口高兜底，避免回退贴顶
            targetY = panel.height * MusicMetrics.Lyrics.viewportAnchorRatio
        }
        return CGRect(x: 0, y: targetY - panel.height / 2,
                      width: panel.width, height: panel.height)
    }

    /// [PX] lyrics spec §22.3 侧栏检查器歌词基线：以视口高 × 0.381 为焦点组框中心。
    static func sidebarSelectedLineRect(panelHeight: CGFloat, panelWidth: CGFloat) -> CGRect? {
        guard panelHeight > 1 else { return nil }
        let h = panelHeight.rounded()
        let w = panelWidth.rounded()
        let targetY = (h * MusicMetrics.Lyrics.viewportAnchorRatio).rounded()
        return CGRect(x: 0, y: targetY - h / 2,
                      width: w, height: h)
    }
}
