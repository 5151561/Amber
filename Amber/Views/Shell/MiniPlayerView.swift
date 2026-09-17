import AVKit
import AppKit
import SwiftUI

/// 底部悬浮播放条：液态玻璃胶囊，对 macOS Music.app 逐项实测复刻。
///
/// 版式（自左向右）：传输键（148）· g · 中央区块 · g · 歌词/待播/AirPlay/音量（147），
/// 两侧内缩 9，总宽恒为 700。g 随播放态变：空闲 9（中央块 369），有曲目 1（中央块 385）。
/// 度量与出处见 `MusicMetrics.MiniPlayer`。
///
/// 交互对齐 Music.app：
/// - 胶囊悬浮：歌名右侧浮现星形收藏键
/// - 进度条悬浮：细线长高为粗条，封面/文字淡出+虚化+缩小，浮现已播/剩余时间标签
/// - 展开全屏：有歌时入口在封面上（悬浮浮现展开图标），无歌时只有中央那一个图标
///
/// 骨架换 AppKit（appkit-rewrite-plan 阶段 2）时**像素与行为一个不改**，只换了实现：
/// 玻璃 `NSGlassEffectView`、按键`NSButton`、封面/进度条/音量条自绘、悬浮态
/// `NSTrackingArea` + 自己持有的布尔（铁律 3：界面自己的显示态自己持有，不上广播）。
/// 内部排版全部走 `layout()` 手排 frame：这一条胶囊的每个数都是实测常量，
/// 用约束表达反而要为「组间距随播放态跳变」再挂一层可变约束。
@MainActor
final class MiniPlayerView: NSView {

    private typealias M = MusicMetrics.MiniPlayer

    /// 展开到全屏播放器的示意图标
    fileprivate static let expandSymbol = "arrow.up.left.and.arrow.down.right"

    private let appState: AppState
    private var player: PlayerController { appState.player }
    private var library: LibraryStore { appState.library }
    private let observers = TaskBag()

    // MARK: 视图

    /// 玻璃胶囊。旧版是 SwiftUI `.glassEffect(.regular)`（`amberGlass(clear: false)`），
    /// AppKit 侧对应 `NSGlassEffectView.Style.regular`——SDK 头文件里这枚枚举只有
    /// `regular`（Standard glass effect style）与`clear`（Clear glass effect style）两档，
    /// 与 SwiftUI 的 `Glass.regular` / `.clear` 一一对应。
    private let glass = NSGlassEffectView()
    /// 玻璃只保证 `contentView` 在效果里面（头文件原话），所有控件都挂这一层。
    private let content = NSView()

    private let shuffleButton = MiniIconButton()
    private let previousButton = MiniIconButton()
    private let playButton = MiniIconButton()
    private let nextButton = MiniIconButton()
    private let repeatButton = MiniIconButton()

    private let centerView = NSView()
    /// 进度条悬浮时整体淡出/缩小/虚化的那一层（封面、两行字、星、波形、更多）
    private let centerContent = NSView()
    private let artworkView = MiniArtworkView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let starButton = MiniIconButton()
    private let qualityButton = MiniIconButton()
    private let moreButton = MiniIconButton()
    private let placeholderButton = MiniIconButton()
    private let progressView = MiniProgressView()
    /// 只在进度条悬浮时淡入。用的是不参与命中的子类：这两枚常驻在中央块两端、
    /// 只是 alpha 为 0，普通 `NSTextField` 会把底下的波形/更多/星形键整条盖住。
    private let elapsedField = MiniTimeLabel(labelWithString: "")
    private let remainingField = MiniTimeLabel(labelWithString: "")

    /// 音量气泡里那条自绘细条
    private let volumeBar = MiniVolumeBar()

    private let lyricsButton = MiniIconButton()
    private let queueButton = MiniIconButton()
    private let airPlayButton = MiniRoutePickerView()
    private let volumeButton = MiniIconButton()

    // MARK: 自己持有的状态（铁律 3）

    private var track: Track?
    private var capsuleHovering = false
    private var scrubHovering = false
    private var showingQuality = false
    private var showingVolume = false
    private var capsuleTracking: NSTrackingArea?
    /// 弹出中的 ••• 菜单（见 `showMoreMenu`）。
    private var moreMenu: NSMenu?

    /// 展开整窗播放器之后还要做的事。主窗那份胶囊不用（整窗播放器就在同一扇窗里），
    /// 独立迷你窗那份由 `MiniPlayerWindowController` 接上：把主窗叫到前面来
    /// （Music 里点迷你窗的封面就是切回主窗）。
    var onExpand: (() -> Void)?

    private lazy var qualityPopover = makeQualityPopover()
    private lazy var volumePopover = makeVolumePopover()

    /// [HIG] 「减弱动态效果」：自绘的过渡系统不会替我们降级，得自己读这一位。
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - 生命周期

