import AppKit
import CoreImage
import SwiftUI

// MARK: - 艺人目录页的两块新卡 + 钉住的背景层（批 D）

// 目录艺人页（`design-ref/ui-spec/pages/catalog-artist.png`，@2x 全屏截图 + Music 1.7
// 实机 2026-09-06 对照）由三块东西组成，这个文件只管这三块，页面与布局引擎在批 C：
//
// 1. `ArtistBackdropView`——钉在 scroll view 底下的满幅封面背景：图**不随文稿滚**，
//    静止时上半清晰、往下渐变进模糊并一直铺到页底（各栏目的页面底色就是这张糊图），
//    滚动时清晰层淡出、整页转糊（实机行为详见类注释）。
// 2. `ArtistHeroView`（`CatalogItem.Kind.artistHero`）——hero 那件 collection item：
//    艺人名 40pt 白字居中 + 名字下面三枚圆键 ⓘ(45) / 白底 ▶(69) / ★(45)——
//    **三枚恒在**。名字与按钮是内容、随文稿滚（与实机一致），不带图；
//    ⓘ 点开的艺人介绍面板在 `AboutPanel.swift`。
// 3. `ArtistReleaseCardView`（`.release`）——图下并排带左半的「最新發行」卡：
//    162 方封面贴左 + 右侧三行（发行日期 / 专辑名 /「N 首歌曲」）+ 一枚 ＋ 圆键。
//
// 像素规格全部取自 `MusicMetrics.ArtistPage`（每条自带 [PX]/[实测] 出处），
// 这个文件里只留几条页面私有的 [推]，各自在声明处注明出处。
// 铁律（`AGENTS.md`「界面层」）：不新增 Representable、悬浮/收藏态由视图自己持有并重画、
// 行高一类先问系统默认（`intrinsicContentSize` / `sizeThatFits`），不写死。

// MARK: - 圆键

/// hero 的三枚圆键与「最新發行」的 ＋ 键共用这一个：一个圆 + 一个字形，三种底。
///
/// - `.glass`：半透明毛玻璃圆（ⓘ / ★）。材质照`CatalogPlayButton` 的做法取`.hudWindow`
///   ——AppKit 侧最薄的一档窗内材质，等价于 SwiftUI 的 `.ultraThinMaterial`。
/// - `.solidWhite`：白色实心圆 + 黑字形（hero 的 ▶，与 Music 一致，**不是**毛玻璃）。
/// - `.subtle`：`secondaryLabelColor` 20% 的底 + 主色字形（「最新發行」的 ＋，
///   浓度照 `CatalogExplicitBadge` 那块脏标）。
///
/// 艺人简介面板（`AboutPanel.swift`）左上角那枚 ✕ 也是这一个的`.glass` 档，
/// 所以它是 internal 而不是 private。
final class ArtistCircleButton: NSButton {

    enum Style { case glass, solidWhite, subtle }

    var onClick: (() -> Void)?

    private let style: Style
    private let diameter: CGFloat
    private let glyphSize: CGFloat
    private let material = NSVisualEffectView()
    private let glyph = NSImageView()
    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    /// 字形色。★ 收藏后要换品牌红，所以单独开出来，改完立刻重画（铁律 3）。
    var glyphColor: NSColor = .white {
        didSet { glyph.contentTintColor = glyphColor }
    }

    init(style: Style, diameter: CGFloat, symbol: String, glyphSize: CGFloat,
         weight: NSFont.Weight = .semibold) {
        self.style = style
        self.diameter = diameter
        self.glyphSize = glyphSize
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        isBordered = false
        bezelStyle = .shadowlessSquare
        title = ""
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.masksToBounds = true
        target = self
        action = #selector(clicked)

        if style == .glass {
            material.material = .hudWindow
            material.blendingMode = .withinWindow
            // hero 一直压着大图，窗口失焦时也不该退成灰片，所以钉死 .active
            // （默认 .followsWindowActiveState 会跟着窗口一起失活）。
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = diameter / 2
            material.layer?.masksToBounds = true
            material.frame = bounds
            material.autoresizingMask = [.width, .height]
            addSubview(material)
        }

        glyph.imageScaling = .scaleNone
        glyph.frame = bounds
        glyph.autoresizingMask = [.width, .height]
        addSubview(glyph)
        setSymbol(symbol, weight: weight)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    func setSymbol(_ name: String, weight: NSFont.Weight = .semibold) {
        glyph.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: glyphSize, weight: weight))
        glyph.contentTintColor = glyphColor
    }

    @objc private func clicked() { onClick?() }

    // MARK: 悬浮 / 按下

    // 悬浮态自己持有（铁律 3）：进出用自己的 tracking area，不经过页面那套 hitTest 分发
    // ——页面那套是按整张卡分发的，落不到卡里的单个按钮上。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyFeedback() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyFeedback() }

    /// `super.mouseDown` 自带跟踪循环（抬手仍在盒内才发 action），会一直阻塞到 mouseUp，
    /// 所以按下态在它前后各刷一次就够，不用另开状态机。
    override func mouseDown(with event: NSEvent) {
        pressed = true
        applyFeedback()
        super.mouseDown(with: event)
        pressed = false
        applyFeedback()
    }

    private func applyFeedback() {
        // 反馈只用整体透明度：不缩放、不换色，与目录卡上其它按钮同一档轻反馈。
        alphaValue = pressed ? 0.6 : (hovering ? 0.85 : 1)
    }

    // MARK: 底色

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
            switch style {
            case .glass:
                layer?.backgroundColor = nil
            case .solidWhite:
                layer?.backgroundColor = NSColor.white.cgColor
            case .subtle:
                layer?.backgroundColor = NSColor.secondaryLabelColor
                    .withAlphaComponent(0.2).cgColor
            }
        }
    }
}

