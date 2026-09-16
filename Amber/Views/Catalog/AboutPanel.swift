import AppKit

// MARK: - 介绍面板

// 对应 Music 艺人页 hero 上那枚 ⓘ 键弹出的「艺人介绍」面板（用户实机截图为准，
// 不是 `catalog-artist.png` 里的形态——那张图没展开这个面板）。
//
// **两处在用**：艺人页 hero 的 ⓘ（`ArtistHeroView.presentBio()`）与专辑页头简介末行的
// 「更多」（`AlbumHeaderView.presentAbout()`）——所以类型名不带 artist，内容由调用点凑
// （`AboutContent`：名字 + 一张图 + 若干事实行 + 正文）。结构自上而下：
//
//   ┌────────────────────────────┐  ← 圆角矩形卡，比窗口小一圈、居中
//   │ ✕                          │     满幅铺大图（艺人页头图 / 专辑封面）
//   │                            │
//   │ ─── 下半程模糊 + 压暗 ───    │
//   │ 名字（32 semibold 白）       │
//   │ 成立日期 / 2017年           │  ← 事实行：小号次要标签 + 下一行正文（正文可为胶囊）
//   │ 關於                        │
//   │ 简介正文（13pt，长文可滚）    │
//   └────────────────────────────┘
//
// **这里的数一条实测基线都没有**（Music 这个面板没量过 AX/PX），所以全部标 `[推]`，
// 集中放在 `AboutMetrics` 里当本文件私有常量——按 `AGENTS.md`「界面层」第 5、6 条，
// 没有出处的数不许进 `MusicMetrics`。
//
// 下半程「既模糊又压暗」两层与 hero 是同一套手法（`NSVisualEffectView.maskImage`
// 一张上透明→下不透明的竖渐变，压暗的 `CAGradientLayer` 叠在模糊**之上**），
// 实测结论写在 `ArtistHeroView` 的类注释里，那两个零件（`ArtistScrimGradientView`
// / `ArtistCircleButton`）就是为了这里复用才从 private 提成 internal 的。
//
// **呈现方式是窗口内的覆盖层，不是 `presentAsSheet(_:)`**，理由见 `AboutPanelOverlayView`。
//
// 铁律：不新增 Representable（全 AppKit）；面板不进 `NSHostingView`；
// 简介正文照 Music **不可选中**，所以是普通 `NSTextField` 标签而不是 `NSTextView`。

// MARK: - 内容

/// 面板里「小号次要色标签 + 下一行正文」的一条事实行。
///
/// Music 那张截图上是「成立日期 / 2017年」「類型 / 國語流行樂（圆角胶囊）」。
/// 专辑那边填的是「艺人 / 发行日期 / 曲风」。
/// 我们的音源大多给不出这些字段，所以这一段是**有才摆**：给空数组就整段不占位
/// （连 `nameToFacts` 那段间距也不留）。等取数接上之后往调用点里填即可，面板这边不用改。
struct AboutFact {
    /// 上一行的小号次要色标签，例如「成立日期」
    let label: String
    /// 下一行的正文，例如「2017年」
    let value: String
    /// 正文是否摆成圆角胶囊（Music 的「類型」是胶囊，「成立日期」是纯文字）
    let isChip: Bool

    init(label: String, value: String, isChip: Bool = false) {
        self.label = label
        self.value = value
        self.isChip = isChip
    }
}

/// 面板要的全部内容。字段全部来自 `CatalogItem` 现有的三项：
/// `title` / `artworkURL` / `description`。
struct AboutContent {
    let name: String
    let artworkURL: String?
    let facts: [AboutFact]
    /// 简介正文；nil 或空串时面板照常出来，正文位置摆 `AboutPanelView.emptyBody`。
    let body: String?

    init(name: String, artworkURL: String?, facts: [AboutFact] = [], body: String?) {
        self.name = name
        self.artworkURL = artworkURL
        self.facts = facts
        self.body = body
    }
}

/// 面板的宿主。由 `RootViewController` 实现（它本来就是迷你播放器/整窗播放器/toast
/// 这些覆盖层的宿主）；hero 与专辑页头沿响应链往上找它，不持有引用（铁律 4：意图冒泡）。
@MainActor
protocol AboutPanelPresenting: AnyObject {
    func presentAboutPanel(_ content: AboutContent)
}

