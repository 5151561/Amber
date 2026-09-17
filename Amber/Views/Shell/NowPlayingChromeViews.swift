import AVKit
import AppKit
import SwiftUI

/// 整窗播放器的四角玻璃胶囊与粒子层（Music 的 `HeaderLayoutView` + `FooterButtons`）。
///
/// ```
/// NowPlayingChromeView                    整块铺满窗口，空处不接命中测试
///   ├── glassContainer : NSGlassEffectContainerView   四颗胶囊整层跟着 rollover 一起淡
///   │     ├── headerLeading   关闭 + 切迷你播放器
///   │     ├── headerTrailing  AirPlay + 分隔线 + 音量条 + 喇叭
///   │     ├── footerLeading   反应条
///   │     └── footerTrailing  翻译（独立圆玻璃）+ 歌词/待播胶囊
///   └── particles : ReactionEffectView    反应粒子，不跟着 rollover 淡
/// ```
///
/// 像素全部照 `MusicMetrics.NowPlaying` 那一组（[PX] 逐项实测），换骨架一个数不改。
///
/// rollover（[实测] nowplaying spec §2.3）由本视图自己持有并驱动，**不上广播**
/// （AGENTS.md 界面层铁律 3；那条原来写的是「不经 `@Published`」，剥离 Combine 之后
/// 换成了 `@Observable` 的属性，要守的东西一个字没变）；两档计时取 miniplayer spec §11.1 `MPContentView`
/// 的 ivar 实测值——那张表记的就是整窗内容视图自己的字段，迷你横条与整窗是同一台
/// `MPContentView`，所以两处本来就是同一个数。
@MainActor
final class NowPlayingChromeView: NSView, NSMenuItemValidation {

    private typealias M = MusicMetrics.NowPlaying

    // MARK: 对外

    var onClose: (() -> Void)?
    var onShowMiniPlayer: (() -> Void)?
    var onInspectorClicked: ((PlayerInspector) -> Void)?
    var onReportLyricsConcern: (() -> Void)?

