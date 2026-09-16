import AppKit
import SwiftUI

/// 同步歌词面板。整窗播放器与侧栏检查器共用这一套。
///
/// 里面是 Music 歌词模块的的复刻（`Amber/Lyrics/`，规格见歌词规格与
/// lyrics 规格）：`NSScrollView` + flipped 文档视图，
/// 每行一个 `SyncedLyricsLineView`，滚动是逐帧写`contentView.bounds.origin`，
/// 逐字是一条 30pt 软边的渐变扫过。**外观参数默认取 `LyricsSpecs` 的实测基线**
/// ——字体走 Dynamic Type、当前行贴顶（`selectedLinePosition = .top(12)`）。
///
/// 整窗播放器另有一套覆盖（`Overrides`）：Music 自己也是这么干的——
/// 基线 spec 是侧栏那档，整窗把 `selectedLinePosition` 换成带载荷矩形的
/// `.center(rect:)`、把字号换成`TextStyles.plist` 的四档
/// （nowplaying spec §2.5 与 §8.2）。不传覆盖就是基线，侧栏走这条。
///
/// 歌词面板**自己不 seek**（只把行交给 delegate），
/// 点击一行由 `Coordinator` 转给`PlayerController`。
struct SyncedLyricsView: NSViewControllerRepresentable {

    let lyrics: [LyricLine]
    let player: PlayerController
    /// 面板是不是真的在跟随。整窗播放器收起时传 false，停掉每帧驱动——
    /// 视图留着（展开即完成态），只是不再逐帧走查（[TYPE] `LyricsOptions.isActive`）。
    var isActive = true
    /// 翻译 / 发音两条副行的显隐。**不是把数据摘掉**：数据整份交给歌词视图，
    /// 显隐落在 `LyricsSpecs` 上，切换时走带弹簧的重排
    /// （`setSecondaryLinesVisible`），行视图不拆不建。
    var showsTranslation = true
    var showsTransliteration = true
    /// 整窗播放器的覆盖项；侧栏不传。
    var overrides = Overrides()

    /// 设置 › 通用 ›「更大字体」。歌词面板挂在 AppKit 骨架里（整窗与侧栏两处宿主都
    /// 不在设置窗那棵环境里），所以在这儿直接订阅 `shared`——两个宿主各订一遍
    /// 反而会漏（新宿主一加又得再补一处），落在这条唯一的读取点上最省。
    /// 与 `showsTranslation` 那两条一样，改了走`updateNSViewController` 重建行视图。
    @ObservedObject private var settings = AppSettings.shared

    /// 覆盖基线 spec 的两项。都只影响外观，时间轴与状态机不受影响。
    struct Overrides: Equatable {
        /// [实测] §2.5 B 路的载荷矩形（滚动视图自己的坐标系）：当前行在这个矩形里**垂直居中**
        /// （`y = lineFrame.minY − (rect.height − lineFrame.height)/2 − rect.minY`，
        /// 与行高无关，所以行有没有翻译行都停在同一条线上）。
        /// 整窗播放器把它摆成「以封面中心为中心」，见 `LyricsBaseline`。
        var selectedLineRect: CGRect?
        /// 歌词栏的水平内边距。**必须落在滚动视图里面**（走
        /// `SyncedLyricsViewController.margins`），不能加在滚动视图外面：
        /// 行贴着 clip view 左沿时，逐行模糊往左糊出去的那一圈会被 NSClipView 剪掉，
        /// 未轮到的行左边缘出现一条硬边。[AX] Music 也是这么摆的——滚动区 683、
        /// 行 `[754, …, 645, …]`，19pt 的余量在滚动区之内。
        var horizontalMargin: CGFloat = 0
        /// [资源] `TextStyles.plist` 的整窗四档（28/38/50/72），按歌词栏宽度落档；
        /// 行距跟着一起换（[PX] 顶距 = 2.5 倍字号）。
        /// 基线 spec 的 `font` 走 Dynamic Type 的`.largeTitle`（macOS 约 26pt）、`lineSpacing = 25`。
        var sizeClass: MusicMetrics.Lyrics.SizeClass?
    }

