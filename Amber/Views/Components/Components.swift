import AVKit
import AppKit
import CoreImage
import SwiftUI

// MARK: - 主题

extension Color {
    /// 网易云红
    static let neteaseRed = Color(red: 0.80, green: 0.10, blue: 0.10)
    /// QQ 音乐绿
    static let qqGreen = Color(red: 0.19, green: 0.76, blue: 0.49)
    /// 封面占位渐变副色（品牌红 amberKey 在 MusicColors.swift）
    static let amberPurple = Color(red: 0.55, green: 0.20, blue: 0.85)

    /// Apple Music 侧栏图标红（对激活状态 Music.app 实测：深色 #FF6376，浅色用 Music 红）
    ///
    /// 侧栏骨架换成 NSOutlineView 之后图标是 `NSImageView` 画的，要拿 NSColor，
    /// 值挪到了 `NSColor.amberSidebarAccent`；这里只是包一层，**同一份值**。
    static let amberSidebarAccent = Color(nsColor: .amberSidebarAccent)

    /// 侧栏选中胶囊的底色。见 `NSColor.amberSidebarSelection`。
    static let amberSidebarSelection = Color(nsColor: .amberSidebarSelection)

    static func tint(for kind: ProviderKind) -> Color {
        switch kind {
        case .netease: return .neteaseRed
        case .qq: return .qqGreen
        }
    }
}

/// 侧栏骨架是 AppKit（NSOutlineView）画的，图标色与选中底色都要拿 NSColor。
/// 与上面的 `Color` 是同一份值——`Color` 那边只是包一层。
extension NSColor {
    /// Apple Music 侧栏图标红。行图标**选中时也是这个红**：
    /// [PX] Music `design-ref/ui-spec/pages/home.png` 主页那一行（选中）图标实测 rgb(255,90,118)，
    /// 没有被选中前景色顶掉洗成白色。
    static let amberSidebarAccent = NSColor(name: "amberSidebarAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            // 目标渲染值 #FF6376；侧栏 vibrancy 会把颜色洗淡，此处按实测补偿加深
            ? NSColor(srgbRed: 1.00, green: 0.26, blue: 0.38, alpha: 1)
            : NSColor(srgbRed: 0.98, green: 0.14, blue: 0.23, alpha: 1)
    }

    /// 侧栏选中胶囊的底色，**窗口在前台**那一档。
    ///
    /// 是压在侧栏底色上的**中性灰**，不是 accent —— `List(selection:)` 那一版取 App 的
    /// `AccentColor`（Amber 那份就是 Music 红），画出来是一整条实心红胶囊，这两个 token
    /// 就是为了把它换回中性灰而存在的。
    ///
    /// [PX] 值沿用 Amber 手绘那一版（`MainView` 里被删掉的`selectionFill`）：深色白 14.2% /
    /// 浅色黑 9%。与 Music 实测对得上——`home.png` 选中行胶囊 rgb(71,71,71) 压在侧栏底色
    /// rgb(42,42,42) 上，折回去是白 ≈13.6%。
    static let amberSidebarSelection = NSColor(name: "amberSidebarSelection") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.142)
            : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.09)
    }

    /// 侧栏选中胶囊的底色，**窗口不在前台**那一档（同样沿用手绘那一版：白 7% / 黑 4.5%）。
    static let amberSidebarSelectionInactive = NSColor(name: "amberSidebarSelectionInactive") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07)
            : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.045)
    }
}

// MARK: - 公用文案

enum MusicText {
    /// 「N 首歌曲」+ 总时长。详情页头用「 • 」分隔，页脚用「，」，正文一字不差。
    ///
    /// [注] 不足 1 分钟的歌单两处历史处理不同，收敛时原样保留、没有统一：
    /// 详情页（专辑/歌单头与页脚）按总**秒数**判断，半分钟的列表会写成「1 首歌曲 • 0 分钟」；
    /// 资料库播放列表页按总**分钟**判断，不足 1 分钟就只留歌曲数。
    static func countAndDuration(count: Int, seconds: TimeInterval,
                                 separator: String,
                                 hidesSubMinute: Bool = false) -> String {
        let countText = "\(count) 首歌曲"
        let totalMinutes = Int(seconds) / 60
        guard seconds > 0, !(hidesSubMinute && totalMinutes == 0) else { return countText }
        if totalMinutes >= 60 {
            return "\(countText)\(separator)\(totalMinutes / 60) 小时 \(totalMinutes % 60) 分钟"
        }
        return "\(countText)\(separator)\(totalMinutes) 分钟"
    }
}

