import AppKit
import SwiftUI

// MARK: - 目录页卡片（AppKit）公共件 —— 阶段 3 批 B

// 这一批把 `CatalogCards.swift` 里那七种 SwiftUI 卡片 + 多列曲目行原样搬成
// `NSCollectionViewItem`。原则是计划 §2 铁律 5「换骨架，像素一个不改」：
// 字号 / 间距 / 圆角 / 遮罩浓度全部照搬 SwiftUI 版（那些数各自带 [AX]/[PX]/[WEB] 出处），
// 颜色一律走系统语义色（SwiftUI 的 `.primary`/`.secondary` 就是 `labelColor`/
// `secondaryLabelColor`），悬浮态由视图自己持有（铁律 3），不新增 Representable（铁律 1）。

/// 卡片里的文字标签。
///
/// `NSTextField` 即便是 label 形态也会**吃掉**落在它身上的点击（cell 不可编辑就把事件
/// 丢掉，不往父视图冒泡），而目录卡的点击要按区域分派（封面进主体、副标题进艺人页），
/// 所以标签一律不参与命中测试。先例：`MiniPlayerView.MiniTimeLabel`。
final class CatalogLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
enum CatalogCardKit {

    /// `NSTextField(labelWithString:)` 的 cell 左右**各留 2pt**，SwiftUI 的 `Text` 没有。
    /// （`MiniPlayerView.labelInset` 同一条：13pt 系统字的墨迹在裸 `NSString.draw` 里从
    /// 1.0 起，装进 label 后从 3.0 起。）手排 frame 时要把这 2pt 补回来，否则整排右移 2。
    static let labelInset: CGFloat = 2

    /// 悬浮态的淡入淡出，与 SwiftUI 版 `.easeInOut(duration: 0.15)` 同。
    static let hoverDuration: TimeInterval = 0.15

    static func label(size: CGFloat,
                      weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor,
                      lines: Int = 1) -> CatalogLabel {
        let field = CatalogLabel(labelWithString: "")
        field.font = weight == .regular ? .systemFont(ofSize: size)
                                        : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.maximumNumberOfLines = lines
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = lines != 1
        field.cell?.usesSingleLineMode = lines == 1
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    /// 压在封面上的白字都带这层投影（SwiftUI：`.shadow(color:.black.opacity(0.35), radius:3, y:1)`）。
    /// AppKit 的 y 轴向上，偏移取负。
    static func applyArtworkShadow(_ field: NSTextField, blur: CGFloat = 3, dy: CGFloat = 1) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = NSSize(width: 0, height: -dy)
        field.shadow = shadow
    }

    /// 纯字宽（不含上面那 2pt）
    static func textWidth(_ field: NSTextField) -> CGFloat {
        field.attributedStringValue.size().width
    }

    /// 单行行高取标签自己报的（13pt 系统字 = 16，与 [AX] Music 的标题框 16 一致）。
    static func lineHeight(_ field: NSTextField) -> CGFloat {
        field.intrinsicContentSize.height
    }

    static func setOpacity(_ layer: CALayer?, _ value: Float, animated: Bool) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(hoverDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        }
        layer.opacity = value
        CATransaction.commit()
    }

    static func setFrame(_ layer: CALayer?, _ frame: CGRect) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        CATransaction.commit()
    }

    /// 系统「减弱动态效果」开着就不做淡入淡出（与迷你播放器同一条）。
    static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

// MARK: - 封面

/// 卡片的封面块：`CALayer` 贴图（`resizeAspectFill`，与旧版 `ArtworkView` 的
/// `scaledToFill` + 裁切是同一件事）+ 没图时的渐变占位 + 悬浮暗罩 + 图底可读性渐变。
/// 圆角与遮罩都在这一层，外面不用再裁。
final class CatalogArtworkView: NSView {

    private let placeholder = CAGradientLayer()
    private let artwork = CALayer()
    private let glyph = NSImageView()
    private let hoverScrim = CALayer()
    private let legibility = CAGradientLayer()

    private var loadTask: Task<Void, Never>?
    private var requestedURL: String?
    /// 请求序号，只增不减：晚到的图靠它认主，见 `setArtwork`。
    private var requestToken: UInt64 = 0
    /// 这次铺的是条目自带的品牌渐变（非 nil）还是默认灰底（nil），见 `applyPlaceholderFill`。
    private var brandFill: [Color]?