    /// 整窗播放器展开着没有。收起期间不起 rollover 计时、不发射粒子。
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                setRollState(true, animated: false)
                // 展开时**只显形、不起计时**：Music 那对计时器是
                // `mouseStartingInterestTimer`（等鼠标先进来）+ `mouseInterestTimer`
                // （进来之后才计停留），所以「开了播放中但一直没动鼠标」不该把关闭键
                // 也收掉。指针本来就在窗内（有过 mouseMoved）时才把兴趣计时续上。
                if pointerInside { updateRollover(interested: true) }
            } else {
                mouseInterestTimer?.invalidate(); mouseInterestTimer = nil
                mouseStartingInterestTimer?.invalidate(); mouseStartingInterestTimer = nil
                reactions.stop()
                setRollState(true, animated: false)
            }
        }
    }

    // MARK: 私有状态（铁律 3：界面自己的显示态自己持有，不上广播）

    private let appState: AppState
    private var player: PlayerController { appState.player }

    private var isInspectorOpen = false
    private var inspectorMode: PlayerInspector

    /// [TYPE] `NowPlayingViewModel.VolumeControl.preMuteVolume: Float?`：
    /// 静音只是把音量压到 0，再点一次要还原到静音前那一档。
    private var preMuteVolume: Double?

    /// 反应条（[TYPE] `EmojiReactionPicker`）展开着没有。
    private var isReactionBarOpen = false

    /// 这首歌的显示歌词。翻译键摆不摆、右键那条「报告歌词问题」灰不灰都看它。
    /// 取的是 `LyricsStore` 的**显示口**（自定义歌词优先），与歌词面板共用同一份缓存，
    /// 所以这一路不会多打一趟网络。
    private var displayLyrics: [LyricLine] = []
    private var lyricsToken: String?
    private var lyricsTask: Task<Void, Never>?

    private let observers = TaskBag()

    // MARK: rollover（nowplaying spec §2.3）

    /// `rollState` 的等价物：四颗胶囊这一整层现在露不露。
    private var rollState = true
    /// `mouseInterestTimer`：到点把胶囊淡掉。
    private var mouseInterestTimer: Timer?
    /// `mouseStartingInterestTimer`：起步计时，压住「指针擦过窗口」的抖动。
    private var mouseStartingInterestTimer: Timer?
    private var pointerInside = false
    private var rolloverTrackingArea: NSTrackingArea?
    /// `viewDidMoveToWindow` 挂的`windowFocusObserver`（spec §2.3 的 +384）。
    /// 另一支 `accessibilityFocusObserver`（+392）没做：AX 焦点没有公开通知。
    private var focusObservers: [any NSObjectProtocol] = []

    // MARK: 视图

    /// [HIG] *Adopting Liquid Glass*：多个自定义玻璃元素要包进同一个容器
    /// （「helps optimize performance by reducing the number of passes」）。
    /// `spacing` 留 0——头文件原话：默认值足够做批处理，又不会把邻近的两片
    /// 合并变形。翻译键与歌词/待播那颗胶囊只隔 6，正是**不能**合并的一对。
    private let glassContainer = NSGlassEffectContainerView()
    private let capsuleHost = NSView()

    private let headerLeadingGlass = NSGlassEffectView()
    private let headerTrailingGlass = NSGlassEffectView()
    private let footerLeadingGlass = NSGlassEffectView()
    private let footerTrailingGlass = NSGlassEffectView()
    private let translationGlass = NSGlassEffectView()

    private let headerLeadingContent = CapsuleContentView()
    private let headerTrailingContent = CapsuleContentView()
    private let footerLeadingContent = CapsuleContentView()
    private let footerTrailingContent = CapsuleContentView()

    private let closeButton = NowPlayingIconButton()
    private let miniPlayerButton = NowPlayingIconButton()

    /// 系统输出设备选择器直接放（铁律 1：不再经 `NSViewRepresentable`）。
    private let routePicker = NowPlayingRoutePickerView()
    private let volumeDivider = NSView()
    /// [实测] 系统 `NSSlider`（regular）在这版 macOS 上就是「细轨 + 横胶囊滑块」：
    /// 轨道高 6，与 [PX] 对 Music 量到的 6 一模一样；拖动时的玻璃高光是自绘层做不出来的。
    /// 所以这里用系统件，不再自绘（AGENTS 界面层铁律 6：先用系统默认值）。
    private let volumeBar = NSSlider()
    private let speakerButton = NowPlayingIconButton()

    private let lyricsButton = NowPlayingIconButton()
    private let queueButton = NowPlayingIconButton()
    private var translationHost: NSHostingView<AnyView>?

    private let reactionButton = NowPlayingIconButton()
    private var emojiButtons: [NowPlayingEmojiButton] = []

    private let reactions = ReactionEmitter()
    private let particles = ReactionEffectView()

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - 生命周期

    init(appState: AppState) {
        self.appState = appState
        self.inspectorMode = appState.inspectorMode
        super.init(frame: .zero)
        wantsLayer = true
        buildViews()
        bind()
        updateVolume()
        updateInspectorButtons()
        updateReactionBar(animated: false)
        reloadLyricsIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 计时器与观察者令牌都不是 `Sendable`，非隔离的 `deinit` 取不到它们。
    /// 标 `isolated`：主线程上释放时照旧同步跑完，注销时机不变。
    isolated deinit {
        mouseInterestTimer?.invalidate()
        mouseStartingInterestTimer?.invalidate()
        let center = NotificationCenter.default
        focusObservers.forEach(center.removeObserver)
    }

    override var isFlipped: Bool { false }

    /// 空处不接命中测试：整窗播放器的内容列压在本层底下，点封面/进度条要落到它身上。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self || hit === glassContainer || hit === capsuleHost || hit === particles {
            return nil
        }
        return hit
    }

    // MARK: - 搭视图

    private func buildViews() {
        glassContainer.contentView = capsuleHost
        addSubview(glassContainer)

        for glass in [headerLeadingGlass, headerTrailingGlass,
                      footerLeadingGlass, footerTrailingGlass, translationGlass] {
            // 小胶囊压在近乎平坦的底色上，[实测] 填充只比底色暗 2 级——clear 那一档。
            glass.style = .clear
            glass.cornerRadius = M.capsuleHeight / 2
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            capsuleHost.addSubview(glass)
        }
        headerLeadingGlass.contentView = headerLeadingContent
        headerTrailingGlass.contentView = headerTrailingContent
        footerLeadingGlass.contentView = footerLeadingContent
        footerTrailingGlass.contentView = footerTrailingContent

        // 左上：关闭 + 切迷你播放器
        configure(closeButton, symbol: "xmark", pointSize: M.closeIconSize,
                  help: "关闭“播放中”") { [weak self] in self?.onClose?() }
        // Music 的语义：收起整窗播放器，并把独立的迷你播放器窗开出来
        // （窗口 ▸ 迷你播放器那一扇，见 MiniPlayerWindowController）。
        configure(miniPlayerButton, symbol: "pip.enter", pointSize: M.miniPlayerIconSize,
                  help: "切换到迷你播放程序") { [weak self] in self?.onShowMiniPlayer?() }
        [closeButton, miniPlayerButton].forEach(headerLeadingContent.addSubview)

        // 右上：AirPlay + 分隔线 + 音量条 + 喇叭
        routePicker.isRoutePickerButtonBordered = false
        routePicker.toolTip = "隔空播放"
        routePicker.setAccessibilityLabel("隔空播放")
        headerTrailingContent.addSubview(routePicker)

        volumeDivider.wantsLayer = true
        volumeDivider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
        headerTrailingContent.addSubview(volumeDivider)

        volumeBar.minValue = 0
        volumeBar.maxValue = 1
        volumeBar.isContinuous = true
        volumeBar.controlSize = .regular
        // 胶囊是压在封面模糊上的深色玻璃，这一块整体按深色渲染：滑块与轨道才是白的。
        // `trackFillColor` 取 `.labelColor` 与迷你播放器窗那条同源（[实测]）。
        volumeBar.appearance = NSAppearance(named: .darkAqua)
        volumeBar.trackFillColor = .labelColor
        volumeBar.target = self
        volumeBar.action = #selector(volumeSliderChanged)
        volumeBar.setAccessibilityLabel("音量")
        headerTrailingContent.addSubview(volumeBar)

        configure(speakerButton, symbol: VolumeGlyph.symbol(for: 1),
                  pointSize: M.volumeIconSize, help: "静音") { [weak self] in self?.toggleMute() }
        // [PX] 同一条胶囊里只有这颗不是纯白：关闭/迷你播放器/AirPlay 都是 1.00，喇叭 0.85。
        speakerButton.glyphColor = NSColor(white: 1, alpha: M.volumeIconOpacity)
        headerTrailingContent.addSubview(speakerButton)

        // 右下：歌词 + 待播 + 独立圆玻璃的翻译键
        configure(lyricsButton, symbol: "quote.bubble.fill", pointSize: M.lyricsIconSize,
                  help: "显示歌词") { [weak self] in self?.onInspectorClicked?(.lyrics) }
        configure(queueButton, symbol: "list.bullet", pointSize: M.queueIconSize,
                  help: "待播清单") { [weak self] in self?.onInspectorClicked?(.queue) }
        lyricsButton.menu = makeLyricsOptionsMenu()
        [lyricsButton, queueButton].forEach(footerTrailingContent.addSubview)

        let host = appState.hostingView { translationButton }
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = []
        translationHost = host
        translationGlass.contentView = host
        translationGlass.isHidden = true

        // 左下：反应条
        configure(reactionButton, symbol: "face.smiling", pointSize: M.reactionIconSize,
                  help: "反应") { [weak self] in self?.toggleReactionBar() }
        footerLeadingContent.addSubview(reactionButton)
        for symbol in ReactionEmitter.symbols {
            let button = NowPlayingEmojiButton(symbol: symbol)
            button.onPressChanged = { [weak self] pressing in
                guard let self else { return }
                // [HIG] 减弱动态效果时不发射粒子，免得计时器空转。
                if pressing, !self.reduceMotion {
                    self.reactions.start(symbol)
                } else {
                    self.reactions.stop()
                }
            }
            button.isHidden = true
            footerLeadingContent.addSubview(button)
            emojiButtons.append(button)
        }

        // 粒子铺满整块，从反应条那条线往上飞。**不跟着 rollover 淡**：胶囊收掉之后
        // 已经在飞的那几颗照常走完自己的 lifetime。
        reactions.onEmit = { [weak self] symbol in self?.particles.emit(symbol) }
        particles.emitterBottomInset = M.footerBottomInset + M.capsuleHeight + 8
        addSubview(particles)
    }

    private func configure(_ button: NowPlayingIconButton, symbol: String, pointSize: CGFloat,
                           help: String, action: @escaping () -> Void) {
        button.symbolName = symbol
        button.pointSize = pointSize
        button.toolTip = help
        // [HIG] *Adopting Liquid Glass*：「always specify an accessibility label for each
        // icon」。不补这一句 VoiceOver 念的就是 "xmark"、"quote bubble fill" 这种字形名。
        button.setAccessibilityLabel(help)
        button.onClick = action
    }

    // MARK: - 订阅

    private func bind() {
        // `@Published` 是在 **willSet** 里发的，同步读回去拿到的是**旧值**，
        // 异步回主队列这一跳正好落在赋值之后（同 `MiniPlayerView.bind`）。
        observers.observe({ [player] in player.volume }) { [weak self] _ in
            self?.updateVolume()
        }

        observers.observeAny({ [player] in (player.currentIndex, player.queue) }) { [weak self] in
            self?.reloadLyricsIfNeeded()
        }

        // 在「显示简介 › 歌词」里改完自定义歌词，显示口那份会换，翻译键跟着重判。
        observers.observe({ TrackInfoStore.shared.infos }) { [weak self] _ in self?.reloadLyricsIfNeeded() }
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        glassContainer.frame = bounds
        capsuleHost.frame = bounds
        particles.frame = bounds

        let capsule = M.capsuleHeight
        let top = bounds.height - M.headerTop - capsule

        // [PX] 左上胶囊 76×36，左沿 100.5（让开红绿灯）、上沿 8。
        headerLeadingGlass.frame = NSRect(x: M.headerLeadingInset, y: top,
                                          width: M.headerLeadingWidth, height: capsule)
        headerLeadingContent.frame = NSRect(x: 0, y: 0,
                                            width: M.headerLeadingWidth, height: capsule)
        // 两颗 36 宽的槽在 76 的胶囊里居中（旧版是 `HStack(spacing: 0).frame(width: 76)`）。
        let leadingPad = (M.headerLeadingWidth - capsule * 2) / 2
        closeButton.frame = NSRect(x: leadingPad, y: 0, width: capsule, height: capsule)
        miniPlayerButton.frame = NSRect(x: leadingPad + capsule, y: 0,
                                        width: capsule, height: capsule)

        // [PX] 右上胶囊 217×36，距窗口右沿 8。内部横向排布（胶囊内偏移）：
        // AirPlay 槽 40 → 分隔线 1 → 空 11.15 → 音量轨道 114（52.15…166.15）
        // → 空 6.25 → 喇叭槽 36 → 右内边距 8.6。这一串不能用等分间隔顶，
        // 实测两端留白并不相等。
        headerTrailingGlass.frame = NSRect(
            x: bounds.width - M.headerTrailingInset - M.headerTrailingWidth, y: top,
            width: M.headerTrailingWidth, height: capsule)
        headerTrailingContent.frame = NSRect(x: 0, y: 0,
                                             width: M.headerTrailingWidth, height: capsule)
        routePicker.frame = NSRect(x: 0, y: 0, width: M.airPlaySlotWidth, height: capsule)
        volumeDivider.frame = NSRect(x: M.airPlaySlotWidth,
                                     y: (capsule - M.volumeDividerHeight) / 2,
                                     width: M.volumeDividerWidth, height: M.volumeDividerHeight)
        let trackX = M.airPlaySlotWidth + M.volumeDividerWidth + M.dividerToVolumeTrack
        // 高度取系统件自己的自然高（[实测] regular 16），只钉 [PX] 量到的轨道宽 114。
        let sliderHeight = volumeBar.fittingSize.height
        volumeBar.frame = NSRect(x: trackX, y: (capsule - sliderHeight) / 2,
                                 width: M.volumeTrackWidth, height: sliderHeight)
        speakerButton.frame = NSRect(x: trackX + M.volumeTrackWidth + M.volumeTrackToSpeaker,
                                     y: 0, width: M.speakerSlotWidth, height: capsule)

        // [PX] 右下：两颗键的胶囊 72×36，距窗口右沿 10、底 11.5。
        let footerGroupWidth = M.footerButtonSlot * 2
        let footerGroupX = bounds.width - M.footerTrailingInset - footerGroupWidth
        footerTrailingGlass.frame = NSRect(x: footerGroupX, y: M.footerBottomInset,
                                           width: footerGroupWidth, height: capsule)
        footerTrailingContent.frame = NSRect(x: 0, y: 0,
                                             width: footerGroupWidth, height: capsule)
        lyricsButton.frame = NSRect(x: 0, y: 0, width: M.footerButtonSlot, height: capsule)
        queueButton.frame = NSRect(x: M.footerButtonSlot, y: 0,
                                   width: M.footerButtonSlot, height: capsule)
        // 翻译键自成一组（[TYPE] `FooterLayoutGlassGroup`：一组一颗玻璃），
        // 所以是独立的一颗圆玻璃，与那颗胶囊隔 `footerGlassGroupSpacing`。
        translationGlass.frame = NSRect(
            x: footerGroupX - M.footerGlassGroupSpacing - M.footerButtonSlot,
            y: M.footerBottomInset, width: M.footerButtonSlot, height: capsule)
        translationHost?.frame = NSRect(x: 0, y: 0, width: M.footerButtonSlot, height: capsule)

        // [PX] 左下：反应条。展开时前面多摆六个表情槽。
        let reactionWidth = M.footerButtonSlot * CGFloat(isReactionBarOpen
                                                        ? emojiButtons.count + 1 : 1)
        footerLeadingGlass.frame = NSRect(x: M.footerTrailingInset, y: M.footerBottomInset,
                                          width: reactionWidth, height: capsule)
        footerLeadingContent.frame = NSRect(x: 0, y: 0, width: reactionWidth, height: capsule)
        for (index, button) in emojiButtons.enumerated() {
            button.frame = NSRect(x: M.footerButtonSlot * CGFloat(index), y: 0,
                                  width: M.footerButtonSlot, height: capsule)
        }
        reactionButton.frame = NSRect(
            x: reactionWidth - M.footerButtonSlot, y: 0,
            width: M.footerButtonSlot, height: capsule)
    }

    // MARK: - 各件的刷新

    /// 宿主推进来的抽屉状态：两颗底栏键的开启态按它画。
    func setInspector(open: Bool, mode: PlayerInspector) {
        isInspectorOpen = open
        inspectorMode = mode
        updateInspectorButtons()
    }

    private func updateInspectorButtons() {
        let lyricsOpen = isInspectorOpen && inspectorMode == .lyrics
        let queueOpen = isInspectorOpen && inspectorMode == .queue
        apply(lyricsButton, active: lyricsOpen,
              help: lyricsOpen ? "隐藏歌词" : "显示歌词")
        apply(queueButton, active: queueOpen,
              help: queueOpen ? "隐藏待播清单" : "待播清单")
        updateTranslationButton()
    }

    /// [PX] 开启态画 30 直径的浅色圆片、图标反相；关闭态是**纯白**。
    private func apply(_ button: NowPlayingIconButton, active: Bool, help: String) {
        button.drawsActiveCircle = active
        button.glyphColor = active ? NSColor(white: 0, alpha: 0.82)
                                   : NSColor(white: 1, alpha: M.footerIconOpacity)
        button.toolTip = help
        button.setAccessibilityLabel(help)
    }

    @objc private func volumeSliderChanged() {
        guard PlayerControlsState(player: player).canSetVolume else { return }
        player.volume = volumeBar.doubleValue
        preMuteVolume = nil
    }

    private func updateVolume() {
        // 拖动中这条回来的就是自己刚写出去的值，写回去也不动；不等才赋值，免得跟手时打架。
        if volumeBar.doubleValue != player.volume { volumeBar.doubleValue = player.volume }
        volumeBar.isEnabled = PlayerControlsState(player: player).canSetVolume
        speakerButton.symbolName = VolumeGlyph.symbol(for: player.volume)
        let state = PlayerControlsState(player: player)
        speakerButton.isEnabled = state.canMute
        // [HIG] 喇叭字形随音量换（speaker / wave.1 / wave.3），名字不能跟着变。
        let help = state.isMuted ? "取消静音" : "静音"
        speakerButton.toolTip = help
        speakerButton.setAccessibilityLabel(help)
    }

    /// 静音：压到 0 并记下原值；再点一次还原。`canMute` 为假不动。
    private func toggleMute() {
        let state = PlayerControlsState(player: player)
        guard state.canMute else { return }
        if let restored = preMuteVolume {
            player.volume = restored
            preMuteVolume = nil
        } else {
            preMuteVolume = player.volume
            player.volume = 0
        }
    }

    private func toggleReactionBar() {
        isReactionBarOpen.toggle()
        reactions.stop()
        updateReactionBar(animated: true)
    }

    private func updateReactionBar(animated: Bool) {
        apply(reactionButton, active: isReactionBarOpen,
              help: isReactionBarOpen ? "收起反应" : "反应")
        emojiButtons.forEach { $0.isHidden = !isReactionBarOpen }
        guard animated, !reduceMotion else {
            needsLayout = true
            layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    // MARK: - 歌词（翻译键与右键菜单）

    /// 歌词模块往底栏塞的那颗（[TYPE] `NowPlayingLookupID("lyricsFooterButton")`）。
    /// 只有歌词展开且这首歌真有译文/发音才摆（`drawsTranslationButton` 的语义）。
    private var translationButton: some View {
        LyricsTranslationButton(hasTranslation: displayLyrics.hasTranslation,
                                hasTransliteration: displayLyrics.hasTransliteration,
                                placement: .footerSlot)
    }

    private func updateTranslationButton() {
        let lyricsOpen = isInspectorOpen && inspectorMode == .lyrics
        let hasAny = displayLyrics.hasTranslation || displayLyrics.hasTransliteration
        translationGlass.isHidden = !(lyricsOpen && hasAny)
        translationHost?.rootView = appState.hostingRoot { translationButton }
    }

    private func reloadLyricsIfNeeded() {
        let track = player.currentTrack
        let token = LyricsStore.displayToken(for: track, trackInfo: TrackInfoStore.shared)
        guard token != lyricsToken else { return }
        lyricsToken = token
        lyricsTask?.cancel()

        guard let track else {
            displayLyrics = []
            updateTranslationButton()
            return
        }
        if let cached = LyricsStore.shared.cachedDisplayLyrics(for: track) {
            displayLyrics = cached
            updateTranslationButton()
            return
        }
        displayLyrics = []
        updateTranslationButton()
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let loaded = await LyricsStore.shared.displayLyrics(
                for: track, using: self.appState.provider(track.kind))
            guard !Task.isCancelled, self.player.currentTrack?.id == track.id else { return }
            self.displayLyrics = loaded
            self.updateTranslationButton()
        }
    }

    /// [TYPE] `LyricsOptions._buildOptionsMenu`。那一项在 Music 里挂的是
    /// [实测] §8.4 `PBPlayerMetadataViewModel.doReportAConcernForLyricsForCurrentlyPlayingItem`
    /// ——入口在播放器元数据 VM 上，不在歌词模块里，所以 Amber 也从这条接。
    private func makeLyricsOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "报告歌词问题",
                              action: #selector(reportLyricsConcern(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func reportLyricsConcern(_ sender: Any?) {
        onReportLyricsConcern?()
    }

    /// `NSMenuItemValidation`：右键菜单里那一项「没歌 / 没词就置灰」。
    /// `NSView` 自己不实现这个方法，所以是协议实现而不是 `override`。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(reportLyricsConcern(_:)) else { return true }
        return player.currentTrack != nil && !displayLyrics.isEmpty
    }

    // MARK: - rollover（nowplaying spec §2.3）

    /// `NSTrackingArea` 装在本视图自己身上：`.inVisibleRect` 让它跟着 bounds 走，
    /// 窗口每次 resize 都不用重算矩形。`.mouseMoved` 由 tracking area 自己投递
    /// ——与 `hitTest` 无关，所以「空处不接命中」不妨碍收鼠标移动。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let rolloverTrackingArea { removeTrackingArea(rolloverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        rolloverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        updateRollover(interested: true)
    }

    override func mouseMoved(with event: NSEvent) {
        pointerInside = true
        updateRollover(interested: true)
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        // ★ 离开窗口走的是短的那一档（0.3），不是窗内静止那档（3.75）。
        updateRollover(interested: false, exitingWindow: true)
    }

    /// spec §2.3 的 `viewDidMoveToWindow`：挂窗口焦点观察，焦点变化也驱动淡入淡出。
    /// 块式观察者注册的是通知中心自己造的令牌，`removeObserver(self)` 摘不掉，
    /// 得存下来逐个摘。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        focusObservers.forEach(center.removeObserver)
        focusObservers = []
        guard let window = amberWindow else { return }
        // 块式观察者的闭包是 `@Sendable`；`queue: .main` 已经把投递线程钉死在主线程，
        // 所以用 `assumeIsolated` 接回主线程隔离的自己。
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            focusObservers.append(center.addObserver(forName: name, object: window,
                                                     queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateRollover(interested: self.pointerInside)
                }
            })
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification] {
            focusObservers.append(center.addObserver(forName: name, object: window,
                                                     queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRollover(interested: false) }
            })
        }
        updateRollover(interested: pointerInside)
    }

    /// 有「兴趣」（指针在窗内、或窗口刚拿到焦点）就露出来；没有就起表，到点淡掉。
    ///
    /// [实测] miniplayer spec §11.1 的**双计时器**：起步计时
    /// `kDelayBeforeStartingRolloverMin` = 0.1 决定「多久之后才认这次兴趣」，
    /// 兴趣计时决定「多久之后淡掉」——窗内静止 `kMouseInterestTimeoutInSeconds` = 3.75、
    /// 指针离开窗口 `kMouseInterestExitingWindowTimeoutInSeconds` = 0.3。
    /// 那张 ivar 表记的就是 `MPContentView`（整窗内容视图）自己的字段，
    /// 迷你横条与整窗共用同一台，所以两处是同一个数（旧版这里写的 3 是 `[推]`）。
    private func updateRollover(interested: Bool, exitingWindow: Bool = false) {
        guard isActive else { return }
        guard interested else {
            mouseStartingInterestTimer?.invalidate()
            mouseStartingInterestTimer = nil
            scheduleRolloverHide(after: exitingWindow ? NowPlayingRollover.exitingWindow
                                                      : NowPlayingRollover.interest)
            return
        }
        // 已经露着：只把兴趣计时续上，不重新起步。
        if rollState {
            scheduleRolloverHide(after: NowPlayingRollover.interest)
            return
        }
        guard mouseStartingInterestTimer == nil else { return }
        mouseStartingInterestTimer = Timer.scheduledTimer(
            withTimeInterval: NowPlayingRollover.startDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mouseStartingInterestTimer = nil
                self.setRollState(true, animated: true)
                self.scheduleRolloverHide(after: NowPlayingRollover.interest)
            }
        }
    }

    private func scheduleRolloverHide(after delay: TimeInterval) {
        mouseInterestTimer?.invalidate()
        mouseInterestTimer = nil
        mouseInterestTimer = Timer.scheduledTimer(withTimeInterval: delay,
                                                  repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.setRollState(false, animated: true) }
        }
    }

    /// `setRollState:`。四颗胶囊整层一起改 `alphaValue`——这就是「它们必须共一个容器」
    /// 的理由。粒子层不在这一层里，已经在飞的粒子不跟着淡。
    private func setRollState(_ visible: Bool, animated: Bool) {
        guard visible != rollState else { return }
        rollState = visible
        let target: CGFloat = visible ? 1 : 0
        if visible { glassContainer.isHidden = false }
        guard animated, !reduceMotion else {
            glassContainer.alphaValue = target
            // 淡到 0 之后彻底摘掉：`alphaValue == 0` 的视图在 AppKit 里照样吃点击。
            glassContainer.isHidden = !visible
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? NowPlayingRollover.fadeIn : NowPlayingRollover.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            glassContainer.animator().alphaValue = target
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.glassContainer.isHidden = self.glassContainer.alphaValue <= 0
            }
        }
    }
}

