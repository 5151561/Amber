import AppKit
import SwiftUI

/// 「正在播放」整窗播放器的**内容列**（封面 / 元数据 / 时间行 / 传输行）。
///
/// 基线是 Music 1.7 的实测结果：结构照 `NowPlayingView` 的类型树
/// （nowplaying spec §6.1），行为照主二进制那几个 VM（§3、§4），
/// 数值照 `MusicMetrics.NowPlaying`（AX frame + 截图逐像素）。
///
/// ```
/// NowPlayingView(columnWidth:)             ← AppKit 给的定尺寸槽，铁律 2
///   └── MacContentView
///         ├── ArtworkContainerView         §6.1 封面格子（播放/暂停两档尺寸）
///         ├── MetadataLabels               §4.2 标题/副标题、§4.5 心水、§4.6 菜单
///         ├── MacTimeControlView           §4.3 时间三值、§4.4 徽标
///         └── ControlsAndFooterButtonsView §3.3 播放键三态、随机/循环
/// ```
///
/// **只剩内容列**：背景（`MiniPlayerBackdropMetalView`）、四角胶囊、rollover、粒子层、
/// 右半区抽屉全部归 AppKit 那台容器（`NowPlayingContainerViewController` +
/// `NowPlayingChromeView`），计划阶段 6。连带没了的还有：
///
/// - `GeometryReader` 量容器：**列宽由容器算好当参数传进来**（「三处决定」第 3 条），
///   槽位几何的契约写在 `NowPlayingContainerViewController.contentGeometry`；
/// - 两个 `PreferenceKey`（`primaryArtworkCenterY` / `hostedContentMinY`）：
///   封面中心由容器按同一个列宽自算，直接推给歌词面板；
/// - `onContinuousHover` / 窗口焦点那两条 `onReceive`：rollover 归 AppKit 的 tracking area；
/// - Esc：响应链原生就有（`RootViewController.cancelOperation(_:)`）。
///
/// **树里每一层都是独立的 `View` 类型，不是 computed property**：
/// computed property 没有自己的依赖集，几块内容全靠顶层那一个 body 撑着，于是顶层
/// `@EnvironmentObject` 了三个上帝对象（`AppState` 10 个 `@Published`、
/// `PlayerController` 17 个、`LibraryStore` 28 个），一首歌播完 `notePlayed` 改
/// `playCounts`、弹一句 toast 都要把整屏重算一遍
/// （design-ref/reactive-ui-review.md §2.1）。拆开之后各订各的：
///
/// | 块 | 订谁 |
/// | --- | --- |
/// | `MacContentView` / `ControlsAndFooterButtonsView` | `PlayerController` |
/// | `MetadataLabels` | `PlayerController`（经入参）+ **`LibraryStore`（只为那颗心水星）** |
/// | `MacTimeControlView` | `PlayerController`（时间行三态由入参给） |
/// | `ArtworkContainerView` | 谁都不订，全是入参 |
struct NowPlayingView: View {
    /// 内容列宽。由 AppKit 容器按 §2/§6.1 的契约算好传进来，这一侧不再自己量。
    let columnWidth: CGFloat
    let artwork: NSImage?
    /// 整窗播放器展开着没有。只往下传给时间行那一块——收起期间不必再按 10 Hz 走时，
    /// 见 `PlaybackTimeReader.isActive`。
    let isActive: Bool
    /// 时间行三态的当前值与「点了要翻下一档」的回调。真值在 AppKit 容器上。
    let timeAccessory: NowPlayingTimeAccessory
    let onCycleTimeAccessory: () -> Void
    let onGoToArtist: (Track) -> Void

    var body: some View {
        MacContentView(column: columnWidth,
                       artwork: artwork,
                       isActive: isActive,
                       timeAccessory: timeAccessory,
                       onCycleTimeAccessory: onCycleTimeAccessory,
                       onGoToArtist: onGoToArtist)
    }
}

// MARK: - MacContentView

