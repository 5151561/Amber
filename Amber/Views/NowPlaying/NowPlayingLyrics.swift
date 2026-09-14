import Combine
import SwiftUI

/// 歌词面板与整窗播放器之间的桥。
///
/// Music 这条桥是 `LyricsViewController`（源文件名实测
/// **Music/Lyrics.swift:18**，见 nowplaying spec §8.1），三个模型的字段表是
/// 实测的：
///
/// ```
/// Lyrics       viewModel / options / lyricsViewController / footerButton / viewProvider
/// LyricsOptions                      _isVisible / _isActive / _buildOptionsMenu / _$observationRegistrar
/// LyricsViewController               lyrics: NSViewController / options / activeBaselineConstraint / offsetObservation
/// ```
///
/// 三件事照搬过来：
///
/// 1. **装配**（`viewDidLoad`）：子 VC 的 view`addAndAlignSubview:` 贴附到容器 +
///    `addChildViewController:`。SwiftUI 侧对应`FullWindowHostedContentView` 把歌词视图
///    以 `.frame(maxWidth:maxHeight: .infinity)` 铺进右半区，容器不越俎代庖排版。
/// 2. **弱引用宿主**（`swift_weakInit`）：歌词面板不持有播放器。
///    这里同解——`NowPlayingLyrics` 只有数据与开关，不引用`AppState` / 播放器。
/// 3. **偏移观察 → 基线约束**（`offsetObservation +32` → `activeBaselineConstraint +24`）：
///    容器几何一变（抽屉开合、窗口缩放）就把新的基线传导给歌词布局。
///    Amber 用 `LayoutHints.primaryArtworkCenterY` 走同一条路，见下面`LyricsBaseline`。
///
/// 而「哪一行、怎么亮、怎么滚」全在 `Amber/Lyrics/` 那套 Music 的歌词模块复刻里
/// （lyrics 侧规格，lyrics 规格），本文件一概不碰。

// MARK: - LyricsOptions

/// [TYPE] `LyricsOptions`：`_isVisible` / `_isActive` / `_buildOptionsMenu`。
///
/// 两个 Bool 不是一回事：`isVisible` 是**抽屉开着**（底栏那颗键的开关态），
/// `isActive` 是**面板真的在跟随**（有歌词内容、且没被折叠遮住）。
/// Music 的底栏键读前者、歌词自身的动画节流读后者。
@MainActor
final class LyricsOptions: ObservableObject {
    @Published var isVisible = true
    @Published var isActive = false
    // [TYPE] 第三个字段 `_buildOptionsMenu: (() -> NSMenu?)?`（歌词自己供菜单、宿主只负责摆）
    // 在 Amber 里落成 `LyricsOptionsMenu`——SwiftUI 的菜单内容直接挂在底栏那颗键的
    // `.contextMenu` 上，不需要再存一个闭包。
}

// MARK: - 时间源

// [TYPE] §8.3 那两个同名不同形的 DurationSnapshot（Music 的播放界面层六字段 / 主程序三字段）
// 在 Amber 这边不用再造：歌词面板是 `Amber/Lyrics/` 那套 AppKit 复刻，
// 时间由 `SyncedLyricsTimingProvider`（`PlayerController.elapsedTime` + `isPaused`）
// 直接供给，防抖走 `TimingProviderGate`（lyrics spec §1.4）——
// 正好对应主程序那份「播放时刻 + 是否暂停」的三字段快照，语义一致。

// MARK: - 歌词模型（Lyrics）

@MainActor
final class NowPlayingLyrics: ObservableObject {
    let options = LyricsOptions()

    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var isLoading = false
    /// 当前这份歌词是哪首歌的。换歌时先清空再取，避免上一首的词挂在新歌上。
    @Published private(set) var loadedTrackID: String?

    private var optionsObserver: AnyCancellable?