    init(appState: AppState) {
        self.appState = appState
        super.init(frame: NSRect(x: 0, y: 0, width: M.width, height: M.height))
        translatesAutoresizingMaskIntoConstraints = false
        buildViews()
        bind()
        updateTrack(player.currentTrack, force: true)
        updatePlayButton()
        updateShuffle()
        updateRepeat()
        updateVolume()
        updateInspectorButtons()
        updateSkipButtons()
        updateTime(player.currentTime)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 胶囊自己按内容定宽（700）；外面只给「≤ 内容列宽 − 2×margin」的上限，
    /// 窄窗口时由那条 required 不等式压住固有宽度。
    override var intrinsicContentSize: NSSize { NSSize(width: M.width, height: M.height) }

    override var isFlipped: Bool { false }

    // MARK: - 搭视图

    private func buildViews() {
        glass.style = .regular
        glass.contentView = content
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 传输键
        configure(shuffleButton, symbol: "shuffle", pointSize: M.shuffleIconSize, help: "随机播放") { [weak self] in
            self?.player.toggleShuffle()
        }
        configure(previousButton, symbol: "backward.fill", pointSize: M.skipIconSize, help: "上一首") { [weak self] in
            self?.player.previous()
        }
        configure(playButton, symbol: "play.fill", pointSize: M.playIconSize, help: "播放") { [weak self] in
            self?.player.togglePlayPause()
        }
        configure(nextButton, symbol: "forward.fill", pointSize: M.skipIconSize, help: "下一首") { [weak self] in
            self?.player.next()
        }
        configure(repeatButton, symbol: "repeat", pointSize: M.repeatIconSize, help: "循环") { [weak self] in
            self?.player.cycleRepeatMode()
        }
        [shuffleButton, previousButton, playButton, nextButton, repeatButton].forEach(content.addSubview)

        // 中央区块
        content.addSubview(centerView)
        centerContent.wantsLayer = true
        // [HIG/实现] 悬浮虚化要走 Core Image：NSView 的 backing layer 默认不吃
        // `layer.filters`，必须先开这一位。
        centerContent.layerUsesCoreImageFilters = true
        centerView.addSubview(centerContent)

        artworkView.onClick = { [weak self] in self?.expandNowPlaying() }
        centerContent.addSubview(artworkView)

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        subtitleField.font = .systemFont(ofSize: 13)
        subtitleField.textColor = .secondaryLabelColor
        for field in [titleField, subtitleField] {
            field.lineBreakMode = .byTruncatingTail
            field.usesSingleLineMode = true
            field.cell?.truncatesLastVisibleLine = true
            centerContent.addSubview(field)
        }

        configure(starButton, symbol: "star", pointSize: M.starIconSize, help: "收藏") { [weak self] in
            guard let self, let track = self.track else { return }
            self.library.toggleFavorite(track)
        }
        starButton.isHidden = true
        centerContent.addSubview(starButton)

        // Music.app 的 audioBadge：点开是**当前这首的音质**加一个设置入口，
        // 不是全屏播放器的入口——整条胶囊只有封面能展开播放器。
        configure(qualityButton, symbol: "waveform", pointSize: 15, help: "音质") { [weak self] in
            self?.toggleQualityPopover()
        }
        centerContent.addSubview(qualityButton)

        configure(moreButton, symbol: "ellipsis", pointSize: M.trailingIconSize, help: "更多") { [weak self] in
            self?.showMoreMenu()
        }
        // 旧版这颗是 `.foregroundStyle(.primary)`，不随「有没有歌」变灰。
        moreButton.glyphColor = .labelColor
        centerContent.addSubview(moreButton)

        // 空播放态：命中区只有正中这一个图标，悬浮时换成展开示意图标。
        configure(placeholderButton, symbol: "music.note", pointSize: 17, help: "展开播放器") { [weak self] in
            self?.expandNowPlaying()
        }
        placeholderButton.glyphColor = .secondaryLabelColor
        placeholderButton.onHover = { [weak self] hovering in
            guard let self else { return }
            self.placeholderButton.symbolName = hovering ? Self.expandSymbol : "music.note"
            self.placeholderButton.glyphColor = hovering ? .labelColor : .secondaryLabelColor
        }
        centerView.addSubview(placeholderButton)

        for field in [elapsedField, remainingField] {
            field.font = .monospacedDigitSystemFont(ofSize: M.timeLabelSize, weight: .regular)
            // [PX] 时间标签是纯白，不是 secondary。
            field.textColor = .white
            field.alphaValue = 0
            centerView.addSubview(field)
        }
        remainingField.alignment = .right

        progressView.onHoverChange = { [weak self] in self?.setScrubHovering($0) }
        progressView.onScrub = { [weak self] value in
            guard let self, self.player.duration > 0 else { return }
            self.player.seek(to: value * self.player.duration)
        }
        progressView.onNudge = { [weak self] delta in
            guard let self, self.player.duration > 0 else { return }
            let target = (self.player.currentTime + delta * self.player.duration)
            self.player.seek(to: min(max(target, 0), self.player.duration))
        }
        // 进度条压在中央内容之上（旧版是 `.overlay`，命中优先级同此）。
        centerView.addSubview(progressView)

        // 尾部键
        configure(lyricsButton, symbol: "quote.bubble", pointSize: M.trailingIconSize, help: "歌词") { [weak self] in
            self?.appState.toggleInspector(.lyrics)
        }
        configure(queueButton, symbol: "list.bullet", pointSize: M.trailingIconSize, help: "待播清单") { [weak self] in
            self?.appState.toggleInspector(.queue)
        }
        configure(volumeButton, symbol: "speaker.wave.3.fill", pointSize: M.volumeIconSize, help: "音量") { [weak self] in
            self?.toggleVolumePopover()
        }
        // Music 的 miniPlayer.airplayButton：待播清单与音量之间。系统的输出设备选择器，
        // 自绘按钮列不出 AirPlay 目标，所以这一颗直接用 AVKit 的。
        airPlayButton.isRoutePickerButtonBordered = false
        airPlayButton.toolTip = "AirPlay"
        airPlayButton.setAccessibilityLabel("AirPlay")
        [lyricsButton, queueButton, airPlayButton, volumeButton].forEach(content.addSubview)
    }

    private func configure(_ button: MiniIconButton, symbol: String, pointSize: CGFloat,
                           help: String, action: @escaping () -> Void) {
        button.symbolName = symbol
        button.pointSize = pointSize
        button.toolTip = help
        // [HIG] *Adopting Liquid Glass*：「always specify an accessibility label for each
        // icon」。不补这一句 VoiceOver 念的就是 "quote bubble"、"ellipsis" 这种东西。
        button.setAccessibilityLabel(help)
        button.onClick = action
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        // 胶囊：圆角取高度的一半。
        glass.cornerRadius = bounds.height / 2

        let spacing = groupSpacing
        let height = bounds.height
        var x = M.edgePadding
        for button in [shuffleButton, previousButton, playButton, nextButton, repeatButton] {
            let box = button === playButton ? M.playButtonSize : M.transportButtonSize
            button.frame = NSRect(x: x, y: (height - box) / 2, width: box, height: box)
            x += box + M.transportSpacing
        }

        let trailingX = bounds.width - M.edgePadding - M.trailingWidth
        var tx = trailingX
        for view in [lyricsButton, queueButton, airPlayButton, volumeButton] as [NSView] {
            view.frame = NSRect(x: tx, y: (height - M.trailingButtonSize) / 2,
                                width: M.trailingButtonSize, height: M.trailingButtonSize)
            tx += M.trailingButtonSize + M.trailingSpacing
        }

        let centerX = M.edgePadding + M.transportWidth + spacing
        centerView.frame = NSRect(x: centerX, y: 0,
                                  width: max(0, trailingX - spacing - centerX), height: height)
        layoutCenter()
    }

    /// 封面（有歌）与正中那颗音符（空闲）都是「展开整窗播放器」的入口。
    private func expandNowPlaying() {
        appState.showingNowPlaying = true
        onExpand?()
    }

    /// Music 空闲时把三组撑开（间距 9），有曲目就收到 1，中央块相应从 369 变 385。
    private var groupSpacing: CGFloat { track == nil ? M.idleGroupSpacing : M.groupSpacing }

    /// `NSTextField(labelWithString:)` 的 cell 左右**各留 2pt**，SwiftUI 的`Text` 没有。
    /// [实测 2026-09-05，独立探针] 同一串 13pt 系统字：`NSString.draw(at: .zero)` 的墨迹
    /// 从 1.0 起（字形自身的左边距），装进 label 后从 3.0 起，`fittingSize` 也正好比
    /// 字宽多 4。不把这 2pt 补回来，标题与副标题会整排右移 2，星形跟着一起偏。
    private static let labelInset: CGFloat = 2

    /// 纯字宽（不含上面那 2pt）。[AX] Music 的标题框 137.5 就是这个宽度
    /// （同字体实测 137.2），星形正贴在它的右沿。
    private func textWidth(_ field: NSTextField) -> CGFloat {
        field.attributedStringValue.size().width
    }

    private func layoutCenter() {
        let width = centerView.bounds.width
        let height = centerView.bounds.height
        let inset = M.centerContentInset

        centerContent.frame = centerView.bounds
        placeholderButton.frame = NSRect(x: (width - M.artworkSize) / 2,
                                         y: (height - M.artworkSize) / 2,
                                         width: M.artworkSize, height: M.artworkSize)

        artworkView.frame = NSRect(x: inset, y: (height - M.artworkSize) / 2,
                                   width: M.artworkSize, height: M.artworkSize)

        // 波形与「更多」两颗贴排，中间不留缝：[AX] Music `home.json` 里 audioBadge
        // 与 contextMenu 的左沿差正好一个 36（986.5 / 1022.5），「更多」右沿距区块右沿 8。
        let moreX = width - inset - M.trailingButtonSize
        let qualityX = moreX - M.trailingButtonSize
        let buttonY = (height - M.trailingButtonSize) / 2
        qualityButton.frame = NSRect(x: qualityX, y: buttonY,
                                     width: M.trailingButtonSize, height: M.trailingButtonSize)
        moreButton.frame = NSRect(x: moreX, y: buttonY,
                                  width: M.trailingButtonSize, height: M.trailingButtonSize)

        // 两行文字：行框相邻（centerTextSpacing = 0），整块以胶囊中线居中。
        // 行高取 NSTextField 自己报的（13pt 系统字 = 16），与 [AX] Music 的标题框 16 一致。
        let textX = inset + M.artworkSize + M.artworkToText
        let available = max(0, qualityX - textX)
        let lineHeight = titleField.intrinsicContentSize.height
        let blockHeight = lineHeight * 2 + M.centerTextSpacing
        let subtitleY = (height - blockHeight) / 2
        let titleY = subtitleY + lineHeight + M.centerTextSpacing

        // 星形贴在标题**字形**右沿（[AX] 标题 694.5+137.5 = 喜爱键的 832），
        // 所以宽度按字宽算，`labelInset` 只用来补 NSTextField 的内缩。
        let starWidth = starButton.isHidden ? 0 : M.starGap + M.starButtonSize
        let titleWidth = min(textWidth(titleField), max(0, available - starWidth))
        titleField.frame = NSRect(x: textX - Self.labelInset, y: titleY,
                                  width: titleWidth + Self.labelInset * 2, height: lineHeight)
        starButton.frame = NSRect(x: textX + titleWidth + M.starGap,
                                  y: titleY + (lineHeight - M.starButtonSize) / 2,
                                  width: M.starButtonSize, height: M.starButtonSize)
        subtitleField.frame = NSRect(x: textX - Self.labelInset, y: subtitleY,
                                     width: min(textWidth(subtitleField), available)
                                         + Self.labelInset * 2,
                                     height: lineHeight)

        // [AX] 命中区对 Music 的 AXSlider：中央区块**全宽** × 底部 18pt。
        progressView.frame = NSRect(x: 0, y: 0, width: width, height: M.scrubHitHeight)

        // 悬浮时两端浮出的时间标签：左贴左内缩、右贴右内缩，各占一半。
        let timeHeight = elapsedField.intrinsicContentSize.height
        let timeY = (height - timeHeight) / 2
        let timeWidth = max(0, (width - inset * 2) / 2)
        elapsedField.frame = NSRect(x: inset - Self.labelInset, y: timeY,
                                    width: timeWidth, height: timeHeight)
        remainingField.frame = NSRect(x: width - inset - timeWidth + Self.labelInset, y: timeY,
                                      width: timeWidth, height: timeHeight)
    }

    // MARK: - 悬浮

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let capsuleTracking { removeTrackingArea(capsuleTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        capsuleTracking = area
    }

    override func mouseEntered(with event: NSEvent) { setCapsuleHovering(true) }
    override func mouseExited(with event: NSEvent) { setCapsuleHovering(false) }

    private func setCapsuleHovering(_ hovering: Bool) {
        guard capsuleHovering != hovering else { return }
        capsuleHovering = hovering
        updateStar()
    }

    /// 进度条悬浮：中央内容淡到 8%、缩到 98%、虚化 2.5，两端浮出时间标签。
    private func setScrubHovering(_ hovering: Bool) {
        guard scrubHovering != hovering else { return }
        scrubHovering = hovering
        guard track != nil else { return }
        // [HIG] 减弱动态效果时不做中间帧：该到位的还是到位，只是瞬间切过去。
        let duration = reduceMotion ? 0 : M.scrubMorphDuration
        guard let layer = centerContent.layer else { return }

        animate(layer, keyPath: "opacity",
                to: hovering ? Float(M.scrubFadeOpacity) : 1, duration: duration)
        animate(layer, keyPath: "transform",
                to: NSValue(caTransform3D: scaleTransform(hovering ? M.scrubContentScale : 1, in: layer)),
                duration: duration)
        setBlur(radius: hovering ? M.scrubBlurRadius : 0, on: layer, duration: duration)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            elapsedField.animator().alphaValue = hovering ? 1 : 0
            remainingField.animator().alphaValue = hovering ? 1 : 0
        }
    }

    /// 以图层中心为锚点缩放。`anchorPoint` 万一不是 (0.5, 0.5)，用一段平移补回来。
    private func scaleTransform(_ scale: CGFloat, in layer: CALayer) -> CATransform3D {
        guard scale != 1 else { return CATransform3DIdentity }
        let dx = (0.5 - layer.anchorPoint.x) * layer.bounds.width
        let dy = (0.5 - layer.anchorPoint.y) * layer.bounds.height
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -dx, -dy, 0)
    }