    func makeCoordinator() -> Coordinator { Coordinator(player: player) }

    /// 水平内边距转成控制器的 `margins`。
    private var contentMargins: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: overrides.horizontalMargin,
                     bottom: 0, right: overrides.horizontalMargin)
    }

    /// 把覆盖项叠到基线 spec 上。
    private func makeSpecs() -> LyricsSpecs {
        var specs = LyricsSpecs()
        // 整份词没有时间轴（全是 `.plain` / `.credits`）时切到静态档：一次铺开、
        // 统一亮度、用户自己滚，不高亮不自动滚不点击跳转。判据在数据侧
        // （`[LyricLine].isUntimed`），渲染契约在 `LyricsSpecs.renderingMode`。
        specs.renderingMode = lyrics.isUntimed ? .static : .synced
        specs.showsTranslation = showsTranslation
        specs.showsTransliteration = showsTransliteration
        specs.largerSecondary = settings.values.largerText
        if let rect = overrides.selectedLineRect {
            specs.selectedLinePosition = .center(rect: rect)
        }
        if let sizeClass = overrides.sizeClass {
            specs.font = .systemFont(ofSize: sizeClass.lineSize, weight: .bold)
            // 行距要跟着字号一起换：基线 spec 的 `lineSpacing = 25` 配的是 26pt 的
            // Dynamic Type，直接拿去配 38pt 会挤成 63pt 的顶距。
            // [PX] 整窗 38pt 档实测顶距 95 = 2.5 倍字号，`SizeClass.lineSpacing`
            // 就是按「顶距 − 行盒」反解出来的那个数。
            specs.lineSpacing = sizeClass.lineSpacing
            // 副行**按同一个倍率**跟着换档，不逐档写死。
            //
            // 基线那五个字体是 `LyricsSpecs` 里实测的 TextStyle + bold trait
            // （15 / 12 / 11 / 14），配的是侧栏 24–26pt 的正文；整窗正文换到
            // 28/38/50/72 之后它们一动不动，宽度拉到底也还是最小那一档。
            // [资源] `TextStyles.plist` 10205–10208 给的整窗副行四档 13/17/20/24
            // 就是这里的落点：让基线 15 的 `transliterationFont` 正好落到那个数，
            // 倍率由它反解，另外四处字体按同一倍率跟着走。**留白不跟**——
            // 发音是贴着正文的，`translationSpacing` / `transliterationLineHeightAdjustment`
            // 一放大就在正文与发音之间硬塞一道缝。
            //
            // 早先这段是整个撤掉的，理由是「10205–10212 在 Music 里挂的是
            // 曲名/歌手，没有实测支持」——但撤掉的代价是副行**永远停在最小档**，
            // 比档位可能选错更明显。按倍率缩也把当初那条反对意见解掉了：
            // 两档译文（12 / 15）的比例留着，`translationFont(hasTransliteration:)`
            // 那道 csel 照常选得出档，不会被写成同一个字体。
            // 要换成逐档写死的实测值，拿 Music 50 / 72pt 档译文行的 [PX] 来推。
            //
            // 侧栏档不缩：`TextStyles.plist` 那四档只覆盖整窗，侧栏（10200）没有
            // 对应的副行条目，而 `LyricsSpecs` 实测得到的那五个字体本来就是
            // 侧栏这一档——再乘一次等于把基线缩掉。同 `interludeScale` / `lineSpacing`。
            if sizeClass != .sidebar {
                specs.scaleSecondaryFonts(
                    by: sizeClass.secondarySize / specs.transliterationFont.pointSize)
            }

            // 间奏的点跟着字号档放大，**行高不跟**：[AX] Music 50pt 档实测
            // 点 21 / 间距 13 / 行高 42，行高相对基线 40 几乎没动。
            // 连行高一起放大会让轮到间奏时撑开一大块，看着像「弹出来」。
            let dots = sizeClass.interludeScale
            specs.instrumentalBreakDotLength =
                (specs.instrumentalBreakDotLength * dots).rounded()
            specs.instrumentalBreakDotMargin =
                (specs.instrumentalBreakDotMargin * dots).rounded()
        }
        return specs
    }

    func makeNSViewController(context: Context) -> SyncedLyricsViewController {
        let specs = makeSpecs()
        context.coordinator.appliedOverrides = overrides
        context.coordinator.appliedRenderingMode = specs.renderingMode

        let controller = SyncedLyricsViewController()
        controller.specs = specs
        controller.margins = contentMargins
        controller.delegate = context.coordinator

        let visual = SyncedLyricsVisualExperienceManager()
        visual.specs = specs
        visual.viewController = controller

        let timeline = SyncedLyricsManager(configuration: .init(specs: specs),
                                           maxSelectedLines: specs.maxSelectedLines)
        timeline.delegate = controller
        // 每帧走查要比 `PlaybackClock` 的 10 Hz 细，直接问播放器。
        timeline.elapsedTimeProvider = { [weak player] in player?.elapsedTime ?? 0 }

        visual.manager = timeline
        controller.manager = visual
        visual.timingProvider = player
        controller.isActive = isActive

        return controller
    }

    func updateNSViewController(_ controller: SyncedLyricsViewController, context: Context) {
        controller.isActive = isActive
        // 副行显隐单独走一条带弹簧的重排，不并进下面那套「换歌就重建」。
        controller.setSecondaryLinesVisible(translation: showsTranslation,
                                            transliteration: showsTransliteration)
        let coordinator = context.coordinator
        let identity = Coordinator.identity(of: lyrics)
        // 字号档换了要连带重建行视图：字体是在 `configure(line:specs:)` 里落到层上的，
        // 光改 specs 不会让已经建好的行改字号。跨档只发生在窗口拉过断点时，不是每帧。
        // 「更大字体」按同一条走：它把两条副行的档位对调，已经建好的行同样不会自己改。
        let fontsChanged = coordinator.appliedOverrides.sizeClass != overrides.sizeClass
            || coordinator.appliedLargerText != settings.values.largerText
        let rectChanged: Bool = {
            guard let r1 = coordinator.appliedOverrides.selectedLineRect,
                  let r2 = overrides.selectedLineRect else {
                return (coordinator.appliedOverrides.selectedLineRect == nil) != (overrides.selectedLineRect == nil)
            }
            return abs(r1.minY - r2.minY) > 0.5 || abs(r1.height - r2.height) > 0.5
        }()
        let marginsChanged =
            coordinator.appliedOverrides.horizontalMargin != overrides.horizontalMargin
        // 有戳 ⇄ 无戳换歌时渲染档也得跟着换。**必须并进重建行视图那条析取**：
        // 换歌本来就因 `identity` 变了而重建行，但 specs 还停在上一首的档上，
        // 静态档等于没开；而「诞生模糊 / 诞生即选中」恰恰是在建行那一步落下去的，
        // 跟字号档同理——光改 specs 不会让已经建好的行改外观。
        let renderingMode: LyricsSpecs.RenderingMode = lyrics.isUntimed ? .static : .synced
        let modeChanged = coordinator.appliedRenderingMode != renderingMode

        if marginsChanged {
            controller.margins = contentMargins
            controller.relayoutEverything()
        }

        if fontsChanged || rectChanged || marginsChanged || modeChanged {
            let specs = makeSpecs()
            controller.specs = specs
            controller.manager?.specs = specs
            coordinator.appliedOverrides = overrides
            coordinator.appliedLargerText = settings.values.largerText
            coordinator.appliedRenderingMode = renderingMode
            // 每帧驱动的开关也读 `renderingMode`（静态档不起链），而它只在
            // `isVisible` / `isActive` 变化时才被推一次——换档这条路没人推，
            // 这里显式补一次。两个方向都要：切进静态档要停链，切回来要重开。
            controller.updateDisplayLink()
        }

        // 只在真的换了歌词时重建行视图——SwiftUI 每次更新都重排的话，
        // 一首歌几十个 `NSView` 加一堆`CATextLayer` 会被反复拆建。
        if coordinator.lyricsIdentity != identity || fontsChanged || modeChanged {
            coordinator.lyricsIdentity = identity
            controller.setLyrics(LyricsAdapter.makeLyrics(from: lyrics))
        } else if rectChanged {
            // 只挪了基线：重算几何落位并把当前行滑到新位置——
            // 这就是 [实测] §8.1 那条 `offsetObservation → activeBaselineConstraint`。
            controller.relayoutEverything()
            controller.reanchorSelectedLine()
        }
    }

    /// SwiftUI 把这块面板拆掉时的停机口。
    ///
    /// `startDisplayLink` 用的`view.displayLink(target: self, …)` **强引用控制器**，
    /// 而 SwiftUI 拆 `NSViewControllerRepresentable` 时不保证走
    /// `viewWillDisappear`（整窗播放器收起时就只是把整块挪出窗口，一次都不走）——
    /// 没有这一口，链子不 `invalidate`，控制器活着、每帧照跑。
    static func dismantleNSViewController(_ controller: SyncedLyricsViewController,
                                          coordinator: Coordinator) {
        controller.tearDown()
    }

    final class Coordinator: SyncedLyricsViewControllerDelegate {
        private let player: PlayerController
        var lyricsIdentity: Int = 0
        var appliedOverrides = Overrides()
        /// 上一次落到行视图上的「更大字体」档。它不在 `Overrides` 里（那是整窗
        /// 播放器的覆盖项，这条是应用级偏好），单记一份。
        var appliedLargerText = AppSettings.shared.values.largerText
        /// 上一次下发的渲染档。有戳 ⇄ 无戳来回换歌时靠它判断要不要重建行视图。
        var appliedRenderingMode: LyricsSpecs.RenderingMode = .synced

        init(player: PlayerController) { self.player = player }

        /// 行的身份：条数 + 首尾时间 + 首行文字。够区分换歌，又不必逐行比。
        ///
        /// 副行显隐**不**并进来：那条路不改数据，只改 spec 再重排，
        /// 见 `setSecondaryLinesVisible`。
        static func identity(of lyrics: [LyricLine]) -> Int {
            var hasher = Hasher()
            hasher.combine(lyrics.count)
            hasher.combine(lyrics.first?.time ?? 0)
            hasher.combine(lyrics.last?.end ?? 0)
            hasher.combine(lyrics.first?.text ?? "")
            return hasher.finalize()
        }

        func syncedLyricsViewController(_ controller: SyncedLyricsViewController,
                                        didTap line: (any LyricsLine)?) {
            // 词曲作者那一行的时间是 ∞，点不动。
            guard let line, line.startTime.isFinite else { return }
            player.seek(to: line.startTime)
        }
    }
}


extension SyncedLyricsViewController {

    /// 基线（`selectedLinePosition`）变了之后，把当前选中行重新滑到新落点。
    ///
    /// 走的是既有的 `jump(to:animated:)`：目标行与视口相交才动画、完全不可见就硬跳
    /// （§2.7）。没有选中行（还没起播 / 歌词为空）时什么都不做，
    /// 下一次 `didSelect` 自然会用新的 spec 落位。
    func reanchorSelectedLine() {
        guard let visual = manager,
              let view = visual.selectedLineViews.last,
              let index = visual.lineViews.firstIndex(of: view),
              let line = lyrics?.lines[safe: index]
        else { return }
        jump(to: line, animated: true)
    }
}
