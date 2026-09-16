import AppKit
import SwiftUI

/// 「正在播放」整窗播放器。
///
/// 基线是 Music 1.7 的实测结果：结构照 `NowPlayingView` 的类型树
/// （nowplaying spec §6.1），行为照主二进制那几个 VM（§3、§4），
/// 数值照 `MusicMetrics.NowPlaying`（AX frame + 截图逐像素）。
///
/// ```
/// NowPlayingView
///   ├── MPContentView                        §2 背景纱罩 / 抽屉 / rollover
///   │     ├── NowPlayingBackdropView         §2.1 纱罩与律动＝内容视图宽度的函数
///   │     └── MacContentView(contentWidthFraction:)
///   │           ├── ArtworkContainerView     §6.1 primaryArtworkCenterY 从这里报出去
///   │           ├── MetadataLabels           §4.2 标题/副标题、§4.5 心水、§4.6 菜单
///   │           ├── MacTimeControlView       §4.3 时间三值、§4.4 徽标
///   │           └── ControlsAndFooterButtonsView  §3.3 播放键三态、随机/循环
///   ├── FullWindowHostedContentView          §8 歌词（基线与封面中心对齐）
///   ├── TrackSectionsPlatter                 §6.5 待播清单盘（展开/收起）
///   ├── HeaderLayoutView                     左上关闭/迷你、右上 AirPlay/音量
///   └── FooterButtons                        右下歌词/待播、左下反应
/// ```
///
/// 行为层在 `NowPlayingViewModel`，歌词接线在`NowPlayingLyrics`——
/// 这一层只负责摆放与手势，两边都不越界（与 Music 的分层一致）。
struct NowPlayingView: View {
    /// 是否正处于「展开」状态。整块播放器是常驻的（收起时被整体位移到窗口外），
    /// 收起期间要停掉背景律动与 rollover 计时，别在看不见的地方一直合成。
    let isPresented: Bool

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var model = NowPlayingViewModel()
    /// 订阅曲目简介：在「显示简介 › 歌词」里改完自定义歌词，下面那条取词的
    /// `.task(id:)` 才会拿到新的键并重取（`infos` 是 `@Published`）。
    @ObservedObject private var trackInfo = TrackInfoStore.shared

    /// [HIG] 「减弱动态效果」：这一屏的动效全是自绘的（背景律动、粒子、封面缩放），
    /// 系统不会替它们降级，得自己读这一位。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias M = MusicMetrics.NowPlaying

    @State private var artwork: NSImage?
    @State private var showQuality = false
    @State private var reactions = ReactionEmitter()


    private var track: Track? { player.currentTrack }

    private var controlsState: PlayerControlsState { PlayerControlsState(player: player) }

    private var metadata: NowPlayingMetadata {
        NowPlayingMetadata(
            item: track,
            controls: controlsState,
            duration: player.duration,
            isFavorite: track.map { library.isFavorite($0) } ?? false,
            // 徽标要跟徽标点开的气泡说同一件事：这一路流真就绪了就按实际拿到的
            // 那一档判，还没就绪才退回目录里「这首有没有无损档」那一位。
            isLossless: player.streamFormat?.isLossless ?? (track?.losslessAvailable == true))
    }

    /// 右半区（歌词 / 待播盘）是否占位。两个抽屉共用同一列。
    private var showsHostedColumn: Bool { model.isLyricsOpen || model.isQueueOpen }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                NowPlayingBackdropView(
                    artwork: artwork,
                    isPaused: !player.isPlaying || !isPresented,
                    // [实测] §2.1 入参是**内容视图宽度**（批次 33 翻案，不是高度）。
                    contentWidth: geo.size.width)