    /// NSView 的 backing layer 关掉了隐式动画，属性动画一律显式加。
    private func animate(_ layer: CALayer, keyPath: String, to value: Any, duration: Double) {
        guard duration > 0 else {
            layer.removeAnimation(forKey: keyPath)
            layer.setValue(value, forKeyPath: keyPath)
            return
        }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = layer.presentation()?.value(forKeyPath: keyPath)
            ?? layer.value(forKeyPath: keyPath)
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.setValue(value, forKeyPath: keyPath)
        layer.add(animation, forKey: keyPath)
    }

    /// [PX] 淡出的同时还要虚化：Music 悬浮态标题的归一化边缘锐度只剩静止的 15%，
    /// 单纯降不透明度做不到（残影会是「清晰但淡」，一眼就不同）。
    private func setBlur(radius: CGFloat, on layer: CALayer, duration: Double) {
        if radius > 0, layer.filters == nil {
            guard let filter = CIFilter(name: "CIGaussianBlur") else { return }
            filter.name = "blur"
            filter.setValue(0, forKey: "inputRadius")
            layer.filters = [filter]
        }
        guard layer.filters != nil else { return }
        animate(layer, keyPath: "filters.blur.inputRadius", to: radius, duration: duration)
        if radius == 0 {
            let deadline = DispatchTime.now() + duration
            DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
                guard let self, !self.scrubHovering else { return }
                layer.filters = nil
            }
        }
    }

    // MARK: - 订阅（每个 sink 只刷它自己那几件）

    private func bind() {
        // 下面这些订阅都在闭包里回读属性（`clock` 那条例外：它把值当参数传下来）。
        // 从前这里一律先 `receive(on: .main)` 再读，不是为了换线程——`@Published` 是在
        // **willSet** 里发的，同步读回去拿到的是**旧值**（随机/循环/音量那几颗因此慢一拍、
        // 永远显示上一次的状态），异步回主队列那一跳正好落在赋值之后。
        // `Observations` 在值落定之后才发，回读就是新值，那一跳整类删掉了。
        //
        // 当前曲目：`currentIndex` 与`queue` 分别发一次，中间那一拍两者还不同步，
        // 同一跳之后直接读 `currentTrack` 才是两者都落定的值。
        observers.observeAny({ [player] in (player.currentIndex, player.queue) }) { [weak self] in
            guard let self else { return }
            self.updateTrack(self.player.currentTrack)

        }

        observers.observeAny({ [player] in (player.isPlaying, player.isLoading) }) { [weak self] in
            self?.updatePlayButton()
        }

        observers.observe({ [player] in player.isShuffled }) { [weak self] _ in
            self?.updateShuffle()
        }

        observers.observe({ [player] in player.repeatMode }) { [weak self] _ in
            self?.updateRepeat()
        }

        observers.observe({ [player] in player.volume }) { [weak self] _ in
            self?.updateVolume()
        }

        observers.observe({ [player] in player.duration }) { [weak self] _ in
            guard let self else { return }
            self.updateTime(self.player.currentTime)

        }

        // 进度 10 Hz 一跳，只让进度条与两枚时间标签跟着跳（见 `PlaybackClock`）。
        observers.observe({ [clock = player.clock] in clock.time }) { [weak self] time in
            self?.updateTime(time)
        }

        // 高亮 = 「主窗面板开着」且「开的正是这一档」。两位分开之后这两颗键才与
        // 迷你窗抽屉的档位说同一件事（reactive-ui-review §2.1「多份真相」）。
        observers.observeAny({ [appState] in (appState.inspectorMode, appState.isInspectorOpen) }) { [weak self] in
            self?.updateInspectorButtons()
        }

        observers.observe({ [library] in library.favoriteTracks }) { [weak self] _ in
            self?.updateStar()
        }
    }

    // MARK: - 各件的刷新

    private func updateTrack(_ newTrack: Track?, force: Bool = false) {
        guard force || newTrack != track else { return }
        let hadTrack = track != nil
        track = newTrack

        if let newTrack {
            artworkView.setArtwork(url: newTrack.artworkURL)
            titleField.stringValue = newTrack.title
            subtitleField.stringValue = newTrack.albumName.isEmpty
                ? newTrack.artistName
                : "\(newTrack.artistName) — \(newTrack.albumName)"
        }
        centerContent.isHidden = newTrack == nil
        progressView.isHidden = newTrack == nil
        placeholderButton.isHidden = newTrack != nil
        if newTrack == nil, scrubHovering { setScrubHovering(false) }

        // 无曲目时**只禁传输键**并变灰（旧版 `Color.secondary`）。
        // 尾部那四颗一律照常可点：歌词/待播清单开的是面板（队列空着也要能打开看一眼，
        // 面板自己有「待播清单为空」那一档空态），音量改的是播放器音量、AirPlay 选的是
        // 输出设备——都与「现在有没有一首歌」无关。早先把 `queueButton` / `volumeButton`
        // 混进传输键那一组是照抄了「跟着有没有歌走」的写法，不对。
        // （AirPlay 那颗是 `AVRoutePickerView`，Amber 从来没禁过它；空闲时偏灰是这个系统
        // 控件自己的静息画法，不是禁用态。）
        for button in [shuffleButton, previousButton, playButton, nextButton, repeatButton] {
            button.isEnabled = newTrack != nil
        }
        updateShuffle()
        updateRepeat()
        updateVolume()
        updateInspectorButtons()
        updateSkipButtons()
        apply(qualityButton, active: showingQuality)
        updatePlayButton()
        updateStar()
        updateTime(player.currentTime)

        if force || hadTrack != (newTrack != nil) { needsLayout = true } else { layoutCenter() }
    }

    private func updatePlayButton() {
        if player.isLoading {
            playButton.symbolName = "hourglass"
        } else {
            playButton.symbolName = player.isPlaying ? "pause.fill" : "play.fill"
        }
        let help = player.isPlaying ? "暂停" : "播放"
        playButton.toolTip = help
        playButton.setAccessibilityLabel(help)
        playButton.glyphColor = tint(level: MusicGrays.primary)
    }

    private func updateShuffle() {
        apply(shuffleButton, active: player.isShuffled, level: MusicGrays.tertiary, dot: true)
    }

    private func updateRepeat() {
        repeatButton.symbolName = player.repeatMode == .one ? "repeat.1" : "repeat"
        apply(repeatButton, active: player.repeatMode != .off, level: MusicGrays.tertiary, dot: true)
    }

    private func updateVolume() {
        volumeButton.symbolName = VolumeGlyph.symbol(for: player.volume)
        apply(volumeButton, active: showingVolume)
        volumeBar.value = player.volume
    }

    private func updateInspectorButtons() {
        let open = appState.isInspectorOpen
        apply(lyricsButton, active: open && appState.inspectorMode == .lyrics)
        apply(queueButton, active: open && appState.inspectorMode == .queue)
    }

    /// 上一首/下一首没有激活态，只随「有没有歌」换档。
    private func updateSkipButtons() {
        previousButton.glyphColor = tint(level: MusicGrays.primary)
        nextButton.glyphColor = tint(level: MusicGrays.primary)
    }

    private func updateStar() {
        guard let track else {
            starButton.isHidden = true
            return
        }
        // Music：胶囊悬浮时歌名右侧才浮出这一颗。
        let wasHidden = starButton.isHidden
        starButton.isHidden = !capsuleHovering
        let favorite = library.isFavorite(track)
        starButton.symbolName = favorite ? "star.fill" : "star"
        starButton.glyphColor = .secondaryLabelColor
        let help = favorite ? "取消收藏" : "收藏"
        starButton.toolTip = help
        // [HIG] 不补就念 "star" / "star fill"，收藏与否得靠听图形名猜。
        starButton.setAccessibilityLabel(help)
        if wasHidden != starButton.isHidden { layoutCenter() }
    }

    private func updateTime(_ time: TimeInterval) {
        let duration = player.duration
        let value = duration > 0 ? min(time / duration, 1) : 0
        progressView.progress = value
        progressView.setAccessibilityValue(duration > 0 ? "\(time.mmss) / \(duration.mmss)" : "--:--")
        guard scrubHovering else { return }
        elapsedField.stringValue = duration > 0 ? time.mmss : "--:--"
        let remaining = duration - time
        remainingField.stringValue = (duration > 0 && remaining >= 0) ? "-" + remaining.mmss : "--:--"
    }

    /// [PX] Music 的传输播放键是 systemPrimary（0.85），未激活的随机/循环是
    /// systemTertiary（0.25），尾部四键才是纯白；无曲目时整排是 secondary。
    private func tint(level: CGFloat = 1) -> NSColor {
        track == nil ? .secondaryLabelColor : NSColor(white: 1, alpha: level)
    }

    /// dot 为 true 时，开启态在字形下方补一颗圆点：[资源] Music.app 的 Assets.car 里
    /// 随机/循环用的是 `shuffle.and.dot` / `repeat.and.dot` / `repeat1.and.dot`
    /// 三个自定义符号，开启不只是变色，字形本身就多一颗点。
    private func apply(_ button: MiniIconButton, active: Bool,
                       level: CGFloat = 1, dot: Bool = false) {
        button.glyphColor = active ? .amberSidebarAccent : tint(level: level)
        button.showsDot = dot && active
    }

    // MARK: - 气泡与菜单

    private func toggleQualityPopover() {
        if qualityPopover.isShown {
            qualityPopover.close()
        } else {
            showingQuality = true
            apply(qualityButton, active: true)
            qualityPopover.show(relativeTo: qualityButton.bounds, of: qualityButton,
                                preferredEdge: .maxY)
        }
    }

    private func toggleVolumePopover() {
        if volumePopover.isShown {
            volumePopover.close()
        } else {
            showingVolume = true
            updateVolume()
            volumePopover.show(relativeTo: volumeButton.bounds, of: volumeButton,
                               preferredEdge: .maxY)
        }
    }

    private func makeQualityPopover() -> NSPopover {
        let popover = NSPopover()
        // 音质气泡是叶子，留 SwiftUI（整窗播放器的「无损」徽标点开的是同一枚）。
        let controller = appState.hostingController { AudioQualityPopover() }
        // 宿主页那边用 `sizingOptions = []`（尺寸由 AppKit 槽说了算）；气泡正相反，
        // 尺寸得由 SwiftUI 内容报上来。
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        return popover
    }

    private func makeVolumePopover() -> NSPopover {
        // Music 的音量条是自绘细条，不是 NSSlider；照旧版 `AmberTrackBar` 的样子搭一条。
        let container = NSView()
        let low = NSImageView()
        let high = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: NSFont.smallSystemFontSize,
                                                 weight: .regular)
        low.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        high.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        for view in [low, high] {
            view.contentTintColor = .secondaryLabelColor
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        volumeBar.translatesAutoresizingMaskIntoConstraints = false
        volumeBar.onScrub = { [weak self] value in self?.player.volume = value }
        volumeBar.value = player.volume
        container.addSubview(volumeBar)
        NSLayoutConstraint.activate([
            low.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            volumeBar.leadingAnchor.constraint(equalTo: low.trailingAnchor, constant: 8),
            high.leadingAnchor.constraint(equalTo: volumeBar.trailingAnchor, constant: 8),
            container.trailingAnchor.constraint(equalTo: high.trailingAnchor, constant: 14),
            volumeBar.widthAnchor.constraint(equalToConstant: 120),
            volumeBar.heightAnchor.constraint(equalToConstant: MiniVolumeBar.hitHeight),
            volumeBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            container.bottomAnchor.constraint(equalTo: volumeBar.bottomAnchor, constant: 12),
            low.centerYAnchor.constraint(equalTo: volumeBar.centerYAnchor),
            high.centerYAnchor.constraint(equalTo: volumeBar.centerYAnchor),
        ])
        let controller = NSViewController()
        controller.view = container
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = container.fittingSize
        popover.behavior = .transient
        popover.delegate = self
        return popover
    }

    /// 与整窗播放器、迷你窗同一份 •••（`PlayerMoreMenu` 那张表）。
    /// 从前这里只有一条「喜欢」。
    ///
    /// **向上弹**：胶囊贴着窗口底边，菜单往下没地方去。
    ///
    /// `popUp(positioning:at:in:)` 传 nil 项时把菜单的**左上角**摆在`at`，菜单向下长。
    /// 坑在坐标系：**`NSButton.isFlipped` 是`true`**（实测，不是「AppKit 视图默认不翻转」
    /// 那条通则），所以按钮坐标里 `(0,0)` 是**左上角**、y 向下增。要让菜单**底边**贴住
    /// 按钮顶边，就得往上减一整个菜单高。
    ///
    /// [实测 2026-09-09] 一颗贴窗底的 `NSButton` + 8 项菜单，量菜单窗的屏幕矩形
    /// （「菜单底边 − 按钮顶边」，0 = 贴住）：`(0, minY)` +197、`(0, maxY)` +221、
    /// `(0, maxY + size.height)` **+423**（反而更往下）、`positioning: items.last` +53、
    /// **`(0, minY − size.height)` −5** ← 取这个；那 5pt 是菜单窗自带的阴影内缩，视觉上正好贴住。
    /// 读 `menu.size` 会顺手把菜单排一遍，拿到的是真实高度。
    private func showMoreMenu() {
        guard let menu = makeMoreMenu() else { return }
        // 菜单存成属性：动作挂在菜单项自己身上（`ClosureMenuItem`），
        // 弹出期间不留个强引用，收起后再走回来的那一下就没人接着了。
        moreMenu = menu
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: moreButton.bounds.minY - menu.size.height),
                   in: moreButton)
    }

    /// 实机自证的口子：菜单要点出来才看得见，鼠标又驱动不了（见 AGENTS）——
    /// 让 `-dumpmenus` 走这同一条路把当场建出来的那份写下来。
    func makeMoreMenu() -> NSMenu? {
        guard let track else { return nil }
        return PlayerMoreMenu.makeMenu(PlayerMoreMenu.entries(
            track: track, appState: appState, library: library, downloads: appState.downloads))
    }
}