    /// 图底可读性渐变的高度（0 = 不要这层）。SwiftUI 的 `LegibilityScrim`：透明 → 黑 0.55。
    var legibilityHeight: CGFloat = 0 { didSet { needsLayout = true } }
    /// 悬浮暗罩的浓度（海报/方卡 0.18、hero 0.15、大横幅 0.3）
    var hoverScrimOpacity: Float = 0.18
    /// 悬浮暗罩的颜色（大横幅是 `rgba(51,51,51,.3)`，其余是纯黑）
    var hoverScrimColor: NSColor = .black {
        didSet { hoverScrim.backgroundColor = hoverScrimColor.cgColor }
    }
    var cornerRadius: CGFloat = MusicMetrics.Card.artworkCornerRadius {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true

        placeholder.startPoint = CGPoint(x: 0, y: 1)   // topLeading
        placeholder.endPoint = CGPoint(x: 1, y: 0)     // bottomTrailing
        ArtworkPlaceholder.fill(placeholder, for: self)
        layer?.addSublayer(placeholder)

        artwork.contentsGravity = .resizeAspectFill
        artwork.masksToBounds = true
        artwork.isHidden = true
        layer?.addSublayer(artwork)

        glyph.imageScaling = .scaleNone
        glyph.contentTintColor = .amberArtworkPlaceholderGlyph
        glyph.isHidden = true
        addSubview(glyph)

        hoverScrim.backgroundColor = NSColor.black.cgColor
        hoverScrim.opacity = 0
        layer?.addSublayer(hoverScrim)

        legibility.colors = [NSColor(white: 0, alpha: 0).cgColor,
                             NSColor(white: 0, alpha: 0.55).cgColor]
        legibility.startPoint = CGPoint(x: 0.5, y: 1)   // 顶端透明
        legibility.endPoint = CGPoint(x: 0.5, y: 0)     // 底端黑 0.55
        legibility.isHidden = true
        layer?.addSublayer(legibility)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 占位底色是动态色，`cgColor` 只在铺上去那一刻解析一次，浅深切换时要重来一遍。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPlaceholderFill()
    }

    private func applyPlaceholderFill() {
        guard let brandFill, !brandFill.isEmpty else {
            ArtworkPlaceholder.fill(placeholder, for: self)
            return
        }
        // 条目自带的渐变也可能是动态色（心水歌曲那张就是 `labelColor` 派生的），
        // 同样按本视图的外观解析，别落到 `NSAppearance.current` 上。
        effectiveAppearance.performAsCurrentDrawingAppearance {
            placeholder.colors = brandFill.map { NSColor($0).cgColor }
        }
    }