/// 音量图标的四档（静音 + 三档波纹）。整窗播放器与迷你播放器共用一份。
enum VolumeGlyph {
    static func symbol(for volume: Double) -> String {
        if volume <= 0.001 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

// MARK: - 路由派生

extension Route {
    /// 曲目 →「艺人」的落点（`Route.album(of:)` 的姊妹）。
    ///
    /// 卡片与曲目行里的艺人名只有 id 与名字都在时才挂链接：id 空了打不开艺人页，
    /// 名字空了链接就是个零宽的点不到的洞。头像与简介一律传 nil——艺人页自己会再取一遍。
    static func artist(of track: Track) -> Route? {
        artist(id: track.artistId, kind: track.kind, name: track.artistName)
    }

    /// 专辑 →「艺人」的落点，判定与曲目那条一致。
    static func artist(of album: Album) -> Route? {
        artist(id: album.artistId, kind: album.kind, name: album.artistName)
    }

    private static func artist(id: String?, kind: ProviderKind, name: String) -> Route? {
        guard let id, !id.isEmpty, !name.isEmpty else { return nil }
        return .artist(Artist(id: id, kind: kind, name: name, avatarURL: nil, description: nil))
    }
}

// MARK: - 音乐源切换

struct ProviderPicker: View {
    @Binding var selection: ProviderKind
    /// 设置里启用的源；只剩一个源时不显示切换器
    let kinds: [ProviderKind]

    var body: some View {
        if kinds.count > 1 {
            Picker("音乐源", selection: $selection) {
                ForEach(kinds) { kind in
                    Text(kind.shortName).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: MusicMetrics.ProviderPicker.width,
                   height: MusicMetrics.ProviderPicker.height)
            .accessibilityLabel("音乐源")
        }
    }
}

// MARK: - 空状态

struct MusicEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: MusicMetrics.Page.titleSize, weight: .bold))
                MusicEmptyStateContent(message: message, systemImage: systemImage)
            }
            .padding(.horizontal, MusicMetrics.Page.leadingMargin)
            .padding(.top, MusicMetrics.Page.titleTop)
        }
    }
}

struct MusicEmptyStateContent: View {
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: MusicMetrics.EmptyState.spacing) {
            Image(systemName: systemImage)
                .font(.system(size: MusicMetrics.EmptyState.iconSize, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: MusicMetrics.EmptyState.maxTextWidth)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, MusicMetrics.EmptyState.topPadding)
    }
}

// MARK: - 封面图

struct ArtworkView: View {
    let url: String?
    var tint: Color = .amberKey
    /// 想要的封面边长（point）。按 `ArtworkSize` 的阶梯改写请求地址；
    /// 传 nil 就用 provider 给的原始地址。
    var points: CGFloat?

    @State private var image: NSImage?

    private var requestURL: String? {
        guard let points else { return url }
        return ArtworkSize.url(url, points: points)
    }

    var body: some View {
        // 图放 overlay 里、底下垫一张 Color.clear：`scaledToFill` 报的尺寸比提议的**大**
        // （方图塞进 1074:460 的大横幅就报成正方形），直接当布局主体的话，外面
        // `.frame(height:)` 只钉住了槽位，实际视图仍是那个正方形——渲染被 clipShape 裁掉看不出来，
        // 命中区却整块溢出，把上一栏目压死（主页「为你推荐最新作品」点不动、滑不动就是这么来的）。
        // Color.clear 老老实实收下提议尺寸，图只负责画。
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [tint.opacity(0.85), Color.amberPurple.opacity(0.55)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: requestURL) {
                let requested = requestURL
                // 内存里有就当场换掉，没有就先撤旧图：这个视图会随行复用，
                // 换了条目还留着上一条的封面就是「封面串图」。
                if let cached = ImageCache.shared.memoryCachedImage(for: requested) {
                    image = cached
                    return
                }
                image = nil
                guard let loaded = await ImageCache.shared.image(for: requested) else { return }
                if requested == requestURL { image = loaded }
            }
    }
}

// MARK: - 区块标题

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    // 实测 Music.app 主页：标题 15pt semibold，下方可选 13pt 灰色说明
    var body: some View {
        VStack(alignment: .leading, spacing: MusicMetrics.SectionHeader.titleToSubtitle) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 卡片

/// 封面右下角的悬浮播放键：`.ultraThinMaterial` 玻璃圆片。
/// 全仓 6 处（主页大卡、目录页各式卡、资料库专辑/播放列表/心水网格卡）同一个形，
/// 只差两点：目录页那批字形 14pt 且带投影，其余 15pt 无投影。直径与内边距是同一档。
struct CardPlayButton: View {
    let action: () -> Void
    /// `play.fill` 字号。目录页卡 14，其余 15。
    var iconSize: CGFloat = 15
    /// 目录页的卡压在深色封面上，玻璃片额外带一层投影。
    var hasShadow = false

    var body: some View {
        Button(action: action) { glass }
            .buttonStyle(.plain)
            .padding(MusicMetrics.Card.playButtonPadding)
    }

    @ViewBuilder
    private var glass: some View {
        let disc = Image(systemName: "play.fill")
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: MusicMetrics.Card.playButtonSize,
                   height: MusicMetrics.Card.playButtonSize)
            .background(.ultraThinMaterial, in: Circle())
        if hasShadow {
            disc.shadow(color: .black.opacity(0.35), radius: 4, y: 1.5)
        } else {
            disc
        }
    }
}