extension NSView {
    /// 沿响应链（自己 → 各级父视图 → 各级视图控制器 → 窗口）找简介面板的宿主。
    func findAboutPanelPresenter() -> AboutPanelPresenting? {
        var responder: NSResponder? = self
        while let current = responder {
            if let host = current as? AboutPanelPresenting { return host }
            responder = current.nextResponder
        }
        return nil
    }
}

// MARK: - 度量（全部 [推]）

private enum AboutMetrics {
    /// [推] 卡的圆角。用户读图约 20，与 macOS 26 的 sheet 观感同一档。
    static let cornerRadius: CGFloat = 20
    /// [推] 卡宽取窗口宽的 0.7，并夹在 480…900：窄了中文正文一行放不下几个字，
    /// 宽了长简介会摊成一行一行的长条，读起来要来回扫。
    static let widthRatio: CGFloat = 0.7
    static let minWidth: CGFloat = 480
    static let maxWidth: CGFloat = 900
    /// [推] 卡高上限取窗口高的 0.9（「比窗口小一圈」），超了正文自己滚。
    static let maxHeightRatio: CGFloat = 0.9
    /// [推] 卡高下限：简介只有一句话时也别塌成一条，上半程还得看得出是张艺人图。
    static let minHeight: CGFloat = 340
    /// [推] 「下半部分是模糊 + 压暗带」——取一半。卡高也是按这个比例反推的：
    /// 文字块量出多高，卡就有多高的两倍（再夹进上下限）。
    static let bandRatio: CGFloat = 0.5
    /// [推] 卡与窗口边之间至少留这么多，窄窗口下 `widthRatio` 算出来的宽由它兜底。
    static let windowMargin: CGFloat = 24

    /// [推] 左上角那枚毛玻璃 ✕：直径 40（比 hero 的侧键 45 小一档），离左、上各 24。
    static let closeDiameter: CGFloat = 40
    static let closeInset: CGFloat = 24

    /// [推] 文字左右各让 28。
    static let textInset: CGFloat = 28
    /// [推] 艺人名比 hero 上那个 40pt 小一档，取 32 semibold。
    static let nameSize: CGFloat = 32
    /// [推] 事实行：标签 11pt 次要（白 55%），正文 13pt 白。
    static let factLabelSize: CGFloat = 11
    static let factValueSize: CGFloat = 13
    /// [推] 「关于」与艺人名同族、小一档、加粗。
    static let aboutTitleSize: CGFloat = 20
    /// [推] 简介正文 13pt，行距按系统默认（不设 `NSParagraphStyle`）。
    static let bodySize: CGFloat = 13

    /// [推] 竖向间距。
    static let nameToFacts: CGFloat = 18
    static let factLabelToValue: CGFloat = 2
    static let factSpacing: CGFloat = 14
    static let factsToAbout: CGFloat = 24
    static let aboutToBody: CGFloat = 8
    static let bottomPadding: CGFloat = 28

    /// [推] 胶囊（「類型 / 國語流行樂」那种）：左右各 10、上下各 4，底是白 15%。
    static let chipPaddingH: CGFloat = 10
    static let chipPaddingV: CGFloat = 4

    /// [推] 卡的投影：与窗口内容拉开层次，让人一眼看出这是压在页面上的一层。
    static let shadowBlur: CGFloat = 40
    static let shadowOffsetY: CGFloat = 10

    static let bodyColor = NSColor(white: 1, alpha: 0.85)
    static let factLabelColor = NSColor(white: 1, alpha: 0.55)
    static let chipBackground = NSColor(white: 1, alpha: 0.15)
}

// MARK: - 胶囊

/// 事实行里 `isChip` 的那种正文：白 15% 的圆角胶囊 + 白字。
/// 宽高按字撑（`intrinsicContentSize`），圆角取高的一半。
private final class AboutChip: NSView {

    private let field = CatalogCardKit.label(size: AboutMetrics.factValueSize, color: .white)

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AboutMetrics.chipBackground.cgColor
        field.stringValue = text
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CatalogCardKit.textWidth(field).rounded(.up) + AboutMetrics.chipPaddingH * 2,
               height: CatalogCardKit.lineHeight(field) + AboutMetrics.chipPaddingV * 2)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        // label 自带 2pt 内缩，手排 frame 时补回来（`CatalogCardKit.labelInset`）
        let inset = CatalogCardKit.labelInset
        field.frame = NSRect(x: AboutMetrics.chipPaddingH - inset,
                             y: AboutMetrics.chipPaddingV,
                             width: bounds.width - AboutMetrics.chipPaddingH * 2 + inset * 2,
                             height: CatalogCardKit.lineHeight(field))
    }
}