// MARK: - 胶囊里的那种键

/// 无边框图标键。字号是视觉大小，frame 是 [PX] 实测的槽——两者独立。
/// 底栏那两颗还要画开启态那片 30 直径的浅色圆片（图标反相由 `glyphColor` 给）。
private final class NowPlayingIconButton: NSButton {

    var onClick: (() -> Void)?

    var symbolName = "" { didSet { applySymbol() } }
    var pointSize: CGFloat = 13 { didSet { applySymbol() } }
    var glyphColor: NSColor = .white {
        didSet { contentTintColor = glyphColor }
    }
    /// [PX] 开启态是 30 直径的浅色圆片，图标反相。
    var drawsActiveCircle = false {
        didSet {
            guard drawsActiveCircle != oldValue else { return }
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .shadowlessSquare
        imagePosition = .imageOnly
        // 字号已经是 [PX] 反推出来的视觉大小，槽比它大；默认的
        // `.scaleProportionallyDown` 会在盒子偏小时偷偷把字形缩掉。
        imageScaling = .scaleNone
        title = ""
        target = self
        action = #selector(clicked)
        contentTintColor = glyphColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clicked() { onClick?() }

    private func applySymbol() {
        guard !symbolName.isEmpty else { return }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    override func draw(_ dirtyRect: NSRect) {
        if drawsActiveCircle {
            let diameter = MusicMetrics.NowPlaying.footerActiveCircle
            // [PX] 圆片 (210,210,209) 压在玻璃 (46,45,40) 上 → 白 0.78
            NSColor(white: 1, alpha: MusicMetrics.NowPlaying.footerActiveCircleOpacity).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - diameter / 2,
                                        y: bounds.midY - diameter / 2,
                                        width: diameter, height: diameter)).fill()
        }
        super.draw(dirtyRect)
    }
}

/// 四块玻璃胶囊的内容宿主。胶囊是控件区，不是拖窗把手——瞄滑块差几点落到胶囊底色上，
/// 窗就被划走。[实测 2026-09-17 真指针拖拽] 挡住它要**两条同时成立**：
/// 继承 `NSControl`，**且**自己把 `mouseDown` 吃掉。少任何一条都还会被拖走：
/// 光覆写 `mouseDownCanMoveWindow = false` 不管用（`-dumpviews` 的 drag 列看得到它确实
/// 答了 false，窗照样走）；光换成 `NSControl` 不吃 `mouseDown` 也不管用。
private final class CapsuleContentView: NSControl {
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

// MARK: - 反应条里的表情

/// 按住某个表情持续发射粒子，松手停。不能用 `NSButton`：它的动作在松手时才发，
/// 这里要的是按下/松开两端。
/// 继承 `NSControl` 的理由同 `NowPlayingVolumeBar`：`NSView` 的话按住往旁边一挪，
/// 拖动被窗口截走、`mouseUp` 永远不来，`pressed` 卡在 true、粒子停不下。
private final class NowPlayingEmojiButton: NSControl {

    var onPressChanged: ((Bool) -> Void)?

    private let symbol: String
    private var pressed = false

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        toolTip = "按住发送反应"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("发送反应 \(symbol)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17)]
        let text = symbol as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                              y: bounds.midY - size.height / 2),
                  withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        onPressChanged?(true)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        onPressChanged?(false)
    }

    override func accessibilityPerformPress() -> Bool {
        onPressChanged?(true)
        onPressChanged?(false)
        return true
    }
}

// MARK: - AirPlay

/// 系统输出设备选择器（Music 用的是同一颗）。`AVRoutePickerView` 的固有尺寸比槽大一圈
/// （实测画到 41.5×38），会把自己撑出给定的盒子——[PX] 这里的槽是 40 宽 × 36 高，
/// 不是正方形（AX 实测 y 51…91 对胶囊 53…89 就是被它撑的）。
private final class NowPlayingRoutePickerView: AVRoutePickerView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: MusicMetrics.NowPlaying.airPlaySlotWidth,
               height: MusicMetrics.NowPlaying.capsuleHeight)
    }
}