/// [AX] 内容列宽 = 窗口宽 × 0.28…（1440 → 403），抽屉开时这一列落在左半区正中。
///
/// 列宽本身由容器算（`contentWidthFraction` 是**对整窗**取的 0.28，不是对半区），
/// 这一层只按给定的列宽往下摆——堆叠常量还是 `MusicMetrics.NowPlaying` 那一组。
private struct MacContentView: View {
    let column: CGFloat
    let artwork: NSImage?
    let isActive: Bool
    let timeAccessory: NowPlayingTimeAccessory
    let onCycleTimeAccessory: () -> Void
    let onGoToArtist: (Track) -> Void

    @Environment(PlayerController.self) private var player

    private typealias M = MusicMetrics.NowPlaying

    private var track: Track? { player.currentTrack }

    private var controlsState: PlayerControlsState { PlayerControlsState(player: player) }

    /// 心水那一位不在这里填（默认 false）：只有 `MetadataLabels` 用得上它，
    /// 而填它要观察 `LibraryStore`。见 `NowPlayingMetadata.isFavorite` 的注释。
    private var metadata: NowPlayingMetadata {
        NowPlayingMetadata(
            item: track,
            controls: controlsState,
            duration: player.duration,
            // 徽标要跟徽标点开的气泡说同一件事：这一路流真就绪了就按实际拿到的
            // 那一档判，还没就绪才退回目录里「这首有没有无损档」那一位。
            isLossless: player.streamFormat?.isLossless ?? (track?.losslessAvailable == true))
    }

    var body: some View {
        let meta = metadata

        return VStack(spacing: 0) {
            ArtworkContainerView(artwork: artwork, size: column,
                                 aspect: meta.artworkAspectRatio,
                                 isPlaying: player.isPlaying)
            Spacer().frame(height: M.artworkToMetadata)
            MetadataLabels(meta: meta, onGoToArtist: onGoToArtist)
            Spacer().frame(height: M.metadataToScrubber)
            MacTimeControlView(meta: meta, isActive: isActive,
                               timeAccessory: timeAccessory,
                               onCycleTimeAccessory: onCycleTimeAccessory)
            Spacer().frame(height: M.timeToTransport)
            ControlsAndFooterButtonsView(state: controlsState)
        }
        .frame(width: column)
    }
}

// MARK: - ArtworkContainerView

/// 封面有**两个尺寸**：播放时铺满整格，暂停时缩到 0.73 倍，格子本身不变，
/// 所以下面的曲名/进度条/传输键一动不动。
///
/// [TYPE] `NowPlayingView.ArtworkContainerView.Layout(scale:)` +
/// `ArtworkContainerView.__artworkScale`（LazyState CGFloat）——是个 Layout，
/// 不是 transform，所以圆角与阴影不跟着缩。
/// [AX] 实测暂停态：外层格子 `AXImage` 403×403.5，里面真正画出来的那张
/// 294.5×294.75，两者同心（中心都在 x=360），294.5 / 403 = 0.7308。
///
/// **格子的中心 y 就是歌词面板的基线锚点**（§6.1 `LayoutHints.primaryArtworkCenterY`）
/// ——它现在由 AppKit 容器按同一个列宽自算（`contentGeometry.artworkCenterY`），
/// 不再由本视图往上报 preference。算的是外层格子、不是里面那张会缩放的图，
/// 暂停时基线才不会跟着跳。
///
/// 全是入参、一个 `@EnvironmentObject` 都不订：封面这一格与资料库、导航、toast
/// 没有任何关系（拆之前它们全在同一个 body 里，见 `NowPlayingView` 的类型注释）。
private struct ArtworkContainerView: View {
    let artwork: NSImage?
    let size: CGFloat
    let aspect: CGFloat
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias M = MusicMetrics.NowPlaying

    var body: some View {
        let scale = isPlaying ? M.artworkPlayingScale : M.artworkPausedScale
        // 不取整：403 × 0.7308 = 294.5，正是实测值；取整会掉到 294。
        let drawn = size * scale

        return ZStack {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.sRGB, red: 0.150, green: 0.150, blue: 0.164)
                Image(systemName: "music.note")
                    .font(.system(size: drawn * 0.42))
                    .foregroundStyle(.white.opacity(0.32))
            }
        }
        .frame(width: drawn, height: drawn / aspect)
        .clipShape(RoundedRectangle(cornerRadius: M.artworkCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .frame(width: size, height: size / aspect)
        // [HIG] 减弱动态效果时直接切到目标尺寸：播放/暂停两档大小照旧生效
        // （0.73 倍仍是 0.73 倍），只是不走那段弹簧。
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82),
                   value: scale)
    }
}