    /// 装饰层不接点击，但要放行内部的按钮（悬浮播放键）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        CatalogCardKit.setFrame(placeholder, bounds)
        CatalogCardKit.setFrame(artwork, bounds)
        CatalogCardKit.setFrame(hoverScrim, bounds)
        CatalogCardKit.setFrame(legibility,
                                NSRect(x: 0, y: 0, width: bounds.width, height: legibilityHeight))
        legibility.isHidden = legibilityHeight <= 0
        glyph.frame = bounds
    }

    /// - Parameters:
    ///   - points: 想要的封面边长；nil = 用 provider 给的原始地址（MV 的 16:9 模板改写会 404）
    ///   - fallbackColors: 条目自带的品牌渐变；只有在**没有封面地址**时才顶上（与 SwiftUI 版同）
    ///   - brandGlyphSize: 品牌渐变上的音符字号；nil = 品牌渐变上不摆音符
    ///     （SwiftUI 版只有方卡的非电台形态摆，海报/hero/大横幅是纯渐变）
    ///   - loadingGlyphSize: 图还没到时那张渐变占位上的音符字号
    ///     （旧版 `ArtworkView` 是 `.title2`，即 17pt）
    func setArtwork(url: String?,
                    points: CGFloat?,
                    fallbackColors: [Color]? = nil,
                    brandGlyphSize: CGFloat? = nil,
                    loadingGlyphSize: CGFloat? = 17) {
        let brandColors = url == nil ? fallbackColors : nil
        let glyphSize: CGFloat?
        if let brandColors, !brandColors.isEmpty {
            // 条目自带的品牌渐变是深色块，音符照旧压白。
            glyph.contentTintColor = NSColor(white: 1, alpha: 0.75)
            glyphSize = brandGlyphSize
        } else {
            glyph.contentTintColor = .amberArtworkPlaceholderGlyph
            glyphSize = loadingGlyphSize
        }
        // 记下这次铺的是哪一种，浅深切换时照原样重铺（见 `applyPlaceholderFill`）。
        brandFill = brandColors
        applyPlaceholderFill()
        if let glyphSize {
            glyph.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: glyphSize, weight: .regular))
            glyph.isHidden = false
        } else {
            glyph.image = nil
            glyph.isHidden = true
        }

        let request = points.map { ArtworkSize.url(url, points: $0) } ?? url
        // 「没有封面」这一路必须每次都走到底：卡片是复用的（表格 `makeView`、集合视图的
        // item），`nil == nil` 认作「没变」就直接 return 的话，上一条目的封面会原样留在
        // 层上——资料库艺人页那些没有封面的本地专辑显示成别人的碟就是这么来的。
        guard request != requestedURL || request == nil else { return }
        requestedURL = request
        // 每次请求换一个号：`requestedURL` 有 nil，光比地址分不出「这次的 nil」和
        // 「上一次的 nil」，晚到的图会认错主人。
        requestToken &+= 1
        let token = requestToken
        loadTask?.cancel()
        loadTask = nil
        guard let request else { showArtwork(nil); return }
        // 内存里已经有就当场贴上，不走 `Task`：哪怕图早就在 `NSCache` 里，
        // 「先置空 → 下一轮微任务回填」也必定让卡片白一帧，切页时那下闪动就是它。
        if let cached = ImageCache.shared.memoryCachedImage(for: request) {
            showArtwork(cached)
            return
        }
        showArtwork(nil)
        loadTask = Task { [weak self] in
            let image = await ImageCache.shared.image(for: request)
            guard let self, !Task.isCancelled, self.requestToken == token, let image else { return }
            self.showArtwork(image)
        }
    }

    /// 本地画出来的封面（心水歌曲那张白底红星卡）：没有地址可请求，直接贴图。
    /// 走一次 `requestToken`，把还在飞的网络请求作废，免得晚到的图盖掉它。
    func setLocalArtwork(_ image: NSImage?) {
        loadTask?.cancel()
        loadTask = nil
        requestedURL = nil
        requestToken &+= 1
        glyph.image = nil
        glyph.isHidden = true
        showArtwork(image)
    }

    /// nil = 回到占位（渐变 + 音符）。贴图不走隐式动画：卡片是复用的，
    /// 淡入会变成「上一张淡出成这一张」。
    private func showArtwork(_ image: NSImage?) {
        // 贴给层的是 CGImage：`contents` 收下 `NSImage` 时，AppKit 会在提交那一刻按本层的
        // 尺寸／倍率重画一遍，同一张图挂在几个尺寸的层上就得各画一次（本地封面正是这种
        // 共用一份实例的情形），画的过程互相串起来就是那种「横带拼接」的花图。
        // `??` 的两边一个是 `CGImage?`、一个是 `NSImage`，合起来编译器要把 `Any?` 隐式
        // 提成 `Any`（一条警告）。拆成 `if let` 两条路，贴上去的东西也一眼看得清。
        let contents: Any?
        if let cgImage = image?.amberCGImage {
            contents = cgImage
        } else {
            contents = image
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artwork.contents = contents
        artwork.isHidden = image == nil
        CATransaction.commit()
        if image != nil { glyph.isHidden = true }
    }

    func setHovering(_ hovering: Bool, animated: Bool) {
        CatalogCardKit.setOpacity(hoverScrim, hovering ? hoverScrimOpacity : 0, animated: animated)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        requestedURL = nil
        // 清封面走 `showArtwork(nil)` 这条唯一通路（它把隐式动画关掉），别直接写
        // `contents = nil`：手加的 sublayer 是吃隐式动画的，那一下会给复用中的层挂一次
        // `contents` 淡出，紧接着 `configure` 贴上的新图就成了「上一张淡成这一张」——
        // 正是 `showArtwork` 注释里要躲开的那件事。
        showArtwork(nil)
        glyph.isHidden = true
        CatalogCardKit.setOpacity(hoverScrim, 0, animated: false)
    }
}

// MARK: - 悬浮播放键

/// 卡片右下角（大横幅是左下角）悬浮才现身的播放键：34 圆玻璃片 + 白 `play.fill`，
/// 四周内缩 8（`MusicMetrics.Card.playButtonSize / playButtonPadding`，与 SwiftUI 版
/// `CardPlayButton` 同）。压在深色封面上时再带一层投影。
final class CatalogPlayButton: NSButton {