// MARK: - 「糊进黑底」的带：压暗那一层

/// 只做渐变的一层：`makeBackingLayer` 直接给`CAGradientLayer`，省一层 sublayer 的手工排布。
///
/// 现在只有艺人简介面板（`AboutPanel.swift`）的下半程在用这一套「模糊 + 压暗」；
/// 艺人页本身的封面背景换了钉住的 `ArtistBackdropView`（见它的类注释）。
/// 这一层与配套的遮罩图 `makeFadeMask()` 保持 internal，两处共用的实测结论
/// 留在 `AboutPanel` 侧。
final class ArtistScrimGradientView: NSView {

    override func makeBackingLayer() -> CALayer { CAGradientLayer() }

    private var gradient: CAGradientLayer? { layer as? CAGradientLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 与 `CatalogArtworkView.legibility` 同一套单位坐标：y=1 是顶端、y=0 是底端。
        gradient?.startPoint = CGPoint(x: 0.5, y: 1)
        gradient?.endPoint = CGPoint(x: 0.5, y: 0)
        // [推] 参考图里这条带是「上面还看得见图 → 下面完全是黑」：
        // 顶端全透明、中段压掉一半、底端纯黑接页面背景。三段而不是两段，是因为两段线性
        // 到中点就已经 0.5 黑，名字上方那截图会被压得太早。
        gradient?.colors = [NSColor(white: 0, alpha: 0).cgColor,
                            NSColor(white: 0, alpha: 0.5).cgColor,
                            NSColor(white: 0, alpha: 1).cgColor]
        gradient?.locations = [0, 0.55, 1]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 「上透明 → 下不透明」的遮罩：`maskImage` 只看 alpha 通道，颜色随便取黑。
    /// 1×64 一条竖渐变即可（见 `ArtistHeroView` 类注释里的实测结论：整张图会被拉满视图）。
    static func makeFadeMask() -> NSImage {
        let image = NSImage(size: NSSize(width: 1, height: 64), flipped: false) { rect in
            guard let gradient = NSGradient(colors: [NSColor(white: 0, alpha: 0),
                                                     NSColor(white: 0, alpha: 1)]) else {
                return false
            }
            gradient.draw(in: rect, angle: 270)   // 270 = 从上往下，起点色（透明）在顶端
            return true
        }
        image.capInsets = NSEdgeInsetsZero
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - 钉住的满幅背景层

/// 艺人页的封面背景：**钉在 scroll view 底下、不随文稿滚**，随滚动从清晰转糊。
///
/// 实机行为（Music 1.7，2026-09-06 告五人页，截图 + 逐帧对照）：
/// - 名字/按钮/各栏目是内容，随文稿滚；封面图**钉在原地**——滚 ~230pt 后内容上移了一个
///   身位，图还在原处，只是已经完全糊了。所以图不能是 collection view 里的一件，
///   得垫在 scroll view 底下（`CatalogPageViewController.makePinnedBackdrop`）。
/// - 静止时清晰带从页顶延伸到 hero 高的四成半，四成半到七成渐变进模糊；模糊**一直铺到
///   页面底**——「最新發行」「熱門歌曲」「專輯」全都压在这张糊图上，越往下越暗。
///   糊图就是页面的背景色，滚到多深它都在（深处那层暗青色就是艺人图糊出来的）。
///
/// 三层（都是 `CALayer`，视图非翻转，y=0 在底）：
/// 1. `blurLayer`：整页一张**预合成**的糊图（见`regenerateBackdrop()`）；
/// 2. `sharpLayer`：清晰原图，frame 是 hero 带，`mask` 用竖向渐变在
///    `backdropSharpFadeStart…End` 渐隐——它压在糊层上，静止时上半段全清晰、
///    渐隐段露出下面的糊层（同一张图逐像素对齐，所以交叉淡化不会「呼吸」）；
/// 3. `scrimLayer`：压暗层，从渐隐段末尾开始压到`backdropScrimBottom`。
/// 滚动时只动一个数：`sharpLayer.opacity = 1 − offset / backdropScrollFadeDistance`，
/// 清晰层淡完，整页就剩糊图。
final class ArtistBackdropView: NSView, CatalogPageBackdroping {

    private typealias A = MusicMetrics.ArtistPage

    private let blurLayer = CALayer()
    private let sharpLayer = CALayer()
    private let scrimLayer = CAGradientLayer()
    private let sharpMask = CAGradientLayer()

    private var loadTask: Task<Void, Never>?
    private var requestedURL: String?
    private var sharpImage: CGImage?
    /// **层上那两张画布**对应的尺寸（宽/高一致才不重画，见 `regenerateBackdrop()`）。
    private var canvasFor: NSSize?
    /// **正在后台烘**的那一档。与 `canvasFor` 分开：投递出去到贴回来之间层上还是旧画布，
    /// 只看 `canvasFor` 挡不住重复投递——首次装图那一路层上干脆是空的，
    /// 拖窗会把同一档尺寸连投几十次。
    private var pendingCanvas: NSSize?
    /// 每次投递自增。烘好的画布拿着投递时的号回来，对不上就是过期画布，丢掉——
    /// 实时拖窗时后发的先回来是常态，不校验就会贴上一档尺寸的画布。
    private var canvasToken: UInt64 = 0
    /// 正在后台烘的那一趟。留住句柄是为了**新一档来时把旧的取消**：号（`canvasToken`）
    /// 只管「回来了贴不贴」，挡不住旧那趟把高斯模糊算完——实时拖窗时每一档宽度都会
    /// 整页糊一遍，算出来全扔。取消后 `bake` 在两次渲染之间看 `Task.isCancelled` 提前收工。
    private var bakeTask: Task<Void, Never>?
    /// 被 `isHidden` 收着（艺人页压在栈里、或切走了）期间该烘没烘的那一笔，
    /// 等 `viewDidUnhide()` 补。导航容器只切 `isHidden` 不摘视图，隐藏的页照样参与布局，
    /// 不挡的话拖窗时栈里每一张艺人页都在后台按每一档宽度烘一遍。
    private var needsBakeWhenShown = false
    /// `CIContext` 是 `NS_SWIFT_SENDABLE` 的（头文件里就这么标的），建一次交给后台那一路复用。
    /// `cacheIntermediates: false`：这些中间结果只用一次，留着白占显存。
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        // 两层贴的都是自己渲染出来的画布，画布尺寸 == frame 尺寸，1:1 贴。
        blurLayer.contentsGravity = .resize
        layer?.addSublayer(blurLayer)

        sharpLayer.contentsGravity = .resize
        sharpLayer.mask = sharpMask
        sharpMask.startPoint = CGPoint(x: 0.5, y: 1)   // 渐变从顶端起算
        sharpMask.endPoint = CGPoint(x: 0.5, y: 0)
        sharpMask.colors = [NSColor.white.cgColor, NSColor.white.cgColor,
                            NSColor.clear.cgColor]
        layer?.addSublayer(sharpLayer)

        scrimLayer.startPoint = CGPoint(x: 0.5, y: 1)
        scrimLayer.endPoint = CGPoint(x: 0.5, y: 0)
        scrimLayer.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor,
                             NSColor(white: 0, alpha: A.backdropScrimBottom).cgColor]
        layer?.addSublayer(scrimLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 背景层不吃任何事件（它只是背景）。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: 数据

    /// 装封面。来的多半是 2000×938 的宽幅页头图（`Artist.bannerURL`），这类地址没有
    /// `R{n}x{n}M` 档位段，`ArtworkSize.url` 匹配不上会原样透传（也**不能**改写，
    /// 服务器只有预生成尺寸，改了必 404）；没有宽幅图的艺人退回方头像，那个地址是小图
    /// 模板，传 nil 拿到的就是 300px，糊过之后无所谓，但清晰层拉到 1237pt 会软——
    /// 所以按 `fullPlayer`(800pt) 要，`ArtworkSize.url` 会吸附到 1200px 档。
    func setArtwork(url: String?) {
        let request = ArtworkSize.url(url, points: ArtworkSize.fullPlayer)
        // 「没有封面」这一路每次都走到底：`nil == nil` 当成「没变」直接 return 的话，
        // 上一位艺人的头图会原样留在层上（同 `CatalogArtworkView.setArtwork`）。
        guard request != requestedURL || request == nil else { return }
        requestedURL = request
        loadTask?.cancel()
        loadTask = nil
        sharpImage = nil
        blurLayer.contents = nil
        sharpLayer.contents = nil
        canvasFor = nil
        // 换人时把号推过去：上一位的画布可能还在后台烘，回来时不作废就会贴到这一位身上。
        pendingCanvas = nil
        canvasToken &+= 1
        bakeTask?.cancel()
        bakeTask = nil
        guard let request else { return }
        if let cached = ImageCache.shared.memoryCachedImage(for: request) {
            install(image: cached)
            return
        }
        loadTask = Task { [weak self] in
            let image = await ImageCache.shared.image(for: request)
            guard let self, !Task.isCancelled, self.requestedURL == request, let image else { return }
            self.install(image: image)
        }
    }

    private func install(image: NSImage) {
        guard let cg = image.amberCGImage else { return }
        sharpImage = cg
        needsLayout = true
    }

    // MARK: 滚动

    func catalogPageScrollOffsetDidChange(_ offset: CGFloat) {
        let alpha = max(0, min(1, 1 - offset / A.backdropScrollFadeDistance))
        guard sharpLayer.opacity != Float(alpha) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sharpLayer.opacity = Float(alpha)
        CATransaction.commit()
    }

    // MARK: 排布

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }
        let heroHeight = A.heroHeight(viewportHeight: height)

        // 非翻转视图的 layer 坐标 y=0 在底：hero 带贴着视图顶。
        blurLayer.frame = bounds
        let heroRect = NSRect(x: 0, y: height - heroHeight, width: width, height: heroHeight)
        sharpLayer.frame = heroRect

        // 清晰层的渐隐段跟着**图**走，不是 hero 段：图按 fit-width 铺出来的自然高里，
        // 四成半到七成之间从清晰渐变进模糊（实机 1470×923：图 580、渐隐 260→418，
        // 按钮/名字压在渐糊带上才读得清）。段比图高的那截（图底到段底）完全交给糊层。
        let imageHeight = sharpImage.map { image in
            min(heroHeight, CGFloat(image.height) * (width / CGFloat(image.width)))
        } ?? heroHeight
        sharpMask.frame = sharpLayer.bounds
        sharpMask.locations = [NSNumber(value: Double(A.backdropSharpFadeStart * imageHeight / heroHeight)),
                               NSNumber(value: Double(A.backdropSharpFadeEnd * imageHeight / heroHeight))]

        // 压暗层：渐隐段末尾才开始压，到页面底压满。
        scrimLayer.frame = bounds
        scrimLayer.locations = [0, NSNumber(value: Double(min(1, A.backdropSharpFadeEnd
            * imageHeight / height))), 1]

        // 糊图与清晰层逐像素对齐，画布尺寸（宽/高）变了才重画。
        regenerateBackdropIfNeeded(width: width, height: height, heroHeight: heroHeight)
    }

    /// 把图**预合成**进两张画布，清晰层与糊层贴的都是画布，映射天然一致：
    ///
    /// 映射只有一套——整图**不裁切**：按内容列宽铺（fit-width）、**顶对齐页顶**、
    /// 自然高。图的自然高不到页底时（宽幅页头 2000×938 铺出来只有 ~570），底下用
    /// 镜像反射接下去——实机（Music 告五人页）栏目区背后就是画面内容的顺延
    /// （外套、白裙、光带一路延续下去），不是图底边拖出来的黑影；图比页高时
    /// （方头像退回）多出来的部分本来就是顺延，直接用。
    ///
    /// - 清晰画布：同一构图**不糊**，裁出 hero 带那一段，按 2x 渲染（要显示原图细节）。
    /// - 糊画布：同一构图 + 高斯 36，整页一段，1x 就够。
    /// 交叉淡化时两层逐像素对齐，图不会「呼吸」。
    ///
    /// 烘这两张**不在主线程做**：它从前挂在 `layout()` 里，而糊画布那一张是
    /// `CIGaussianBlur(radius: 36)` 渲整页 1x 画布，实时拖窗时每一档新尺寸都要同步烘一次。
    /// 现在投给 `bake` 那条 `@concurrent` 的路，算完回主 actor 贴——**这期间旧画布照旧
    /// 显示**（不清 `contents`），所以拖动过程中背景不会闪空。
    private func regenerateBackdropIfNeeded(width: CGFloat, height: CGFloat, heroHeight: CGFloat) {
        guard let sharpImage, sharpImage.width > 0, sharpImage.height > 0,
              width > 0, height > 0 else { return }
        let canvas = NSSize(width: width, height: height)
        func isSameCanvas(_ size: NSSize?) -> Bool {
            guard let size else { return false }
            return abs(size.width - canvas.width) < 0.5 && abs(size.height - canvas.height) < 0.5
        }
        if isSameCanvas(pendingCanvas) { return }
        if isSameCanvas(canvasFor), blurLayer.contents != nil { return }
        // 看不见就不起新的，记一笔等露出来再烘（见 `needsBakeWhenShown`）。在飞的那趟
        // 不动：它烘的是隐藏之前那一档，回来时多半正好用得上。
        if isHiddenOrHasHiddenAncestor {
            needsBakeWhenShown = true
            return
        }
        pendingCanvas = canvas
        canvasToken &+= 1
        let token = canvasToken
        let context = ciContext
        bakeTask?.cancel()
        bakeTask = Task { [weak self] in
            let baked = await Self.bake(source: sharpImage, width: width, height: height,
                                        heroHeight: heroHeight, context: context)
            // 号对不上＝这趟的输入已经过时（拖窗时后发的先回来是常态），画布丢掉，
            // 两份记账也不动——那是当值那一趟的。
            guard let self, self.canvasToken == token else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.sharpLayer.contents = baked.sharp
            self.blurLayer.contents = baked.blurred
            CATransaction.commit()
            self.canvasFor = canvas
            self.pendingCanvas = nil
            self.bakeTask = nil
        }
    }

    /// 露出来了（自己或祖先的 `isHidden` 翻回 false 都会调）：隐藏期间挡下的那次烘
    /// 在这里补。只标 `needsLayout`，真正投递仍走 `layout()` → `regenerateBackdropIfNeeded`
    /// 同一条路，尺寸取露出时那一刻的。烘好之前层上还是旧画布（不清 `contents`），
    /// 与拖窗途中的表现一样，不会闪空。
    override func viewDidUnhide() {
        super.viewDidUnhide()
        guard needsBakeWhenShown else { return }
        needsBakeWhenShown = false
        needsLayout = true
    }

    /// 烘那一趟本身。`@concurrent`：SE-0461 之后非隔离 async 函数默认继承调用方隔离，
    /// 不标就还是在主 actor 上跑，等于什么都没搬（同 `MusicProvider` 那 17 处的理由）。
    ///
    /// 入参全是 `Sendable` 的：`CGImage` 与 `CIContext` 头文件里就标着；
    /// `CIFilter` 不是，所以滤镜在这一路里现建。
    @concurrent
    private nonisolated static func bake(
        source: CGImage, width: CGFloat, height: CGFloat, heroHeight: CGFloat, context: CIContext
    ) async -> (sharp: CGImage?, blurred: CGImage?) {
        // 2x 像素空间里做映射（清晰画布要 retina 细节；糊画布顺着这个空间一起算，
        // 反正马上要糊掉）。视图坐标顶左、CI 坐标底左，图顶对齐页顶就是
        // CI 的 y = 画布高 − 图画布高。
        let scale2x = width * 2 / CGFloat(source.width)
        let drawnHeight2x = CGFloat(source.height) * scale2x
        let top2x = height * 2 - drawnHeight2x
        let image = CIImage(cgImage: source)
        let base = image
            .transformed(by: CGAffineTransform(scaleX: scale2x, y: scale2x))
            .transformed(by: CGAffineTransform(translationX: 0, y: top2x))
        var composed = base
        if drawnHeight2x < height * 2 {
            // 镜像一份贴在图底下面（关于图底那条线翻折），接出「顺延」的延续。
            let mirror = image
                .transformed(by: CGAffineTransform(scaleX: scale2x, y: -scale2x))
                .transformed(by: CGAffineTransform(translationX: 0, y: top2x))
            composed = base.composited(over: mirror)
        }
        composed = composed.clampedToExtent()

        // 清晰画布：hero 带那一段（2x）。
        let heroCrop = CGRect(x: 0, y: (height - heroHeight) * 2,
                              width: width * 2, height: heroHeight * 2)
        // 被取消（又来了新一档 / 换了人）就别再算了：结果拿回去也对不上号。
        // 两次渲染各看一眼，最贵的那张糊画布尤其要挡在前面。
        guard !Task.isCancelled else { return (nil, nil) }
        let sharp = context.createCGImage(composed, from: heroCrop)
        guard !Task.isCancelled else { return (nil, nil) }
        // 糊画布：整页（1x 像素空间另算一遍映射，反正马上糊掉）。
        var blurred: CGImage?
        if let filter = CIFilter(name: "CIGaussianBlur") {
            let scale1x = width / CGFloat(source.width)
            let top1x = height - CGFloat(source.height) * scale1x
            var page = image
                .transformed(by: CGAffineTransform(scaleX: scale1x, y: scale1x))
                .transformed(by: CGAffineTransform(translationX: 0, y: top1x))
            if CGFloat(source.height) * scale1x < height {
                let mirror1x = image
                    .transformed(by: CGAffineTransform(scaleX: scale1x, y: -scale1x))
                    .transformed(by: CGAffineTransform(translationX: 0, y: top1x))
                page = page.composited(over: mirror1x)
            }
            page = page.clampedToExtent()
            filter.setValue(page, forKey: kCIInputImageKey)
            filter.setValue(36, forKey: kCIInputRadiusKey)
            blurred = filter.outputImage.flatMap {
                context.createCGImage($0, from: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return (sharp, blurred)
    }
}

// MARK: - hero

/// 艺人页顶上那件「hero」collection item——**只摆艺人名与三枚圆键，不带图**。
///
/// 实机行为（Music 1.7，2026-09-06 告五人页）：名字与按钮是**内容**，随文稿滚；
/// 封面图钉在页面底下不滚（滚起来从清晰变糊），所以图挪到了 `ArtistBackdropView`
/// （钉在 scroll view 底下的背景层），这一件透明、让图从身上透出来。
///
/// **不可点**：不像别的目录卡那样点了跳转，右键也不弹菜单——落点全在那三枚圆键上。
final class ArtistHeroView: CatalogCardContentView {

    private typealias M = MusicMetrics.ArtistPage

    /// [推] 艺人名左右各让出的余量：与目录内容列的 `Catalog.leadingMargin`(34) 同宽，
    /// 名字长到要折行时不至于顶到窗口边。
    private static let nameSideMargin: CGFloat = MusicMetrics.Catalog.leadingMargin
    private let nameField = CatalogCardKit.label(size: M.heroNameSize, weight: .bold,
                                                 color: .white, lines: 2)
    // 字形尺寸按圆的直径取：Music 的 ⓘ/★ 大约占圆的四成、▶ 占三成半（参考图目测），
    // 这里按直径比例算，圆一改字形跟着走。
    private let infoButton = ArtistCircleButton(style: .glass, diameter: M.heroSideDiameter,
                                                symbol: "info", glyphSize: M.heroSideDiameter * 0.4)
    private let playButton = ArtistCircleButton(style: .solidWhite, diameter: M.heroPlayDiameter,
                                                symbol: "play.fill",
                                                glyphSize: M.heroPlayDiameter * 0.35)
    private let starButton = ArtistCircleButton(style: .glass, diameter: M.heroSideDiameter,
                                                symbol: "star.fill",
                                                glyphSize: M.heroSideDiameter * 0.36)

    /// 收藏态自己持有（铁律 3），点一下就地改字形色，不绕 `@Published`。
    private var isFavorite = false

    override func build() {
        nameField.alignment = .center
        // 压在图上的白字都带这层投影（与别的目录卡同一条），糊过的底也还是图，字要脱开
        CatalogCardKit.applyArtworkShadow(nameField, blur: 6, dy: 2)
        addSubview(nameField)

        infoButton.onClick = { [weak self] in self?.presentBio() }
        infoButton.setAccessibilityLabel("简介")
        infoButton.toolTip = "简介"
        addSubview(infoButton)

        playButton.glyphColor = .black          // 白底黑图标
        playButton.onClick = { [weak self] in self?.item?.onPlay?() }
        playButton.setAccessibilityLabel("播放")
        playButton.toolTip = "播放"
        addSubview(playButton)

        starButton.onClick = { [weak self] in self?.toggleFavorite() }
        addSubview(starButton)
    }

    override func apply(_ item: CatalogItem) {
        nameField.stringValue = item.title
        // 宽幅页头图由 `ArtistBackdropView` 装载，这里不碰封面；
        // `item.artworkURL` 仍随卡走，ⓘ 的介绍面板（`presentBio`）要用它。
        playButton.isEnabled = item.onPlay != nil
        // 没有热门歌曲可放时整枚键淡下去，别让它看着能点
        playButton.alphaValue = item.onPlay != nil ? 1 : 0.4
        refreshFavorite()
        needsLayout = true
    }

    /// 整件不给悬浮态（不可点）。
    override func hoverDidChange(_ hovering: Bool, animated: Bool) {}

    override func resetContent() {}

    // MARK: 不可点

    override func handleClick(at point: NSPoint, clickCount: Int) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func accessibilityPerformPress() -> Bool { false }

    // MARK: 收藏这位艺人

    private var artist: Artist? {
        if case .artist(let artist) = item?.route { return artist }
        return nil
    }

    private func refreshFavorite() {
        isFavorite = artist.map { appState?.library.isFavoriteArtist($0) ?? false } ?? false
        starButton.glyphColor = isFavorite ? NSColor(Color.amberKey) : .white
        starButton.isEnabled = artist != nil
        let label = isFavorite ? "取消收藏" : "收藏"
        starButton.setAccessibilityLabel(label)
        starButton.toolTip = label
    }

    private func toggleFavorite() {
        guard let artist, let appState else { return }
        appState.library.toggleFavoriteArtist(artist)
        refreshFavorite()
        starButton.needsDisplay = true
    }

    // MARK: ⓘ 简介

    /// Music 点 ⓘ 弹的是**一整块艺人介绍面板**（满幅大图 + 「关于」正文），不是一小片
    /// 纯文字气泡，所以这里只负责把内容凑齐、沿响应链交给宿主
    /// （`AboutPanelPresenting`，实现在`RootViewController`），面板本体在
    /// `AboutPanel.swift`。
    ///
    /// 事实行（「生日 / 1979年1月18日」「职业 / …」那几条）来自艺人本身：
    /// hero 这张卡的 `route` 就是`.artist(artist)`，`Artist.facts` 由音源填
    /// （QQ 走百科表，见 `QQAPI.parseWikiFacts`；给不出就是空数组，面板整段不占位）。
    /// 「职业」「代表作品」这类是并列的短词，摆成胶囊；日期/国籍是单值，摆成普通行。
    private func presentBio() {
        guard let item else { return }
        var facts: [AboutFact] = []
        if case .artist(let artist) = item.route {
            facts = artist.facts.map {
                AboutFact(label: $0.label, value: $0.value,
                              isChip: Self.chipFactLabels.contains($0.label))
            }
        }
        findAboutPanelPresenter()?.presentAboutPanel(
            AboutContent(name: item.title,
                             artworkURL: item.artworkURL,
                             facts: facts,
                             body: item.description))
    }

    #if DEBUG
    /// 实机验收用：`-artistdemo -artistbio` 直接弹介绍面板，走的就是 ⓘ 的这条路
    /// （交互类验收交给用户做，但「面板里到底有没有内容」得靠 `-dumpviews` 自证）。
    func debugPresentBio() { presentBio() }
    #endif

    /// 摆成胶囊的那几行（对应 Music 面板上「類型 / 國語流行樂」那种圆角标签）。
    private static let chipFactLabels: Set<String> = ["职业", "国籍"]

    // MARK: 排布

    override func layout() {
        super.layout()

        // 三枚圆键整行水平居中；相邻边距 27，行底距 hero 底 72。
        // **恒定三枚**：Music 的 ⓘ 一直在（点开的面板本来就有「没有简介」这一态），
        // 早先「没简介就藏起来、剩两枚重新居中」会让同一页在不同艺人之间整排左右横跳，
        // 而且横跳的还是白底 ▶ 这枚主键——用户实机反馈的就是这条，收回成固定排布。
        let side = M.heroSideDiameter
        let play = M.heroPlayDiameter
        let gap = M.heroButtonSpacing
        let rowWidth = side + gap + play + gap + side
        let rowBottom = M.heroButtonsBottom
        let centerY = rowBottom + play / 2
        var x = ((bounds.width - rowWidth) / 2).rounded()
        infoButton.frame = NSRect(x: x, y: centerY - side / 2, width: side, height: side)
        x += side + gap
        playButton.frame = NSRect(x: x, y: rowBottom, width: play, height: play)
        x += play + gap
        starButton.frame = NSRect(x: x, y: centerY - side / 2, width: side, height: side)

        // 艺人名：字形底（末行基线）距按钮行顶 20.5。基线在文本框底边上方一个 |descender|，
        // 两行时也成立（撑高是往上长），所以框底 = 基线 + descender（descender 为负）。
        let maxWidth = max(0, bounds.width - Self.nameSideMargin * 2)
        let nameHeight = nameField.sizeThatFits(NSSize(width: maxWidth,
                                                       height: .greatestFiniteMagnitude)).height
        let baseline = rowBottom + play + M.heroNameToButtons
        let nameY = baseline + (nameField.font?.descender ?? 0)
        nameField.frame = NSRect(x: (bounds.width - maxWidth) / 2, y: nameY,
                                 width: maxWidth, height: nameHeight)
    }
}

// MARK: - 「最新發行」卡

/// 图下并排带的左半：162 方封面贴左 + 右侧三行 + 一枚 ＋ 圆键。
/// 卡宽 364（`releaseWidth`）、卡高由布局给（3 ×`Catalog.trackRowHeight` = 168），
/// 所以这里一律按 `bounds` 排，不假设高度。
///
/// 点封面 / 标题进专辑页（走基类默认落点），右键走基类的 `CatalogCardActions`。
final class ArtistReleaseCardView: CatalogCardContentView {

    private typealias M = MusicMetrics.ArtistPage

    private let artworkView = CatalogArtworkView()
    private let dateField = CatalogCardKit.label(size: M.releaseDateSize,
                                                 color: .secondaryLabelColor)
    private let titleField = CatalogCardKit.label(size: M.releaseTitleSize, lines: 2)
    private let countField = CatalogCardKit.label(size: M.releaseCountSize,
                                                  color: .secondaryLabelColor)
    private let addButton = ArtistCircleButton(style: .subtle,
                                               diameter: M.releaseAddButtonSize,
                                               symbol: "plus",
                                               glyphSize: M.releaseAddButtonSize * 0.45)
    private let playButton = CatalogPlayButton()

    override func build() {
        artworkView.cornerRadius = MusicMetrics.Card.artworkCornerRadius
        addSubview(artworkView)
        playButton.onClick = { [weak self] in self?.item?.onPlay?() }
        artworkView.addSubview(playButton)

        addSubview(dateField)
        addSubview(titleField)
        addSubview(countField)

        addButton.glyphColor = .labelColor
        addButton.onClick = { [weak self] in self?.addTapped() }
        addSubview(addButton)
    }

    override func apply(_ item: CatalogItem) {
        artworkView.setArtwork(url: item.artworkURL, points: M.releaseArtwork,
                               fallbackColors: item.fallbackColors)
        dateField.stringValue = item.eyebrow ?? ""
        dateField.isHidden = (item.eyebrow ?? "").isEmpty
        titleField.stringValue = item.title
        countField.stringValue = item.subtitle ?? ""
        countField.isHidden = item.subtitle == nil
        addButton.isHidden = album == nil
        playButton.setVisible(false, animated: false)
        refreshLibraryState()
        needsLayout = true
    }

    override func hoverDidChange(_ hovering: Bool, animated: Bool) {
        artworkView.setHovering(hovering, animated: animated)
        // 只有真能播才摆播放键（`onPlay` 为 nil 时不摆）
        playButton.setVisible(hovering && item?.onPlay != nil, animated: animated)
    }

    override func resetContent() {
        artworkView.prepareForReuse()
        playButton.setVisible(false, animated: false)
    }

    override var artworkViewForAlignment: NSView? { artworkView }

    // MARK: ＋ 入库

    private var album: Album? {
        if case .album(let album) = item?.route { return album }
        return nil
    }

    /// 形态走 `DownloadStore.action(inLibrary:tracks:)`——专辑页头、播放列表页头、
    /// 资料库艺人页的专辑块都是这一套（+ / ↓ / ⏹ / ✓）。同一张碟从哪儿点都得是同一个手感。
    private var cardAction: LibraryDownloadAction = .addToLibrary

    private func refreshLibraryState() {
        guard let album, let appState else { return }
        let inLibrary = appState.library.isAlbumInLibrary(album)
        // 目录卡手里没有曲目，入库之后才能从资料库把它们取出来
        let tracks = inLibrary ? appState.library.tracks(in: album) : []
        cardAction = appState.downloads.action(inLibrary: inLibrary, tracks: tracks)
        addButton.setSymbol(cardAction.symbol)
        addButton.setAccessibilityLabel(cardAction.label)
        addButton.toolTip = cardAction.label
    }

    /// 入库要整张碟的曲目，先拉一次详情再写库——与 `CatalogCardActions.toggleAlbumLibrary`
    /// 同一条路（toast 文案也一致）。
    private func addTapped() {
        guard let album, let appState else { return }
        if cardAction != .addToLibrary {
            let tracks = appState.library.tracks(in: album)
            guard cardAction != .done else {
                // 点 ✓ ＝移除整张碟的下载，先问一句（`DownloadRemovalAlert`）
                DownloadRemovalAlert.confirm(count: tracks.count, in: amberWindow) { [weak self] in
                    appState.downloads.removeDownload(tracks)
                    self?.refreshLibraryState()
                }
                return
            }
            appState.downloads.perform(cardAction, tracks: tracks)
            refreshLibraryState()
            return
        }
        Task { @MainActor [weak self] in
            do {
                let detail = try await appState.provider(album.kind).albumDetail(album)
                appState.library.addAlbumToLibrary(album, tracks: detail.tracks)
                appState.showToast("已将《\(album.name)》添加到资料库")
                // 卡片是复用的：等回来时可能已经换了一张碟，只在还是同一张时刷图标
                if self?.album?.id == album.id { self?.refreshLibraryState() }
            } catch {
                appState.showToast("拿不到专辑曲目：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 排布

    override func layout() {
        super.layout()
        let art = M.releaseArtwork
        artworkView.frame = NSRect(x: 0, y: bounds.height - art, width: art, height: art)
        playButton.frame = NSRect(x: art - CatalogPlayButton.inset - CatalogPlayButton.diameter,
                                  y: CatalogPlayButton.inset,
                                  width: CatalogPlayButton.diameter,
                                  height: CatalogPlayButton.diameter)

        let textX = art + M.releaseArtworkToText
        let textWidth = max(0, bounds.width - textX)
        // 手排 frame 时把 label 自带的 2pt 内缩补回来，否则整列右移 2（`CatalogCardKit.labelInset`）
        let fieldX = textX - CatalogCardKit.labelInset
        let fieldWidth = textWidth + CatalogCardKit.labelInset * 2

        // 右列 = 日期 / 专辑名 / 曲目数 / ＋，**整列垂直居中**在卡里（实机如此，
        // 不是从封面顶往下排）：行距 4、末行到 ＋ 12。
        var rows: [(field: NSTextField, height: CGFloat)] = []
        for field in [dateField, titleField, countField] where !field.isHidden {
            let height = field === titleField
                ? field.sizeThatFits(NSSize(width: textWidth,
                                            height: .greatestFiniteMagnitude)).height
                : CatalogCardKit.lineHeight(field)
            rows.append((field, height))
        }
        let size = M.releaseAddButtonSize
        var total = size + M.releaseTextToButton
        for (index, row) in rows.enumerated() {
            total += row.height + (index > 0 ? M.releaseLineSpacing : 0)
        }
        var top = (bounds.height + total) / 2
        for row in rows {
            top -= row.height
            row.field.frame = NSRect(x: fieldX, y: top, width: fieldWidth, height: row.height)
            top -= M.releaseLineSpacing
        }
        // 循环退出时 top 已多减了一个行距，补回来再落 ＋（距末行 releaseTextToButton）。
        addButton.frame = NSRect(x: textX, y: top + M.releaseLineSpacing - size,
                                 width: size, height: size)
    }
}

// MARK: - NSCollectionViewItem 外壳

final class ArtistHeroItem: NSCollectionViewItem, CatalogCardConfigurable {
    private let card = ArtistHeroView()
    override func loadView() { view = card }
    override func prepareForReuse() { super.prepareForReuse(); card.prepareForReuse() }
    func configure(with item: CatalogItem, appState: AppState) {
        card.configure(with: item, appState: appState)
    }
}

final class ArtistReleaseItem: NSCollectionViewItem, CatalogCardConfigurable {
    private let card = ArtistReleaseCardView()
    override func loadView() { view = card }
    override func prepareForReuse() { super.prepareForReuse(); card.prepareForReuse() }
    func configure(with item: CatalogItem, appState: AppState) {
        card.configure(with: item, appState: appState)
    }
}
