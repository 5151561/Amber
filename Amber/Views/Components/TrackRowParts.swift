import AppKit
import SwiftUI

// MARK: - 曲目行的公共件（阶段 4 批 A）

// 这一批把 `TrackRow.swift`（SwiftUI）原样搬成`NSTableRowView` + 三种形态的格子。
// 原则同阶段 3：计划 §2 铁律 5「换骨架，像素一个不改」——字号 / 间距 / 圆角 / 浓度
// 全部照搬 SwiftUI 版（数各自带 [AX]/[PX]/[实测] 出处，都在 `MusicMetrics.TrackRow`
// 与 `MusicMetrics.Rating` 里），颜色走系统语义色（SwiftUI 的`.primary`/`.secondary`
// 就是 `labelColor`/`secondaryLabelColor`），悬浮态由行视图自己持有（铁律 3），
// 不新增 Representable（铁律 1），滚动容器里的格子不挂 `NSHostingView`（铁律 2）。

@MainActor
enum TrackRowKit {

    /// 品牌红。`Color.amberKey` 本身就是一份动态`NSColor`，包回去仍随外观解析。
    static let key = NSColor(Color.amberKey)

    static func symbol(_ name: String, size: CGFloat,
                       weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    /// 行里的普通文字。与目录卡同一份工厂：`CatalogLabel` 不参与命中测试，
    /// 点击照样落到底下的行（选中）或按钮上。
    static func label(size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> CatalogLabel {
        CatalogCardKit.label(size: size, weight: weight, color: color)
    }

    /// 序号与时长这类等宽数字（SwiftUI 的 `.monospacedDigit()`）。
    static func digitsLabel(size: CGFloat, color: NSColor = .secondaryLabelColor,
                            alignment: NSTextAlignment) -> CatalogLabel {
        let field = label(size: size, color: color)
        field.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        field.alignment = alignment
        return field
    }

    /// 把左对齐标签摆到「墨迹左沿 = `inkLeading`」的位置。
    ///
    /// `NSTextField(labelWithString:)` 的 cell 左右**各留 2pt**，SwiftUI 的`Text` 没有
    /// （`CatalogCardKit.labelInset` 同一条），手排 frame 时要把这 2pt 补回来。
    static func layout(_ field: NSTextField, inkLeading: CGFloat, width: CGFloat,
                       centerY: CGFloat) {
        let height = field.intrinsicContentSize.height
        field.frame = NSRect(x: inkLeading - CatalogCardKit.labelInset,
                             y: (centerY - height / 2).rounded(.toNearestOrEven),
                             width: max(0, width + CatalogCardKit.labelInset * 2),
                             height: height)
    }

    /// 右对齐标签：墨迹右沿落在 `inkTrailing`。
    static func layout(_ field: NSTextField, inkTrailing: CGFloat, width: CGFloat,
                       centerY: CGFloat) {
        let height = field.intrinsicContentSize.height
        field.frame = NSRect(x: inkTrailing + CatalogCardKit.labelInset - width
                                - CatalogCardKit.labelInset * 2,
                             y: (centerY - height / 2).rounded(.toNearestOrEven),
                             width: max(0, width + CatalogCardKit.labelInset * 2),
                             height: height)
    }
}

// MARK: - 不接点击的图标

/// `NSImageView` 是`NSControl`，会把落在它身上的点击吃掉。压在按钮上的纯装饰图标
/// （封面上的播放三角、评分星）一律不参与命中测试，让点击落到底下的按钮。
final class TrackRowGlyphView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - 小图标键

/// 心水星、入库键、序号位的播放键：一枚 SF Symbol，命中区由外面给的 frame 决定。
///
/// `alphaValue = 0` 的视图仍然参与`hitTest`（只有`isHidden` 才不参与），所以
/// 「悬浮才显形」的键收起时一定要 `isHidden`（先例：`CatalogPlayButton.setVisible`），
/// 否则未悬浮的行上会有一块点不动的死区。
final class TrackRowGlyphButton: NSButton {

    var onClick: (() -> Void)?

    private let pointSize: CGFloat
    private let weight: NSFont.Weight

    /// `tint` 不给就是品牌红。默认值写成 nil 再在里面取：默认参数的表达式在
    /// **非隔离**上下文里求值，直接写 `TrackRowKit.key` 会撞 Swift 6 的并发检查。
    init(symbol: String, pointSize: CGFloat, weight: NSFont.Weight = .regular,
         tint: NSColor? = nil) {
        self.pointSize = pointSize
        self.weight = weight
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .shadowlessSquare
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        image = TrackRowKit.symbol(symbol, size: pointSize, weight: weight)
        contentTintColor = tint ?? TrackRowKit.key
        target = self
        action = #selector(clicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clicked() { onClick?() }

    func setSymbol(_ name: String) {
        image = TrackRowKit.symbol(name, size: pointSize, weight: weight)
    }

    /// 悬浮才显形的键：`isHidden` 与`alphaValue` 一起动，不然会留下点不动的死区。
    func setVisible(_ visible: Bool) {
        isHidden = !visible
        alphaValue = visible ? 1 : 0
        setAccessibilityHidden(!visible)
    }
}

// MARK: - 可点的文字

/// 歌单行的艺人 / 专辑：点了跳转（SwiftUI 版是 `NavigationLink`）。
///
/// 文字本体仍是 `CatalogLabel`（不接点击），外面套一层`NSButton` 收点击——
/// 表格里只有 `NSControl` 才拿得到自己的`mouseDown`，普通视图的点击会被
/// `NSTableView` 的选中逻辑吞掉。没有落点时整块不接点击，交回行去选中。
final class TrackRowLinkButton: NSButton {

    let label: CatalogLabel
    var onClick: (() -> Void)?
    /// 有落点才可点；没有就退成一块普通文字。
    var isLink = false

    init(size: CGFloat, color: NSColor) {
        label = TrackRowKit.label(size: size, color: color)
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .shadowlessSquare
        title = ""
        imagePosition = .imageOnly
        addSubview(label)
        target = self
        action = #selector(clicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clicked() { onClick?() }

    override func hitTest(_ point: NSPoint) -> NSView? { isLink ? super.hitTest(point) : nil }

    override func layout() {
        super.layout()
        TrackRowKit.layout(label, inkLeading: 0, width: bounds.width, centerY: bounds.midY)
    }
}

// MARK: - 星级

/// 音轨行的五颗评分星（`RatingStars` 的 AppKit 版，`emptyFilled: true` 那一档）。
///
/// [PX] 未评分的星是**去饱和的品牌红实心**（`Rating.emptyOpacity` = 0.25），不是灰色也不是空心。
/// 星形之间是负间距（`Rating.rowStarSpacing` = −1.3），命中区按各自的字形盒算，
/// 重叠处归后面那颗（与 SwiftUI 的 z 序一致）。
final class TrackRowRatingView: NSButton {

    private typealias R = MusicMetrics.Rating

    var onRate: ((Int) -> Void)?

    private var stars: [TrackRowGlyphView] = []
    private var rating = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .shadowlessSquare
        title = ""
        imagePosition = .imageOnly
        let image = TrackRowKit.symbol("star.fill", size: R.rowStarSize)
        for index in 0..<5 {
            let view = TrackRowGlyphView()
            view.image = image
            view.imageScaling = .scaleNone
            view.setAccessibilityLabel("评 \(index + 1) 星")
            addSubview(view)
            stars.append(view)
        }
        setAccessibilityRole(.slider)
        // 标签说「这是什么」、值说「现在是多少」，与另外四条自绘滑块同解
        // （`MiniPlayerView:1093` 是「播放进度」+ mm:ss）。从前这里把值写进了标签、
        // 值一直是空的：报着 `.slider` 却没有 value，VoiceOver 念不出当前档位。
        setAccessibilityLabel("评分")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setRating(_ value: Int) {
        rating = value
        for (index, star) in stars.enumerated() {
            star.contentTintColor = index < value
                ? TrackRowKit.key
                : TrackRowKit.key.withAlphaComponent(R.emptyOpacity)
        }
        // 值写在这里而不是 `init`：同一只视图会被表格复用、评分也能当场改
        //（右键菜单、⌘1…⌘5），只在建视图那一次写等于永远停在建的那一刻。
        let description = value == 0 ? "未评分" : "\(value) 星"
        setAccessibilityValue(description)
        toolTip = description
    }

    /// `.slider` 这个 role 许诺了「能调」，所以把 VoiceOver 的 ⌃⌥→ / ⌃⌥← 接上，
    /// 落点与鼠标点星同一条（`onRate`）。0 星 = 未评分，是合法档位，所以下界是 0。
    override func accessibilityPerformIncrement() -> Bool {
        guard rating < 5 else { return false }
        onRate?(rating + 1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard rating > 0 else { return false }
        onRate?(rating - 1)
        return true
    }

    /// 五颗星占的总宽（左对齐排在 `Rating.rowWidth` 的槽里）。
    var starsWidth: CGFloat {
        guard let size = stars.first?.image?.size else { return 0 }
        return size.width * 5 + R.rowStarSpacing * 4
    }

    override func layout() {
        super.layout()
        guard let size = stars.first?.image?.size else { return }
        var x: CGFloat = 0
        for star in stars {
            star.frame = NSRect(x: x, y: (bounds.height - size.height) / 2,
                                width: size.width, height: size.height)
            x += size.width + R.rowStarSpacing
        }
    }

    /// 表格里只有控件自己收得到 `mouseDown`；这里不往下传，避免顺手把行也选了
    /// （SwiftUI 版的 `onTapGesture` 同样只落在星上）。
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (index, star) in stars.enumerated().reversed() where star.frame.contains(point) {
            onRate?(index + 1)
            return
        }
    }
}

// MARK: - 正在播放的四条电平

/// `NowPlayingLevelsView`（SwiftUI）的 CALayer 版，复刻`TrackNowPlayingIndicatorView`。
///
/// 为什么不是 `NSHostingView`：计划 §2 铁律 2 明写「滚动容器里的单元格不许用
/// `NSHostingView`，除非里面真有 SwiftUI 才能做的控件」。这里只是四条圆角矩形加一条
/// `repeatForever` 的往复动画，CALayer 原生就能做，而每行挂一个宿主视图在滚动时要
/// 多付一整棵 SwiftUI 树的代价。语义与 SwiftUI 版逐条对齐：模型值恒为静止高度
/// （播放中 `minLevel`、暂停`idleLevel`），播放时再叠一条`transform.scale.y` 的
/// 无限往复动画；「减弱动态效果」开着就只留静止的一帧。
final class TrackRowLevelsView: NSView {

    private typealias M = MusicMetrics.NowPlayingLevels

    private var bars: [CALayer] = []
    private var isPlaying = false

    static let intrinsicWidth = M.width(levelWidth: M.rowLevelWidth)
    static let intrinsicHeight = M.rowMaximumLevelHeight

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for _ in 0..<M.count {
            let bar = CALayer()
            bar.cornerRadius = M.cornerRadius
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        applyColors()
        setAccessibilityHidden(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.intrinsicWidth, height: Self.intrinsicHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let width = M.rowLevelWidth
        let height = M.rowMaximumLevelHeight
        var x = (bounds.width - Self.intrinsicWidth) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            bar.position = CGPoint(x: x + width / 2, y: bounds.midY)
            x += width + M.spacing
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
        // 视图被摘下来（复用）时动画会被系统丢掉，装回去要重新起摆。
        if amberWindow != nil { syncSwing() }
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            let color = TrackRowKit.key.cgColor
            for bar in bars { bar.backgroundColor = color }
        }
    }

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        syncSwing()
    }

    func stop() {
        for bar in bars { bar.removeAllAnimations() }
    }

    /// 不摆时停在哪：播放中（还没起摆）取 `minLevel`，暂停取`idleLevel`。
    private var restingLevel: CGFloat { isPlaying ? M.minLevel : M.idleLevel }

    private func syncSwing() {
        let resting = restingLevel
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.removeAllAnimations()
            bar.transform = CATransform3DMakeScale(1, resting, 1)
        }
        CATransaction.commit()

        // [HIG] 「减弱动态效果」：这四条是不停的往复动画，系统不会替它降级，
        // 开了这一位就停在静止的一帧（与 SwiftUI 版同）。
        guard isPlaying, !CatalogCardKit.reducesMotion else { return }
        let now = CACurrentMediaTime()
        for (index, bar) in bars.enumerated() {
            let period = M.periods[index % M.periods.count]
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = resting
            animation.toValue = 1
            animation.duration = period / 2
            animation.autoreverses = true
            animation.repeatCount = .greatestFiniteMagnitude
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.beginTime = now + period * Double(index) / Double(M.count)
            bar.add(animation, forKey: "swing")
        }
    }
}

// MARK: - 行里的 40×40 封面

/// 歌单行与丰富行的小封面：`CatalogArtworkView` 贴图 + 悬浮暗罩 + 中央的播放/暂停字形。
/// 整块是一个 `NSButton`（点了从这一行起播），封面与字形都不接点击。
final class TrackRowArtworkButton: NSButton {

    private typealias M = MusicMetrics.TrackRow

    var onClick: (() -> Void)?

    private let artwork = CatalogArtworkView()
    private let glyph = TrackRowGlyphView()
    private let levels = TrackRowLevelsView()
    private let glyphSize: CGFloat
    private let glyphWeight: NSFont.Weight

    /// - Parameters:
    ///   - scrimOpacity: 悬浮暗罩浓度（歌单行 0.35、丰富行 0.18，照搬 SwiftUI 版）
    ///   - glyphSize/glyphWeight: 中央播放三角的字号字重（歌单 15 bold、丰富 12 semibold）
    ///   - showsLevels: 当前曲且未悬浮时把四条电平压在封面上（只有歌单行这么做）
    init(scrimOpacity: Float, glyphSize: CGFloat, glyphWeight: NSFont.Weight,
         showsLevels: Bool) {
        self.glyphSize = glyphSize
        self.glyphWeight = glyphWeight
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .shadowlessSquare
        title = ""
        imagePosition = .imageOnly
        target = self
        action = #selector(clicked)

        artwork.cornerRadius = M.artworkCornerRadius
        artwork.hoverScrimOpacity = scrimOpacity
        addSubview(artwork)

        glyph.imageScaling = .scaleNone
        glyph.contentTintColor = .white
        glyph.isHidden = true
        addSubview(glyph)

        levels.isHidden = true
        if showsLevels { addSubview(levels) }

        setAccessibilityLabel("播放")
        toolTip = "播放"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clicked() { onClick?() }

    func setArtwork(url: String?) {
        artwork.setArtwork(url: url, points: ArtworkSize.row)
    }

    /// - Parameters:
    ///   - hovering: 悬浮时压暗罩、摆播放/暂停字形
    ///   - isCurrent/isPlaying: 当前曲且未悬浮时压暗罩、摆电平
    func setState(hovering: Bool, isCurrent: Bool, isPlaying: Bool) {
        let showsGlyph = hovering
        let showsLevels = !hovering && isCurrent && levels.amberSuperview != nil
        artwork.setHovering(showsGlyph || showsLevels, animated: false)
        glyph.image = TrackRowKit.symbol(isPlaying ? "pause.fill" : "play.fill",
                                         size: glyphSize, weight: glyphWeight)
        glyph.isHidden = !showsGlyph
        levels.isHidden = !showsLevels
        levels.setPlaying(isPlaying)
        toolTip = isPlaying ? "暂停" : "播放"
        setAccessibilityLabel(isPlaying ? "暂停" : "播放")
    }

    override func layout() {
        super.layout()
        artwork.frame = bounds
        glyph.frame = bounds
        levels.frame = NSRect(x: (bounds.width - TrackRowLevelsView.intrinsicWidth) / 2,
                              y: (bounds.height - TrackRowLevelsView.intrinsicHeight) / 2,
                              width: TrackRowLevelsView.intrinsicWidth,
                              height: TrackRowLevelsView.intrinsicHeight)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artwork.prepareForReuse()
        glyph.isHidden = true
        levels.isHidden = true
        levels.stop()
    }
}

// MARK: - 序号 / 电平 / 播放键三选一的那一格

/// 专辑行与丰富行的首列（`indexWidth` = 27）：静止时是序号，悬浮换成品牌红播放键，
/// 当前曲换成四条电平。三者都在这一格里居中。
final class TrackRowLeadingSlot: NSView {

    let playButton = TrackRowGlyphButton(symbol: "play.fill", pointSize: 16, weight: .semibold)
    private let indexLabel = TrackRowKit.digitsLabel(size: 12, alignment: .center)
    private let levels = TrackRowLevelsView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(indexLabel)
        addSubview(levels)
        addSubview(playButton)
        levels.isHidden = true
        playButton.setVisible(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setIndex(_ index: Int) { indexLabel.stringValue = "\(index)" }

    func setState(hovering: Bool, isCurrent: Bool, isPlaying: Bool) {
        playButton.setVisible(hovering)
        playButton.setSymbol(isPlaying ? "pause.fill" : "play.fill")
        playButton.toolTip = isPlaying ? "暂停" : "播放"
        playButton.setAccessibilityLabel(isPlaying ? "暂停" : "播放")
        levels.isHidden = hovering || !isCurrent
        levels.setPlaying(isPlaying)
        indexLabel.isHidden = hovering || isCurrent
    }

    override func layout() {
        super.layout()
        playButton.frame = bounds
        TrackRowKit.layout(indexLabel, inkLeading: 0, width: bounds.width, centerY: bounds.midY)
        levels.frame = NSRect(x: (bounds.width - TrackRowLevelsView.intrinsicWidth) / 2,
                              y: (bounds.height - TrackRowLevelsView.intrinsicHeight) / 2,
                              width: TrackRowLevelsView.intrinsicWidth,
                              height: TrackRowLevelsView.intrinsicHeight)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        levels.stop()
        levels.isHidden = true
        playButton.setVisible(false)
        indexLabel.isHidden = false
    }
}

// MARK: - 搜索结果的来源标

/// 搜索行标题右侧那枚小胶囊（`kind.shortName`）：10pt 中粗次要色，
/// 左右内缩 6、上下 2，底 `quaternary` 0.7。
final class TrackRowKindBadge: NSView {

    private let label = TrackRowKit.label(size: 10, weight: .medium, color: .secondaryLabelColor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(label)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CatalogCardKit.textWidth(label) + 12,
               height: label.intrinsicContentSize.height + 4)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        TrackRowKit.layout(label, inkLeading: 6, width: bounds.width - 12, centerY: bounds.midY)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.backgroundColor = NSColor.quaternaryLabelColor
                .withAlphaComponent(NSColor.quaternaryLabelColor.alphaComponent * 0.7).cgColor
        }
    }
}