    static let diameter = MusicMetrics.Card.playButtonSize
    static let inset = MusicMetrics.Card.playButtonPadding

    var onClick: (() -> Void)?

    private let material = NSVisualEffectView()
    private let glyph = NSImageView()

    init(iconSize: CGFloat = 14, hasShadow: Bool = true) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        isBordered = false
        bezelStyle = .shadowlessSquare
        title = ""
        imagePosition = .imageOnly
        target = self
        action = #selector(clicked)

        // SwiftUI 版是 `.background(.ultraThinMaterial, in: Circle())`。
        // AppKit 侧最薄的一档窗内材质是 `.hudWindow`，同样是「透过它看到底下的封面」。
        material.material = .hudWindow
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = Self.diameter / 2
        material.layer?.masksToBounds = true
        material.frame = bounds
        material.autoresizingMask = [.width, .height]
        addSubview(material)

        glyph.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: iconSize, weight: .semibold))
        glyph.contentTintColor = .white
        glyph.imageScaling = .scaleNone
        glyph.frame = bounds
        glyph.autoresizingMask = [.width, .height]
        addSubview(glyph)

        if hasShadow {
            wantsLayer = true
            layer?.masksToBounds = false
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.35
            layer?.shadowRadius = 4
            layer?.shadowOffset = CGSize(width: 0, height: -1.5)
        }

        // [HIG] Liquid Glass 的图标键必须自带 accessibility label，否则 VoiceOver 只念「按钮」。
        setAccessibilityLabel("播放")
        toolTip = "播放"
        isHidden = true
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clicked() { onClick?() }

    override func layout() {
        super.layout()
        // `CGPath` 的这组初始化器 `transform` 是 `UnsafePointer<CGAffineTransform>?`，
        // 整条声明因此被判为不安全；传 nil 时压根没有指针可悬垂。全仓只两处（另一处在
        // `CatalogPageViewController` 的胶囊），够不上做外壳的判据，就地标。
        layer?.shadowPath = unsafe CGPath(ellipseIn: bounds, transform: nil)
    }

    /// `alphaValue = 0` 的视图仍然参与 `hitTest`（只有 `isHidden` 才不参与），
    /// 所以收起时一定要 `isHidden`，不然卡片右下角有一块 34×34 点不动。
    func setVisible(_ visible: Bool, animated: Bool) {
        guard isHidden == visible else { return }
        guard animated, !CatalogCardKit.reducesMotion else {
            isHidden = !visible
            alphaValue = visible ? 1 : 0
            return
        }
        if visible {
            alphaValue = 0
            isHidden = false
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CatalogCardKit.hoverDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            // 完成回调的类型是 `@Sendable`，而这里动的是主线程隔离的视图。
            // `NSAnimationContext` 明文保证回调在主线程，所以用 `assumeIsolated` 接回来。
            MainActor.assumeIsolated {
                guard let self, !visible else { return }
                self.isHidden = true
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview = amberSuperview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }
}

// MARK: - 「更多」键

/// 节目宽卡与曲目行右侧那颗 •••：15pt 字形，静止次要色、卡片悬浮时转品牌色。
final class CatalogMoreButton: NSButton {

    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .shadowlessSquare
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(clicked)
        setAccessibilityLabel("更多")
        toolTip = "更多"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clicked() { onClick?() }

    func setHovering(_ hovering: Bool) {
        contentTintColor = hovering ? NSColor(Color.amberKey) : .secondaryLabelColor
    }
}

// MARK: - Explicit 脏标

/// 方卡标题右侧的「E」：8pt bold 次要色，左右内缩 2.5、上下 0.5，底 `secondary` 0.2、圆角 2。
final class CatalogExplicitBadge: NSView {

    private let label = CatalogCardKit.label(size: 8, weight: .bold, color: .secondaryLabelColor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 2
        label.stringValue = "E"
        addSubview(label)
        setAccessibilityLabel("儿童不宜")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let size = label.intrinsicContentSize
        // label 自带的 2pt 内缩正好把 2.5 的横向 padding 吃掉大半，只补差额
        return NSSize(width: CatalogCardKit.textWidth(label) + 5, height: size.height + 1)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: (bounds.width - label.intrinsicContentSize.width) / 2,
                             y: (bounds.height - label.intrinsicContentSize.height) / 2,
                             width: label.intrinsicContentSize.width,
                             height: label.intrinsicContentSize.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
            layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.2).cgColor
        }
    }
}