// MARK: - 面板本体

/// 圆角卡本身：满幅大图 + 左上 ✕ + 下半程模糊压暗带上的文字块。
///
/// 尺寸由 `fittingSize(in:)` 给（宿主的覆盖层照它摆），内部一律手排 frame：
/// 文字块整体**贴底**排（自下而上：正文 → 关于 → 事实行 → 艺人名），
/// 内容不多时富余的高度留在艺人名上方，那截仍是图，与 Music 一致。
final class AboutPanelView: NSView {

    /// 没有简介时正文位置的那句话。口气与 `ArtistPageModel.emptyMessage`
    /// （「这位艺人暂时没有可显示的内容。」）一致。
    static let emptyBody = "这位艺人暂时没有简介。"

    var onClose: (() -> Void)?

    /// 圆角与裁切在这一层：投影要挂在**不裁切**的根上，两件事不能同一层做。
    private let clip = NSView()
    private let artworkView = CatalogArtworkView()
    private let blurBand = NSVisualEffectView()
    private let scrimView = ArtistScrimGradientView()
    private let nameField = CatalogCardKit.label(size: AboutMetrics.nameSize, weight: .semibold,
                                                 color: .white, lines: 2)
    private let aboutTitle = CatalogCardKit.label(size: AboutMetrics.aboutTitleSize,
                                                  weight: .semibold, color: .white)
    /// 正文照 Music **不可选中**：普通标签（`CatalogLabel` 连点击都不接），
    /// 长文的滚动交给外面这层 `NSScrollView`。
    private let bodyField = CatalogCardKit.label(size: AboutMetrics.bodySize,
                                                 color: AboutMetrics.bodyColor, lines: 0)
    private let bodyScroll = NSScrollView()
    private let bodyDocument = NSView()
    private let closeButton = ArtistCircleButton(style: .glass,
                                                 diameter: AboutMetrics.closeDiameter,
                                                 symbol: "xmark",
                                                 glyphSize: AboutMetrics.closeDiameter * 0.4)