// MARK: - 气泡关闭时把按钮的激活态收回

extension MiniPlayerView: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        if popover === qualityPopover {
            showingQuality = false
            apply(qualityButton, active: false)
        } else if popover === volumePopover {
            showingVolume = false
            updateVolume()
        }
    }
}

// MARK: - 时间标签

/// 悬浮才淡入的已播/剩余时间。`alphaValue = 0` 不影响`hitTest`（只有`isHidden` 才影响），
/// 而这两枚的 frame 横跨中央块两端、正压在波形/更多/星形键的中段，所以干脆不接任何点击。
private final class MiniTimeLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - 图标键

/// 无边框图标键。字号是视觉大小，frame 是 [AX] 实测的命中盒——两者独立，
/// [TYPE] `MiniPlayerTransportSpecs` 里边键那个字体就是**以图标为参数**的函数，
/// Music 自己也逐键分档。
private final class MiniIconButton: NSButton {

    var onClick: (() -> Void)?
    /// 需要悬浮换字形的那一颗（空播放态的中央图标）才挂 tracking area。
    var onHover: ((Bool) -> Void)? { didSet { updateTrackingAreas() } }

    var symbolName = "" { didSet { applySymbol() } }
    var pointSize: CGFloat = 13 { didSet { applySymbol() } }
    var glyphColor: NSColor = .white {
        didSet {
            contentTintColor = glyphColor
            if showsDot { needsDisplay = true }
        }
    }
    /// 开启态字形下方那颗圆点
    var showsDot = false { didSet { needsDisplay = true } }