// MARK: - 缩略图角标

/// 压在缩略图右下角的小角标（搜索结果 MV 卡的时长，旧版 `MVCard` 那颗）：
/// 10/500 白字，左右内缩 5、上下 2，底黑 0.65、圆角 3。摆位（距图边 6）由用它的卡负责。
final class CatalogCornerBadge: NSView {

    private typealias M = MusicMetrics.Catalog

    private let label = CatalogCardKit.label(size: M.videoBadgeTextSize,
                                             weight: .medium, color: .white)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = M.videoBadgeCornerRadius
        layer?.backgroundColor = NSColor(white: 0, alpha: M.videoBadgeBackgroundAlpha).cgColor
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var text: String = "" {
        didSet {
            label.stringValue = text
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CatalogCardKit.textWidth(label) + M.videoBadgeHPadding * 2,
               height: CatalogCardKit.lineHeight(label) + M.videoBadgeVPadding * 2)
    }

    override func layout() {
        super.layout()
        let height = CatalogCardKit.lineHeight(label)
        label.frame = NSRect(x: M.videoBadgeHPadding - CatalogCardKit.labelInset,
                             y: (bounds.height - height) / 2,
                             width: max(0, bounds.width - M.videoBadgeHPadding * 2)
                                 + CatalogCardKit.labelInset * 2,
                             height: height)
    }

    /// 装饰件，不接点击（点在角标上仍然算点在卡上）。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - 键盘焦点环

/// 卡片的键盘焦点环。**环本身整只交给系统画**（铁律 6）：`NSFocusRingPlacement.only`
/// 之后填的那条路径，AppKit 按当前强调色 / 外观渲成系统那只环，粗细、羽化、颜色
/// 一个数都不在这里定——换句话说，用户在「系统设置 ▸ 外观」里换强调色，这只环跟着换。
/// 这里自己定的只有两件：形状（跟着卡片的圆角），和那一点内缩。
///
/// 焦点环是本轮**唯一新增的像素**（从前这四页对键盘用户压根没有可见的落点，
/// 见审查单 §2.5-1），出处记在 `inset` 上。
///
/// **为什么单独做成一只视图**：11 种卡整棵都是 CALayer 组的（`override func draw` 全仓
/// 0 处），把环画进卡片自己的 `draw` 等于给每一张卡都配上一块位图后备。这只视图只在
/// 真的拿到焦点时才在场，没焦点时整棵树和从前一模一样。
private final class CatalogCardFocusRingView: NSView {

    /// 路径往里让出的一圈 ＝ 环往外扩的那一圈。层背视图的绘制被自己的 bounds 裁掉，
    /// 环画到界外就没了，所以先让出来。
    ///
    /// [实测 probe 2026-09-17] 系统不公开这个数（`NSFocusRingPlacement` 只说画哪一层），
    /// 所以量了一次：在 160×160 的层背画布正中填一个 80×80 的圆角矩形，
    /// `NSFocusRingPlacement.only` 之后墨迹盒是 37…123，即**四周各外扩 3.0pt**，
    /// 内部不填（环是空心的，卡片内容照样透出来）。同一次探针也确认了
    /// 「层背视图里 `NSSetFocusRingStyle` 画得出来」——画出来的正是系统那只蓝环
    /// （首像素 r0.30 g0.65 b1.00 a0.08，对得上 `keyboardFocusIndicatorColor`）。
    static let inset: CGFloat = 3