// MARK: - MetadataLabels

/// [TYPE] `MetadataLabels(fonts:allowsEyebrow:allowsSubtitle:allowsMarquee:)`：
/// eyebrow（电台/播放列表名）在标题上方，Amber 没有这个概念时整行不占位。
///
/// 标题两行的取值全走 `NowPlayingMetadata`（§4.2）：远控设备名覆盖、
/// 无条目时的占位串都在那边判，这里只管画。
private struct MetadataLabels: View {
    let meta: NowPlayingMetadata
    let onGoToArtist: (Track) -> Void

    /// 整窗播放器里**唯一**观察资料库的一小块——只为那颗心水星。
    /// 从前这一位是在顶层 body 里算的（`metadata` 里那句 `library.isFavorite`），
    /// 于是一首歌播完 `notePlayed` 改 `playCounts` / `lastPlayedAt`，
    /// 整屏跟着重算一遍（design-ref/reactive-ui-review.md §2.1）。
    @EnvironmentObject private var library: LibraryStore

    private typealias M = MusicMetrics.NowPlaying

    /// [实测] §4.5 心水是个三态机（内部 {2 liked, 3 disliked}、UI {0,1,2}）。
    /// Amber 只走 none ↔ liked 两态，理由见 `FavoritingState` 的注释。
    private var favoritingState: FavoritingState {
        guard let track = meta.item else { return .none }
        return library.isFavorite(track) ? .liked : .none
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(meta.primaryTitle)
                    .font(.system(size: M.titleSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(M.titleOpacity))
                    .lineLimit(1)
                // [实测] §4.2 `secondaryTitleIsActionable` + `doSecondaryTitleLinkAction`
                // （导航事件码 0x61）：副标题可点时跳到艺人。
                Group {
                    if meta.secondaryTitleIsActionable, let track = meta.item {
                        Button {
                            onGoToArtist(track)
                        } label: {
                            Text(meta.secondaryTitle).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("前往艺人")
                        // [HIG] 副标题本身念的是「歌手 — 专辑」，听不出它还是个链接。
                        .accessibilityLabel("前往艺人：\(meta.secondaryTitle)")
                    } else {
                        Text(meta.secondaryTitle)
                    }
                }
                .font(.system(size: M.subtitleSize))
                .foregroundStyle(.white.opacity(M.subtitleOpacity))
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let track = meta.item {
                favoriteButton(track: track, state: favoritingState)
                Spacer().frame(width: M.metadataAccessorySpacing)
                moreButton(track: track)
            }
        }
        .frame(height: M.metadataHeight)
    }

    private func favoriteButton(track: Track, state: FavoritingState) -> some View {
        Button {
            library.toggleFavorite(track)
        } label: {
            Image(systemName: state.symbolName)
                .font(.system(size: M.favoriteIconSize))
                .foregroundStyle(state == .none ? .white.opacity(M.metadataAccessoryOpacity)
                                                : Color.amberKeyDark)
                .frame(width: M.metadataAccessorySize, height: M.metadataAccessorySize)
                .background(.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(state == .liked ? "取消心水" : "心水")
        // [HIG] 不补就念 SF Symbol 名（"star" / "star fill"），当前是不是心水听不出来。
        .accessibilityLabel(state == .liked ? "取消心水" : "心水")
    }

    private func moreButton(track: Track) -> some View {
        Menu {
            // 与底部悬浮播放条那颗 ••• 同一份（`PlayerMoreMenu`）。
            PlayerMoreMenu(track: track)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: M.moreIconSize))
                .foregroundStyle(.white.opacity(M.metadataAccessoryOpacity))
                .frame(width: M.metadataAccessorySize, height: M.metadataAccessorySize)
                .background(.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        // 与音轨行的 ••• 同一套：borderlessButton 会拿系统控件字体覆盖
        // label 的字号，字形只画到 11 宽（实测该是 15）。
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: M.metadataAccessorySize, height: M.metadataAccessorySize)
        .help("更多")
        // [HIG] 不补就念 "ellipsis"。
        .accessibilityLabel("更多")
    }
}

// MARK: - MacTimeControlView

/// [AX] 进度条命中区 403×15、可见轨道 6；下面一行时间标签左右各一，
/// 中间是 `TimeControlAccessoryView`（Music 那处显示「无损」音质徽标）。
///
/// 时间三值走 [实测] §4.3：VM 只给 double 秒，取负与 mm:ss 在这一层。
private struct MacTimeControlView: View {
    let meta: NowPlayingMetadata
    /// 整窗播放器展开着没有。收起期间整块播放器仍在视图树里（故障 16 之后不再靠
    /// `isHidden` 停更新），所以得自己把 10 Hz 的走时闸上——不然没人看的时候
    /// 这三处还在跟着 `PlaybackClock` 跳。闸一关，`PlaybackTimeReader` 换成不订阅的
    /// 那一支，读数冻在 `player.currentTime` 上；一展开立刻换回活的。
    ///
    /// 换支路会重建括号里的子树（`AmberTrackBar` 的悬浮态 `@State` 跟着归零），
    /// 而这件事只发生在收起／展开那一刻——那时鼠标不在上面，看不出来。
    let isActive: Bool
    /// 时间行三态：值与「翻下一档」的回调都由 AppKit 容器给
    /// （从前是 `@ObservedObject` 一份 VM，rollover 一翻这一行就跟着重算一次）。
    let timeAccessory: NowPlayingTimeAccessory
    let onCycleTimeAccessory: () -> Void

    @Environment(PlayerController.self) private var player

    @State private var showQuality = false

    private typealias M = MusicMetrics.NowPlaying

    var body: some View {
        // 进度 10 Hz 一跳，只让真的读进度的那几处跟着跳（见 `PlaybackTimeReader`）。
        // 徽标不读进度，必须留在框外：它上面挂着音质气泡，气泡宿主每 100ms
        // 重建一次会闪。
        VStack(spacing: M.scrubberToTime) {
            PlaybackTimeReader(isActive: isActive, frozenTime: player.currentTime) { time in
                AmberTrackBar(
                    progress: playbackProgress(at: time),
                    height: M.scrubberBarHeight,
                    hitHeight: M.scrubberHitHeight,
                    accessibilityLabel: "播放进度",
                    accessibilityValue: scrubberAccessibilityValue(meta, at: time),
                    onScrub: { p in
                        // [实测] §4.3 `setCurrentTimecode:`：秒 → 毫秒取整 → setPosition:
                        guard meta.endingTimecode > 0 else { return }
                        player.seek(to: p * meta.endingTimecode)
                    })
            }

            HStack(spacing: 0) {
                PlaybackTimeReader(isActive: isActive, frozenTime: player.currentTime) { time in
                    Text(timecodeText(meta.currentTimecode(at: time), duration: meta.endingTimecode))
                }
                Spacer(minLength: 4)
                badges(meta.badges)
                Spacer(minLength: 4)
                Button {
                    onCycleTimeAccessory()
                } label: {
                    PlaybackTimeReader(isActive: isActive, frozenTime: player.currentTime) { time in
                        Text(trailingTimeText(meta, at: time))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("切换剩余时间／总时长／播完时刻")
                // [HIG] 这颗的 label 是时间文本本身（如「-1:23」），听不出可以点；
                // 补一个说明名，读数留给 value。
                .accessibilityLabel("切换剩余时间／总时长／播完时刻")
                .accessibilityValue(Text(trailingTimeText(meta, at: player.currentTime)))
            }
            .font(.system(size: M.timeSize).monospacedDigit())
            .foregroundStyle(.white.opacity(M.timeOpacity))
            .frame(height: M.timeRowHeight)
        }
    }

    /// [实测] §4.4 徽标：Live 由 `liveMode` 判、无损这一枚是 UI 层按透传的`audioFormat*` 决定。
    /// Amber 只有「音源提供无损档」一位，不支持的曲目整块不占位——Music 同样什么都不画。
    ///
    /// 整块可点，点开是音质气泡（和迷你播放器的波形键同一枚）。Music.app 这处也是
    /// 按钮：`TimeControlAccessoryView` 点了出音质与「音频质量设置」，不是死标签。
    @ViewBuilder
    private func badges(_ list: [NowPlayingMetadata.Badge]) -> some View {
        if list.isEmpty {
            // 一枚都没有时不要留一颗零宽的按钮，命中区会挡住进度条下面那一行。
            EmptyView()
        } else {
            Button {
                showQuality.toggle()
            } label: {
                HStack(spacing: 6) {
                    ForEach(list, id: \.self) { badge in
                        HStack(spacing: 4) {
                            if let symbol = badge.symbolName {
                                Image(systemName: symbol).font(.system(size: M.badgeSize))
                            }
                            Text(badge.title).font(.system(size: M.badgeSize))
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("音质")
            // [HIG] 徽标里的 waveform 字形会被念成 "waveform"，「音质」这层意思全丢了。
            .accessibilityLabel("音质")
            .popover(isPresented: $showQuality, arrowEdge: .top) {
                AudioQualityPopover()
            }
        }
    }

    // MARK: 数值

    private func playbackProgress(at time: TimeInterval) -> Double {
        let duration = player.duration
        guard duration > 0 else { return 0 }
        return min(time / duration, 1)
    }

    private func timecodeText(_ value: TimeInterval, duration: TimeInterval) -> String {
        duration > 0 ? value.mmss : "--:--"
    }

    /// [HIG] 进度条的 AX 值念「已播 / 总时长」，比裸百分比有用。
    private func scrubberAccessibilityValue(_ meta: NowPlayingMetadata, at time: TimeInterval) -> String {
        let duration = meta.endingTimecode
        guard duration > 0 else { return "--:--" }
        return "\(meta.currentTimecode(at: time).mmss) / \(duration.mmss)"
    }

    /// [实测] §4.3：`remainingDisplayedTimecode` 是 end − current 的**裸差值**，
    /// 取负号与 mm:ss 都在视图层做。
    private func trailingTimeText(_ meta: NowPlayingMetadata, at time: TimeInterval) -> String {
        let duration = meta.endingTimecode
        guard duration > 0 else { return "--:--" }
        switch timeAccessory {
        case .remaining:
            return "-" + max(meta.remainingDisplayedTimecode(at: time), 0).mmss
        case .duration:
            return duration.mmss
        case .endsAt:
            let remaining = max(meta.remainingDisplayedTimecode(at: time), 0)
            return Self.endsAtFormatter.string(from: Date().addingTimeInterval(remaining))
        }
    }

    /// 「结束于」的时刻格式。这条走的是 10 Hz 的走时路径，
    /// DateFormatter 现建现用每秒要造十个。
    private static let endsAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter
    }()
}

// MARK: - ControlsAndFooterButtonsView

/// [AX] 随机 / 循环是贴内容列左右沿的 30×30 命中盒
/// （`PlayerControlsView.AccessoryButton(alignment:)`），
/// 中间三颗才是 `TransportControlsView`：上一首中心 −86、播放居中、下一首 +86。
private struct ControlsAndFooterButtonsView: View {
    let state: PlayerControlsState

    @Environment(PlayerController.self) private var player

    private typealias M = MusicMetrics.NowPlaying

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                // [实测] §3.3 shuffle 底层 1（关）↔ 2（开）
                transportEdgeButton(
                    systemImage: "shuffle", size: M.shuffleIconSize,
                    active: player.isShuffled,
                    help: player.isShuffled ? "不随机播放" : "随机播放") {
                        player.toggleShuffle()
                    }
                Spacer(minLength: 0)
                // [实测] §3.3 repeat 底层 0 → 1（全部）→ 2（单曲）→ 0
                transportEdgeButton(
                    systemImage: player.repeatMode.symbolName,
                    size: M.repeatIconSize,
                    active: player.repeatMode.isOn,
                    help: player.repeatMode.help) {
                        player.cycleRepeatMode()
                    }
            }

            // 三颗键各占 transportRowHeight 见方的命中盒，
            // 圆心间距 = skipOffsetFromCenter，故盒间空隙 = 间距 − 盒宽。
            HStack(spacing: M.skipOffsetFromCenter - M.transportRowHeight) {
                // [实测] §3.3 点按 = skipPrevious / skipNext；按住走 KeyScanTimer 那条
                // （`startFFRew:` / `doFFRewUsingKeyScanTimer:`，FF = 1、Rewind = 0）。
                scanButton("backward.fill", size: M.skipIconSize, opacity: M.skipOpacity,
                           enabled: state.previousTrackActionEnabled, help: "上一首",
                           direction: .rewind) { player.previous() }
                transportButton(PlayButtonState.resolve(state).symbolName,
                                size: M.playIconSize,
                                opacity: M.playOpacity,
                                enabled: state.hasItem,
                                help: PlayButtonState.resolve(state).help) {
                    player.togglePlayPause()
                }
                scanButton("forward.fill", size: M.skipIconSize, opacity: M.skipOpacity,
                           enabled: state.nextTrackActionEnabled, help: "下一首",
                           direction: .fastForward) { player.next() }
            }
        }
        .frame(height: M.transportRowHeight)
    }

    private func transportEdgeButton(systemImage: String, size: CGFloat, active: Bool,
                                     help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .foregroundStyle(active ? Color.amberKeyDark : .white.opacity(M.edgeButtonOpacity))
                .frame(width: M.edgeButtonSize, height: M.edgeButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        // [HIG] *Adopting Liquid Glass*：「always specify an accessibility label for each
        // icon」。`.help` 只落到 help tag / AX hint，**名字仍由 SF Symbol 名生成**，
        // 不补这一句 VoiceOver 念的就是 "shuffle"、"repeat" 这种字形名。
        .accessibilityLabel(help)
    }

    private func transportButton(_ systemImage: String, size: CGFloat, opacity: CGFloat,
                                 enabled: Bool, help: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .foregroundStyle(.white.opacity(enabled ? opacity : 0.35))
                .frame(width: M.transportRowHeight, height: M.transportRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        // [HIG] 同上：不补就念 "play fill" / "pause fill"。
        .accessibilityLabel(help)
    }

    /// 点按走 skip、按住走快进/回退扫描。
    private func scanButton(_ systemImage: String, size: CGFloat, opacity: CGFloat,
                            enabled: Bool, help: String,
                            direction: PlayerController.ScanDirection,
                            action: @escaping () -> Void) -> some View {
        TransportScanButton(systemImage: systemImage, size: size, opacity: opacity,
                            boxSize: M.transportRowHeight, enabled: enabled, help: help,
                            direction: direction, player: player, onTap: action)
    }
}

// MARK: - 传输键：点按切歌，按住扫描

/// [实测] §3.3：点按走 `skipNext` / `skipPrevious`，按住走
/// `startFFRew:` + `doFFRewUsingKeyScanTimer:`（FF = 1、Rewind = 0）。
///
/// 不能用 `Button` 再叠一个长按手势：那样松手时按钮的点击照样会触发，
/// 「按住快进再松手」会额外切一首歌。这里直接用按压状态自己分流。
private struct TransportScanButton: View {
    let systemImage: String
    let size: CGFloat
    let opacity: CGFloat
    let boxSize: CGFloat
    let enabled: Bool
    let help: String
    let direction: PlayerController.ScanDirection
    let player: PlayerController
    let onTap: () -> Void

    @State private var isScanning = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size))
            .foregroundStyle(.white.opacity(enabled ? opacity : 0.35))
            .frame(width: boxSize, height: boxSize)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: PlayerController.scanHoldDelay) {
                guard enabled else { return }
                isScanning = true
                player.startFFRew(direction)
            } onPressingChanged: { pressing in
                guard enabled, !pressing else { return }
                if isScanning {
                    isScanning = false
                    player.stopFFRew()
                } else {
                    onTap()
                }
            }
            .help(help)
            // [HIG] 同上：不补就念 "backward fill" / "forward fill"。
            .accessibilityLabel(help)
    }
}