    init() {
        // 嵌套的 ObservableObject 不会自动向上冒泡，转发一次，
        // 这样 `NowPlayingViewModel.isLyricsOpen` 才跟着开关变。
        optionsObserver = options.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var isEmpty: Bool { lines.isEmpty }

    func clear() {
        lines = []
        loadedTrackID = nil
        options.isActive = false
    }

    /// 取词走 `LyricsStore`：与侧栏歌词共用一份缓存，同一首在两处之间来回切只打一次网络。
    /// 命中缓存时不先清空——直接从上一首的词换成这一首的，中间不插一帧空态。
    func load(track: Track?, using provider: any MusicProvider, isPlaying: Bool) async {
        guard let track else {
            clear()
            return
        }
        if let cached = LyricsStore.shared.cachedLyrics(for: track) {
            apply(cached, of: track, isPlaying: isPlaying)
            return
        }
        clear()
        isLoading = true
        defer { isLoading = false }
        let loaded = await LyricsStore.shared.lyrics(for: track, using: provider)
        // 换歌时 `.task(id:)` 会取消上一份，取消后回来的结果不能再写进去。
        guard !Task.isCancelled else { return }
        apply(loaded, of: track, isPlaying: isPlaying)
    }

    private func apply(_ loaded: [LyricLine], of track: Track, isPlaying: Bool) {
        lines = loaded
        loadedTrackID = track.id
        updateActivity(isPlaying: isPlaying)
    }

    /// [TYPE] `LyricsOptions._isActive`：面板**真的在跟随**＝抽屉开着、有词、且在播。
    /// 与 `isVisible`（抽屉开关）分开——底栏那颗键读`isVisible`，
    /// 跟随相关的节流读 `isActive`。
    func updateActivity(isPlaying: Bool) {
        options.isActive = options.isVisible && !isEmpty && isPlaying
    }
}

// MARK: - 基线（offsetObservation → activeBaselineConstraint）

/// 歌词当前行停在哪个高度。
///
/// 实测给了两头：
/// - `LayoutHints` 实测**只有**`primaryArtworkCenterY` / `hostedContentMinY` 两个可选 CGFloat
///   （nowplaying spec §6.1）——SwiftUI 布局与 AppKit 侧要同步的锚点就这两个；
/// - 桥上挂着 `offsetObservation` + `activeBaselineConstraint`（§8.1）。
///
/// 两头一拼就知道基线是拿封面中心算的。对得上实测：
/// 基线窗口 923 高时封面顶 182、底 585.5 → 中心 **383.75**；
/// 而歌词侧 [PX] 量到的当前行墨迹中心 = 窗口高 × **0.417** = 384.9。
/// 两个独立量出来的数差 1.2pt——**当前行是与封面中心对齐的**，
/// 不是「窗口高的 0.417」那个巧合比例。
///
/// 换算出来的矩形喂给 `LyricsSpecs.selectedLinePosition = .center(rect:)`，
/// 也就是 §2.5 分派表里读载荷的那一支；拿不到锚点（歌词摆在侧栏时）就不覆盖，
/// 用基线 spec 的 `.top(12)`。
enum LyricsBaseline {
    /// 把公共坐标系里的封面中心，换算成歌词滚动视图坐标系里的载荷矩形。
    ///
    /// 载荷只有 `midY` 有意义（§2.5 的 B 路把行在矩形里垂直居中，
    /// `y = lineFrame.minY − (rect.height − lineFrame.height)/2 − rect.minY`），
    /// 高度取面板高、宽度取面板宽，纯粹是为了读起来还是「那个容器」。
    /// 矩形可以探出视口（minY 为负），公式只用到 minY 与 height，不影响。
    ///
    /// - Parameters:
    ///   - artworkCenterY: `LayoutHints.primaryArtworkCenterY`
    ///   - panel: 歌词滚动区在同一坐标系里的矩形
    /// - Returns: nil 表示锚点还没报上来，这时用 `LyricsSpecs` 的基线落点（`.top(12)`）。
    static func selectedLineRect(artworkCenterY: CGFloat?, panel: CGRect) -> CGRect? {
        guard let artworkCenterY, panel.height > 1 else { return nil }
        let targetY = artworkCenterY - panel.minY        // 换算进滚动视图自己的坐标系
        return CGRect(x: 0, y: targetY - panel.height / 2,
                      width: panel.width, height: panel.height)
    }
}

// MARK: - 布局锚点的传递

/// 整窗播放器的公共坐标系名。两个 LayoutHint 都记在这里面。
enum NowPlayingCoordinateSpace {
    static let name = "nowPlaying"
}

/// [实测] §6.1 `LayoutHints.primaryArtworkCenterY`
struct PrimaryArtworkCenterYKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// [实测] §6.1 `LayoutHints.hostedContentMinY`
/// 歌词面板与待播盘会**同时**上报（两个抽屉共用右半区），所以不能「后来者覆盖」——
/// 那样谁赢取决于 SwiftUI 的访问顺序。语义是「托管区的顶边」，取两者较小的那个。
struct HostedContentMinYKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        guard let next = nextValue() else { return }
        value = value.map { Swift.min($0, next) } ?? next
    }
}

extension View {
    /// 把自己的中心 y 报成 `primaryArtworkCenterY`（封面用）。
    func reportsPrimaryArtworkCenterY() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: PrimaryArtworkCenterYKey.self,
                    value: geo.frame(in: .named(NowPlayingCoordinateSpace.name)).midY)
            })
    }

    /// 把自己的顶边报成 `hostedContentMinY`（歌词/待播盘用）。
    func reportsHostedContentMinY() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: HostedContentMinYKey.self,
                    value: geo.frame(in: .named(NowPlayingCoordinateSpace.name)).minY)
            })
    }
}