    /// 跟着卡片的圆角走，让环贴着卡形而不是套一个方框。
    var cornerRadius: CGFloat = 0 {
        didSet {
            guard cornerRadius != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 纯装饰：点击照旧落在它盖住的那张卡上。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        guard rect.width > 0, rect.height > 0 else { return }
        // 路径往里缩了多少，圆角也要跟着小多少，不然环的转角会比卡片更方。
        let radius = max(0, cornerRadius - Self.inset)
        NSGraphicsContext.saveGraphicsState()
        NSFocusRingPlacement.only.set()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - 卡片根视图

/// 所有目录卡的根视图：悬浮态由自己持有（计划 §2 铁律 3），点击按区域分派，
/// 右键弹自己那份 `NSMenu`。
@MainActor
class CatalogCardContentView: NSView, CatalogHoverTarget {

    private(set) var item: CatalogItem?
    private(set) weak var appState: AppState?

    /// 有落点（route / onOpen）或点击即播（onPlay）才算可交互：都没有的卡不可点、也不给悬浮态。
    private(set) var isInteractive = false
    private(set) var isHovering = false

    /// 键盘焦点态（审查单 §2.5-1 剩下的那一半）。
    ///
    /// **与悬浮态是两个字段，不合并**：页面侧的 `hoveredCard` 是鼠标驱动的，
    /// 滚轮滚动、鼠标没动时也会重算一次（见 `CatalogCardItem.CatalogHoverTarget` 的注释）——
    /// 两件事共用一个字段，等于鼠标一动就把键盘焦点抹掉。
    /// 铁律 3：显示态由视图自己持有、自己 `needsDisplay`，不上广播。
    private(set) var isKeyboardFocused = false

    /// 焦点环只在真的拿到焦点时才建，没焦点的卡不多这一只视图。
    private var focusRing: CatalogCardFocusRingView?

    /// 宿主 `NSCollectionViewItem.isSelected` 的 KVO。
    ///
    /// `NSCollectionViewItem` 不把选中态转给自己的 `view`（它的 setter 只写 ivar），
    /// 而 11 种卡的 item 外壳分散在三个文件里；`selected` 是普通合成属性，
    /// **自动 KVO 成立**（IB 里绑定选中态走的就是它），所以在根视图这一处接一次
    /// 就覆盖全部卡型，不必逐个外壳覆写 `isSelected`。
    private var selectionObservation: NSKeyValueObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 子类在这里搭子视图
    func build() {}
    /// 子类在这里把数据装上
    func apply(_ item: CatalogItem) {}
    /// 子类在这里改悬浮的样子
    func hoverDidChange(_ hovering: Bool, animated: Bool) {}
    /// 子类在这里补自己的复位
    func resetContent() {}
    /// 封面/画面视图（用于翻页胶囊对齐封面中心）
    open var artworkViewForAlignment: NSView? { nil }

    final func configure(with item: CatalogItem, appState: AppState) {
        self.item = item
        self.appState = appState
        isInteractive = item.route != nil || item.onOpen != nil || item.onPlay != nil
        apply(item)
        // 「身份没变、内容变了」时页面会拿**同一张**卡再 configure 一次
        //（心水星、入库态，见 `CatalogPageViewController.reconfigure(_:)`）。
        // `apply` 是照「刚出队」写的，会把悬浮那几件复位（播放键收掉、暗罩撤掉），
        // 而此刻鼠标可能正停在这张卡上——不补这一下，用户会在鼠标没动的情况下
        // 眼睁睁看着播放键消失。正常出队那条路 `prepareForReuse` 已经把`isHovering`
        // 清成 false，走不到这里，所以不影响复用。
        if isHovering { hoverDidChange(true, animated: false) }
        setAccessibilityLabel([item.eyebrow, item.title, item.subtitle]
            .compactMap { $0 }.joined(separator: "，"))
        bindSelectionIfNeeded()
        needsLayout = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if isHovering {
            isHovering = false
            hoverDidChange(false, animated: false)
        }
        // 出队时先把焦点环撤掉：新的选中态由 collection view 随后写进 `isSelected`，
        // KVO 会把该亮的那张重新点亮。不撤的话，上一位的环会跟着卡片被复用出去。
        setKeyboardFocused(false)
        item = nil
        appState = nil
        isInteractive = false
        resetContent()
    }

    // MARK: 键盘焦点（审查单 §2.5-1）

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bindSelectionIfNeeded()
    }

    /// 接一次就够：卡片复用的是同一只视图挂在同一只 item 上，
    /// 所以 `prepareForReuse` 不解这条 KVO（解了下一轮还得重接）。
    ///
    /// 两个调用点是同一件事的两次机会：`configure` 那次一定接得上（item 正在喂数据给
    /// 自己的 `view`，两者的关系已经成立），`viewDidMoveToWindow` 那次只是更早一点。
    private func bindSelectionIfNeeded() {
        guard selectionObservation == nil, let item = enclosingCollectionViewItem else { return }
        selectionObservation = item.observe(\.isSelected, options: [.initial, .new]) { [weak self] _, change in
            guard let focused = change.newValue else { return }
            // `setSelected:` 由 `NSCollectionView` 在主线程调，KVO 是同步发出来的；
            // 这里再跳一次主 actor 会让环晚一个 runloop 才亮，方向键连按就跟不上手。
            MainActor.assumeIsolated { self?.setKeyboardFocused(focused) }
        }
    }

    /// 根视图挂在 item 的 `view` 上，所以响应链上第一位 `NSCollectionViewItem` 就是宿主。
    private var enclosingCollectionViewItem: NSCollectionViewItem? {
        var responder = amberNextResponder
        while let current = responder {
            if let item = current as? NSCollectionViewItem { return item }
            responder = current.amberNextResponder
        }
        return nil
    }

    private func setKeyboardFocused(_ focused: Bool) {
        guard focused != isKeyboardFocused else { return }
        isKeyboardFocused = focused
        guard focused else {
            focusRing?.removeFromSuperview()
            focusRing = nil
            return
        }
        let ring = CatalogCardFocusRingView(frame: bounds)
        ring.autoresizingMask = [.width, .height]
        focusRing = ring
        addSubview(ring, positioned: .above, relativeTo: nil)
        layoutFocusRing()
    }

    /// 子类全都在自己的 `layout()` 头上调 `super.layout()`，所以这一条对 11 种卡都成立。
    override func layout() {
        super.layout()
        layoutFocusRing()
    }

    /// 环的圆角跟着卡片自己的圆角走：链接卡 / 首要结果卡是卡根带圆角，
    /// 其余卡的圆角在封面块上，都没有就退回海报卡那一档。
    private func layoutFocusRing() {
        guard let focusRing else { return }
        focusRing.frame = bounds
        if let radius = layer?.cornerRadius, radius > 0 {
            focusRing.cornerRadius = radius
        } else if let artwork = artworkViewForAlignment as? CatalogArtworkView {
            focusRing.cornerRadius = artwork.cornerRadius
        } else {
            focusRing.cornerRadius = MusicMetrics.Catalog.posterCornerRadius
        }
    }

    /// 整卡默认落点：有 route 就推一层；没有 route 但有 `onOpen` 的（资料库派生的艺人卡）
    /// 走它自己那条跳转；再没有就当「点了直接播」（Apple 的电台卡就是这样）。
    final func activatePrimary() {
        guard let item else { return }
        if let route = item.route {
            appState?.push(route)
        } else if let onOpen = item.onOpen {
            onOpen()
        } else if let onPlay = item.onPlay {
            onPlay()
        }
    }

    /// 有曲目上下文的卡走**目录页那一份**曲目项序（`TrackActions.catalogRow`，与目录曲目行同）；
    /// 专辑 / 歌单 / 艺人 / 电台卡走集合那一份（`CollectionActions`）。
    ///
    /// 菜单每次弹出都当场装配：`ClosureMenuItem` 自己当 target、自己持有闭包，
    /// 卡片不必再留一个控制器防释放。
    final func makeTrackMenu() -> NSMenu? {
        guard let item, let appState else { return nil }
        guard let track = item.track else {
            return CatalogCardActions.makeMenu(for: item, appState: appState)
        }
        return MenuSpec.makeMenu(TrackActions(tracks: [track], appState: appState,
                                              fallbackPlay: item.onPlay).catalogRow())
    }

    // MARK: 悬浮（由 `CatalogPageViewController` 按 hitTest 分发，见 `CatalogHoverTarget`）

    final func setHovering(_ hovering: Bool) {
        let wanted = hovering && isInteractive
        guard wanted != isHovering else { return }
        isHovering = wanted
        hoverDidChange(wanted, animated: true)
    }

    // MARK: 点击

    override func mouseDown(with event: NSEvent) {}

    /// 与 SwiftUI 的 `Button` 同：按下不触发，抬手仍在盒内才算一次点击。
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        handleClick(at: point, clickCount: event.clickCount)
    }

    /// 子类按区域分派（封面 / 标题 / 副标题各有各的落点）；默认整卡一个落点。
    func handleClick(at point: NSPoint, clickCount: Int) {
        guard isInteractive else { return }
        activatePrimary()
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeTrackMenu() }

    override func accessibilityPerformPress() -> Bool {
        guard isInteractive else { return false }
        activatePrimary()
        return true
    }
}


// MARK: - 专辑 / 歌单 / 艺人卡的菜单

/// 没有曲目上下文的卡（专辑、歌单、艺人、电台、MV）那份菜单。
///
/// 这里只**报能力**：把这张卡能做的事塞进 `CollectionActions` 的口袋里，
/// 排在哪由 `CollectionActions.entries` 说了算（实测项序见那边的注释）。
/// 从前是各卡各自 `addItem` 拼一份，才拼出了各处不一致的顺序。
@MainActor
enum CatalogCardActions {