    private var hoverArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .shadowlessSquare
        imagePosition = .imageOnly
        // 字号已经是 [PX] 反推出来的视觉大小，命中盒比它大；默认的
        // `.scaleProportionallyDown` 会在盒子偏小时偷偷把字形缩掉。
        imageScaling = .scaleNone
        title = ""
        target = self
        action = #selector(clicked)
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
        super.draw(dirtyRect)
        guard showsDot else { return }
        let size = MusicMetrics.MiniPlayer.activeDotSize
        // 旧版是 `Circle().offset(y: 8)`（SwiftUI 的 y 向下），这里坐标向上，取负。
        let rect = NSRect(x: bounds.midX - size / 2,
                          y: bounds.midY - MusicMetrics.MiniPlayer.activeDotOffset - size / 2,
                          width: size, height: size)
        glyphColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea); self.hoverArea = nil }
        guard onHover != nil else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

// MARK: - 封面

/// 展开全屏播放器的唯一入口（对齐 Music.app）：有歌在播时挂在封面上，
/// 悬浮封面压黑 45% 并浮现展开图标；标题与「歌手 — 专辑」不再是按钮。
private final class MiniArtworkView: NSView {

    var onClick: (() -> Void)?

    /// 封面走 `CALayer`：`NSImageView` 只有 aspect-fit，而旧版`ArtworkView` 是
    /// `scaledToFill` + 裁切；`contentsGravity = .resizeAspectFill` 才是同一件事
    /// （比例不是 1:1 的封面按高度收、宽度溢出的部分由圆角裁掉）。
    private let artwork = CALayer()
    private let placeholder = CAGradientLayer()
    private let placeholderGlyph = NSImageView()
    private let dim = NSView()
    private let expandGlyph = NSImageView()
    private var hoverArea: NSTrackingArea?
    private var loadTask: Task<Void, Never>?
    private var requestedURL: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = MusicMetrics.MiniPlayer.artworkCornerRadius
        layer?.masksToBounds = true
        placeholder.startPoint = CGPoint(x: 0, y: 1)
        placeholder.endPoint = CGPoint(x: 1, y: 0)
        ArtworkPlaceholder.fill(placeholder, for: self)
        layer?.addSublayer(placeholder)
        artwork.contentsGravity = .resizeAspectFill
        artwork.masksToBounds = true
        artwork.isHidden = true
        layer?.addSublayer(artwork)