// MARK: - FullWindowHostedContentView

/// [TYPE] `NowPlayingView.FullWindowHostedContentView`：整窗播放器右半区那块「托管内容」，
/// 歌词就装在这里（`hostedContentToggleButton` 是底栏那颗键）。
///
/// 这一层只做三件事，与 `LyricsViewController.viewDidLoad` 的三步对应：
/// 贴附子视图、把容器几何换算成基线、按 §8.2 的宽度域决定字号档。
struct FullWindowHostedContentView: View {
    @ObservedObject var lyrics: NowPlayingLyrics
    /// [实测] §6.1 `LayoutHints.primaryArtworkCenterY`——基线的唯一来源。
    let artworkCenterY: CGFloat?
    let player: PlayerController
    /// 面板是不是真的在跟随（[TYPE] `LyricsOptions.isActive`）。
    var isActive = true

    @AppStorage(LyricsTranslationOptions.showTranslationKey)
    private var showTranslation = LyricsTranslationOptions.showTranslationDefault
    @AppStorage(LyricsTranslationOptions.showTransliterationKey)
    private var showTransliteration = LyricsTranslationOptions.showTransliterationDefault

    private typealias M = MusicMetrics.NowPlaying

    var body: some View {
        GeometryReader { geo in
            let panel = geo.frame(in: .named(NowPlayingCoordinateSpace.name))
            Group {
                if lyrics.isLoading {
                    placeholder("正在获取歌词…")
                } else if lyrics.isEmpty {
                    placeholder("播放歌曲并在此处查看歌词。")
                } else {
                    SyncedLyricsView(
                        lyrics: lyrics.lines,
                        player: player,
                        isActive: isActive,
                        showsTranslation: showTranslation,
                        showsTransliteration: showTransliteration,
                        overrides: .init(
                            selectedLineRect: LyricsBaseline.selectedLineRect(
                                artworkCenterY: artworkCenterY, panel: panel),
                            // [实测] §8.2 `breakpointForWidth:` 的入参是歌词视图
                            // `_layoutFrame` 的**宽度原值**（边距已由布局折进 frame，
                            // 不再额外换算）。列宽仍夹在 maxWidth 内。
                            //
                            // [AX] 2026-09-03 两边同窗口（1470×923）实测：Music 的歌词
                            // 滚动区是 `[735, 121, 683, 771]`、19pt 内边距在它**里面**，
                            // 行视图 `[754, …, 645, …]`；Amber 的 19pt 加在滚动区**外面**，
                            // 行视图同为 754/645 但滚动区只有 645。所以这里要传**加边距
                            // 之前**的宽度（=683），传扣过边距的 645 等于扣了两次——
                            // 683 落 50pt 档、645 落 38pt 档，正好差一整档字号。
                            // 这 19pt 走滚动视图**内部**的 margins，不能用
                            // `.padding` 加在外面：行贴着 clip view 左沿时，
                            // 逐行模糊糊出去的那一圈会被剪掉（未轮到的行左边一条硬边）。
                            horizontalMargin: M.hostedContentInset,
                            sizeClass: MusicMetrics.Lyrics.sizeClass(
                                forWidth: min(geo.size.width,
                                              MusicMetrics.Lyrics.maxWidth))))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // 翻译键**不在这里**：整窗那颗是底栏按钮组的一员
            // （`lyricsFooterButton` → `FooterLayoutGlassGroup`），
            // 摆在 `NowPlayingView.footerTrailing` 那颗胶囊里，见
            // `LyricsTranslationButton.Placement.footerSlot`。
        }
        .padding(.top, M.hostedContentTop)
        .padding(.trailing, M.hostedContentTrailing)
        .padding(.bottom, M.hostedContentBottom)
        .reportsHostedContentMinY()
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white.opacity(M.subtitleOpacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 歌词选项菜单

/// [TYPE] `LyricsOptions._buildOptionsMenu`。
/// 其中「报告关注问题」那一项在 Music 里挂的是
/// [实测] §8.4 `PBPlayerMetadataViewModel.doReportAConcernForLyricsForCurrentlyPlayingItem`
/// ——入口在播放器元数据 VM 上，不在歌词模块里，所以 Amber 也从这条接。
struct LyricsOptionsMenu: View {
    let track: Track?
    let hasLyrics: Bool
    let onReportConcern: () -> Void

    var body: some View {
        Button("报告歌词问题") { onReportConcern() }
            .disabled(track == nil || !hasLyrics)
    }
}