/// 资料库网格卡的通用外形（专辑 / 播放列表 / 心水歌曲三张卡共用）。
///
/// [AX] 封面底 344 = 文字块顶 344：零间距。
/// [实测] `AMPGridCollectionViewItem.prepareForReuse` 的 label 布局常量 12 / 10（左 12、右 10），
/// 文字块定高 46（`labelViewHeight`），底垫 10（[AX] cell 高 290 = 234 + 46 + 10）。
struct LibraryGridCard<Artwork: View, Label: View>: View {
    /// 列宽（网格按容器宽算好后传入，封面即这个宽的正方形）。
    let width: CGFloat
    let route: Route
    /// 悬浮时压在封面上的暗罩浓度；专辑卡与播放列表卡不罩（0），心水卡罩 0.12。
    var hoverScrim: Double = 0
    /// 悬浮播放键的动作；给 nil 就不摆这颗键（心水歌曲为空时就是这种）。
    var play: (() -> Void)?
    @ViewBuilder var artwork: () -> Artwork
    @ViewBuilder var label: () -> Label

    @State private var hovering = false

    private typealias M = MusicMetrics.LibraryGrid

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: route) {
                artwork()
                    .frame(width: width, height: width)
                    .overlay {
                        if hovering && hoverScrim > 0 { Color.black.opacity(hoverScrim) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: MusicMetrics.Card.artworkCornerRadius,
                                                style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if hovering, let play {
                            CardPlayButton(action: play)
                        }
                    }
            }
            .buttonStyle(.plain)

            label()
                .padding(.leading, M.labelLeading)
                .padding(.trailing, M.labelTrailing)
                .frame(height: M.labelHeight, alignment: .top)
                .padding(.bottom, M.cellBottomPad)
        }
        .onHover { hovering = $0 }
    }
}

/// 大卡片（歌单/专辑网格）
struct MediaCard: View {
    let artworkURL: String?
    let title: String
    let subtitle: String
    var tint: Color = .amberKey
    var onPlay: (() -> Void)? = nil

    @State private var hovering = false

    private typealias M = MusicMetrics.Card

    var body: some View {
        VStack(alignment: .leading, spacing: M.artworkToText) {
            ZStack {
                ArtworkView(url: artworkURL, tint: tint, points: ArtworkSize.gridItem)
                    .aspectRatio(1, contentMode: .fit)
                    .cornerRadius(M.artworkCornerRadius)
                if hovering, let onPlay {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            CardPlayButton(action: onPlay)
                        }
                    }
                }
            }
            // 实测 Music.app 卡片：标题/副标题都是 13pt，各一行，标题常规字重。
            // [实测] `AMPGridCollectionViewItem.labelViewHeight` → 46：文字块是**定高**的，
            // 副标题为空的卡片也占同样高度，一行网格才对得齐。
            VStack(alignment: .leading, spacing: M.textSpacing) {
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: M.labelHeight, alignment: .top)
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - 进度条 / 音量条

/// Apple Music 风细进度条：默认无滑块，悬浮或拖动时显示白色圆点。
/// 五星评分：Music.app 在专辑信息行与音轨行都用它，未评分时显示去饱和的空心星。
struct RatingStars: View {
    let rating: Int
    var starSize: CGFloat
    var spacing: CGFloat
    /// [PX] Music 的两处星级不同形：音轨行未评分是实心去饱和红，
    /// 头部信息行未评分才是空心描边（两者同色，amberKey @0.25）。
    var emptyFilled = false
    /// [PX] 资料库「歌曲」表的未评分星是**满色空心**（且只在悬浮时显形），
    /// 与专辑页的去饱和红不同，故未评分的浓度可覆盖。
    var emptyOpacity: CGFloat = MusicMetrics.Rating.emptyOpacity
    var setRating: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { value in
                Image(systemName: value <= rating || emptyFilled ? "star.fill" : "star")
                    .font(.system(size: starSize))
                    .foregroundStyle(value <= rating
                                     ? Color.amberKey
                                     : Color.amberKey.opacity(emptyOpacity))
                    .contentShape(Rectangle())
                    .onTapGesture { setRating?(value) }
                    .help("评 \(value) 星")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rating == 0 ? "未评分" : "\(rating) 星")
    }
}

/// 音源无损档标记：只表示音源侧提供无损，Amber 自身仍按可播档位取流。
struct LosslessBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .medium))
            Text("无损")
                .font(.system(size: MusicMetrics.Detail.albumMetaSize))
        }
        .foregroundStyle(.secondary)
        .help("音源提供无损档；Amber 目前播放最高 320k")
    }
}