        placeholderGlyph.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        placeholderGlyph.contentTintColor = .amberArtworkPlaceholderGlyph
        addSubview(placeholderGlyph)

        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        dim.isHidden = true
        addSubview(dim)

        expandGlyph.image = NSImage(systemSymbolName: MiniPlayerView.expandSymbol,
                                    accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        expandGlyph.contentTintColor = .white
        expandGlyph.isHidden = true
        addSubview(expandGlyph)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        // [HIG] 不补的话 VoiceOver 念的是封面图，完全看不出这是展开播放器的入口。
        setAccessibilityLabel("展开播放器")
        toolTip = "展开播放器"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholder.frame = bounds
        artwork.frame = bounds
        CATransaction.commit()
        dim.frame = bounds
        placeholderGlyph.frame = bounds
        expandGlyph.frame = bounds
    }

    /// 灰底是动态色，`cgColor` 解析一次就定死了，浅深切换要重铺。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ArtworkPlaceholder.fill(placeholder, for: self)
    }

    func setArtwork(url: String?) {
        let request = ArtworkSize.url(url, points: ArtworkSize.row)
        // 「没有封面」这一路每次都走到底，别拿 `nil == nil` 当「没变」——那样上一首的封面
        // 会留在层上（同 `CatalogArtworkView.setArtwork`）。
        guard request != requestedURL || request == nil else { return }
        requestedURL = request
        loadTask?.cancel()
        loadTask = nil
        // 内存里已经有就当场贴，**不先置空**：哪怕图早就在 `NSCache` 里，
        // 「先 `contents = nil` → 下一轮微任务回填」也必定让胶囊白一帧，
        // 换歌时那下闪动就是它（`ImageCache.memoryCachedImage` 的头注写的正是这条路）。
        if let cached = ImageCache.shared.memoryCachedImage(for: request) {
            show(cached)
            return
        }
        // 图没到之前露的是渐变占位（与旧版 `ArtworkView` 同形）。
        artwork.contents = nil
        artwork.isHidden = true
        placeholderGlyph.isHidden = false
        loadTask = Task { [weak self] in
            let image = await ImageCache.shared.image(for: request)
            guard let self, !Task.isCancelled, self.requestedURL == request,
                  let image else { return }
            self.show(image)
        }
    }

    /// 贴 CGImage 而不是 NSImage，理由同 `CatalogArtworkView.showArtwork`。
    private func show(_ image: NSImage) {
        let contents: Any
        if let cgImage = image.amberCGImage {
            contents = cgImage
        } else {
            contents = image
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artwork.contents = contents
        artwork.isHidden = false
        CATransaction.commit()
        placeholderGlyph.isHidden = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ hovering: Bool) {
        guard dim.isHidden == hovering else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            dim.isHidden = !hovering
            expandGlyph.isHidden = !hovering
            dim.alphaValue = 1
            expandGlyph.alphaValue = 1
            return
        }
        if hovering {
            dim.alphaValue = 0
            expandGlyph.alphaValue = 0
            dim.isHidden = false
            expandGlyph.isHidden = false
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dim.animator().alphaValue = hovering ? 1 : 0
            expandGlyph.animator().alphaValue = hovering ? 1 : 0
        } completionHandler: { [weak self] in
            // 完成回调的类型是 `@Sendable`，而这里动的是主线程隔离的视图。
            // `NSAnimationContext` 明文保证回调在主线程，所以用 `assumeIsolated` 接回来。
            MainActor.assumeIsolated {
                guard let self, !hovering else { return }
                self.dim.isHidden = true
                self.expandGlyph.isHidden = true
            }
        }
    }

    /// 与 SwiftUI 的 `Button` 同：按下不触发，抬手仍在盒内才算一次点击。
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }

    override func mouseDown(with event: NSEvent) {}

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