    static func makeMenu(for item: CatalogItem, appState: AppState) -> NSMenu? {
        actions(for: item, appState: appState).makeMenu()
    }

    static func actions(for item: CatalogItem, appState: AppState) -> CollectionActions {
        let library = appState.library
        var actions = CollectionActions()
        actions.play = item.onPlay

        // 落点：有 `route` 就按类型换标题；
        // 没有 `route`、落点挂在 `onOpen` 上的卡（资料库派生的艺人）走它自己那条，
        // 否则这类卡菜单里一条落点都没有。
        if let route = item.route {
            let title: String?
            switch route {
            case .album: title = "前往专辑"
            case .playlist: title = "前往歌单"
            case .artist: title = "前往艺人"
            default: title = nil
            }
            if let title { actions.goTo = (title, { appState.push(route) }) }
        } else if let onOpen = item.onOpen, let title = item.openMenuTitle {
            actions.goTo = (title, onOpen)
        }

        // 副标题上那个艺人的落点（卡副标题可点时才有）。
        if let subtitleRoute = item.subtitleRoute, case .artist = subtitleRoute {
            actions.goToArtist = { appState.push(subtitleRoute) }
        }

        // 视频卡：下 / 删本地那份 MV（落点见 `DownloadStore.mvRelativePath`）。
        // 「下载 / 移除下载」在 `CollectionActions` 里本来就是分开的两条，
        // 判据同一个、方向相反，永远只出现一个。
        if let mv = item.mv {
            let downloads = appState.downloads
            if downloads.localMVURL(for: mv) == nil {
                actions.download = { downloads.downloadMV(mv) }
            } else {
                actions.removeDownload = { downloads.removeMVDownload(mv) }
            }
            // 取流被拒时的兜底：还能去音源网页版看。
            actions.openOnWeb = { NSWorkspace.shared.open(mv.webURL) }
        }

        // 「分享」交给系统共享菜单的那条链接：卡指向哪个对象就分享哪一页。
        switch item.route {
        case .album(let album): actions.shareURL = album.webShareURL
        case .playlist(let playlist): actions.shareURL = playlist.webShareURL
        case .artist(let artist): actions.shareURL = artist.webShareURL
        default: actions.shareURL = item.mv?.webURL
        }

        // 艺人卡：「减少推荐」写的是音源账号里的口味（QQ 的不喜欢名单收歌手；
        // 网易云没有这条能力，那边整对不摆）。
        if case .artist(let artist) = item.route {
            if appState.canSuggestLess(artist: artist, less: true) {
                actions.suggestLess = { appState.suggestLess(artist: artist, less: true) }
            }
            if appState.canSuggestLess(artist: artist, less: false) {
                actions.undoSuggestLess = { appState.suggestLess(artist: artist, less: false) }
            }
        }

        if case .album(let album) = item.route {
            if library.isFavoriteAlbum(album) {
                actions.undoFavorite = { library.toggleFavoriteAlbum(album) }
            } else {
                actions.favorite = { library.toggleFavoriteAlbum(album) }
            }
            let toggleLibrary = { toggleAlbumLibrary(album, appState: appState) }
            if library.isAlbumInLibrary(album) {
                actions.deleteFromLibrary = toggleLibrary
            } else {
                actions.addToLibrary = toggleLibrary
            }
        } else if case .playlist(let playlist) = item.route,
                  !library.isPlaylistInLibrary(playlist) {
            actions.addToLibrary = {
                library.addPlaylistToLibrary(playlist)
                appState.showToast("已将《\(playlist.name)》添加到资料库")
            }
        }

        return actions
    }

    /// 入库要整张碟的曲目，先拉一次详情再写库（与专辑页头的「添加到资料库」同一条路）。
    private static func toggleAlbumLibrary(_ album: Album, appState: AppState) {
        Task { @MainActor in
            do {
                let detail = try await appState.provider(album.kind).albumDetail(album)
                if appState.library.isAlbumInLibrary(album) {
                    appState.library.removeAlbumFromLibrary(album, tracks: detail.tracks)
                    appState.showToast("已将《\(album.name)》从资料库中删除")
                } else {
                    appState.library.addAlbumToLibrary(album, tracks: detail.tracks)
                    appState.showToast("已将《\(album.name)》添加到资料库")
                }
            } catch {
                appState.showToast("拿不到专辑曲目：\(error.localizedDescription)")
            }
        }
    }
}