                if showsHostedColumn {
                    HStack(spacing: 0) {
                        macContentView(in: CGSize(width: geo.size.width / 2, height: geo.size.height))
                            .frame(width: geo.size.width / 2)
                        hostedColumn(in: CGSize(width: geo.size.width / 2, height: geo.size.height))
                            .frame(width: geo.size.width / 2)
                    }
                } else {
                    macContentView(in: geo.size)
                }
            }
            // 两个 LayoutHint 都记在这个坐标系里（§6.1）
            .coordinateSpace(name: NowPlayingCoordinateSpace.name)
            .overlay(alignment: .topLeading) { headerLeading }
            .overlay(alignment: .topTrailing) { headerTrailing }
            .overlay(alignment: .bottomLeading) { footerLeading }
            .overlay(alignment: .bottomTrailing) { footerTrailing }
            // 粒子铺满整块，从反应条那条线往上飞。
            // 没有粒子时整块不摆：里面是 `TimelineView(.animation)`，
            // 挂着就按屏幕刷新率重画，收起状态下也一样烧（实测 20% 以上 CPU）。
            // [HIG] 减弱动态效果时整块不摆：这块的**全部**内容就是往上飞的粒子，
            // 没有别的状态要保住，不发射即可（发射端也一并停，见 footerLeading）。
            .overlay {
                if !reduceMotion, !reactions.particles.isEmpty {
                    ReactionEffectView(particles: reactions.particles,
                                       emitterBottomInset: M.footerBottomInset + M.capsuleHeight + 8)
                        .allowsHitTesting(false)
                }
            }
        }
        // [实测] §6.1 LayoutHints：封面中心 → 歌词基线（§8.1 的 offsetObservation 那条路）
        .onPreferenceChange(PrimaryArtworkCenterYKey.self) { value in
            model.layoutHints.primaryArtworkCenterY = value
        }
        .onPreferenceChange(HostedContentMinYKey.self) { value in
            model.layoutHints.hostedContentMinY = value
        }
        // [实测] §2.3 鼠标停住就把悬浮控件收掉；动一下立刻显形。
        .onContinuousHover { phase in
            if case .active = phase { model.noteMouseActivity() }
        }
        // [实测] §2.3 `windowFocusObserver`：焦点变化驱动控件淡入淡出。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.noteWindowFocus(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            model.noteWindowFocus(false)
        }
        // [实测] §1.1 `FullWindowPlayer.cancelOperation:`：Esc 关掉整窗播放器。
        //
        // 不能用 `.onExitCommand`——那条要视图在焦点链上才收得到，整窗播放器里
        // 没有任何控件持有焦点，实测按 Esc 没反应。挂一颗零尺寸的 cancelAction 按钮，
        // 它是窗口级的，收起时 disabled 掉免得抢别处的 Esc。
        // 阶段 1 起骨架由 AppKit 接管：整窗位移归 `NowPlayingHostController` 的 CALayer 弹簧，
        // 安全区在 `NowPlayingRoot` 上以`.ignoresSafeArea()` 铺满全窗。
        .task(id: track?.id) { await loadTrackAssets() }
        // 歌词**单独一条**，键是「曲目 id + 这首的自定义歌词」：在简介面板里改完
        // 自定义歌词要立刻换上新的那份，而只认 `track.id` 的话不换歌就永远不重取。
        // 不把复合键并进上面那条：那条还在取封面，自定义词一改会连封面一起重取，
        // 白白再跑一遍 0.5 秒的淡入动画。取词那一步因此从 `loadTrackAssets` 里搬到这里。
        .task(id: LyricsStore.displayToken(for: track, trackInfo: trackInfo)) {
            guard let track else {
                model.lyrics.clear()
                return
            }
            await model.lyrics.load(track: track, using: appState.provider(track.kind),
                                    isPlaying: player.isPlaying)
        }
        .onChange(of: isPresented) { _, presented in model.setPresented(presented) }
        // [TYPE] `LyricsOptions.isActive`：抽屉开合 / 播停都要重算一次「是否在跟随」。
        .onChange(of: player.isPlaying) { _, playing in
            model.lyrics.updateActivity(isPlaying: playing)
        }
        .onChange(of: model.isLyricsOpen) { _, _ in
            model.lyrics.updateActivity(isPlaying: player.isPlaying)
        }
        .onAppear { model.setPresented(isPresented) }
    }

    // 窗口级快捷键（Esc 关闭、⌘↑/⌘↓ 音量）原先是三颗零尺寸隐形按钮：
    // 整窗播放器里没有控件持有焦点，`.onExitCommand` / `.onKeyPress` 那类要焦点的写法
    // 收不到事件。骨架换成 AppKit 之后两件都归位了——Esc 走响应链的
    // `RootViewController.cancelOperation(_:)`，⌘↑/⌘↓ 是「控制」菜单里的两条
    // （步长同样是 [实测] §3.3 的 `VolumeScale` ±12/256）。

    // MARK: - MacContentView

    /// [AX] 内容列宽 = 所在半区宽 × 0.28…（右半区占位时半区是窗口的一半，
    /// 不占位时是整窗；1440 宽、歌词开 → 720 × 0.56 = 403）。
    ///
    /// Music 的 `contentWidthFraction` 是**对整窗**取的 0.28，抽屉开时内容列
    /// 落在左半区正中；这里换算成「半区宽的 0.56」，得到同一个数。
    private func macContentView(in size: CGSize) -> some View {
        let byWidth = size.width * M.contentWidthFraction * (showsHostedColumn ? 2 : 1)
        let stackBelowArtwork = M.artworkToMetadata + M.metadataHeight + M.metadataToScrubber
            + M.scrubberHitHeight + M.scrubberToTime + M.timeRowHeight
            + M.timeToTransport + M.transportRowHeight
        let byHeight = size.height - stackBelowArtwork - M.minVerticalMargin * 2
        let column = max(min(byWidth, byHeight), 120).rounded()

        return VStack(spacing: 0) {
            artworkContainerView(size: column)
            Spacer().frame(height: M.artworkToMetadata)
            metadataLabels
            Spacer().frame(height: M.metadataToScrubber)
            macTimeControlView
            Spacer().frame(height: M.timeToTransport)
            controlsAndFooterButtonsView
        }
        .frame(width: column)
        .offset(y: M.contentOffsetY)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    /// **格子的中心 y 就是 `LayoutHints.primaryArtworkCenterY`**（§6.1），
    /// 歌词当前行的基线跟着它走（见 `LyricsBaseline`）——所以报的是外层格子、
    /// 不是里面那张会缩放的图，暂停时基线才不会跟着跳。
    private func artworkContainerView(size: CGFloat) -> some View {
        let scale = player.isPlaying ? M.artworkPlayingScale : M.artworkPausedScale
        // 不取整：403 × 0.7308 = 294.5，正是实测值；取整会掉到 294。
        let drawn = size * scale
        let aspect = metadata.artworkAspectRatio

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
        .reportsPrimaryArtworkCenterY()
    }

    // MARK: - MetadataLabels

    /// [TYPE] `MetadataLabels(fonts:allowsEyebrow:allowsSubtitle:allowsMarquee:)`：
    /// eyebrow（电台/播放列表名）在标题上方，Amber 没有这个概念时整行不占位。
    ///
    /// 标题两行的取值全走 `NowPlayingMetadata`（§4.2）：远控设备名覆盖、
    /// 无条目时的占位串都在那边判，这里只管画。
    private var metadataLabels: some View {
        let meta = metadata
        return HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(meta.primaryTitle)
                    .font(.system(size: M.titleSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(M.titleOpacity))
                    .lineLimit(1)
                // [实测] §4.2 `secondaryTitleIsActionable` + `doSecondaryTitleLinkAction`
                // （导航事件码 0x61）：副标题可点时跳到艺人。
                Group {
                    if meta.secondaryTitleIsActionable, let track {
                        Button {
                            appState.goToArtist(of: track)
                            close()
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
            if let track {
                favoriteButton(track: track, state: meta.favoritingState)
                Spacer().frame(width: M.metadataAccessorySpacing)
                moreButton(track: track)
            }
        }
        .frame(height: M.metadataHeight)
    }

    /// [实测] §4.5 心水是个三态机（内部 {2 liked, 3 disliked}、UI {0,1,2}）。
    /// Amber 只走 none ↔ liked 两态，理由见 `FavoritingState` 的注释。
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

    // MARK: - MacTimeControlView

    /// [AX] 进度条命中区 403×15、可见轨道 6；下面一行时间标签左右各一，
    /// 中间是 `TimeControlAccessoryView`（Music 那处显示「无损」音质徽标）。
    ///
    /// 时间三值走 [实测] §4.3：VM 只给 double 秒，取负与 mm:ss 在这一层。
    private var macTimeControlView: some View {
        let meta = metadata
        // 进度 10 Hz 一跳，只让真的读进度的那几处跟着跳（见 `PlaybackTimeReader`）。
        // 徽标不读进度，必须留在框外：它上面挂着音质气泡，气泡宿主每 100ms
        // 重建一次会闪。
        return VStack(spacing: M.scrubberToTime) {
            PlaybackTimeReader { time in
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
                PlaybackTimeReader { time in
                    Text(timecodeText(meta.currentTimecode(at: time), duration: meta.endingTimecode))
                }
                Spacer(minLength: 4)
                badges(meta.badges)
                Spacer(minLength: 4)
                Button {
                    model.timeAccessory = model.timeAccessory.next
                } label: {
                    PlaybackTimeReader { time in
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

    // MARK: - ControlsAndFooterButtonsView

    /// [AX] 随机 / 循环是贴内容列左右沿的 30×30 命中盒
    /// （`PlayerControlsView.AccessoryButton(alignment:)`），
    /// 中间三颗才是 `TransportControlsView`：上一首中心 −86、播放居中、下一首 +86。
    private var controlsAndFooterButtonsView: some View {
        let state = controlsState
        return ZStack {
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

    // MARK: - 右半区：歌词与待播盘

    /// 两个抽屉共用右半区。歌词在底层铺满，待播盘从底部推上来盖住下半截
    /// （[实测] §6.5 `trackSectionsPlatter.expanded` / `.collapsed`），
    /// 盘高不低于 [实测] §2.2 的 `drawerHeight = 200`。
    private func hostedColumn(in size: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            if model.isLyricsOpen {
                FullWindowHostedContentView(
                    lyrics: model.lyrics,
                    artworkCenterY: model.layoutHints.primaryArtworkCenterY,
                    player: player,
                    // 收起时停掉歌词的每帧驱动。视图留着（展开即完成态），
                    // 只是不再逐帧走查——`CADisplayLink` 是跟着`viewWillAppear`
                    // 起的，而整块播放器是位移出去、不是移出视图树。
                    isActive: isPresented)
            }
            if model.isQueueOpen {
                TrackSectionsPlatter(isActive: isPresented)
                    .frame(height: platterHeight(in: size))
                    .padding(.leading, M.hostedContentInset)
                    .padding(.trailing, M.hostedContentTrailing)
                    .padding(.bottom, M.hostedContentBottom)
                    .reportsHostedContentMinY()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // 单开待播盘时这一列的高度 = 盘高 + 底边距，父 HStack 默认居中对齐，
        // 于是整块盘会往上浮（实测比 hostedContentTop 高了 44）。
        // 注意 `.frame(maxHeight:)` 自己默认也是居中，得显式贴底——歌词开着时
        // 里面那个 GeometryReader 会把列撑满，这条不起作用；单开盘时才生效。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// 歌词也开着时盘只占下半截（下限 200），单开时占满整列。
    private func platterHeight(in size: CGSize) -> CGFloat {
        let available = size.height - M.hostedContentTop - M.hostedContentBottom
        guard model.isLyricsOpen else { return max(available, M.drawerMinHeight) }
        return max(available * 0.5, M.drawerMinHeight)
    }

    // MARK: - HeaderLayoutView

    /// [PX] 左上胶囊 76×36，左沿 100.5（让开红绿灯）、上沿 8。
    private var headerLeading: some View {
        HStack(spacing: 0) {
            capsuleButton("xmark", size: M.closeIconSize, help: "关闭“播放中”") { close() }
            // Music 的语义：收起整窗播放器，并把独立的迷你播放器窗开出来
            // （窗口 ▸ 迷你播放器那一扇，见 MiniPlayerWindowController）。
            capsuleButton("pip.enter", size: M.miniPlayerIconSize, help: "切换到迷你播放程序") {
                close()
                AuxiliaryWindows.shared.showMiniPlayer()
            }
        }
        .frame(width: M.headerLeadingWidth, height: M.capsuleHeight)
        .amberGlass(in: Capsule(), interactive: true)
        .padding(.leading, M.headerLeadingInset)
        .padding(.top, M.headerTop)
        .rollover(model)
    }

    /// [PX] 右上胶囊 217×36，内部横向排布（数字都是胶囊内的偏移）：
    /// AirPlay 槽 40 → 分隔线 1 → 空 11.15 → 音量轨道 114（52.15…166.15）
    /// → 空 6.25 → 喇叭槽 36 → 右内边距 8.6。
    /// 这一串不能用等分 Spacer 顶，实测两端留白并不相等。
    private var headerTrailing: some View {
        let state = controlsState
        return HStack(spacing: 0) {
            // 固有尺寸给成「槽宽 × 胶囊高」，不然 AVRoutePickerView 按正方形
            // 撑到 40×40，上下各探出胶囊 2pt（AX 实测 y 51…91 对胶囊 53…89）。
            AirPlayButton(size: M.airPlaySlotWidth, height: M.capsuleHeight)
                .frame(width: M.airPlaySlotWidth, height: M.capsuleHeight)
                .help("隔空播放")

            Rectangle()
                .fill(.white.opacity(0.16))
                .frame(width: M.volumeDividerWidth, height: M.volumeDividerHeight)

            Spacer().frame(width: M.dividerToVolumeTrack)

            AmberTrackBar(
                progress: player.volume,
                height: M.scrubberBarHeight,
                continuous: true,
                alwaysShowsKnob: true,
                knobSize: CGSize(width: M.volumeKnobWidth, height: M.volumeKnobHeight),
                accessibilityLabel: "音量",
                onScrub: { value in
                    guard state.canSetVolume else { return }
                    player.volume = value
                    model.preMuteVolume = nil
                })
                .frame(width: M.volumeTrackWidth)

            Spacer().frame(width: M.volumeTrackToSpeaker)

            Button {
                model.toggleMute(on: player, state: state)
            } label: {
                Image(systemName: VolumeGlyph.symbol(for: player.volume))
                    .font(.system(size: M.volumeIconSize))
                    .foregroundStyle(.white.opacity(M.volumeIconOpacity))
                    .frame(width: M.speakerSlotWidth, height: M.capsuleHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!state.canMute)
            .help(state.isMuted ? "取消静音" : "静音")
            // [HIG] 喇叭字形随音量换（speaker / wave.1 / wave.3），名字不能跟着变。
            .accessibilityLabel(state.isMuted ? "取消静音" : "静音")

            Spacer().frame(width: M.speakerTrailingInset)
        }
        .frame(width: M.headerTrailingWidth, height: M.capsuleHeight)
        .amberGlass(in: Capsule(), interactive: true)
        .padding(.trailing, M.headerTrailingInset)
        .padding(.top, M.headerTop)
        .rollover(model)
    }

    // MARK: - FooterButtons

    /// [PX] 右下胶囊：每颗键 36 宽的槽，开启态画 30 直径的浅色圆片、图标反相。
    ///
    /// 两颗键 [实测] §1.1 都是 `validate_*` 恒真——**永远可用**，没内容由面板自己兜底。
    /// 歌词那颗右键出 `LyricsOptions.buildOptionsMenu` 的选项菜单（§8.1 / §8.4）。
    private var footerTrailing: some View {
        HStack(spacing: M.footerGlassGroupSpacing) {
            // 歌词模块往底栏塞的那颗（[TYPE] `NowPlayingLookupID`
            // `"lyricsFooterButton"`）。底栏按钮按
            // `FooterLayoutGlassGroup(ids:)` 分组、**一组一颗玻璃**
            // （`FooterButtonView` 还从环境读`_hasGlassGroupSiblings`）——
            // 翻译键自成一组，所以是独立的一颗圆玻璃，不并进歌词/待播那颗胶囊。
            // 只有歌词展开且这首歌真有译文才摆（`drawsTranslationButton` 的语义）。
            if model.isLyricsOpen {
                LyricsTranslationButton(
                    hasTranslation: model.lyrics.lines.hasTranslation,
                    hasTransliteration: model.lyrics.lines.hasTransliteration,
                    placement: .footerSlot)
                    .frame(width: M.capsuleHeight, height: M.capsuleHeight)
                    .amberGlass(in: Circle(), interactive: true)
            }

            HStack(spacing: 0) {
                footerButton("quote.bubble.fill", size: M.lyricsIconSize,
                             active: model.isLyricsOpen,
                             help: model.isLyricsOpen ? "隐藏歌词" : "显示歌词") {
                    withAnimation(.easeInOut(duration: 0.22)) { model.lyricsClicked() }
                }
                .contextMenu {
                    LyricsOptionsMenu(track: track,
                                      hasLyrics: !model.lyrics.isEmpty,
                                      onReportConcern: reportLyricsConcern)
                }
                footerButton("list.bullet", size: M.queueIconSize,
                             active: model.isQueueOpen,
                             help: model.isQueueOpen ? "隐藏待播清单" : "待播清单") {
                    // [实测] §6.5 盘的展开/收起是具名动画
                    // trackSectionsPlatter.expanded/.collapsed
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        model.queueClicked()
                    }
                }
            }
            .frame(height: M.capsuleHeight)
            .amberGlass(in: Capsule(), interactive: true)
        }
        .padding(.trailing, M.footerTrailingInset)
        .padding(.bottom, M.footerBottomInset)
        .rollover(model)
    }

    /// 表情反应条（`EmojiReactionPicker` [TYPE]）：
    /// 按住某个表情持续发射粒子，松手停。参数来自 Music 的 `ReactionEffect.ca`，
    /// 见 `ReactionEffectView.Spec`。Music 只对支持的曲目摆出这颗，Amber 一直摆。
    private var footerLeading: some View {
        HStack(spacing: 0) {
            if model.isReactionBarOpen {
                ForEach(ReactionEmitter.symbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 17))
                        .frame(width: M.footerButtonSlot, height: M.capsuleHeight)
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 0) {
                        } onPressingChanged: { pressing in
                            // [HIG] 减弱动态效果时不发射粒子，免得计时器空转
                            if pressing, !reduceMotion { reactions.start(symbol) } else { reactions.stop() }
                        }
                        .help("按住发送反应")
                }
            }
            footerButton("face.smiling", size: M.reactionIconSize,
                         active: model.isReactionBarOpen,
                         help: model.isReactionBarOpen ? "收起反应" : "反应") {
                withAnimation(.easeInOut(duration: 0.22)) { model.isReactionBarOpen.toggle() }
                reactions.stop()
            }
        }
        .frame(height: M.capsuleHeight)
        .amberGlass(in: Capsule(), interactive: true)
        .padding(.leading, M.footerTrailingInset)
        .padding(.bottom, M.footerBottomInset)
        .rollover(model)
    }

    private func footerButton(_ systemImage: String, size: CGFloat, active: Bool,
                              help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if active {
                    Circle()
                        .fill(.white.opacity(M.footerActiveCircleOpacity))
                        .frame(width: M.footerActiveCircle, height: M.footerActiveCircle)
                }
                Image(systemName: systemImage)
                    .font(.system(size: size))
                    .foregroundStyle(active ? Color.black.opacity(0.82)
                                            : .white.opacity(M.footerIconOpacity))
            }
            .frame(width: M.footerButtonSlot, height: M.capsuleHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        // [HIG] 同上：不补就念 "quote bubble fill" / "list bullet" / "face smiling"。
        .accessibilityLabel(help)
    }

    private func capsuleButton(_ systemImage: String, size: CGFloat, help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .frame(width: M.capsuleHeight, height: M.capsuleHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        // [HIG] 同上：不补就念 "xmark" / "pip enter"。
        .accessibilityLabel(help)
    }

    // MARK: - 动作

    private func close() {
        appState.showingNowPlaying = false
    }

    /// 歌词面板右键里的「报告歌词问题」，与 ••• 菜单末尾那条是同一件事
    /// （出处见 `PlayerMoreMenu.reportLyricsConcern`）。
    private func reportLyricsConcern() {
        PlayerMoreMenu.reportLyricsConcern(appState)
    }

    // MARK: - 数值

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
        switch model.timeAccessory {
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

    // MARK: - 资源加载

    private func loadTrackAssets() async {
        guard let track else {
            // 只有真的没曲目时才清空；换歌时留着旧封面，等新的取回来再换。
            // 先清成 nil 的话背景场跟着变 nil，画面会闪一下空态灰再淡进新色。
            artwork = nil
            return
        }

        // [实测] 整窗播放器走 ITMPMetadataModel 那一档（800），是整套阶梯里最大的
        if let loaded = await ImageCache.shared.image(
            for: ArtworkSize.url(track.artworkURL, points: ArtworkSize.fullPlayer)),
           track.id == self.track?.id {
            withAnimation(.easeInOut(duration: 0.5)) { artwork = loaded }
        }
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

// MARK: - rollover

private extension View {
    /// [实测] §2.3：悬浮控件跟着 `rollState` 淡入淡出；鼠标停在控件上就不收
    /// （Music 那边是 `rolloverTracker` 挡的）。
    func rollover(_ model: NowPlayingViewModel) -> some View {
        opacity(model.rolloverVisible ? 1 : 0)
            .allowsHitTesting(model.rolloverVisible)
            .onHover { inside in
                if inside { model.holdRollover() } else { model.noteMouseActivity() }
            }
    }
}