// MARK: - 进度条

/// 迷你播放器的进度条：两层 `CALayer`（轨道白 25% / 已播白 85%），
/// 命中区是中央区块全宽 × 18（[AX] 对 Music 的 AXSlider）。
/// 自绘轨道继承 `NSControl` 的理由见 `NowPlayingVolumeBar`（不然拖它会把窗口拖走）。
private final class MiniProgressView: NSControl {

    private typealias M = MusicMetrics.MiniPlayer

    var onScrub: ((Double) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    /// VoiceOver 的增减：按总时长的 ±5% 走。
    var onNudge: ((Double) -> Void)?

    var progress: Double = 0 {
        didSet {
            guard dragValue == nil, progress != oldValue else { return }
            layoutBars(animated: false)
        }
    }

    private var hovering = false
    private var dragValue: Double?
    private let track = CALayer()
    private let played = CALayer()
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // [Web] 轨道 systemTertiary-onDark、已播 systemPrimary-onDark
        track.backgroundColor = NSColor(white: 1, alpha: MusicGrays.tertiary).cgColor
        played.backgroundColor = NSColor(white: 1, alpha: MusicGrays.primary).cgColor
        layer?.addSublayer(track)
        layer?.addSublayer(played)

        // [HIG] 命中区尺寸对上了 Music 的 AXSlider，角色也要对上：自绘的轨道在 AX 树里
        // 什么都不是，旧 SwiftUI 版靠 `accessibilityRepresentation` 造替身，AppKit 直接报角色。
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("播放进度")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        layoutBars(animated: false)
    }