struct AmberTrackBar: View {
    var progress: Double
    var height: CGFloat = 5
    /// true 时拖动过程中持续回调（音量），false 时松手才回调（进度）
    var continuous = false
    /// true 时滑块常驻显示（音量条），false 时仅悬浮/拖动显示（进度条）
    var alwaysShowsKnob = false
    /// 滑块尺寸。默认是直径 height+5 的圆点；[PX] 整窗播放器的音量条量到的是
    /// 24×13 的横胶囊，与轨道不同宽高，所以做成可给值。
    var knobSize: CGSize?
    /// 命中区高度，默认 height + 6。[AX] 整窗播放器的进度条命中区是 15。
    var hitHeight: CGFloat?
    /// [HIG] 辅助功能名（进度条「播放进度」、音量条「音量」）。自绘轨道没有系统给的
    /// 名字，不给就只剩一个无名 slider。
    var accessibilityLabel: String
    /// [HIG] 辅助功能值。不给时按百分比念——音量正好就是百分比，进度条才需要
    /// 传「已播 / 总时长」这种更有用的读法。
    var accessibilityValue: String?
    var onScrub: (Double) -> Void

    @State private var hovering = false
    @State private var dragProgress: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let value = min(max(dragProgress ?? progress, 0), 1)
            let knob = knobSize ?? CGSize(width: height + 5, height: height + 5)

            ZStack(alignment: .leading) {
                // [Web] 轨道 systemTertiary-onDark、已播 systemPrimary-onDark
                // （[PX] 整窗播放器实测 0.22 / 0.80，与这两档在测量误差内，不另设 token）
                Capsule().fill(.white.opacity(MusicGrays.tertiary))
                Capsule().fill(.white.opacity(MusicGrays.primary))
                    .frame(width: width * value)
                if alwaysShowsKnob || hovering || dragProgress != nil {
                    Capsule()
                        .fill(.white)
                        .frame(width: knob.width, height: knob.height)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .offset(x: min(max(width * value - knob.width / 2, 0), width - knob.width))
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let p = min(max(drag.location.x / width, 0), 1)
                        dragProgress = p
                        if continuous { onScrub(p) }
                    }
                    .onEnded { drag in
                        let p = min(max(drag.location.x / width, 0), 1)
                        dragProgress = nil
                        onScrub(p)
                    })
        }
        .frame(height: hitHeight ?? (height + 6))
        // [HIG] 这条是 Capsule + DragGesture 自绘的，AX 树里既没有 slider 角色也没有值，
        // VoiceOver / 语音控制 / 全键盘控制都调不动它（对照 Music.app：同样位置是 AXSlider）。
        // `accessibilityRepresentation` 正是官方给「自定义 slider 轨道」的解法——替身视图
        // 被隐藏且不可交互，框架只拿它生成 AX 元素，所以**视觉与手势零变化**。
        .accessibilityRepresentation { representation }
    }

    /// 只用来生成 AX 元素的替身。`Slider` 要 Binding，而这里拿的是值 + 回调，
    /// 现造一个转发过去即可（它不参与绘制，读的永远是外面传进来的 progress）。
    private var representation: some View {
        Slider(value: Binding(get: { progress }, set: { onScrub($0) }), in: 0 ... 1) {
            Text(self.accessibilityLabel)
        }
        .accessibilityValue(Text(accessibilityValue ?? percentText))
    }

    private var percentText: String {
        "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }
}

// MARK: - Liquid Glass

extension View {
    /// Apple 的液态玻璃（macOS 26+）。低于 26 时回落到 material。
    /// - clear: 几乎不扩散，用于底色平坦处（全屏播放器的悬浮控件，实测填充只比底色暗 2 级）
    /// - regular: 有扩散，用于压在图片内容之上（主窗口底部的悬浮播放胶囊）
    /// 注意：内边距要在调用前加好，glassEffect 会按传入形状裁切并绘制玻璃层。
    ///
    /// [HIG] *Adopting Liquid Glass* 要求多个自定义玻璃元素必须包进同一个
    /// `GlassEffectContainer`——它「helps optimize performance while fluidly morphing
    /// Liquid Glass shapes into each other」。目前全项目只有迷你播放器那颗胶囊在用，
    /// 单独一片没有可合并的邻居，所以先不套容器；**将来再加第二处玻璃元素时，
    /// 要把同屏的几处一起挪进 `GlassEffectContainer`**。
    @ViewBuilder
    func amberGlass(in shape: some Shape, clear: Bool = true, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            let base: Glass = clear ? .clear : .regular
            glassEffect(interactive ? base.interactive() : base, in: shape)
        } else {
            background(clear ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial), in: shape)
        }
    }
}