    private var factRows: [(label: CatalogLabel, value: NSView)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.shadowBlurRadius = AboutMetrics.shadowBlur
        shadow.shadowOffset = NSSize(width: 0, height: -AboutMetrics.shadowOffsetY)
        self.shadow = shadow

        clip.wantsLayer = true
        clip.layer?.cornerRadius = AboutMetrics.cornerRadius
        clip.layer?.masksToBounds = true
        addSubview(clip)

        artworkView.cornerRadius = 0        // 圆角由 `clip` 统一切
        artworkView.hoverScrimOpacity = 0   // 面板不可点，也就没有悬浮暗罩
        clip.addSubview(artworkView)

        blurBand.material = .hudWindow
        blurBand.blendingMode = .withinWindow
        // 与 hero 同：压着大图的材质在窗口失焦时也不该退成灰片
        blurBand.state = .active
        blurBand.maskImage = ArtistScrimGradientView.makeFadeMask()
        clip.addSubview(blurBand)
        clip.addSubview(scrimView)          // 压暗层必须在模糊层之上

        nameField.stringValue = ""
        clip.addSubview(nameField)

        aboutTitle.stringValue = "关于"
        clip.addSubview(aboutTitle)

        bodyScroll.drawsBackground = false
        bodyScroll.autohidesScrollers = true
        bodyScroll.hasVerticalScroller = true
        bodyScroll.documentView = bodyDocument
        bodyDocument.addSubview(bodyField)
        clip.addSubview(bodyScroll)

        closeButton.onClick = { [weak self] in self?.onClose?() }
        closeButton.setAccessibilityLabel("关闭")
        closeButton.toolTip = "关闭"
        clip.addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 内容

    func apply(_ content: AboutContent) {
        nameField.stringValue = content.name
        setAccessibilityLabel(content.name)
        // 与 hero 要同一张图、同一档尺寸：命中同一份缓存，点开就有，不会白一帧。
        artworkView.setArtwork(url: content.artworkURL, points: ArtworkSize.fullPlayer)

        let body = content.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        bodyField.stringValue = body.isEmpty ? Self.emptyBody : body

        for row in factRows {
            row.label.removeFromSuperview()
            row.value.removeFromSuperview()
        }
        factRows = content.facts.map { fact in
            let label = CatalogCardKit.label(size: AboutMetrics.factLabelSize,
                                             color: AboutMetrics.factLabelColor)
            label.stringValue = fact.label
            clip.addSubview(label)
            let value: NSView
            if fact.isChip {
                value = AboutChip(text: fact.value)
            } else {
                let field = CatalogCardKit.label(size: AboutMetrics.factValueSize, color: .white)
                field.stringValue = fact.value
                value = field
            }
            clip.addSubview(value)
            return (label, value)
        }
        needsLayout = true
    }

    // MARK: 点击不外漏

    /// 面板里的空白处也算「面板上」：吞掉，别顺着响应链冒到覆盖层去（那层点了要关）。
    override func mouseDown(with event: NSEvent) {}

    // MARK: 尺寸

    /// 按容器（窗口内容区）给的余量算这张卡该多大。
    /// 宽：`widthRatio` 夹进 `minWidth…maxWidth`，再被窗口宽减两边留白兜底。
    /// 高：文字块量出的高度按 `bandRatio` 反推，夹进 `minHeight…窗口高 × maxHeightRatio`。
    func fittingSize(in container: NSSize) -> NSSize {
        let roomWidth = max(0, container.width - AboutMetrics.windowMargin * 2)
        let wanted = min(max(container.width * AboutMetrics.widthRatio, AboutMetrics.minWidth),
                         AboutMetrics.maxWidth)
        let width = min(wanted, roomWidth)
        let text = textMetrics(width: width)
        let natural = (text.fixed + text.body) / AboutMetrics.bandRatio
        let roomHeight = min(container.height * AboutMetrics.maxHeightRatio,
                             max(0, container.height - AboutMetrics.windowMargin * 2))
        let height = min(max(natural, AboutMetrics.minHeight), roomHeight)
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    /// 文字块拆成「固定的那些」与「正文」两截：卡高不够时只有正文让步（滚），
    /// 艺人名 / 事实行 / 「关于」始终整条摆得下。
    private func textMetrics(width: CGFloat) -> (fixed: CGFloat, body: CGFloat) {
        let fieldWidth = self.fieldWidth(for: width)
        var fixed = AboutMetrics.bottomPadding
        fixed += height(of: aboutTitle, width: fieldWidth) + AboutMetrics.aboutToBody
        fixed += AboutMetrics.factsToAbout
        if !factRows.isEmpty {
            for (index, row) in factRows.enumerated() {
                fixed += CatalogCardKit.lineHeight(row.label) + AboutMetrics.factLabelToValue
                fixed += valueHeight(row.value)
                if index < factRows.count - 1 { fixed += AboutMetrics.factSpacing }
            }
            fixed += AboutMetrics.nameToFacts
        }
        fixed += height(of: nameField, width: fieldWidth)
        return (fixed, height(of: bodyField, width: fieldWidth))
    }

    /// 手排 frame 的标签一律把自带的 2pt 内缩补回来，字的左沿才真在 `textInset` 上。
    private func fieldWidth(for width: CGFloat) -> CGFloat {
        max(0, width - AboutMetrics.textInset * 2) + CatalogCardKit.labelInset * 2
    }

    private func height(of field: NSTextField, width: CGFloat) -> CGFloat {
        field.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    private func valueHeight(_ view: NSView) -> CGFloat {
        (view as? NSTextField).map { CatalogCardKit.lineHeight($0) } ?? view.intrinsicContentSize.height
    }

    // MARK: 排布

    override func layout() {
        super.layout()
        clip.frame = bounds
        artworkView.frame = clip.bounds

        // 下半程那条带：模糊 + 压暗同高同位，压暗在上（与 hero 同一条）。
        let band = (bounds.height * AboutMetrics.bandRatio).rounded()
        let bandRect = NSRect(x: 0, y: 0, width: bounds.width, height: band)
        blurBand.frame = bandRect
        scrimView.frame = bandRect

        closeButton.frame = NSRect(x: AboutMetrics.closeInset,
                                   y: bounds.height - AboutMetrics.closeInset
                                      - AboutMetrics.closeDiameter,
                                   width: AboutMetrics.closeDiameter,
                                   height: AboutMetrics.closeDiameter)

        let fieldX = AboutMetrics.textInset - CatalogCardKit.labelInset
        let fieldWidth = self.fieldWidth(for: bounds.width)
        let text = textMetrics(width: bounds.width)
        // 正文可见高度：带里除去固定几条剩下多少就给多少，且不超过正文自己的高度
        // （否则非翻转坐标系里比可视区矮的文档会沉到底，「关于」与正文之间空一大截）。
        let bodyVisible = max(0, min(text.body, band - text.fixed))

        var cursor = AboutMetrics.bottomPadding
        bodyScroll.frame = NSRect(x: fieldX, y: cursor, width: fieldWidth, height: bodyVisible)
        bodyDocument.frame = NSRect(x: 0, y: 0, width: fieldWidth, height: text.body)
        bodyField.frame = bodyDocument.bounds
        // 文档比可视区高时 `NSScrollView` 初始停在**底部**（非翻转坐标系），先拉回顶端。
        bodyScroll.contentView.scroll(to: NSPoint(x: 0, y: text.body - bodyVisible))
        bodyScroll.hasVerticalScroller = text.body > bodyVisible
        cursor += bodyVisible + AboutMetrics.aboutToBody

        let aboutHeight = height(of: aboutTitle, width: fieldWidth)
        aboutTitle.frame = NSRect(x: fieldX, y: cursor, width: fieldWidth, height: aboutHeight)
        cursor += aboutHeight + AboutMetrics.factsToAbout

        // 事实行自下而上摆：每条先正文（或胶囊）后标签，条与条之间 factSpacing。
        for (index, row) in factRows.enumerated().reversed() {
            let valueHeight = self.valueHeight(row.value)
            if let chip = row.value as? AboutChip {
                chip.frame = NSRect(x: AboutMetrics.textInset, y: cursor,
                                    width: chip.intrinsicContentSize.width, height: valueHeight)
            } else {
                row.value.frame = NSRect(x: fieldX, y: cursor,
                                         width: fieldWidth, height: valueHeight)
            }
            cursor += valueHeight + AboutMetrics.factLabelToValue
            let labelHeight = CatalogCardKit.lineHeight(row.label)
            row.label.frame = NSRect(x: fieldX, y: cursor, width: fieldWidth, height: labelHeight)
            cursor += labelHeight
            if index > 0 { cursor += AboutMetrics.factSpacing }
        }
        if !factRows.isEmpty { cursor += AboutMetrics.nameToFacts }

        let nameHeight = height(of: nameField, width: fieldWidth)
        nameField.frame = NSRect(x: fieldX, y: cursor, width: fieldWidth, height: nameHeight)
    }
}

// MARK: - 覆盖层

/// 铺满窗口内容区的一层：居中摆面板、面板外面点一下就关。
///
/// **为什么不是 `presentAsSheet(_:)`**（动手前查过文档）：
/// - `NSWindow.beginSheet(_:completionHandler:)` 文档原话：sheet 在场期间
///   「most events targeted at the receiver are prohibited」——宿主窗口收不到点击，
///   「点面板外面关掉」这条就实现不了（系统 sheet 只认自己内部的按钮）。
///   而这正是 Music 这个面板的关法之一。
/// - `presentAsSheet(_:)` 文档只说「presents another view controller as a sheet」，
///   给的入口是 `dismiss(_:)`；sheet 窗口的背景与圆角由 AppKit 自己画，
///   AppKit 侧也没有 UIKit 那个 `sheetPresentationController` 可以调形
///   （那是 UIKit 的 API，AppKit 没有对应物），拿不到「满幅大图铺到圆角边」的保证。
///
/// 所以退回窗口内的覆盖层——`RootViewController` 本来就是迷你播放器、整窗播放器、
/// toast 这些覆盖层的宿主，照它现有的做法再加一层，Esc 也顺着它已有的
/// `cancelOperation(_:)` 走。sheet 白给的那三样（动画 / 焦点 / Esc）这边分别是：
/// 淡入淡出（带「减弱动态效果」降级）、面板自己吞点击、宿主的 `cancelOperation`。
final class AboutPanelOverlayView: NSView {

    let panel = AboutPanelView()
    /// 点面板外面 / 点 ✕ 都走这条。
    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 「四周窗口内容仍可见」：这层只负责接点击，不压暗——用户读图时没提到变暗，
        // 没有把握就不加。[推]
        addSubview(panel)
        panel.onClose = { [weak self] in self?.onDismiss?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let size = panel.fittingSize(in: bounds.size)
        panel.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                             y: ((bounds.height - size.height) / 2).rounded(),
                             width: size.width, height: size.height)
    }

    /// 落在面板上的点击由面板自己吞（`AboutPanelView.mouseDown`），
    /// 冒到这里的就只剩「面板外面」。
    override func mouseDown(with event: NSEvent) { onDismiss?() }

    /// 底下的页面在这层在场期间不该还能滚：这层不是滚动视图，响应链也不经过页面，
    /// 滚轮事件到此为止。
    override func scrollWheel(with event: NSEvent) {}
}