    /// 静止 2pt 距底 4.5；悬浮长高为 8pt 距底 9，宽度不变。
    private func layoutBars(animated: Bool) {
        let height = hovering ? M.progressHoverHeight : M.progressHeight
        let bottom = hovering ? M.progressHoverBottom : M.progressBottom
        let inset = M.centerContentInset
        let width = max(0, bounds.width - inset * 2)
        let value = min(max(dragValue ?? progress, 0), 1)

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(M.scrubMorphDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        }
        track.frame = NSRect(x: inset, y: bottom, width: width, height: height)
        track.cornerRadius = height / 2
        played.frame = NSRect(x: inset, y: bottom, width: width * value, height: height)
        played.cornerRadius = height / 2
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        layoutBars(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        onHoverChange?(value)
    }

    // 旧版是 `DragGesture(minimumDistance: 0)`：按下即跟手，松手才 seek。
    override func mouseDown(with event: NSEvent) {
        dragValue = value(at: event)
        layoutBars(animated: false)
    }

    override func mouseDragged(with event: NSEvent) {
        dragValue = value(at: event)
        layoutBars(animated: false)
    }

    override func mouseUp(with event: NSEvent) {
        let target = value(at: event)
        // 先 seek 再松开 `dragValue`：`seek` 会同步把进度推到目标点，
        // 反过来就是先把条摆回旧 `progress`、再跳过去。
        onScrub?(target)
        dragValue = nil
        layoutBars(animated: false)
    }

    private func value(at event: NSEvent) -> Double {
        let point = convert(event.locationInWindow, from: nil)
        let inset = M.centerContentInset
        let width = max(1, bounds.width - inset * 2)
        return min(max((point.x - inset) / width, 0), 1)
    }

    override func accessibilityPerformIncrement() -> Bool {
        onNudge?(0.05)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onNudge?(-0.05)
        return true
    }
}

// MARK: - 音量条

/// 音量气泡里那条细轨。Music 的音量条是自绘细条（不是 `NSSlider`），
/// 形制照旧版 `AmberTrackBar`：5pt 轨道 + 常驻白色圆钮，命中高度 11。
/// 自绘轨道继承 `NSControl` 的理由见 `NowPlayingVolumeBar`（不然拖它会把窗口拖走）。
private final class MiniVolumeBar: NSControl {

    static let barHeight: CGFloat = 5
    static let hitHeight: CGFloat = barHeight + 6
    private static let knobSize: CGFloat = barHeight + 5

    var onScrub: ((Double) -> Void)?
    var value: Double = 1 {
        didSet {
            guard dragValue == nil, value != oldValue else { return }
            layoutBars()
        }
    }

    private var dragValue: Double?
    private let track = CALayer()
    private let played = CALayer()
    private let knob = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        track.backgroundColor = NSColor(white: 1, alpha: MusicGrays.tertiary).cgColor
        played.backgroundColor = NSColor(white: 1, alpha: MusicGrays.primary).cgColor
        knob.backgroundColor = NSColor.white.cgColor
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 2
        knob.shadowOffset = CGSize(width: 0, height: -1)
        [track, played, knob].forEach { layer?.addSublayer($0) }

        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("音量")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        layoutBars()
    }

    private func layoutBars() {
        let current = min(max(dragValue ?? value, 0), 1)
        let height = Self.barHeight
        let y = (bounds.height - height) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
        track.cornerRadius = height / 2
        played.frame = NSRect(x: 0, y: y, width: bounds.width * current, height: height)
        played.cornerRadius = height / 2
        let knobSize = Self.knobSize
        let knobX = min(max(bounds.width * current - knobSize / 2, 0), bounds.width - knobSize)
        knob.frame = NSRect(x: knobX, y: (bounds.height - knobSize) / 2,
                            width: knobSize, height: knobSize)
        knob.cornerRadius = knobSize / 2
        // 圆钮带阴影，frame 在 `mouseDragged` 里逐事件重排：不给 `shadowPath`，
        // 合成器每一帧都要照层的 alpha 现算一次离屏（同 `CatalogPlayButton.layout`）。
        // 走 `NSBezierPath.cgPath` 而不是 `CGPath(ellipseIn:transform:)`：后者的
        // `transform` 是裸指针形参，整条声明被判为不安全；这条是纯安全 API，
        // 按三档的第一档「能改成安全代码的先改，不标注」。
        knob.shadowPath = NSBezierPath(ovalIn: knob.bounds).cgPath
        CATransaction.commit()
        setAccessibilityValue("\(Int((current * 100).rounded()))%")
    }

    // 音量是 continuous：拖动过程中就一路回调。
    override func mouseDown(with event: NSEvent) { scrub(event) }
    override func mouseDragged(with event: NSEvent) { scrub(event) }
    override func mouseUp(with event: NSEvent) {
        scrub(event)
        dragValue = nil
    }

    private func scrub(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let target = min(max(point.x / max(bounds.width, 1), 0), 1)
        dragValue = target
        layoutBars()
        onScrub?(target)
    }

    override func accessibilityPerformIncrement() -> Bool {
        onScrub?(min(value + 0.05, 1))
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onScrub?(max(value - 0.05, 0))
        return true
    }
}

// MARK: - AirPlay

/// 系统输出设备选择器（Music 用的是同一颗）。`AVRoutePickerView` 的固有尺寸比 Music
/// 的按钮大一圈（实测画到 41.5×38），会把自己撑出给定的盒子、压掉与相邻两键的间距，
/// 所以把固有尺寸钉成 `trailingButtonSize` 见方——与那份已删的 SwiftUI 壳同一手法。
private final class MiniRoutePickerView: AVRoutePickerView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: MusicMetrics.MiniPlayer.trailingButtonSize,
               height: MusicMetrics.MiniPlayer.trailingButtonSize)
    }
}
